import Foundation
import XCTest
@testable import VideoPrompter
@testable import PrompterCore

private actor CloudPollGate {
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  func hold() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class CloudPollReviewTests: XCTestCase {
  func testCloudPassWaitsForExternalRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      UserDefaults.standard.removeObject(forKey: ICloudScripts.enabledKey)
      ICloudScripts.cloudDocsOverride = nil
      try? FileManager.default.removeItem(at: root)
    }
    UserDefaults.standard.set(true, forKey: ICloudScripts.enabledKey)
    ICloudScripts.cloudDocsOverride = root
    ICloudScripts.lastPass = .distantPast
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.appendingPathComponent("lib").path], defaults: freshDefaults("PollCloud")))
    await store.waitForInitialLoad()
    let file = root.appendingPathComponent("linked.md")
    try Data("original".utf8).write(to: file)
    _ = try await store.createScript(title: "Linked", markdown: "original", linkTo: file)
    try Data("changed".utf8).write(to: file)
    let gate = CloudPollGate()
    await store.library!.setLinkedAccessHook { _ in await gate.hold() }
    let poll = Task { await store.refreshExternalChanges() }
    for _ in 0..<100 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
    var completed = false
    let cloud = Task { await store.syncICloudScripts(); completed = true }
    try await Task.sleep(for: .milliseconds(300))
    let overlapped = completed
    await gate.release()
    await poll.value
    await cloud.value
    await store.library!.setLinkedAccessHook(nil)
    XCTAssertFalse(overlapped, "Cloud sync must not run while external refresh is working")
  }

}
