#!/usr/bin/env python3
"""The kiosk's native settings cover every configuration key the web Admin writes.

The key list is not copied here: it is read out of webui/admin/app.js, from the string
literals the Admin uses while it builds the key of a config write or read (`key: "..."`,
`entries.push({ key: ... })`, `L.configAt(cfg, "...")` and friends). A setting added to
the Admin therefore fails this test until the kiosk has a row for it, or until it is
listed in NOT_NATIVE below with the reason it cannot be.

A key counts as covered when the kiosk's settings sources name it. The kiosk often
builds a key from a prefix and a leaf (`@"integrations.mqtt.%@"` plus `@"port"`), so a
key is also covered when its parent is covered and its last segment appears as a leaf.
"""

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

KIOSK_SOURCES = (
    "ios-kiosk/src/Screens/DBSettingsScreen.m",
    "ios-kiosk/src/Screens/DBSettingsPages.m",
    "ios-kiosk/src/Screens/DBRoleChange.m",
    "ios-kiosk/src/Screens/DBNoticeDialog.m",
    "ios-kiosk/src/Core/DBSettingsLogic.m",
)

# Admin keys the kiosk deliberately has no row for. Keep this empty unless a key truly
# cannot be edited on the device, and say why.
NOT_NATIVE = {}

KEY_CONTEXT = re.compile(
    r'(?:\bkey\s*:\s*|\bpush\(\s*|\bL\.configAt\([^,\n]+,\s*)'
    r'((?:"[^"\n]*"|\'[^\'\n]*\'|[\w.\[\]]+|\s*\+\s*)+)')
LITERAL = re.compile(r'"([^"\n]*)"|\'([^\'\n]*)\'')
KEY_SHAPE = re.compile(r'[a-z0-9_]+(\.[a-z0-9_]+)+')


def read(relative_path):
    with open(os.path.join(ROOT, relative_path), encoding="utf-8") as handle:
        return handle.read()


def admin_keys():
    """Dotted key fragments from the Admin's config-key expressions."""
    keys = set()
    for match in KEY_CONTEXT.finditer(read("webui/admin/app.js")):
        for pair in LITERAL.findall(match.group(1)):
            literal = pair[0] or pair[1]
            if "." not in literal:
                continue
            fragment = literal.strip(".")
            if KEY_SHAPE.fullmatch(fragment):
                keys.add(fragment)
    return keys


def covered(key, source):
    if key in source:
        return True
    if "." not in key:
        return ('"%s"' % key) in source or ("%s." % key) in source
    parent, leaf = key.rsplit(".", 1)
    leaf_named = any(form in source for form in (
        '"%s"' % leaf, ".%s\"" % leaf, ".%s." % leaf, '"%s.' % leaf, ".%s%%" % leaf))
    return leaf_named and covered(parent, source)


class KioskSettingsParity(unittest.TestCase):

    def test_the_admin_key_list_is_really_extracted(self):
        keys = admin_keys()
        # A refactor of the Admin that defeats the extraction must fail here, not pass
        # the parity check with an empty list.
        self.assertGreaterEqual(len(keys), 40, sorted(keys))
        for expected in ("audio.volume", "ui.languages", "emergency.trigger.mode",
                         "integrations.web_push.sender_url", "local.video.playback",
                         "time.ntp.servers", "display.appearance_schedule"):
            self.assertIn(expected, keys)

    def test_every_admin_config_key_has_a_native_row(self):
        source = "\n".join(read(path) for path in KIOSK_SOURCES)
        missing = sorted(key for key in admin_keys()
                         if key not in NOT_NATIVE and not covered(key, source))
        self.assertEqual(missing, [],
                         "the web Admin writes these keys and the kiosk settings have no "
                         "row for them: %s" % ", ".join(missing))

    def test_exemptions_are_still_needed(self):
        keys = admin_keys()
        source = "\n".join(read(path) for path in KIOSK_SOURCES)
        for key, reason in NOT_NATIVE.items():
            self.assertTrue(reason.strip(), key)
            self.assertIn(key, keys, "%s is no longer an Admin key; drop the exemption" % key)
            self.assertFalse(covered(key, source),
                             "%s is covered now; drop the exemption" % key)


if __name__ == "__main__":
    unittest.main(verbosity=2)
