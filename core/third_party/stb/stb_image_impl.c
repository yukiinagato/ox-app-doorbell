// armv7/iOS 5 has no thread-local storage; stb uses it only for per-thread flags.
#define STBI_NO_THREAD_LOCALS
/* Single translation unit for stb_image (public domain / MIT). Core decodes a theme background
   once per change to average its colour; nothing else in the build needs an image decoder.
   Decoding is memory-only: core already reads the asset file itself, and keeping stb away from
   stdio avoids a second path-handling surface on Windows. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
/* Only the formats an administrator can upload as a theme background. */
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#include "stb_image.h"
