import Foundation
import XCTest
@testable import PrompterCore

private final class HeldLinkPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  let release = DispatchSemaphore(value: 0)
  init(_ url: URL) { presentedItemURL = url; super.init() }
  func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
    _ = release.wait(timeout: .now() + 12)
    completionHandler(nil)
  }
}

@MainActor final class LibraryBackoffReviewTests: XCTestCase {
  func testSaveDoesNotResetPollingWriteBackoff() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vp-backoff-review2-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root.appendingPathComponent("library"))
    let file = root.appendingPathComponent("slow.md")
    try Data("original".utf8).write(to: file)
    var record = try await library.createLinked(title: "Slow", markdown: "original", to: file)
    let presenter = HeldLinkPresenter(file)
    NSFileCoordinator.addFilePresenter(presenter)
    defer { for _ in 0..<10 { presenter.release.signal() }; NSFileCoordinator.removeFilePresenter(presenter) }
    record = try await library.save(record.id, markdown: "first edit", expectedFingerprint: record.metadata.contentFingerprint)
    _ = try await library.externalChange(for: record.id) // write reservation times out and backs off
    record = try await library.save(record.id, markdown: "second edit", expectedFingerprint: record.metadata.contentFingerprint)
    let retry = Task { try await library.externalChange(for: record.id) }
    try await Task.sleep(for: .milliseconds(1050))
    for _ in 0..<10 { presenter.release.signal() }
    _ = try await retry.value
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second edit")
  }
}
