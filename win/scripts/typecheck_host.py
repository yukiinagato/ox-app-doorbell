#!/usr/bin/env python3
"""Type-check the WPF shell's C# on a host without Windows.

Every .cs file of win/DoorbellApp is compiled (as a library, nothing is run) with Roslyn `csc`
against the .NET Framework 4.8 reference assemblies and the pinned ModernWpfUI package, with
one generated stub per XAML class that declares its x:Name fields the way the markup compiler
would. It catches wrong member names, missing usings and type errors in code-behind. It does
not compile XAML markup and proves nothing about run time; `win\\build.cmd` in CI stays the
real build.

The two packages are fetched only with --fetch, from nuget.org, into a cache directory outside
the repository, and their SHA-256 is checked before use:

    ModernWpfUI <version pinned in DoorbellApp.csproj>
    Microsoft.NETFramework.ReferenceAssemblies.net48 1.0.3

Without the packages the check is skipped (exit 0) unless --require is given, so it never
breaks a default test run on a machine that has not opted in.

    python3 win/scripts/typecheck_host.py --fetch     first use
    python3 win/scripts/typecheck_host.py             afterwards
"""

import argparse
import glob
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "win", "DoorbellApp")
DEFAULT_CACHE = os.path.join(os.path.expanduser("~"), "Library", "Caches",
                             "doorbell-win-typecheck")
REFERENCE_VERSION = "1.0.3"
# SHA-256 of the .nupkg files as published on nuget.org.
PINS = {
    ("modernwpfui", "0.9.6"):
        "776b93df90c50547f82035fa7259b3b7162b9a9712b2485b30d16bf53686cb1d",
    ("microsoft.netframework.referenceassemblies.net48", REFERENCE_VERSION):
        "8a7e348538e7eb91351696911689f49e3d4f63f8bab517432bbe159b8b1104a2",
}
XAML = "{http://schemas.microsoft.com/winfx/2006/xaml}"
PRESENTATION = "http://schemas.microsoft.com/winfx/2006/xaml/presentation"
MODERN = "http://schemas.modernwpf.com/2019"
# x:Name inside these belongs to a template's own namescope, not to the class.
TEMPLATE_SCOPES = ("Style", "ControlTemplate", "DataTemplate", "ItemsPanelTemplate")
FRAMEWORK_REFERENCES = (
    "mscorlib", "System", "System.Core", "System.Xaml", "WindowsBase", "PresentationCore",
    "PresentationFramework", "System.Web", "System.Web.Extensions", "System.Speech",
    "System.Management", "System.Windows.Forms", "System.Drawing", "Microsoft.CSharp",
    "System.Security", "System.Xml", "System.Xml.Linq", "System.Net.Http", "System.Data",
    "System.Configuration", "System.Runtime.Serialization", "UIAutomationProvider",
    "UIAutomationTypes",
)


def modern_wpf_version():
    with open(os.path.join(APP, "DoorbellApp.csproj"), encoding="utf-8") as handle:
        match = re.search(r'<PackageReference Include="ModernWpfUI" Version="([^"]+)"',
                          handle.read())
    if not match:
        raise SystemExit("typecheck_host: DoorbellApp.csproj does not pin ModernWpfUI")
    return match.group(1)


def package_dir(cache, name, version):
    return os.path.join(cache, name, version)


def fetch(cache, name, version):
    target = package_dir(cache, name, version)
    if os.path.isdir(target):
        return
    pin = PINS.get((name, version))
    if pin is None:
        raise SystemExit("typecheck_host: no checksum pinned for %s %s; add it to PINS after "
                         "verifying the package" % (name, version))
    url = "https://api.nuget.org/v3-flatcontainer/%s/%s/%s.%s.nupkg" % (
        name, version, name, version)
    print("typecheck_host: fetching %s %s from %s into %s" % (name, version, url, cache))
    os.makedirs(cache, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=cache, suffix=".nupkg", delete=False) as archive:
        with urllib.request.urlopen(url, timeout=120) as response:
            shutil.copyfileobj(response, archive)
        path = archive.name
    try:
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for block in iter(lambda: handle.read(1 << 20), b""):
                digest.update(block)
        if digest.hexdigest() != pin:
            raise SystemExit("typecheck_host: checksum mismatch for %s %s (got %s)" % (
                name, version, digest.hexdigest()))
        staging = target + ".tmp"
        shutil.rmtree(staging, ignore_errors=True)
        with zipfile.ZipFile(path) as package:
            package.extractall(staging)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        os.rename(staging, target)
    finally:
        os.remove(path)


def named_fields(element, fields):
    namespace, _, name = element.tag[1:].partition("}") if element.tag.startswith("{") \
        else ("", "", element.tag)
    if name in TEMPLATE_SCOPES or name.endswith(".Resources"):
        return
    field = element.get(XAML + "Name")
    if field:
        if namespace == MODERN:
            name = "ModernWpf.Controls." + name
        elif namespace.startswith("clr-namespace:"):
            name = namespace.split(":", 1)[1].split(";")[0] + "." + name
        fields.append((name, field))
    for child in element:
        named_fields(child, fields)


def write_stubs(directory):
    for path in sorted(glob.glob(os.path.join(APP, "**", "*.xaml"), recursive=True)):
        root = ET.parse(path).getroot()
        full_name = root.get(XAML + "Class")
        if not full_name:
            continue
        namespace, _, name = full_name.rpartition(".")
        fields = []
        for child in root:
            named_fields(child, fields)
        lines = ["using System.Windows; using System.Windows.Controls;",
                 "using System.Windows.Controls.Primitives; using System.Windows.Shapes;",
                 "using System.Windows.Media; using System.Windows.Documents;",
                 "namespace %s {" % namespace, "    public partial class %s {" % name]
        lines += ["        internal %s %s;" % field for field in fields]
        lines += ["        public void InitializeComponent() { }", "    }", "}", ""]
        with open(os.path.join(directory, full_name + ".g.cs"), "w", encoding="utf-8") as out:
            out.write("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--fetch", action="store_true",
                        help="download the two pinned NuGet packages into the cache if absent")
    parser.add_argument("--require", action="store_true",
                        help="fail instead of skipping when the packages or csc are absent")
    parser.add_argument("--cache", default=os.environ.get("DOORBELL_WIN_TYPECHECK_CACHE",
                                                          DEFAULT_CACHE),
                        help="package cache directory (default: %(default)s)")
    args = parser.parse_args()

    cache = os.path.abspath(args.cache)
    if os.path.commonpath([cache, ROOT]) == ROOT:
        raise SystemExit("typecheck_host: the cache must be outside the repository")
    packages = (("modernwpfui", modern_wpf_version()),
                ("microsoft.netframework.referenceassemblies.net48", REFERENCE_VERSION))
    if args.fetch:
        for name, version in packages:
            fetch(cache, name, version)
    missing = [("%s %s" % p) for p in packages if not os.path.isdir(package_dir(cache, *p))]
    compiler = shutil.which("csc")
    if missing or not compiler:
        reason = ("packages not in %s: %s (run with --fetch)" % (cache, ", ".join(missing))
                  if missing else "csc (Roslyn, e.g. from mono) is not on PATH")
        print("typecheck_host: SKIPPED, " + reason)
        return 1 if args.require else 0

    modern = os.path.join(package_dir(cache, *packages[0]), "lib", "net462")
    framework = os.path.join(package_dir(cache, *packages[1]), "build", ".NETFramework", "v4.8")
    print("typecheck_host: using packages cached in " + cache)
    with tempfile.TemporaryDirectory(prefix="doorbell-win-typecheck-") as work:
        write_stubs(work)
        sources = [path for path in glob.glob(os.path.join(APP, "**", "*.cs"), recursive=True)
                   if os.sep + "obj" + os.sep not in path and os.sep + "bin" + os.sep not in path]
        sources += glob.glob(os.path.join(work, "*.cs"))
        command = [compiler, "-nologo", "-langversion:7.3", "-target:library", "-nostdlib",
                   "-noconfig", "-out:" + os.path.join(work, "typecheck.dll"),
                   # Stub fields are never assigned; reference-assembly version unification.
                   "-nowarn:CS0649,CS0169,CS0414,CS1701,CS1702,CS0108"]
        command += ["-r:" + os.path.join(framework, name + ".dll")
                    for name in FRAMEWORK_REFERENCES
                    if os.path.exists(os.path.join(framework, name + ".dll"))]
        command += ["-r:" + path
                    for path in sorted(glob.glob(os.path.join(framework, "Facades", "*.dll")))]
        command += ["-r:" + os.path.join(modern, "ModernWpf.dll"),
                    "-r:" + os.path.join(modern, "ModernWpf.Controls.dll")]
        result = subprocess.run(command + sources, capture_output=True, text=True)
        errors = sorted({line.replace(ROOT + os.sep, "").replace(work + os.sep, "<xaml stub> ")
                         for line in (result.stdout + result.stderr).splitlines()
                         if ": error " in line})
    for line in errors:
        print(line)
    if errors or result.returncode != 0:
        print("typecheck_host: %d error(s)" % len(errors))
        return 1
    print("typecheck_host: %d C# files type-check against .NET Framework 4.8 and ModernWpfUI %s"
          % (len(sources), packages[0][1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
