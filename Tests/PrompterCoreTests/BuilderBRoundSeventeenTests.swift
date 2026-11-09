import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundSeventeenTests: XCTestCase {
  func testReadingPageStatesItsScopeAtEverySize() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("BuilderBSeventeenScope")))
    let camera = CameraModel(defaults: freshDefaults("BuilderBSeventeenScopeCamera"))
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(ReadingSettingsPage(store: store, camera: camera).uiZoom(zoom), size: .init(width: 700, height: 900))
      defer { LibraryAX.close(window) }
      XCTAssertFalse(LibraryAX.named("Reading settings apply to all scripts. Save a reading preset to reuse a look.", in: host).isEmpty)
    }
  }

  func testExposureHelpUsesQualifiedLanguageAndExactRendererRanges() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBSeventeenExposure"))
    camera.guides.zebras = true
    camera.guides.falseColour = true
    let (window, host) = await LibraryAX.host(ExposureKeyHelp(model: camera), size: .init(width: 640, height: 1400))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named(ExposureGuidance.cameraJudgement, in: host).isEmpty)
    XCTAssertTrue(LibraryAX.named("Clipping", in: host).isEmpty)
    XCTAssertEqual(CameraExposure.bands.map { FalseColourKey.rangeLabel($0.range) },
      ["0–2.5%", "2.5–4%", "38–42%", "52–56%", "97–99%", "99–100%"])
    for (index, band) in CameraExposure.bands.enumerated() {
      XCTAssertFalse(LibraryAX.named("\(FalseColourKey.labels[index]). \(band.name)", in: host).isEmpty)
    }
    XCTAssertFalse(LibraryAX.named("Grey shows brightness between these bands.", in: host).isEmpty)
    XCTAssertFalse(ExposureLegend.zebraTitle(for: .brightAreas).contains("blown"))
  }
}

extension AppearanceSnapshotTests {
  func testBuilderBRoundSeventeenFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    let camera = CameraModel(defaults: freshDefaults("BuilderBSeventeenSnapshots"))
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      try await snapshot(ExposureLegend(model: camera, zoom: zoom), name: "b17-narrow-strip-\(Int(zoom * 100))-\(mode)", size: .init(width: 240, height: 100), scheme: scheme, destination: destination)

    }
  }
}
