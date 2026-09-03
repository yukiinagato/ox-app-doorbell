#!/usr/bin/env python3
"""Generate deterministic platform localization assets from strings.yaml.

The input is intentionally a restricted, dependency-free subset of YAML so the
generator also runs on legacy build hosts without PyYAML:

    key.path: { ja: "...", en: "...", zh: "..." }

Named placeholders use ``{name}``. Each renderer converts them to the native
platform format. Missing translations fall back to Japanese for compatibility
with the existing catalog; placeholder mismatches are fatal.
"""

import argparse
import json
import os
import re
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "i18n", "strings.yaml")
LANGS = ("ja", "en", "zh")
BASE = "ja"

LINE_RE = re.compile(r"^([A-Za-z0-9_.]+):\s*\{\s*(.*)\s*\}\s*$")
PAIR_RE = re.compile(r'(\w+):\s*"((?:[^"\\]|\\.)*)"')
PH_RE = re.compile(r"\{(\w+)\}")
OPTIONAL_MISSING_PREFIXES = (os.path.join(ROOT, "webui", "locale") + os.sep,)


class I18nError(Exception):
    """Raised when the restricted catalog format or translations are invalid."""


def parse(path):
    """Parse the restricted one-entry-per-line localization catalog."""
    entries = {}
    with open(path, encoding="utf-8") as source:
        for line_number, raw in enumerate(source, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            match = LINE_RE.match(line)
            if not match:
                raise I18nError(
                    f"{path}:{line_number}: unsupported catalog line: {line!r}"
                )
            key, body = match.group(1), match.group(2)
            if key in entries:
                raise I18nError(f"{path}:{line_number}: duplicate key: {key}")

            translations = {}
            cursor = 0
            for pair in PAIR_RE.finditer(body):
                if body[cursor:pair.start()].strip(" ,\t"):
                    raise I18nError(
                        f"{path}:{line_number}: unsupported mapping syntax for {key}"
                    )
                lang = pair.group(1)
                if lang not in LANGS:
                    raise I18nError(
                        f"{path}:{line_number}: unsupported language {lang!r} for {key}"
                    )
                if lang in translations:
                    raise I18nError(
                        f"{path}:{line_number}: duplicate language {lang!r} for {key}"
                    )
                try:
                    translations[lang] = json.loads('"' + pair.group(2) + '"')
                except ValueError as error:
                    raise I18nError(
                        f"{path}:{line_number}: invalid quoted text for {key}: {error}"
                    )
                cursor = pair.end()
            if body[cursor:].strip(" ,\t"):
                raise I18nError(
                    f"{path}:{line_number}: unsupported mapping syntax for {key}"
                )
            if BASE not in translations:
                raise I18nError(
                    f"{path}:{line_number}: {key} is missing base language {BASE!r}"
                )
            entries[key] = translations
    return entries


def validate(entries):
    """Validate translation coverage and placeholder parity."""
    errors = []
    for key, translations in entries.items():
        base_placeholders = sorted(PH_RE.findall(translations[BASE]))
        for lang in LANGS:
            if lang not in translations:
                print(
                    f"warning: {key} has no {lang} translation; using {BASE}",
                    file=sys.stderr,
                )
                continue
            if sorted(PH_RE.findall(translations[lang])) != base_placeholders:
                errors.append(f"{key}: placeholder mismatch in {lang}")
    if errors:
        raise I18nError("\n".join(errors))


def text(entries, key, lang):
    """Return one translation, applying the catalog's base-language fallback."""
    return entries[key].get(lang, entries[key][BASE])


def xml_escape(value):
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "\\'")
    )


def objective_c_escape(value):
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def add_output(outputs, relative_path, content):
    outputs[os.path.join(ROOT, *relative_path.split("/"))] = content


def render_web(entries, outputs):
    for lang in LANGS:
        data = {key: text(entries, key, lang) for key in sorted(entries)}
        add_output(
            outputs,
            f"webui/locale/{lang}.json",
            json.dumps(data, ensure_ascii=False, indent=1) + "\n",
        )


def to_android(value):
    order = []

    def replace_placeholder(match):
        name = match.group(1)
        if name not in order:
            order.append(name)
        return f"%{order.index(name) + 1}$s"

    # Android formats a resource only when arguments are passed (getString(id, args)), and that path
    # runs the value through String.format: a literal '%' next to a placeholder (e.g. "{n}%") must be
    # doubled or the lookup throws and the raw key leaks into the UI. Placeholder-free strings are
    # returned verbatim by getString(id), so their '%' must stay single.
    if PH_RE.search(value):
        value = value.replace("%", "%%")
    return PH_RE.sub(replace_placeholder, value)


def render_android(entries, outputs):
    for lang in LANGS:
        suffix = "" if lang == "en" else f"-{lang}"
        lines = [
            '<?xml version="1.0" encoding="utf-8"?>',
            "<!-- Generated by tools/gen_i18n.py from i18n/strings.yaml; do not edit.",
            "     Changes made here will be overwritten by the next generation. -->",
            "<resources>",
        ]
        for key in sorted(entries):
            name = key.replace(".", "_")
            value = xml_escape(to_android(text(entries, key, lang)))
            lines.append(f'    <string name="{name}">{value}</string>')
        lines.append("</resources>\n")
        add_output(
            outputs,
            f"android/app/src/main/res/values{suffix}/strings.xml",
            "\n".join(lines),
        )


def render_ios(entries, outputs):
    for lang in LANGS:
        lines = ["/* Generated by tools/gen_i18n.py; do not edit. */"]
        for key in sorted(entries):
            value = PH_RE.sub("%@", text(entries, key, lang))
            lines.append(f'"{key}" = "{objective_c_escape(value)}";')
        add_output(
            outputs,
            f"ios/Doorbell/{lang}.lproj/Localizable.strings",
            "\n".join(lines) + "\n",
        )


def render_objective_c_dictionary(entries, outputs):
    header = """/* Generated by tools/gen_i18n.py; do not edit. */
#import <Foundation/Foundation.h>

NSDictionary *DBGeneratedStringsForLanguage(NSString *language);
"""
    lines = [
        "/* Generated by tools/gen_i18n.py; do not edit. */",
        '#import "DBGeneratedStrings.h"',
        "#import <dispatch/dispatch.h>",
        "",
    ]
    function_names = {"ja": "Japanese", "en": "English", "zh": "Chinese"}
    for lang in LANGS:
        function_name = function_names[lang]
        lines.extend(
            [
                f"static NSDictionary *DBGenerated{function_name}Strings(void) {{",
                "  static NSDictionary *strings = nil;",
                "  static dispatch_once_t onceToken;",
                "  dispatch_once(&onceToken, ^{",
                "    strings = [[NSDictionary alloc] initWithObjectsAndKeys:",
            ]
        )
        for key in sorted(entries):
            value = objective_c_escape(text(entries, key, lang))
            lines.append(f'      @"{value}", @"{key}",')
        lines.extend(["      nil];", "  });", "  return strings;", "}", ""])

    lines.extend(
        [
            "NSDictionary *DBGeneratedStringsForLanguage(NSString *language) {",
            '  if ([language isEqualToString:@"en"]) return DBGeneratedEnglishStrings();',
            '  if ([language isEqualToString:@"zh"]) return DBGeneratedChineseStrings();',
            "  return DBGeneratedJapaneseStrings();",
            "}",
            "",
        ]
    )
    add_output(outputs, "ios-kiosk/src/Core/DBGeneratedStrings.h", header)
    add_output(
        outputs,
        "ios-kiosk/src/Core/DBGeneratedStrings.m",
        "\n".join(lines),
    )


def to_dotnet(value):
    order = []

    def replace_placeholder(match):
        name = match.group(1)
        if name not in order:
            order.append(name)
        return "{%d}" % order.index(name)

    return PH_RE.sub(replace_placeholder, value)


RESX_HEAD = """<?xml version="1.0" encoding="utf-8"?>
<root>
  <resheader name="resmimetype"><value>text/microsoft-resx</value></resheader>
  <resheader name="version"><value>2.0</value></resheader>
  <resheader name="reader"><value>System.Resources.ResXResourceReader, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>
  <resheader name="writer"><value>System.Resources.ResXResourceWriter, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>
"""


def render_windows(entries, outputs):
    for lang in LANGS:
        filename = "Strings.resx" if lang == "ja" else f"Strings.{lang}.resx"
        parts = [RESX_HEAD]
        for key in sorted(entries):
            name = key.replace(".", "_")
            value = xml_escape(to_dotnet(text(entries, key, lang))).replace("\\'", "'")
            parts.append(
                f'  <data name="{name}" xml:space="preserve"><value>{value}</value></data>\n'
            )
        parts.append("</root>\n")
        add_output(
            outputs,
            f"win/DoorbellApp/Resources/{filename}",
            "".join(parts),
        )


def render_all(entries):
    outputs = {}
    render_web(entries, outputs)
    render_android(entries, outputs)
    render_ios(entries, outputs)
    render_objective_c_dictionary(entries, outputs)
    render_windows(entries, outputs)
    return outputs


def relative(path):
    return os.path.relpath(path, ROOT)


def check_outputs(outputs):
    stale = []
    for path, expected in sorted(outputs.items()):
        try:
            with open(path, encoding="utf-8") as current_file:
                current = current_file.read()
        except OSError:
            if path.startswith(OPTIONAL_MISSING_PREFIXES):
                continue
            stale.append((path, "missing"))
            continue
        if current != expected:
            stale.append((path, "stale"))
    if stale:
        for path, reason in stale:
            print(f"{relative(path)}: {reason}; run tools/gen_i18n.py", file=sys.stderr)
        return False
    print(f"gen_i18n: {len(outputs)} generated files are current")
    return True


def write_outputs(outputs):
    changed = 0
    for path, content in sorted(outputs.items()):
        current = None
        try:
            with open(path, encoding="utf-8") as current_file:
                current = current_file.read()
        except OSError:
            pass
        if current == content:
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        temporary = path + ".tmp"
        with open(temporary, "w", encoding="utf-8", newline="\n") as output:
            output.write(content)
        os.replace(temporary, path)
        changed += 1
        print(f"generated {relative(path)}")
    print(f"gen_i18n: {changed} of {len(outputs)} files updated")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail without writing when a generated file is missing or stale",
    )
    args = parser.parse_args(argv)
    try:
        entries = parse(SRC)
        validate(entries)
        outputs = render_all(entries)
    except I18nError as error:
        print(f"gen_i18n: {error}", file=sys.stderr)
        return 1
    if args.check:
        return 0 if check_outputs(outputs) else 1
    write_outputs(outputs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
