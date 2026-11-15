#!/usr/bin/env python3
"""Android native settings must cover the configuration keys the web Admin edits.

The key list is derived from webui/admin/app.js rather than copied: every dotted string literal
under a configuration root that is not an i18n id is a key (or key prefix) the Admin reads or
writes. A key counts as covered when the Android shell's settings sources name it. Keys the
shell does not cover yet are listed in KNOWN_GAPS; the test fails when the Admin gains a key
that is neither covered nor listed, and when a listed gap has been closed but not removed, so
the list can only shrink deliberately.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
ADMIN = ROOT / "webui" / "admin" / "app.js"
STRINGS = ROOT / "i18n" / "strings.yaml"
ANDROID = ROOT / "android" / "app" / "src" / "main" / "java" / "jp" / "ox" / "doorbell"

CONFIG_ROOTS = (
    "ui", "display", "sip", "emergency", "integrations", "time", "quiet_hours",
    "video_playback", "speech", "reply", "events", "visitor_flow",
)
LITERAL = re.compile(
    r"""["'`]((?:%s)\.[A-Za-z0-9_.]+)["'`]""" % "|".join(CONFIG_ROOTS))

# Literals that match the pattern but are not keys a settings row edits.
NOT_KEYS = {
    "time.google.com",
    # Core derives this from time.zone; the Admin form reads it and never writes it.
    "integrations.tz_offset_min",
}

# Admin keys with no Android settings row yet. Remove an entry when its row lands.
KNOWN_GAPS = {
    # The playback policy editor (strategy order, timeouts, per-pair overrides).
    "video_playback.global",
    "video_playback.pairs",
}


# Keys the Admin builds at run time (per device, per region, per level), which no literal scan
# can find. Listed once here, by the path under the device's local subtree or the cluster root.
DYNAMIC_KEYS = [
    "local.camera.codec", "local.camera.resolution", "local.camera.mjpeg_fps",
    "local.camera.mjpeg_quality", "local.camera.h264_resolution", "local.camera.h264_fps",
    "local.camera.h264_bitrate_kbps", "local.camera.device_hint", "local.camera.source_ref",
    "local.motion.enabled", "local.motion.sensitivity", "local.motion.min_interval_s",
    "local.visitor_layout", "local.video.playback", "local.video.rotation",
    "local.display.appearance", "local.theme.call_button_bg", "local.ui.elements",
    "local.audio.volume", "local.capabilities",
    "audio.volume.call", "audio.volume.sos", "audio.volume.idle",
    "display.appearance", "display.appearance_schedule.dark_from",
    "display.appearance_schedule.light_from",
    "display.screensaver.enabled", "display.screensaver.mode", "display.screensaver.schedule",
    "display.screensaver.from", "display.screensaver.to", "display.screensaver.after_s",
    "display.screensaver.brightness",
    "display.theme.backdrop.enabled", "display.theme.backdrop.opacity",
    "display.theme.backdrop.color", "display.theme.ink_override", "display.theme.bg_color",
    "display.theme.bg_image",
    "speech.provider", "speech.voice", "speech.rate",
    "video_playback.global.strategies",
]

# Dynamic keys with no Android row yet.
DYNAMIC_GAPS = {
    "local.capabilities",
    "speech.provider", "speech.voice", "speech.rate",
    "video_playback.global.strategies",
}


def i18n_ids():
    ids = set()
    for line in STRINGS.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z0-9_.]+):\s*\{", line)
        if match:
            ids.add(match.group(1))
    return ids


def admin_keys():
    source = ADMIN.read_text(encoding="utf-8")
    ids = i18n_ids()
    keys = set()
    for literal in LITERAL.findall(source):
        key = literal.rstrip("._")
        if key in ids or literal in ids or key in NOT_KEYS or "." not in key:
            continue
        keys.add(key)
    return keys


def android_sources():
    paths = sorted(ANDROID.glob("*Settings*.kt")) + sorted(ANDROID.glob("VisitorFlowEdit*.kt"))
    return "\n".join(path.read_text(encoding="utf-8") for path in paths)


def covered(key, sources):
    """Named whole, or as a dotted prefix plus leaf the way the Kotlin builds nested keys."""
    if key in sources:
        return True
    head, _, leaf = key.rpartition(".")
    if not head:
        return False
    if (head + ".") in sources and ('"%s"' % leaf) in sources:
        return True
    # val root = "integrations.mqtt" ... "$root.host"
    if ('"%s"' % head) in sources and ('.%s"' % leaf) in sources:
        return True
    # "$local.camera.codec": the path below the device's local subtree.
    below = key.split(".", 1)[1] if key.startswith("local.") else key
    return ("." + below + '"') in sources or ("." + below + ".") in sources


class AndroidSettingsParity(unittest.TestCase):
    def test_the_admin_key_list_is_derived_and_not_empty(self):
        keys = admin_keys()
        self.assertGreater(len(keys), 25, sorted(keys))
        self.assertIn("ui.call_flow", keys)
        self.assertIn("time.ntp.servers", keys)

    def test_every_admin_key_has_a_native_row_or_is_a_listed_gap(self):
        sources = android_sources()
        missing = sorted(
            key for key in admin_keys() if not covered(key, sources) and key not in KNOWN_GAPS)
        self.assertEqual([], missing, "Admin keys with no Android settings row: %s" % missing)

    def test_listed_gaps_are_real(self):
        keys = admin_keys()
        sources = android_sources()
        stale = sorted(
            gap for gap in KNOWN_GAPS if gap not in keys or covered(gap, sources))
        self.assertEqual([], stale, "Remove closed or vanished gaps from KNOWN_GAPS: %s" % stale)

    def test_dynamic_admin_keys_have_rows_or_are_listed_gaps(self):
        sources = android_sources()
        missing = sorted(
            key for key in DYNAMIC_KEYS if not covered(key, sources) and key not in DYNAMIC_GAPS)
        self.assertEqual([], missing, "Dynamic Admin keys with no Android row: %s" % missing)
        stale = sorted(gap for gap in DYNAMIC_GAPS if covered(gap, sources))
        self.assertEqual([], stale, "Remove closed gaps from DYNAMIC_GAPS: %s" % stale)


# The visitor-flow editor writes these: the scalar leaves, one whole value per step, and a leaf per
# door start (docs/en/visitor-flow-contract.md, section 8). The container itself is never written.
FLOW_KEYS = [
    "visitor_flow.enabled", "visitor_flow.start", "visitor_flow.idle_s", "visitor_flow.require_call",
    "visitor_flow.steps", "doors.%s.visitor_flow.start",
]
FLOW_STRINGS = [
    "flow_editor.title", "flow_editor.enabled", "flow_editor.start", "flow_editor.door_start",
    "flow_editor.idle_s", "flow_editor.require_call", "flow_editor.require_call_off_warning",
    "flow_editor.steps", "flow_editor.add_step", "flow_editor.duplicate_step",
    "flow_editor.delete_step", "flow_editor.step_in_use", "flow_editor.field_title",
    "flow_editor.field_body", "flow_editor.field_images", "flow_editor.add_image",
    "flow_editor.image_alt", "flow_editor.field_options", "flow_editor.add_option",
    "flow_editor.option_label", "flow_editor.option_icon", "flow_editor.option_purpose",
    "flow_editor.option_primary", "flow_editor.option_enabled", "flow_editor.option_target",
    "flow_editor.field_purpose", "flow_editor.field_on_unanswered", "flow_editor.field_message",
    "flow_editor.field_to", "flow_editor.field_return_s", "flow_editor.field_snapshot",
    "flow_editor.snapshot_none", "flow_editor.snapshot_door_station", "flow_editor.snapshot_camera",
    "flow_editor.snapshot_no_camera", "flow_editor.templates", "flow_editor.template_purposes",
    "flow_editor.template_delivery", "flow_editor.template_confirm", "flow_editor.reset_default",
    "flow_editor.reset_default_confirm", "flow_editor.customize", "flow_editor.default_note",
    "flow_editor.conflict", "flow_editor.call_flow_superseded", "visitor_flow.invalid",
]


class AndroidVisitorFlowEditor(unittest.TestCase):
    def sources(self):
        return "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(ANDROID.glob("*Flow*.kt")) + sorted(ANDROID.glob("*Settings*.kt")))

    def test_every_flow_key_is_written_by_the_editor(self):
        sources = self.sources()
        for key in FLOW_KEYS:
            self.assertIn(key.replace("%s", "$door"), sources, key)

    def test_the_editor_never_writes_a_container_or_a_key_below_a_step(self):
        model = (ANDROID / "VisitorFlowEditModel.kt").read_text(encoding="utf-8")
        editor = (ANDROID / "VisitorFlowEditor.kt").read_text(encoding="utf-8")
        for text in (model, editor):
            self.assertNotRegex(text, r'Set\("visitor_flow(\.steps)?"')
            self.assertNotRegex(text, r'Set\("\$STEPS\.\$\w+\.(title|body|options|images|kind)')
        # Deleting visitor_flow as one op is how "Reset to the built-in wizard" works.
        self.assertIn("ConfigOp.Delete(ROOT)", model)

    def test_every_editor_string_exists_in_the_catalogue(self):
        ids = i18n_ids()
        for key in FLOW_STRINGS:
            self.assertIn(key, ids, key)

    def test_the_editor_sits_in_the_calls_category(self):
        activity = (ANDROID / "SettingsActivity.kt").read_text(encoding="utf-8")
        self.assertIn("flowEditor.section()", activity)
        self.assertIn('key == "ui.call_flow" && FlowEdit.hasSteps(config)', activity)


if __name__ == "__main__":
    unittest.main()
