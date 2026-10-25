import XCTest

@testable import VideoPrompter

@MainActor final class GoogleDocsTests: XCTestCase {
  func testDocumentIDComesOutOfEveryLinkShape() {
    let id = "1AbCdEfGhIjKlMnOpQrStUvWxYz_0123456789-ab"
    for link in [
      "https://docs.google.com/document/d/\(id)/edit",
      "https://docs.google.com/document/d/\(id)/edit?usp=sharing",
      "https://docs.google.com/document/u/1/d/\(id)/edit#heading=h.abc",
      "  https://docs.google.com/document/d/\(id)  ",
      id,
    ] {
      XCTAssertEqual(GoogleDocs.documentID(from: link), id, link)
    }
    XCTAssertNil(GoogleDocs.documentID(from: "https://example.com/document"))
    XCTAssertNil(GoogleDocs.documentID(from: "match notes"))
  }

  func testCleanDropsEmbeddedPictures() {
    let markdown = "\u{FEFF}# Preview\r\n\r\nIntro ![][image1] line.\r\n\r\n[image1]: <data:image/png;base64,AAAA>\r\n"
    XCTAssertEqual(GoogleDocs.clean(markdown), "# Preview\n\nIntro  line.\n")
  }

  func testFileNameReadsEitherDispositionForm() {
    XCTAssertEqual(GoogleDocs.fileName("attachment; filename=\"Match preview.md\"; filename*=UTF-8''Match%20preview%20%E2%80%93%20final.md"), "Match preview – final")
    XCTAssertEqual(GoogleDocs.fileName("attachment; filename=\"Team news.md\""), "Team news")
    XCTAssertNil(GoogleDocs.fileName(nil))
  }

  func testLinksAreRememberedPerScript() {
    let defaults = UserDefaults(suiteName: "GoogleDocsTests.\(UUID().uuidString)")!
    let links = GoogleDocLinks(defaults: defaults)
    let script = UUID()
    XCTAssertNil(links[script])
    links[script] = .init(document: "doc", fingerprint: "abc")
    XCTAssertEqual(GoogleDocLinks(defaults: defaults)[script], .init(document: "doc", fingerprint: "abc"))
    links[script] = nil
    XCTAssertNil(links[script])
  }
}
