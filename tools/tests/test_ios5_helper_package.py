import gzip
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "ios-compat" / "tools" / "package_helper_deb.py"
SPEC = importlib.util.spec_from_file_location("package_helper_deb", MODULE_PATH)
assert SPEC and SPEC.loader
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


def ar_members(data: bytes) -> dict[str, bytes]:
    if not data.startswith(b"!<arch>\n"):
        raise AssertionError("not an ar archive")
    offset = 8
    members: dict[str, bytes] = {}
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise AssertionError("bad ar header")
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58].decode().strip())
        offset += 60
        members[name] = data[offset:offset + size]
        offset += size + (size % 2)
    return members


def tar_entries(compressed: bytes) -> dict[str, tarfile.TarInfo]:
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
        raw = stream.read()
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        return {entry.name: entry for entry in archive.getmembers()}


class Ios5HelperPackageTests(unittest.TestCase):
    def test_package_stages_fixed_files_without_enabling_launchd(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "doorbell-keepalive"
            helper.write_bytes(b"\xce\xfa\xed\xfehelper")
            template = root / "helper.plist"
            template.write_text("<plist><dict/></plist>\n", encoding="utf-8")
            output = root / "helper.deb"
            second_output = root / "helper-second.deb"
            PACKAGE.make_package(helper, template, output, "0.3.0")
            PACKAGE.make_package(helper, template, second_output, "0.3.0")

            self.assertEqual(output.read_bytes(), second_output.read_bytes())

            members = ar_members(output.read_bytes())
            self.assertEqual(set(members), {"debian-binary", "control.tar.gz", "data.tar.gz"})
            control = tar_entries(members["control.tar.gz"])
            data = tar_entries(members["data.tar.gz"])
            self.assertIn("./control", control)
            self.assertIn("./postinst", control)
            self.assertIn("./prerm", control)
            self.assertEqual(control["./postinst"].mode, 0o755)
            self.assertEqual(control["./prerm"].mode, 0o755)
            self.assertIn("./usr/local/libexec/doorbell-keepalive", data)
            self.assertEqual(data["./usr/local/libexec/doorbell-keepalive"].mode, 0o755)
            self.assertIn(
                "./usr/local/share/doorbell/jp.keihan.doorbell.keepalive.plist", data
            )
            self.assertNotIn("./Library/LaunchDaemons/jp.keihan.doorbell.keepalive.plist", data)

    def test_installer_requires_explicit_enable_and_uses_fixed_paths(self) -> None:
        installer = (ROOT / "ios-compat" / "scripts" / "install_helper_ios5.sh").read_text()
        self.assertIn('DB_CONFIRM_ROOT_HELPER:-}" == "YES"', installer)
        self.assertIn("refusing to replace a different active helper definition", installer)
        self.assertIn("/usr/local/libexec/doorbell-keepalive", installer)
        self.assertIn("/Library/LaunchDaemons/jp.keihan.doorbell.keepalive.plist", installer)
        self.assertIn("set SSHPASS to the device's commissioned root SSH password", installer)
        self.assertNotIn("SSHPASS:-alpine", installer)
        self.assertNotIn("rm -rf", installer)


if __name__ == "__main__":
    unittest.main()
