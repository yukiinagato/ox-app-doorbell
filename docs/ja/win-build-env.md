# Windows ビルド環境 (Apple Silicon Mac + ローカル VM)

これは環境構築案であり、現 revision の Windows VM/Toughpad 検証完了証跡ではありません。
VM、toolchain、artifact、結果を記録してから build verified とし、実機 commissioning は別に行います。

方針: 開発の反復はローカル VM、(任意で) リリース成果物は GitHub Actions。
Docker は不可 — macOS の Docker は Linux コンテナのみで、WPF/.NET Framework の
ビルドチェーンは Windows にしか存在しない。

## 1. VM を用意する (Windows 11 ARM64)

| ソフト | 費用 | 備考 |
|---|---|---|
| UTM | 無料 | ARM64 Win11 の ISO/VHDX を取り込み。手軽 |
| VMware Fusion | 個人利用無料 | 安定。共有フォルダあり |
| Parallels | 有料 | 体験最良。Microsoft 公認の Win11 ARM 提供フロー |

- Windows 11 ARM64 を導入 (Microsoft 公式の Insider/ISO 経由、または Parallels の自動取得)。
- ARM64 Windows は多くの x86/x64 tool をエミュレーションできますが、この VM 経路の完了済み
  検証記録は repository にありません。候補 build 環境として扱います。

## 2. VM に入れるもの

1. **Visual Studio 2022 Community** — ワークロード:
   - 「.NET デスクトップ開発」(WPF / .NET Framework 4.8 SDK+targeting pack)
   - 「C++ によるデスクトップ開発」(MSVC v143, CMake, Windows 10 SDK)
   - 個別コンポーネント: 「MSVC v141 - VS2017 C++ x64/x86 ビルドツール」
     (Win7 実機向けの保険。ARM64 上ではエミュレーション実行で遅いが可)
2. **Git**、(任意) **Claude Code** — VM 内でも作業を引き継げるように。
3. **Inno Setup 6** (インストーラ作成、Phase 1 後半)。

## 3. リポジトリ共有

- 推奨: VM の共有フォルダで Mac 側の `~/Documents/project/app-doorbell` をマウント
  (VMware/Parallels)。または git で同期 (コミット単位のやり取り)。
- ビルドは VM 内ローカルディスクの build ディレクトリで行う (共有 FS 上の
  ビルドは遅い): `win/build.cmd` がそのように配置する。

## 4. ビルド (VM 内)

```bat
win\build.cmd            :: core DLL (x86+x64, MSVC) + WPF app + テスト実行
```

エラーと正確な toolchain version を release record に保存します。

## 5. Mac 側での事前検証 (mingw-w64)

Mac 上で `brew install mingw-w64` 後:

```bash
cmake -S core -B build-win64 -DCMAKE_TOOLCHAIN_FILE=core/cmake/mingw-w64.cmake && cmake --build build-win64 -j8
```

これで Winsock/API 移植ミスの大半を VM に行く前に潰せる (最終確認は MSVC/実機)。

## 6. Toughpad 実機検証 (最終)

- 対応下限は Windows 7 SP1。Windows XP は対象外（.NET Framework 4.8、インストーラの
  MinVersion 6.1sp1、watchdog の Vista 以降 API のため）。
- Win7 機: .NET Framework 4.8 オフラインインストーラと KB3140245（WinHTTP の TLS 1.2）が前提。
  セットアップは .NET 4.8 がなければ中止し、KB3140245 がなければ警告する。未導入の間は HTTPS
  連携が失敗し、理由は `logs\doorbell.log` に出る。v143 成果物が動かない場合のみ v141 ビルドに切替。
- AEC キャリブレーション・カメラ列挙・kiosk (シェル置換) は実機でのみ最終確認できる。

## 7. 2026-11 レビュー修正の確認

修正時点では Windows 上で一度も実行していない。Windows レーンを検証済みとする前に VM で実行すること。

```bat
:: Contract tests and the watchdog policy
python win\tests\test_windows_contracts.py
cmake -S win\watchdog -B build-watchdog -A x64 -DBUILD_TESTING=ON
cmake --build build-watchdog --config Release -j
ctest --test-dir build-watchdog -C Release --output-on-failure

:: Full bundle; a release additionally needs DB_SIGN_CERT_SHA1 and DB_UPDATE_PUBLISHER (the CN)
set DB_ALLOW_SIP_STUB=1
win\build.cmd
```

インストール済み端末で（1〜3 は管理者プロンプト）:

1. `icacls "%ProgramData%\Doorbell"` で Users が `(RX)` のみ、`...\service` に Users の書込みがなく、
   `...\data` は Users `(M)`、`...\data\secure` に `Doorbell Operators` があること。
2. 標準ユーザーで `%ProgramData%\Doorbell\service` にファイルを作れないこと。
3. `sc qc DoorbellWatchdog` でアプリが起動し、`watchdog.log` が `...\service` にあること。
4. `DoorbellApp.exe` を 5 分以内に 3 回強制終了するとセーフモードになり、クラスタ離脱（初期化）を 3 回してもならないこと。
5. 別アカウントへのユーザー切替で、アプリが新しいコンソールセッションへ移ること。
6. UI スレッドを止める（ディスパッチャーでデバッガ停止）と約 20 秒で watchdog が再起動すること。
7. 2 つ目の `DoorbellApp.exe` は終了コード 5 で終わり、1 つ目が動き続けること。
8. 門口機カメラを抜き差ししても、アプリ再起動なしで映像が戻ること。
9. 着信画面の開閉を繰り返しても `netstat -ano` にループバックのメディア接続が残らないこと。
10. 未署名または別署名のインストーラによるアプリ内更新が `web_admin.update_untrusted` で拒否されること。
