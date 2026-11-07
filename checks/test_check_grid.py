"""Regression tests for discovery, multiline literals and deliberate grid exceptions."""
from pathlib import Path
import tempfile
import unittest
import runpy

_grid = runpy.run_path(str(Path(__file__).with_name("check-grid.py")))
source_files, violations = _grid["source_files"], _grid["violations"]


class GridTests(unittest.TestCase):
    def test_spacing_and_frames_across_lines(self):
        text = 'HStack(spacing: 5) { Text("x") }.padding(\n  .horizontal, 7)\n.frame(\n width: 190,\n height: 135)'
        self.assertEqual(violations(text), [(1, '5'), (2, '7'), (4, '190'), (5, '135')])
        self.assertEqual(violations('.padding(-7).padding(8).frame(width: .infinity)'), [(1, '-7')])

    def test_exception_requires_a_reason_and_is_local(self):
        self.assertEqual(violations('.padding(7) // grid: ok'), [(1, '7')])
        self.assertEqual(violations('.padding(7) // grid: ok Optical alignment\n.padding(6)'), [(2, '6')])

    def test_comments_strings_and_video_dimensions_are_not_layout(self):
        text = '// .padding(7)\n/* HStack(spacing: 9) */\nText(".padding(7)")\nlet aspect = CGSize(width: 16, height: 9)'
        self.assertEqual(violations(text), [])
        self.assertEqual(violations('RoundedRectangle(cornerRadius: 14)\nSpacer(minLength: 3)'), [(1, '14'), (2, '3')])

    def test_new_views_are_discovered_in_both_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = [root / 'Sources/New/UnusualName.swift', root / 'iPad/New/Screen.swift']
            for path in expected:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('import SwiftUI\nText("New").padding(7)')
            self.assertEqual(source_files(root), expected)
            self.assertTrue(all(violations(path.read_text()) for path in source_files(root)))


if __name__ == '__main__':
    unittest.main()
