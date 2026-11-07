import AppKit
import Foundation
import PrompterCore
import Synchronization
import XCTest
@testable import VideoPrompter

/// Reproductions only. Every path and defaults suite is disposable; no hardware or visible windows.
private final class QAUnsavedDocument: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  let releaseSave = DispatchSemaphore(value: 0)
  let saveRequests = Mutex(0)
  init(url: URL) { presentedItemURL = url; super.init(); presentedItemOperationQueue.maxConcurrentOperationCount = 1 }
  func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
    saveRequests.withLock { $0 += 1 }
    // Bounded even if an assertion or task fails. Models an editor awaiting an unsaved-document decision.
    _ = releaseSave.wait(timeout: .now() + 5)
    completionHandler(nil)
  }
}

@MainActor final class QAFindingsTests: XCTestCase {
  func testUnchangedLinkedFileDoesNotBlockUnrelatedLibraryWorkOnEditorSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-qa-coordination-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let external = root.appendingPathComponent("external.md")
    let text = "# Existing draft\n\nNothing on disk has changed."
    try text.write(to: external, atomically: true, encoding: .utf8)
    let library = try MarkdownLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.createLinked(title: "Existing", markdown: text, to: external)
    let editor = QAUnsavedDocument(url: external)
    NSFileCoordinator.addFilePresenter(editor)
    defer { editor.releaseSave.signal(); NSFileCoordinator.removeFilePresenter(editor) }
    let refresh = Task { try await library.externalChange(for: record.id) }
    try await Task.sleep(for: .milliseconds(250))
    let created = Mutex(false)
    let unrelated = Task {
      _ = try await library.create(title: "Unrelated", markdown: "New unrelated work")
      created.withLock { $0 = true }
    }
    try await Task.sleep(for: .milliseconds(350))
    let requestedSaves = editor.saveRequests.withLock { $0 }
    let wasResponsive = created.withLock { $0 }
    editor.releaseSave.signal()
    _ = try await refresh.value
    try await unrelated.value
    XCTAssertEqual(requestedSaves, 0, "Polling unchanged text must not request a write/save reservation from its editor")
    XCTAssertTrue(wasResponsive, "An unsaved external document must not stall unrelated library creation")
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), text)
  }

  func testUTF16MarkdownAcceptedByPreviewCanActuallyBeImported() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-qa-utf16-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let external = root.appendingPathComponent("UTF16.md")
    let text = "# Bonjour\n\nCafé, 世界 and football."
    try XCTUnwrap(text.data(using: .utf16)).write(to: external)
    let preview = try await DocumentImporter().preview(url: external)
    XCTAssertEqual(preview.markdown, text)
    let suite = "QAFindings.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.appendingPathComponent("library").path], defaults: defaults)
    addTeardownBlock { @MainActor in
      _ = await store.flushPendingSaves()
      TestDefaults.remove(suite)
    }
    let camera = CameraModel(defaults: defaults)
    let actions = ControlActions(store: store, presenter: PresenterController(camera: camera), camera: camera,
      recorder: CameraRecorder(defaults: defaults))
    let result = await actions.handle("script_import", ["path": external.path])
    XCTAssertEqual(result.body["ok"] as? Bool, true, "Preview accepts UTF-16, but linked-file validation rejects the import: \(result.body)")
    XCTAssertEqual(store.scripts.first?.markdown, text)
    XCTAssertEqual(try Data(contentsOf: external), text.data(using: .utf16), "Import must preserve the original")
  }
  func testBlockedLinkedWriteTimesOutWithoutBlockingLibraryAndPreservesBothEdits() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vp-wait-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let external = root.appendingPathComponent("unsaved.md")
    try "original".write(to: external, atomically: true, encoding: .utf8)
    let libraryRoot = root.appendingPathComponent("library")
    let library = try MarkdownLibrary(rootURL: libraryRoot)
    let record = try await library.createLinked(title: "Linked", markdown: "original", to: external)
    let editor = QAUnsavedDocument(url: external)
    NSFileCoordinator.addFilePresenter(editor)
    defer { editor.releaseSave.signal(); NSFileCoordinator.removeFilePresenter(editor) }
    let start = ContinuousClock.now
    let save = Task { try await library.save(record.id, markdown: "local edit", expectedFingerprint: record.metadata.contentFingerprint) }
    try await Task.sleep(for: .milliseconds(200))
    let unrelated = try await library.create(title: "Unrelated", markdown: "safe")
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "An editor must not hold the library actor")
    XCTAssertEqual(unrelated.markdown, "safe")
    let saved = try await save.value
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(3), "The save must return on its bounded deadline")
    XCTAssertEqual(saved.markdown, "local edit")
    XCTAssertGreaterThan(editor.saveRequests.withLock { $0 }, 0, "This test must actually hold a writer")
    let waiting = await library.linkedSyncWaiting()
    XCTAssertTrue(waiting.joined().contains("Waiting for unsaved.md"))
    let restarted = try MarkdownLibrary(rootURL: libraryRoot)
    let durable = try await restarted.read(record.id)
    XCTAssertEqual(durable.markdown, "local edit", "The edit is durable before external sync completes")
    // The editor saves after our deadline. A cancelled reservation must not overwrite it later.
    try "external edit".write(to: external, atomically: false, encoding: .utf8)
    editor.releaseSave.signal()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "external edit")
    let changed = try await library.externalChange(for: record.id)
    XCTAssertEqual(changed?.markdown, "external edit")
    let conflicts = await library.takeLinkConflicts()
    XCTAssertEqual(conflicts.count, 1)
    XCTAssertEqual(try String(contentsOf: libraryRoot.appendingPathComponent("Conflicts").appendingPathComponent(XCTUnwrap(conflicts.first)), encoding: .utf8), "local edit")
    let settled = await library.linkedSyncWaiting()
    XCTAssertTrue(settled.isEmpty)
  }

  func testUTF16LinkedRoundTripRetainsEncodingAndExternalEdits() async throws {
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
      let root = URL(fileURLWithPath: "/private/tmp/vp-utf-\(UUID())")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let file = root.appendingPathComponent("script.md")
      let bom = Data(encoding == .utf16LittleEndian ? [0xff, 0xfe] : [0xfe, 0xff])
      let original = bom + "# Café 世界".data(using: encoding)!
      try original.write(to: file)
      let library = try MarkdownLibrary(rootURL: root.appendingPathComponent("library"))
      let preview = try await DocumentImporter().preview(url: file)
      let record = try await library.createLinked(title: "Unicode", markdown: preview.markdown, to: file)
      XCTAssertEqual(try Data(contentsOf: file), original)
      _ = try await library.save(record.id, markdown: "# Local café 世界", expectedFingerprint: record.metadata.contentFingerprint)
      XCTAssertEqual(try Data(contentsOf: file), bom + "# Local café 世界".data(using: encoding)!)
      try (bom + "# External été 世界".data(using: encoding)!).write(to: file)
      let change = try await library.externalChange(for: record.id)
      XCTAssertEqual(change?.markdown, "# External été 世界")
    }
  }

  func testUnlinkWhileEditorHoldsWriteDoesNotWriteOrRestoreWaitingState() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vp-unlink-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let external = root.appendingPathComponent("unlink.md")
    try "original".write(to: external, atomically: true, encoding: .utf8)
    let library = try MarkdownLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.createLinked(title: "Linked", markdown: "original", to: external)
    let editor = QAUnsavedDocument(url: external)
    NSFileCoordinator.addFilePresenter(editor)
    defer { editor.releaseSave.signal(); NSFileCoordinator.removeFilePresenter(editor) }
    let save = Task { try await library.save(record.id, markdown: "new local", expectedFingerprint: record.metadata.contentFingerprint) }
    for _ in 0..<50 {
      if editor.saveRequests.withLock({ $0 > 0 }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(editor.saveRequests.withLock { $0 }, 0)
    _ = try await library.unlink(record.id)
    _ = try await save.value
    let waiting = await library.linkedSyncWaiting()
    XCTAssertTrue(waiting.isEmpty)
    editor.releaseSave.signal()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "original")
    let current = try await library.read(record.id)
    XCTAssertEqual(current.markdown, "new local")
    XCTAssertNil(current.metadata.linkedPath)
  }

}
