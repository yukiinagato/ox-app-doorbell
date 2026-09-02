#!/usr/bin/env bash
# Doorbell.app (armv7/iOS5.1) を .deb に梱包する。
# 手動 scp→/Applications だと SpringBoard/LaunchServices が図标を収录しない事があるため、
# dpkg 正規経路で入れる。postinst が uicache で図标登録する。
#
#   bash ios-legacy/scripts/build_deb.sh
#   => ios-legacy/build/doorbell.deb
#
# 前提: 先に build_app.sh 済み (ios-legacy/build/Doorbell.app が存在)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$LEGACY/build/Doorbell.app"
OUT="$LEGACY/build/doorbell.deb"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo 0.1.0)"

[ -d "$APP" ] || { echo "error: $APP が無い。先に build_app.sh を実行"; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/pkg/DEBIAN" "$STAGE/pkg/Applications"
cp -R "$APP" "$STAGE/pkg/Applications/"
find "$STAGE/pkg" \( -name '.DS_Store' -o -name '._*' \) -delete 2>/dev/null || true

cat > "$STAGE/pkg/DEBIAN/control" <<EOF
Package: jp.ox.doorbell
Name: ドアホン
Version: $VERSION
Architecture: iphoneos-arm
Description: Doorbell mesh intercom node (armv7/iOS5.1, full C++17 core + mini-SIP)
Maintainer: ox
Author: ox
Section: Utilities
Depends: firmware (>= 5.0)
EOF

cat > "$STAGE/pkg/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
chown -R root:wheel /Applications/Doorbell.app 2>/dev/null || true
chmod -R 0755 /Applications/Doorbell.app 2>/dev/null || true
if command -v uicache >/dev/null 2>&1; then
  uicache -p /Applications/Doorbell.app 2>/dev/null || uicache 2>/dev/null || true
fi
exit 0
EOF

cat > "$STAGE/pkg/DEBIAN/prerm" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$STAGE/pkg/DEBIAN/postinst" "$STAGE/pkg/DEBIAN/prerm"

# --- tar + ar を全て Python で生成 ---
# macOS の tar は LIBARCHIVE.xattr.com.apple.provenance 等の pax 拡張ヘッダを混ぜ、
# iOS 側の古い tar が「corrupted tarfile」と誤判定する。tarfile なら xattr を持たない。
# macOS の ar は __.SYMDEF を混ぜて .deb を壊すので ar も手組み。
printf '2.0\n' > "$STAGE/debian-binary"
python3 - "$STAGE" "$OUT" <<'PY'
import sys, os, tarfile, io
work, out = sys.argv[1], sys.argv[2]
pkg = os.path.join(work, "pkg")

def norm(ti):
    # 所有者を root:wheel に正規化 (postinst でも chown するが tar 段でも揃える)
    ti.uid = 0; ti.gid = 0; ti.uname = "root"; ti.gname = "wheel"
    ti.mtime = 0
    return ti

def make_tar(path, root, arcprefix, names=None):
    # GNU 形式・pax 無しで tar.gz を作る
    with tarfile.open(path, "w:gz", format=tarfile.GNU_FORMAT) as tf:
        if names is None:  # ディレクトリツリーを歩く
            entries = []
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames.sort(); filenames.sort()
                for d in dirnames:
                    entries.append(os.path.join(dirpath, d))
                for f in filenames:
                    entries.append(os.path.join(dirpath, f))
            for full in entries:
                rel = os.path.relpath(full, root)
                tf.add(full, arcname=arcprefix + rel, recursive=False, filter=norm)
        else:              # 指定ファイルのみ (DEBIAN control 群)
            for n in names:
                tf.add(os.path.join(root, n), arcname=arcprefix + n, recursive=False, filter=norm)

# control.tar.gz : DEBIAN/ の中身をルート直下に
make_tar(os.path.join(work, "control.tar.gz"),
         os.path.join(pkg, "DEBIAN"), "./", names=["control", "postinst", "prerm"])
# data.tar.gz : Applications/ ツリー (DEBIAN を除外)
def make_data(path):
    with tarfile.open(path, "w:gz", format=tarfile.GNU_FORMAT) as tf:
        base = pkg
        for dirpath, dirnames, filenames in os.walk(base):
            if "DEBIAN" in dirnames: dirnames.remove("DEBIAN")
            dirnames.sort(); filenames.sort()
            for d in dirnames:
                full = os.path.join(dirpath, d)
                tf.add(full, arcname="./" + os.path.relpath(full, base), recursive=False, filter=norm)
            for f in filenames:
                full = os.path.join(dirpath, f)
                tf.add(full, arcname="./" + os.path.relpath(full, base), recursive=False, filter=norm)
make_data(os.path.join(work, "data.tar.gz"))

def hdr(name, size):
    h = name.ljust(16) + "0".ljust(12) + "0".ljust(6) + "0".ljust(6) + "100644".ljust(8) + str(size).ljust(10) + "`\n"
    assert len(h) == 60
    return h.encode()
blob = bytearray(b"!<arch>\n")
for m in ("debian-binary", "control.tar.gz", "data.tar.gz"):
    data = open(os.path.join(work, m), "rb").read()
    blob += hdr(m, len(data)) + data
    if len(data) % 2: blob += b"\n"
open(out, "wb").write(blob)
print("wrote", out, len(blob), "bytes")
PY

echo "ok: $OUT (version $VERSION)"
echo "検証: ar -t \"$OUT\""
ar -t "$OUT"
