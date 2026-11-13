import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testAdjustTabsStayOnOneRow() async throws {
    let defaults = freshDefaults("AdjustTabsRow")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let view = AdjustPanel(selection: .constant(.zebras), showsMic: .constant(true), camera: CameraModel(defaults: defaults), store: store, startsMeter: false, devicesOverride: [], recorder: CameraRecorder(defaults: defaults))
    let (window, host) = await LibraryAX.host(view, size: .init(width: 470, height: 900))
    defer { LibraryAX.close(window) }
    let frames = try AdjustTab.allCases.map { tab in
      let button = try XCTUnwrap(LibraryAX.named(tab.rawValue, in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
      return try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    }
    XCTAssertEqual(Set(frames.map(\.minY)).count, 1, "All five tabs share one row")
    for (index, frame) in frames.enumerated() {
      XCTAssertGreaterThanOrEqual(frame.height, 44)
      for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
    }
    XCTAssertFalse(LibraryAX.named("Close Adjust", in: host).isEmpty)
    XCTAssertFalse(window.isVisible)
  }

  func testAdjustF2Snapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("AdjustF2Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    let devices = [CameraDevice(uid: "one", name: "Studio camera"), CameraDevice(uid: "two", name: "MacBook Pro camera")]
    camera.selectedUID = "one"
    for tab in AdjustTab.allCases {
      for zoom in [1.0, 2.0] {
        for size in [CGSize(width: 1600, height: 1000), CGSize(width: 1000, height: 700)] {
          let view = AdjustPanel(selection: .constant(tab), showsMic: .constant(true), camera: camera, store: store, startsMeter: false, zoom: zoom, width: 470 * zoom, devicesOverride: devices, recorder: recorder)
          try await snapshot(view, name: "f2-\(tab.rawValue.replacingOccurrences(of: " ", with: "-"))-\(Int(zoom * 100))-\(Int(size.width))", size: size, scheme: .dark, destination: URL(fileURLWithPath: output))
        }
      }
    }
  }
}

extension AppearanceSnapshotTests {
  func testG2AdjustSnapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("G2Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    let destination = URL(fileURLWithPath: output)
    for zoom in [1.0, 2.0] {
      for tab in AdjustTab.allCases {
        camera.guides = .firstUse
        camera.chooseGuide { $0.thirds = true; $0.axes = true }
        let view = AdjustPanel(selection: .constant(tab), showsMic: .constant(true), camera: camera, store: store, startsMeter: false, zoom: zoom, width: 470 * zoom, devicesOverride: [], recorder: recorder)
        try await snapshot(view, name: "g2-\(tab.rawValue)-\(Int(zoom * 100))", size: .init(width: 470 * zoom, height: 900 * zoom), scheme: .dark, destination: destination)
        if tab == .guides {
          try await snapshot(AlphaGuideSections(model: camera, advancedExpanded: true).padding(AlphaStyle.panelInset).uiZoom(zoom), name: "g2-guides-advanced-\(Int(zoom * 100))", size: .init(width: 470 * zoom, height: 1000 * zoom), scheme: .dark, destination: destination)
          camera.framingGuidesBypassed = true
          try await snapshot(view, name: "g2-guides-bypassed-\(Int(zoom * 100))", size: .init(width: 470 * zoom, height: 900 * zoom), scheme: .dark, destination: destination)
        }
        if tab == .falseColour {
          camera.exposureBypassed = true
          camera.setGreyCardCheck(true)
          try await snapshot(view, name: "g2-grey-card-\(Int(zoom * 100))", size: .init(width: 470 * zoom, height: 1200 * zoom), scheme: .dark, destination: destination)
        }
      }
    }
  }
}

extension AppearanceSnapshotTests {
  /// Round 4: the camera cards at the narrow, standard and wide panel and at 200% text, and the Advanced section opened.
  func testRound4CameraSnapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Round4Camera")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    let devices = [CameraDevice(uid: "fx3", name: "Sony FX3"), CameraDevice(uid: "mac", name: "MacBook Pro Camera")]
    camera.selectedUID = "fx3"
    // The same capture-card label the presenter fixtures show for the Sony FX3.
    let sourceInfo = ["fx3": CameraSourceInfo(displayName: "Sony FX3", connection: .hdmiCapture, width: 3840, height: 2160, nominalFrameRate: 25)]
    let destination = URL(fileURLWithPath: output)
    for (name, width, zoom) in [("narrow", 340.0, 1.0), ("standard", 470.0, 1.0), ("wide", 900.0, 1.0), ("200", 470.0, 2.0)] {
      camera.setRotation(.none)
      let view = AdjustPanel(selection: .constant(.camera), showsMic: .constant(true), camera: camera, store: store, startsMeter: false, zoom: zoom, width: width * zoom, devicesOverride: devices, sourceInfoOverride: sourceInfo, recorder: recorder)
      try await snapshot(view, name: "round4-camera-\(name)", size: .init(width: width * zoom, height: 900 * zoom), scheme: .dark, destination: destination)
    }
    camera.setRotation(.threeQuarters)
    let advanced = CameraAdjustView(model: camera, devicesOverride: devices, sourceInfoOverride: sourceInfo, initiallyAdvanced: true).padding(AlphaStyle.panelInset)
      .frame(width: 470, height: 900, alignment: .top).background(Color(white: 0.07)).environment(\.colorScheme, .dark).tint(AlphaStyle.accent)
    try await snapshot(advanced, name: "round4-camera-advanced", size: .init(width: 470, height: 900), scheme: .dark, destination: destination)
  }
}
