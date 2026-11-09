import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundNineTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBNine")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults))
  }

  func testPracticeButtonCallsPracticeWithoutCreatingOrRecording() async throws {
    let (store, _) = fixture()
    let originalScripts = store.scripts.count
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      var practices = 0
      let (window, host) = await LibraryAX.host(LibraryStartView(store: store, importing: .constant(false),
        practice: { practices += 1 }, camera: {}).uiZoom(zoom), size: .init(width: 840, height: 800))
      defer { LibraryAX.close(window) }
      let button = try XCTUnwrap(LibraryAX.named("Quick Reading Practice", in: host).first)
      XCTAssertEqual(LibraryAX.value(button, "accessibilityRole"), "AXButton")
      XCTAssertTrue(LibraryAX.bool(button, "accessibilityPerformPress"))
      XCTAssertEqual(practices, 1)
      XCTAssertEqual(store.scripts.count, originalScripts)
    }
  }

  func testSmallFolderListFitsItsRowsAndLeavesSpaceForScripts() async throws {
    let (store, camera) = fixture()
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1440, height: 900))
      defer { LibraryAX.close(window) }
      let folders = try XCTUnwrap(LibraryAX.named("Script folders", in: host).first)
      let frame = try XCTUnwrap(folders.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      XCTAssertLessThanOrEqual(frame.height, 80 * zoom, "Two scope rows should not reserve a large empty section")
      XCTAssertFalse(LibraryAX.named("All Scripts", in: host).isEmpty)
      XCTAssertFalse(LibraryAX.named("Recently Deleted", in: host).isEmpty)
      XCTAssertFalse(LibraryAX.named("Scripts", in: host).isEmpty)
    }
    for index in 0..<12 { _ = try await store.createLibraryFolder(named: "Folder \(index)") }
    store.uiZoom = 1
    let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1440, height: 900))
    defer { LibraryAX.close(window) }
    let folders = try XCTUnwrap(LibraryAX.named("Script folders", in: host).first)
    let frame = try XCTUnwrap(folders.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    XCTAssertLessThanOrEqual(frame.height, 222, "Allow the native list's two-point border around its 220-point viewport")
    XCTAssertGreaterThan(frame.height, 80)
  }

  func testEditorAndReadingSizesRemainIndependent() async throws {
    let (store, _) = fixture()
    let readingSize = store.settings.fontSize
    let (window, host) = await LibraryAX.host(EditorTextPopover(store: store))
    defer { LibraryAX.close(window) }
    let slider = try XCTUnwrap(LibraryAX.named("Editor text size", in: host).first {
      LibraryAX.value($0, "accessibilityRole") == "AXSlider"
    })
    let editorSize = store.previewFontSize
    _ = LibraryAX.bool(slider, "accessibilityPerformIncrement")
    XCTAssertGreaterThan(store.previewFontSize, editorSize)
    XCTAssertEqual(store.settings.fontSize, readingSize)
    XCTAssertFalse(LibraryAX.named("Changes only the writing surface.", in: host).isEmpty)
  }

  func testExposureNamesPurposeAndKeepsTeachingCollapsed() async throws {
    let (_, camera) = fixture()
    for purpose in CameraGuides.ZebraPurpose.allCases {
      camera.guides.useZebraPreset(purpose)
      camera.guides.zebras = true
      camera.guides.falseColour = true
      let (window, host) = await LibraryAX.host(ExposureLegend(model: camera), size: .init(width: 520, height: 600))
      defer { LibraryAX.close(window) }
      XCTAssertFalse(LibraryAX.named("Key", in: host).isEmpty)
      XCTAssertTrue(LibraryAX.named(ExposureLegend.zebraTitle(for: purpose), in: host).isEmpty)
      XCTAssertTrue(LibraryAX.named("Grey shows brightness between these bands.", in: host).isEmpty)
    }
    camera.guides.zebraLevel = 95
    camera.guides.zebraRange = 5
    XCTAssertEqual(ExposureLegend.zebraTitle(for: camera.guides.validatedZebraPurpose), "Zebras · Custom")
  }
}
