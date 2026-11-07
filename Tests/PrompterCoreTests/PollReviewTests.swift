import Foundation
import XCTest
@testable import VideoPrompter
@testable import PrompterCore

private actor PollGate {
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  func hold() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class PollReviewTests: XCTestCase {
  func testSlowPollReturnsBeforeBlockedChildAndAppliesItLater() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.appendingPathComponent("lib").path], defaults: freshDefaults("PollReview")))
    await store.waitForInitialLoad()
    let file = root.appendingPathComponent("linked.md")
    try Data("original".utf8).write(to: file)
    let record = try await store.createScript(title: "Linked", markdown: "original", linkTo: file)
    try Data("changed".utf8).write(to: file)
    let gate = PollGate()
    await store.library!.setLinkedAccessHook { _ in await gate.hold() }
    var completed = false
    let poll = Task { await store.refreshExternalChanges(); completed = true }
    for _ in 0..<100 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(1300))
    let returned = completed
    await gate.release()
    await poll.value
    await store.library!.setLinkedAccessHook(nil)
    for _ in 0..<100 where store.scripts.first(where: { $0.id == record.id })?.markdown != "changed" { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(returned, "A blocked child must not hold the caller")
    XCTAssertEqual(store.scripts.first(where: { $0.id == record.id })?.markdown, "changed")
  }
}
