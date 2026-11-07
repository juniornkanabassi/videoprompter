import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testBamaContrastAndTipStates() async throws {
    _ = NSApplication.shared
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let destination = URL(fileURLWithPath: output)
    let defaults = freshDefaults("BamaSnapshots")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    _ = try await store.createScript(title: "A clear opening", markdown: String(repeating: "Read these words in your own time.\n\n", count: 12))
    let camera = CameraModel(defaults: defaults)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    try await snapshot(HStack(spacing: Space.margin) {
      VStack {
        Text("Standard contrast").foregroundStyle(.white)
        Rectangle().fill(Palette.onDarkQuiet(.standard)).frame(width: 160, height: 64)
      }
      VStack {
        Text("Increased contrast").foregroundStyle(.white)
        Rectangle().fill(Palette.onDarkQuiet(.increased)).frame(width: 160, height: 64)
      }
    }.padding(Space.margin).background(.black), name: "bama-contrast-tokens-\(mode)",
      size: .init(width: 440, height: 140), scheme: scheme, destination: destination)
    defaults.set(true, forKey: "readingTipHidden")
    try await snapshot(LibraryView(store: store, camera: camera), name: "bama-library-tip-hidden-\(mode)", size: .init(width: 1440, height: 900), scheme: scheme, destination: destination)
  }
}
