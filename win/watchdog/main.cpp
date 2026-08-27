// doorbell-watchdog: 主アプリの死活監視 + 前台守衛 (依存ゼロの Win32 単体 exe)。
//  - DoorbellApp.exe を起動し、終了したら再起動する
//  - 60 秒以内に 3 回死んだら OS を再起動 (アプリでなく環境の問題とみなす)
//  - 【前台守衛】3 秒毎に前面ウィンドウを検査し、アプリ以外 (Windows Update の再起動促し、
//    ドライバのポップアップ等) が前面を奪っていたらアプリを最前面へ引き戻す。
//    %ProgramData%\Doorbell\admin_unlocked.flag が存在する間は守衛を停止
//    (管理者が PIN で解錠して保守中 — MainWindow が書き、App 起動時に削除される)。
//    watchdog は子 (DoorbellApp) の親プロセスなので SetForegroundWindow が許可される —
//    失敗した時は SwitchToThisWindow (undocumented だが Win7+ で安定) へフォールバック。
//  - TODO: 名前付きパイプ心跳で「生きてるが固まった」も検出
// 使い方: doorbell-watchdog.exe [アプリのフルパス]   (省略時: 自分と同じフォルダの DoorbellApp.exe)
#include <windows.h>
#include <shlobj.h>

#include <cstdio>
#include <string>

// SwitchToThisWindow (user32) — 前台強奪の最終手段 (ヘッダ宣言なし)
extern "C" WINUSERAPI void WINAPI SwitchToThisWindow(HWND hwnd, BOOL fAltTab);

static DWORD g_app_pid = 0;  // 現在の子プロセス (守衛スレッドが参照; 再起動毎に更新)

static void enableShutdownPrivilege() {
  HANDLE token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
    return;
  TOKEN_PRIVILEGES tp{};
  LookupPrivilegeValueW(nullptr, SE_SHUTDOWN_NAME, &tp.Privileges[0].Luid);
  tp.PrivilegeCount = 1;
  tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
  AdjustTokenPrivileges(token, FALSE, &tp, sizeof(tp), nullptr, nullptr);
  CloseHandle(token);
}

// %ProgramData%\Doorbell\admin_unlocked.flag — 存在中は前台守衛を止める
static std::wstring adminFlagPath() {
  wchar_t base[MAX_PATH];
  if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, 0, base))) return L"";
  return std::wstring(base) + L"\\Doorbell\\admin_unlocked.flag";
}

static bool adminUnlocked() {
  static std::wstring path = adminFlagPath();
  return !path.empty() && GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// 対象 pid のトップレベル可視ウィンドウを探す (owner 無し = メインウィンドウ)
struct FindWin {
  DWORD pid;
  HWND hwnd;
};
static BOOL CALLBACK enumProc(HWND h, LPARAM lp) {
  auto* f = reinterpret_cast<FindWin*>(lp);
  DWORD pid = 0;
  GetWindowThreadProcessId(h, &pid);
  if (pid != f->pid || !IsWindowVisible(h) || GetWindow(h, GW_OWNER) != nullptr) return TRUE;
  f->hwnd = h;
  return FALSE;  // 発見 — 列挙終了
}
static HWND findAppWindow(DWORD pid) {
  FindWin f{pid, nullptr};
  EnumWindows(&enumProc, reinterpret_cast<LPARAM>(&f));
  return f.hwnd;
}

// 前台守衛スレッド: 3 秒毎に前面ウィンドウの所有プロセスを検査し、
// アプリ以外が前面なら引き戻す (Windows Update の再起動促し・ドライバ弾窗対策)
static DWORD WINAPI guardThread(LPVOID) {
  for (;;) {
    Sleep(3000);
    DWORD app = g_app_pid;
    if (app == 0 || adminUnlocked()) continue;  // 未起動 or 保守中は何もしない
    HWND fg = GetForegroundWindow();
    DWORD fg_pid = 0;
    if (fg) GetWindowThreadProcessId(fg, &fg_pid);
    if (fg_pid == app) continue;  // アプリが前面 — 正常
    HWND w = findAppWindow(app);
    if (!w) continue;  // ウィンドウ未生成 (起動中)
    // 最前面へ引き戻す。watchdog は子の親なので SetForegroundWindow が許可されるが、
    // フォアグラウンドロック中は失敗する — その時は SwitchToThisWindow で強奪する。
    if (IsIconic(w)) ShowWindow(w, SW_RESTORE);
    SetWindowPos(w, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    if (!SetForegroundWindow(w)) SwitchToThisWindow(w, TRUE);
    wprintf(L"[watchdog] 前面を奪ったプロセス pid=%lu からアプリへ引き戻した\n",
            static_cast<unsigned long>(fg_pid));
  }
  return 0;
}

int wmain(int argc, wchar_t** argv) {
  // アプリのパス: 引数 or 自分と同じフォルダの DoorbellApp.exe
  wchar_t self[MAX_PATH];
  GetModuleFileNameW(nullptr, self, MAX_PATH);
  std::wstring app;
  if (argc >= 2) {
    app = argv[1];
  } else {
    app = self;
    size_t sl = app.find_last_of(L'\\');
    app = app.substr(0, sl + 1) + L"DoorbellApp.exe";
  }
  enableShutdownPrivilege();
  CreateThread(nullptr, 0, &guardThread, nullptr, 0, nullptr);

  // 60 秒以内に 3 回死んだら OS 再起動 (crash 時刻のリングバッファ)
  ULONGLONG crash[3] = {0, 0, 0};
  int ci = 0;

  for (;;) {
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    std::wstring cmd = L"\"" + app + L"\"";
    if (!CreateProcessW(app.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr,
                        &si, &pi)) {
      wprintf(L"[watchdog] 起動失敗 (%lu): %s — 10 秒後に再試行\n", GetLastError(), app.c_str());
      Sleep(10'000);
      continue;
    }
    g_app_pid = pi.dwProcessId;
    // 子が SetForegroundWindow を自分で使えるように許可 (起動直後の全画面化用)
    AllowSetForegroundWindow(pi.dwProcessId);
    wprintf(L"[watchdog] 起動 pid=%lu\n", static_cast<unsigned long>(pi.dwProcessId));
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    g_app_pid = 0;
    wprintf(L"[watchdog] 終了 code=%lu\n", static_cast<unsigned long>(code));

    // 保守解錠中の手動終了は再起動もカウントもしない (flag が消えたら次周期で復帰)
    while (adminUnlocked()) Sleep(3000);

    ULONGLONG now = GetTickCount64();
    ULONGLONG oldest = crash[ci];
    crash[ci] = now;
    ci = (ci + 1) % 3;
    if (oldest != 0 && now - oldest < 60'000) {
      wprintf(L"[watchdog] 60 秒以内に 3 回死んだ — OS を再起動する\n");
      ExitWindowsEx(EWX_REBOOT | EWX_FORCE,
                    SHTDN_REASON_MAJOR_APPLICATION | SHTDN_REASON_MINOR_HUNG);
      Sleep(60'000);  // 再起動待ち
    }
    Sleep(2000);  // 即時クラッシュループの緩和
  }
}
