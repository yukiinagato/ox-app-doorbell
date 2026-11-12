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
    "video_playback", "speech", "reply", "events",
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
    return "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(ANDROID.glob("*Settings*.kt")))


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
    return ('"%s"' % head) in sources and ('.%s"' % leaf) in sources


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


if __name__ == "__main__":
    unittest.main()
