# Vendored third-party (pinned)

| lib | version | source | license | files |
|---|---|---|---|---|
| sqlite | 3.53.4 (amalgamation 3530400) | sqlite.org/2026/sqlite-amalgamation-3530400.zip | Public Domain | sqlite/ |
| civetweb | v1.16 | github.com/civetweb/civetweb | MIT | civetweb/ (src + inl + header) |
| monocypher | 4.0.2 | github.com/LoupVaillant/Monocypher | CC0/BSD-2 | monocypher/ (+ed25519 optional) |
| cJSON | v1.7.18 | github.com/DaveGamble/cJSON | MIT | cjson/ |
| doctest | v2.4.11 | github.com/doctest/doctest | MIT | doctest/doctest.h (tests only) |
| stb | image_write 1.16 / image 2.30 (master 取得 2026-08-28) | github.com/nothings/stb | Public Domain / MIT | stb/ (stb_image_write.h; stb_image.h はテスト検証のみ) |
| pjsip | (Phase 1) 2.15.1 予定 | github.com/pjsip/pjproject | GPLv2+ | — |
| libjpeg-turbo | (Phase 1) | github.com/libjpeg-turbo | BSD | — |

更新手順: 同一固定版を再取得し差分レビューの上で置換。改変禁止（パッチが要る場合は `patches/` に分離）。
