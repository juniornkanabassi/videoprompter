import AppKit
import AVFoundation
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testBuilderBLibraryDesign() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = freshDefaults("BuilderBSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let record = try await store.createScript(title: "A clear opening", markdown: "# A clear opening\n\nRead these opening words at your own pace.\n\n**Important words** stay clear.")
    store.selectedID = record.id
    let camera = CameraModel(defaults: defaults)
    camera.authorization = .authorized
    let recorder = CameraRecorder(defaults: defaults)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      if zoom != 1.5 {
        try await snapshot(LibraryView(store: store, camera: camera), name: "library-\(Int(zoom * 100))-\(mode)", size: .init(width: 1440, height: 900), scheme: scheme, destination: destination)
      }
      try await snapshot(ReadingSettingsPage(store: store, camera: camera).uiZoom(zoom), name: "reading-settings-page-\(Int(zoom * 100))-\(mode)", size: .init(width: 700, height: 900), scheme: scheme, destination: destination)
    }
    store.uiZoom = 1
    try await snapshot(EditorTextPopover(store: store), name: "library-text-size-popover-\(mode)", size: .init(width: 340, height: 300), scheme: scheme, destination: destination)
    try await snapshot(ReadingContrastWarning(textHex: "#FFFFFF", textOpacity: 1, backgroundHex: "#000000", darkness: .constant(0.25)).padding(Space.margin), name: "reading-contrast-warning-\(mode)", size: .init(width: 520, height: 160), scheme: scheme, destination: destination)
    recorder.phase = .recording
    try await snapshot(CameraPicker(model: camera, recorder: recorder).padding(Space.margin), name: "camera-picker-recording-locked-\(mode)", size: .init(width: 420, height: 120), scheme: scheme, destination: destination)
    recorder.phase = .idle
    try await snapshot(ZStack {
      LinearGradient(colors: [.white, .gray, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
      Color.black.opacity(0.5)
      ScriptTextView(document: PrompterDocument(markdown: "Read clearly over a bright picture.\n\nYour words stay easy to follow."), tokenIndex: 0, guideFraction: 0.35, fontName: "Helvetica", fontSize: 48, textOpacity: 1, overVideo: true, onSeek: { _ in })
    }, name: "presenter-script-over-video-halo-\(mode)", size: .init(width: 1000, height: 650), scheme: scheme, destination: destination)
  }

  func testBuilderBRoundFiveFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBRoundFiveSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    let folder = try await store.createLibraryFolder(named: "Drafts")
    _ = try await store.createLibraryFolder(named: "Ready to record")
    let record = try await store.createScript(title: "A clear opening", markdown: "Read these words at your own pace.")
    store.moveSelectedScripts([record.id], to: folder.id)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      store.selectFolder(folder.id)
      store.selectedID = record.id
      try await snapshot(LibraryView(store: store, camera: camera), name: "library-folders-\(Int(zoom * 100))-\(mode)", size: .init(width: 1440, height: 900), scheme: scheme, destination: destination)
    }
    store.uiZoom = 1
    try await snapshot(VStack(alignment: .leading, spacing: Space.md) {
      ExposureGuidance(zebras: true, face: true, falseColour: true)
      ForEach(ExposureGuidance.colourMeanings, id: \.self) { Text($0) }
    }.font(.callout).frame(width: 400, alignment: .leading).padding(Space.margin), name: "exposure-guidance-\(mode)", size: .init(width: 440, height: 520), scheme: scheme, destination: destination)
    let id = try await PracticeReading.prepare(store: store)
    let practice = try XCTUnwrap(store.scripts.first { $0.id == id })
    try await snapshot(ScriptTextView(document: PrompterDocument(markdown: practice.markdown), tokenIndex: 0, guideFraction: 0.3, fontName: "Helvetica", fontSize: 36, textOpacity: 1, onSeek: { _ in }).background(.black), name: "practice-reading-\(mode)", size: .init(width: 1000, height: 800), scheme: scheme, destination: destination)
    for authorization in [AVAuthorizationStatus.notDetermined, .denied, .authorized] {
      camera.authorization = authorization
      try await snapshot(CameraPickerList(model: camera, startsPreview: false, devicesOverride: [], close: {}), name: "camera-recovery-\(authorization.rawValue)-\(mode)", size: .init(width: 540, height: 300), scheme: scheme, destination: destination)
    }
  }

  func testBuilderBRoundSevenFixtures() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBSevenSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    let folder = try await store.createLibraryFolder(named: "Drafts")
    let sourceFolder = root.appendingPathExtension("source")
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    let linked = sourceFolder.appendingPathComponent("Production script.md")
    addTeardownBlock { try? FileManager.default.removeItem(at: sourceFolder) }
    try "Read these words.".write(to: linked, atomically: true, encoding: .utf8)
    let script = try await store.createScript(title: "An opening with a long title that wraps in a narrow window", markdown: "Read these words.", linkTo: linked)
    store.moveSelectedScripts([script.id], to: folder.id)
    store.selectFolder(folder.id)
    store.selectedID = script.id
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      try await snapshot(LibraryView(store: store, camera: camera), name: "library-narrow-\(Int(zoom * 100))-\(mode)", size: .init(width: 840, height: 700), scheme: scheme, destination: destination)
    }
    store.uiZoom = 1
    camera.displayMode = .prompterOnly
    store.settings.textColorHex = "#000000"
    store.settings.backgroundColorHex = "#000000"
    try await snapshot(ReadingSettingsPage(store: store, camera: camera), name: "script-colour-recovery-\(mode)", size: .init(width: 700, height: 1400), scheme: scheme, destination: destination)
  }

}
