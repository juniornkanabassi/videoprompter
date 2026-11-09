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
