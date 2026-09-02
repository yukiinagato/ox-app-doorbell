// Doorbell Windows recovery supervisor.
//
// Production mode is a Windows service which launches DoorbellApp in the
// active console session, observes a cross-session heartbeat, and restarts the
// app with bounded backoff. Three failures in five minutes enter sticky safe
// mode. The supervisor never reboots Windows.
#include <windows.h>
#include <sddl.h>
#include <shlobj.h>
#include <userenv.h>
#include <wtsapi32.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

#include "recovery_policy.h"

namespace {

constexpr wchar_t kServiceName[] = L"DoorbellWatchdog";
constexpr wchar_t kHeartbeatName[] = L"Global\\DoorbellAppHeartbeat.v1";
constexpr DWORD kHeartbeatGraceMs = 30'000;
constexpr DWORD kHeartbeatTimeoutMs = 20'000;
constexpr std::uint64_t kHealthyRunMs = 5ULL * 60ULL * 1000ULL;

SERVICE_STATUS_HANDLE g_service_status_handle = nullptr;
SERVICE_STATUS g_service_status{};
HANDLE g_stop_event = nullptr;
std::wstring g_app_path;
std::atomic<DWORD> g_app_pid{0};

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

std::wstring dataDirectory() {
  wchar_t base[MAX_PATH]{};
  if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, 0, base))) return L"";
  const std::wstring directory = std::wstring(base) + L"\\Doorbell";
  CreateDirectoryW(directory.c_str(), nullptr);
  return directory;
}

std::wstring dataPath(const wchar_t* leaf) {
  const std::wstring directory = dataDirectory();
  return directory.empty() ? L"" : directory + L"\\" + leaf;
}

std::wstring statePath() { return dataPath(L"watchdog-state.txt"); }
std::wstring logPath() { return dataPath(L"watchdog.log"); }
std::wstring adminFlagPath() { return dataPath(L"admin_unlocked.flag"); }

bool adminUnlocked() {
  const std::wstring path = adminFlagPath();
  return !path.empty() && GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

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

void logLine(const std::wstring& message) {
  OutputDebugStringW((L"[doorbell-watchdog] " + message + L"\n").c_str());
  const std::wstring path = logPath();
  if (path.empty()) return;
  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  const std::string line = utf8(message + L"\r\n");
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
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
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
    } catch (...) {
      logLine(L"Ignoring malformed recovery-state entry");
    }
  }
  policy.restore(safe_mode, consecutive, failures);
  policy.prune(nowEpochMs());
  return policy;
}

bool savePolicy(const doorbell::RecoveryPolicy& policy) {
  const std::wstring target = statePath();
  if (target.empty()) return false;
  const std::wstring temporary = target + L".tmp";
  std::ostringstream output;
  output << "schema=1\n";
  output << "safe=" << (policy.safeMode() ? 1 : 0) << "\n";
  output << "consecutive=" << policy.consecutiveFailures() << "\n";
  for (const std::uint64_t failure : policy.failureTimes()) {
    output << "failure=" << failure << "\n";
  }
  const std::string body = output.str();
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
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

HANDLE createHeartbeatEvent() {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  // LocalSystem/admins get full access; authenticated interactive users may
  // signal and wait. This allows a non-elevated WPF app to pulse a service event.
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x00100002;;;AU)", SDDL_REVISION_1,
          &descriptor, nullptr)) {
    return nullptr;
  }
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = descriptor;
  HANDLE event = CreateEventW(&attributes, FALSE, FALSE, kHeartbeatName);
  LocalFree(descriptor);
  return event;
}

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
    if (app_pid == 0 || adminUnlocked()) continue;
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

bool launchProcess(bool as_active_user, bool safe_mode, PROCESS_INFORMATION* process) {
  std::wstring command = L"\"" + g_app_path + L"\"";
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

enum class ChildResult { stopped, exited, heartbeat_timeout };

ChildResult superviseChild(PROCESS_INFORMATION* process, HANDLE heartbeat,
                           std::uint64_t* elapsed_ms, DWORD* exit_code) {
  g_app_pid.store(process->dwProcessId);
  AllowSetForegroundWindow(process->dwProcessId);
  const ULONGLONG started = GetTickCount64();
  ULONGLONG last_heartbeat = started;
  HANDLE wait_handles[3] = {g_stop_event, process->hProcess, heartbeat};
  const DWORD handle_count = heartbeat ? 3 : 2;
  ChildResult result = ChildResult::exited;

  for (;;) {
    const DWORD wait = WaitForMultipleObjects(handle_count, wait_handles, FALSE, 1000);
    if (wait == WAIT_OBJECT_0) {
      result = ChildResult::stopped;
      break;
    }
    if (wait == WAIT_OBJECT_0 + 1) {
      result = ChildResult::exited;
      break;
    }
    if (heartbeat && wait == WAIT_OBJECT_0 + 2) {
      last_heartbeat = GetTickCount64();
      continue;
    }
    const ULONGLONG now = GetTickCount64();
    if (heartbeat && now - started >= kHeartbeatGraceMs &&
        now - last_heartbeat >= kHeartbeatTimeoutMs) {
      logLine(L"Application heartbeat timed out; terminating only DoorbellApp");
      TerminateProcess(process->hProcess, ERROR_TIMEOUT);
      WaitForSingleObject(process->hProcess, 5000);
      result = ChildResult::heartbeat_timeout;
      break;
    }
  }

  if (result == ChildResult::stopped &&
      WaitForSingleObject(process->hProcess, 0) == WAIT_TIMEOUT) {
    TerminateProcess(process->hProcess, ERROR_CANCELLED);
    WaitForSingleObject(process->hProcess, 5000);
  }
  GetExitCodeProcess(process->hProcess, exit_code);
  *elapsed_ms = GetTickCount64() - started;
  g_app_pid.store(0);
  CloseHandle(process->hThread);
  CloseHandle(process->hProcess);
  return result;
}

int runSupervisor(bool service_mode) {
  doorbell::RecoveryPolicy policy = loadPolicy();
  HANDLE heartbeat = createHeartbeatEvent();
  if (!heartbeat) logLine(L"Heartbeat event unavailable; exit monitoring remains active");

  HANDLE guard = nullptr;
  if (!service_mode) guard = CreateThread(nullptr, 0, foregroundGuard, nullptr, 0, nullptr);

  while (WaitForSingleObject(g_stop_event, 0) == WAIT_TIMEOUT) {
    if (adminUnlocked()) {
      WaitForSingleObject(g_stop_event, 3000);
      continue;
    }
    PROCESS_INFORMATION process{};
    if (!launchProcess(service_mode, policy.safeMode(), &process)) {
      const DWORD error = GetLastError();
      logLine(L"DoorbellApp launch failed, error=" + std::to_wstring(error));
      if (service_mode && (error == ERROR_NO_TOKEN || error == ERROR_NO_SUCH_LOGON_SESSION ||
                           error == ERROR_PIPE_NOT_CONNECTED)) {
        // Boot-time absence of an interactive user is not an application crash.
        if (WaitForSingleObject(g_stop_event, 5000) != WAIT_TIMEOUT) break;
        continue;
      }
      const unsigned delay = policy.recordFailure(nowEpochMs());
      savePolicy(policy);
      if (WaitForSingleObject(g_stop_event, delay * 1000) != WAIT_TIMEOUT) break;
      continue;
    }

    logLine(L"DoorbellApp launched pid=" + std::to_wstring(process.dwProcessId) +
            (policy.safeMode() ? L" (safe mode)" : L""));
    std::uint64_t elapsed = 0;
    DWORD exit_code = 0;
    const ChildResult result = superviseChild(&process, heartbeat, &elapsed, &exit_code);
    if (result == ChildResult::stopped) break;

    if (elapsed >= kHealthyRunMs) policy.recordHealthy();
    const unsigned delay = policy.recordFailure(nowEpochMs());
    savePolicy(policy);
    logLine(L"DoorbellApp failure exit=" + std::to_wstring(exit_code) +
            L", retry in " + std::to_wstring(delay) + L" seconds" +
            (policy.safeMode() ? L" (safe mode active)" : L""));
    if (WaitForSingleObject(g_stop_event, delay * 1000) != WAIT_TIMEOUT) break;
  }

  if (guard) {
    WaitForSingleObject(guard, 5000);
    CloseHandle(guard);
  }
  if (heartbeat) CloseHandle(heartbeat);
  return 0;
}

void setServiceStatus(DWORD state, DWORD error = NO_ERROR, DWORD hint = 0) {
  g_service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_service_status.dwCurrentState = state;
  g_service_status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP : 0;
  g_service_status.dwWin32ExitCode = error;
  g_service_status.dwWaitHint = hint;
  SetServiceStatus(g_service_status_handle, &g_service_status);
}

DWORD WINAPI serviceControl(DWORD control, DWORD, LPVOID, LPVOID) {
  if (control == SERVICE_CONTROL_STOP && g_stop_event) {
    setServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 10'000);
    SetEvent(g_stop_event);
  }
  return NO_ERROR;
}

void WINAPI serviceMain(DWORD argc, wchar_t** argv) {
  (void)argc;
  (void)argv;
  g_service_status_handle = RegisterServiceCtrlHandlerExW(kServiceName, serviceControl, nullptr);
  if (!g_service_status_handle) return;
  setServiceStatus(SERVICE_START_PENDING, NO_ERROR, 10'000);
  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!g_stop_event) {
    setServiceStatus(SERVICE_STOPPED, GetLastError());
    return;
  }
  setServiceStatus(SERVICE_RUNNING);
  const int result = runSupervisor(true);
  CloseHandle(g_stop_event);
  g_stop_event = nullptr;
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
      L"Restarts DoorbellApp with heartbeat monitoring, bounded backoff and safe mode.");
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
  if (!g_stop_event) return 2;
  SetConsoleCtrlHandler(consoleControl, TRUE);
  const int result = runSupervisor(false);
  CloseHandle(g_stop_event);
  g_stop_event = nullptr;
  return result;
}
