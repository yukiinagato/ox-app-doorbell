"""The icon pipeline: the path parser, the generator's outputs, and the hand-drawn-icon check."""

import os
import re
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import check_icons  # noqa: E402
import gen_icons  # noqa: E402
import svg_path  # noqa: E402


class SvgPathTest(unittest.TestCase):
    def test_line_commands(self):
        subpaths = svg_path.flatten("M1 2 L3 4 H5 V6 Z")
        self.assertEqual(len(subpaths), 1)
        closed, points = subpaths[0]
        self.assertTrue(closed)
        self.assertEqual(points[0], (1.0, 2.0))
        self.assertIn((5.0, 4.0), points)
        self.assertIn((5.0, 6.0), points)

    def test_relative_commands_accumulate(self):
        _closed, points = svg_path.flatten("M0 0 l 2 0 l 0 2")[0]
        self.assertEqual(points[-1], (2.0, 2.0))

    def test_arc_traces_a_circle(self):
        # Tabler draws every dot as two arcs; getting these wrong is how a circle becomes a wedge.
        _closed, points = svg_path.flatten("M10 19a2 2 0 1 0 -4 0a2 2 0 0 0 4 0")[0]
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        self.assertAlmostEqual(min(xs), 6.0, places=2)
        self.assertAlmostEqual(max(xs), 10.0, places=2)
        self.assertAlmostEqual(min(ys), 17.0, places=2)
        self.assertAlmostEqual(max(ys), 21.0, places=2)
        for x, y in points:
            self.assertAlmostEqual(((x - 8.0) ** 2 + (y - 19.0) ** 2) ** 0.5, 2.0, places=2)

    def test_cubic_stays_inside_its_hull(self):
        _closed, points = svg_path.flatten("M0 0 C 0 10 10 10 10 0")[0]
        self.assertTrue(all(0 <= x <= 10 and 0 <= y <= 10 for x, y in points))
        self.assertEqual(points[-1], (10.0, 0.0))

    def test_unsupported_command_is_refused(self):
        with self.assertRaises(svg_path.PathError):
            svg_path.flatten("M0 0 X 3")


class GenIconsTest(unittest.TestCase):
    def setUp(self):
        self.names = gen_icons.icon_names()

    def test_vendored_sources_exist_with_a_licence(self):
        self.assertTrue(self.names, "no Tabler icons are vendored")
        self.assertTrue(os.path.exists(os.path.join(gen_icons.SOURCE_DIR, "LICENSE")))
        for required in ("door", "device-tablet", "topology-star-3"):
            self.assertIn(required, self.names, required + " names a device kind in the UI")

    def test_generated_tree_is_current(self):
        # The same check CI runs: an edited SVG with stale outputs must fail here first.
        result = subprocess.run([sys.executable, os.path.join(ROOT, "tools/gen_icons.py"),
                                 "--check"], cwd=ROOT, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout.decode() + result.stderr.decode())

    def test_every_platform_gets_every_icon(self):
        for name in self.names:
            flat = name.replace("-", "_")
            self.assertTrue(os.path.exists(os.path.join(
                ROOT, "android/app/src/main/res/drawable", "ic_tabler_" + flat + ".xml")))
            imageset = os.path.join(ROOT, "ios/Doorbell/Assets.xcassets",
                                    "Tabler" + gen_icons.camel(name) + ".imageset")
            self.assertTrue(os.path.exists(os.path.join(imageset, "icon.pdf")))
            self.assertTrue(os.path.exists(os.path.join(imageset, "Contents.json")))
            for suffix in ("", "@2x"):
                self.assertTrue(os.path.exists(os.path.join(
                    ROOT, "ios-kiosk/resources/icons", "tabler_" + flat + suffix + ".png")))

    def test_outputs_carry_the_generated_banner(self):
        for path in ("android/app/src/main/res/drawable/ic_tabler_door.xml",
                     "win/DoorbellApp/Resources/Icons.xaml",
                     "webui/icons/tabler-sprite.svg"):
            with open(os.path.join(ROOT, path), "r", encoding="utf-8") as handle:
                self.assertIn(gen_icons.BANNER, handle.read(), path)

    def test_geometry_is_passed_through_unchanged(self):
        # XAML takes SVG path syntax as-is, so its geometry must be byte-identical to the
        # vendored file rather than a re-rendering of it. Android takes the same geometry with
        # one spelling change: its own lint refuses a bare ".01" because that crashes some
        # devices' path parser, so the generator writes the leading zero. Same numbers.
        data = gen_icons.path_data(gen_icons.read_source("door"))
        with open(os.path.join(ROOT, "win/DoorbellApp/Resources/Icons.xaml"),
                  "r", encoding="utf-8") as handle:
            self.assertIn(">" + data + "<", handle.read())
        android = gen_icons.android_path_data(data)
        with open(os.path.join(ROOT, "android/app/src/main/res/drawable/ic_tabler_door.xml"),
                  "r", encoding="utf-8") as handle:
            self.assertIn(android, handle.read())
        numbers = lambda text: [float(n) for n in
                                re.findall(r"-?(?:\d+\.?\d*|\.\d+)", text)]
        self.assertEqual(numbers(data), numbers(android))
        self.assertNotIn("v.01", android)

    def test_android_path_data_only_adds_the_leading_zero(self):
        self.assertEqual("M14 12v0.01", gen_icons.android_path_data("M14 12v.01"))
        self.assertEqual("M1 -0.5l2.5 3", gen_icons.android_path_data("M1 -.5l2.5 3"))
        # A decimal that already has its digit is left exactly as it was.
        unchanged = "M6 21v-16a2 2 0 0 1 2 -2h8a2 2 0 0 1 2 2v16"
        self.assertEqual(unchanged, gen_icons.android_path_data(unchanged))

    def test_the_admin_sprite_resolves_every_reference(self):
        with open(os.path.join(ROOT, "webui/admin/index.html"), "r", encoding="utf-8") as handle:
            html = handle.read()
        self.assertIn(gen_icons.SPRITE_BEGIN, html)
        import re
        referenced = set(re.findall(r'href=["\']#(i-[a-z0-9-]+)["\']', html))
        with open(os.path.join(ROOT, "webui/admin/app.js"), "r", encoding="utf-8") as handle:
            referenced |= {"i-" + name for name in re.findall(r'icon\("([a-z0-9-]+)"\)',
                                                              handle.read())}
        self.assertTrue(referenced)
        for symbol in sorted(referenced):
            self.assertIn('id="' + symbol + '"', html, symbol + " has no symbol in the sprite")

    def test_pdf_is_a_readable_single_page(self):
        blob = gen_icons.pdf_bytes("door", gen_icons.path_data(gen_icons.read_source("door")))
        self.assertTrue(blob.startswith(b"%PDF-1.4"))
        self.assertIn(b"/MediaBox [0 0 24 24]", blob)
        self.assertIn(b"startxref", blob)
        self.assertTrue(blob.rstrip().endswith(b"%%EOF"))


class CheckIconsTest(unittest.TestCase):
    def test_generated_outputs_are_not_flagged(self):
        for path in ("android/app/src/main/res/drawable/ic_tabler_door.xml",
                     "win/DoorbellApp/Resources/Icons.xaml",
                     "webui/icons/tabler-sprite.svg",
                     "webui/admin/index.html"):
            self.assertEqual(check_icons.violations_in(path), [], path)

    def test_a_hand_drawn_icon_is_flagged(self):
        # The rule exists because these drift: the three device glyphs were drawn by hand in
        # every shell independently before the library was chosen. The fixture is written here
        # rather than pointed at a checked-in file, because a hand-drawn drawable is precisely
        # what must never be in the tree -- the ic_count_* drawables this used to name are gone.
        rel = "android/app/src/main/res/drawable/zz_hand_drawn_fixture.xml"
        path = os.path.join(ROOT, rel)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<vector xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <path android:pathData="M4 4 L20 20" />\n'
                "</vector>\n")
        try:
            flagged = check_icons.violations_in(rel)
        finally:
            os.remove(path)
        self.assertTrue(flagged, "a hand-drawn drawable must be refused")

    def test_the_allow_list_carries_a_reason(self):
        for entry in check_icons.ALLOWED:
            self.assertEqual(len(entry), 2)
            self.assertTrue(entry[1].strip(), entry[0] + " needs a reason")


if __name__ == "__main__":
    unittest.main()
