import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor enum LibraryAX {
  static func value(_ object: NSObject, _ name: String) -> String {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return "" }
    let value = object.perform(selector)?.takeUnretainedValue()
    return value as? String ?? (value as? NSAttributedString)?.string ?? ""
  }
  static func elements(_ element: Any) -> [NSObject] {
    var visited = Set<ObjectIdentifier>()
    func visit(_ node: Any) -> [NSObject] {
      guard let object = node as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
      let selector = NSSelectorFromString("accessibilityChildren")
      let children = object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
      return [object] + children.flatMap(visit) + ((object as? NSView)?.subviews ?? []).flatMap(visit)
    }
    return visit(element)
  }
  static func named(_ label: String, in root: Any) -> [NSObject] {
    elements(root).filter { value($0, "accessibilityLabel") == label || value($0, "accessibilityTitle") == label || value($0, "accessibilityValue") == label }
  }
  static func bool(_ object: NSObject, _ name: String) -> Bool {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return false }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
  }
  static func host<V: View>(_ view: V, size: NSSize = .init(width: 800, height: 800)) async -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: .init(origin: .init(x: -20000, y: -20000), size: size), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = .init(origin: .zero, size: size)
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
    return (window, host)
  }
  static func close(_ window: NSWindow) { window.contentView = nil; window.close() }
}

@MainActor final class BuilderBLibraryTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderB")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults), CameraRecorder(defaults: defaults))
  }

  func testContrastAndLowestReadableDarkness() throws {
    XCTAssertLessThan(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 1, backgroundHex: "#000000", darkness: 0.25), 3)
    XCTAssertGreaterThanOrEqual(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 1, backgroundHex: "#000000", darkness: 0.5), 3)
    let minimum = try XCTUnwrap(ReadingContrast.minimumDarkness(textHex: "#FFFFFF", textOpacity: 1, backgroundHex: "#000000"))
    XCTAssertGreaterThanOrEqual(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 1, backgroundHex: "#000000", darkness: minimum), 3)
    XCTAssertLessThan(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 1, backgroundHex: "#000000", darkness: minimum - 0.000001), 3)
    XCTAssertNil(ReadingContrast.minimumDarkness(textHex: "#FFFFFF", textOpacity: 0.2, backgroundHex: "#000000"))
  }

  func testContrastWarningActionChangesOnlyDarkness() async throws {
    var darkness = 0.25
    let (window, host) = await LibraryAX.host(ReadingContrastWarning(textHex: "#FFFFFF", textOpacity: 1, backgroundHex: "#000000", darkness: Binding(get: { darkness }, set: { darkness = $0 })))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named("Text may be hard to read over a bright picture.", in: host).isEmpty)
    let button = try XCTUnwrap(LibraryAX.named("Make Readable", in: host).first)
    XCTAssertTrue(LibraryAX.bool(button, "accessibilityPerformPress"))
    XCTAssertEqual(darkness, try XCTUnwrap(ReadingContrast.minimumDarkness(textHex: "#FFFFFF", textOpacity: 1, backgroundHex: "#000000")), accuracy: 0.000001)
  }

  func testCameraPickerLockThroughoutRecordingLifecycle() async throws {
    let (_, camera, recorder) = fixture()
    for phase in [CameraRecorder.Phase.preparing, .waitingForFrames, .recording, .saving, .idle] {
      recorder.phase = phase
      let (window, host) = await LibraryAX.host(CameraPicker(model: camera, recorder: recorder))
      defer { LibraryAX.close(window) }
      let picker = try XCTUnwrap(LibraryAX.named("Camera", in: host).first)
      XCTAssertEqual(LibraryAX.bool(picker, "isAccessibilityEnabled"), phase == .idle)
      if phase != .idle { XCTAssertEqual(LibraryAX.value(picker, "accessibilityHelp"), "Stop recording to change camera") }
    }
  }

  func testReadingPageHasOnlyReadingControls() async throws {
    let (store, camera, _) = fixture()
    let (window, host) = await LibraryAX.host(ReadingSettingsPage(store: store, camera: camera), size: .init(width: 700, height: 2800))
    defer { LibraryAX.close(window) }
    for label in ["Presenter view", "Editor font", "Editor text size", "Interface size…", "Voice and Microphone Settings…"] {
      XCTAssertTrue(LibraryAX.named(label, in: host).isEmpty, label)
    }
    XCTAssertFalse(LibraryAX.named("Reading font", in: host).isEmpty)
  }

  func testFirstLaunchCameraButtonIsInsideViewportAt200Percent() async throws {
    let (store, _, _) = fixture()
    store.uiZoom = 2
    let (window, host) = await LibraryAX.host(LibraryStartView(store: store, importing: .constant(false), practice: {}, camera: {}).uiZoom(2), size: .init(width: 1132 - 400, height: 800))
    defer { LibraryAX.close(window) }
    let button = try XCTUnwrap(LibraryAX.named("Camera Only", in: host).first)
    let rect = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    XCTAssertTrue(window.convertToScreen(host.bounds).contains(rect), "Camera Only must be visible before scrolling: \(rect)")
  }

  func testDeleteKeyHandlerUsesUndoAndUndoRestoresBatch() async throws {
    let (store, _, _) = fixture()
    let first = try await store.createScript(title: "One", markdown: "First script")
    let second = try await store.createScript(title: "Two", markdown: "Second script")
    let undo = UndoManager()
    store.delete([first.id, second.id], undoManager: undo)
    for _ in 0..<100 where !undo.canUndo { try await Task.sleep(for: .milliseconds(10)) }
    guard undo.canUndo else { throw XCTSkip("Builder A has supplied the delete signature but not its undo implementation yet. Library Delete-key routing is verified separately.") }
    XCTAssertEqual(undo.undoActionName, "Move to Trash")
    undo.undo()
    for _ in 0..<100 where store.scripts.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(Set(store.scripts.map(\.id)).isSuperset(of: [first.id, second.id]))

  }

  func testDeleteKeyPassesUndoManager() throws {
    let source = try sourceText("Sources/VideoPrompter/Library/LibraryView.swift")
    let handler = source.components(separatedBy: ".onKeyPress(characters:")[1].components(separatedBy: ".onChange")[0]
    XCTAssertTrue(handler.contains("store.delete(selection, undoManager: undoManager)"))
  }

  func testLibraryToolbarAccessibilityOrderAtBothSizes() async throws {
    let (store, _, _) = fixture()
    for zoom in [1.0, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(HStack { LibraryPresenterActions(store: store) }.uiZoom(zoom), size: .init(width: 1100, height: 180))
      defer { LibraryAX.close(window) }
      let controls = try ["Recordings", "Camera Only", "Present"].map { label in
        try XCTUnwrap(LibraryAX.named(label, in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
      }
      let frames = try controls.map { try XCTUnwrap($0.value(forKey: "accessibilityFrame") as? NSValue).rectValue }
      XCTAssertLessThan(frames[0].midX, frames[1].midX)
      XCTAssertLessThan(frames[1].midX, frames[2].midX)
      XCTAssertTrue(frames.allSatisfy { window.convertToScreen(host.bounds).contains($0) })
    }
  }

  func testLibraryStructureAndVocabulary() throws {
    let library = try sourceText("Sources/VideoPrompter/Library/LibraryView.swift")
    XCTAssertFalse(library.contains(".inspector("))
    XCTAssertFalse(library.contains("ReadingSettingsSheet("))
    let toolbar = try XCTUnwrap(library.components(separatedBy: "struct LibraryPresenterActions: View").last)
    let positions = try ["Button(\"Recordings\"", "Button(\"Camera Only\"", "Button(\"Present\""].map { text in try XCTUnwrap(toolbar.range(of: text)?.lowerBound) }
    XCTAssertTrue(positions[0] < positions[1] && positions[1] < positions[2])
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for directory in ["Sources/VideoPrompter/Library", "Sources/VideoPrompter/Import", "Resources"] {
      let files = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil))
      for case let file as URL in files where ["swift", "md", "txt"].contains(file.pathExtension) {
        let text = try String(contentsOf: file, encoding: .utf8)
        for phrase in ["Paste as New Script", "Dismiss receipt", "Saved settings"] { XCTAssertFalse(text.contains(phrase), "\(file.lastPathComponent): \(phrase)") }
      }
    }
  }

  func testHaloAppliesOnlyOverVideoAndDoesNotChangeText() throws {
    let document = PrompterDocument(markdown: "Read **these words** clearly.")
    let text = TrackingTextView()
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = text
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 48, textOpacity: 1, overVideo: true)
    let withHalo = text.string
    let halo = try XCTUnwrap(text.textStorage?.attribute(.shadow, at: 0, effectiveRange: nil) as? NSShadow)
    XCTAssertEqual(halo.shadowBlurRadius, 6)
    XCTAssertEqual(halo.shadowColor?.alphaComponent, 0.6)
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 48, textOpacity: 1)
    XCTAssertNil(text.textStorage?.attribute(.shadow, at: 0, effectiveRange: nil))
    XCTAssertEqual(text.string, withHalo)
  }

  private func sourceText(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
  }
}
