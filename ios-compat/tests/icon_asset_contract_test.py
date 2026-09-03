#!/usr/bin/env python3
"""Every icon the kiosk asks for is one tools/gen_icons.py actually wrote.

A name typo does not fail the build: DBIconAsset returns nil for an icon that is not
vendored and the caller lays out without it, which is the right behaviour on a device
and the wrong one in CI, because the glyph simply goes missing and nobody notices.
So the names are checked here instead.
"""

import os
import re
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ICON_DIR = os.path.join(ROOT, "ios-kiosk/resources/icons")

# Where a name can be written: a literal at the call site, or one of the two
# mapping functions that answer with a name.
LITERAL = re.compile(r'tintedImageNamed:@"([a-z0-9-]+)"')
# Inside a name-returning function, every plain lowercase literal is a candidate.
# Icon names are Tabler's own hyphenated ids; a purpose id such as p_visit uses
# an underscore, which is what tells the two apart.
ANY_LITERAL = re.compile(r'@"([a-z0-9-]+)"')


def sources():
    for base, _dirs, files in os.walk(os.path.join(ROOT, "ios-kiosk/src")):
        for name in files:
            if name.endswith((".m", ".h")):
                yield os.path.join(base, name)


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def requested_names():
    """Names asked for by the icon call sites and the two name-returning functions."""
    names = set()
    for path in sources():
        text = read(path)
        for match in LITERAL.finditer(text):
            names.add(match.group(1))
        for func in ("NSString *DBFleetGlyphIconName(DBFleetGlyph glyph) {",
                     "+ (NSString *)iconNameForPurpose:(NSString *)purposeId {"):
            if func not in text:
                continue
            body = text[text.index(func):]
            body = body[:body.index("\n}\n")]
            names.update(n for n in ANY_LITERAL.findall(body) if "_" not in n)
    return names


class IconAssetContracts(unittest.TestCase):

    def test_generated_icons_exist(self):
        self.assertTrue(os.path.isdir(ICON_DIR),
                        "tools/gen_icons.py output is missing: " + ICON_DIR)
        vendored = {f[len("tabler_"):-len(".png")]
                    for f in os.listdir(ICON_DIR)
                    if f.startswith("tabler_") and f.endswith(".png")
                    and not f.endswith("@2x.png")}
        self.assertTrue(vendored, "no icons vendored")
        names = requested_names()
        # The four counters/knob names must be among them, so an accidental
        # deletion of a call site does not make this test vacuous.
        for required in ("topology-star-3", "door", "device-tablet", "chevrons-right",
                         "home", "package", "mail"):
            self.assertIn(required, names,
                          "the shell no longer asks for the %s icon" % required)
        for name in sorted(names):
            # gen_icons.py folds hyphens to underscores in the file name.
            self.assertIn(name.replace("-", "_"), vendored,
                          'no generated icon for "%s"; add it to tools/gen_icons.py '
                          "and regenerate" % name)

    def test_every_requested_icon_has_a_retina_copy(self):
        for name in sorted(requested_names()):
            path = os.path.join(ICON_DIR, "tabler_%s@2x.png" % name.replace("-", "_"))
            self.assertTrue(os.path.exists(path), "missing @2x for " + name)

    def test_the_bundle_copies_the_generated_directory(self):
        makefile = read(os.path.join(ROOT, "ios-kiosk/Makefile"))
        self.assertIn("resources/icons/*.png", makefile,
                      "the app bundle would ship without any icons")


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0]])
