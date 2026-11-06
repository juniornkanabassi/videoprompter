import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundSixteenTests: XCTestCase {
  func testStripSeparatesNearWhiteFromClippingWithoutAFaceTarget() async throws {
    XCTAssertEqual(FalseColourStrip.captions, ["Too dark", "Mid-tones", "Bright", "Clipping"])
    XCTAssertEqual(FalseColourStrip.bandGroups, [0..<2, 2..<4, 4..<5, 5..<6])
    let camera = CameraModel(defaults: freshDefaults("BuilderBSixteenStrip"))
    camera.guides.falseColour = true
    let (window, host) = await LibraryAX.host(ExposureLegend(model: camera, zoom: 2), size: .init(width: 720, height: 100))
    defer { LibraryAX.close(window) }
    XCTAssertTrue(LibraryAX.named("Face", in: host).isEmpty)
    let bright = try XCTUnwrap(LibraryAX.named("Bright", in: host).first)
    let clipping = try XCTUnwrap(LibraryAX.named("Clipping", in: host).first)
    XCTAssertLessThanOrEqual(frame(bright).maxX, frame(clipping).minX)
    XCTAssertTrue(LibraryAX.value(clipping, "accessibilityHelp").contains("not proof of camera sensor clipping"))
  }

  func testNarrowStripKeepsKeyInsideTheAvailableWidth() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBSixteenNarrow"))
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      for width in [240.0, 520.0, 720.0] {
        let (window, host) = await LibraryAX.host(ExposureLegend(model: camera, zoom: zoom), size: .init(width: width, height: 100))
        defer { LibraryAX.close(window) }
        host.sizingOptions = []
        host.frame.size = .init(width: width, height: 100)
        host.layoutSubtreeIfNeeded()
        let key = try XCTUnwrap(LibraryAX.named("Key", in: host).first)
        XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame(key)), "Key at \(width) points / \(zoom)")
      }
    }
  }

  func testSharedExposureSwitchesLeadWithTheJobAndRetainReferenceQualifications() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBSixteenExposure"))
    XCTAssertEqual(ExposureLegend.zebraTitle(for: .brightAreas), "Find blown highlights · Zebras")
    XCTAssertTrue(ExposureGuidance.zebraLookFor(camera.guides).contains("do not prove"))
    camera.guides.useZebraPreset(.faceReference)
    let (window, host) = await LibraryAX.host(Form { ExposureSettingsContent(model: camera) }.formStyle(.grouped))
    defer { LibraryAX.close(window) }
    for label in ["Check brightness · Zebras", "Check brightness · False colour"] {
      XCTAssertFalse(LibraryAX.named(label, in: host).isEmpty, label)
    }
    let reference = ExposureGuidance.zebraLookFor(camera.guides)
    XCTAssertTrue(reference.contains("Skin tones vary"))
    XCTAssertTrue(reference.contains("flat picture"))
    XCTAssertTrue(ExposureGuidance.facePurpose.contains("not a target for every face"))
    XCTAssertTrue(ExposureGuidance.facePurpose.contains("Skin tones vary"))
    XCTAssertTrue(ExposureGuidance.facePurpose.contains("flat picture"))
    XCTAssertFalse(ExposureGuidance.colourMeanings.joined().contains("face"))
  }

  func testOwnedSlidersHaveNativeTwentyFourPointTargetsAndKeepBindings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBSixteenSliders")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    store.settings.mode = "Manual"
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(VStack {
        EditorTextControls(store: store)
        ReadingSettingsPage(store: store, camera: camera)
      }.uiZoom(zoom), size: .init(width: 1000, height: 5000))
      defer { LibraryAX.close(window) }
      let sliders = LibraryAX.elements(host).filter { LibraryAX.value($0, "accessibilityRole") == "AXSlider" }
      XCTAssertGreaterThanOrEqual(sliders.count, 10)
      for slider in sliders {
        XCTAssertGreaterThanOrEqual(frame(slider).height, 24 * zoom - 0.5, LibraryAX.value(slider, "accessibilityLabel"))
      }
      let nativeSliders = LibraryAX.elements(host).compactMap { $0 as? NSSlider }
      XCTAssertEqual(nativeSliders.count, 10)
      for slider in nativeSliders {
        XCTAssertGreaterThanOrEqual(slider.bounds.height, 24)
        for y in [2.0, slider.bounds.height - 2] {
          let point = NSPoint(x: slider.bounds.midX, y: y)
          XCTAssertTrue(slider.hitTest(slider.convert(point, to: slider.superview)) === slider, "The entire native slider must receive pointer input")
        }
      }
      let editor = try XCTUnwrap(LibraryAX.named("Editor text size", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXSlider" })
      let previous = store.previewFontSize
      let reading = store.settings.fontSize
      _ = LibraryAX.bool(editor, "accessibilityPerformIncrement")
      XCTAssertGreaterThan(store.previewFontSize, previous)
      XCTAssertEqual(store.settings.fontSize, reading)
    }
  }

  private func frame(_ object: NSObject) -> NSRect {
    (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
  }
}
