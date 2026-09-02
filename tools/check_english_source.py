#!/usr/bin/env python3
"""Reject newly added non-English developer text in source files.

By default the checker examines added working-tree lines relative to ``HEAD``,
including staged, unstaged, and untracked files. ``--base REV`` is suitable for
a clean CI checkout because it examines additions between REV and the current
tree. ``--all`` audits every eligible file and is intentionally stricter than
the incremental gate.

Localization assets, vendor code, licenses, explicitly localized documents, and the frozen
``ios-legacy`` archival snapshot are excluded. Normal application source is checked for comments
and log calls; tests and scripts are checked on every added line.
"""

import argparse
import os
import re
import subprocess
import sys
import unicodedata


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SOURCE_EXTENSIONS = {
    ".c",
    ".cc",
    ".cpp",
    ".cxx",
    ".h",
    ".hh",
    ".hpp",
    ".m",
    ".mm",
    ".swift",
    ".java",
    ".kt",
    ".kts",
    ".cs",
    ".fs",
    ".go",
    ".rs",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
    ".html",
    ".css",
    ".scss",
    ".xml",
    ".xaml",
    ".py",
    ".rb",
    ".pl",
    ".php",
    ".sh",
    ".bash",
    ".zsh",
    ".fish",
    ".ps1",
    ".bat",
    ".cmd",
    ".gradle",
    ".cmake",
    ".mk",
    ".yaml",
    ".yml",
}
SCRIPT_EXTENSIONS = {
    ".py",
    ".rb",
    ".pl",
    ".php",
    ".sh",
    ".bash",
    ".zsh",
    ".fish",
    ".ps1",
    ".bat",
    ".cmd",
    ".gradle",
    ".cmake",
    ".mk",
}
BUILD_FILENAMES = {
    "cmakelists.txt",
    "makefile",
    "gnumakefile",
    "dockerfile",
    "gradlew",
}
EXCLUDED_PARTS = {
    ".git",
    ".gradle",
    ".idea",
    ".vscode",
    "build",
    "dist",
    "deriveddata",
    "node_modules",
    "pods",
    "carthage",
    "third_party",
    "third-party",
    "vendor",
    "vendors",
    "external",
    "deps",
    "licenses",
}
LICENSE_NAMES = {
    "license",
    "license.txt",
    "license.md",
    "copying",
    "copying.txt",
    "notice",
    "notice.txt",
    "authors",
}
HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")
LOG_RE = re.compile(
    r"(?:\bNSLog\s*\(|\bLog\s*\.\s*[vdiwe]\s*\(|"
    r"\b(?:logger|logging|console)\s*\.\s*\w+\s*\(|"
    r"\b(?:print|printf|fprintf|puts|syslog)\s*\(|"
    r"\b(?:DB_LOG[A-Z]*|LOG_[A-Z]+)\s*\()"
)
SHELL_LOG_RE = re.compile(r"^\s*(?:echo|printf|Write-(?:Host|Error|Warning))\b")
TEST_NAME_RE = re.compile(
    r"(?:\b(?:TEST|TEST_F|TEST_P|TEST_CASE|SECTION|SCENARIO)\s*\(|"
    r"(?<![.\w])(?:describe|context|it|test)\s*\(|"
    r"\b(?:def|func)\s+test\w*|\bfun\s+(?:`[^`]+`|test\w*))"
)


class CheckError(Exception):
    """Raised when repository state cannot be inspected safely."""


def normalized_path(path):
    value = path.replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value


def is_localization_asset(path):
    value = normalized_path(path)
    lower = value.lower()
    parts = lower.split("/")
    name = parts[-1]
    if parts[0] == "i18n" or "locale" in parts or "locales" in parts:
        return True
    if any(part.endswith(".lproj") for part in parts):
        return True
    if name == "localizable.strings":
        return True
    if name == "strings.xml" and any(part.startswith("values") for part in parts):
        return True
    if name.startswith("strings.") and name.endswith(".resx"):
        return True
    if name == "strings.resx":
        return True
    if name in {"dbgeneratedstrings.h", "dbgeneratedstrings.m"}:
        return True
    return False


def is_excluded(path):
    value = normalized_path(path)
    lower = value.lower()
    parts = lower.split("/")
    name = parts[-1]
    if any(part in EXCLUDED_PARTS for part in parts):
        return True
    if name in LICENSE_NAMES or name.startswith("license."):
        return True
    if lower.startswith("docs/ja/") or lower.startswith("docs/zh/"):
        return True
    if lower.startswith("ios-legacy/"):
        return True
    if lower.endswith(".ja.md") or lower.endswith(".zh.md"):
        return True
    return is_localization_asset(value)


def is_candidate(path):
    if is_excluded(path):
        return False
    name = os.path.basename(path).lower()
    extension = os.path.splitext(name)[1]
    return extension in SOURCE_EXTENSIONS or name in BUILD_FILENAMES


def is_test(path):
    value = normalized_path(path).lower()
    parts = value.split("/")
    name = parts[-1]
    stem = os.path.splitext(name)[0]
    return (
        any(part in {"test", "tests", "__tests__"} for part in parts[:-1])
        or stem.startswith("test_")
        or stem.endswith("_test")
        or ".test." in name
        or ".spec." in name
    )


def is_script(path):
    value = normalized_path(path).lower()
    name = os.path.basename(value)
    extension = os.path.splitext(name)[1]
    return (
        extension in SCRIPT_EXTENSIONS
        or name in BUILD_FILENAMES
        or value.startswith(".github/workflows/")
        or "/scripts/" in "/" + value
    )


def has_non_english_letter(value):
    return any(
        ord(character) > 127 and unicodedata.category(character).startswith("L")
        for character in value
    )


def is_comment_line(line):
    stripped = line.lstrip()
    if stripped.startswith(("//", "/*", "*/", "* ", "<!--", "# ", "#\t")):
        return True
    if stripped.lower().startswith("rem "):
        return True
    if stripped.startswith("#pragma mark"):
        return True
    return "//" in line or "/*" in line or "<!--" in line


def violation_reason(path, line):
    if not has_non_english_letter(line):
        return None
    if "english-source: allow" in line:
        return None
    if is_test(path):
        if is_comment_line(line):
            return "non-English developer comment in test"
        if LOG_RE.search(line) or SHELL_LOG_RE.search(line):
            return "non-English developer log in test"
        if TEST_NAME_RE.search(line):
            return "non-English test name"
        return None
    if is_script(path):
        return "non-English text in script or build source"
    if is_comment_line(line):
        return "non-English developer comment"
    if LOG_RE.search(line) or SHELL_LOG_RE.search(line):
        return "non-English log message"
    return None


def parse_added_lines(patch):
    """Yield (path, line number, text) tuples for additions in a Git patch."""
    path = None
    line_number = 0
    for raw in patch.splitlines():
        if raw.startswith("+++ "):
            path = raw[4:]
            if path.startswith("b/"):
                path = path[2:]
            if path == "/dev/null":
                path = None
            continue
        hunk = HUNK_RE.match(raw)
        if hunk:
            line_number = int(hunk.group(1))
            continue
        if path is None or raw.startswith("\\ No newline"):
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            yield path, line_number, raw[1:]
            line_number += 1
        elif raw.startswith(" "):
            line_number += 1


def run_git(arguments):
    process = subprocess.run(
        ["git", "-c", "core.quotepath=false"] + arguments,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        message = process.stderr.decode("utf-8", "replace").strip()
        raise CheckError(message or "Git command failed")
    return process.stdout


def untracked_paths():
    output = run_git(["ls-files", "--others", "--exclude-standard", "-z"])
    return [item.decode("utf-8", "surrogateescape") for item in output.split(b"\0") if item]


def all_paths():
    output = run_git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    return [item.decode("utf-8", "surrogateescape") for item in output.split(b"\0") if item]


def file_lines(path):
    absolute = os.path.join(ROOT, path)
    try:
        with open(absolute, "rb") as source:
            raw = source.read()
    except OSError:
        return []
    if b"\0" in raw:
        return []
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError:
        return []
    return list(enumerate(value.splitlines(), 1))


def changed_lines(base):
    patch = run_git(
        [
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--unified=0",
            "--diff-filter=ACMR",
            base,
            "--",
        ]
    ).decode("utf-8", "surrogateescape")
    yield from parse_added_lines(patch)
    for path in untracked_paths():
        for line_number, line in file_lines(path):
            yield path, line_number, line


def audit_lines():
    for path in all_paths():
        for line_number, line in file_lines(path):
            yield path, line_number, line


def find_violations(lines):
    violations = []
    for path, line_number, line in lines:
        if not is_candidate(path):
            continue
        reason = violation_reason(path, line)
        if reason:
            violations.append((normalized_path(path), line_number, reason))
    return sorted(set(violations))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--base",
        metavar="REV",
        help="check added lines between REV and the current working tree",
    )
    group.add_argument(
        "--all",
        action="store_true",
        help="audit every eligible tracked and untracked source file",
    )
    args = parser.parse_args(argv)
    try:
        lines = audit_lines() if args.all else changed_lines(args.base or "HEAD")
        violations = find_violations(lines)
    except CheckError as error:
        print(f"check_english_source: {error}", file=sys.stderr)
        return 2
    for path, line_number, reason in violations:
        print(f"{path}:{line_number}: {reason}")
    if violations:
        print(
            f"check_english_source: {len(violations)} violation(s)",
            file=sys.stderr,
        )
        return 1
    print("check_english_source: no violations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
