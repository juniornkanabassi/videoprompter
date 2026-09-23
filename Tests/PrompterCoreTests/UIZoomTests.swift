import AppKit
import PrompterCore
import SwiftUI
import XCTest

@testable import JuniorPrompter

/// View > Zoom In, Zoom Out and Actual Size. Nothing here shows a window or takes focus: the
/// windows are never ordered in, and "a click lands" is AppKit's own hit test, which is what a
/// real click asks before anything reaches a view.
@MainActor
final class UIZoomTests: XCTestCase {
  private var store: AppStore!
  private var root: URL!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    _ = NSApplication.shared
    root = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-\(UUID().uuidString)")
    defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
  }

  override func tearDown() async throws {
    store = nil
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  func testZoomStepsStopAtTheEndsResetAndPersist() {
    XCTAssertEqual(store.uiZoom, 1)
    store.stepUIZoom(in: true)
    XCTAssertEqual(store.uiZoom, 1.1)
    for _ in 0..<20 { store.stepUIZoom(in: true) }
    XCTAssertEqual(store.uiZoom, 2, "stops at the largest step")
    for _ in 0..<20 { store.stepUIZoom(in: false) }
    XCTAssertEqual(store.uiZoom, 1, "Zoom Out stops at actual size")
    store.uiZoom = 1.2
    store.stepUIZoom(in: false)
    XCTAssertEqual(store.uiZoom, 1.1, "an off-step value goes to the next step down")
    store.stepUIZoom(in: true)
    store.stepUIZoom(in: true)
    XCTAssertEqual(store.uiZoom, 1.5)
    XCTAssertEqual(store.settings.fontSize, PrompterSettings().fontSize, "the UI zoom leaves the text sizes alone")
    XCTAssertEqual(store.previewFontSize, 18)

    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(reopened.uiZoom, 1.5, "kept across launches")
    defaults.set(40.0, forKey: "uiZoom")
    XCTAssertEqual(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults).uiZoom, 2,
      "a saved value out of range is clamped")
  }

  /// At every step an AppKit view in a zoomed pane fills the pane on screen, is laid out at
  /// 1/scale, and every point of it takes the click.
  func testAZoomedPaneFillsItsSpaceAndClicksLandOnItsAppKitViews() async {
    var actualSize = 0.0
    for scale in AppStore.uiZoomSteps {
      let probe = Plain()
      let window = hosting(Probe(view: probe).uiZoom(scale), size: NSSize(width: 800, height: 500))
      await settle(window)
      let onScreen = probe.convert(probe.bounds, to: nil)
      XCTAssertEqual(onScreen.width, 800, accuracy: 1, "\(scale)")
      XCTAssertEqual(onScreen.height, 500, accuracy: 1, "\(scale)")
      XCTAssertEqual(probe.frame.width, 800 / scale, accuracy: 1, "\(scale): laid out at 1/scale")
      if scale == 1 { actualSize = hitRatio(of: probe, in: window) }
      XCTAssertGreaterThan(actualSize, 0.85)
      XCTAssertEqual(hitRatio(of: probe, in: window), actualSize, "\(scale): clicks land as at actual size")
    }
    XCTAssertEqual(NSHostingView(rootView: Color.red.frame(width: 100, height: 40).uiZoom(1.5)).fittingSize,
                   NSSize(width: 150, height: 60))
  }

  /// A popover hosts its own view tree, so the inspector's zoom has to be applied to its content:
  /// the Guides popover's content grows with every step, exactly as the pane behind it does.
  func testTheGuidesPopoverContentScalesWithTheLibrary() {
    let actual = NSHostingView(rootView: CameraGuideSettings(model: CameraModel.shared).frame(width: 300).padding().uiZoom(1)).fittingSize
    XCTAssertGreaterThan(actual.height, 0)
    for scale in AppStore.uiZoomSteps {
      let zoomed = NSHostingView(rootView: CameraGuideSettings(model: CameraModel.shared).frame(width: 300).padding().uiZoom(scale)).fittingSize
      XCTAssertEqual(zoomed.width, actual.width * scale, accuracy: 1, "\(scale): width")
      XCTAssertEqual(zoomed.height, actual.height * scale, accuracy: 1, "\(scale): height")
    }
  }

  /// The real library window at every step: the editor, sidebar and inspector scale together,
  /// no control spills out of the window, a click on every visible control reaches what it
  /// reaches at actual size, and the editor's own text size (Make Text Bigger) is untouched.
  func testTheLibraryWindowScalesEveryPaneAndKeepsEveryControlClickable() async throws {
    let record = try await store.library!.create(
      title: "Zoom", markdown: (1...30).map { "Passage \($0) with several readable words." }.joined(separator: "\n\n"))
    await store.reload()
    store.selectedID = record.id
    let window = hosting(LibraryView(store: store), size: NSSize(width: 1400, height: 900))
    var rowHeightAtActualSize: CGFloat = 0
    // What a click on each control and across the editor reaches at actual size, which every
    // zoom must keep. (Off screen, SwiftUI sends a click on the editor's header fields to the
    // editor itself even unzoomed, so the unzoomed answer is the reference, not an ideal.)
    var reachedAtActualSize: [ObjectIdentifier: String] = [:]
    var editorAtActualSize = 0.0
    for scale in AppStore.uiZoomSteps {
      store.uiZoom = scale
      await settle(window)
      let editor = try XCTUnwrap(views(of: NSTextView.self, in: window).first { $0.isEditable && $0.string.contains("Passage 1 ") },
        "\(scale): no editor")
      let editorOnScreen = editor.convert(editor.visibleRect, to: nil)
      XCTAssertEqual(editorOnScreen.width / editor.visibleRect.width, scale, accuracy: 0.01, "\(scale): the editor is zoomed")
      XCTAssertEqual(editor.frame.width, editor.enclosingScrollView?.contentView.bounds.width ?? 0, accuracy: 0.5,
        "\(scale): the text is as wide as the pane showing it")
      if scale == 1 { editorAtActualSize = hitRatio(of: editor, in: window) }
      XCTAssertEqual(editorAtActualSize, 1, "the editor takes clicks all over")
      XCTAssertEqual(hitRatio(of: editor, in: window), editorAtActualSize, "\(scale): the editor takes clicks all over")
      let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
      XCTAssertEqual(font.pointSize, 18, accuracy: 0.5, "\(scale): the editor's text size is its own setting")

      let outline = try XCTUnwrap(views(of: NSOutlineView.self, in: window).first, "\(scale): no sidebar")
      let row = outline.convert(outline.rect(ofRow: 0), to: nil).height
      if scale == 1 { rowHeightAtActualSize = row }
      XCTAssertEqual(row / rowHeightAtActualSize, scale, accuracy: 0.05, "\(scale): the sidebar is zoomed")

      let content = try XCTUnwrap(window.contentView).bounds
      let controls = views(of: NSControl.self, in: window).filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
      XCTAssertGreaterThan(controls.count, 5, "\(scale): the inspector's controls are there")
      var clicked = 0
      for control in controls {
        let rect = control.convert(control.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(rect.minX, content.minX - 1, "\(scale): \(type(of: control)) spills left")
        XCTAssertLessThanOrEqual(rect.maxX, content.maxX + 1, "\(scale): \(type(of: control)) spills right")
        // Only the part a scroll view shows can be clicked at all.
        let shown = control.convert(control.visibleRect, to: nil)
        guard shown.width > 4, shown.height > 4 else { continue }
        let hit = window.contentView?.superview?.hitTest(NSPoint(x: shown.midX, y: shown.midY))
        let reached = hit.map { hit -> String in
          if hit === control || hit.isDescendant(of: control) { return "itself" }
          // The list row or scroll view holding it, which passes the click on.
          if control.isDescendant(of: hit) || control.enclosingScrollView.map(hit.isDescendant(of:)) == true { return "its container" }
          return "\(type(of: hit))"
        } ?? "nothing"
        if scale == 1 { reachedAtActualSize[ObjectIdentifier(control)] = reached; continue }
        guard let expected = reachedAtActualSize[ObjectIdentifier(control)] else { continue }
        if reached != "itself" { XCTAssertEqual(reached, expected, "\(scale): a click on \(type(of: control))") }
        clicked += 1
      }
      if scale != 1 { XCTAssertGreaterThan(clicked, 5, "\(scale): controls compared with actual size") }
    }
    window.contentView = nil
  }

  /// The library window at its narrowest, sized the way SwiftUI's own window sizes it. The fixed
  /// 760-point minimum let the window go narrower than the three columns need (SwiftUI asks twice
  /// the inspector's ideal width on top of the sidebar and editor), and AppKit looped on
  /// constraints until it crashed; showing the inspector in a narrowed window did the same.
  /// Zoom must not raise that minimum either, or 200% would outgrow a laptop screen.
  func testTheNarrowestLibraryWindowLaysOutWithTheInspectorShownOrHiddenAtEveryZoom() async throws {
    let record = try await store.library!.create(title: "Small", markdown: "A short script.")
    await store.reload()
    store.selectedID = record.id
    store.inspector = false
    let controller = NSHostingController(rootView: LibraryView(store: store))
    controller.sizingOptions = [.minSize]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    window.contentViewController = controller
    await settle(window)
    window.setContentSize(window.contentMinSize)   // as far as dragging the corner goes
    await settle(window)
    XCTAssertEqual(window.contentMinSize.width, 932, "the minimum does not shrink with the inspector hidden")
    store.inspector = true
    for scale in AppStore.uiZoomSteps + AppStore.uiZoomSteps.reversed() {
      store.uiZoom = scale
      await settle(window)
      XCTAssertEqual(controller.view.frame.width, 932, accuracy: 1, "\(scale)")
      XCTAssertEqual(window.contentMinSize.width, 932, "\(scale): zoom leaves the minimum alone")
      let editor = try XCTUnwrap(views(of: NSTextView.self, in: window).first { $0.isEditable && $0.string.contains("short") })
      XCTAssertEqual(editor.frame.width, editor.enclosingScrollView?.contentView.bounds.width ?? 0, accuracy: 0.5, "\(scale)")
    }
    window.contentViewController = nil
  }

  /// The presenter zooms its controls only: the script's size and the reading guide are the
  /// presenter's own text settings, sized for the prompter glass.
  func testThePresenterZoomsItsControlsAndLeavesTheScriptAlone() async throws {
    try XCTSkipIf(CameraModel.shared.presentsWithVideo, "video on would open a camera from a test")
    OffscreenPanels.install()
    defer { OffscreenPanels.uninstall() }
    let record = try await store.library!.create(title: "Read", markdown: "Opening words to read.\n\nA second passage.")
    await store.reload()
    store.selectedID = record.id
    let controller = PresenterController()
    controller.present(store: store)
    let panel = try XCTUnwrap(controller.panel)
    defer { controller.close() }
    func measure() async throws -> (text: NSRect, font: CGFloat) {
      await settle(panel)
      let text = try XCTUnwrap(views(of: NSTextView.self, in: panel).first { $0.string.contains("Opening") })
      let font = try XCTUnwrap(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
      return (text.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? .zero, font.pointSize)
    }
    let actual = try await measure()
    store.uiZoom = 1.5
    let zoomed = try await measure()
    XCTAssertEqual(zoomed.text, actual.text, "the script fills the same space")
    XCTAssertEqual(zoomed.font, actual.font, "the script's text size is unchanged")
  }

  // MARK: Helpers

  private final class Plain: NSView {}
  private struct Probe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
  }

  private func hosting<V: View>(_ view: V, size: NSSize) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: view)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
  }

  private func settle(_ window: NSWindow) async {
    // SwiftUI hit-tests from what it last drew, so draw (off screen) before asking where a click goes.
    for _ in 0..<8 { window.contentView?.layoutSubtreeIfNeeded(); window.display(); try? await Task.sleep(for: .milliseconds(30)) }
  }

  /// The share of a 10 x 10 grid over the view's visible part whose click reaches it.
  private func hitRatio(of view: NSView, in window: NSWindow) -> Double {
    let rect = view.convert(view.visibleRect, to: nil)
    var hits = 0
    for i in 0..<10 { for j in 0..<10 {
      let point = NSPoint(x: rect.minX + rect.width * (Double(i) + 0.5) / 10, y: rect.minY + rect.height * (Double(j) + 0.5) / 10)
      if let hit = window.contentView?.superview?.hitTest(point), hit === view || hit.isDescendant(of: view) { hits += 1 }
    } }
    return Double(hits) / 100
  }

  private func views<T: NSView>(of type: T.Type, in window: NSWindow) -> [T] {
    func walk(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(walk) }
    return window.contentView.map(walk) ?? []
  }
}
