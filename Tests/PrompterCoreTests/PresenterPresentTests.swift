import AppKit
import ObjectiveC
import PrompterCore
import SwiftUI
import XCTest

@testable import VidPrompt

/// Present, driven the way the toolbar, Cmd-Option-P and the menu drive it, with every presenter
/// panel kept off the screen: ordering an `NSPanel` only flips a flag that `isVisible` reports
/// (with KVO, as AppKit does), full screen is a flag `styleMask` reports, and activation is
/// counted, never performed. Nothing here shows a window, takes focus or opens a camera.
@MainActor
final class PresenterPresentTests: XCTestCase {
  private var store: AppStore!
  private var root: URL!
  private var controller: PresenterController!

  override func setUp() async throws {
    try await super.setUp()
    _ = NSApplication.shared
    try XCTSkipIf(CameraModel.shared.presentsWithVideo, "video on would open a camera from a test")
    OffscreenPanels.install()
    root = FileManager.default.temporaryDirectory.appendingPathComponent("present-\(UUID().uuidString)")
    store = AppStore(
      arguments: ["test", "--data-directory", root.path],
      defaults: UserDefaults(suiteName: "VidPromptTests.\(UUID().uuidString)")!)
    controller = PresenterController()
  }

  override func tearDown() async throws {
    controller = nil
    store = nil
    OffscreenPanels.uninstall()
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  private func script(_ title: String) async throws -> ScriptRecord {
    let record = try await store.library!.create(
      title: title, markdown: "\(title) opening words.\n\nA second passage to read.")
    await store.reload()
    return record
  }

  // The controller's own state, read the way the view sees it.
  private var panel: NSPanel? { Mirror(reflecting: controller!).descendant("panel") as? NSPanel }
  private var draft: PresenterDraft? { Mirror(reflecting: controller!).descendant("draft") as? PresenterDraft }
  private var showsPresenter: Bool {
    guard let panel, panel.isVisible, let content = panel.contentView else { return false }
    return String(describing: type(of: content)).hasPrefix("NSHostingView")
  }
  /// The red close button: `windowShouldClose`, then AppKit closes the panel.
  private func closeFromTheButton() {
    guard let panel, controller.windowShouldClose(panel) else { return }
    panel.close()
  }

  /// 16 Sep log, 23:01:01–03 and 23:30:50–54: Present pressed four and six times in a row on an
  /// open presenter. Each press swapped in a new hosting view, so the capture session stopped
  /// and started again every time (`running -> 0`, `running -> 1`, graph torn down) and the text
  /// re-rendered. A press on a presenter already showing this script must only bring it forward.
  func testPresentingAnOpenPresenterAgainKeepsItsContent() async throws {
    store.selectedID = try await script("Open").id
    controller.present(store: store)
    let content = try XCTUnwrap(panel?.contentView)
    XCTAssertTrue(showsPresenter)
    for press in 2...4 {
      controller.present(store: store)
      XCTAssertTrue(panel?.contentView === content, "press \(press) rebuilt the open presenter")
      XCTAssertTrue(showsPresenter)
    }
  }

  /// The pencil tapped while "close" waits for the full-screen exit: the exit ordered the panel
  /// out and emptied it with the edit still open, and from then on every Present hit the draft
  /// guard and ordered front an empty, transparent panel.
  func testPresentAfterAFullScreenCloseRacedByAnEditStillShowsThePresenter() async throws {
    store.selectedID = try await script("Race").id
    controller.present(store: store)
    let shown = try XCTUnwrap(panel)
    OffscreenPanels.setFullScreen(shown, true)
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: shown))
    controller.close()
    XCTAssertEqual(OffscreenPanels.fullScreenToggles, 1, "close from full screen waits for the exit")
    try XCTUnwrap(draft).begin(session: store.session)
    OffscreenPanels.setFullScreen(shown, false)
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: shown))

    controller.present(store: store)
    XCTAssertTrue(showsPresenter, "Present showed an empty panel, or nothing")
    draft?.cancel(resuming: false)
  }

  /// The toolbar button is disabled and Cmd-Option-P returns at `guard let script` once the
  /// selection is not a script. SwiftUI tags every `ForEach` row, so a click on a folder row
  /// (beside its button) or on a Recently Deleted row made a folder or a trashed script the
  /// "selected script": the detail pane reads "Select a script" and Present does nothing.
  func testNoSidebarRowTakesPresentAway() async throws {
    let presented = try await script("Kept")
    let trashed = try await script("Binned")
    _ = try await store.library!.createFolder(name: "Folder")
    try await store.library!.delete(trashed.id)
    await store.reload()
    store.selectedID = presented.id
    let host = NSHostingView(rootView: LibraryView(store: store))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    window.contentView = host
    func settle() async { for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }
    await settle()
    let outline = try XCTUnwrap(Self.outline(in: host), "no sidebar list")
    var clickable = 0
    for row in 0..<outline.numberOfRows {
      // What a click does: ask the list, then select.
      guard outline.delegate?.outlineView?(outline, shouldSelectItem: outline.item(atRow: row) as Any) ?? true
      else { continue }
      clickable += 1
      outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      await settle()
      XCTAssertNotNil(store.selected, "sidebar row \(row) left no script to present (selected \(String(describing: store.selectedID)))")
      store.selectedID = presented.id
      await settle()
    }
    XCTAssertGreaterThan(clickable, 0, "the script row itself must stay selectable")
    window.contentView = nil
  }
  private static func outline(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    return view.subviews.lazy.compactMap(outline(in:)).first
  }

  // MARK: Ruled out: these pass on b621f66 and guard the fix.

  func testPresentCloseFromTheButtonPresentShowsThePresenterEachTime() async throws {
    store.selectedID = try await script("Again").id
    for round in 1...3 {
      controller.present(store: store)
      XCTAssertTrue(showsPresenter, "round \(round)")
      closeFromTheButton()
      XCTAssertFalse(panel?.isVisible ?? true, "round \(round): the close button closes")
    }
    controller.present(store: store)
    controller.close()
    controller.present(store: store)
    XCTAssertTrue(showsPresenter, "close() then Present")
  }

  func testPresentAfterAFullScreenCloseShowsThePresenter() async throws {
    store.selectedID = try await script("Full").id
    controller.present(store: store)
    let shown = try XCTUnwrap(panel)
    OffscreenPanels.setFullScreen(shown, true)
    controller.close()
    OffscreenPanels.setFullScreen(shown, false)
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: shown))
    XCTAssertFalse(shown.isVisible)
    XCTAssertEqual(shown.level, .floating)
    controller.present(store: store)
    XCTAssertTrue(showsPresenter)
  }

  /// Present pressed while "close" is still waiting for the full-screen exit keeps it up.
  func testPresentDuringAFullScreenCloseKeepsThePresenterUp() async throws {
    store.selectedID = try await script("Keep").id
    controller.present(store: store)
    let shown = try XCTUnwrap(panel)
    OffscreenPanels.setFullScreen(shown, true)
    controller.close()
    controller.present(store: store)
    OffscreenPanels.setFullScreen(shown, false)
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: shown))
    XCTAssertTrue(showsPresenter)
  }

  func testPresentWithASavedFrameOffEveryScreenBringsItBack() async throws {
    store.selectedID = try await script("Lost").id
    controller.present(store: store)
    let shown = try XCTUnwrap(panel)
    closeFromTheButton()
    // Where a Prompter XL that has since gone away left it.
    shown.setFrame(NSRect(x: 60_000, y: 60_000, width: 1395, height: 1024), display: false)
    controller.present(store: store)
    XCTAssertTrue(showsPresenter)
    XCTAssertTrue(PresenterController.hasReachableTitleBar(
      shown.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame)))
  }

  func testPresentAfterSwitchingScriptsShowsTheNewScript() async throws {
    let first = try await script("First")
    let second = try await script("Second")
    store.selectedID = first.id
    controller.present(store: store)
    store.selectedID = second.id
    controller.present(store: store)
    XCTAssertTrue(showsPresenter)
    XCTAssertEqual(store.session.activeScriptID, second.id)
    XCTAssertEqual(draft?.recordID, second.id, "the presenter still edits the first script")
    XCTAssertEqual(panel?.title, "VidPrompt · Second")
  }
}

/// Swaps a few `NSPanel` and `NSApplication` methods for flags, and back again.
@MainActor enum OffscreenPanels {
  private static var shown = Set<ObjectIdentifier>()
  private static var fullScreen = Set<ObjectIdentifier>()
  private(set) static var fullScreenToggles = 0
  private(set) static var activations = 0
  private static var installed = false

  static func setShown(_ panel: NSWindow, _ on: Bool) {
    guard shown.contains(ObjectIdentifier(panel)) != on else { return }
    panel.willChangeValue(for: \.isVisible)
    if on { shown.insert(ObjectIdentifier(panel)) } else { shown.remove(ObjectIdentifier(panel)) }
    panel.didChangeValue(for: \.isVisible)
  }
  static func isShown(_ panel: NSWindow) -> Bool { shown.contains(ObjectIdentifier(panel)) }
  static func setFullScreen(_ panel: NSWindow, _ on: Bool) {
    if on { fullScreen.insert(ObjectIdentifier(panel)) } else { fullScreen.remove(ObjectIdentifier(panel)) }
  }
  static func isFullScreen(_ panel: NSWindow) -> Bool { fullScreen.contains(ObjectIdentifier(panel)) }
  static func countToggle() { fullScreenToggles += 1 }
  static func countActivation() { activations += 1 }

  private static let panelSwaps: [(Selector, Selector)] = [
    (#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSPanel.offscreen_makeKeyAndOrderFront(_:))),
    (#selector(NSWindow.orderFrontRegardless), #selector(NSPanel.offscreen_orderFrontRegardless)),
    (#selector(NSWindow.orderFront(_:)), #selector(NSPanel.offscreen_orderFront(_:))),
    (#selector(NSWindow.makeKey), #selector(NSPanel.offscreen_makeKey)),
    (#selector(NSWindow.orderOut(_:)), #selector(NSPanel.offscreen_orderOut(_:))),
    (#selector(NSWindow.close), #selector(NSPanel.offscreen_close)),
    (#selector(getter: NSWindow.isVisible), #selector(getter: NSPanel.offscreen_isVisible)),
    (#selector(getter: NSWindow.styleMask), #selector(getter: NSPanel.offscreen_styleMask)),
    (#selector(NSWindow.toggleFullScreen(_:)), #selector(NSPanel.offscreen_toggleFullScreen(_:))),
  ]
  private static let appSwaps: [(Selector, Selector)] = [
    (#selector(NSApplication.activate(ignoringOtherApps:)), #selector(NSApplication.offscreen_activate(ignoringOtherApps:))),
    (#selector(NSApplication.activate as (NSApplication) -> () -> Void), #selector(NSApplication.offscreen_activateCooperatively)),
  ]

  static func install() {
    guard !installed else { return }
    swapAll()
    installed = true
  }
  static func uninstall() {
    guard installed else { return }
    swapAll()
    installed = false
    shown.removeAll()
    fullScreen.removeAll()
    fullScreenToggles = 0
    activations = 0
  }
  private static func swapAll() {
    for (original, replacement) in panelSwaps { swap(NSPanel.self, original, replacement) }
    for (original, replacement) in appSwaps { swap(NSApplication.self, original, replacement) }
  }
  /// Gives the class its own entry first, so the inherited `NSWindow` method is left alone.
  private static func swap(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
    guard let old = class_getInstanceMethod(type, original),
      let new = class_getInstanceMethod(type, replacement)
    else { return XCTFail("cannot swap \(original)") }
    if class_addMethod(type, original, method_getImplementation(new), method_getTypeEncoding(new)) {
      class_replaceMethod(type, replacement, method_getImplementation(old), method_getTypeEncoding(old))
    } else {
      method_exchangeImplementations(old, new)
    }
  }
}

extension NSPanel {
  @objc fileprivate dynamic func offscreen_makeKeyAndOrderFront(_ sender: Any?) {
    MainActor.assumeIsolated { OffscreenPanels.setShown(self, true) }
  }
  @objc fileprivate dynamic func offscreen_orderFrontRegardless() {
    MainActor.assumeIsolated { OffscreenPanels.setShown(self, true) }
  }
  @objc fileprivate dynamic func offscreen_orderFront(_ sender: Any?) {
    MainActor.assumeIsolated { OffscreenPanels.setShown(self, true) }
  }
  @objc fileprivate dynamic func offscreen_makeKey() {}
  @objc fileprivate dynamic func offscreen_orderOut(_ sender: Any?) {
    MainActor.assumeIsolated { OffscreenPanels.setShown(self, false) }
  }
  /// AppKit's close: `willClose`, then off the screen.
  @objc fileprivate dynamic func offscreen_close() {
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: self)
    MainActor.assumeIsolated { OffscreenPanels.setShown(self, false) }
  }
  @objc fileprivate dynamic var offscreen_isVisible: Bool {
    MainActor.assumeIsolated { OffscreenPanels.isShown(self) }
  }
  /// Calls the original getter, which the swap has put under this name.
  @objc fileprivate dynamic var offscreen_styleMask: NSWindow.StyleMask {
    var mask = self.offscreen_styleMask
    if MainActor.assumeIsolated({ OffscreenPanels.isFullScreen(self) }) { mask.insert(.fullScreen) }
    return mask
  }
  @objc fileprivate dynamic func offscreen_toggleFullScreen(_ sender: Any?) {
    MainActor.assumeIsolated { OffscreenPanels.countToggle() }
  }
}

extension NSApplication {
  @objc fileprivate dynamic func offscreen_activate(ignoringOtherApps flag: Bool) {
    MainActor.assumeIsolated { OffscreenPanels.countActivation() }
  }
  @objc fileprivate dynamic func offscreen_activateCooperatively() {
    MainActor.assumeIsolated { OffscreenPanels.countActivation() }
  }
}
