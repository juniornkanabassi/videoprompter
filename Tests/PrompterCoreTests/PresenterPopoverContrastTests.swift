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
        let view = PresenterPopoverSurface(scheme: scheme) { presenter.toolsSurface }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .environment(\.colorScheme, .dark)
          .environment(\.presenterReduceTransparency, reduced)
        try await snapshot(view, name: "fable-tools-\(name)-\(reduced ? "reduced" : "transparent")", size: .init(width: 640, height: 600), scheme: scheme, destination: URL(fileURLWithPath: output))
        try assertPopoverPixels(URL(fileURLWithPath: output).appendingPathComponent("fable-tools-\(name)-\(reduced ? "reduced" : "transparent").png"))
      }
    }
  }
}

/// Read the actual glyphs and local backgrounds, not just the intended semantic colours.
@MainActor private func assertPopoverPixels(_ url: URL) throws {
  let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
  let scale = Double(image.pixelsWide) / 640
  for rect in [CGRect(x: 95, y: 168, width: 86, height: 16), CGRect(x: 89, y: 210, width: 455, height: 16), CGRect(x: 89, y: 130, width: 36, height: 12)] {
    var colours: [Int: Int] = [:]
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
      for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
        guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let key = Int((c.redComponent * 255).rounded()) << 16 | Int((c.greenComponent * 255).rounded()) << 8 | Int((c.blueComponent * 255).rounded())
        colours[key, default: 0] += 1
      }
    }
    let background = try XCTUnwrap(colours.max(by: { $0.value < $1.value })?.key)
    func luminance(_ key: Int) -> Double {
      let c = [Double((key >> 16) & 255), Double((key >> 8) & 255), Double(key & 255)].map { $0 / 255 }
        .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
      return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
    }
    let base = luminance(background)
    let contrast = colours.filter { $0.value >= 8 }.keys.map { key in
      let ink = luminance(key)
      return (max(base, ink) + 0.05) / (min(base, ink) + 0.05)
    }.max() ?? 1
    XCTAssertGreaterThanOrEqual(contrast, 4.5, "Rendered Tools contrast in \(url.lastPathComponent), \(rect)")
  }
}
