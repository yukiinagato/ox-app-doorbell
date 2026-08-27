// doorbell-watchdog: 主アプリの死活監視 (依存ゼロの Win32 単体 exe)。
//  - DoorbellApp.exe を起動し、終了したら再起動する
//  - 60 秒以内に 3 回死んだら OS を再起動 (アプリでなく環境の問題とみなす)
//  - TODO(Phase1後半): 名前付きパイプ心跳で「生きてるが固まった」も検出
// 使い方: doorbell-watchdog.exe [アプリのフルパス]   (省略時: 自分と同じフォルダの DoorbellApp.exe)
#include <windows.h>

#include <cstdio>
#include <string>

static void enableShutdownPrivilege() {
  HANDLE token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
    return;
  TOKEN_PRIVILEGES tp{};
  LookupPrivilegeValueW(nullptr, SE_SHUTDOWN_NAME, &tp.Privileges[0].Luid);
  tp.PrivilegeCount = 1;
  tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
  AdjustTokenPrivileges(token, FALSE, &tp, 0, nullptr, nullptr);
  CloseHandle(token);
}

int wmain(int argc, wchar_t** argv) {
  wchar_t self[MAX_PATH];
  GetModuleFileNameW(nullptr, self, MAX_PATH);
  std::wstring app;
  if (argc >= 2) {
    app = argv[1];
  } else {
    app = self;
    size_t p = app.find_last_of(L'\\');
    app = app.substr(0, p + 1) + L"DoorbellApp.exe";
  }

  int fails = 0;
  ULONGLONG window_start = GetTickCount64();

  for (;;) {
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    std::wstring cmdline = L"\"" + app + L"\"";
    if (!CreateProcessW(app.c_str(), &cmdline[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr,
                        &si, &pi)) {
      fwprintf(stderr, L"CreateProcess 失敗 (%lu): %s\n", GetLastError(), app.c_str());
      Sleep(5000);
      continue;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    ULONGLONG now = GetTickCount64();
    if (now - window_start > 60'000) {  // 窓リセット
      window_start = now;
      fails = 0;
    }
    fails++;
    fwprintf(stderr, L"app 終了 (code=%lu, fails=%d)\n", code, fails);
    if (fails >= 3) {
      fwprintf(stderr, L"連続失敗 → OS 再起動\n");
      enableShutdownPrivilege();
      ExitWindowsEx(EWX_REBOOT | EWX_FORCE, SHTDN_REASON_MAJOR_APPLICATION);
      Sleep(30'000);
    }
    Sleep(2000);
  }
}
