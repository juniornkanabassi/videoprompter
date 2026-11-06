import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundFiveTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBRoundFive")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults))
  }

  func testPracticeSavesSelectsAndReusesShortGuidedScriptWithoutStartingCapture() async throws {
    let (store, _) = fixture()
    let first = try await PracticeReading.prepare(store: store)
    XCTAssertEqual(store.selectedID, first)
    XCTAssertEqual(store.selected?.metadata.title, PracticeReading.title)
    let words = PrompterDocument(markdown: try XCTUnwrap(store.selected?.markdown)).spokenTokens.count
    XCTAssertTrue((50...120).contains(words))
    XCTAssertTrue(store.selected!.markdown.contains("Press Start reading"))
    XCTAssertTrue(store.selected!.markdown.contains("follows my voice"))
    let repeated = try await PracticeReading.prepare(store: store)
    XCTAssertEqual(repeated, first)
    XCTAssertFalse(store.session.state == .running)
    store.settings.mode = "Manual"
    _ = try await PracticeReading.prepare(store: store)
    XCTAssertEqual(store.settings.mode, "Manual")
    XCTAssertTrue(store.selected!.markdown.contains("steady speed"))
  }

  func testPracticeOpensThePreparedScript() async throws {
    let (store, camera) = fixture()
    camera.displayMode = .videoOnly
    camera.cleanView = true
    var shown: [UUID] = []
    await PracticeReading.present(store: store, camera: camera) { prepared in
      XCTAssertEqual(camera.displayMode, .prompterOnly)
      XCTAssertFalse(camera.cleanView)
      if let id = prepared.selectedID { shown.append(id) }
    }
    camera.restoreSavedDisplayMode()
    XCTAssertEqual(camera.displayMode, .videoOnly, "Practice must preserve the saved view preference")
    XCTAssertEqual(shown, [try XCTUnwrap(store.selectedID)])
    XCTAssertEqual(store.selected?.metadata.title, PracticeReading.title)
    XCTAssertFalse(store.session.state == .running)
  }

  func testPracticeButtonInvokesGuidedTry() async throws {
    let (store, _) = fixture()
    var tried = false
    let (window, host) = await LibraryAX.host(LibraryStartView(store: store, importing: .constant(false), practice: { tried = true }, camera: {}))
    defer { LibraryAX.close(window) }
    let button = try XCTUnwrap(LibraryAX.named("Try the Practice Script", in: host).first)
    XCTAssertTrue(LibraryAX.bool(button, "accessibilityPerformPress"))
    XCTAssertTrue(tried)
  }

  func testLibraryFoldersStayVisibleWithSameNavigationAtEveryZoom() async throws {
    let (store, camera) = fixture()
    let folder = try await store.createLibraryFolder(named: "Drafts")
    let script = try await store.createScript(title: "My opening", markdown: "Read these words.")
    store.selectedID = script.id
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1440, height: 900))
      defer { LibraryAX.close(window) }
      for label in ["All Scripts", "Drafts", "Recently Deleted", "My opening", "Editor text size"] {
        XCTAssertFalse(LibraryAX.named(label, in: host).isEmpty, "\(label), zoom \(zoom)")
      }
      XCTAssertTrue(LibraryAX.named("Script folder", in: host).isEmpty, "No replacement popup navigation")
      XCTAssertEqual(store.selectedID, script.id)
      XCTAssertNotNil(store.folders.first { $0.id == folder.id })
    }
  }

  func testContrastDoesNotApproveDarkTextOverUnknownCameraOrDimCues() throws {
    XCTAssertEqual(ReadingContrast.worstCase(textHex: "#000000", textOpacity: 1, backgroundHex: "#000000", darkness: 0), 1)
    XCTAssertEqual(ReadingContrast.worstCase(textHex: "#808080", textOpacity: 1, backgroundHex: "#000000", darkness: 0), 1)
    XCTAssertLessThan(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 0.42, backgroundHex: "#000000", darkness: 0.5), 3)
    let minimum = try XCTUnwrap(ReadingContrast.minimumDarkness(textHex: "#FFFFFF", textOpacity: 0.42, backgroundHex: "#000000"))
    XCTAssertGreaterThan(minimum, 0.5)
    XCTAssertGreaterThanOrEqual(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 0.42, backgroundHex: "#000000", darkness: minimum), 3)
    XCTAssertNil(ReadingContrast.minimumDarkness(textHex: "#FFFFFF", textOpacity: 0.42, backgroundHex: "#000000", threshold: 4.5))
  }

  func testExposureExplainsFaceAndEveryColour() async throws {
    let (store, camera) = fixture()
    camera.guides.zebras = true
    camera.guides.zebraRange = 5
    let (window, host) = await LibraryAX.host(ExposureGuidance(zebras: true, face: true, falseColour: true))
    defer { LibraryAX.close(window) }
    let allText = LibraryAX.elements(host).map { LibraryAX.value($0, "accessibilityValue") }.joined(separator: " ")
    XCTAssertTrue(allText.contains("lit cheek"))
    XCTAssertTrue(allText.contains("log footage"))
    XCTAssertEqual(ExposureGuidance.colourMeanings.count, CameraExposure.bands.count)
    XCTAssertTrue(ExposureGuidance.colourMeanings.allSatisfy { $0.contains(".") })
    XCTAssertEqual(store.settings.mode, "Voice")
  }

  func testModernIconHasSeparateVectorObjectsAndThreeAppearances() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let icon = root.appendingPathComponent("Resources/AppIcon/VideoPrompter.icon")
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: icon.appendingPathComponent("icon.json"))) as? [String: Any])
    let groups = try XCTUnwrap(json["groups"] as? [[String: Any]])
    XCTAssertEqual(groups.count, 3)
    for group in groups {
      let layers = try XCTUnwrap(group["layers"] as? [[String: Any]])
      for layer in layers {
        let image = try XCTUnwrap(layer["image-name"] as? String)
        XCTAssertTrue(image.hasSuffix(".svg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.appendingPathComponent("Assets/" + image).path))
        XCTAssertEqual((layer["opacity-specializations"] as? [[String: Any]])?.count, 3)
      }
    }
    let background = try String(contentsOf: icon.appendingPathComponent("Assets/Background-Default.svg"), encoding: .utf8)
    XCTAssertTrue(background.contains("M0 0H1024V1024H0Z"), "The system applies the outer mask")
  }
}
