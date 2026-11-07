import AppKit
import AVFoundation
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class FinalFooterTests: XCTestCase {
  func fixture() async throws -> (AppStore, CameraModel, CameraRecorder, ScriptRecord) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinalFooter-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("FinalFooter")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "My Script", markdown: String(repeating: "Read these words at your own pace. ", count: 100))
    store.settings.mode = "Manual"; store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder; camera.displayMode = .prompterWithVideo
    camera.recordingReadyOverride = true; camera.pictureSizeOverride = .init(width: 1080, height: 1920)
    return (store, camera, recorder, record)
  }

  func testCameraJumpBarFitsOneRowAtEverySize() async throws {
    let (store, camera, recorder, _) = try await fixture()
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(CameraRecordingPage(store: store, camera: camera, recorder: recorder, startsCamera: false).uiZoom(zoom), size: .init(width: 560, height: 640))
      defer { LibraryAX.close(window) }
      let segments = LibraryAX.elements(host).filter { LibraryAX.value($0, "accessibilityRole") == "AXRadioButton" }
      XCTAssertEqual(segments.count, 4)
      let rects = try segments.map { try XCTUnwrap($0.value(forKey: "accessibilityFrame") as? NSValue).rectValue }
      for rect in rects { XCTAssertTrue(window.convertToScreen(host.bounds).insetBy(dx: -1, dy: -1).contains(rect), "Jump control clips at \(zoom): \(rect)") }
      for rect in rects.dropFirst() { XCTAssertEqual(rect.midY, rects.first?.midY ?? 0, accuracy: 1) }
    }
  }

  func testStateTableAndTakeNaming() async throws {
    let (store, camera, recorder, record) = try await fixture()
    func view() -> PresenterView { PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder) }
    XCTAssertEqual(store.session.visibleReadingState, "Ready")
    XCTAssertTrue(view().recordingStateTitle.hasPrefix("Ready · Portrait"))
    camera.pictureSizeOverride = nil
    XCTAssertEqual(view().recordingStateTitle, "Waiting for picture")
    camera.recordingReadyOverride = false
    XCTAssertEqual(view().recordingStateTitle, "Camera unavailable")
    recorder.phase = .preparing; XCTAssertEqual(view().recordingStateTitle, "Starting…")
    recorder.phase = .recording; recorder.recordedDuration = 84
    XCTAssertEqual(view().recordingStateTitle, "REC 01:24")
    recorder.phase = .saving; XCTAssertEqual(view().recordingStateTitle, "Saving…")
    recorder.phase = .idle
    store.session.pause(); XCTAssertEqual(store.session.visibleReadingState, "Paused")
    let folder = FileManager.default.temporaryDirectory
    XCTAssertTrue(CameraRecorder.fileURL(in: folder, defaultLabel: record.metadata.title).lastPathComponent.hasPrefix("My Script "))
    XCTAssertTrue(CameraRecorder.fileURL(in: folder).lastPathComponent.hasPrefix("Video Prompter "))
    XCTAssertEqual(CameraRecorder.fileURL(in: folder, defaultLabel: "Client/Take").deletingLastPathComponent(), folder)
    XCTAssertTrue(CameraRecorder.fileURL(in: folder, label: "Custom", defaultLabel: "My Script").lastPathComponent.hasPrefix("Custom "))
    XCTAssertEqual(PermissionRow.statusText(.denied), "Not allowed")
    XCTAssertTrue(PermissionRow.settingsURL("Camera").absoluteString.hasSuffix("Privacy_Camera"))
  }

  func testSmallDisplayAndWindow() throws {
    let area = NSRect(x: 0, y: 0, width: 800, height: 480)
    XCTAssertTrue(area.contains(PresenterFrameMemory.clamp(area, into: area)))
    let panel = PresenterPanel(captureVisible: false)
    defer { panel.close() }
    panel.setFrame(NSRect(x: 0, y: 0, width: 400, height: 300), display: false)
    XCTAssertEqual(panel.frame.size, PresenterFrameMemory.minimumSize(in: try XCTUnwrap(panel.screen).visibleFrame))

  }

  func testFocusedButtonKeepsSpace() throws {
    let panel = PresenterPanel(captureVisible: false)
    defer { panel.close() }
    let button = NSButton(title: "Record", target: nil, action: nil)
    panel.contentView = button; panel.makeFirstResponder(button)
    panel.onPassageKey = { _ in true }
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    XCTAssertFalse(panel.handlePassageKey(event))
  }

  func testClickerOnlyHandlesBareKeysOnReadingSurface() throws {
    let panel = PresenterPanel(captureVisible: false)
    defer { panel.close() }
    var keys: [UInt16] = []; panel.onPassageKey = { keys.append($0); return true }
    panel.makeFirstResponder(panel)
    for code: UInt16 in [49, 115, 116, 121, 123, 124] {
      func event(_ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
      }
      XCTAssertTrue(panel.handlePassageKey(try event()))
      for flags: NSEvent.ModifierFlags in [.shift, .command, .option, .control] { XCTAssertFalse(panel.handlePassageKey(try event(flags))) }
      let editor = NSTextView(); panel.contentView = editor; panel.makeFirstResponder(editor)
      XCTAssertFalse(panel.handlePassageKey(try event()))
      panel.makeFirstResponder(panel)
    }
    XCTAssertEqual(keys, [49, 115, 116, 121, 123, 124])
  }

  func testFooterGeometryAndUntruncatedActionsAcrossStateMatrix() async throws {
    let (store, camera, recorder, record) = try await fixture()
    var evidence: [[String: Any]] = []
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for size in [NSSize(width: 720, height: 520), .init(width: 1000, height: 700)] {
        for state in ["idle", "waiting", "countdown", "reading", "recording", "saved", "problem", "failed"] {
          let recorder = CameraRecorder(defaults: freshDefaults("MatrixTake")); camera.recorder = recorder
          store.session.pause(); recorder.phase = .idle; recorder.errorMessage = nil
          recorder.savedTake = nil; recorder.droppedAudioBuffers = 0
          camera.pictureSizeOverride = state == "waiting" ? nil : .init(width: 1080, height: 1920)
          if state == "reading" { store.session.play(captureAudio: false) }
          if state == "countdown" { store.session.countdownTick = .seconds(60); store.session.startReading() }
          if state == "recording" { recorder.phase = .recording }
          if state == "saved" || state == "problem" { recorder.savedTake = URL(fileURLWithPath: "/tmp/My Script 2026-11-06 14-03-22.mov"); recorder.lastTakeDuration = 84 }
          if state == "problem" { recorder.droppedAudioBuffers = 3 }
          if state == "failed" { recorder.phase = .recording; recorder.errorMessage = "Camera disconnected"; recorder.phase = .idle }
          let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
          let (window, host) = await LibraryAX.host(view, size: size)
          host.sizingOptions = []; host.frame = .init(origin: .zero, size: size)
          for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
          func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
          let scroll = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first?.enclosingScrollView)
          XCTAssertGreaterThanOrEqual(scroll.frame.height, size.height * 0.65 - 1, "\(state), \(zoom), \(size)")
          try assertFrozenFooter(host, size: size, zoom: zoom)
          // SwiftUI may forward a container identifier to a child AX node. Measure the
          // space actually reserved below the reading viewport, including footer padding.
          let footerHeight = size.height - scroll.frame.height
          XCTAssertLessThanOrEqual(footerHeight, size.height * 0.35, "Footer budget: \(state), \(zoom)")
          evidence.append(["zoom": zoom, "state": state, "width": size.width, "height": size.height,
                           "readingHeight": scroll.frame.height, "readingFraction": scroll.frame.height / size.height,
                           "footerHeight": footerHeight])
          if let reading = LibraryAX.named("Reading status", in: host).first,
             let recording = LibraryAX.named("Recording status", in: host).first,
             let first = reading.value(forKey: "accessibilityFrame") as? NSValue,
             let second = recording.value(forKey: "accessibilityFrame") as? NSValue {
            XCTAssertEqual(first.rectValue.midY, second.rectValue.midY, accuracy: 1)
            XCTAssertEqual(LibraryAX.value(recording, "accessibilityRole"), "AXButton")
            // Round 19: the state band is one line up to 150%; at 200% in the minimum window it may
            // use two lines (mode above state, or the output check wrapped), never three.
            let oneLine = 24 * zoom + 1, twoLines = 40 * zoom + 1
            // The long countdown fixture ("Starts in 60") is also allowed a second line at 150%.
            let tight = size.width == 720 && (zoom == 2 || (zoom == 1.5 && state == "countdown"))
            XCTAssertLessThanOrEqual(first.rectValue.height, tight ? twoLines : oneLine, "Reading status wrapped: \(state), \(zoom), \(size)")
            XCTAssertLessThanOrEqual(second.rectValue.height, tight || state == "recording" ? twoLines : oneLine, "Recording status wrapped: \(state), \(zoom), \(size)")
          }
          let nodes = LibraryAX.elements(host)
          for node in nodes where LibraryAX.value(node, "accessibilityRole") == "AXButton" {
            let name = LibraryAX.value(node, "accessibilityLabel")
            let rect = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            XCTAssertTrue(window.convertToScreen(host.bounds).insetBy(dx: -1, dy: -1).contains(rect), "Clipped action \(name) \(state) \(zoom)")
          }
          if state == "saved" {
            // Round 19: a clean take keeps the quick picture checks; its receipt opens from Last take.
            for name in ["Guides", "Exposure check", "Switch camera", "Last take"] { XCTAssertFalse(LibraryAX.named(name, in: host).isEmpty, name) }
            let opener = try XCTUnwrap(LibraryAX.named("Last take", in: host).first)
            XCTAssertEqual(LibraryAX.value(opener, "accessibilityValue"), "Saved My Script 2026-11-06 14-03-22.mov · 1:24")
            XCTAssertTrue(LibraryAX.named("Hide receipt", in: host).isEmpty)
          }
          if state == "problem" || state == "failed" {
            XCTAssertTrue(LibraryAX.named("Guides", in: host).isEmpty, "A take problem stays prominent until hidden")
            for name in ["Review", "Hide receipt"] + (state == "problem" ? ["Show in Finder"] : []) { XCTAssertFalse(LibraryAX.named(name, in: host).isEmpty, name) }
            let hide = try XCTUnwrap(LibraryAX.named("Hide receipt", in: host).first)
            XCTAssertTrue(LibraryAX.bool(hide, "accessibilityPerformPress")); XCTAssertTrue(recorder.receiptHidden)
            recorder.receiptHidden = false
          }
          LibraryAX.close(window)
        }
      }
    }
    recorder.phase = .idle; store.session.pause()
    if let path = ProcessInfo.processInfo.environment["VIDEOPROMPTER_LAYOUT_EVIDENCE"] {
      let target = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("final-footer-layout.json")
      try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: target)
    }
  }

  func testCameraAndExposureKeepSixtyPercentClearAtDoubleSize() async throws {
    let (store, camera, _, record) = try await fixture()
    store.uiZoom = 2
    camera.guides.falseColour = true
    let size = NSSize(width: 720, height: 520)
    var evidence: [[String: Any]] = []
    for state in ["waiting", "ready", "recording", "saved"] {
      let recorder = CameraRecorder(defaults: freshDefaults("CombinedFooter"))
      camera.recorder = recorder
      camera.pictureSizeOverride = state == "waiting" ? nil : .init(width: 1080, height: 1920)
      if state == "recording" { recorder.phase = .recording }
      if state == "saved" { recorder.savedTake = URL(fileURLWithPath: "/tmp/My Script.mov"); recorder.lastTakeDuration = 84 }
      let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
      let (window, host) = await LibraryAX.host(view, size: size)
      host.sizingOptions = []; host.frame = .init(origin: .zero, size: size)
      for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
      func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
      let scroll = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first?.enclosingScrollView)
      XCTAssertFalse(LibraryAX.named("Key", in: host).isEmpty, "Exposure strip must be present")
      try assertFrozenFooter(host, size: size, zoom: 2, readingFloor: 0.60)
      let transport = ["Start reading", "Back to start", state == "recording" ? "Stop recording" : "Record"]
      let frames = try transport.map { label in
        try XCTUnwrap(LibraryAX.named(label, in: host).first?.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      }
      for frame in frames.dropFirst() { XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1) }
      let reading = try XCTUnwrap(LibraryAX.named("Reading status", in: host).first)
      XCTAssertTrue(LibraryAX.value(reading, "accessibilityValue").contains("Automatic scroll"))
      let geometry = LibraryAX.elements(host).filter { LibraryAX.value($0, "accessibilityRole") == "AXButton" }.map {
        "\(LibraryAX.value($0, "accessibilityLabel")): \($0.value(forKey: "accessibilityFrame") ?? "none")"
      }
      evidence.append(["state": state, "clearHeight": scroll.frame.height, "clearPercent": scroll.frame.height / size.height * 100, "controls": geometry])
      LibraryAX.close(window)
    }
    if let path = ProcessInfo.processInfo.environment["VIDEOPROMPTER_LAYOUT_EVIDENCE"] {
      try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("combined-footer-layout.json"))
    }
  }

  func testFileActionsUndoWithoutLosingContents() async throws {
    let (store, _, _, record) = try await fixture()
    let manager = UndoManager(); manager.groupsByEvent = false
    let folder = try await store.createLibraryFolder(named: "Original")
    manager.beginUndoGrouping(); store.renameFolder(folder.id, name: "Renamed", undoManager: manager); manager.endUndoGrouping()
    _ = await store.flushPendingSaves(); XCTAssertEqual(manager.undoActionName, "Rename Folder")
    manager.undo(); _ = await store.flushPendingSaves(); XCTAssertEqual(store.folders.first?.name, "Original")
    manager.beginUndoGrouping(); store.moveSelectedScripts([record.id], to: folder.id, undoManager: manager); manager.endUndoGrouping()
    _ = await store.flushPendingSaves(); XCTAssertEqual(manager.undoActionName, "Move to Folder")
    manager.undo(); _ = await store.flushPendingSaves(); XCTAssertNil(store.scripts.first(where: { $0.id == record.id })?.metadata.folderID)
    try await store.deleteScript(record.id)
    manager.beginUndoGrouping(); store.restore(record.id, undoManager: manager); manager.endUndoGrouping()
    await store.waitForScriptDeletions()
    XCTAssertEqual(manager.undoActionName, "Restore Script")
    manager.undo()
    await store.waitForScriptDeletions()
    XCTAssertTrue(store.trash.contains(where: { $0.id == record.id }))
    manager.redo()
    await store.waitForScriptDeletions()
    XCTAssertEqual(store.scripts.first(where: { $0.id == record.id })?.markdown, record.markdown)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("UndoLink-\(UUID()).md")
    try record.markdown.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    manager.beginUndoGrouping()
    let linked = await store.relink(record.id, to: url, resolution: .useFile, undoManager: manager)
    manager.endUndoGrouping()
    XCTAssertTrue(linked)
    XCTAssertEqual(manager.undoActionName, "Link File")
    manager.undo(); _ = await store.flushPendingSaves(); XCTAssertNil(store.scripts.first(where: { $0.id == record.id })?.metadata.linkedPath)
    manager.redo(); _ = await store.flushPendingSaves()
    manager.beginUndoGrouping(); store.unlink(record.id, undoManager: manager); manager.endUndoGrouping()
    _ = await store.flushPendingSaves(); XCTAssertEqual(manager.undoActionName, "Unlink")
    manager.undo(); _ = await store.flushPendingSaves(); XCTAssertEqual(store.scripts.first(where: { $0.id == record.id })?.metadata.linkedPath, url.path)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), record.markdown)
  }

  func testRestoreUndoRedoWaitsForCompletionInsteadOfStaleLists() async throws {
    let (store, _, _, record) = try await fixture()
    try await store.deleteScript(record.id)
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping(); store.restore(record.id, undoManager: manager); manager.endUndoGrouping()
    await store.waitForScriptDeletions()

    let deletionEntered = expectation(description: "Undo paused before deletion")
    var release: CheckedContinuation<Void, Never>?
    store.deleteGate = {
      await withCheckedContinuation { release = $0; deletionEntered.fulfill() }
    }
    manager.undo()
    await fulfillment(of: [deletionEntered], timeout: 2)
    // This was the old redo wait predicate: it is already true while Undo is blocked.
    XCTAssertTrue(store.scripts.contains { $0.id == record.id })
    manager.redo()
    var finished = false
    let completion = Task { await store.waitForScriptDeletions(); finished = true }
    await Task.yield()
    XCTAssertFalse(finished)
    store.deleteGate = nil
    release?.resume()
    await completion.value
    XCTAssertTrue(store.scripts.contains { $0.id == record.id })
    XCTAssertFalse(store.trash.contains { $0.id == record.id })
    XCTAssertEqual(manager.undoActionName, "Restore Script")
    XCTAssertNil(store.errorMessage)
  }

  func testPresetAndShootSetupUndo() async throws {
    let (store, camera, recorder, _) = try await fixture()
    let undo = UndoManager(); undo.groupsByEvent = false
    store.savePreset(named: "Studio"); let preset = try XCTUnwrap(store.presets.first)
    store.settings.fontSize = 72
    undo.beginUndoGrouping(); store.updatePreset(preset.id, undoManager: undo); undo.endUndoGrouping()
    undo.undo(); XCTAssertEqual(store.presets.first, preset)
    undo.redo(); XCTAssertEqual(store.presets.first?.fontSize, 72)
    XCTAssertTrue(store.saveShootSetup(named: "Studio", camera: camera, recorder: recorder))
    var setup = try XCTUnwrap(store.shootSetups.first)
    setup.cameraUID = nil; setup.reading.audioDeviceUID = nil; setup.microphoneUID = nil
    undo.beginUndoGrouping(); store.deleteShootSetup(setup.id, undoManager: undo); undo.endUndoGrouping()
    XCTAssertEqual(undo.undoActionName, "Delete Shoot Setup"); undo.undo(); XCTAssertEqual(store.shootSetups.first?.id, setup.id)
    store.settings.fontSize = 40
    undo.beginUndoGrouping(); XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: [], undoManager: undo)); undo.endUndoGrouping()
    undo.undo(); XCTAssertEqual(store.settings.fontSize, 40)
  }
}

extension AppearanceSnapshotTests {
  func testFinalFooter() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let (store, camera, recorder, record) = try await FinalFooterTests().fixture()
    let scheme: ColorScheme = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let appearance = scheme == .dark ? "dark" : "light"
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for size in [NSSize(width: 720, height: 520), .init(width: 1000, height: 700)] {
        let widthSuffix = size.width == 720 ? "" : "-wide"
        for state in ["idle", "countdown", "reading", "recording", "saved", "problem", "failed", "camera-view"] + (zoom == 2 && size.width == 720 ? ["waiting-exposure", "ready-exposure", "recording-exposure", "saved-exposure"] : []) {
          let recorder = CameraRecorder(defaults: freshDefaults("FinalSnapshotTake"))
          camera.recorder = recorder
          camera.guides.falseColour = state.hasSuffix("-exposure")
          camera.pictureSizeOverride = state == "waiting-exposure" ? nil : .init(width: 1080, height: 1920)
          recorder.phase = .idle; recorder.errorMessage = nil; recorder.savedTake = nil
          recorder.droppedAudioBuffers = 0; recorder.receiptHidden = false
          camera.displayMode = state == "camera-view" ? .videoOnly : .prompterWithVideo
          store.session.stop(); store.session.present(record: record, settings: store.settings)
          if state == "countdown" { store.session.countdownTick = .seconds(60); store.session.startReading() }
          if state == "reading" { store.session.play(captureAudio: false) }
          if state == "recording" || state == "recording-exposure" { recorder.phase = .recording }
          if state == "saved" || state == "saved-exposure" || state == "problem" { recorder.savedTake = URL(fileURLWithPath: "/tmp/My Script 2026-11-06 14-03-22.mov") }
          if state == "problem" { recorder.droppedAudioBuffers = 3 }
          if state == "failed" { recorder.phase = .recording; recorder.errorMessage = "Camera disconnected"; recorder.phase = .idle }
          recorder.lastTakeDuration = 84; recorder.recordedDuration = 83
          XCTAssertEqual(recorder.takeFailure != nil, state == "failed", "Each snapshot must start with a clean take state")
          let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), hasScript: state != "camera-view", camera: camera, startsCamera: false, recorder: recorder)
          let name = state == "saved" ? "receipt" : state
          try await snapshot(view, name: "fable-bar-\(name)-\(Int(zoom * 100))\(widthSuffix)-\(appearance)", size: size, scheme: scheme, destination: URL(fileURLWithPath: output))
        }
      }
      recorder.phase = .idle; recorder.errorMessage = nil; store.session.pause(); camera.displayMode = .prompterWithVideo
      camera.recorder = recorder
      let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
      try await snapshot(view.outputControls, name: "fable-precheck-\(Int(zoom * 100))-\(appearance)", size: .init(width: 640, height: 700), scheme: scheme, destination: URL(fileURLWithPath: output))
      try await snapshot(CameraRecoveryView(model: camera) {}, name: "fable-recovery-\(Int(zoom * 100))-\(appearance)", size: .init(width: 640, height: 600), scheme: scheme, destination: URL(fileURLWithPath: output))
    }
  }
}

@MainActor final class FinalVocabularyTests: XCTestCase {
  func testFrozenSectionSevenMatchesOwnedUI() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let spec = try String(contentsOf: root.appendingPathComponent("DESIGN-SPEC.md"), encoding: .utf8)
    let section = try XCTUnwrap(spec.components(separatedBy: "## 7. Frozen vocabulary").last?.components(separatedBy: "## 8.").first)
    let labels = ["Start reading", "Back to start", "Read again", "Voice follow", "Automatic scroll", "Clean view", "Exit clean view", "Tools", "Guides", "Exposure check", "Switch camera", "Waiting for picture", "Camera unavailable", "Starting…", "Saving…", "Last take", "Check microphone", "Show in Finder", "Hide"]
    let presenter = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Presenter/PresenterController.swift"), encoding: .utf8)
      + String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Presenter/PresenterView.swift"), encoding: .utf8)
    let camera = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Camera/CameraWindow.swift"), encoding: .utf8)
      + String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Camera/CameraModel.swift"), encoding: .utf8)
    for label in labels {
      XCTAssertTrue(section.contains(label), "Undocumented vocabulary: \(label)")
      XCTAssertTrue((presenter + camera).contains("\"\(label)\""), "Missing UI vocabulary: \(label)")
    }
    let exposure = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Presenter/ExposureLegend.swift"), encoding: .utf8)
    for label in PresenterDisplayMode.allCases.map(\.label) + CameraGuides.ZebraPurpose.allCases.map(ExposureLegend.zebraTitle) + FalseColourStrip.captions + ["Check brightness · False colour", "Face reference"] {
      XCTAssertTrue(section.contains(label), "Undocumented camera or exposure vocabulary: \(label)")
      XCTAssertTrue((camera + exposure).contains("\"\(label)\""), "Missing camera or exposure vocabulary: \(label)")
    }
    let menu = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/App/VideoPrompterApp.swift"), encoding: .utf8)
    for name in ["ToolbarCommands()", "Zoom In", "Zoom Out", "Actual Size", "Make Text Bigger", "Make Text Smaller", "Start Reading", "Pause Reading", "Last Take", "Open Second Monitor Window"] { XCTAssertTrue(menu.contains(name), name) }
    XCTAssertFalse(menu.contains("InspectorCommands()"))
    XCTAssertTrue(menu.contains("[.shift, .control, .command]"))
    for file in ["Presenter/PresenterController.swift", "Presenter/PresenterView.swift", "Camera/CameraWindow.swift", "Camera/CameraModel.swift", "App/VideoPrompterApp.swift", "Settings/SettingsView.swift", "Settings/ShootSetup.swift"] {
      let text = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/" + file), encoding: .utf8)
      for retired in ["\"Not recording\"", "\"Dismiss\"", "\"OK\"", "Find blown highlights", "\"Show saved take…\""] { XCTAssertFalse(text.contains(retired), "\(file): \(retired)") }
    }
  }

  func testNativeSettingsButtonsAndAlertTitlesUseTitleCase() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let expression = try NSRegularExpression(pattern: #"(?:Button|\.alert)\("([^"\\]+)""#)
    let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with", "over"]
    for file in ["SettingsView.swift", "ShootSetup.swift"] {
      let text = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Settings/" + file), encoding: .utf8)
      for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let label = String(text[Range(match.range(at: 1), in: text)!])
        for word in label.split(separator: " ").dropFirst() where !small.contains(String(word)) {
          if let first = word.first, first.isLetter { XCTAssertTrue(first.isUppercase, "\(file): \(label)") }
        }
      }
    }
  }
}

/// Shared by the matrix and PNG capture, so a snapshot cannot silently accept clipped controls.
@MainActor func assertFrozenFooter(_ host: NSView, size: NSSize, zoom: Double, readingFloor: Double = 0.65, file: StaticString = #filePath, line: UInt = #line) throws {
  func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
  if let scroll = views(host).compactMap({ $0 as? NSTextView }).first?.enclosingScrollView {
    XCTAssertGreaterThanOrEqual(scroll.frame.height, size.height * readingFloor, "Reading floor", file: file, line: line)
  }
  for label in ["Start reading", "Back to start", "Pause", "Read again", "Stop recording", "Show camera", "Tools", "Guides", "Exposure check", "Switch camera", "Play", "Show in Finder"] {
    for node in LibraryAX.named(label, in: host) where LibraryAX.value(node, "accessibilityRole") == "AXButton" {
      let rect = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue, file: file, line: line).rectValue
      let width = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: (["Guides", "Exposure check", "Switch camera", "Play", "Show in Finder"].contains(label) ? 12 : 13) * zoom)]).width
      XCTAssertGreaterThanOrEqual(rect.width + 1, width, "Truncated \(label)", file: file, line: line)
    }
  }
}
