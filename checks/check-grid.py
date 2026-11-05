#!/usr/bin/env python3
"""Fail on off-grid literal spacing in the audited application chrome."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = ["Camera/CameraPicker.swift", "Library/RelinkSheet.swift", "Library/LibraryView.swift", "Settings/SettingsView.swift", "Presenter/PresenterController.swift"]
PATTERN = re.compile(r"(?:spacing:\s*|cornerRadius:\s*|\.padding\(\s*(?:\.[A-Za-z]+,\s*)?)(\d+(?:\.\d+)?)")
# Keep all three spellings covered: this lint used to silently miss colon spacing.
for sample, expected in [("HStack(spacing: 5)", "5"), ("RoundedRectangle(cornerRadius: 14)", "14"),
                         (".padding( 7)", "7"), (".padding(.horizontal, 6)", "6")]:
    match = PATTERN.search(sample)
    assert match and match[1] == expected, sample
errors = []
for relative in FILES:
    path = ROOT / "Sources/VideoPrompter" / relative
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if "grid: ok" in line:
            continue
        for match in PATTERN.finditer(line):
            value = float(match[1])
            if value not in (0, 1, 2) and value % 4:
                errors.append(f"{path.relative_to(ROOT)}:{number}: off-grid spacing {match[1]}: {line.strip()}")
if errors:
    print("\n".join(errors))
    print(f"FAIL grid: {len(errors)} off-grid values")
    sys.exit(1)
print(f"PASS grid: {len(FILES)} audited chrome files")
