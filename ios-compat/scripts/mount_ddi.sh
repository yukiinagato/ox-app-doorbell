#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DDI_CACHE="${IOS5_DDI_CACHE:-$HOME/.cache/ios-compat-ddi/5.1}"
DDI_IMAGE="$DDI_CACHE/DeveloperDiskImage.dmg"
DDI_SIGNATURE="$DDI_CACHE/DeveloperDiskImage.dmg.signature"
XCODE_IMAGE="${XCODE_463_DMG:-$HOME/Downloads/Xcode_4.6.3.dmg}"
XCODE_MOUNT="${XCODE_463_MOUNT:-/private/tmp/xcode463}"
PMD_VENV="${PMD3_VENV:-$HOME/.venvs/pmd3}"
DDI_SOURCE="$XCODE_MOUNT/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/5.1"

if [[ ! -f "$DDI_IMAGE" ]]; then
  if [[ ! -f "$DDI_SOURCE/DeveloperDiskImage.dmg" ]]; then
    [[ -f "$XCODE_IMAGE" ]] || { echo "error: Xcode 4.6.3 image not found" >&2; exit 1; }
    mkdir -p "$XCODE_MOUNT"
    if ! echo Y | hdiutil attach -nobrowse -readonly -mountpoint "$XCODE_MOUNT" \
        "$XCODE_IMAGE" >/dev/null 2>&1; then
      hdiutil detach "$XCODE_MOUNT" >/dev/null 2>&1 || true
      echo Y | hdiutil attach -nobrowse -readonly -mountpoint "$XCODE_MOUNT" \
        "$XCODE_IMAGE" >/dev/null
    fi
  fi
  mkdir -p "$DDI_CACHE"
  cp "$DDI_SOURCE/DeveloperDiskImage.dmg" "$DDI_IMAGE"
  cp "$DDI_SOURCE/DeveloperDiskImage.dmg.signature" "$DDI_SIGNATURE"
fi

if [[ ! -x "$PMD_VENV/bin/pymobiledevice3" ]]; then
  python3 -m venv "$PMD_VENV"
  "$PMD_VENV/bin/pip" install -q --disable-pip-version-check pymobiledevice3
fi

"$PMD_VENV/bin/pymobiledevice3" afc push "$DDI_IMAGE" \
  /PublicStaging/staging.dimage 2>&1 | tail -1
if ! python3 -W ignore::DeprecationWarning "$REPO_ROOT/ios-compat/tools/mount_ddi.py" \
    "$DDI_IMAGE" "$DDI_SIGNATURE"; then
  probe_file="$(mktemp -t ddi-probe).tiff"
  if idevicescreenshot "$probe_file" >/dev/null 2>&1; then
    rm -f "$probe_file"
    echo "DDI was already mounted"
  else
    rm -f "$probe_file"
    echo "error: DDI mount failed" >&2
    exit 1
  fi
fi

if [[ $# -ge 1 ]]; then
  output_file="$1"
  tiff_file="$(mktemp -t ios5-shot).tiff"
  idevicescreenshot "$tiff_file" >/dev/null
  sips -s format png "$tiff_file" --out "$output_file" >/dev/null
  rm -f "$tiff_file"
  echo "screenshot: $output_file"
fi
