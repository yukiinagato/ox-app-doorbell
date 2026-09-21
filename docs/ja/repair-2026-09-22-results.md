# 修正実行レポート — 2026-09-22

基準 SHA は `0fbeed4720efb25dafb79083f86d4c21c39f5087` です。作業開始時の未コミット変更はなく、最終状態も未コミットです。影響する配布物は Android `0.3.16` / build `17`、modern iOS `0.1.32` / `33`、iOS kiosk `0.3.44` / `47`、Windows `0.1.11` / `0.1.11.8` に更新しました。

R1–R6 は実装済みです。R1 は認証状態を単一 Runloop に直列化、R2 は排出待ち可能な C callback slot、R3 は欠落後に実 IDR だけで復帰、R4 は一回だけ完了するログイン要求、R5 は generation 付き単一 polling runtime、R6 は所有権を持つ QR scan session を実装しています。正式な回帰テストは `core/tests/test_capi_abi.cpp`、`core/tests/test_fmp4_demux.cpp`、`webui/tests/admin_runtime.test.js` にあります。

実行済み結果：Core build、R1–R3 の 26 assertion、関連 HTTP/C ABI/fMP4 の 1,776 assertion、全 WebUI tests、i18n/English/diff checks、`ios-compat/scripts/test_host.sh` はすべて PASS です。ログは無視対象の `build/repair-host/repair-*.log` にあります。

未検証：集約 `ctest`、native/Web 同時移行、実ソフトウェア decode、TSan、ASan/UBSan、modern iOS、Windows、実ブラウザーおよび実機。Android modern/legacy19 は Java Runtime 不在のため BLOCKED です。iPad mini 1（iOS 9.3.6 / armv7）は未検証です。公開、デプロイ、push、PR、実機操作は行っていません。
