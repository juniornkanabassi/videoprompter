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
}
