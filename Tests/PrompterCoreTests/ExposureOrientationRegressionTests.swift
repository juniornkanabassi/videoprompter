import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import VideoPrompter

final class ExposureOrientationRegressionTests: XCTestCase {
  /// A connection with a device's non-zero defaults, without opening any capture device.
  private final class Connection: AVCaptureConnection, @unchecked Sendable {
    var angle: CGFloat = 90
    var mirror = true
    var automaticMirror = true
    override var videoRotationAngle: CGFloat {
      get { angle }
      set { angle = newValue }
    }
    override func isVideoRotationAngleSupported(_ angle: CGFloat) -> Bool { true }
    override var isVideoMirroringSupported: Bool { true }
    override var isVideoMirrored: Bool {
      get { mirror }
      set { mirror = newValue }
    }
    override var automaticallyAdjustsVideoMirroring: Bool {
      get { automaticMirror }
      set { automaticMirror = newValue }
    }
  }

  func testAnalysisConnectionDiscardsDeviceRotationAndMirrorDefaults() {
    let connection = Connection(inputPorts: [], output: AVCaptureVideoDataOutput())
    for rotation in CameraRotation.allCases {
      connection.angle = CGFloat(rotation.rawValue)
      connection.mirror = true
      connection.automaticMirror = true
      CameraRotation.keepSensorOrientation(connection)
      XCTAssertEqual(connection.videoRotationAngle, 0)
      XCTAssertFalse(connection.isVideoMirrored)
      XCTAssertFalse(connection.automaticallyAdjustsVideoMirroring)
    }
  }

  func testBothAnalysisOutputsNormaliseTheirConnectionsAtAttachment() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for name in ["CameraExposure", "CameraOrientation"] {
      let source = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Camera/\(name).swift"), encoding: .utf8)
      XCTAssertTrue(source.contains("CameraRotation.keepSensorOrientation(output.connection(with: .video))"), name)
    }
  }

  @MainActor func testExposureTogglesKeepOverlayCornersAlignedAtEveryRotationAndMirror() throws {
    let view = CameraStageView(frame: CGRect(x: 0, y: 0, width: 720, height: 520))
    defer { view.stop() }
    let aspect = SharedCameraSession.shared.pictureSize ?? CGSize(width: 16, height: 9)
    for rotation in CameraRotation.allCases {
      for mirrored in [false, true] {
        var guides = CameraGuides()
        guides.rotation = rotation
        let picture = rotation.fittedRect(aspect: aspect, in: view.bounds)
        let expected = CALayer()
        CameraStageView.place(expected, on: picture, turnedBy: rotation)
        if mirrored {
          expected.setAffineTransform(expected.affineTransform().concatenating(CGAffineTransform(scaleX: -1, y: 1)))
        }
        for (zebras, falseColour) in [(false, false), (true, false), (true, true), (false, true), (false, false)] {
          guides.zebras = zebras; guides.falseColour = falseColour
          view.apply(uid: nil, guides: guides, mirrored: mirrored)
          view.layoutSubtreeIfNeeded()
          XCTAssertEqual(view.pictureLayer.bounds, expected.bounds)
          XCTAssertEqual(view.pictureLayer.position, expected.position)
          XCTAssertEqual(view.pictureLayer.affineTransform(), expected.affineTransform())
          for overlay in [view.zebraMask, view.falseColourLayer] {
            XCTAssertEqual(overlay.frame, view.pictureLayer.bounds)
            XCTAssertEqual(overlay.affineTransform(), .identity)
          }
          XCTAssertEqual(guides.rotation, rotation)
        }
      }
    }
  }

  func testLegendUsesTheActiveSkinTableAndRange() throws {
    var settings = CameraExposure.Settings(zebras: true, zebraLevel: 45, zebraRange: 2, falseColour: true)
    XCTAssertEqual(settings.zebraRangeLabel, "43 to 47")
    let skin = try XCTUnwrap(settings.legendBands.first { $0.label == "Skin" })
    XCTAssertEqual(skin.range, "43 to 47")
    XCTAssertEqual(skin.colour, settings.colourTable[Int(CameraExposure.code(ire: 45))])
    XCTAssertNotEqual(skin.colour, settings.colourTable[Int(CameraExposure.code(ire: 54))])
    for band in settings.legendBands { XCTAssertTrue(settings.colourTable.contains(band.colour)) }
    settings.zebraLevel = 95; settings.zebraRange = 0
    XCTAssertEqual(settings.zebraRangeLabel, "95+")
    XCTAssertNil(settings.legendBands.first { $0.label == "Skin" })
    XCTAssertEqual(settings.legendBands.first { $0.label == "Brighter mid-tones" }?.range, "52 to 56")
    settings.zebraLevel = 40; settings.zebraRange = 1
    XCTAssertTrue(try XCTUnwrap(settings.legendBands.first { $0.label == "Mid grey" }).range.contains(", "),
                  "A skin range splitting mid grey must not label the missing middle as green")
  }

  func testZebraModeSwitchReadoutAndStoredDefault() {
    var guides = CameraGuides.firstUse
    XCTAssertEqual(guides.zebraLevel, 45)
    XCTAssertEqual(guides.zebraRange, 2)
    XCTAssertEqual(guides.exposure.zebraReadout, "Stripes on 43 to 47 IRE")
    guides.zebraRange = 7
    guides.zebraRangeMode = false
    XCTAssertEqual(guides.zebraRange, 0)
    XCTAssertEqual(guides.zebraLevel, 45)
    XCTAssertEqual(guides.exposure.zebraReadout, "Stripes on 45 IRE and above")
    guides.zebraRangeMode = true
    XCTAssertEqual(guides.zebraRange, 2)
    guides.useZebraPreset(.brightAreas)
    XCTAssertEqual(guides.exposure.zebraReadout, "Stripes on 95 IRE and above")
    XCTAssertEqual(guides.exposure.zebraLegend, "Zebras: Limit 95 IRE and above")
    guides.zebraRangeMode = true
    XCTAssertEqual(guides.exposure.zebraLegend, "Zebras: Range 93 to 97 IRE")
    guides.zebraLevel = 0; guides.zebraRange = 10
    XCTAssertEqual(guides.exposure.zebraReadout, "Stripes on 0 to 10 IRE")
    guides.zebraLevel = 100
    XCTAssertEqual(guides.exposure.zebraReadout, "Stripes on 90 to 100 IRE")
    let store = CameraGuideStore(defaults: freshDefaults("ZebraMode"))
    store.set(guides, for: "camera-a")
    XCTAssertEqual(store.guides(for: "camera-a"), guides)
    XCTAssertEqual(store.guides(for: "camera-b"), .firstUse)
  }

  private struct ZebraControlsHost: View {
    @ObservedObject var camera: CameraModel
    var body: some View { ZebraSettings(guides: $camera.guides) }
  }

  @MainActor func testZebraControlsSwitchModeAndApplyPresets() async throws {
    let camera = CameraModel(defaults: freshDefaults("ZebraControls"))
    camera.guides = .firstUse
    let (window, host) = await LibraryAX.host(ZebraControlsHost(camera: camera), size: .init(width: 360, height: 240))
    defer { LibraryAX.close(window) }
    func settle() async throws {
      for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    }
    try await settle()
    XCTAssertFalse(LibraryAX.named("Stripes on 43 to 47 IRE", in: host).isEmpty)
    let limit = try XCTUnwrap(LibraryAX.named("Limit", in: host).first)
    _ = LibraryAX.bool(limit, "accessibilityPerformPress")
    try await settle()
    XCTAssertEqual(camera.guides.zebraRange, 0)
    XCTAssertFalse(LibraryAX.named("Stripes on 45 IRE and above", in: host).isEmpty)
    let range = try XCTUnwrap(LibraryAX.named("Range", in: host).first)
    _ = LibraryAX.bool(range, "accessibilityPerformPress")
    try await settle()
    XCTAssertEqual(camera.guides.zebraRange, 2)
    let clipping = try XCTUnwrap(LibraryAX.named("Clipping 95+", in: host).first)
    XCTAssertTrue(LibraryAX.bool(clipping, "accessibilityPerformPress"))
    try await settle()
    XCTAssertFalse(LibraryAX.named("Stripes on 95 IRE and above", in: host).isEmpty)
    let skin = try XCTUnwrap(LibraryAX.named("Skin 45 ±2", in: host).first)
    XCTAssertTrue(LibraryAX.bool(skin, "accessibilityPerformPress"))
    try await settle()
    XCTAssertEqual(camera.guides.zebraLevel, 45)
    XCTAssertEqual(camera.guides.zebraRange, 2)
    XCTAssertEqual(camera.guides.validatedZebraPurpose, .faceReference)
  }

  @MainActor func testLegendTogglePersistsAndCleanViewHidesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExposureLegend-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("ExposureLegend")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .videoOnly
    camera.guides.zebras = true
    camera.guides.zebraLevel = 45; camera.guides.zebraRange = 2
    let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(), hasScript: false,
                             camera: camera, startsCamera: false, recorder: recorder).defaultAppStorage(defaults)
    let (window, host) = await LibraryAX.host(view, size: .init(width: 720, height: 520))
    defer { LibraryAX.close(window) }
    func settle() async throws {
      for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    }
    try await settle()
    XCTAssertFalse(LibraryAX.named("Zebras: Range 43 to 47 IRE", in: host).isEmpty)
    let toggle = try XCTUnwrap(LibraryAX.named("Legend", in: host).first)
    XCTAssertTrue(LibraryAX.bool(toggle, "accessibilityPerformPress"))
    try await settle()
    XCTAssertEqual(defaults.object(forKey: "presenterExposureLegend") as? Bool, false)
    XCTAssertTrue(LibraryAX.named("Zebras: Range 43 to 47 IRE", in: host).isEmpty)
    XCTAssertTrue(LibraryAX.bool(toggle, "accessibilityPerformPress"))
    try await settle()
    XCTAssertEqual(defaults.object(forKey: "presenterExposureLegend") as? Bool, true)
    camera.cleanView = true
    try await settle()
    XCTAssertTrue(LibraryAX.named("Zebras: Range 43 to 47 IRE", in: host).isEmpty)
    camera.cleanView = false; camera.guides.zebras = false; camera.guides.falseColour = false
    try await settle()
    XCTAssertTrue(LibraryAX.named("Zebras: Range 43 to 47 IRE", in: host).isEmpty)
  }
}
