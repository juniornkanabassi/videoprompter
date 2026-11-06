import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundFifteenTests: XCTestCase {
  func testPreviewUsesRealParagraphsFontSpacingAndActiveWord() async throws {
    var settings = PrompterSettings()
    settings.fontName = "Courier"
    settings.fontSize = 48
    settings.lineSpacing = 0.5
    settings.paragraphSpacing = 1
    settings.highlightActiveWord = true
    let (window, host) = await LibraryAX.host(ReadingLayoutPreview(settings: settings, overVideo: false), size: .init(width: 420, height: 600))
    defer { LibraryAX.close(window) }
    func textView(in view: NSView) -> NSTextView? {
      if let text = view as? NSTextView { return text }
      return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    let text = try XCTUnwrap(textView(in: host))
    let storage = try XCTUnwrap(text.textStorage)
    XCTAssertTrue(text.string.contains("\n"))
    XCTAssertTrue(text.string.contains("Pause. Begin again."))
    XCTAssertFalse(text.string.contains("**"))
    let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertEqual(font.familyName, "Courier")
    XCTAssertEqual(font.pointSize, 48 * ReadingLayoutPreview.scale, accuracy: 0.01)
    let paragraph = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertEqual(paragraph.lineSpacing, 24 * ReadingLayoutPreview.scale, accuracy: 0.01)
    XCTAssertEqual(paragraph.paragraphSpacing, 48 * ReadingLayoutPreview.scale, accuracy: 0.01)
    let active = (text.string as NSString).range(of: "line")
    let activeColour = try XCTUnwrap(storage.attribute(.foregroundColor, at: active.location, effectiveRange: nil) as? NSColor)
    XCTAssertEqual(activeColour.usingColorSpace(.sRGB), NSColor.systemYellow.usingColorSpace(.sRGB))
    XCTAssertTrue((storage.attribute(.font, at: active.location, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    let layout = try XCTUnwrap(text.layoutManager)
    let container = try XCTUnwrap(text.textContainer)
    XCTAssertGreaterThan(layout.usedRect(for: container).height, font.pointSize * 2)
  }

  func testExposureExplanationsArePresentBeforeChoosingAnAid() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBFifteenExposure"))
    for zoom in [1.0, 1.5, 2.0] {
      let (window, host) = await LibraryAX.host(Form { ExposureSettingsContent(model: camera) }.formStyle(.grouped).uiZoom(zoom), size: .init(width: 700, height: 1100))
      defer { LibraryAX.close(window) }
      for label in [ExposureGuidance.zebraPurpose(camera.guides), ExposureGuidance.colourPurpose, ExposureGuidance.facePurpose] {
        XCTAssertTrue(LibraryAX.elements(host).contains { node in
          ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"].contains {
            LibraryAX.value(node, $0).contains(label)
          }
        }, label)
      }
      XCTAssertFalse(camera.guides.zebras)
      XCTAssertFalse(camera.guides.falseColour)
    }
  }

  func testMonitorCaptionsStayInsideTheOneLineStripAtEverySize() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBFifteenStrip"))
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      let (window, host) = await LibraryAX.host(ExposureLegend(model: camera, zoom: zoom), size: .init(width: 720, height: 100))
      defer { LibraryAX.close(window) }
      let key = try XCTUnwrap(LibraryAX.named("Key", in: host).first)
      let keyFrame = frame(key)
      for label in FalseColourStrip.captions {
        let caption = try XCTUnwrap(LibraryAX.named(label, in: host).first, label)
        let rect = frame(caption)
        XCTAssertGreaterThan(rect.width, 20 * zoom)
        XCTAssertLessThanOrEqual(abs(rect.midY - keyFrame.midY), 8 * zoom)
        XCTAssertLessThanOrEqual(rect.maxX, keyFrame.minX)
      }
      XCTAssertLessThanOrEqual(host.fittingSize.height, 40 * zoom)
    }
  }

  private func frame(_ object: NSObject) -> NSRect {
    (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
  }
}

extension AppearanceSnapshotTests {
  func testBuilderBRoundFifteenFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    let camera = CameraModel(defaults: freshDefaults("BuilderBFifteenSnapshots"))
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      try await snapshot(ExposureLegend(model: camera, zoom: zoom), name: "r15-labelled-strip-\(Int(zoom * 100))-\(mode)", size: .init(width: 720, height: 100), scheme: scheme, destination: destination)
      try await snapshot(Form { ExposureSettingsContent(model: camera) }.formStyle(.grouped).uiZoom(zoom), name: "r15-exposure-\(Int(zoom * 100))-\(mode)", size: .init(width: 700, height: 1100), scheme: scheme, destination: destination)
      for variant in ["normal", "mirrored", "spaced"] {
        var settings = PrompterSettings()
        settings.highlightActiveWord = true
        settings.horizontalMirror = variant == "mirrored"
        if variant == "spaced" { settings.fontName = "Courier"; settings.fontSize = 54; settings.lineSpacing = 0.5; settings.paragraphSpacing = 1 }
        try await snapshot(ReadingLayoutPreview(settings: settings, overVideo: false).padding(Space.md).uiZoom(zoom), name: "r15-preview-\(variant)-\(Int(zoom * 100))-\(mode)", size: .init(width: 640, height: 850), scheme: scheme, destination: destination)
      }
    }
  }
}
