import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundEightTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBEight")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults))
  }

  func testLinkedMetadataIsDisclosedWithoutHidingBrokenLinkRecovery() async throws {
    let (store, camera) = fixture()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    try "# Keep my heading\n\nThe script stays intact.".write(to: url, atomically: true, encoding: .utf8)
    let record = try await store.createScript(title: "Keep my heading", markdown: "# Keep my heading\n\nThe script stays intact.", linkTo: url)
    store.selectedID = record.id
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1000, height: 800))
      defer { LibraryAX.close(window) }
      XCTAssertFalse(LibraryAX.named("Linked", in: host).isEmpty)
      XCTAssertTrue(LibraryAX.named("Unlink file", in: host).isEmpty)
      let details = try XCTUnwrap(LibraryAX.named("Script details", in: host).first)
      XCTAssertEqual(LibraryAX.value(details, "accessibilityValue"), "Collapsed")
      XCTAssertTrue(LibraryAX.bool(details, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(60))
      XCTAssertFalse(LibraryAX.named("Unlink file", in: host).isEmpty)
      XCTAssertEqual(store.selected?.markdown, record.markdown)
    }
  }

  func testKeyUsesExactlyTheRendererRangesAndEverydayWordsFirst() async throws {
    XCTAssertEqual(CameraExposure.bands.map { FalseColourKey.rangeLabel($0.range) }, ["0–2.5%", "2.5–4%", "38–42%", "52–56%", "97–99%", "99–100%"])
    let (window, host) = await LibraryAX.host(FalseColourKey(), size: .init(width: 480, height: 180))
    defer { LibraryAX.close(window) }
    for (index, band) in CameraExposure.bands.enumerated() {
      XCTAssertFalse(LibraryAX.named("\(FalseColourKey.labels[index]). \(band.name)", in: host).isEmpty)
    }
    var guides = CameraGuides(); guides.useZebraPreset(.faceReference)
    let (guideWindow, guideHost) = await LibraryAX.host(ExposureGuidance(zebras: true, guides: guides, falseColour: true))
    defer { LibraryAX.close(guideWindow) }
    XCTAssertFalse(LibraryAX.elements(guideHost).contains { LibraryAX.value($0, "accessibilityValue").contains("IRE") })
  }

  func testPopoverRestoresNativeFocusToItsOpener() async throws {
    for zoom in [1.0, 1.5, 2.0] {
      let (window, host) = await LibraryAX.host(FocusFixture().uiZoom(zoom))
      defer { LibraryAX.close(window) }
      window.makeKeyAndOrderFront(nil)
      for dismissal in ["Selection", "Escape"] {
        let button = try XCTUnwrap(LibraryAX.named("Adjust text", in: host).first)
        XCTAssertTrue(LibraryAX.bool(button, "accessibilityPerformPress"))
        try await Task.sleep(for: .milliseconds(180))
        let popover = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible && $0.contentView.map { !LibraryAX.named("Done adjusting", in: $0).isEmpty } == true })
        if dismissal == "Selection" {
          let done = try XCTUnwrap(LibraryAX.named("Done adjusting", in: popover.contentView!).first)
          XCTAssertTrue(LibraryAX.bool(done, "accessibilityPerformPress"))
        } else {
          let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: popover.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
          popover.sendEvent(escape)
        }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(LibraryAX.bool(try XCTUnwrap(LibraryAX.named("Adjust text", in: host).first), "isAccessibilityFocused"), "Native focus at \(zoom), \(dismissal)")
      }
    }
  }

  func testTwoPopoverOpenersKeepTheirOwnNativeFocus() async throws {
    let (window, host) = await LibraryAX.host(HStack {
      FocusFixture(title: "First text control")
      FocusFixture(title: "Second text control")
    })
    defer { LibraryAX.close(window) }
    window.makeKeyAndOrderFront(nil)
    for title in ["Second text control", "First text control"] {
      let opener = try XCTUnwrap(LibraryAX.named(title, in: host).first)
      XCTAssertTrue(LibraryAX.bool(opener, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(180))
      let popover = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible && $0.contentView.map { !LibraryAX.named("Done adjusting", in: $0).isEmpty } == true })
      let done = try XCTUnwrap(LibraryAX.named("Done adjusting", in: popover.contentView!).first)
      XCTAssertTrue(LibraryAX.bool(done, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(180))
      XCTAssertTrue(LibraryAX.bool(try XCTUnwrap(LibraryAX.named(title, in: host).first), "isAccessibilityFocused"), title)
    }
  }

  func testRealLibraryTextPopoverRestoresFocusAfterEscape() async throws {
    let (store, camera) = fixture()
    let script = try await store.createScript(title: "Focus check", markdown: "My script stays unchanged.")
    store.selectedID = script.id
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1000, height: 800))
      defer { LibraryAX.close(window) }
      window.makeKeyAndOrderFront(nil)
      let opener = try XCTUnwrap(LibraryAX.named("Editor text size", in: host).first)
      XCTAssertTrue(LibraryAX.bool(opener, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(180))
      let popover = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible && $0.contentView.map { !LibraryAX.named("Editor font", in: $0).isEmpty } == true })
      let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: popover.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
      popover.sendEvent(escape)
      try await Task.sleep(for: .milliseconds(180))
      XCTAssertTrue(LibraryAX.bool(opener, "isAccessibilityFocused"), "Library text size at \(zoom)")
    }
  }

  func testPresetEmptyTextRenderedContrastInBothAppearances() async throws {
    let (store, _) = fixture()
    for scheme in [ColorScheme.light, .dark] {
      let (window, host) = await LibraryAX.host(SettingsPage(store: store, tab: .presets)
        .environment(\.colorScheme, scheme), size: .init(width: 700, height: 900))
      defer { LibraryAX.close(window) }
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      host.layoutSubtreeIfNeeded()
      let text = try XCTUnwrap(LibraryAX.named("Your reading presets appear here.", in: host).first)
      let screen = try XCTUnwrap(text.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      let frame = host.convert(window.convertFromScreen(screen), from: nil)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
      let sx = CGFloat(bitmap.pixelsWide) / host.bounds.width
      let sy = CGFloat(bitmap.pixelsHigh) / host.bounds.height
      let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
      var counts: [Int: Int] = [:]
      for y in Int(top * sy)..<Int((top + frame.height) * sy) {
        for x in Int(frame.minX * sx)..<Int(frame.maxX * sx) {
          let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          let rgb = (Int((c.redComponent * 255).rounded()) << 16) | (Int((c.greenComponent * 255).rounded()) << 8) | Int((c.blueComponent * 255).rounded())
          counts[rgb, default: 0] += 1
        }
      }
      func luminance(_ rgb: Int) -> Double {
        let channels = [rgb >> 16, (rgb >> 8) & 255, rgb & 255].map { Double($0) / 255 }
        let l = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return l[0] * 0.2126 + l[1] * 0.7152 + l[2] * 0.0722
      }
      let background = try XCTUnwrap(counts.max { $0.value < $1.value }?.key)
      let bg = luminance(background)
      let foreground = try XCTUnwrap(counts.filter { $0.value >= 8 }.keys.max {
        abs(luminance($0) - bg) < abs(luminance($1) - bg)
      })
      let ratio = (max(bg, luminance(foreground)) + 0.05) / (min(bg, luminance(foreground)) + 0.05)
      XCTAssertGreaterThanOrEqual(ratio, 4.5)
      print("PRESET_CONTRAST \(scheme) \(ratio) foreground=\(String(foreground, radix: 16)) background=\(String(background, radix: 16))")
    }
  }
}

private struct FocusFixture: View {
  @State private var open = false
  var title = "Adjust text"
  var body: some View {
    Button(title) { open = true }
      .restoringPopoverFocus(isPresented: $open, identifier: "focus-fixture")
      .popover(isPresented: $open) {
        Button("Done adjusting") { open = false }.padding(24)
          .onExitCommand { open = false }
      }
  }
}
