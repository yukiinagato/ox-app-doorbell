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

- Win7 機: .NET Framework 4.8 オフラインインストーラ + TLS1.2 有効化パッチが前提
  (provision スクリプトが設定)。v143 成果物が動かない場合のみ v141 ビルドに切替。
- AEC キャリブレーション・カメラ列挙・kiosk (シェル置換) は実機でのみ最終確認できる。
