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

# Every icon is a literal "f7:<name>" naming assets/icons/framework7/<name>.svg.
F7_LITERAL = re.compile(r'@"f7:([a-z0-9_]+)"')


def sources():
    for base, _dirs, files in os.walk(os.path.join(ROOT, "ios-kiosk/src")):
        for name in files:
            if name.endswith((".m", ".h")):
                yield os.path.join(base, name)


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def requested_names():
    names = set()
    for path in sources():
        names.update(F7_LITERAL.findall(read(path)))
    return names


class IconAssetContracts(unittest.TestCase):

    def test_every_requested_icon_is_generated_with_a_retina_copy(self):
        names = requested_names()
        for required in ("house_fill", "bell_fill", "videocam_fill", "tv_fill",
                         "rectangle_3_offgrid_fill", "chevron_right_2", "person_fill"):
            self.assertIn(required, names, "the shell no longer asks for " + required)
        for name in sorted(names):
            for suffix in ("", "@2x"):
                self.assertTrue(os.path.exists(
                    os.path.join(ICON_DIR, "f7_%s%s.png" % (name, suffix))),
                    "no generated Framework7 icon for " + name)

    def test_the_kiosk_ships_no_tabler_png(self):
        leftovers = [f for f in os.listdir(ICON_DIR) if f.startswith("tabler_")]
        self.assertEqual(leftovers, [])

    def test_the_bundle_copies_the_generated_directory(self):
        makefile = read(os.path.join(ROOT, "ios-kiosk/Makefile"))
        self.assertIn("resources/icons/*.png", makefile,
                      "the app bundle would ship without any icons")


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0]])
