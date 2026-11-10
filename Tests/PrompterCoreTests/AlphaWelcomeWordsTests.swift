import PrompterCore

import XCTest
@testable import VideoPrompter

final class AlphaWelcomeWordsTests: XCTestCase {
  func testAlphaWelcomeAvoidsRetiredWords() throws {
    guard !Features.recording else { throw XCTSkip("Alpha wording only") }
    for term in ["Tools", "Mic level", "Legend", "Check sound", "arrow", "Paste Copied Text", "record"] {
      XCTAssertFalse(WelcomeScript.markdown.localizedCaseInsensitiveContains(term), "Retired term: \(term)")
    }
  }
}

extension AlphaWelcomeWordsTests {
  func testEveryBoldWelcomeControlExistsInUI() throws {
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/VideoPrompter")
    let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)!
    var ui = ""
    for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "WelcomeScript.swift" {
      ui += try String(contentsOf: url, encoding: .utf8)
    }
    let regex = try NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    let script = WelcomeScript.monitorMarkdown as NSString
    for match in regex.matches(in: WelcomeScript.monitorMarkdown, range: NSRange(location: 0, length: script.length)) {
      let name = script.substring(with: match.range(at: 1))
      if name == WelcomeScript.spanishTitle { continue }
      // Navigation paths name existing controls; Space and Escape are keyboard equivalents.
      for component in name.components(separatedBy: " > ") {
        XCTAssertTrue(ui.contains(component), "Missing welcome control: \(component)")
      }
    }
  }
}
