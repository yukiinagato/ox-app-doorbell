// Doorbell Windows recovery supervisor.
//
// Production mode is a Windows service which launches DoorbellApp in the active console session
// and restarts it with bounded backoff. The app talks to the supervisor over a local named pipe
// that only the process the supervisor launched may use (the client PID is checked on connect):
// UI-thread heartbeats, the kiosk unlock window, and the reason for a deliberate exit. Three
// crashes in five minutes enter safe mode, which lifts itself after an hour without a crash or
// with --clear-safe-mode. Deliberate exits, restarts requested by the app, logoff and session
// moves are not crashes. The supervisor never reboots Windows.
//
// Files: the service keeps its state and log in %ProgramData%\Doorbell\service, a directory it
// creates with a protected DACL (SYSTEM and Administrators only, users may read). It refuses to
// write there if the directory is a reparse point, and never writes into the app's data
// directory, which ordinary users can modify.
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>
#include <userenv.h>
#include <wtsapi32.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "recovery_policy.h"

namespace {

constexpr wchar_t kServiceName[] = L"DoorbellWatchdog";
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\DoorbellWatchdog.v1";
// Without any heartbeat at all the app is treated as hung once this has passed since launch.
constexpr ULONGLONG kFirstHeartbeatGraceMs = 60'000;
// After the first heartbeat, this much silence means the UI thread is stuck.
constexpr ULONGLONG kHeartbeatTimeoutMs = 20'000;
constexpr std::uint64_t kHealthyRunMs = 5ULL * 60ULL * 1000ULL;
constexpr DWORD kUnlockMinSeconds = 60;
constexpr DWORD kUnlockMaxSeconds = 30 * 60;
constexpr DWORD kSessionMoveGraceMs = 10'000;
constexpr LONGLONG kMaxLogBytes = 1024 * 1024;

SERVICE_STATUS_HANDLE g_service_status_handle = nullptr;
SERVICE_STATUS g_service_status{};
HANDLE g_stop_event = nullptr;
// Signalled on any console-session change, so waits for an interactive user end early.
HANDLE g_session_event = nullptr;
std::wstring g_app_path;
std::atomic<DWORD> g_app_pid{0};
std::atomic<DWORD> g_app_session{0xFFFFFFFF};
std::atomic<ULONGLONG> g_last_heartbeat{0};
std::atomic<ULONGLONG> g_unlock_until{0};
std::atomic<bool> g_session_ended{false};
std::atomic<bool> g_session_move{false};
std::mutex g_expected_mu;
std::string g_expected_exit;
std::mutex g_client_mu;
HANDLE g_client_pipe = INVALID_HANDLE_VALUE;

std::wstring modulePath() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) return L"";
  return std::wstring(buffer.data(), length);
}

std::wstring parentDirectory(const std::wstring& path) {
  const std::size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? L"." : path.substr(0, slash);
}

std::wstring defaultAppPath() {
  return parentDirectory(modulePath()) + L"\\DoorbellApp.exe";
}

bool isReparsePoint(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
}

// SYSTEM and Administrators own the directory; authenticated users may only read it.
constexpr wchar_t kServiceDirSddl[] =
    L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FRFX;;;AU)";

bool applyProtectedDacl(const std::wstring& path) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(kServiceDirSddl, SDDL_REVISION_1,
                                                            &descriptor, nullptr))
    return false;
  BOOL present = FALSE, defaulted = FALSE;
  PACL dacl = nullptr;
  bool ok = GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) && present &&
            SetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
                                  DACL_SECURITY_INFORMATION |
                                      PROTECTED_DACL_SECURITY_INFORMATION,
                                  nullptr, nullptr, dacl, nullptr) == ERROR_SUCCESS;
  LocalFree(descriptor);
  return ok;
}

// Returns the service directory, or an empty string when it is unsafe or unavailable. The
// result is cached per process; the DACL is re-applied once so a tampered directory is repaired.
std::wstring serviceDirectory() {
  static std::once_flag once;
  static std::wstring directory;
  std::call_once(once, [] {
    wchar_t base[MAX_PATH]{};
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, 0, base))) return;
    const std::wstring root = std::wstring(base) + L"\\Doorbell";
    const std::wstring candidate = root + L"\\service";
    CreateDirectoryW(root.c_str(), nullptr);
    if (isReparsePoint(root)) {
      OutputDebugStringW(L"[doorbell-watchdog] refusing a reparse-point data root\n");
      return;
    }
    CreateDirectoryW(candidate.c_str(), nullptr);
    if (isReparsePoint(candidate)) {
      OutputDebugStringW(L"[doorbell-watchdog] refusing a reparse-point service directory\n");
      return;
    }
    if (!applyProtectedDacl(candidate)) {
      OutputDebugStringW(L"[doorbell-watchdog] cannot protect the service directory\n");
      return;
    }
    directory = candidate;
  });
  return directory;
}

std::wstring servicePath(const wchar_t* leaf) {
  const std::wstring directory = serviceDirectory();
  return directory.empty() ? L"" : directory + L"\\" + leaf;
}

std::wstring statePath() { return servicePath(L"watchdog-state.txt"); }
std::wstring logPath() { return servicePath(L"watchdog.log"); }

std::string utf8(const std::wstring& input) {
  if (input.empty()) return {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, input.c_str(), -1, nullptr, 0,
                                        nullptr, nullptr);
  if (bytes <= 1) return {};
  std::string result(static_cast<std::size_t>(bytes), '\0');
  if (WideCharToMultiByte(CP_UTF8, 0, input.c_str(), -1, &result[0], bytes,
                          nullptr, nullptr) == 0) {
    return {};
  }
  result.resize(static_cast<std::size_t>(bytes - 1));
  return result;
}

std::mutex g_log_mu;

void logLine(const std::wstring& message) {
  OutputDebugStringW((L"[doorbell-watchdog] " + message + L"\n").c_str());
  const std::wstring path = logPath();
  if (path.empty()) return;
  std::lock_guard<std::mutex> lock(g_log_mu);
  WIN32_FILE_ATTRIBUTE_DATA info{};
  if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) {
    LARGE_INTEGER size{};
    size.LowPart = info.nFileSizeLow;
    size.HighPart = static_cast<LONG>(info.nFileSizeHigh);
    if (size.QuadPart > kMaxLogBytes) {
      const std::wstring rotated = path + L".1";
      MoveFileExW(path.c_str(), rotated.c_str(), MOVEFILE_REPLACE_EXISTING);
    }
  }
  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now{};
  GetSystemTime(&now);
  wchar_t stamp[32]{};
  wsprintfW(stamp, L"%04u-%02u-%02uT%02u:%02u:%02uZ ", now.wYear, now.wMonth, now.wDay,
            now.wHour, now.wMinute, now.wSecond);
  const std::string line = utf8(stamp + message + L"\r\n");
  DWORD written = 0;
  if (!line.empty()) {
    WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
  }
  CloseHandle(file);
}

std::uint64_t nowEpochMs() {
  FILETIME file_time{};
  GetSystemTimeAsFileTime(&file_time);
  ULARGE_INTEGER value{};
  value.LowPart = file_time.dwLowDateTime;
  value.HighPart = file_time.dwHighDateTime;
  constexpr std::uint64_t kWindowsToUnix100ns = 116444736000000000ULL;
  return (value.QuadPart - kWindowsToUnix100ns) / 10'000ULL;
}

bool readWholeFile(const std::wstring& path, std::string* result) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart < 0 || size.QuadPart > 64 * 1024) {
    CloseHandle(file);
    return false;
  }
  result->assign(static_cast<std::size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  const BOOL ok = result->empty() ||
      ReadFile(file, &(*result)[0], static_cast<DWORD>(result->size()), &read, nullptr);
  CloseHandle(file);
  if (!ok) return false;
  result->resize(read);
  return true;
}

doorbell::RecoveryPolicy loadPolicy() {
  doorbell::RecoveryPolicy policy;
  std::string data;
  if (!readWholeFile(statePath(), &data)) return policy;

  bool safe_mode = false;
  std::size_t consecutive = 0;
  std::uint64_t last_failure = 0;
  std::vector<std::uint64_t> failures;
  std::istringstream input(data);
  std::string line;
  while (std::getline(input, line)) {
    try {
      if (line.rfind("safe=", 0) == 0) safe_mode = line.substr(5) == "1";
      if (line.rfind("consecutive=", 0) == 0) {
        consecutive = static_cast<std::size_t>(std::stoull(line.substr(12)));
      }
      if (line.rfind("failure=", 0) == 0) failures.push_back(std::stoull(line.substr(8)));
      if (line.rfind("last_failure=", 0) == 0) last_failure = std::stoull(line.substr(13));
    } catch (...) {
      logLine(L"Ignoring malformed recovery-state entry");
    }
  }
  policy.restore(safe_mode, consecutive, failures, last_failure);
  policy.prune(nowEpochMs());
  return policy;
}

bool savePolicy(const doorbell::RecoveryPolicy& policy) {
  const std::wstring target = statePath();
  if (target.empty()) return false;
  const std::wstring temporary = target + L".tmp";
  std::ostringstream output;
  output << "schema=2\n";
  output << "safe=" << (policy.safeMode() ? 1 : 0) << "\n";
  output << "consecutive=" << policy.consecutiveFailures() << "\n";
  output << "last_failure=" << policy.lastFailureMs() << "\n";
  for (const std::uint64_t failure : policy.failureTimes()) {
    output << "failure=" << failure << "\n";
  }
  const std::string body = output.str();
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH |
                                FILE_FLAG_OPEN_REPARSE_POINT,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const BOOL ok = WriteFile(file, body.data(), static_cast<DWORD>(body.size()),
                            &written, nullptr) && written == body.size() && FlushFileBuffers(file);
  CloseHandle(file);
  if (!ok || !MoveFileExW(temporary.c_str(), target.c_str(),
                          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

bool unlockActive() {
  const ULONGLONG until = g_unlock_until.load();
  return until != 0 && GetTickCount64() < until;
}

std::string takeExpectedExit() {
  std::lock_guard<std::mutex> lock(g_expected_mu);
  std::string reason = g_expected_exit;
  g_expected_exit.clear();
  return reason;
}

// ---- Supervisor channel --------------------------------------------------------------------

// Interactive users may connect; the server then accepts only the PID it launched.
constexpr wchar_t kPipeSddl[] = L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)";

bool waitOverlapped(HANDLE pipe, OVERLAPPED* overlapped, DWORD* transferred, DWORD timeout) {
  HANDLE handles[2] = {overlapped->hEvent, g_stop_event};
  const DWORD wait = WaitForMultipleObjects(2, handles, FALSE, timeout);
  if (wait != WAIT_OBJECT_0) {
    CancelIoEx(pipe, overlapped);
    GetOverlappedResult(pipe, overlapped, transferred, TRUE);
    return false;
  }
  return GetOverlappedResult(pipe, overlapped, transferred, FALSE) != FALSE;
}

void handleCommand(const std::string& line) {
  if (line == "hb") {
    g_last_heartbeat.store(GetTickCount64());
    return;
  }
  if (line.rfind("unlock ", 0) == 0) {
    DWORD seconds = kUnlockMinSeconds;
    try {
      seconds = static_cast<DWORD>(std::stoul(line.substr(7)));
    } catch (...) {
    }
    seconds = (std::max)(kUnlockMinSeconds, (std::min)(kUnlockMaxSeconds, seconds));
    g_unlock_until.store(GetTickCount64() + static_cast<ULONGLONG>(seconds) * 1000ULL);
    logLine(L"Kiosk unlocked by the app for " + std::to_wstring(seconds) + L" seconds");
    return;
  }
  if (line == "lock") {
    if (g_unlock_until.exchange(0) != 0) logLine(L"Kiosk locked again by the app");
    return;
  }
  if (line.rfind("expect ", 0) == 0) {
    const std::string reason = line.substr(7);
    if (reason == "clean" || reason == "restart" || reason == "session") {
      std::lock_guard<std::mutex> lock(g_expected_mu);
      g_expected_exit = reason;
    }
  }
}

bool sendToApp(const std::string& message) {
  std::lock_guard<std::mutex> lock(g_client_mu);
  if (g_client_pipe == INVALID_HANDLE_VALUE) return false;
  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!overlapped.hEvent) return false;
  DWORD written = 0;
  bool ok = WriteFile(g_client_pipe, message.data(), static_cast<DWORD>(message.size()),
                      &written, &overlapped) != FALSE;
  if (!ok && GetLastError() == ERROR_IO_PENDING)
    ok = waitOverlapped(g_client_pipe, &overlapped, &written, 2000);
  CloseHandle(overlapped.hEvent);
  return ok && written == message.size();
}

void serveClient(HANDLE pipe) {
  {
    std::lock_guard<std::mutex> lock(g_client_mu);
    g_client_pipe = pipe;
  }
  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  char buffer[512];
  while (overlapped.hEvent && WaitForSingleObject(g_stop_event, 0) == WAIT_TIMEOUT) {
    ResetEvent(overlapped.hEvent);
    DWORD read = 0;
    BOOL ok = ReadFile(pipe, buffer, sizeof(buffer) - 1, &read, &overlapped);
    if (!ok && GetLastError() == ERROR_IO_PENDING)
      ok = waitOverlapped(pipe, &overlapped, &read, INFINITE) ? TRUE : FALSE;
    if (!ok || read == 0) break;
    std::string line(buffer, buffer + read);
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
    handleCommand(line);
  }
  if (overlapped.hEvent) CloseHandle(overlapped.hEvent);
  std::lock_guard<std::mutex> lock(g_client_mu);
  g_client_pipe = INVALID_HANDLE_VALUE;
}

DWORD WINAPI pipeServer(LPVOID) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(kPipeSddl, SDDL_REVISION_1,
                                                            &descriptor, nullptr)) {
    logLine(L"Supervisor channel unavailable: security descriptor");
    return 0;
  }
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = descriptor;
  while (WaitForSingleObject(g_stop_event, 0) == WAIT_TIMEOUT) {
    HANDLE pipe = CreateNamedPipeW(
        kPipeName, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1,
        4096, 4096, 0, &attributes);
    if (pipe == INVALID_HANDLE_VALUE) {
      logLine(L"Supervisor channel unavailable, error=" + std::to_wstring(GetLastError()));
      if (WaitForSingleObject(g_stop_event, 5000) != WAIT_TIMEOUT) break;
      continue;
    }
    OVERLAPPED overlapped{};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    DWORD ignored = 0;
    BOOL connected = ConnectNamedPipe(pipe, &overlapped);
    if (!connected) {
      const DWORD error = GetLastError();
      if (error == ERROR_PIPE_CONNECTED) connected = TRUE;
      else if (error == ERROR_IO_PENDING)
        connected = waitOverlapped(pipe, &overlapped, &ignored, INFINITE) ? TRUE : FALSE;
    }
    if (overlapped.hEvent) CloseHandle(overlapped.hEvent);
    if (connected) {
      ULONG client_pid = 0;
      const DWORD expected = g_app_pid.load();
      if (GetNamedPipeClientProcessId(pipe, &client_pid) && expected != 0 &&
          client_pid == expected) {
        serveClient(pipe);
      } else {
        logLine(L"Rejected a supervisor-channel client that is not the launched app (pid=" +
                std::to_wstring(client_pid) + L")");
      }
      DisconnectNamedPipe(pipe);
    }
    CloseHandle(pipe);
  }
  LocalFree(descriptor);
  return 0;
}

// ---- Foreground guard (console mode only) ---------------------------------------------------
// In service mode the supervisor runs in session 0 and cannot touch the user's desktop; the app
// keeps its own kiosk window in front there.

struct FindWindowData {
  DWORD pid;
  HWND window;
};

BOOL CALLBACK findWindowCallback(HWND window, LPARAM parameter) {
  auto* data = reinterpret_cast<FindWindowData*>(parameter);
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid == data->pid && IsWindowVisible(window) && GetWindow(window, GW_OWNER) == nullptr) {
    data->window = window;
    return FALSE;
  }
  return TRUE;
}

DWORD WINAPI foregroundGuard(LPVOID) {
  while (WaitForSingleObject(g_stop_event, 3000) == WAIT_TIMEOUT) {
    const DWORD app_pid = g_app_pid.load();
    if (app_pid == 0 || unlockActive()) continue;
    DWORD foreground_pid = 0;
    const HWND foreground = GetForegroundWindow();
    if (foreground) GetWindowThreadProcessId(foreground, &foreground_pid);
    if (foreground_pid == app_pid) continue;
    FindWindowData data{app_pid, nullptr};
    EnumWindows(findWindowCallback, reinterpret_cast<LPARAM>(&data));
    if (!data.window) continue;
    if (IsIconic(data.window)) ShowWindow(data.window, SW_RESTORE);
    SetWindowPos(data.window, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetForegroundWindow(data.window);
  }
  return 0;
}

// ---- Launch and supervision -----------------------------------------------------------------

bool launchProcess(bool as_active_user, bool safe_mode, PROCESS_INFORMATION* process) {
  std::wstring command = L"\"" + g_app_path + L"\" --supervised";
  if (safe_mode) command += L" --safe-mode";
  std::vector<wchar_t> command_buffer(command.begin(), command.end());
  command_buffer.push_back(L'\0');
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.lpDesktop = const_cast<wchar_t*>(L"winsta0\\default");
  const std::wstring working_directory = parentDirectory(g_app_path);

  if (!as_active_user) {
    return CreateProcessW(g_app_path.c_str(), command_buffer.data(), nullptr, nullptr, FALSE,
                          CREATE_NEW_PROCESS_GROUP, nullptr, working_directory.c_str(),
                          &startup, process) != FALSE;
  }

  const DWORD session = WTSGetActiveConsoleSessionId();
  if (session == 0xFFFFFFFF) {
    SetLastError(ERROR_NO_SUCH_LOGON_SESSION);
    return false;
  }
  HANDLE user_token = nullptr;
  HANDLE primary_token = nullptr;
  LPVOID environment = nullptr;
  bool launched = false;
  if (WTSQueryUserToken(session, &user_token) &&
      DuplicateTokenEx(user_token, TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY |
                                       TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID,
                       nullptr, SecurityImpersonation, TokenPrimary, &primary_token)) {
    CreateEnvironmentBlock(&environment, primary_token, FALSE);
    launched = CreateProcessAsUserW(
                   primary_token, g_app_path.c_str(), command_buffer.data(), nullptr, nullptr,
                   FALSE, CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT, environment,
                   working_directory.c_str(), &startup, process) != FALSE;
  }
  if (environment) DestroyEnvironmentBlock(environment);
  if (primary_token) CloseHandle(primary_token);
  if (user_token) CloseHandle(user_token);
  return launched;
}

struct ChildOutcome {
  bool stopped = false;
  bool heartbeat_timeout = false;
  bool session_ended = false;
  DWORD exit_code = 0;
  std::uint64_t elapsed_ms = 0;
};

ChildOutcome superviseChild(PROCESS_INFORMATION* process) {
  ChildOutcome outcome;
  g_last_heartbeat.store(0);
  g_session_ended.store(false);
  g_session_move.store(false);
  takeExpectedExit();
  DWORD session = 0xFFFFFFFF;
  if (ProcessIdToSessionId(process->dwProcessId, &session)) g_app_session.store(session);
  g_app_pid.store(process->dwProcessId);
  AllowSetForegroundWindow(process->dwProcessId);
  const ULONGLONG started = GetTickCount64();
  ULONGLONG move_requested = 0;
  HANDLE wait_handles[2] = {g_stop_event, process->hProcess};

  for (;;) {
    const DWORD wait = WaitForMultipleObjects(2, wait_handles, FALSE, 1000);
    if (wait == WAIT_OBJECT_0) {
      outcome.stopped = true;
      break;
    }
    if (wait == WAIT_OBJECT_0 + 1) break;
    const ULONGLONG now = GetTickCount64();
    if (g_session_move.load()) {
      if (move_requested == 0) {
        move_requested = now;
        logLine(L"Console session changed; asking DoorbellApp to move to the active session");
        if (!sendToApp("exit session")) move_requested = now - kSessionMoveGraceMs;
      }
      if (now - move_requested >= kSessionMoveGraceMs) {
        TerminateProcess(process->hProcess, doorbell::kExitSessionEnded);
        WaitForSingleObject(process->hProcess, 5000);
        outcome.session_ended = true;
        break;
      }
      continue;
    }
    const ULONGLONG last = g_last_heartbeat.load();
    const bool hung = last == 0 ? now - started >= kFirstHeartbeatGraceMs
                                : now - last >= kHeartbeatTimeoutMs;
    if (hung && !g_session_ended.load()) {
      logLine(last == 0 ? L"DoorbellApp never sent a UI heartbeat; terminating it"
                        : L"DoorbellApp UI heartbeat timed out; terminating it");
      TerminateProcess(process->hProcess, ERROR_TIMEOUT);
      WaitForSingleObject(process->hProcess, 5000);
      outcome.heartbeat_timeout = true;
      break;
    }
  }

  if (outcome.stopped && WaitForSingleObject(process->hProcess, 0) == WAIT_TIMEOUT) {
    sendToApp("exit service_stop");
    if (WaitForSingleObject(process->hProcess, 5000) == WAIT_TIMEOUT) {
      TerminateProcess(process->hProcess, ERROR_CANCELLED);
      WaitForSingleObject(process->hProcess, 5000);
    }
  }
  GetExitCodeProcess(process->hProcess, &outcome.exit_code);
  if (g_session_ended.load() || g_session_move.load()) outcome.session_ended = true;
  outcome.elapsed_ms = GetTickCount64() - started;
  g_app_pid.store(0);
  CloseHandle(process->hThread);
  CloseHandle(process->hProcess);
  return outcome;
}

// Waits up to ms or until stop; a session change ends the wait early. Returns false on stop.
bool waitOrStop(DWORD ms) {
  HANDLE handles[2] = {g_stop_event, g_session_event};
  const DWORD count = g_session_event ? 2 : 1;
  const DWORD wait = WaitForMultipleObjects(count, handles, FALSE, ms);
  if (g_session_event) ResetEvent(g_session_event);
  return wait != WAIT_OBJECT_0;
}

int runSupervisor(bool service_mode) {
  doorbell::RecoveryPolicy policy = loadPolicy();
  if (policy.maybeAutoClear(nowEpochMs())) {
    logLine(L"Safe mode lifted: no crash in the last hour");
    savePolicy(policy);
  }
  HANDLE server = CreateThread(nullptr, 0, pipeServer, nullptr, 0, nullptr);
  if (!server) logLine(L"Supervisor channel thread unavailable; exit monitoring remains active");

  HANDLE guard = nullptr;
  if (!service_mode) guard = CreateThread(nullptr, 0, foregroundGuard, nullptr, 0, nullptr);

  while (WaitForSingleObject(g_stop_event, 0) == WAIT_TIMEOUT) {
    if (policy.maybeAutoClear(nowEpochMs())) {
      logLine(L"Safe mode lifted: no crash in the last hour");
      savePolicy(policy);
    }
    PROCESS_INFORMATION process{};
    if (!launchProcess(service_mode, policy.safeMode(), &process)) {
      const DWORD error = GetLastError();
      if (service_mode && (error == ERROR_NO_TOKEN || error == ERROR_NO_SUCH_LOGON_SESSION ||
                           error == ERROR_PIPE_NOT_CONNECTED)) {
        // No interactive user yet: not an application crash. A logon ends the wait early.
        if (!waitOrStop(5000)) break;
        continue;
      }
      logLine(L"DoorbellApp launch failed, error=" + std::to_wstring(error));
      const unsigned delay = policy.recordFailure(nowEpochMs());
      savePolicy(policy);
      if (!waitOrStop(delay * 1000)) break;
      continue;
    }

    logLine(L"DoorbellApp launched pid=" + std::to_wstring(process.dwProcessId) +
            (policy.safeMode() ? L" (safe mode)" : L""));
    const ChildOutcome outcome = superviseChild(&process);
    if (outcome.stopped) break;

    const std::string expected = takeExpectedExit();
    const doorbell::ExitKind kind = doorbell::classifyExit(
        outcome.exit_code, outcome.heartbeat_timeout, outcome.session_ended, expected);
    if (outcome.elapsed_ms >= kHealthyRunMs) policy.recordHealthy();

    switch (kind) {
      case doorbell::ExitKind::restart_requested:
        logLine(L"DoorbellApp asked to be restarted");
        savePolicy(policy);
        if (!waitOrStop(1000)) goto done;
        continue;
      case doorbell::ExitKind::session_ended:
        logLine(L"DoorbellApp ended with its console session; waiting for the active session");
        savePolicy(policy);
        if (!waitOrStop(2000)) goto done;
        continue;
      case doorbell::ExitKind::already_running:
        logLine(L"Another DoorbellApp instance owns this device; retrying in 10 seconds");
        if (!waitOrStop(10'000)) goto done;
        continue;
      case doorbell::ExitKind::clean:
        savePolicy(policy);
        if (unlockActive()) {
          logLine(L"DoorbellApp closed by an administrator; relaunching when the unlock ends");
          while (unlockActive())
            if (!waitOrStop(3000)) goto done;
        } else {
          logLine(L"DoorbellApp closed while the kiosk was locked; relaunching");
          if (!waitOrStop(2000)) goto done;
        }
        continue;
      case doorbell::ExitKind::failure:
        break;
    }

    const unsigned delay = policy.recordFailure(nowEpochMs());
    savePolicy(policy);
    logLine(L"DoorbellApp failure exit=" + std::to_wstring(outcome.exit_code) +
            (outcome.heartbeat_timeout ? L" (hung)" : L"") + L", retry in " +
            std::to_wstring(delay) + L" seconds" +
            (policy.safeMode() ? L" (safe mode active)" : L""));
    if (!waitOrStop(delay * 1000)) break;
  }

done:
  if (guard) {
    WaitForSingleObject(guard, 5000);
    CloseHandle(guard);
  }
  if (server) {
    // Unblock a ConnectNamedPipe that is still waiting for a client.
    HANDLE poke = CreateFileW(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, 0, nullptr);
    if (poke != INVALID_HANDLE_VALUE) CloseHandle(poke);
    WaitForSingleObject(server, 5000);
    CloseHandle(server);
  }
  return 0;
}

void setServiceStatus(DWORD state, DWORD error = NO_ERROR, DWORD hint = 0) {
  g_service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_service_status.dwCurrentState = state;
  g_service_status.dwControlsAccepted =
      state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SESSIONCHANGE : 0;
  g_service_status.dwWin32ExitCode = error;
  g_service_status.dwWaitHint = hint;
  SetServiceStatus(g_service_status_handle, &g_service_status);
}

void onSessionChange(DWORD event_type, DWORD session_id) {
  const DWORD app_session = g_app_session.load();
  const bool app_running = g_app_pid.load() != 0;
  switch (event_type) {
    case WTS_SESSION_LOGOFF:
      if (app_running && session_id == app_session) g_session_ended.store(true);
      break;
    case WTS_CONSOLE_CONNECT:
    case WTS_SESSION_LOGON:
      // Fast user switching or a new logon on the console: the kiosk belongs to whoever is now
      // at the screen. A non-console logon (RDP) is ignored by the active-console check.
      if (app_running && session_id != app_session &&
          session_id == WTSGetActiveConsoleSessionId())
        g_session_move.store(true);
      break;
    default:
      break;
  }
  if (g_session_event) SetEvent(g_session_event);
}

DWORD WINAPI serviceControl(DWORD control, DWORD event_type, LPVOID event_data, LPVOID) {
  if (control == SERVICE_CONTROL_STOP && g_stop_event) {
    setServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 20'000);
    SetEvent(g_stop_event);
    return NO_ERROR;
  }
  if (control == SERVICE_CONTROL_SESSIONCHANGE && event_data) {
    const auto* notification = static_cast<const WTSSESSION_NOTIFICATION*>(event_data);
    onSessionChange(event_type, notification->dwSessionId);
    return NO_ERROR;
  }
  if (control == SERVICE_CONTROL_INTERROGATE) return NO_ERROR;
  return ERROR_CALL_NOT_IMPLEMENTED;
}

void WINAPI serviceMain(DWORD argc, wchar_t** argv) {
  (void)argc;
  (void)argv;
  g_service_status_handle = RegisterServiceCtrlHandlerExW(kServiceName, serviceControl, nullptr);
  if (!g_service_status_handle) return;
  setServiceStatus(SERVICE_START_PENDING, NO_ERROR, 10'000);
  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  g_session_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!g_stop_event) {
    setServiceStatus(SERVICE_STOPPED, GetLastError());
    return;
  }
  setServiceStatus(SERVICE_RUNNING);
  const int result = runSupervisor(true);
  CloseHandle(g_stop_event);
  g_stop_event = nullptr;
  if (g_session_event) CloseHandle(g_session_event);
  g_session_event = nullptr;
  setServiceStatus(SERVICE_STOPPED, result == 0 ? NO_ERROR : ERROR_SERVICE_SPECIFIC_ERROR);
}

BOOL WINAPI consoleControl(DWORD control) {
  if ((control == CTRL_C_EVENT || control == CTRL_BREAK_EVENT || control == CTRL_CLOSE_EVENT) &&
      g_stop_event) {
    SetEvent(g_stop_event);
    return TRUE;
  }
  return FALSE;
}

std::wstring quote(const std::wstring& value) { return L"\"" + value + L"\""; }

int installService(const std::wstring& app_path) {
  if (GetFileAttributesW(app_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    logLine(L"Cannot install: DoorbellApp.exe not found at " + app_path);
    return 2;
  }
  const std::wstring binary = quote(modulePath()) + L" --service " + quote(app_path);
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CREATE_SERVICE);
  if (!manager) return 3;
  SC_HANDLE service = CreateServiceW(
      manager, kServiceName, L"Doorbell kiosk watchdog", SERVICE_CHANGE_CONFIG | DELETE |
      SERVICE_START | SERVICE_STOP, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START,
      SERVICE_ERROR_NORMAL, binary.c_str(), nullptr, nullptr, nullptr, nullptr, nullptr);
  if (!service) {
    const DWORD error = GetLastError();
    CloseServiceHandle(manager);
    return error == ERROR_SERVICE_EXISTS ? 4 : 5;
  }
  SERVICE_DESCRIPTIONW description{};
  description.lpDescription = const_cast<wchar_t*>(
      L"Restarts DoorbellApp with UI heartbeat monitoring, bounded backoff and safe mode.");
  ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, &description);
  SERVICE_DELAYED_AUTO_START_INFO delayed{TRUE};
  ChangeServiceConfig2W(service, SERVICE_CONFIG_DELAYED_AUTO_START_INFO, &delayed);
  const BOOL started = StartServiceW(service, 0, nullptr);
  const DWORD start_error = started ? ERROR_SUCCESS : GetLastError();
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return (started || start_error == ERROR_SERVICE_ALREADY_RUNNING) ? 0 : 6;
}

int uninstallService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) return 2;
  SC_HANDLE service = OpenServiceW(manager, kServiceName, SERVICE_STOP | DELETE | SERVICE_QUERY_STATUS);
  if (!service) {
    const DWORD error = GetLastError();
    CloseServiceHandle(manager);
    return error == ERROR_SERVICE_DOES_NOT_EXIST ? 0 : 3;
  }
  SERVICE_STATUS status{};
  ControlService(service, SERVICE_CONTROL_STOP, &status);
  const BOOL removed = DeleteService(service);
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return removed ? 0 : 4;
}

int clearSafeMode() {
  doorbell::RecoveryPolicy policy = loadPolicy();
  policy.clearSafeMode();
  return savePolicy(policy) ? 0 : 2;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  g_app_path = defaultAppPath();
  if (argc >= 3 && (wcscmp(argv[1], L"--service") == 0 ||
                    wcscmp(argv[1], L"--install") == 0)) {
    g_app_path = argv[2];
  } else if (argc >= 2 && argv[1][0] != L'-') {
    g_app_path = argv[1];
  }

  if (argc >= 2 && wcscmp(argv[1], L"--install") == 0) return installService(g_app_path);
  if (argc >= 2 && wcscmp(argv[1], L"--uninstall") == 0) return uninstallService();
  if (argc >= 2 && wcscmp(argv[1], L"--clear-safe-mode") == 0) return clearSafeMode();
  if (argc >= 2 && wcscmp(argv[1], L"--service") == 0) {
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<wchar_t*>(kServiceName), serviceMain}, {nullptr, nullptr}};
    if (!StartServiceCtrlDispatcherW(table)) return static_cast<int>(GetLastError());
    return 0;
  }

  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  g_session_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!g_stop_event) return 2;
  SetConsoleCtrlHandler(consoleControl, TRUE);
  const int result = runSupervisor(false);
  CloseHandle(g_stop_event);
  g_stop_event = nullptr;
  if (g_session_event) CloseHandle(g_session_event);
  g_session_event = nullptr;
  return result;
}
