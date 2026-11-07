import AppKit
import Foundation
import SwiftUI
import Synchronization
import XCTest
@testable import PrompterCore
@testable import VideoPrompter

private actor ReviewAccessGate {
  var arrivals = Set<Bool>()
  var continuations: [Bool: CheckedContinuation<Void, Never>] = [:]
  func hold(_ writing: Bool) async {
    guard arrivals.insert(writing).inserted else { return }
    await withCheckedContinuation { continuations[writing] = $0 }
  }
  func entered(_ writing: Bool) -> Bool { continuations[writing] != nil }
  func release(_ writing: Bool) { continuations.removeValue(forKey: writing)?.resume() }
}

private final class ReviewHeldEditor: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  let release = DispatchSemaphore(value: 0)
  init(_ url: URL) { presentedItemURL = url; super.init() }
  func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
    _ = release.wait(timeout: .now() + 4)
    completionHandler(nil)
  }
}

private final class ReviewSlowWriter: @unchecked Sendable {
  let holding = Mutex(false)
  let release = DispatchSemaphore(value: 0)
}

@MainActor final class ReviewFixTests: XCTestCase {
  override func setUp() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
  }
  private func fixture() async throws -> (AppStore, UserDefaults, URL) {
    let root = URL(fileURLWithPath: "/private/tmp/vp-review-\(UUID())")
    let defaults = freshDefaults("ReviewFixes")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.appendingPathComponent("library").path], defaults: defaults))
    await store.waitForInitialLoad()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (store, defaults, root)
  }

  func testUnsupportedOriginalIsPreservedOnlyOnceAcrossEdits() async throws {
    let (store, _, root) = try await fixture()
    let library = try XCTUnwrap(store.library)
    let file = root.appendingPathComponent("unmarked.md")
    let original = try XCTUnwrap("# Café 世界".data(using: .utf16LittleEndian))
    try original.write(to: file)
    var record = try await library.createLinked(title: "Unmarked", markdown: "# Café 世界", to: file)
    for i in 0..<5 { record = try await library.save(record.id, markdown: "Edit \(i)", expectedFingerprint: record.metadata.contentFingerprint) }
    let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("library/Conflicts"), includingPropertiesForKeys: nil)
    XCTAssertEqual(files.filter { $0.lastPathComponent.contains("-unsupported-") }.count, 1)
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  func testFailedUnsupportedRelinkDoesNotLeaveWarning() async throws {
    let (store, _, root) = try await fixture()
    let library = try XCTUnwrap(store.library)
    let file = root.appendingPathComponent("unmarked.md")
    try XCTUnwrap("# Café 世界".data(using: .utf16LittleEndian)).write(to: file)
    let record = try await library.create(title: "Local", markdown: "Local edit")
    do { _ = try await library.relink(id: record.id, to: file, resolution: .keepLibrary); XCTFail("Relink should fail") } catch {}
    let waiting = await library.linkedSyncWaiting()
    XCTAssertTrue(waiting.isEmpty)
  }

  func testBOMlessUTF16NeverReplacesOriginalAndPreservesBothVersions() async throws {
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
      for path in ["save", "poll", "relink"] {
        let (store, _, root) = try await fixture()
        let library = try XCTUnwrap(store.library)
        let file = root.appendingPathComponent("unmarked.md")
        let text = "# Café 世界\n\nRead this script."
        let original = try XCTUnwrap(text.data(using: encoding))
        try original.write(to: file)
        let preview = try await DocumentImporter().preview(url: file)
        XCTAssertEqual(preview.markdown, text)
        XCTAssertFalse(preview.markdown.contains("\0"))
        let record = try await library.createLinked(title: "Unmarked", markdown: text, to: file)
        let edit = "My local edit"
        if path == "save" {
          _ = try await library.save(record.id, markdown: edit, expectedFingerprint: record.metadata.contentFingerprint)
        } else if path == "poll" {
          let local = try await library.scriptURL(for: record.id)
          try edit.write(to: local, atomically: true, encoding: .utf8)
          _ = try await library.externalChange(for: record.id)
        } else {
          _ = try await library.unlink(record.id)
          let local = try await library.create(title: "Local", markdown: edit)
          do { _ = try await library.relink(id: local.id, to: file, resolution: .keepLibrary); XCTFail("Unsafe relink must fail") }
          catch { /* Both copies must already be durable below. */ }
        }
        XCTAssertEqual(try Data(contentsOf: file), original, path)
        let copies = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("library/Conflicts"), includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) }
        XCTAssertTrue(copies.contains(original), path)
        XCTAssertTrue(copies.contains(Data(edit.utf8)), path)
        let statuses = await library.linkedSyncWaiting()
        XCTAssertTrue(statuses.joined().contains("unsupported encoding"))
      }
    }
  }

  func testUTF8BOMSurvivesSaveAndReturnedLinkFingerprintIsCurrent() async throws {
    let (store, _, root) = try await fixture()
    let library = try XCTUnwrap(store.library)
    let file = root.appendingPathComponent("bom.md")
    let bom = Data([0xef, 0xbb, 0xbf])
    try (bom + Data("Original café".utf8)).write(to: file)
    let record = try await library.createLinked(title: "BOM", markdown: "Original café", to: file)
    let saved = try await library.save(record.id, markdown: "Edited 世界", expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(try Data(contentsOf: file), bom + Data("Edited 世界".utf8))
    XCTAssertEqual(saved.metadata.linkedFingerprint, MarkdownLibrary.fingerprint("Edited 世界"))
    let durable = try await library.read(record.id)
    XCTAssertEqual(saved, durable)
  }

  func testWaitingIsInlineAndCannotReplaceOrClearRealError() async throws {
    let (store, defaults, root) = try await fixture()
    let library = try XCTUnwrap(store.library)
    let file = root.appendingPathComponent("busy.md")
    try Data("original".utf8).write(to: file)
    let record = try await store.createScript(title: "Busy", markdown: "original", linkTo: file)
    store.selectedID = record.id
    let editor = ReviewHeldEditor(file)
    NSFileCoordinator.addFilePresenter(editor)
    defer { editor.release.signal(); NSFileCoordinator.removeFilePresenter(editor) }
    _ = try await library.save(record.id, markdown: "saved locally", expectedFingerprint: record.metadata.contentFingerprint)
    let realError = "The edit was preserved but could not replace the file."
    store.errorMessage = realError
    await store.refreshLinkedSyncStatus()
    XCTAssertEqual(store.errorMessage, realError)
    XCTAssertTrue(store.linkedSyncStatus?.contains("Waiting for busy.md") == true)
    XCTAssertFalse(store.linkedSyncStatus?.contains("Save or close") == true)
    // Avoid showing the existing real error alert while inspecting the inline status.
    store.errorMessage = nil
    let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: CameraModel(defaults: defaults)))
    defer { LibraryAX.close(window) }
    XCTAssertTrue(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityIdentifier") == "linked-sync-status" })
    XCTAssertNil(store.errorMessage)
    store.errorMessage = realError
    _ = try await library.unlink(record.id)
    await store.refreshLinkedSyncStatus()
    XCTAssertNil(store.linkedSyncStatus)
    XCTAssertEqual(store.errorMessage, realError)
  }

  func testPollOverlappingSaveRefreshesEditorAndNextSaveSucceeds() async throws {
    let (store, _, root) = try await fixture()
    let library = try XCTUnwrap(store.library)
    let file = root.appendingPathComponent("race.md")
    try Data("original".utf8).write(to: file)
    let record = try await store.createScript(title: "Race", markdown: "original", linkTo: file)
    store.selectedID = record.id
    store.session.present(record: record, settings: store.settings)
    try Data("external version".utf8).write(to: file)
    let gate = ReviewAccessGate()
    await library.setLinkedAccessHook { await gate.hold($0) }
    let poll = Task { await store.refreshExternalChanges() }
    for _ in 0..<100 where !(await gate.entered(false)) { try await Task.sleep(for: .milliseconds(5)) }
    let readEntered = await gate.entered(false)
    XCTAssertTrue(readEntered)
    store.updateMarkdown("local version", for: record.id)
    for _ in 0..<200 where !(await gate.entered(true)) { try await Task.sleep(for: .milliseconds(5)) }
    let writeEntered = await gate.entered(true)
    XCTAssertTrue(writeEntered)
    await gate.release(false)
    await poll.value
    await gate.release(true)
    await library.setLinkedAccessHook(nil)
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    XCTAssertEqual(store.selected?.markdown, "external version")
    let durable = try await library.read(record.id)
    XCTAssertEqual(store.selected, durable)
    let conflicts = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("library/Conflicts"), includingPropertiesForKeys: nil)
    XCTAssertTrue(try conflicts.contains { try String(contentsOf: $0, encoding: .utf8) == "local version" })
    store.updateMarkdown("next edit", for: record.id)
    let next = await store.flushPendingSaves()
    XCTAssertTrue(next)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "next edit")
    XCTAssertFalse(store.hasFailedSaves)
  }

  func testSlowReadGetsLongerRetryAndLeavesWaiting() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vp-slow-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root.appendingPathComponent("library"))
    let file = root.appendingPathComponent("slow.md")
    try Data("original".utf8).write(to: file)
    let record = try await library.createLinked(title: "Slow", markdown: "original", to: file)
    let slow = ReviewSlowWriter()
    let writer = Task.detached {
      var error: NSError?
      NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &error) { target in
        slow.holding.withLock { $0 = true }
        _ = slow.release.wait(timeout: .now() + 8)
        try! Data("external version".utf8).write(to: target)
      }
    }
    defer { slow.release.signal() }
    for _ in 0..<100 where !slow.holding.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(slow.holding.withLock { $0 })
    _ = try await library.externalChange(for: record.id)
    let waiting = await library.linkedSyncWaiting()
    XCTAssertFalse(waiting.isEmpty)
    let retry = Task { try await library.externalChange(for: record.id) }
    try await Task.sleep(for: .milliseconds(1300))
    slow.release.signal()
    await writer.value
    let changed = try await retry.value
    XCTAssertEqual(changed?.markdown, "external version", "The retry must outlive the original one-second deadline")
    let settled = await library.linkedSyncWaiting()
    XCTAssertTrue(settled.isEmpty)
  }

  func testActualPresenterKeyDownDoesNotOpenToolsBeforeOrDuringTake() async throws {
    let (store, defaults, _) = try await fixture()
    let record = try await store.createScript(title: "Keys", markdown: String(repeating: "Read these words.\n\n", count: 100))
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    let draft = PresenterDraft(record: record)
    draft.noticeMessage = "Review this change."
    recorder.savedTake = URL(fileURLWithPath: "/private/tmp/synthetic-take.mov")
    let host = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder))
    let panel = PresenterPanel(captureVisible: false)
    let previous = PresenterController.shared.panel
    PresenterController.shared.panel = panel
    panel.contentView = host
    panel.makeKeyAndOrderFront(nil)
    defer { recorder.phase = .idle; store.session.pause(); panel.contentView = nil; panel.close(); PresenterController.shared.panel = previous }
    for taking in [false, true] {
      if taking { recorder.phase = .recording; store.session.play(captureAudio: false) }
      for code: UInt16 in [49, 123, 124, 116, 121, 0] {
        panel.makeFirstResponder(panel)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: code == 49 ? " " : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        panel.sendEvent(key)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(NSApp.windows.filter { $0 !== panel && $0.isVisible }.isEmpty,
          "Key \(code), taking \(taking): no popover or other window may open")
      }
      host.layoutSubtreeIfNeeded()
      if taking {
        XCTAssertFalse(LibraryAX.named("Tools", in: host).isEmpty, "Named tools remain reachable")
        XCTAssertTrue(LibraryAX.value(try XCTUnwrap(LibraryAX.named("Check reading…", in: host).first), "accessibilityValue").contains("Review this change"), "Reading status exposes the notice directly")

      }
    }
  }

  func testRestoredAndCameraMatchedFramesEnforceMinimum() async throws {
    let defaults = freshDefaults("ReviewFrames")
    let screen = PresenterFrameMemory.Screen(id: 1, name: "Small", frame: NSRect(x: 0, y: 0, width: 800, height: 600), visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600))
    PresenterFrameMemory.save(NSRect(x: 50, y: 50, width: 200, height: 150), on: screen, to: defaults)
    let restored = try XCTUnwrap(PresenterFrameMemory.restored(from: defaults, screens: [screen]))
    XCTAssertEqual(restored.size, NSSize(width: 720, height: 520))
    for rotation in CameraRotation.allCases {
      let matched = PresenterController.matchedCameraFrame(picture: CGSize(width: 16, height: 9), rotation: rotation, in: screen.visibleFrame)
      XCTAssertGreaterThanOrEqual(matched.width, 720)
      XCTAssertGreaterThanOrEqual(matched.height, 520)
    }
    let panel = PresenterPanel(captureVisible: false)
    defer { panel.close() }
    panel.setFrame(NSRect(x: 0, y: 0, width: 100, height: 100), display: false)
    XCTAssertEqual(panel.frame.size, NSSize(width: 720, height: 520))
    let (store, preferences, _) = try await fixture()
    let record = try await store.createScript(title: "Reading floor", markdown: String(repeating: "Read these words. ", count: 200))
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    store.session.play(captureAudio: false)
    defer { store.session.pause() }
    let host = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: CameraModel(defaults: preferences), startsCamera: false, recorder: CameraRecorder(defaults: preferences)))
    host.sizingOptions = [] // Match the presenter's fixed-size production host.
    panel.contentView = host
    defer { panel.contentView = nil }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for frame in [restored, PresenterController.matchedCameraFrame(picture: CGSize(width: 16, height: 9), rotation: .quarter, in: screen.visibleFrame)] {
      panel.setFrame(frame, display: false)
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let text = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        let viewport = try XCTUnwrap(text.enclosingScrollView)
        if viewport.frame.height < panel.frame.height * 0.65 {
          print("Reading floor geometry: host=\(host.frame) panel=\(panel.frame) viewport=\(viewport.frame)")
          for node in LibraryAX.elements(host) where ["AXButton", "AXMenuButton", "AXPopUpButton"].contains(LibraryAX.value(node, "accessibilityRole")) {
            print("control", LibraryAX.value(node, "accessibilityLabel"), node.value(forKey: "accessibilityFrame") ?? "")
          }
        }
        XCTAssertGreaterThanOrEqual(viewport.frame.height, panel.frame.height * 0.65, "\(zoom), \(frame)")
      }
    }
  }

  func testStableCameraPickerIdentifier() async throws {
    let (_, preferences, _) = try await fixture()
    let (window, host) = await LibraryAX.host(CameraPicker(model: CameraModel(defaults: preferences), recorder: CameraRecorder(defaults: preferences)))
    defer { LibraryAX.close(window) }
    let opener = try XCTUnwrap(LibraryAX.named("Camera", in: host).first)
    XCTAssertEqual(LibraryAX.value(opener, "accessibilityIdentifier"), "camera-picker")
  }

  func testPopoverFocusInfrastructureEntersAndReturnsToTools() async throws {
    struct FocusFixture: View {
      @State var open = false
      var body: some View {
        Button("Tools") { open.toggle() }
          .restoringPopoverFocus(isPresented: $open, identifier: "tools-focus-fixture")
          .popover(isPresented: $open) {
            VStack {
              Button("Smaller text") {}.initialPopoverFocus()
              Button("Done") { open = false }
            }.padding().popoverEntryFocus()
          }
      }
    }
    let (panel, host) = await LibraryAX.host(FocusFixture())
    panel.makeKeyAndOrderFront(nil)
    defer { LibraryAX.close(panel) }
    let opener = try XCTUnwrap(LibraryAX.named("Tools", in: host).first)
    XCTAssertTrue(LibraryAX.bool(opener, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(350))
    let popover = try XCTUnwrap(NSApp.windows.first { $0 !== panel && $0.isVisible && $0.contentView.map { !LibraryAX.named("Smaller text", in: $0).isEmpty } == true })
    let first = try XCTUnwrap(LibraryAX.named("Smaller text", in: popover.contentView!).first)
    XCTAssertTrue(LibraryAX.bool(first, "isAccessibilityFocused"))
    let done = try XCTUnwrap(LibraryAX.named("Done", in: popover.contentView!).first)
    XCTAssertTrue(LibraryAX.bool(done, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertFalse(popover.isVisible)
    XCTAssertTrue(LibraryAX.bool(try XCTUnwrap(LibraryAX.named("Tools", in: host).first), "isAccessibilityFocused"))
  }

  func testResponseBudgetRejectsEscapingBeforeSerialisingOversizedReply() throws {
    let response = ControlResult.ok(["markdown": String(repeating: "\t", count: 20_000)]).wire(id: "bounded", maxBytes: 1024)
    XCTAssertLessThan(response.count, 1024)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, "response_too_large")
    XCTAssertTrue(ControlCLI.help().contains("64 KB"))
    XCTAssertTrue(ControlResult.ok(["value": "test"]).wire(id: String(repeating: "x", count: 2000), maxBytes: 1024).isEmpty)
  }
}
