import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class ReferenceMonitorBuildTests: XCTestCase {
  private func fixture() async throws -> (AppStore, CameraModel, CameraRecorder, ScriptRecord) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReferenceMonitor-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("ReferenceMonitor")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Reference monitor", markdown: "Read these words at your own pace.")
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    camera.guides = .firstUse
    camera.guides.thirds = true
    camera.guides.zebras = true
    camera.guides.falseColour = true
    let recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    return (store, camera, recorder, record)
  }

  func testRecordingSurfacesAndCommandsAreUnavailable() async throws {
    guard !Features.recording else { throw XCTSkip("Reference-monitor build only") }
    let (store, camera, recorder, record) = try await fixture()
    recorder.savedTake = URL(fileURLWithPath: "/tmp/previous-take.mov")
    for phase in [CameraRecorder.Phase.idle, .recording, .saving] {
      recorder.phase = phase
      let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session,
        draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder))
      for label in ["Record", "Stop recording", "Recording status", "Last take", "Saved"] {
        XCTAssertTrue(LibraryAX.named(label, in: host).isEmpty, label)
      }
      LibraryAX.close(window)
    }
    recorder.phase = .idle
    let (settingsWindow, settingsHost) = await LibraryAX.host(CameraRecordingPage(store: store, camera: camera, recorder: recorder, startsCamera: false))
    for label in ["Recording", "Recording format", "Mirror saved video", "Take name", "Show Recordings Folder"] {
      XCTAssertTrue(LibraryAX.named(label, in: settingsHost).isEmpty, label)
    }
    LibraryAX.close(settingsWindow)
    recorder.usesSeparateMicrophone = true
    recorder.microphoneUID = "old-recording-input"
    recorder.followingMicrophoneUID = "monitor-input"
    XCTAssertEqual(recorder.resolvedMicrophoneUID, "monitor-input")
    let (menuWindow, menuHost) = await LibraryAX.host(RecordingMenuItems())
    for label in ["Record", "Stop Recording", "Show Recordings Folder", "Last Take"] {
      XCTAssertTrue(LibraryAX.named(label, in: menuHost).isEmpty, label)
    }
    LibraryAX.close(menuWindow)
    let presenter = PresenterController(camera: camera, recorder: recorder)
    let actions = ControlActions(store: store, presenter: presenter, camera: camera, recorder: recorder,
      audioAuthorization: { XCTFail("Must not request recording audio access"); return .notDetermined })
    for action in ["record_start", "record_stop", "record_set"] {
      let response = await actions.handle(action, [:])
      XCTAssertEqual((response.body["error"] as? [String: String])?["message"], "Recording is not available in this build")
    }
    await recorder.start(camera: camera)
    XCTAssertEqual(recorder.phase, .idle)
    XCTAssertFalse(recorder.isTestingInput)
    XCTAssertEqual(recorder.errorMessage, "Recording is not available in this build")
  }

  func testCleanShowsOnlyCameraAndPreservesAids() async throws {
    let (store, camera, recorder, record) = try await fixture()
    let previous = camera.guides
    camera.cleanView = true
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session,
      draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder))
    defer { LibraryAX.close(window) }
    let elements = LibraryAX.elements(host)
    for identifier in ["presenter-control-bar", "presenter-state-band", "presenter-context-band", "presenter-exposure-legend"] {
      XCTAssertFalse(elements.contains { LibraryAX.value($0, "accessibilityIdentifier") == identifier }, identifier)
    }
    XCTAssertFalse(elements.contains { ["AXButton", "AXTextArea", "AXStaticText"].contains(LibraryAX.value($0, "accessibilityRole")) })
    XCTAssertTrue(descendants(host).contains { $0 is CameraStageView })
    XCTAssertFalse(camera.previewGuides.zebras)
    XCTAssertFalse(camera.previewGuides.falseColour)
    XCTAssertFalse(camera.previewGuides.thirds)
    XCTAssertEqual(camera.guides, previous)
    camera.cleanView = false
    XCTAssertEqual(camera.previewGuides, previous)
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(LibraryAX.named("Start reading", in: host).isEmpty)
    camera.cleanView = true
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertTrue(LibraryAX.named("Start reading", in: host).isEmpty)
    NotificationCenter.default.post(name: .init("VideoPrompter.presenterInteraction"), object: nil)
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(LibraryAX.named("Exit clean view", in: host).isEmpty)
    XCTAssertTrue(camera.cleanView)
    XCTAssertEqual(camera.guides, previous)
  }

  func testCleanHidesNativeWindowButtonsUntilInteraction() throws {
    let camera = CameraModel(defaults: freshDefaults("CleanWindowControls"))
    let controller = PresenterController(camera: camera, frameDefaults: nil)
    let panel = PresenterPanel(captureVisible: false)
    controller.panel = panel
    defer { controller.panel = nil; panel.close() }
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
    camera.cleanView = true
    for type in buttons { XCTAssertTrue(try XCTUnwrap(panel.standardWindowButton(type)).isHidden) }
    let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    panel.sendEvent(move)
    for type in buttons { XCTAssertFalse(try XCTUnwrap(panel.standardWindowButton(type)).isHidden) }
    camera.cleanView = false
    for type in buttons { XCTAssertFalse(try XCTUnwrap(panel.standardWindowButton(type)).isHidden) }
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
