import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundThirteenTests: XCTestCase {
  func testEveryBandAndZebraLimitAreVisibleWithoutScrollingAtEveryZoom() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBThirteen"))
    camera.guides.zebras = true
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      let (window, host) = await LibraryAX.host(ExposureLegend(model: camera, zoom: zoom), size: .init(width: 520, height: 520))
      defer { LibraryAX.close(window) }
      host.sizingOptions = []
      window.setContentSize(.init(width: 520, height: 520))
      host.frame = .init(x: 0, y: 0, width: 520, height: 520)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let bounds = host.convert(host.bounds, to: nil)
      let screenBounds = window.convertToScreen(bounds)
      let labels = CameraExposure.bands.enumerated().map { "\(FalseColourKey.labels[$0.offset]). \($0.element.name)" }
        + [ExposureLegend.compactMeasurement(level: camera.guides.zebraLevel, range: camera.guides.zebraRange)]
      for label in labels {
        let element = try XCTUnwrap(LibraryAX.named(label, in: host).first, label)
        let frame = try XCTUnwrap(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertGreaterThan(frame.width, 0, label)
        XCTAssertTrue(screenBounds.insetBy(dx: -1, dy: -1).contains(frame), "\(label) at \(zoom): \(frame) outside \(screenBounds)")
      }
      XCTAssertFalse(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityRole") == "AXScrollArea" }, "Only expanded teaching should scroll")
      XCTAssertTrue(LibraryAX.named(ExposureGuidance.colourMeanings[0], in: host).isEmpty)
    }
  }

  func testHighlightBandsStayAboveTransportInTheMinimumPresenter() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBThirteenPresenter")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let script = try await store.createScript(title: "Exposure check", markdown: "Read these words at your own pace.")
    store.settings.mode = "Manual"
    store.session.present(record: script, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    camera.recordingReadyOverride = true
    camera.guides.zebras = true; camera.guides.falseColour = true
    let recorder = CameraRecorder(defaults: defaults)
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session,
        draft: PresenterDraft(record: script), camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
      defer { LibraryAX.close(window) }
      host.sizingOptions = []
      window.setContentSize(.init(width: 720, height: 520))
      host.frame = .init(x: 0, y: 0, width: 720, height: 520)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let record = try XCTUnwrap(LibraryAX.named("Record", in: host).first)
      let transportFrame = try XCTUnwrap(record.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      let help = try XCTUnwrap(LibraryAX.named("How to read this", in: host).first)
      let helpFrame = try XCTUnwrap(help.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      XCTAssertGreaterThan(helpFrame.minY, transportFrame.maxY, "Help must stay above the transport at \(zoom)")
      for (index, band) in CameraExposure.bands.enumerated() {
        let node = try XCTUnwrap(LibraryAX.named("\(FalseColourKey.labels[index]). \(band.name)", in: host).first)
        let frame = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertGreaterThan(frame.minY, transportFrame.maxY, "\(band.name) overlaps transport at \(zoom): \(frame), \(transportFrame)")
      }
    }
  }

  func testVisibleFolderActionsUseSelectedFolderAndKeepItsScripts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("BuilderBThirteenFolders")))
    let folder = try await store.createLibraryFolder(named: "Drafts")
    store.selectFolder(folder.id)
    let script = try await store.createScript(title: "Retain me", markdown: "Keep these words.")
    var renamed: UUID?
    for selected in [nil, folder] {
      let (window, host) = await LibraryAX.host(VStack {
        LibraryFolderActions(store: store, folder: selected) { renamed = $0.id }
      })
      defer { LibraryAX.close(window) }
      let create = try XCTUnwrap(LibraryAX.named("New Folder…", in: host).first)
      let rename = try XCTUnwrap(LibraryAX.named("Rename Folder…", in: host).first)
      let remove = try XCTUnwrap(LibraryAX.named("Remove Folder, Keep Scripts", in: host).first)
      XCTAssertTrue(LibraryAX.bool(create, "isAccessibilityEnabled"))
      XCTAssertEqual(LibraryAX.bool(rename, "isAccessibilityEnabled"), selected != nil)
      XCTAssertEqual(LibraryAX.bool(remove, "isAccessibilityEnabled"), selected != nil)
      if selected != nil {
        XCTAssertTrue(LibraryAX.bool(rename, "accessibilityPerformPress"))
        XCTAssertEqual(renamed, folder.id)
        XCTAssertTrue(LibraryAX.bool(remove, "accessibilityPerformPress"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(store.folders.contains { $0.id == folder.id })
        XCTAssertTrue(store.scripts.contains { $0.id == script.id })
      } else {
        XCTAssertTrue(LibraryAX.bool(create, "accessibilityPerformPress"))
        XCTAssertTrue(store.namingNewFolder)
        store.namingNewFolder = false
      }
    }
  }

  func testEditorOffersDirectReadingSettingsWithoutLinkingSizes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("BuilderBThirteenEditor")))
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(EditorTextPopover(store: store), size: .init(width: 600, height: 600))
      defer { LibraryAX.close(window) }
      host.sizingOptions = []
      window.setContentSize(.init(width: 600, height: 600))
      host.frame = .init(x: 0, y: 0, width: 600, height: 600)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let button = try XCTUnwrap(LibraryAX.named("Reading text size…", in: host).first)
      let linkFrame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      XCTAssertTrue(window.convertToScreen(host.bounds).contains(linkFrame), "Reading link must stay visible at \(zoom)")
      XCTAssertEqual(LibraryAX.value(button, "accessibilityRole"), "AXLink")
      XCTAssertTrue(LibraryAX.bool(button, "isAccessibilityEnabled"))
      let readingSize = store.settings.fontSize
      let slider = try XCTUnwrap(LibraryAX.named("Editor text size", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXSlider" })
      XCTAssertTrue(LibraryAX.bool(slider, "accessibilityPerformIncrement"))
      XCTAssertEqual(store.settings.fontSize, readingSize)
    }
  }
}

extension AppearanceSnapshotTests {
  func testBuilderBRoundThirteenFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBThirteenSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    camera.guides.zebras = true
    camera.guides.falseColour = true
    camera.displayMode = .prompterWithVideo
    camera.recordingReadyOverride = true
    let script = try await store.createScript(title: "Exposure check", markdown: "Read these words at your own pace.")
    store.settings.mode = "Manual"
    store.session.present(record: script, settings: store.settings)
    let recorder = CameraRecorder(defaults: defaults)
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      try await snapshot(ExposureLegend(model: camera, zoom: zoom), name: "r13-monitor-key-\(Int(zoom * 100))-\(mode)", size: .init(width: 520, height: 520), scheme: scheme, destination: destination)
      try await snapshot(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: script), camera: camera, startsCamera: false, recorder: recorder), name: "r13-presenter-key-\(Int(zoom * 100))-\(mode)", size: .init(width: 720, height: 520), scheme: scheme, destination: destination)
      try await snapshot(EditorTextPopover(store: store), name: "r13-editor-size-\(Int(zoom * 100))-\(mode)", size: .init(width: 600, height: 600), scheme: scheme, destination: destination)
    }
  }
}
