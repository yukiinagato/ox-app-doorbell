import os
import tempfile
import unittest

import sys


TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import check_english_source as english_source
import gen_i18n


class GeneratorTests(unittest.TestCase):
    def parse_catalog(self, content):
        handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False)
        try:
            handle.write(content)
            handle.close()
            return gen_i18n.parse(handle.name)
        finally:
            try:
                os.unlink(handle.name)
            except OSError:
                pass

    def test_parses_escapes_and_renders_legacy_objective_c_dictionary(self):
        entries = self.parse_catalog(
            r'sample.key: { ja: "\u65e5 {name}", en: "Hello {name}", zh: "\u4e2d {name}" }'
            "\n"
        )
        gen_i18n.validate(entries)
        outputs = {}
        gen_i18n.render_objective_c_dictionary(entries, outputs)
        implementation = outputs[
            os.path.join(gen_i18n.ROOT, "ios-kiosk", "src", "Core", "DBGeneratedStrings.m")
        ]
        self.assertIn("initWithObjectsAndKeys", implementation)
        self.assertIn(chr(0x65E5) + " {name}", implementation)
        self.assertNotIn("@{", implementation)

    def test_rejects_placeholder_mismatch(self):
        entries = {
            "sample": {"ja": "{name}", "en": "plain", "zh": "{name}"}
        }
        with self.assertRaises(gen_i18n.I18nError):
            gen_i18n.validate(entries)

    def test_rejects_duplicate_catalog_keys(self):
        with self.assertRaises(gen_i18n.I18nError):
            self.parse_catalog(
                'sample: { ja: "a", en: "a", zh: "a" }\n'
                'sample: { ja: "b", en: "b", zh: "b" }\n'
            )


class EnglishSourceTests(unittest.TestCase):
    def test_detects_letters_but_allows_unicode_punctuation(self):
        self.assertFalse(english_source.has_non_english_letter("English — still English"))
        self.assertTrue(english_source.has_non_english_letter(chr(0x65E5)))

    def test_classifies_comments_logs_test_names_and_scripts(self):
        foreign = chr(0x65E5) + chr(0x672C) + chr(0x8A9E)
        self.assertEqual(
            "non-English developer comment",
            english_source.violation_reason("core/source.cpp", "// " + foreign),
        )
        self.assertEqual(
            "non-English log message",
            english_source.violation_reason("core/source.cpp", 'printf("' + foreign + '");'),
        )
        self.assertEqual(
            "non-English log message",
            english_source.violation_reason("core/source.cpp", 'DB_LOGW(tag, "' + foreign + '");'),
        )
        self.assertEqual(
            "non-English test name",
            english_source.violation_reason(
                "core/tests/source_test.cpp", 'TEST_CASE("' + foreign + '")'
            ),
        )
        self.assertEqual(
            "non-English text in script or build source",
            english_source.violation_reason("tools/build.py", foreign),
        )
        self.assertIsNone(
            english_source.violation_reason("core/source.cpp", 'label = @"' + foreign + '";')
        )
        self.assertIsNone(
            english_source.violation_reason(
                "core/tests/source_test.cpp", 'const char *fixture = "' + foreign + '";'
            )
        )
        self.assertIsNone(
            english_source.violation_reason(
                "web/tests/source.test.js", 'assert(/' + foreign + '/.test(message));'
            )
        )

    def test_excludes_localizations_vendor_licenses_and_localized_docs(self):
        excluded = [
            "i18n/strings.yaml",
            "android/app/src/main/res/values-ja/strings.xml",
            "ios/Doorbell/ja.lproj/Localizable.strings",
            "ios-kiosk/src/Core/DBGeneratedStrings.m",
            "vendor/library/source.cpp",
            "third_party/library/source.cpp",
            "LICENSE",
            "docs/ja/setup.md",
            "docs/guide.zh.md",
            "ios-legacy/Doorbell/DBAppDelegate.m",
        ]
        for path in excluded:
            self.assertTrue(english_source.is_excluded(path), path)

    def test_parses_added_line_numbers(self):
        patch = """diff --git a/source.cpp b/source.cpp
--- a/source.cpp
+++ b/source.cpp
@@ -4,0 +5,2 @@
+first
+second
"""
        self.assertEqual(
            [("source.cpp", 5, "first"), ("source.cpp", 6, "second")],
            list(english_source.parse_added_lines(patch)),
        )


if __name__ == "__main__":
    unittest.main()
