#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MINISIP="$REPO_ROOT/ios-kiosk/mini_sip"
OUT="$REPO_ROOT/build/ios-compat/host-tests"
CC="${CC:-$(xcrun -f clang 2>/dev/null || command -v clang || command -v cc)}"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"

mkdir -p "$OUT"
COMMON=(
  "$MINISIP/minisip.c"
  "$MINISIP/sip.c"
  "$MINISIP/sdp.c"
  "$MINISIP/rtp.c"
  "$MINISIP/g711.c"
)
CFLAGS=(-std=c99 -Wall -Wextra -Werror -O2 -I"$MINISIP")
[[ -z "$MACOS_SDK" ]] || CFLAGS+=(-isysroot "$MACOS_SDK")

"$CC" "${CFLAGS[@]}" "${COMMON[@]}" \
  "$REPO_ROOT/ios-compat/tests/minisip_uas_loopback.c" -lm \
  -o "$OUT/minisip_uas_loopback"
"$CC" "${CFLAGS[@]}" "${COMMON[@]}" \
  "$REPO_ROOT/ios-compat/tests/minisip_cli.c" -lm \
  -o "$OUT/minisip_cli"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Core" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBBootConfig.m" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBMediaSource.m" \
  "$REPO_ROOT/ios-compat/tests/media_source_test.m" \
  -framework Foundation -o "$OUT/media_source_test"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Core" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBCallEventTracker.m" \
  "$REPO_ROOT/ios-compat/tests/call_event_tracker_test.m" \
  -framework Foundation -o "$OUT/call_event_tracker_test"

swiftc \
  "$REPO_ROOT/ios/Doorbell/CallRevisionLifecycle.swift" \
  "$REPO_ROOT/ios-compat/tests/modern_call_revision_test.swift" \
  -o "$OUT/modern_call_revision_test"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Net" \
  "$REPO_ROOT/ios-kiosk/src/Net/DBHTTPMediaSupport.m" \
  "$REPO_ROOT/ios-compat/tests/http_media_test.m" \
  -framework Foundation -o "$OUT/http_media_test"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Net" \
  "$REPO_ROOT/ios-kiosk/src/Net/DBRTPH264Depacketizer.m" \
  "$REPO_ROOT/ios-kiosk/src/Net/DBRTSPH264Source.m" \
  "$REPO_ROOT/ios-compat/tests/rtsp_h264_test.m" \
  -framework Foundation -o "$OUT/rtsp_h264_test"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Core" \
  "$REPO_ROOT/ios-compat/tests/compatibility_profile_test.m" \
  -framework Foundation -o "$OUT/compatibility_profile_test"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Support" \
  "$REPO_ROOT/ios-kiosk/src/Support/DBRecoveryClient.m" \
  "$REPO_ROOT/ios-compat/tests/recovery_policy_test.m" \
  -framework Foundation -o "$OUT/recovery_policy_test"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Media" \
  "$REPO_ROOT/ios-kiosk/src/Media/DBLiveEdgeGate.m" \
  "$REPO_ROOT/ios-compat/tests/live_edge_gate_test.m" \
  -framework Foundation -o "$OUT/live_edge_gate_test"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Core" -I"$REPO_ROOT/ios-kiosk/src/Support" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBUiTheme.m" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBSosSlideModel.m" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBCallHistoryModel.m" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBNoticeModel.m" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBBootConfig.m" \
  "$REPO_ROOT/ios-kiosk/src/Support/DBSafeModeRecovery.m" \
  "$REPO_ROOT/ios-compat/tests/native_settings_ux_test.m" \
  -framework Foundation -o "$OUT/native_settings_ux_test"

"$CC" -fobjc-arc -Wall -Wextra -Werror -O2 -isysroot "$MACOS_SDK" \
  -I"$REPO_ROOT/ios-kiosk/src/Core" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBRefreshCoalescer.m" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBBackoffPolicy.m" \
  "$REPO_ROOT/ios-kiosk/src/Core/DBPairingModel.m" \
  "$REPO_ROOT/ios-compat/tests/pairing_ux_test.m" \
  -framework Foundation -o "$OUT/pairing_ux_test"

"$OUT/minisip_uas_loopback"
"$OUT/media_source_test"
"$OUT/call_event_tracker_test"
"$OUT/modern_call_revision_test"
"$OUT/http_media_test"
"$OUT/rtsp_h264_test"
"$OUT/compatibility_profile_test"
"$OUT/recovery_policy_test"
"$OUT/live_edge_gate_test"
"$OUT/pairing_ux_test"
"$OUT/native_settings_ux_test"
python3 "$REPO_ROOT/ios-compat/tests/ios9_armv7_profile_test.py"
python3 "$REPO_ROOT/ios-compat/tests/semantic_ui_contract_test.py"
python3 "$REPO_ROOT/ios-compat/tests/sos_presentation_contract_test.py"
python3 "$REPO_ROOT/ios-compat/tests/recovery_safe_mode_contract_test.py"
python3 "$REPO_ROOT/ios-compat/tests/native_settings_contract_test.py"
python3 "$REPO_ROOT/ios-compat/tests/pairing_flow_contract_test.py"
python3 "$REPO_ROOT/ios-compat/tests/pairing_flow_contract_swift_test.py"
# Root keepalive helper: daemon behaviour plus the staged-package/installer rails.
if [[ -n "${DB_SKIP_HELPER_HOST_TESTS:-}" ]]; then
  echo "helper host tests skipped (DB_SKIP_HELPER_HOST_TESTS set; the keepalive-helper job owns them)"
else
  bash "$REPO_ROOT/tools/helper/test_keepalive_helper.sh"
fi
python3 "$REPO_ROOT/tools/tests/test_ios5_helper_package.py"
echo "host tests passed"
