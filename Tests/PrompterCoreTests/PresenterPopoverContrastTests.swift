import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class PresenterPopoverContrastTests: XCTestCase {
  func testResolvedPopoverPairsMeetAAInBothAppearances() {
    for scheme in [ColorScheme.light, .dark] {
      for reduced in [false, true] {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
          for (foreground, background) in [(NSColor.labelColor, NSColor.windowBackgroundColor), (.controlTextColor, .controlBackgroundColor)] {
            let f = foreground.usingColorSpace(.sRGB)!, b = background.usingColorSpace(.sRGB)!
            func luminance(_ colour: NSColor) -> Double {
              func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
              return 0.2126 * linear(colour.redComponent) + 0.7152 * linear(colour.greenComponent) + 0.0722 * linear(colour.blueComponent)
            }
            let first = luminance(f), second = luminance(b)
            XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 4.5, "\(scheme), reduced=\(reduced)")
          }
        }
      }
    }
  }

  func testPopoverResetsInheritedDarkStyleForEveryCombination() async throws {
    for scheme in [ColorScheme.light, .dark] {
      for reduced in [false, true] {
        let probe = AppearanceProbe()
        let content = PresenterPopoverSurface(scheme: scheme) {
          VStack {
            Text("Readable Tools")
            Button("More Text Settings…") {}
            ColourSchemeProbe(probe: probe)
          }.padding()
        }.environment(\.colorScheme, .dark)
          .environment(\.presenterReduceTransparency, reduced)
        let (window, _) = await LibraryAX.host(content)
        XCTAssertEqual(probe.scheme, scheme)
        LibraryAX.close(window)
      }
    }
  }
}

@MainActor private final class AppearanceProbe { var scheme: ColorScheme? }
private struct ColourSchemeProbe: View {
  @Environment(\.colorScheme) private var scheme
  let probe: AppearanceProbe
  var body: some View { Color.clear.frame(width: 1, height: 1).onAppear { probe.scheme = scheme } }
}

extension AppearanceSnapshotTests {
  func testPresenterPopoverContrastMatrix() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let defaults = freshDefaults("PopoverContrast")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    let record = try await store.createScript(title: "Contrast", markdown: "Read the Tools clearly.")
    store.session.present(record: record, settings: store.settings)
    camera.displayMode = .prompterWithVideo
    let presenter = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
    for scheme in [ColorScheme.light, .dark] {
      let name = scheme == .dark ? "dark" : "light"
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != name { continue }
      for reduced in [false, true] {
        // The surface sizes to its content (round 19); top alignment keeps the sampled rectangles in place.
        let view = PresenterPopoverSurface(scheme: scheme) { AdjustPanel(selection: .constant(.zebras), showsMic: .constant(true), camera: camera, store: store, startsMeter: false, recorder: recorder) }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .environment(\.colorScheme, .dark)
          .environment(\.presenterReduceTransparency, reduced)
        try await snapshot(view, name: "fable-tools-\(name)-\(reduced ? "reduced" : "transparent")", size: .init(width: 640, height: 600), scheme: scheme, destination: URL(fileURLWithPath: output))
      }
    }
  }
}
