#!/usr/bin/env python3
"""Check literal SwiftUI spacing and dimensions in all Mac and iPad source files."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
# Ignore comments and strings without changing line numbers, including Markdown examples.
NON_CODE = re.compile(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"', re.S)
NUMBER = r'(-?\d+(?:\.\d+)?)(?![\w.])'
SPACING = re.compile(r'(?:\b(?:spacing|cornerRadius|minLength)\s*:\s*|\.padding\(\s*(?:\.[A-Za-z]+\s*,\s*)?)' + NUMBER)
FRAME = re.compile(r'\.(?:frame|defaultSize)\s*\(([^()]*)\)', re.S)
DIMENSION = re.compile(r'\b(?:width|height|minWidth|maxWidth|minHeight|maxHeight)\s*:\s*' + NUMBER)
EXCEPTION = re.compile(r'//\s*grid: ok\s+\S.*')


def source_files(root):
    # Check all Swift, rather than guessing view filenames; new views cannot silently escape.
    return sorted(path for folder in ('Sources', 'iPad') for path in (root / folder).rglob('*.swift'))


def violations(text):
    code = NON_CODE.sub(lambda m: re.sub(r'[^\n]', ' ', m[0]), text)
    lines = text.splitlines()
    matches = list(SPACING.finditer(code))
    for frame in FRAME.finditer(code):
        matches.extend((match, frame.start(1)) for match in DIMENSION.finditer(frame[1]))
    errors = []
    for item in matches:
        match, base = item if isinstance(item, tuple) else (item, 0)
        value = float(match[1])
        if abs(value) in (0, 1, 2) or value % 4 == 0:
            continue
        line = code.count('\n', 0, base + match.start(1)) + 1
        if not EXCEPTION.search(lines[line - 1]):
            errors.append((line, match[1]))
    return errors


def main():
    paths = source_files(ROOT)
    errors = []
    for path in paths:
        for line, value in violations(path.read_text()):
            errors.append(f'{path.relative_to(ROOT)}:{line}: off-grid value {value} (use the grid or // grid: ok <reason>)')
    if errors:
        print('\n'.join(errors))
        print(f'FAIL grid: {len(errors)} off-grid values')
        return 1
    print(f'PASS grid: {len(paths)} Swift source files (Mac and iPad)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
