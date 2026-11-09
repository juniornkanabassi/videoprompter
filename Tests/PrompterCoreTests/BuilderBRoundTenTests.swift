import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundTenTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBTen")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults))
  }

  func testFolderSheetsNameTheNativeInputAndValidateBlankNames() async throws {
    for zoom in [1.0, 1.5, 2.0] {
      for action in ["Create", "Save"] {
        var saves = 0
        let (window, host) = await LibraryAX.host(FolderSheetFixture(action: action, zoom: zoom, save: { saves += 1 }))
        defer { LibraryAX.close(window) }
        let field = try XCTUnwrap(LibraryAX.named("Folder name", in: host).first {
          LibraryAX.value($0, "accessibilityRole") == "AXTextField"
        })
        XCTAssertEqual(LibraryAX.value(field, "accessibilityLabel"), "Folder name")
        let submit = try XCTUnwrap(LibraryAX.named(action, in: host).first)
        XCTAssertFalse(LibraryAX.bool(submit, "isAccessibilityEnabled"))
        let native = try XCTUnwrap(LibraryAX.elements(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        native.stringValue = "Drafts"
        native.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: native))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(native.stringValue, "Drafts")
        let enabledSubmit = try XCTUnwrap(LibraryAX.named(action, in: host).first)
        XCTAssertTrue(LibraryAX.bool(enabledSubmit, "isAccessibilityEnabled"))
        XCTAssertTrue(LibraryAX.bool(enabledSubmit, "accessibilityPerformPress"))
        XCTAssertEqual(saves, 1)
      }
    }
  }

  func testEditorControlsHaveFullTargetsAndKeepTheScript() async throws {
    let (store, camera) = fixture()
    let markdown = "# My heading stays\n\nThe script is the main event."
    let script = try await store.createScript(title: "My heading stays", markdown: markdown)
    store.selectedID = script.id
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1200, height: 900))
      defer { LibraryAX.close(window) }
      for name in ["Editor text size", "Script details"] {
        let button = try XCTUnwrap(LibraryAX.named(name, in: host).first {
          LibraryAX.value($0, "accessibilityRole") == "AXButton"
        })
        let rect = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertGreaterThanOrEqual(rect.height, 24 * zoom - 0.5, "\(name) at \(zoom)")
        XCTAssertTrue(window.convertToScreen(host.bounds).contains(rect))
      }
      XCTAssertEqual(store.selected?.markdown, markdown)
    }
  }

  func testNewFolderSheetCreatesAndCancelsThroughTheLibrary() async throws {
    let (store, camera) = fixture()
    let (window, _) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1100, height: 800))
    defer { LibraryAX.close(window) }
    window.makeKeyAndOrderFront(nil)
    store.namingNewFolder = true
    try await Task.sleep(for: .milliseconds(200))
    let sheet = try XCTUnwrap(window.sheets.first)
    let root = try XCTUnwrap(sheet.contentView)
    let field = try XCTUnwrap(LibraryAX.elements(root).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    XCTAssertEqual(field.accessibilityLabel(), "Folder name")
    field.stringValue = "Rehearsals"
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    try await Task.sleep(for: .milliseconds(60))
    let create = try XCTUnwrap(LibraryAX.named("Create", in: root).first)
    XCTAssertTrue(LibraryAX.bool(create, "accessibilityPerformPress"))
    for _ in 0..<40 where store.folders.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(store.folders.map(\.name), ["Rehearsals"])
    XCTAssertFalse(store.namingNewFolder)

    store.namingNewFolder = true
    try await Task.sleep(for: .milliseconds(200))
    let secondSheet = try XCTUnwrap(window.sheets.first)
    let secondRoot = try XCTUnwrap(secondSheet.contentView)
    let freshField = try XCTUnwrap(LibraryAX.elements(secondRoot).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    XCTAssertEqual(freshField.stringValue, "")
    XCTAssertTrue(LibraryAX.bool(try XCTUnwrap(LibraryAX.named("Cancel", in: secondRoot).first), "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(store.namingNewFolder)
    XCTAssertEqual(store.folders.map(\.name), ["Rehearsals"])
  }

  func testExposurePurposeStaysVisibleBeforeAndAfterToggling() async throws {
    let (_, camera) = fixture()
    for purpose in CameraGuides.ZebraPurpose.allCases {
      camera.guides.useZebraPreset(purpose)
      camera.guides.zebras = false
      camera.guides.falseColour = false
      let original = camera.guides
      let (window, host) = await LibraryAX.host(Form { ExposureToolToggles(model: camera) }.formStyle(.grouped))
      defer { LibraryAX.close(window) }
      for (label, meaning) in [(ExposureLegend.zebraTitle(for: camera.guides.validatedZebraPurpose), ExposureGuidance.zebraPurpose(camera.guides)), ("False colour", ExposureGuidance.colourPurpose)] {
        XCTAssertFalse(LibraryAX.named(meaning, in: host).isEmpty)
        let toggle = try XCTUnwrap(LibraryAX.named(label, in: host).first {
          ["AXCheckBox", "AXSwitch"].contains(LibraryAX.value($0, "accessibilityRole"))
        })
        // NSSwitch can return false even after dispatching the press; assert the actual binding below.
        _ = LibraryAX.bool(toggle, "accessibilityPerformPress")
        try await Task.sleep(for: .milliseconds(40))
        let updated = try XCTUnwrap(LibraryAX.named(label, in: host).first {
          ["AXCheckBox", "AXSwitch"].contains(LibraryAX.value($0, "accessibilityRole"))
        })
        XCTAssertEqual(LibraryAX.value(updated, "accessibilityHelp"), meaning)
      }
      XCTAssertTrue(camera.guides.zebras)
      XCTAssertTrue(camera.guides.falseColour)
      XCTAssertEqual(camera.guides.zebraLevel, original.zebraLevel)
      XCTAssertEqual(camera.guides.zebraRange, original.zebraRange)
      XCTAssertEqual(camera.guides.validatedZebraPurpose, original.validatedZebraPurpose)
    }
  }
}

private struct FolderSheetFixture: View {
  @State private var name = " "
  let action: String
  let zoom: Double
  let save: () -> Void
  var body: some View {
    FolderNameSheet(title: action == "Create" ? "New Folder" : "Rename Folder",
      name: $name, action: action, zoom: zoom, cancel: {}, save: save)
  }
}

extension AppearanceSnapshotTests {
  func testBuilderBRoundTenFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    let camera = CameraModel(defaults: freshDefaults("BuilderBTenSnapshots"))
    for zoom in [1.0, 1.5, 2.0] {
      for action in ["Create", "Save"] {
        try await snapshot(FolderNameSheet(title: action == "Create" ? "New Folder" : "Rename Folder",
          name: .constant(action == "Create" ? "" : "Drafts"), action: action, zoom: zoom, cancel: {}, save: {}),
          name: "r10-folder-\(action)-\(Int(zoom * 100))-\(mode)", size: .init(width: min(360 * zoom, 640), height: 220 * zoom), scheme: scheme, destination: destination)
      }
      for on in [false, true] {
        camera.guides.zebras = on
        camera.guides.falseColour = on
        try await snapshot(Form { ExposureToolToggles(model: camera) }.formStyle(.grouped).uiZoom(zoom),
          name: "r10-exposure-toggles-\(on)-\(Int(zoom * 100))-\(mode)", size: .init(width: 520 * zoom, height: 220 * zoom), scheme: scheme, destination: destination)
      }
    }
  }
}
