#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


modern = source("ios/Doorbell/UIStyleApplier.swift")
runtime = source("ios/Doorbell/RuntimeSupervisor.swift")
compat = source("ios-kiosk/src/Core/DBSemanticStyle.m")
delegate = source("ios-kiosk/src/Support/DBAppDelegate.m")

for field in ("schema_version", "applied", "rejected", "last_known_good",
              "last_error", "updated_at_ms", "elements"):
    assert f'"{field}"' in modern, field
    assert f'@"{field}"' in compat, field

assert "validationError(proposed" in modern
assert "baseline.foreground" in modern and "baseline.validationBackground" in modern
assert 'source = "last_known_good"' in modern
assert "last_known_good_persist_failed" in modern
assert "scale < 1" in modern and "fontScale < 1" in modern and "44 / smallest" in modern
assert "validationBackground" in modern and "effectiveBackground(for: view)" in modern
assert '"ui_style": UIStyleApplier.runtimeReport()' in runtime
assert "UIStyleApplier.reportChanged" in runtime
assert "if supportsUiManifest { publishUiManifest() }" in runtime

assert "DBSemanticStyleValid(proposed" in compat
assert "baseForeground" in compat and "baseBackground" in compat
assert '@"last_known_good"' in compat
assert "last_known_good_persist_failed" in compat
assert "safetyCritical && number < 1.0" in compat
assert "DBSemanticStyleValid(saved" in compat
assert 'setRuntimeStatusSection:@"ui_style"' in delegate
assert "if (DBSupportsUIManifest(_boot.role))" in delegate

print("semantic UI runtime contract tests passed")
