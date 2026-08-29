#!/bin/bash
# mount_ddi.sh - one-shot: mount the 5.1 Developer Disk Image on the iPad1
# (iOS 5.1.1 / 9B206) and optionally take a screenshot.
#
# Background (2026-08-30):
#   * Apple never shipped a dedicated 5.1.1 (9B206) DDI; Xcode 4.6.3 serves
#     5.1.1 devices with the plain "5.1" (9B176) image. Signature/build
#     mismatch was NEVER the problem.
#   * Modern ideviceimagemounter (1.4.x) and `pymobiledevice3 mounter
#     mount-developer` both choke on iOS 5 -> use pymobiledevice3 only for
#     `afc push`, and the hand-rolled mount_ddi.py for the MountImage step.
#   * The mount lives in RAM: it is GONE after a device reboot -> just rerun
#     this script (needs USB, takes ~10s).
#
# Usage:
#   bash ios-legacy/scripts/mount_ddi.sh              # mount only
#   bash ios-legacy/scripts/mount_ddi.sh shot.png     # mount + screenshot
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="$HOME/.cache/legacy-ddi/5.1"
DMG="$CACHE/DeveloperDiskImage.dmg"
SIG="$CACHE/DeveloperDiskImage.dmg.signature"
XCODE_DMG="${XCODE_463_DMG:-$HOME/Downloads/Xcode_4.6.3.dmg}"
MOUNT_PT="/private/tmp/xcode463"
VENV="$HOME/.venvs/pmd3"
SRC_DIR="$MOUNT_PT/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/5.1"

if [[ ! -f "$DMG" ]]; then
  if [[ ! -f "$SRC_DIR/DeveloperDiskImage.dmg" ]]; then
    echo "[*] attaching $XCODE_DMG -> $MOUNT_PT"
    mkdir -p "$MOUNT_PT"
    if ! echo Y | hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_PT" "$XCODE_DMG" >/dev/null 2>&1; then
      hdiutil detach "$MOUNT_PT" >/dev/null 2>&1 || true
      echo Y | hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_PT" "$XCODE_DMG" >/dev/null
    fi
  fi
  mkdir -p "$CACHE"
  cp "$SRC_DIR/DeveloperDiskImage.dmg" "$DMG"
  cp "$SRC_DIR/DeveloperDiskImage.dmg.signature" "$SIG"
  echo "[*] DDI cached at $DMG ($(du -h "$DMG" | cut -f1))"
fi

if [[ ! -x "$VENV/bin/pymobiledevice3" ]]; then
  echo "[*] bootstrapping pymobiledevice3 venv -> $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check pymobiledevice3
fi
PMD3="$VENV/bin/pymobiledevice3"

echo "[*] uploading staging.dimage via AFC"
"$PMD3" afc push "$DMG" /PublicStaging/staging.dimage 2>&1 | tail -1

echo "[*] issuing MountImage"
if ! python3 -W ignore::DeprecationWarning "$SCRIPT_DIR/mount_ddi.py" "$DMG" "$SIG"; then
  # 'ImageMountFailed' also means "already mounted" -> probe screenshotr
  echo "[!] MountImage errored; probing screenshotr (may be already mounted)"
  PROBE="$(mktemp -t ddi-probe).tiff"
  if idevicescreenshot "$PROBE" >/dev/null 2>&1; then
    rm -f "$PROBE"
    echo "[*] screenshotr works -> image is mounted (nothing to do)"
  else
    echo "[!] screenshotr unavailable -> DDI NOT mounted, MountImage failed"
    exit 1
  fi
fi

if [[ $# -ge 1 ]]; then
  OUT="$1"
  TMP_TIFF="$(mktemp -t legacy-shot).tiff"
  idevicescreenshot "$TMP_TIFF" >/dev/null
  sips -s format png "$TMP_TIFF" --out "$OUT" >/dev/null
  rm -f "$TMP_TIFF"
  echo "[*] screenshot -> $OUT"
fi
echo "[*] done"
