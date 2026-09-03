#!/usr/bin/env python3
"""Cross-platform contract checks for native theme asset retrieval."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]

# Where each native shell keeps the sources that may perform the theme asset request, and the
# extension its own language uses. Naming one file per shell does not hold: the Swift shell moved
# the request out of MainViewController and into DoorbellTheme's background view, so every panel
# wears the theme rather than only the home screen. The contract therefore finds whichever file
# makes the request and holds that one to the rule.
NATIVE_SHELLS = {
    "android": ("android/app/src/main/java/jp/ox/doorbell", "*.kt"),
    "ios": ("ios", "*.swift"),
    "ios-kiosk": ("ios-kiosk/src", "*.m"),
    "win": ("win/DoorbellApp", "*.cs"),
}

# A node's own asset endpoint, served by its Core over loopback.
ASSET_ENDPOINT = "/asset/"

# The web panel's session credential: a token out of the stored panel.tokens, or the ?k= query it
# travels in. A native shell holds no panel session, and a theme picture must never be fetched
# with one -- that would put a credential in a URL and widen the asset request into an
# authenticated one.
CREDENTIAL_MARKERS = ("panel.tokens", "?k=")


def asset_sources(directory, pattern):
    """Every source under `directory` that requests an asset from the node's own endpoint."""
    root = ROOT / directory
    return sorted(
        path
        for path in root.rglob(pattern)
        if "build" not in path.relative_to(root).parts
        and ASSET_ENDPOINT in path.read_text(encoding="utf-8")
    )


class NativeAssetContract(unittest.TestCase):
    def test_every_native_shell_fetches_theme_assets_from_its_own_node(self):
        for shell, (directory, pattern) in NATIVE_SHELLS.items():
            with self.subTest(shell=shell):
                self.assertTrue(
                    asset_sources(directory, pattern),
                    f"no {pattern} source under {directory} requests {ASSET_ENDPOINT}",
                )

    def test_native_theme_requests_do_not_use_panel_credentials(self):
        for shell, (directory, pattern) in NATIVE_SHELLS.items():
            for path in asset_sources(directory, pattern):
                relative = path.relative_to(ROOT).as_posix()
                with self.subTest(source=relative):
                    source = path.read_text(encoding="utf-8")
                    for marker in CREDENTIAL_MARKERS:
                        # Asserted on the boolean rather than with assertNotIn, whose failure
                        # message would print the whole source file into the CI log.
                        self.assertFalse(
                            marker in source,
                            f"{relative} requests {ASSET_ENDPOINT} and carries the panel "
                            f"credential {marker!r}",
                        )


if __name__ == "__main__":
    unittest.main()
