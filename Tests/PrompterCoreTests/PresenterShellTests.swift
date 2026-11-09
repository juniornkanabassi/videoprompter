import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class PresenterShellTests: XCTestCase {
  private func fixture() async throws -> (AppStore, CameraModel, CameraRecorder, PresenterDraft) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("PackageE")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Reading", markdown: String(repeating: "Keep the exact word in place. ", count: 20))
    store.settings.mode = "Manual"
    store.settings.videoDimming = 0.55
    store.settings.fontSize = 52
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    camera.guides.zebras = true
    return (store, camera, CameraRecorder(defaults: defaults), PresenterDraft(record: record))
  }

  func testEscapeClosesAdjustThenReturnsToSetupAndExitsClean() async throws {
    let (store, camera, _, _) = try await fixture()
    let shell = PresenterShell(reading: true, adjustTab: .zebras)
    XCTAssertTrue(shell.escape(camera: camera, session: store.session))
    XCTAssertNil(shell.adjustTab)
    XCTAssertTrue(shell.reading)
    XCTAssertTrue(shell.escape(camera: camera, session: store.session))
    XCTAssertFalse(shell.reading)
    camera.cleanView = true
    XCTAssertTrue(shell.escape(camera: camera, session: store.session))
    XCTAssertFalse(camera.cleanView)
    XCTAssertFalse(shell.escape(camera: camera, session: store.session))
  }

  func testCleanPausesOnExactWordAndHidesEveryControl() async throws {
    let (store, camera, recorder, draft) = try await fixture()
    let shell = PresenterShell(reading: true)
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder, shell: shell), size: .init(width: 1600, height: 1000))
    defer { store.session.pause(); LibraryAX.close(window) }
    store.session.seek(to: 7)
    store.session.play(captureAudio: false)
    let word = store.session.tokenIndex
    camera.cleanView = true
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(store.session.isActivelyRunning)
    XCTAssertEqual(store.session.tokenIndex, word)
    for title in ["Start reading", "Pause", "Camera", "Adjust", "Clean", "Back to start"] {
      XCTAssertTrue(LibraryAX.named(title, in: host).isEmpty, title)
    }
    NotificationCenter.default.post(name: .init("VideoPrompter.presenterInteraction"), object: nil)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(LibraryAX.named("Exit Clean · Esc", in: host).isEmpty)
    try await Task.sleep(for: .milliseconds(2200))
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(LibraryAX.named("Exit Clean · Esc", in: host).isEmpty)
    shell.escape(camera: camera, session: store.session)
    XCTAssertEqual(store.session.tokenIndex, word)
    XCTAssertFalse(store.session.isActivelyRunning)
  }

  func testSetupLabelsAndRealToggleValuesPersistAt200Percent() async throws {
    let (store, camera, recorder, draft) = try await fixture()
    for zoom in [1.0, 1.25, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 1600, height: 1200))
      for title in ["Start reading", "Back to start", "Camera", "Zebras", "False colour", "Guides", "Mic", "Adjust", "Clean"] {
        let node = try XCTUnwrap(LibraryAX.named(title, in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" }, title)
        let frame = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), "\(title) at \(zoom): \(frame)")
        XCTAssertGreaterThanOrEqual(frame.height, 44)
      }
      for title in ["Camera", "Adjust"] {
        let node = try XCTUnwrap(LibraryAX.named(title, in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
        XCTAssertFalse(["On", "Off"].contains(LibraryAX.value(node, "accessibilityValue")))
      }
      LibraryAX.close(window)
    }
  }

  func testReadingShowsOnlyReadingTransport() async throws {
    let (store, camera, recorder, draft) = try await fixture()
    let shell = PresenterShell(reading: true)
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder, shell: shell), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named("Set up the shot", in: host).isEmpty)
    XCTAssertTrue(LibraryAX.named("Adjust", in: host).isEmpty)
    XCTAssertTrue(LibraryAX.named("Camera", in: host).isEmpty)
  }
}

extension AppearanceSnapshotTests {
  func testPackageEShell() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let defaults = freshDefaults("PackageESnapshots")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Matchday", markdown: "Arsenal went to Anfield with a plan.\n\nAnd that is why the back three changed everything this season.\n\nWatch where Saliba stands when the ball goes wide.")
    store.settings.mode = "Manual"
    store.settings.videoDimming = 0.55
    store.settings.fontSize = 52
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    camera.guides.zebras = true
    camera.setRotation(.threeQuarters)
    camera.pictureSizeOverride = .init(width: 1920, height: 1080)
    let destination = URL(fileURLWithPath: output)
    for state in ["setup", "reading", "clean", "setup-200"] {
      store.uiZoom = state == "setup-200" ? 2 : 1
      camera.cleanView = state == "clean"
      if state == "reading" { store.session.play(captureAudio: false) } else { store.session.pause() }
      let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder, shell: PresenterShell(reading: state == "reading"), referencePicture: NSImage(contentsOf: Bundle.module.url(forResource: "presenter-" + (state.hasPrefix("setup") ? "zebras" : "clean"), withExtension: "png", subdirectory: "Fixtures")!)).environment(\.presenterReduceTransparency, false)
      try await snapshot(view, name: "pkgE-\(state)", size: .init(width: 1600, height: 1000), scheme: .dark, destination: destination)
    }
    store.session.pause()
    camera.cleanView = false
    for tab in AdjustTab.allCases {
      try await snapshot(AdjustPanel(selection: .constant(tab), showsMic: .constant(true), camera: camera, store: store, startsMeter: false, devicesOverride: [CameraDevice(uid: "fixture", name: "Cam Link 4K", nickname: "Sony FX3")], recorder: recorder), name: "pkgE-adjust-\(tab.rawValue)", size: .init(width: 470, height: 868), scheme: .dark, destination: destination)
    }
  }
}
