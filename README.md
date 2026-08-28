# ox-app-doorbell

**日本語** | [English](#english) | [中文](#中文)

自宅 (複数棟・複数玄関) 向けのサーバレス自愈ドアホンシステム。旧型の Windows タブレット
(Toughpad)・Android・iOS 端末を玄関子機/室内機として再利用する。P2P メッシュが真実源で、
Home Assistant / Asterisk が落ちても呼出・対講・通知は動き続ける。

- 📖 ドキュメント: [docs/ja/overview.md](docs/ja/overview.md) (全体像) ·
  [docs/ja/deployment.md](docs/ja/deployment.md) (導入手順) ·
  [docs/ja/config-schema.md](docs/ja/config-schema.md) (設定リファレンス)
- 🔧 ビルド: `cmake -S core -B build && cmake --build build && ./build/doorbell_tests`
  — 各平台アプリは GitHub Actions が自動ビルド (Artifacts から取得可)
- 🗣 文書は日本語 (`docs/ja/`, `*.ja.md`) が正、英語 (`docs/en/`) と中文 (`docs/zh/`) は同期訳。
  コード内コメントは日本語で統一。アプリ UI は日/英/中対応 (`i18n/strings.yaml`)。

---

## English

A serverless, self-healing intercom/doorbell system for a multi-building home, built to
reuse old low-spec Windows tablets (Toughpad), Android and iOS devices as door stations
and indoor monitors. A P2P mesh is the source of truth — calls, intercom and
notifications keep working even if Home Assistant or Asterisk goes down.

- 📖 Docs: [docs/en/overview.md](docs/en/overview.md) (architecture) ·
  [docs/en/deployment.md](docs/en/deployment.md) (rollout guide) ·
  [docs/en/config-schema.md](docs/en/config-schema.md) (config reference)
- 🔧 Build: `cmake -S core -B build && cmake --build build && ./build/doorbell_tests`
  — platform apps are built by GitHub Actions (grab them from Artifacts)
- 🗣 Japanese docs (`docs/ja/`, `*.ja.md`) are canonical; English (`docs/en/`) and
  Chinese (`docs/zh/`) are kept in sync. Code comments are Japanese by convention.
  The app UI itself is trilingual (`i18n/strings.yaml`).

---

## 中文

面向多栋建筑住宅的无服务器自愈门铃/对讲系统，把旧的低配 Windows 平板（Toughpad）、
Android、iOS 设备改造成门口机与室内机。P2P 网格是唯一真实源——即使 Home Assistant
或 Asterisk 宕机，呼叫、对讲和通知照常工作。

- 📖 文档：[docs/zh/overview.md](docs/zh/overview.md)（系统全景）·
  [docs/zh/deployment.md](docs/zh/deployment.md)（部署清单）·
  [docs/zh/config-schema.md](docs/zh/config-schema.md)（配置参考）
- 🔧 构建：`cmake -S core -B build && cmake --build build && ./build/doorbell_tests`
  ——各平台 app 由 GitHub Actions 自动构建（从 Artifacts 下载）
- 🗣 文档以日文（`docs/ja/`、`*.ja.md`）为正本，英文（`docs/en/`）与中文（`docs/zh/`）
  为同步译本。代码注释统一日文。应用 UI 本身支持日/英/中（`i18n/strings.yaml`）。
