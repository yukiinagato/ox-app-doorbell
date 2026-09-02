

#pragma once

#include <cstddef>

namespace db {

struct WebAsset {
  const char* path;
  const char* content_type;
  const unsigned char* data;
  size_t len;
};


const WebAsset* webuiAssets(size_t* count);

}  // namespace db
