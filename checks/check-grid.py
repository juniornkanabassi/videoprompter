#!/usr/bin/env python3
"""Fail on off-grid literal spacing in the audited application chrome."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = ["Camera/CameraPicker.swift", "Library/RelinkSheet.swift", "Library/LibraryView.swift", "Settings/SettingsView.swift", "Presenter/PresenterController.swift", "Presenter/ExposureLegend.swift", "Camera/CameraStageView.swift", "Library/LibraryStartView.swift", "Presenter/ReferenceMonitor.swift", "Settings/ShootSetup.swift"]
PATTERN = re.compile(r"(?:spacing:\s*|cornerRadius:\s*|\.padding\(\s*(?:\.[A-Za-z]+,\s*)?)(\d+(?:\.\d+)?)")
# Keep all three spellings covered: this lint used to silently miss colon spacing.
for sample, expected in [("HStack(spacing: 5)", "5"), ("RoundedRectangle(cornerRadius: 14)", "14"),
                         (".padding( 7)", "7"), (".padding(.horizontal, 6)", "6")]:
    match = PATTERN.search(sample)
    assert match and match[1] == expected, sample
def fixed_text_errors(source):
    """Follow modifiers belonging to literal Text, without leaking into the next view."""
    failures = []
    for text in re.finditer(r'Text\("((?:\\.|[^"\\])*)"\)', source):
        if not re.search(r'\w+\s+\w+', text[1]):
            continue
        cursor = text.end()
        while True:
            modifier = re.match(r'\s*\.(\w+)\(', source[cursor:])
            if not modifier:
                break
            start = cursor + modifier.end()
            end, depth, quoted, escaped = start, 1, False, False
            while end < len(source) and depth:
                char = source[end]
                if escaped:
                    escaped = False
                elif char == "\\" and quoted:
                    escaped = True
                elif char == '"':
                    quoted = not quoted
                elif not quoted:
                    depth += (char == "(") - (char == ")")
                end += 1
            arguments = source[start:end - 1].strip()
            if modifier[1] == "fixedSize" and (not arguments or re.search(r'horizontal:\s*true', arguments)):
                failures.append(source.count("\n", 0, cursor) + 1)
            cursor = end
    return failures

assert fixed_text_errors('Text("Two words").font(.body).fixedSize()')
assert fixed_text_errors('Text("Two words")\n.fixedSize(horizontal: true, vertical: false)')
assert not fixed_text_errors('Text("Two words").fixedSize(horizontal: false, vertical: true)')
assert not fixed_text_errors('Text("One").fixedSize()')
assert not fixed_text_errors('Text("Two words")\nButton("Next") {}.fixedSize()')

errors = []
for relative in FILES:
    path = ROOT / "Sources/VideoPrompter" / relative
    source = path.read_text()
    for number in fixed_text_errors(source):
        errors.append(f"{path.relative_to(ROOT)}:{number}: multiword Text must wrap instead of fixing its width")
    for number, line in enumerate(source.splitlines(), 1):
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
