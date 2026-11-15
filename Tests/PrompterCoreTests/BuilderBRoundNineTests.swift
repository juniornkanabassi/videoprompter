import AppKit
import PrompterCore
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
      let button = try XCTUnwrap(LibraryAX.named("Practice with an example script", in: host).first)
      XCTAssertEqual(LibraryAX.value(button, "accessibilityRole"), "AXButton")
      XCTAssertTrue(LibraryAX.bool(button, "accessibilityPerformPress"))
      XCTAssertEqual(practices, 1)
      XCTAssertEqual(store.scripts.count, originalScripts)
    }
  }

  func testHomeOffersLibraryAndContinueForExistingScript() async throws {
    let (store, _) = fixture()
    let script = try await store.createScript(title: "Last script", markdown: "Words")
    var opened = false
    var continued = false
    let view = LibraryStartView(store: store, importing: .constant(false), practice: {}, camera: {},
      openScripts: { opened = true }, continueScript: { continued = true }, lastTitle: script.metadata.title)
    let (window, host) = await LibraryAX.host(view, size: .init(width: 1400, height: 900))
    defer { LibraryAX.close(window) }
    let open = try XCTUnwrap(LibraryAX.named("Open scripts", in: host).first)
    XCTAssertTrue(LibraryAX.bool(open, "accessibilityPerformPress"))
    XCTAssertTrue(opened)
    let resume = try XCTUnwrap(LibraryAX.named("Continue “Last script”", in: host).first)
    XCTAssertTrue(LibraryAX.bool(resume, "accessibilityPerformPress"))
    XCTAssertTrue(continued)
    XCTAssertTrue(LibraryAX.named("Practice with an example script", in: host).isEmpty)
    XCTAssertFalse(LibraryAX.named("No iPad connected", in: host).isEmpty)
  }

  func testHomeNavigationKeepsAndReopensLastScript() async throws {
    let (store, camera) = fixture()
    let script = try await store.createScript(title: "Resume me", markdown: "Words")
    let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1600, height: 900))
    defer { LibraryAX.close(window) }
    let resume = try XCTUnwrap(LibraryAX.named("Continue “Resume me”", in: host).first)
    XCTAssertTrue(LibraryAX.bool(resume, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(store.selectedID, script.id)
    XCTAssertTrue(LibraryAX.named("Continue “Resume me”", in: host).isEmpty)
    NotificationCenter.default.post(name: .videoPrompterHome, object: nil)
    try await Task.sleep(for: .milliseconds(150))
    let open = try XCTUnwrap(LibraryAX.named("Open scripts", in: host).first)
    XCTAssertTrue(LibraryAX.bool(open, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertNil(store.selectedID)
    XCTAssertFalse(LibraryAX.named("Scripts", in: host).isEmpty)
  }

  func testHomeIPadStatusIncludesNameAndTransport() {
    XCTAssertEqual(LibraryStartView.iPadStatus(nil, transport: nil), "No iPad connected")
    let state = PadRemote.State(scripts: [], presenting: nil, running: false, mode: "", speed: 0, word: 0, words: 0, deviceName: "Junior's iPad")
    for transport in ["USB-C", "Wi-Fi"] {
      XCTAssertEqual(LibraryStartView.iPadStatus(state, transport: transport), "Connected · Junior's iPad · \(transport)")
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
