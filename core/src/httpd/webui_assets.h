// 埋め込み Web 資産 (webui/ から tools/embed_webui.py がビルド時に生成)。
// 実体はビルドディレクトリの gen/webui_assets.cpp。
#pragma once

#include <cstddef>

namespace db {

struct WebAsset {
  const char* path;          // 例 "/admin/", "/locale/ja.json"
  const char* content_type;  // 例 "text/html; charset=utf-8"
  const unsigned char* data;
  size_t len;
};

// 資産表 (終端なし; *count に件数)。
const WebAsset* webuiAssets(size_t* count);

}  // namespace db
