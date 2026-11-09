import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testG1PresenterMatrixAndEditor() async throws {
    let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"]
    let defaults = freshDefaults("G1Presenter")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Matchday", markdown: "Arsenal went to Anfield with a plan.\n\nAnd that is why the back three changed everything this season.\n\nWatch where Saliba stands when the ball goes wide.")
    store.settings.mode = "Manual"
    store.settings.fontSize = 52
    store.settings.videoDimming = 0.55
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    camera.guides.zebras = true
    camera.setRotation(.threeQuarters)
    let picture = try XCTUnwrap(NSImage(contentsOf: Bundle.module.url(forResource: "presenter-zebras", withExtension: "png", subdirectory: "Fixtures")!))
    for size in [CGSize(width: 1000, height: 700), CGSize(width: 1600, height: 1000)] {
      for zoom in [1.0, 1.5, 2.0] {
        for state in ["setup", "reading", "editing"] {
          if state == "editing" && (zoom != 2 || size.width != 1000) { continue }
          store.uiZoom = zoom
          if state == "reading" { store.session.play(captureAudio: false) } else { store.session.pause() }
          let draft = PresenterDraft(record: record)
          if state == "editing" { draft.begin(session: store.session) }
          let view = PresenterView(store: store, session: store.session, draft: draft, camera: camera,
            startsCamera: false, recorder: recorder, shell: PresenterShell(reading: state == "reading"),
            referencePicture: picture, sourceInfoOverride: CameraSourceInfo(displayName: "Sony FX3", connection: .hdmiCapture, width: 3840, height: 2160, nominalFrameRate: 25))
            .environment(\.presenterReduceTransparency, false)
          let (window, host) = await LibraryAX.host(view, size: size)
          let nodes = LibraryAX.elements(host)
          if state == "reading" {
            let chip = try XCTUnwrap(nodes.first { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-exposure-legend" })
            let script = try XCTUnwrap(nodes.first { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-script-content" })
            let chipFrame = try XCTUnwrap(chip.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let scriptFrame = try XCTUnwrap(script.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            XCTAssertFalse(chipFrame.intersects(scriptFrame), "Chip must not cover the reading viewport at \(size), \(zoom)")
          }
          if state == "setup" {
            let cameraButton = try XCTUnwrap(LibraryAX.named("Camera", in: host).first)
            XCTAssertEqual(LibraryAX.value(cameraButton, "accessibilityValue"), "Sony FX3, Turned right for vertical")
            let stage = try XCTUnwrap(nodes.first { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-visible-stage" })
            let pictureRegion = try XCTUnwrap(nodes.first { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-picture-region" })
            let stageFrame = try XCTUnwrap(stage.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let pictureFrame = try XCTUnwrap(pictureRegion.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let windowCentre = window.convertToScreen(host.convert(host.bounds, to: nil)).midX
            XCTAssertEqual(pictureFrame.midX, windowCentre, accuracy: 2, "Setup picture must be centred")
            let key = try XCTUnwrap(nodes.first { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-exposure-legend" })
            let keyFrame = try XCTUnwrap(key.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            XCTAssertTrue(stageFrame.contains(keyFrame), "Exposure key must remain visible")
            XCTAssertFalse(LibraryAX.named("Hide key", in: host).isEmpty, "The compact key stays in place at every zoom")
          }
          if state == "editing" {
            let editor = try XCTUnwrap(nodes.compactMap { $0 as? NSTextView }.first { $0.isEditable })
            let usableWidth = editor.bounds.width - 2 * editor.textContainerInset.width
            XCTAssertGreaterThan(usableWidth, 400, "Editing must retain readable sentences")
            XCTAssertTrue(LibraryAX.named("No camera chosen", in: host).isEmpty)
            XCTAssertFalse(LibraryAX.named("Save changes", in: host).isEmpty)
          }
          XCTAssertFalse(window.isVisible)
          LibraryAX.close(window)
          if let output {
            try await snapshot(view, name: "g1-\(state)-\(Int(size.width))-\(Int(zoom * 100))", size: size, scheme: .dark, destination: URL(fileURLWithPath: output), settleDelay: .milliseconds(300))
          }
        }
      }
    }
    // Exercise the minimum-height column and a landscape picture at narrow widths.
    store.session.pause()
    camera.setRotation(.none)
    let landscape = NSImage(size: NSSize(width: 1600, height: 900))
    landscape.lockFocus()
    NSColor.darkGray.setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 900).fill()
    picture.draw(in: NSRect(x: 500, y: 0, width: 600, height: 900))
    landscape.unlockFocus()
    for (size, zoom) in [(CGSize(width: 720, height: 520), 2.0),
                         (CGSize(width: 1000, height: 700), 1.0),
                         (CGSize(width: 1000, height: 700), 2.0),
                         (CGSize(width: 1600, height: 1000), 1.0)] {
      store.uiZoom = zoom
      let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record),
        camera: camera, startsCamera: false, recorder: recorder, referencePicture: landscape,
        sourceInfoOverride: CameraSourceInfo(displayName: "Sony FX3", connection: .hdmiCapture, width: 3840, height: 2160, nominalFrameRate: 25))
      let (window, host) = await LibraryAX.host(view, size: size)
      let nodes = LibraryAX.elements(host)
      func frame(_ id: String) throws -> CGRect {
        let node = try XCTUnwrap(nodes.first { LibraryAX.value($0, "accessibilityIdentifier") == id })
        return try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      }
      if size.width == 720 {
        XCTAssertFalse(try frame("presenter-exposure-legend").intersects(frame("presenter-source-status")))
      } else {
        let stage = try frame("presenter-visible-stage")
        let region = try frame("presenter-picture-region")
        let pictureWidth = min(region.width, region.height * 16 / 9)
        XCTAssertGreaterThanOrEqual(pictureWidth, stage.width * 0.5 - 1)
      }
      XCTAssertFalse(window.isVisible)
      LibraryAX.close(window)
      if let output, size.width != 720 {
        try await snapshot(view, name: "g1-landscape-\(Int(size.width))-\(Int(zoom * 100))", size: size, scheme: .dark, destination: URL(fileURLWithPath: output))
      }
    }
    store.session.pause()
    store.uiZoom = 1
    camera.guides.falseColour = true
    camera.guides.thirds = true
    camera.exposureBypassed = true
    camera.framingGuidesBypassed = true
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session,
      draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder),
      size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    for title in ["Zebras", "False colour", "Guides"] {
      let tile = try XCTUnwrap(LibraryAX.named(title, in: host).first { ["AXButton", "AXCheckBox"].contains(LibraryAX.value($0, "accessibilityRole")) })
      XCTAssertEqual(LibraryAX.value(tile, "accessibilityValue"), "Off", title)
    }
  }
}

extension AppearanceSnapshotTests {
  func testG1MicNameAtPresenterWidth() async throws {
    let name = "ZOOM UAC-232"
    let view = MicMeterView(meter: InputMeter(), micName: name)
      .frame(width: 120, height: 192).uiZoom(2).background(.black)
    let (window, host) = await LibraryAX.host(view, size: .init(width: 240, height: 384))
    defer { LibraryAX.close(window) }
    XCTAssertTrue(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityLabel").contains(name) })
    XCTAssertFalse(window.isVisible)
    if let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] {
      try await snapshot(view, name: "g1-mic-name-200", size: .init(width: 240, height: 384), scheme: .dark, destination: URL(fileURLWithPath: output))
    }
  }
}
