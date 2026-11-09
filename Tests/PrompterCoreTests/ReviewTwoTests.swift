import AppKit
import SwiftUI
import XCTest
import PrompterCore
@testable import VideoPrompter

/// Real hosted controls, transparent under TestOffscreen. No capture or playback.
@MainActor final class ReviewTwoTests: XCTestCase {
  private func fixture() async throws -> (AppStore, UserDefaults, ScriptRecord) {
    let defaults = freshDefaults("ReviewTwo")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Review", markdown: String(repeating: "One two three four five. ", count: 100))
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    return (store, defaults, record)
  }
  private func settle(_ host: NSView) async throws {
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
  }
  private func named(_ title: String, in host: NSView) throws -> NSObject {
    try XCTUnwrap(LibraryAX.named(title, in: host).first, title)
  }

  func testEditingActionsStayOnBarAndCommandReturnSavesWithoutOpeningMenu() async throws {
    let (store, defaults, record) = try await fixture()
    let draft = PresenterDraft(record: record)
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
    window.makeKeyAndOrderFront(nil)
    defer { LibraryAX.close(window) }
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      draft.begin(session: store.session)
      await Task.yield()
      try await settle(host)
      for title in Features.recording ? ["Save changes", "Cancel editing", "Record"] : ["Save changes", "Cancel editing"] {
        let action = try named(title, in: host)
        if ["Save changes", "Cancel editing"].contains(title) {
          XCTAssertTrue(LibraryAX.bool(action, "isAccessibilityEnabled"), title)
        }
        let frame = try XCTUnwrap(action.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), "\(zoom) \(title): \(frame)")
      }
      XCTAssertTrue(LibraryAX.named("Start reading", in: host).isEmpty)
      // The unchanged draft cancels immediately through the real button.
      XCTAssertTrue(LibraryAX.bool(try named("Cancel editing", in: host), "accessibilityPerformPress"))
      XCTAssertFalse(draft.isEditing)
    }
    recorder.phase = .recording
    draft.begin(session: store.session)
    try await settle(host)
    for title in Features.recording ? ["Save changes", "Cancel editing", "Stop recording"] : ["Save changes", "Cancel editing"] {
      let action = try named(title, in: host)
      let frame = try XCTUnwrap(action.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), title)
    }
    recorder.phase = .idle
    draft.markdown = "Saved using Command Return."
    try await settle(host)
    let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    XCTAssertTrue(window.performKeyEquivalent(with: key), "The visible Save button must register Command Return before More is opened")
    for _ in 0..<100 where draft.isEditing { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(draft.isEditing)
    XCTAssertEqual(store.scripts.first { $0.id == record.id }?.markdown, "Saved using Command Return.")
  }

  func testResumeReportsStartingCountdownAndThenRunning() async throws {
    let (store, defaults, _) = try await fixture()
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterOnly
    let recorder = CameraRecorder(defaults: defaults)
    let presenter = PresenterController(camera: camera, recorder: recorder, frameDefaults: nil)
    OffscreenPanels.install(); defer { OffscreenPanels.uninstall() }
    presenter.present(store: store, activate: false)
    defer { presenter.closeNow() }
    store.session.countdownTick = .milliseconds(100)
    let actions = ControlActions(store: store, presenter: presenter, camera: camera, recorder: recorder)
    func result(_ reply: ControlResult) -> [String: Any] { reply.body["result"] as? [String: Any] ?? [:] }
    let first = result(await actions.handle("resume", [:]))
    XCTAssertEqual(first["state"] as? String, "starting")
    XCTAssertEqual(first["countdown"] as? Int, 3)
    XCTAssertFalse(store.session.isActivelyRunning)
    let retry = result(await actions.handle("resume", [:]))
    XCTAssertEqual(retry["state"] as? String, "starting")
    XCTAssertEqual(retry["countdown"] as? Int, 3)
    for _ in 0..<100 where !store.session.isActivelyRunning { try await Task.sleep(for: .milliseconds(10)) }
    let running = result(await actions.handle("status", [:]))
    XCTAssertEqual(running["state"] as? String, "running")
    XCTAssertEqual(running["countdown"] as? Int, 0)
    XCTAssertTrue(ControlCLI.help().contains("3 seconds by default"))
    XCTAssertTrue(ControlProtocol.command(action: "resume")?.summary.contains("countdown") == true, "MCP and CLI share this description")
  }



  func testRecordingBarLevelUsesLiveRecordingSamples() async throws {
    guard Features.recording else { throw XCTSkip("Recording is not available in this build") }
    let (store, defaults, record) = try await fixture()
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    recorder.phase = .recording
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
    defer { recorder.phase = .idle; LibraryAX.close(window) }
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      store.session.meter.show(peakDBFS: -2, isClipping: false)
      recorder.inputMeter.show(peakDBFS: -23, isClipping: false)
      try await settle(host)
      XCTAssertEqual(LibraryAX.value(try named("Recording microphone level", in: host), "accessibilityValue"), "-23.0 dBFS")
      recorder.inputMeter.show(peakDBFS: -8, isClipping: false)
      try await settle(host)
      XCTAssertEqual(LibraryAX.value(try named("Recording microphone level", in: host), "accessibilityValue"), "-8.0 dBFS")
    }
    recorder.inputMeter.reset()
    try await settle(host)
    XCTAssertEqual(LibraryAX.value(try named("Recording microphone level", in: host), "accessibilityValue"), "No recent audio")
    XCTAssertFalse(recorder.isTestingInput, "Showing the level cannot start another capture")
  }

  func testSettingsDefaultCameraAndRecordingRecoveryHaveDistinctSections() async throws {
    guard Features.recording else { throw XCTSkip("Recording is not available in this build") }
    let (store, _, _) = try await fixture()
    for section in ["Recording", "Camera"] {
      let (window, host) = await LibraryAX.host(PresenterSettingsPopover(store: store, initialTab: .camera, initialCameraSection: section))
      XCTAssertFalse(LibraryAX.named("Settings page", in: host).isEmpty)
      XCTAssertFalse(LibraryAX.named("Recording format", in: host).isEmpty, "Common choices stay on the same page for every entry route")
      LibraryAX.close(window)
    }
    for zoom in [1.0, 2.0] {
      store.uiZoom = zoom
      let host = NSHostingView(rootView: AppSettingsView(store: store, selectedTab: .camera))
      let size = host.fittingSize
      XCTAssertGreaterThanOrEqual(size.width, 560)
      XCTAssertGreaterThanOrEqual(size.height, 500)
      let screen = try XCTUnwrap(NSScreen.main).visibleFrame.size
      XCTAssertLessThanOrEqual(size.width, screen.width)
      XCTAssertLessThanOrEqual(size.height, screen.height)
    }
  }


}

@MainActor extension AppearanceSnapshotTests {
  func testReviewTwoEditingMeterAndSettings() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("ReviewTwoSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "A clear opening", markdown: "Read these opening words at your own pace.\n\nLeave room for a natural pause.")
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    let recorder = CameraRecorder(defaults: defaults)
    let draft = PresenterDraft(record: record)
    for (mode, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != mode { continue }
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        for state in ["editing", "recording", "retake"] {
          draft.cancel(resuming: false); recorder.phase = .idle; store.session.restart()
          if state == "editing" { draft.begin(session: store.session) }
          else { recorder.phase = .recording; recorder.inputMeter.show(peakDBFS: -18, isClipping: false) }
          if state == "retake" { store.session.seek(to: 4) }
          try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder), name: "review2-\(state)-\(Int(zoom * 100))-\(mode)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
        }
        camera.guides.marker = CameraAspect(width: 2.39, height: 1)
        try await snapshot(CameraGuideSettings(model: camera).uiZoom(zoom), name: "review2-framing-\(Int(zoom * 100))-\(mode)", size: .init(width: 640, height: 700), scheme: scheme, destination: URL(fileURLWithPath: output))
        try await snapshot(AppSettingsView(store: store, selectedTab: .camera), name: "review2-settings-\(Int(zoom * 100))-\(mode)", size: .init(width: 900, height: 650), scheme: scheme, destination: URL(fileURLWithPath: output))
      }
    }
    recorder.phase = .idle
  }
}
