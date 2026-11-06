import AppKit
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

}
