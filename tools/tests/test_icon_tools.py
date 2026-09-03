"""The icon pipeline: the path parser, the generator's outputs, and the hand-drawn-icon check."""

import os
import re
import shutil
import subprocess
import sys
import tempfile
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

    def test_android_drawables_reference_no_theme_attribute(self):
        """A generated drawable resolves on its own or it does not link.

        The emitted vectors carried android:tint="?attr/colorControlNormal", which needs an
        AppCompat or Material theme this project does not have -- its views are framework views.
        The legacy19 tier is stricter still: it rasterises vectors at build time, where there is
        no theme to read at all, so even ?android:attr/ is unusable. Colour is a literal and the
        shells tint at runtime.
        """
        for name in self.names:
            path = os.path.join(ROOT, "android/app/src/main/res/drawable",
                                "ic_tabler_" + name.replace("-", "_") + ".xml")
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
            self.assertNotIn("?attr/", text, path)
            self.assertNotIn("?android:attr/", text, path)
            self.assertIn('android:strokeColor="#FF000000"', text, path)
            self.assertIn('android:strokeWidth="2"', text, path)
            self.assertIn('android:strokeLineCap="round"', text, path)
            self.assertIn('android:strokeLineJoin="round"', text, path)
            self.assertNotIn("android:tint", text, path)

    def test_the_generator_emits_no_theme_attribute(self):
        # The same rule at the source, so a future edit to the template is caught here and not
        # in an Android resource-linking failure.
        emitted = gen_icons.android_xml("door", "M0 0 L4 4")
        self.assertNotIn("?attr/", emitted)
        self.assertNotIn("?android:attr/", emitted)
        self.assertIn('android:strokeColor="#FF000000"', emitted)

    def test_outputs_carry_the_generated_banner(self):
        for path in ("android/app/src/main/res/drawable/ic_tabler_door.xml",
                     "win/DoorbellApp/Resources/Icons.xaml",
                     "webui/icons/tabler-sprite.svg"):
            with open(os.path.join(ROOT, path), "r", encoding="utf-8") as handle:
                self.assertIn(gen_icons.BANNER, handle.read(), path)

    def test_geometry_survives_number_normalisation(self):
        """Android and XAML get canonical numbers, and not one point moves.

        Tabler writes leading-dot decimals; Android lint refuses them (InvalidVectorPath) as a
        crash risk on some devices. The numbers are re-spelled, so the text is no longer
        byte-identical to the vendored file -- which makes it worth proving the shapes are, by
        flattening both and comparing every point.
        """
        for name in self.names:
            raw = gen_icons.path_data(gen_icons.read_source(name))
            canonical = gen_icons.normalize_path_numbers(raw)
            before = svg_path.flatten(raw)
            after = svg_path.flatten(canonical)
            self.assertEqual(len(before), len(after), name)
            for (closed_a, points_a), (closed_b, points_b) in zip(before, after):
                self.assertEqual(closed_a, closed_b, name)
                self.assertEqual(len(points_a), len(points_b), name)
                for (x1, y1), (x2, y2) in zip(points_a, points_b):
                    self.assertAlmostEqual(x1, x2, places=9, msg=name)
                    self.assertAlmostEqual(y1, y2, places=9, msg=name)

    def test_android_and_xaml_carry_the_canonical_geometry(self):
        data = gen_icons.normalize_path_numbers(
            gen_icons.path_data(gen_icons.read_source("door")))
        with open(os.path.join(ROOT, "android/app/src/main/res/drawable/ic_tabler_door.xml"),
                  "r", encoding="utf-8") as handle:
            self.assertIn(data, handle.read())
        with open(os.path.join(ROOT, "win/DoorbellApp/Resources/Icons.xaml"),
                  "r", encoding="utf-8") as handle:
            self.assertIn(">" + data + "<", handle.read())

    def test_no_leading_dot_numbers_reach_android(self):
        # The exact spelling Android lint rejects: "v.01" for a dot, which Tabler uses a lot.
        pattern = re.compile(r"[\s,\-A-Za-z]\.\d")
        for name in self.names:
            path = os.path.join(ROOT, "android/app/src/main/res/drawable",
                                "ic_tabler_" + name.replace("-", "_") + ".xml")
            with open(path, "r", encoding="utf-8") as handle:
                data = re.search(r'android:pathData="([^"]*)"', handle.read()).group(1)
            self.assertIsNone(pattern.search(data), path + " has a leading-dot number")
            self.assertFalse(data.startswith("."), path)

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
    """The checker is exercised against fixtures this test writes.

    It used to name ic_count_cluster.xml in the repository, which passed only for as long as
    that hand-drawn drawable existed -- the Android shell replaced it with the generated one and
    the test started asserting that an absent file contains no icons. A test of "this is
    refused" has to own the thing being refused.
    """

    def setUp(self):
        self.tree = tempfile.mkdtemp(prefix="icon-check-")
        self.real_root = check_icons.ROOT
        check_icons.ROOT = self.tree
        self.addCleanup(self._restore)

    def _restore(self):
        check_icons.ROOT = self.real_root
        shutil.rmtree(self.tree, ignore_errors=True)

    def fixture(self, rel, text):
        path = os.path.join(self.tree, rel)
        directory = os.path.dirname(path)
        if not os.path.isdir(directory):
            os.makedirs(directory)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return rel

    def test_a_hand_drawn_drawable_is_flagged(self):
        rel = self.fixture(
            "android/app/src/main/res/drawable/ic_count_cluster.xml",
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <path android:fillColor="#FFFFFFFF"\n'
            '        android:pathData="M12,9m-2.6,0a2.6,2.6 0 1,0 5.2,0a2.6,2.6 0 1,0 -5.2,0" />\n'
            "</vector>\n")
        found = check_icons.violations_in(rel)
        self.assertTrue(found, "a hand-drawn drawable must be refused")
        self.assertEqual(found[0][1], 3, "the line number must point at the path")

    def test_a_hand_drawn_ios_glyph_is_flagged(self):
        rel = self.fixture("ios/Doorbell/Marks.swift",
                           "import UIKit\n"
                           "func draw() {\n"
                           "    let ring = UIBezierPath()\n"
                           "}\n")
        self.assertTrue(check_icons.violations_in(rel))

    def test_inline_web_svg_is_flagged(self):
        rel = self.fixture("webui/panel/hand.html",
                           "<div><svg viewBox='0 0 24 24'><path d='M0 0 L4 4'/></svg></div>\n")
        self.assertTrue(check_icons.violations_in(rel))

    def test_comments_are_not_code(self):
        # The defect this guards: a doc comment recording that the drawing was removed read as
        # drawing code, so following the rule and writing it down failed the build.
        swift = self.fixture(
            "ios/Doorbell/ClusterCounters.swift",
            "/// They used to be drawn here with UIBezierPath, which meant three glyphs nobody\n"
            "/// had reviewed. They are template images now.\n"
            "// UIBezierPath\n"
            "/* UIBezierPath\n"
            "   across two lines */\n"
            'let note = "removed the UIBezierPath drawing"\n'
            "final class ClusterIconView: UIView {}\n")
        self.assertEqual(check_icons.violations_in(swift), [])

        xml = self.fixture(
            "android/app/src/main/res/drawable/ic_commented.xml",
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- was <path android:pathData="M0 0" />, now generated -->\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android" />\n')
        self.assertEqual(check_icons.violations_in(xml), [])

    def test_a_url_is_not_a_comment(self):
        # "//" is a comment in the C family and the middle of every http:// URL everywhere else.
        rel = self.fixture(
            "android/app/src/main/res/drawable/ic_url.xml",
            '<vector xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <path android:pathData="M0 0 L4 4" />\n'
            "</vector>\n")
        self.assertTrue(check_icons.violations_in(rel), "a URL must not comment out the file")

    def test_markup_inside_a_script_string_is_still_seen(self):
        # A view file's strings are prose, but webui builds real markup in string literals:
        # blanking those would hide an icon typed out there by hand.
        rel = self.fixture("webui/admin/hand.js",
                           "var html = \"<svg viewBox='0 0 24 24'><path d='M0 0'/></svg>\";\n")
        self.assertTrue(check_icons.violations_in(rel))

    def test_a_missing_path_is_an_error(self):
        with self.assertRaises(FileNotFoundError):
            check_icons.violations_in("android/app/src/main/res/drawable/ic_not_here.xml")

    def test_generated_outputs_are_not_flagged(self):
        check_icons.ROOT = self.real_root
        for path in ("android/app/src/main/res/drawable/ic_tabler_door.xml",
                     "win/DoorbellApp/Resources/Icons.xaml",
                     "webui/icons/tabler-sprite.svg",
                     "webui/admin/index.html"):
            self.assertEqual(check_icons.violations_in(path), [], path)

    def test_the_repository_has_no_hand_drawn_icons(self):
        check_icons.ROOT = self.real_root
        result = subprocess.run([sys.executable, os.path.join(ROOT, "tools/check_icons.py")],
                                cwd=ROOT, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout.decode() + result.stderr.decode())

    def test_the_allow_list_carries_a_reason(self):
        for entry in check_icons.ALLOWED:
            self.assertEqual(len(entry), 2)
            self.assertTrue(entry[1].strip(), entry[0] + " needs a reason")


if __name__ == "__main__":
    unittest.main()
