import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundSevenTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBRoundSeven")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults))
  }

  func testTitleWrapsAndRemainsEditable() async throws {
    var title = "A long title that needs several lines in a narrow editor"
    let (window, host) = await LibraryAX.host(LibraryTitleField(title: Binding(get: { title }, set: { title = $0 })), size: .init(width: 220, height: 140))
    defer { LibraryAX.close(window) }
    let field = try XCTUnwrap(LibraryAX.elements(host).compactMap { $0 as? NSTextField }.first)
    XCTAssertTrue(field.isEditable)
    XCTAssertGreaterThan(field.fittingSize.height, field.font!.pointSize)
    field.stringValue = "A revised title"
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    XCTAssertEqual(title, "A revised title")
  }

  func testReadableRecoveryChangesOnlyBackdropWhenPossible() {
    let (store, _) = fixture()
    store.settings.fontSize = 44
    store.settings.textColorHex = "#FFFFFF"
    store.settings.backgroundColorHex = "#000000"
    store.settings.textOpacity = 1
    store.settings.showCues = true
    store.settings.highlightActiveWord = true
    for video in [false, true] {
      let recovery = ReadingRecovery(current: store.settings, overVideo: video)
      var expected = store.settings
      expected.setBackdropOpacity(recovery.settings.backdropOpacity(withVideo: video), withVideo: video)
      XCTAssertEqual(recovery.settings, expected, "Keep all other reading preferences")
      XCTAssertTrue(recovery.explanation.contains(video ? "Background over camera" : "Script-only background"))
      XCTAssertTrue(recovery.explanation.contains("changes only"))
      XCTAssertGreaterThanOrEqual(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 0.42,
        backgroundHex: "#000000", darkness: recovery.settings.backdropOpacity(withVideo: video)), 3)
    }
  }

  func testMatchingScriptColoursGetExplicitRecoverableChange() async throws {
    let (store, camera) = fixture()
    camera.displayMode = .prompterOnly
    store.settings.textColorHex = "#000000"
    store.settings.backgroundColorHex = "#000000"
    store.settings.showCues = true
    store.settings.highlightActiveWord = true
    let recovery = ReadingRecovery(current: store.settings, overVideo: false)
    XCTAssertEqual(recovery.settings.textColorHex, "#FFFFFF")
    XCTAssertEqual(recovery.settings.backgroundOpacity, 1)
    XCTAssertTrue(recovery.settings.showCues)
    XCTAssertTrue(recovery.settings.highlightActiveWord)
    XCTAssertTrue(recovery.explanation.contains("Text colour to white"))
    XCTAssertTrue(recovery.explanation.contains("keeps stage directions"))
    let (window, host) = await LibraryAX.host(ReadingSettingsPage(store: store, camera: camera), size: .init(width: 700, height: 1800))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named("Make Readable", in: host).isEmpty)
    let action = try XCTUnwrap(LibraryAX.named("Make Readable", in: host).first)
    XCTAssertTrue(LibraryAX.bool(action, "accessibilityPerformPress"))
    XCTAssertEqual(store.settings, recovery.settings)
    let undo = try XCTUnwrap(LibraryAX.named("Undo Make Readable", in: host).first)
    XCTAssertTrue(LibraryAX.bool(undo, "accessibilityPerformPress"))
    XCTAssertEqual(store.settings.textColorHex, "#000000")
  }

  func testSmallTextExplainsAnyNecessaryStageDirectionChange() {
    let (store, _) = fixture()
    store.settings.fontSize = 20
    store.settings.textColorHex = "#000000"
    store.settings.showCues = true
    let recovery = ReadingRecovery(current: store.settings, overVideo: false)
    XCTAssertFalse(recovery.settings.showCues)
    XCTAssertTrue(recovery.explanation.contains("hides stage directions"))
    XCTAssertEqual(recovery.settings.highlightActiveWord, store.settings.highlightActiveWord)
  }

  func testActualFolderHeadingPixelsPassInBothAppearances() async throws {
    let (store, camera) = fixture()
    for scheme in [ColorScheme.light, .dark] {
      for zoom in [1.0, 2.0] {
        store.uiZoom = zoom
        let view = LibraryView(store: store, camera: camera)
          .environment(\.colorScheme, scheme).preferredColorScheme(scheme)
          .background(Color(nsColor: .windowBackgroundColor))
        let (window, host) = await LibraryAX.host(view, size: .init(width: 1440, height: 900))
        defer { LibraryAX.close(window) }
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let heading = try XCTUnwrap(LibraryAX.named("Folders", in: host).first)
        let screen = try XCTUnwrap(heading.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let frame = host.convert(window.convertFromScreen(screen), from: nil)
        XCTAssertTrue(host.bounds.contains(frame))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let sx = Double(bitmap.pixelsWide) / host.bounds.width
        let sy = Double(bitmap.pixelsHigh) / host.bounds.height
        let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        var colours: [Int: Int] = [:]
        for y in Int(top * sy)..<Int((top + frame.height) * sy) {
          for x in Int(frame.minX * sx)..<Int(frame.maxX * sx) {
            let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let rgb = (Int((c.redComponent * 255).rounded()) << 16) | (Int((c.greenComponent * 255).rounded()) << 8) | Int((c.blueComponent * 255).rounded())
            colours[rgb, default: 0] += 1
          }
        }
        let background = try XCTUnwrap(colours.max(by: { $0.value < $1.value })?.key)
        func luminance(_ rgb: Int) -> Double {
          let c = [rgb >> 16, (rgb >> 8) & 255, rgb & 255].map { Double($0) / 255 }
          let l = c.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
          return l[0] * 0.2126 + l[1] * 0.7152 + l[2] * 0.0722
        }
        let bg = luminance(background)
        let ratios = colours.filter { $0.value >= 8 }.map { (rgb: $0.key, ratio: (max(bg, luminance($0.key)) + 0.05) / (min(bg, luminance($0.key)) + 0.05)) }
        let strongest = try XCTUnwrap(ratios.max(by: { $0.ratio < $1.ratio }))
        XCTAssertGreaterThanOrEqual(strongest.ratio, 4.5, "Actual heading, \(scheme) \(zoom)")
        print("FOLDERS_CONTRAST \(scheme) \(zoom): \(strongest.ratio), foreground \(String(strongest.rgb, radix: 16)), background \(String(background, radix: 16))")
      }
    }
  }

  func testCameraPreviewStaysVisibleAboveLongListAtTwoHundredPercent() async throws {
    let (_, camera) = fixture()
    camera.authorization = .authorized
    let devices = (1...12).map { CameraDevice(uid: "test-\($0)", name: "Camera \($0)") }
    camera.selectedUID = "test-10"
    let (window, host) = await LibraryAX.host(CameraPickerList(model: camera, zoom: 2, startsPreview: false,
      devicesOverride: devices, close: {}).uiZoom(2), size: .init(width: 600, height: 700))
    defer { LibraryAX.close(window) }
    let preview = try XCTUnwrap(LibraryAX.named("Live preview of Camera 10", in: host).first)
    let frame = try XCTUnwrap(preview.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame))
    XCTAssertFalse(LibraryAX.named("Camera 10", in: host).isEmpty)
  }

  func testCustomZebraRangeNeverClaimsToBeFaceBrightness() {
    let text = ExposureLegend.measurement(level: 95, range: 5)
    XCTAssertTrue(text.contains("90–100"))
    XCTAssertFalse(text.contains("face"))
    XCTAssertFalse(text.contains("IRE"))
  }

  func testNarrowLibraryKeepsEditorAndSelectionAtEverySize() async throws {
    let (store, camera) = fixture()
    let record = try await store.createScript(title: "A long script title that still needs to be readable", markdown: "Opening words")
    store.selectedID = record.id
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 840, height: 700))
      defer { LibraryAX.close(window) }
      XCTAssertFalse(LibraryAX.named("Editor text size", in: host).isEmpty)
      XCTAssertEqual(store.selectedID, record.id)
      XCTAssertLessThanOrEqual(host.fittingSize.width, 840)
    }
  }

  func testPracticeIsBeforeSecondaryActionsAtTwoHundredPercent() async throws {
    let (store, _) = fixture()
    store.uiZoom = 2
    let (window, host) = await LibraryAX.host(LibraryStartView(store: store, importing: .constant(false), practice: {}, camera: {}).uiZoom(2), size: .init(width: 840, height: 700))
    defer { LibraryAX.close(window) }
    let practice = try XCTUnwrap(LibraryAX.named("Try the Practice Script", in: host).first)
    let frame = try XCTUnwrap(practice.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), "Teaching route stays in the first viewport")
  }
}
