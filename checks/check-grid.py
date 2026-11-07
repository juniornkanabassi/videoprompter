#!/usr/bin/env python3
"""Check literal SwiftUI spacing and dimensions in all Mac and iPad source files."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
NUMBER = re.compile(r'(?<![\w.])-?\d+(?:\.\d+)?(?![\w.])')
CALL = re.compile(r'\.(?:padding|frame|defaultSize|cornerRadius)\s*\(')
SPACING = re.compile(r'\b(?:spacing|horizontalSpacing|verticalSpacing|cornerRadius|minLength)\s*:\s*')
EXCEPTION = re.compile(r'//\s*grid: ok\s+\S.*')


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


def code_only(text):
    """Blank comments and strings, preserving offsets and code in interpolations."""
    result = list(text)

    def blank(start, end):
        for i in range(start, end):
            if text[i] != '\n': result[i] = ' '

    def scan(start, interpolation=False):
        i, depth = start, 1
        while i < len(text):
            if text.startswith('//', i):
                end = text.find('\n', i)
                end = len(text) if end < 0 else end
                blank(i, end); i = end
            elif text.startswith('/*', i):
                begin, nesting = i, 1
                i += 2
                while i < len(text) and nesting:
                    if text.startswith('/*', i): nesting += 1; i += 2
                    elif text.startswith('*/', i): nesting -= 1; i += 2
                    else: i += 1
                blank(begin, i)
            elif text[i] == '"' or (text[i] == '#' and re.match(r'#+"', text[i:])):
                match = re.match(r'(#{0,})((?:"""|"))', text[i:])
                hashes, quote = match.groups()
                end_quote, escape = quote + hashes, '\\' + hashes
                begin = i; i += len(hashes) + len(quote)
                while i < len(text):
                    if text.startswith(end_quote, i):
                        i += len(end_quote); blank(begin, i); break
                    if text.startswith(escape + '(', i):
                        blank(begin, i + len(escape))
                        i = scan(i + len(escape) + 1, True)
                        begin = i
                    elif text.startswith(escape, i): i += len(escape) + 1
                    else: i += 1
                else: blank(begin, i)
            else:
                if interpolation:
                    if text[i] == '(': depth += 1
                    elif text[i] == ')':
                        depth -= 1
                        if depth == 0: return i + 1
                i += 1
        return i

    scan(0)
    return ''.join(result)


def expression_end(code, start, whole_call=False):
    depth = 0
    for i in range(start, len(code)):
        if code[i] in '([{': depth += 1
        elif code[i] in ')]}':
            if depth == 0: return i
            depth -= 1
        elif code[i] == ',' and depth == 0 and not whole_call: return i
    return len(code)


def source_files(root):
    # Check all Swift, rather than guessing view filenames; new views cannot silently escape.
    return sorted(path for folder in ('Sources', 'iPad') for path in (root / folder).rglob('*.swift'))


def violations(text, view_calls=True):
    code = code_only(text)
    lines = text.split('\n')  # the same line count as code.count('\n'), whatever Unicode breaks a string holds
    ranges = [(m.end(), expression_end(code, m.end(), True)) for m in CALL.finditer(code)] if view_calls else []
    ranges += [(m.end(), expression_end(code, m.end())) for m in SPACING.finditer(code)]
    errors = set()
    for start, end in ranges:
        for match in NUMBER.finditer(code, start, end):
            value = float(match[0])
            if abs(value) in (0, 1, 2) or value % 4 == 0: continue
            line = code.count('\n', 0, match.start()) + 1
            if not EXCEPTION.search(lines[line - 1]): errors.add((line, match[0]))
    return sorted(errors)


def main():
    paths = source_files(ROOT)
    errors = [f'{path.relative_to(ROOT)}:{line}: off-grid value {value} (use the grid or // grid: ok <reason>)'
              for path in paths for line, value in violations(path.read_text(), 'import SwiftUI' in path.read_text())]
    for path in paths:
        for line in fixed_text_errors(path.read_text()):
            errors.append(f'{path.relative_to(ROOT)}:{line}: multiword Text must wrap instead of fixing its width')
    if errors:
        print('\n'.join(errors))
        print(f'FAIL grid: {len(errors)} off-grid values')
        return 1
    print(f'PASS grid: {len(paths)} Swift source files (Mac and iPad)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
