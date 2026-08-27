#!/usr/bin/env python3
"""webui/ の静的資産 + i18n locale (strings.yaml から直接生成) を C++ ソースへ埋め込む。

使い方: embed_webui.py <出力.cpp>
マッピング:
    webui/admin/index.html  → /admin/
    webui/admin/<f>         → /admin/<f>
    webui/panel/<name>.html → /panel/<name>
    webui/panel/<f>         → /panel/<f>   (css/js 等)
    (strings.yaml)          → /locale/{ja,en,zh}.json
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_i18n  # noqa: E402  (依存なしの自前パーサを再利用)

ROOT = gen_i18n.ROOT
CTYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".wav": "audio/wav",
    ".ico": "image/x-icon",
}


def collect():
    assets = []  # (url_path, content_type, bytes)
    for sub in ("admin", "panel"):
        base = os.path.join(ROOT, "webui", sub)
        if not os.path.isdir(base):
            continue
        for fn in sorted(os.listdir(base)):
            full = os.path.join(base, fn)
            if not os.path.isfile(full):
                continue
            ext = os.path.splitext(fn)[1].lower()
            ctype = CTYPES.get(ext, "application/octet-stream")
            with open(full, "rb") as f:
                data = f.read()
            if sub == "admin" and fn == "index.html":
                url = "/admin/"
            elif sub == "panel" and ext == ".html":
                url = "/panel/" + os.path.splitext(fn)[0]
            else:
                url = f"/{sub}/{fn}"
            assets.append((url, ctype, data))
    # locale は strings.yaml から直接 (ソースツリーの生成物に依存しない)
    entries = gen_i18n.parse(gen_i18n.SRC)
    for lang in gen_i18n.LANGS:
        data = {k: gen_i18n.text(entries, k, lang) for k in sorted(entries)}
        blob = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        assets.append((f"/locale/{lang}.json", CTYPES[".json"], blob))
    return assets


def emit(assets, out_path):
    lines = [
        "// tools/embed_webui.py が生成 — 編集禁止",
        '#include "httpd/webui_assets.h"',
        "namespace db {",
    ]
    for i, (_, _, data) in enumerate(assets):
        body = ",".join(str(b) for b in data)
        lines.append(f"static const unsigned char a{i}[] = {{{body}}};")
    lines.append("static const WebAsset kAssets[] = {")
    for i, (url, ctype, data) in enumerate(assets):
        lines.append(f'  {{"{url}", "{ctype}", a{i}, {len(data)}}},')
    lines.append("};")
    lines.append("const WebAsset* webuiAssets(size_t* count) {")
    lines.append(f"  *count = {len(assets)};")
    lines.append("  return kAssets;")
    lines.append("}")
    lines.append("}  // namespace db")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    total = sum(len(d) for _, _, d in assets)
    print(f"embed_webui: {len(assets)} assets, {total} bytes -> {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: embed_webui.py <out.cpp>")
    emit(collect(), sys.argv[1])
