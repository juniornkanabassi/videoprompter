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
    XCTAssertFalse(LibraryAX.named("Exit Clean · Esc", in: host).isEmpty, "Faded Clean exit remains reachable by keyboard")
    shell.escape(camera: camera, session: store.session)
    XCTAssertEqual(store.session.tokenIndex, word)
    XCTAssertFalse(store.session.isActivelyRunning)
  }

  func testSetupLabelsAndRealToggleValuesPersistAt200Percent() async throws {
    let (store, camera, recorder, draft) = try await fixture()
    for zoom in [1.0, 1.25, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 1600, height: 1200))
      for title in ["Start reading", "Back to start", "Open script", "Camera", "Zebras", "False colour", "Adjust", "Clean"] {
        let node = try XCTUnwrap(LibraryAX.named(title, in: host).first { ["AXButton", "AXCheckBox"].contains(LibraryAX.value($0, "accessibilityRole")) }, title)
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

  func testNormalTileClickRestoresBypassedExposureAndShowsAdjustState() async throws {
    let (store, camera, recorder, draft) = try await fixture()
    camera.exposureBypassed = true
    let shell = PresenterShell()
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: draft,
      camera: camera, startsCamera: false, recorder: recorder, shell: shell), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    let zebra = try XCTUnwrap(LibraryAX.named("Zebras", in: host).first { $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) })
    XCTAssertEqual(LibraryAX.value(zebra, "accessibilityValue"), "Off")
    XCTAssertTrue(LibraryAX.bool(zebra, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(camera.exposureBypassed)
    XCTAssertTrue(camera.guides.zebras)
    let adjust = try XCTUnwrap(LibraryAX.named("Adjust", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
    XCTAssertTrue(LibraryAX.bool(adjust, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNotNil(shell.adjustTab)
    XCTAssertTrue(LibraryAX.named("Adjust", in: host).contains { LibraryAX.value($0, "accessibilityValue") == "Expanded" })
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


extension AppearanceSnapshotTests {
  func testF1StageMatrix() async throws {
    let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"]
    let defaults = freshDefaults("F1StageMatrix")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Matchday", markdown: "Arsenal went to Anfield with a plan.\n\nAnd that is why the back three changed everything this season.\n\nWatch where Saliba stands when the ball goes wide.")
    store.settings.mode = "Manual"; store.settings.fontSize = 52; store.settings.videoDimming = 0.55
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .prompterWithVideo; camera.guides.zebras = true
    camera.setRotation(.threeQuarters)
    let picture = NSImage(contentsOf: Bundle.module.url(forResource: "presenter-zebras", withExtension: "png", subdirectory: "Fixtures")!)!
    for size in [CGSize(width: 1000, height: 700), CGSize(width: 1600, height: 1000)] {
      for zoom in [1.0, 1.5, 2.0] {
        for state in ["setup", "reading"] {
          store.uiZoom = zoom
          if state == "reading" { store.session.play(captureAudio: false) } else { store.session.pause() }
          let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera,
            startsCamera: false, recorder: recorder, shell: PresenterShell(reading: state == "reading"), referencePicture: picture, sourceInfoOverride: CameraSourceInfo(displayName: "Sony FX3", connection: .hdmiCapture, width: 3840, height: 2160, nominalFrameRate: 25)).environment(\.presenterReduceTransparency, false)
          let (window, host) = await LibraryAX.host(view, size: size)
          let stage = try XCTUnwrap(LibraryAX.elements(host).first { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-visible-stage" })
          let frame = try XCTUnwrap(stage.value(forKey: "accessibilityFrame") as? NSValue).rectValue
          XCTAssertGreaterThanOrEqual(frame.height, size.height / 2, "\(size), \(zoom), \(state): \(frame)")
          XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame))
          let pictureRegion = try XCTUnwrap(LibraryAX.elements(host).first { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-picture-region" })
          let pictureFrame = try XCTUnwrap(pictureRegion.value(forKey: "accessibilityFrame") as? NSValue).rectValue
          XCTAssertGreaterThanOrEqual(pictureFrame.height, size.height / 2, "Visible picture region: \(pictureFrame)")
          print("F1 STAGE \(state) \(Int(size.width))x\(Int(size.height)) @\(zoom): \(frame.size), picture \(pictureFrame.size)")
          LibraryAX.close(window)
          if let output { try await snapshot(view, name: "f1-\(state)-\(Int(size.width))-\(Int(zoom * 100))", size: size, scheme: .dark, destination: URL(fileURLWithPath: output)) }
        }
      }
    }
    store.session.pause()
    camera.cleanView = true
    let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera,
      startsCamera: false, recorder: recorder, referencePicture: NSImage(contentsOf: Bundle.module.url(forResource: "presenter-clean", withExtension: "png", subdirectory: "Fixtures")!), revealsCleanExit: true)
    if let output { try await snapshot(view, name: "f1-exit-pill-visible", size: CGSize(width: 1600, height: 1000), scheme: .dark, destination: URL(fileURLWithPath: output)) }
  }
}
