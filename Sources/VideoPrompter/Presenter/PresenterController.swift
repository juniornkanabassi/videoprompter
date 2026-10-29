import AppKit
import Combine
import PrompterCore
import SwiftUI

@MainActor final class PresenterController: NSObject, NSWindowDelegate {
  static let shared = PresenterController()
  /// Internal so a test can stand in for the panel.
  var panel: PresenterPanel?
  private var screenObserver: NSObjectProtocol?
  private weak var activeSession: SessionStore?
  private var draft: PresenterDraft?
  private let camera: CameraModel
  private var videoObserver: AnyCancellable?
  /// Closing from full screen waits for the exit, so no empty full-screen Space is left behind.
  private(set) var closesAfterFullScreen = false
  private var isFullScreen: Bool { panel?.isInFullScreen == true }
  /// On screen, not minimised and not full screen: the only state a camera fit may resize.
  private var isWindowedOnScreen: Bool {
    panel.map { $0.isVisible && !$0.isMiniaturized && !$0.isInFullScreen } ?? false
  }

  /// Where the presenter's last frame is kept, per data directory. Nil in tests and on an agent
  /// screen, which place the panel themselves.
  private let frameDefaults: UserDefaults?

  init(camera: CameraModel = .shared, frameDefaults: UserDefaults? = PresenterFrameMemory.defaultStore()) {
    self.camera = camera
    self.frameDefaults = frameDefaults
    super.init()
    // The capsule button, Prompter > Present with Video and the inspector's Mode all flip this one
    // property. `dropFirst` skips the value the presenter opens with.
    videoObserver = camera.$displayMode.dropFirst().map { $0 != .prompterOnly }.removeDuplicates().sink { [weak self] on in
      MainActor.assumeIsolated { self?.videoDidChange(on) }
    }
  }

  // A floating window in its own full-screen Space misbehaves, so it floats only outside one.
  func windowWillEnterFullScreen(_ notification: Notification) {
    (notification.object as? NSWindow)?.level = .normal
  }
  func windowDidEnterFullScreen(_ notification: Notification) {
    // A close that arrived while the window was still entering full screen could not leave it then.
    finishPendingClose()
  }
  func windowDidFailToEnterFullScreen(_ window: NSWindow) { (window as? PresenterPanel)?.settle() }
  // Reopen where it was last left, on whichever screen that was (a prompter display, usually),
  // rather than at the main screen's corner. AppKit's own autosave forgot a second screen whose
  // visible frame it had recorded differently, and kept one frame for every data directory.
  func windowDidMove(_ notification: Notification) { rememberFrame(notification) }
  func windowDidResize(_ notification: Notification) { rememberFrame(notification) }
  private func rememberFrame(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window.isVisible, !window.isMiniaturized,
      !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
    // A display that drops out pushes the panel onto another one. That move is not a choice, so
    // it never replaces the memory of the absent display; dragging this window still does.
    let screens = NSScreen.screens.map(PresenterFrameMemory.Screen.init)
    let dragged = NSApp.currentEvent.map { event in
      event.window === window && [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type)
    } ?? false
    if !dragged, PresenterFrameMemory.savedDisplayIsAbsent(in: frameDefaults, screens: screens) { return }
    PresenterFrameMemory.save(window.frame, on: .init(screen), to: frameDefaults)
  }
  func windowDidExitFullScreen(_ notification: Notification) {
    (notification.object as? PresenterPanel)?.settle()
    finishPendingClose()
  }
  /// A close that waited for a full-screen transition goes through `close()`, so an edit begun in
  /// the meantime is asked about instead of the panel being emptied under it.
  private func finishPendingClose() {
    guard closesAfterFullScreen else { return }
    closesAfterFullScreen = false
    close()
  }
  func windowDidFailToExitFullScreen(_ window: NSWindow) {
    closesAfterFullScreen = false
    (window as? PresenterPanel)?.settle()
  }
  /// Video turned on in a windowed presenter fits the window to the camera once. Opening with video
  /// already on, a closed or minimised presenter, full screen and video off all leave it alone.
  func videoDidChange(_ on: Bool) {
    // A temporary view (the monitor, a camera-only start) leaves the window's shape alone.
    guard on, isWindowedOnScreen, !camera.isShowingTemporarily else { return }
    // The new preview selects the camera, and so learns its size, in this same update.
    DispatchQueue.main.async { self.matchCameraSize() }
  }
  /// The presenter capsule's video button.
  func toggleVideo() { camera.presentsWithVideo.toggle() }

  /// Pins the selected passage over the full camera picture. From the library editor this opens
  /// the presenter first; reading pauses, since the script itself is out of view.
  func monitorSelection(store: AppStore, selection: ReferenceMonitor.Selection? = ReferenceMonitor.focusedSelection()) {
    guard let selection, !isEditing else { return }
    // The script the words belong to is presented first, so Back to script returns to it: a
    // camera-only presenter has none, and a library selection may be from another script.
    let otherScript = !selection.inPresenter && store.selected?.id != activeSession?.activeScriptID
    if panel?.isVisible != true || isShowingWithoutScript || otherScript { present(store: store) }
    guard panel?.isVisible == true, !isShowingWithoutScript else { return }
    activeSession?.pause()
    ReferenceMonitor.shared.begin(selection.text, camera: camera)
    // Key, so Esc reaches Back to script even when the command came from the library.
    panel?.orderFrontRegardless()
    panel?.makeKey()
  }
  /// The Prompter menu's Start or Pause. Nothing starts while the script is out of sight.
  func toggleReading(store: AppStore) {
    if store.session.isActivelyRunning { store.session.pause() } else if canStartReading { store.session.play() }
  }
  /// The script is on screen to be read: the same test that enables the bar's Start button.
  var canStartReading: Bool {
    panel?.isVisible == true && panel?.isMiniaturized == false && !isEditing
      && !isShowingWithoutScript && !ReferenceMonitor.shared.isActive && camera.displayMode != .videoOnly
  }
  func endMonitor() { ReferenceMonitor.shared.end(camera: camera) }
  func toggleFullScreen() {
    guard let panel, panel.isVisible else { return }
    panel.toggleFullScreen(nil)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let draft, draft.isEditing { draft.requestClose(); return false }
    // The red button or Cmd-W in full screen: leave the Space first, then close.
    if isFullScreen { closeNow(); return false }
    activeSession?.pause()
    resetTransientViews()
    return true
  }
  /// Ends the monitor and the camera-only presenter, putting back the view the person chose.
  private func resetTransientViews() {
    endMonitor()
    // Every view the person picks is saved, so one that differs was only ever temporary.
    camera.restoreSavedDisplayMode()
    isShowingWithoutScript = false
    cameraOnlyForWantOfScript = false
  }
  func moveReading(_ action: (SessionStore) -> Void) {
    guard let session = activeSession, !isEditing, !isShowingWithoutScript, camera.displayMode != .videoOnly else { return }
    action(session)
  }

  var isEditing: Bool { draft?.isEditing == true }
  /// True while the presenter shows the camera with no script in it.
  private(set) var isShowingWithoutScript = false
  /// Camera only was shown because there was no script, so a script added to it comes up over the
  /// camera instead of hidden behind it. Cleared, with the saved view put back, when it closes.
  private var cameraOnlyForWantOfScript = false

  /// The library's Present: the selected script, or with none selected the camera on its own.
  func presentFromLibrary(store: AppStore) {
    if store.selected != nil { present(store: store) } else { presentCamera(store: store) }
  }

  /// The camera alone, as a monitor for recording without a script. Presenting a script later adds
  /// it over the same picture; the View menu adds the camera to a script the other way round.
  func presentCamera(store: AppStore) {
    guard draft?.isEditing != true else { panel?.makeKeyAndOrderFront(nil); return }
    closesAfterFullScreen = false
    endMonitor()
    if let panel, panel.isVisible, panel.contentView is NSHostingView<PresenterView> {
      // Temporary, like the rest of camera-only: presenting a script brings it back over the camera.
      camera.showTemporarily(.videoOnly)
      cameraOnlyForWantOfScript = true
      activeSession?.pause()
      panel.makeKeyAndOrderFront(nil)
      return
    }
    camera.showTemporarily(.videoOnly)
    let panel = self.panel ?? makePanel()
    self.panel = panel
    store.session.pause()
    activeSession = store.session
    isShowingWithoutScript = true
    cameraOnlyForWantOfScript = true
    panel.onPassageKey = { _ in false }
    panel.title = "Video Prompter · Camera"
    panel.settle()
    let draft = PresenterDraft()
    self.draft = draft
    panel.contentView = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, hasScript: false))
    recoverVisibleFrame(panel)
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func present(store: AppStore, on screen: NSScreen? = nil, activate: Bool = true) {
    guard draft?.isEditing != true else {
      draft?.errorMessage = "Finish or cancel the open edit before presenting another script."
      if activate { panel?.makeKeyAndOrderFront(nil) } else { panel?.orderFrontRegardless() }
      return
    }
    guard let script = store.selected, !store.deletingIDs.contains(script.id) else { return }
    closesAfterFullScreen = false
    let panel = self.panel ?? makePanel()
    self.panel = panel
    // Present on the presenter already showing this script only brings it forward: a new hosting
    // view restarted the camera and threw the open edit away.
    let isShowing = panel.isVisible && store.session.activeScriptID == script.id
      && panel.contentView is NSHostingView<PresenterView> && !isShowingWithoutScript
    // A new script never inherits a passage pinned over the last one.
    if !isShowing { endMonitor() }
    // A script added to a camera-only presenter shows over the picture rather than hiding it.
    if cameraOnlyForWantOfScript, camera.displayMode == .videoOnly { camera.showTemporarily(.prompterWithVideo) }
    cameraOnlyForWantOfScript = false
    isShowingWithoutScript = false
    // For the script already presented this only passes on settings; the anchor stays.
    store.session.present(record: script, settings: store.settings)
    activeSession = store.session
    panel.onPassageKey = { [weak self] direction in
      guard let self, !self.isEditing, self.camera.displayMode != .videoOnly else { return false }
      self.moveReading { if direction == 123 { $0.previousPassage() } else { $0.nextPassage() } }
      return true
    }
    panel.title = "Video Prompter · \(script.metadata.title)"
    panel.settle()
    if isShowing {
      panel.orderFrontRegardless()
      if activate && !CommandLine.arguments.contains("--agent-screen") { panel.makeKey(); NSApp.activate(ignoringOtherApps: true) }
      return
    }
    let draft = PresenterDraft(record: store.session.activeRecord ?? script)
    self.draft = draft
    panel.contentView = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, hasScript: true))
    let targetScreen = screen ?? (CommandLine.arguments.contains("--agent-screen") ? NSScreen.agentScreen : nil)
    if let area = targetScreen?.visibleFrame, !isFullScreen {
      panel.setFrame(area.centred(NSSize(width: min(760, area.width), height: min(520, area.height))), display: true)
    }
    recoverVisibleFrame(panel)
    if !activate {
      panel.orderFrontRegardless()
    } else if screen != nil || CommandLine.arguments.contains("--agent-screen") {
      panel.orderFrontRegardless()
      panel.makeKey()
    } else {
      panel.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
  func close() {
    guard let draft, draft.isEditing else { closeNow(); return }
    draft.requestClose()
  }
  func closeNow() {
    activeSession?.pause()
    // The flags go with the panel, so a present during the full-screen exit still rebuilds it.
    if isFullScreen { closesAfterFullScreen = true; panel?.toggleFullScreen(nil); return }
    resetTransientViews()
    panel?.orderOut(nil)
    // The camera is already let go: the stage view stops holding it when `orderOut` clears the
    // window's `isVisible`. Dropping the hosting view also stops the hidden presenter observing the
    // store and session; `present` builds a fresh one every time.
    panel?.contentView = NSView()
  }

  /// Resize the presenter to the shape of the feed as it is shown — a feed turned 90° gives a
  /// vertical window — as large as the screen it is on allows.
  static func matchedCameraFrame(picture: CGSize, rotation: CameraRotation, in visibleFrame: NSRect) -> NSRect {
    rotation.fittedRect(aspect: picture, in: visibleFrame)
  }
  func matchCameraSize() {
    guard let panel, isWindowedOnScreen,
      let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    else { return }
    // Until the camera reports its size, the stage view draws 16:9 too.
    let picture = SharedCameraSession.shared.pictureSize ?? CGSize(width: 16, height: 9)
    panel.setFrame(Self.matchedCameraFrame(picture: picture, rotation: camera.guides.rotation, in: screen.visibleFrame), display: true)
  }
  private func makePanel() -> PresenterPanel {
    let value = PresenterPanel(captureVisible: CommandLine.arguments.contains("--capture-visible"))
    value.delegate = self
    if let frame = PresenterFrameMemory.restored(from: frameDefaults, screens: NSScreen.screens.map(PresenterFrameMemory.Screen.init)) {
      value.setFrame(frame, display: false)
    }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { if let panel = self?.panel { self?.recoverVisibleFrame(panel) } }
    }
    return value
  }
  private func recoverVisibleFrame(_ panel: NSPanel) {
    guard !isFullScreen, !Self.hasReachableTitleBar(panel.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame)),
      let target = NSScreen.main ?? NSScreen.screens.first
    else { return }
    let area = target.visibleFrame
    panel.setFrame(area.centred(NSSize(width: min(panel.frame.width, area.width), height: min(panel.frame.height, area.height))), display: true)
  }
  static func hasReachableTitleBar(_ frame: NSRect, visibleFrames: [NSRect]) -> Bool {
    let titleBar = NSRect(x: frame.minX, y: frame.maxY - 44, width: frame.width, height: 44)
    return visibleFrames.contains {
      let overlap = titleBar.intersection($0)
      return overlap.width >= 120 && overlap.height >= 24
    }
  }
  static func snappedFrame(_ frame: NSRect, visibleFrames: [NSRect], threshold: CGFloat = 36) -> NSRect {
    guard let visible = visibleFrames.max(by: { $0.intersection(frame).area < $1.intersection(frame).area }) else { return frame }
    var result = frame
    let xTargets = [visible.minX, visible.midX - frame.width / 2, visible.maxX - frame.width,
                    visible.minX + visible.width / 4 - frame.width / 2,
                    visible.minX + visible.width * 3 / 4 - frame.width / 2]
    let yTargets = [visible.minY, visible.midY - frame.height / 2, visible.maxY - frame.height]
    if let x = xTargets.min(by: { abs($0 - frame.minX) < abs($1 - frame.minX) }), abs(x - frame.minX) <= threshold { result.origin.x = x }
    if let y = yTargets.min(by: { abs($0 - frame.minY) < abs($1 - frame.minY) }), abs(y - frame.minY) <= threshold { result.origin.y = y }
    return result
  }
  func snapAfterDrag(_ panel: NSWindow) {
    guard !panel.styleMask.contains(.fullScreen) else { return }
    panel.setFrame(Self.snappedFrame(panel.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame)), display: true)
  }
}

private extension NSRect { var area: CGFloat { width * height } }

/// The presenter's last frame with the display it was on, so a restart puts it back there.
enum PresenterFrameMemory {
  struct Screen {
    let id: UInt32
    let name: String
    let frame: NSRect
    let visibleFrame: NSRect
    init(id: UInt32, name: String, frame: NSRect, visibleFrame: NSRect) {
      self.id = id; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame
    }
    @MainActor init(_ screen: NSScreen) {
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      self.init(id: number?.uint32Value ?? 0, name: screen.localizedName, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
  }
  static let key = "presenterFrame"

  @MainActor static func defaultStore() -> UserDefaults? {
    guard NSClassFromString("XCTestCase") == nil, !CommandLine.arguments.contains("--agent-screen") else { return nil }
    return AppStore.preferences()
  }

  /// Kept relative to the display's origin, so rearranging displays in System Settings moves the
  /// presenter with its display.
  static func save(_ frame: NSRect, on screen: Screen, to defaults: UserDefaults?) {
    let offset = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    defaults?.set(["offset": NSStringFromRect(offset), "display": Int(screen.id), "name": screen.name], forKey: key)
  }

  static func savedDisplayIsAbsent(in defaults: UserDefaults?, screens: [Screen]) -> Bool {
    guard let saved = defaults?.dictionary(forKey: key) else { return false }
    return display(for: saved, in: screens) == nil
  }

  /// ID and name together first, then the name: IDs can be reused by another monitor after a
  /// reconnect. An ID alone counts only for an entry saved without a name.
  private static func display(for saved: [String: Any], in screens: [Screen]) -> Screen? {
    let id = (saved["display"] as? Int).flatMap { UInt32(exactly: $0) }
    guard let name = saved["name"] as? String, !name.isEmpty else { return screens.first { $0.id == id } }
    return screens.first { $0.id == id && $0.name == name } ?? screens.first { $0.name == name }
  }

  /// The saved frame, moved fully inside its display's visible area, or nil when that display is
  /// gone. The display is found by its ID, else by name, since IDs can change after a reconnect.
  static func restored(from defaults: UserDefaults?, screens: [Screen]) -> NSRect? {
    guard let saved = defaults?.dictionary(forKey: key), let text = saved["offset"] as? String,
      let screen = display(for: saved, in: screens) else { return nil }
    let offset = NSRectFromString(text)
    guard offset.width >= 100, offset.height >= 100 else { return nil }
    return clamp(offset.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), into: screen.visibleFrame)
  }

  static func clamp(_ frame: NSRect, into area: NSRect) -> NSRect {
    let size = NSSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
    let x = min(max(frame.minX, area.minX), area.maxX - size.width)
    let y = min(max(frame.minY, area.minY), area.maxY - size.height)
    return NSRect(origin: NSPoint(x: x, y: y), size: size)
  }
}

/// The presenter window. At rest it is `.fullScreenAuxiliary`, which is what lets it float over
/// another app's full-screen Space (OBS, verified on 7 September). It turns `.fullScreenPrimary`
/// only for a full-screen Space of its own, and every way in comes through `toggleFullScreen`:
/// Prompter > Presenter Full Screen, View > Enter Full Screen (Ctrl-Cmd-F) and the green button.
class PresenterPanel: NSPanel {
  var onPassageKey: ((UInt16) -> Bool)?
  /// Only the key presenter receives bare arrows; editing retains native cursor movement.
  func handlePassageKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, [123, 124].contains(event.keyCode),
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      !(firstResponder is NSTextView && (firstResponder as? NSTextView)?.isEditable == true)
    else { return false }
    return onPassageKey?(event.keyCode) == true
  }
  override func keyDown(with event: NSEvent) {
    if !handlePassageKey(event) { super.keyDown(with: event) }
  }

  /// `captureVisible` lets screen capture see the presenter, for testing only.
  convenience init(captureVisible: Bool) {
    self.init(
      contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    sharingType = captureVisible ? .readOnly : .none
    hidesOnDeactivate = false
    isMovableByWindowBackground = true
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    minSize = NSSize(width: 360, height: 220)
    settle()
  }
  static func collectionBehavior(fullScreen: Bool) -> NSWindow.CollectionBehavior {
    [.canJoinAllSpaces, .canJoinAllApplications, fullScreen ? .fullScreenPrimary : .fullScreenAuxiliary]
  }
  /// Internal so a test can stand in for a window in its own full-screen Space.
  var isInFullScreen: Bool { styleMask.contains(.fullScreen) }

  override func toggleFullScreen(_ sender: Any?) {
    // Primary for the transition either way; `settle` puts Auxiliary back once it is over.
    collectionBehavior = Self.collectionBehavior(fullScreen: true)
    redirectZoomButton()
    performFullScreenTransition(sender)
  }
  /// Internal so a test can stand in for AppKit's transition.
  func performFullScreenTransition(_ sender: Any?) { super.toggleFullScreen(sender) }

  /// Level and behaviour for the state the window is really in: floating and Auxiliary outside
  /// full screen; normal and Primary inside it, which is also where a failed exit leaves it.
  func settle() {
    let fullScreen = isInFullScreen
    collectionBehavior = Self.collectionBehavior(fullScreen: fullScreen)
    level = fullScreen ? .normal : .floating
    redirectZoomButton()
  }

  /// An Auxiliary window's green button only zooms; send it to full screen as a Primary one does.
  private func redirectZoomButton() {
    guard let zoom = standardWindowButton(.zoomButton) else { return }
    zoom.target = self
    zoom.action = #selector(toggleFullScreen(_:))
  }

  /// View > Enter Full Screen is disabled for an Auxiliary window unless the panel says otherwise.
  override func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard item.action == #selector(toggleFullScreen(_:)) else { return super.validateMenuItem(item) }
    item.title = isInFullScreen ? "Exit Full Screen" : "Enter Full Screen"
    return true
  }
  /// The same answer on AppKit's other validation path, which the menu may take instead.
  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    item.action == #selector(toggleFullScreen(_:)) || super.validateUserInterfaceItem(item)
  }
}

@MainActor final class PresenterDraft: ObservableObject {
  private(set) var recordID: UUID
  private(set) var expectedFingerprint: String
  private(set) var expectedRevision: UInt64
  @Published var markdown: String
  @Published var isEditing = false
  @Published var isSaving = false
  @Published var closeRequested = false
  /// Whether the pending discard also closes the presenter. Escape during an edit only
  /// discards the typing and carries on reading.
  @Published private(set) var discardCloses = true
  @Published var errorMessage: String?
  @Published var noticeMessage: String?
  private weak var session: SessionStore?
  private var resumeAfterEdit = false
  private var originalMarkdown: String
  var hasEdits: Bool { markdown != originalMarkdown }

  /// For the camera-only presenter, which has no script to edit.
  convenience init() {
    self.init(record: ScriptRecord(metadata: ScriptMetadata(title: "", fileName: ""), markdown: ""))
  }
  init(record: ScriptRecord) {
    recordID = record.id
    expectedFingerprint = record.metadata.contentFingerprint
    expectedRevision = record.metadata.revision
    markdown = record.markdown
    originalMarkdown = record.markdown
  }
  func begin(session: SessionStore) {
    guard let record = session.activeRecord else { return }
    recordID = record.id
    expectedFingerprint = record.metadata.contentFingerprint
    expectedRevision = record.metadata.revision
    markdown = record.markdown
    originalMarkdown = record.markdown
    self.session = session
    resumeAfterEdit = session.isActivelyRunning
    session.pause()
    isEditing = true
    errorMessage = nil
    noticeMessage = nil
  }
  /// Leaves editing; also how a save that went through finishes.
  func cancel(resuming: Bool = true) {
    isEditing = false
    closeRequested = false
    errorMessage = nil
    if resuming { resumeTracking() } else { resumeAfterEdit = false }
  }
  /// Editing pauses recognition; finishing it carries on from the remapped anchor.
  private func resumeTracking() {
    guard resumeAfterEdit else { return }
    resumeAfterEdit = false
    session?.play()
  }
  func requestClose() {
    guard !isSaving else {
      errorMessage = "Wait for the save to finish before closing the presenter."
      return
    }
    discardCloses = true
    closeRequested = true
  }
  /// Escape used to throw typed edits away without asking. Typing goes through the same
  /// confirmation the close button uses; an untouched draft still cancels straight away.
  func requestCancel() {
    guard hasEdits else { cancel(); return }
    discardCloses = false
    closeRequested = true
  }
  func confirm(store: AppStore) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await store.savePresentedMarkdown(
        markdown, for: recordID, expectedFingerprint: expectedFingerprint,
        expectedRevision: expectedRevision)
      if let saved = store.scripts.first(where: { $0.id == recordID }) {
        expectedFingerprint = saved.metadata.contentFingerprint
        expectedRevision = saved.metadata.revision
      }
      cancel()
    } catch {
      errorMessage = "The script changed or could not be saved. Your presenter draft is still open. \(error)"
    }
  }
  func saveAsCopy(store: AppStore) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await store.savePresentedDraftAsCopy(markdown, for: recordID)
      cancel()
      noticeMessage = "Draft saved as a separate script. The presenter remains on the original script."
    } catch {
      errorMessage = "The draft could not be saved as a separate script. \(error)"
    }
  }
  func hasExternalChange(in store: AppStore) -> Bool {
    guard let metadata = store.scripts.first(where: { $0.id == recordID })?.metadata else { return true }
    return metadata.contentFingerprint != expectedFingerprint || metadata.revision != expectedRevision
  }
}

private struct PresenterView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var session: SessionStore
  @ObservedObject var draft: PresenterDraft
  /// False for the camera on its own; the session may still hold an earlier script, never shown.
  var hasScript = true
  @ObservedObject private var camera = CameraModel.shared
  @ObservedObject private var monitor = ReferenceMonitor.shared
  @State private var editorNotice: String?
  @State private var showsCameraSettings = false
  /// False in Video only, unless a draft was already open: it must stay reachable to finish or cancel.
  private var showsScript: Bool { hasScript && (camera.displayMode != .videoOnly || draft.isEditing) }
  var body: some View {
    GeometryReader { geometry in
      let sideInset = ScriptTextView.sideInset(width: geometry.size.width, textWidth: store.settings.textWidth)
      ZStack(alignment: .top) {
        if camera.presentsWithVideo {
          // The live picture is the bottom layer only. The background colour above it is the
          // script's backdrop, so colour, opacity, guide line, mirror, rotation and in-place
          // editing all keep working exactly as they do without video.
          CameraPreview(model: camera)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .task { camera.start() }
        }
        // Video only: the camera stage and its own guides, with no backdrop, script or reading guide.
        if showsScript {
        Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black)
          .opacity(store.settings.backdropOpacity(withVideo: camera.presentsWithVideo))
          .ignoresSafeArea()
        Group {
          if draft.isEditing {
            FormattedMarkdownEditor(
              markdown: $draft.markdown, fontName: store.settings.fontName,
              fontSize: store.settings.fontSize,
              onUnsupportedEdit: {
                editorNotice = "That change could not be applied safely. Your text is unchanged. Try a smaller selection."
              }, focusesOnAppear: true,
              typography: Self.presenterTypography(store.settings, sideInset: sideInset),
              anchorSourceOffset: session.activeToken?.sourceRange.location,
              guideFraction: store.settings.guideFraction,
              verticalMirror: store.settings.verticalMirror != (store.settings.rotation == 180),
              readThroughSourceOffset: session.lastConfirmedTokenIndex.flatMap { index in
                let tokens = session.document.spokenTokens
                return tokens.indices.contains(index) ? tokens[index].sourceRange.upperBound : nil
              })
          } else {
            ScriptTextView(
              document: session.document, tokenIndex: session.tokenIndex,
              lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
              isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
              guideFraction: store.settings.guideFraction,
              verticalMirror: store.settings.verticalMirror != (store.settings.rotation == 180),
              fontName: store.settings.fontName,
              fontSize: store.settings.fontSize, textOpacity: store.settings.textOpacity,
              fontWeight: store.settings.fontWeight, textColorHex: store.settings.textColorHex,
              lineSpacing: store.settings.lineSpacing, paragraphSpacing: store.settings.paragraphSpacing,
              horizontalMargin: sideInset, alignment: store.settings.alignment,
              showCues: store.settings.showCues, highlightActiveWord: store.settings.highlightActiveWord,
              manualPosition: session.isManual ? { session.manualPosition() } : nil,
              onSeek: session.seek, onUserScroll: session.seekFromUserScroll
            )
          }
        }
        .scaleEffect(
          x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1
        ).rotationEffect(.degrees(Double(store.settings.rotation)))
        .clipped()
        GuideLine(settings: store.settings).offset(
          y: ScriptTextView.visualGuideY(height: geometry.size.height, fraction: store.settings.guideFraction))
        }
        if !hasScript, camera.displayMode != .videoOnly {
          Text("No script yet. Choose one in the library and press Present to add it here.")
            .font(.title3).multilineTextAlignment(.center).foregroundStyle(.white)
            .padding(16).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let passage = monitor.passage, !showsScript {
          ReferenceMonitorCaption(passage: passage, fontName: store.settings.fontName) {
            PresenterController.shared.endMonitor()
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          .padding(.bottom, 8)
          // Read through the same glass as the script.
          .scaleEffect(x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1)
          .rotationEffect(.degrees(Double(store.settings.rotation)))
        }
      }
    }.background(Color.clear).onChange(of: store.settings) { _, value in
      session.updateSettings(value)
    }
    .onChange(of: camera.displayMode) { _, mode in monitor.displayModeDidChange(mode) }
    .safeAreaInset(edge: .top, spacing: 0) {
      ZStack {
        RoundedRectangle(cornerRadius: 2).frame(width: 24, height: 4)
          .foregroundStyle(.primary)
        WindowDragHandle { window in
          guard store.settings.presenterSnappingEnabled else { return }
          PresenterController.shared.snapAfterDrag(window)
        }
      }
      .frame(width: 72, height: 24)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(.top, 4)
      .accessibilityLabel("Drag presenter window")
      .accessibilityHint("Drag to move the presenter window")
      .help("Drag to move the presenter")
      .allowsHitTesting(!draft.isEditing)
      .accessibilityHidden(draft.isEditing)
      .uiZoom(store.uiZoom)
      .fixedSize()
      .frame(maxWidth: .infinity)
    }
    // Both notices and controls reserve their actual wrapped height for reading and editing.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        if hasBottomNotice {
          bottomNotice.padding(.horizontal, 10).padding(.top, 6)
        }
        WrapLayout(spacing: 8) {
          Label(draft.isEditing ? "Editing" : session.isActivelyRunning ? (session.isManual ? "Scrolling" : "Listening") : "Paused",
                systemImage: draft.isEditing ? "pencil" : session.isActivelyRunning ? (session.isManual ? "text.line.first.and.arrowtriangle.forward" : "mic.fill") : "pause.circle")
            .font(.caption.weight(.semibold))
            .frame(width: 88)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background((draft.isEditing ? Color.orange : session.isActivelyRunning ? Color.accentColor : Color.secondary).opacity(0.14), in: Capsule())
            .help(draft.isEditing ? "Editing the script. Finish with ⌘Return, or cancel." : session.isActivelyRunning ? "The script is following you" : "Press Start to begin or continue reading")
          // Disabled, not hidden, while editing: the capsule keeps its shape and VoiceOver reads them as dimmed.
          Group {
            CapsuleButton(session.isActivelyRunning ? "Pause" : "Start",
                          systemImage: session.isActivelyRunning ? "pause.fill" : "play.fill", showsTitle: true, width: 66, help: "Start or pause following at the current position", action: session.toggle)
              .buttonStyle(.borderedProminent)
            CapsuleButton("Back to start", systemImage: "arrow.counterclockwise", help: "Return to the first word of the script", action: session.restart)
          }.disabled(!showsScript || draft.isEditing)
          // One View menu instead of a camera toggle, picker and guides button: the bar keeps the
          // same width whether or not the camera is on.
          Menu {
            Picker("What to show", selection: $camera.displayMode) {
              ForEach(PresenterDisplayMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode)
              }
            }.pickerStyle(.inline)
            Divider()
            Button("Monitor Selection with Camera") { PresenterController.shared.monitorSelection(store: store) }
              .disabled(draft.isEditing)
              .help("Drag across a passage first; it is pinned over the camera picture")
            Button("Camera Settings…") { showsCameraSettings = true }
              .disabled(!camera.presentsWithVideo)
          } label: {
            // A titled label: an icon-only one dropped the menu from the accessibility tree, and a
            // Text image drew as a blank square in the bordered bar.
            Label("View", systemImage: camera.displayMode.systemImage).labelStyle(.titleAndIcon)
          } primaryAction: {
            // One click still turns the camera on or off, as the old camera button did.
            PresenterController.shared.toggleVideo()
          }
          .menuStyle(.button).menuIndicator(.visible).fixedSize()
          .accessibilityLabel("Presenter view")
          .accessibilityValue(camera.displayMode.label)
          .help("Click to show or hide the camera; the arrow has every view, Camera Settings and the monitor. \(camera.displayMode.label) now")
          .background {
            Color.clear.popover(isPresented: $showsCameraSettings, arrowEdge: .top) {
              CameraSettingsPanel(model: camera, zoom: store.uiZoom).frame(width: 320).uiZoom(store.uiZoom)
            }
          }
          CapsuleButton(draft.isEditing ? "Finish editing" : "Edit script",
                        systemImage: draft.isEditing ? "checkmark" : "pencil",
                        shortcut: draft.isEditing ? KeyboardShortcut(.return, modifiers: .command) : nil, help: "Edit the script here; Finish editing saves your changes") {
            if draft.isEditing { Task { await draft.confirm(store: store) } } else { draft.begin(session: session) }
          }.disabled(draft.isSaving || !showsScript)
          if draft.isEditing {
            CapsuleButton("Cancel editing", systemImage: "xmark", shortcut: .cancelAction, help: "Leave editing; confirm before discarding an unsaved draft") { draft.requestCancel() }
              .disabled(draft.isSaving)
          } else {
            CapsuleButton("Close presenter", systemImage: "xmark", help: "Close the presenter and pause following") { PresenterController.shared.close() }
          }
        }
        .buttonStyle(.bordered).padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)).padding(10)
      }.frame(maxWidth: .infinity, alignment: .center)
        .uiZoom(store.uiZoom)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
    .confirmationDialog("Discard this presenter draft?", isPresented: $draft.closeRequested) {
      Button(draft.discardCloses ? "Discard Draft and Close" : "Discard Draft", role: .destructive) {
        draft.cancel(resuming: !draft.discardCloses)
        if draft.discardCloses { PresenterController.shared.closeNow() }
      }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("The draft has not been saved to the script library.")
    }
    .onChange(of: draft.markdown) { editorNotice = nil }
    .onChange(of: draft.isEditing) { _, isEditing in if isEditing { editorNotice = nil } }
  }

  private var bottomNotice: some View {
    VStack(spacing: 6) {
      if draft.isEditing, draft.hasExternalChange(in: store) {
        Text("This script changed outside Video Prompter. Finishing will keep this draft and show a conflict instead of overwriting it.")
          .foregroundStyle(.orange)
      }
      if let error = draft.errorMessage {
        Text(error).foregroundStyle(.red)
        Button("Save as Separate Script") { Task { await draft.saveAsCopy(store: store) } }
          .disabled(draft.isSaving)
      }
      if let notice = editorNotice ?? session.anchorNotice ?? draft.noticeMessage { Text(notice) }
    }
    .font(.caption).multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .frame(maxWidth: 560)
  }
  private var hasBottomNotice: Bool {
    editorNotice != nil || session.anchorNotice != nil || draft.noticeMessage != nil
      || draft.errorMessage != nil || (draft.isEditing && draft.hasExternalChange(in: store))
  }
  private static func presenterTypography(_ settings: PrompterSettings, sideInset: CGFloat) -> EditorTypography {
    EditorTypography(
      textColor: (NSColor(hex: settings.textColorHex) ?? .white)
        .withAlphaComponent(settings.textOpacity),
      lineSpacing: max(3, settings.fontSize * settings.lineSpacing),
      paragraphSpacing: max(10, settings.fontSize * settings.paragraphSpacing),
      horizontalInset: sideInset,
      alignment: NSTextAlignment(setting: settings.alignment))
  }
}

/// Core actions show their titles; secondary actions keep their tooltips and VoiceOver labels.
private struct CapsuleButton: View {
  let title: String
  let systemImage: String
  var shortcut: KeyboardShortcut?
  var showsTitle = false
  var width: CGFloat?
  var help: String?
  let action: () -> Void
  init(_ title: String, systemImage: String, shortcut: KeyboardShortcut? = nil, showsTitle: Bool = false, width: CGFloat? = nil, help: String? = nil, action: @escaping () -> Void) {
    self.title = title; self.systemImage = systemImage; self.shortcut = shortcut; self.showsTitle = showsTitle; self.width = width; self.help = help; self.action = action
  }
  var body: some View {
    Button(action: action) {
      if showsTitle { Label(title, systemImage: systemImage).labelStyle(.titleAndIcon).frame(width: width) }
      else { Label(title, systemImage: systemImage).labelStyle(.iconOnly) }
    }
      .keyboardShortcut(shortcut)
      .accessibilityLabel(title)
      .help(help ?? title)
  }
}

/// The reading line across the presenter, drawn over the video too.
struct GuideLine: View {
  let settings: PrompterSettings
  var body: some View {
    Rectangle().fill(.cyan.opacity(settings.guideOpacity)).frame(height: 2).allowsHitTesting(false)
  }
}

private struct WindowDragHandle: NSViewRepresentable {
  let onDragEnded: (NSWindow) -> Void
  func makeNSView(context: Context) -> NSView {
    let view = DragView()
    view.onDragEnded = onDragEnded
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {}
  private final class DragView: NSView {
    var onDragEnded: ((NSWindow) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      window.performDrag(with: event)
      onDragEnded?(window)
    }
  }
}

struct ScriptTextView: NSViewRepresentable {
  let document: PrompterDocument
  let tokenIndex: Int
  var lastConfirmedTokenIndex: Int?
  var isActivelyRunning = false
  var seekRevision = 0
  let guideFraction: Double
  var verticalMirror = false
  let fontName: String
  let fontSize: Double
  let textOpacity: Double
  var fontWeight = "Regular"
  var textColorHex = "#FFFFFF"
  var lineSpacing = 0.16
  var paragraphSpacing = 0.34
  var horizontalMargin = 42.0
  var alignment = "Left"
  var showCues = true
  var highlightActiveWord = false
  /// Manual mode only: the session's exact fractional token position, painted on a display link
  /// while running. Voice passes nil and keeps its eased, word-at-a-time alignment.
  var manualPosition: (() -> Double)?
  let onSeek: (Int) -> Void
  /// A scroll the reader made by hand; falls back to `onSeek`.
  var onUserScroll: ((Int) -> Void)?
  /// The column is `textWidth` of the presenter's width, centred, and never nearer an edge
  /// than the old fixed 42 pt margin. Only the text uses it; the camera stays full size.
  static func sideInset(width: CGFloat, textWidth: Double) -> CGFloat {
    max(42, width * (1 - CGFloat(textWidth)) / 2)
  }
  static func visualGuideY(height: CGFloat, fraction: Double) -> CGFloat {
    min(height, max(54, height * fraction))
  }
  func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.stopObservingUserScrolls()
    coordinator.stopManualScrolling()
  }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let text = TrackingTextView()
    text.setAccessibilityLabel("Presenter script")
    text.isEditable = false
    text.isSelectable = true
    text.drawsBackground = false
    text.textContainerInset = NSSize(width: horizontalMargin, height: 80)
    text.textContainer?.widthTracksTextView = true
    text.onCharacterClick = { context.coordinator.seek($0) }
    text.onLayout = { [weak scroll] in
      guard let scroll else { return }
      context.coordinator.dropScrollGeometry()
      // During a full layout the caller aligns once it returns; see `layOutScript`.
      guard !context.coordinator.isLayingOutScript else { return }
      context.coordinator.invalidateAlignment()
      context.coordinator.alignToCurrent(in: scroll)
    }
    scroll.documentView = text
    context.coordinator.textView = text
    context.coordinator.verticalMirror = verticalMirror
    context.coordinator.observeUserScrolls(in: scroll)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.setSideInset(horizontalMargin)
    coordinator.onSeek = onSeek
    coordinator.onUserScroll = onUserScroll
    coordinator.setManualSource(manualPosition)
    coordinator.tokenIndex = tokenIndex
    coordinator.lastConfirmedTokenIndex = lastConfirmedTokenIndex
    coordinator.guideFraction = guideFraction
    let seeked = coordinator.noteSeekRevision(seekRevision)
    if coordinator.verticalMirror != verticalMirror || seeked {
      coordinator.verticalMirror = verticalMirror
      coordinator.snapToGuide()
    }
    coordinator.isActivelyRunning = isActivelyRunning
    coordinator.updateDisplayLink(for: scroll)
    let style = "\(fontName)|\(fontSize)|\(textOpacity)|\(fontWeight)|\(textColorHex)|\(lineSpacing)|\(paragraphSpacing)|\(alignment)|\(showCues)|\(highlightActiveWord)"
    if coordinator.needsRender(document: document, style: style) {
      coordinator.render(
        document: document, fontName: fontName, fontSize: fontSize, textOpacity: textOpacity,
        fontWeight: fontWeight, textColorHex: textColorHex, lineSpacing: lineSpacing,
        paragraphSpacing: paragraphSpacing,
        alignment: alignment, showCues: showCues, highlightActiveWord: highlightActiveWord)
    }
    coordinator.updateGeneration &+= 1
    let generation = coordinator.updateGeneration
    DispatchQueue.main.async {
      guard coordinator.updateGeneration == generation else { return }
      coordinator.updateReadState()
      if coordinator.manualPosition != nil {
        coordinator.alignManual(in: scroll)
      } else {
        coordinator.align(scroll: scroll, tokenIndex: tokenIndex, guideFraction: guideFraction)
      }
    }
  }
  @MainActor final class Coordinator: NSObject {
    weak var textView: NSTextView?
    var onSeek: (Int) -> Void
    var mappings: [(NSRange, Int)] = []
    /// The system's Reduce Motion; tests that only check where the text lands set it to skip the easing.
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// How long an eased move takes. Ease-out, so the line starts moving at full speed the moment
    /// the reader reaches it, and a new target picks up from wherever the last move had got to:
    /// the 0.60 s ease-in-out this replaced started every line from rest and put the line on the
    /// guide over a second after the reader got there at a fast pace.
    static let easedMoveSeconds = 0.20
    /// Moves the script: eased, or at once, which also stops an easing in flight. Tests swap it to
    /// see what was asked for, since an eased scroll does not advance while the screen is locked.
    static var moveClip: (NSClipView, NSPoint, _ eased: Bool) -> Void = { clip, destination, eased in
      if eased {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = easedMoveSeconds
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          clip.animator().setBoundsOrigin(destination)
        }
      } else {
        // A zero-length animator move is what replaces an animator move in flight; the layer's
        // own animations go too, and the plain assignment leaves the origin exact.
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0
          clip.animator().setBoundsOrigin(destination)
        }
        clip.layer?.removeAllAnimations()
        clip.setBoundsOrigin(destination)
      }
    }
    private var renderedDocument: PrompterDocument?
    private var renderedStyle = ""
    var tokenIndex = 0
    var lastConfirmedTokenIndex: Int?
    var guideFraction = 0.35
    var verticalMirror = false
    private var textOpacity = 1.0
    private var highlightActiveWord = false
    private var textColour = NSColor.white
    private var lastAligned: Int?
    private var lastGuideFraction: Double?
    private var lastAlignmentDestination: NSPoint?
    private var lastReadTokenIndex: Int?
    private var lastReadConfirmedTokenIndex: Int?
    var updateGeneration = 0
    private(set) var seekRevision = 0
    var isActivelyRunning = false {
      // Play resumes Manual alignment after a hand scroll.
      didSet { if isActivelyRunning, !oldValue { isHandScrolled = false; pendingUserSeeks = 0 } }
    }
    /// Manual only: set by the first live-scroll event and held until Play, so `updateNSView`,
    /// `onLayout` and the display link cannot pull the reader's scroll back to the timeline.
    private(set) var isHandScrolled = false
    /// Seek revisions the hand scroll itself caused, which must not lift the suppression.
    private var pendingUserSeeks = 0
    var snapNextAlignment = false
    private var scrollObservers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    /// Every mapping's rendered midY, measured on the gesture's first scroll event. Only geometry
    /// clears it (a new gesture, a render, a resize): each hand-scroll seek re-aligns, and clearing
    /// it there too would measure the whole script again on every event.
    private(set) var liveScrollMidYs: [CGFloat]?
    var onUserScroll: ((Int) -> Void)?
    /// Set only in Manual mode. The display link paints it while `isActivelyRunning`.
    private(set) var manualPosition: (() -> Double)?
    private var displayLink: CADisplayLink?
    private weak var manualScroll: NSScrollView?
    var isDisplayLinkActive: Bool { displayLink != nil }
    init(onSeek: @escaping (Int) -> Void) {
      self.onSeek = onSeek
      super.init()
    }
    func setManualSource(_ source: (() -> Double)?) {
      // Crossing between Manual and Voice hands the scroll position over: re-align from scratch.
      if (source == nil) != (manualPosition == nil) {
        isHandScrolled = false
        invalidateAlignment()
        endsVoiceAnimation = source != nil
      }
      manualPosition = source
    }
    private var endsVoiceAnimation = false
    /// The display link exists only while Manual is running and this view is alive: paused, stopped,
    /// completed and dismantled all remove it, so an idle presenter does no per-frame work.
    func updateDisplayLink(for scroll: NSScrollView) {
      guard isActivelyRunning, manualPosition != nil else { return stopManualScrolling() }
      guard displayLink == nil else { return }
      let link = scroll.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
      link.add(to: .main, forMode: .common)
      displayLink = link
      manualScroll = scroll
    }
    func stopManualScrolling() {
      displayLink?.invalidate()
      displayLink = nil
    }
    @objc private func displayLinkFired(_ link: CADisplayLink) {
      guard isActivelyRunning, manualPosition != nil, let scroll = manualScroll else {
        return stopManualScrolling()
      }
      // A hand on the scroll wheel wins; its first event pauses the session and this link with it.
      guard !isLiveScrolling else { return }
      alignManual(in: scroll)
    }
    func stopObservingUserScrolls() {
      scrollObservers.forEach(NotificationCenter.default.removeObserver)
      scrollObservers.removeAll()
    }
    func observeUserScrolls(in scroll: NSScrollView) {
      stopObservingUserScrolls()
      let center = NotificationCenter.default
      scroll.contentView.postsFrameChangedNotifications = true
      scrollObservers = [
        center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
          MainActor.assumeIsolated {
            guard let self, let scroll else { return }
            self.dropScrollGeometry()
            self.snapToGuide()
            self.alignToCurrent(in: scroll)
          }
        },
        center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.isLiveScrolling = true
            self?.dropScrollGeometry()
            if self?.manualPosition != nil { self?.isHandScrolled = true }
          }
        },
        center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
          guard let self, let scroll else { return }
          MainActor.assumeIsolated { self.userDidScroll(scroll) }
        },
        center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.isLiveScrolling = false
            if self.isActivelyRunning, self.pendingUserSeeks == 0 { self.isHandScrolled = false }
            // The hand let go (momentum included): glide the word it chose onto the guide, once.
            if self.manualPosition == nil, let scroll {
              self.invalidateAlignment()
              self.align(scroll: scroll, tokenIndex: self.tokenIndex, guideFraction: self.guideFraction,
                         eases: !Self.reducesMotion())
            }
          }
        },
      ]
    }
    /// Takes the session's seek revision and returns whether it changed. A seek the hand scroll
    /// caused keeps Manual suppressed; any other (a click, Next passage, Restart) is explicit, so
    /// alignment follows it again.
    func noteSeekRevision(_ revision: Int) -> Bool {
      let bumps = revision &- seekRevision
      guard bumps != 0 else { return false }
      seekRevision = revision
      let fromHand = min(max(bumps, 0), pendingUserSeeks)
      pendingUserSeeks -= fromHand
      if bumps > fromHand { isHandScrolled = false }
      return true
    }
    /// Whether this document or style differs from what is drawn. It runs on every SwiftUI update,
    /// i.e. every word, so it compares instead of hashing the script: an unchanged document shares
    /// its storage with the drawn one, and that comparison returns at once.
    func needsRender(document: PrompterDocument, style: String) -> Bool {
      guard renderedDocument != document || renderedStyle != style else { return false }
      renderedDocument = document
      renderedStyle = style
      return true
    }
    func render(document: PrompterDocument, fontName: String, fontSize: Double, textOpacity: Double,
      fontWeight: String = "Regular", textColorHex: String = "#FFFFFF", lineSpacing: Double = 0.16,
      paragraphSpacing: Double = 0.34, alignment: String = "Left",
      showCues: Bool = true, highlightActiveWord: Bool = false)
    {
      guard let textView else { return }
      self.textOpacity = textOpacity
      self.highlightActiveWord = highlightActiveWord
      textColour = NSColor(hex: textColorHex) ?? .white
      // The editor's own layout, so the same Markdown has the same characters, paragraph styles and
      // height in both. Only presenter state (weight, cues, read colours) is applied after it.
      // Callouts are production notes, so the presenter leaves them out; offsets still map to the file.
      let model = FormattedMarkdownEditModel(markdown: document.markdown, omittingCallouts: true)
      let attributed = NSMutableAttributedString(attributedString: model.rendered(
        fontName: fontName, fontSize: fontSize,
        typography: EditorTypography(
          textColor: textColour.withAlphaComponent(textOpacity),
          lineSpacing: max(3, fontSize * lineSpacing), paragraphSpacing: max(10, fontSize * paragraphSpacing),
          alignment: NSTextAlignment(setting: alignment))))
      let full = NSRange(location: 0, length: attributed.length)
      // Presenter clicks seek within the script, including linked words.
      attributed.removeAttribute(.link, range: full)
      if fontWeight == "Bold" {
        attributed.enumerateAttribute(.font, in: full) { value, range, _ in
          guard let font = value as? NSFont else { return }
          attributed.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
        }
      }
      let visible = model.visibleIndices()
      var blockRanges: [UUID: NSRange] = [:]
      for block in document.blocks {
        let source = block.sourceRange
        let indices = (source.location..<(source.location + source.length)).compactMap { visible[$0] }
        if let low = indices.min(), let high = indices.max() {
          blockRanges[block.id] = NSRange(location: low, length: high - low + 1)
        }
      }
      mappings = []
      dropScrollGeometry()
      let plain = attributed.string as NSString
      let cueRanges = cueRanges(in: plain, document: document, blocks: blockRanges, visible: visible)
      for range in cueRanges {
        attributed.addAttribute(.foregroundColor, value: showCues ? textColour.withAlphaComponent(textOpacity * 0.42) : .clear, range: range)
      }
      if !showCues {
        // ponytail: retain character ranges with subpixel cue width; use glyph suppression if long cues measurably affect wrapping.
        for range in cueRanges {
          var hiddenRange = range
          let end = NSMaxRange(range)
          if end < plain.length, let scalar = UnicodeScalar(plain.character(at: end)),
            CharacterSet.whitespaces.contains(scalar)
          { hiddenRange.length += 1 }
          attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.1), range: hiddenRange)
          attributed.addAttribute(.kern, value: CGFloat(0), range: hiddenRange)
        }
      }
      var cursor = 0
      for (index, token) in document.spokenTokens.enumerated() {
        // A word maps straight from its source offset. Failing that it is looked for only inside its
        // own passage: a spoken word the rendering does not show (a code fence's language tag)
        // otherwise matched the same text paragraphs later, and every word after it mapped there
        // or nowhere: the presenter jumped ahead.
        guard let block = blockRanges[token.blockID] else { continue }
        var found = Self.visibleRange(token.sourceRange, in: visible, matching: token.text, in: plain)
          ?? NSRange(location: NSNotFound, length: 0)
        cursor = max(cursor, block.location)
        while found.location == NSNotFound, cursor < NSMaxRange(block) {
          let search = NSRange(location: cursor, length: NSMaxRange(block) - cursor)
          let candidate = plain.range(of: token.text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
          guard candidate.location != NSNotFound else { break }
          if cueRanges.contains(where: { NSIntersectionRange($0, candidate).length > 0 }) {
            cursor = candidate.location + candidate.length
          } else {
            found = candidate
          }
        }
        if found.location != NSNotFound {
          let range = punctuationRange(after: found, in: plain)
          mappings.append((range, index))
          cursor = range.location + range.length
        }
      }
      // Words already read stay dimmed through a re-render (a style change, an edit, a reopened
      // presenter or the end of an in-place edit): their colour goes in before the text is shown.
      let progress = max(tokenIndex, lastConfirmedTokenIndex ?? 0)
      for (range, index) in mappings where index <= progress {
        attributed.addAttribute(.foregroundColor, value: readColour(index), range: range)
      }
      textView.textStorage?.setAttributedString(attributed)
      lastReadTokenIndex = tokenIndex
      lastReadConfirmedTokenIndex = lastConfirmedTokenIndex
      textView.needsLayout = true
      invalidateAlignment()
    }
    func updateReadState() {
      guard let textView else { return }
      let values = [lastReadTokenIndex, tokenIndex, lastReadConfirmedTokenIndex, lastConfirmedTokenIndex]
        .compactMap { $0 }
      guard let lower = values.min(), let last = values.max(),
        lastReadTokenIndex != tokenIndex || lastReadConfirmedTokenIndex != lastConfirmedTokenIndex
      else { return }
      // Adding or clearing confirmation changes every preceding word's colour. Ordinary
      // unconfirmed progress still needs only the span between the old and new active words.
      let first = (lastReadConfirmedTokenIndex == nil) != (lastConfirmedTokenIndex == nil)
        ? min(0, lower) : lower
      // One edit transaction, so the text storage invalidates and redraws the changed span once
      // instead of once per word; a progress event can cover a dozen words.
      textView.textStorage?.beginEditing()
      var slot = mappingLowerBound(first)
      while slot < mappings.count, mappings[slot].1 <= last {
        let (range, index) = mappings[slot]
        textView.textStorage?.addAttribute(.foregroundColor, value: readColour(index), range: range)
        slot += 1
      }
      textView.textStorage?.endEditing()
      lastReadTokenIndex = tokenIndex
      lastReadConfirmedTokenIndex = lastConfirmedTokenIndex
    }
    /// Read words dim; the current word is highlighted when that is on.
    private func readColour(_ index: Int) -> NSColor {
      let confirmed = lastConfirmedTokenIndex.map { index <= $0 } ?? false
      let alpha = confirmed ? textOpacity * 0.38 : textOpacity
      return index == tokenIndex && !confirmed && highlightActiveWord
        ? .systemYellow.withAlphaComponent(alpha) : textColour.withAlphaComponent(alpha)
    }
    func seek(_ character: Int) {
      guard let nearest = mappings.min(by: { distance(character, $0.0) < distance(character, $1.0) }) else { return }
      onSeek(nearest.1)
    }
    func userDidScroll(_ scroll: NSScrollView) {
      guard isLiveScrolling, let textView,
        let manager = textView.layoutManager, let container = textView.textContainer
      else { return }
      layOutScript(manager, container)
      let guide = scroll.contentView.bounds.origin.y
        + layoutGuideY(height: scroll.contentView.bounds.height, fraction: guideFraction) - textView.textContainerInset.height
      // Each word is measured once per gesture, not twice per trackpad event (60 to 120 a second,
      // and a long script lagged behind the fingers). Layout holds still while the hand scrolls;
      // a render, resize or reflow drops these.
      let midYs = liveScrollMidYs ?? mappings.map { range in
        let glyph = manager.glyphRange(forCharacterRange: range.0, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyph, in: container).midY
      }
      liveScrollMidYs = midYs
      guard let slot = Self.nearestSlot(midYs, to: guide) else { return }
      let nearest = mappings[slot]
      tokenIndex = nearest.1
      lastConfirmedTokenIndex = nil
      if manualPosition != nil { pendingUserSeeks += 1 }
      (onUserScroll ?? onSeek)(nearest.1)
    }
    /// The first slot nearest `guide`. A scan, not a search: mappings are in token order, which is
    /// not always page order (a code fence's language tag can map to a later line of its body).
    static func nearestSlot(_ midYs: [CGFloat], to guide: CGFloat) -> Int? {
      midYs.indices.min { abs(midYs[$0] - guide) < abs(midYs[$1] - guide) }
    }
    private func layoutGuideY(height: CGFloat, fraction: Double) -> CGFloat {
      let visual = ScriptTextView.visualGuideY(height: height, fraction: fraction)
      return verticalMirror ? height - visual : visual
    }
    /// Assigning textContainerInset dirties the layout of the whole script, so only when the
    /// width really moved; the reflowed anchor then snaps back onto the guide line.
    func setSideInset(_ inset: CGFloat) {
      guard let textView, abs(textView.textContainerInset.width - inset) > 0.5 else { return }
      textView.textContainerInset.width = inset
      dropScrollGeometry()
      snapToGuide()
    }
    func invalidateAlignment() {
      lastAligned = nil
      lastGuideFraction = nil
      lastAlignmentDestination = nil
    }
    func dropScrollGeometry() { liveScrollMidYs = nil }
    /// Re-align on the next update without easing.
    func snapToGuide() {
      invalidateAlignment()
      snapNextAlignment = true
    }
    /// The layout ready to measure, with the top and bottom inset that let any word reach the guide.
    private func prepareGuide(_ scroll: NSScrollView, fraction: Double)
      -> (manager: NSLayoutManager, container: NSTextContainer, guideY: CGFloat)?
    {
      guard let textView, let manager = textView.layoutManager, let container = textView.textContainer
      else { return nil }
      let height = scroll.contentView.bounds.height
      let guideY = layoutGuideY(height: height, fraction: fraction)
      let edgeInset = max(80, max(guideY, height - guideY))
      // Same reason: re-laying the whole script out on every advance is the presenter's most
      // expensive recurring work, and the edge inset only changes when the window resizes.
      if abs(textView.textContainerInset.height - edgeInset) > 0.5 {
        textView.textContainerInset = NSSize(width: textView.textContainerInset.width, height: edgeInset)
      }
      layOutScript(manager, container)
      return (manager, container, guideY)
    }
    /// True while `layOutScript` runs. Each paragraph laid out grows the text view, and its
    /// `onLayout` used to align (and so lay out again) inside this very call: one open of a
    /// 4,800-word script ran 134 nested align passes, nested up to 15 deep, about 400 ms.
    private(set) var isLayingOutScript = false
    /// The whole script laid out, with the size changes it causes left to the caller, which
    /// measures and aligns once afterwards.
    private func layOutScript(_ manager: NSLayoutManager, _ container: NSTextContainer) {
      guard !isLayingOutScript else { return }
      isLayingOutScript = true
      defer { isLayingOutScript = false }
      manager.ensureLayout(for: container)
    }
    /// Where the scroll must sit to put this rendered range on the guide.
    private func scrollY(
      of range: NSRange, manager: NSLayoutManager, container: NSTextContainer, guideY: CGFloat
    ) -> CGFloat {
      let glyph = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
      return max(0, rect.midY + (textView?.textContainerInset.height ?? 0) - guideY)
    }
    /// The scroll for a fractional token position, interpolated between the token mappings so motion
    /// is continuous. Words on one line share a scroll position, so interpolating only between
    /// neighbouring words would hold still for a line and then jump one line in one word's time:
    /// instead the scroll runs from a line's first word to the next line's first word across the
    /// words in between. Each line's first word lands exactly on the guide; words with no rendered
    /// range are skipped.
    func manualScrollY(at position: Double, in scroll: NSScrollView) -> CGFloat? {
      guard !mappings.isEmpty, let (manager, container, guideY) = prepareGuide(scroll, fraction: guideFraction),
        let inset = textView?.textContainerInset.height
      else { return nil }
      // Unclamped, so the lines above the first scrollable one still count as different lines.
      func y(_ index: Int) -> CGFloat {
        let glyph = manager.glyphRange(forCharacterRange: mappings[index].0, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyph, in: container).midY + inset - guideY
      }
      let current = mappingIndex(at: position)
      let here = y(current)
      var first = current
      while first > 0, abs(y(first - 1) - here) < 2 { first -= 1 }
      var next = current + 1
      while next < mappings.count, abs(y(next) - here) < 2 { next += 1 }
      guard next < mappings.count else { return max(0, here) }
      let from = Double(mappings[first].1), to = Double(mappings[next].1)
      let fraction = min(max((position - from) / (to - from), 0), 1)
      return max(0, here + (y(next) - here) * CGFloat(fraction))
    }
    /// Mappings are appended in token order, with gaps for words the rendering omits.
    /// Return count when no token reaches the target, including an empty document.
    private func mappingLowerBound(_ tokenIndex: Int) -> Int {
      var low = 0
      var high = mappings.count
      while low < high {
        let middle = low + (high - low) / 2
        if mappings[middle].1 < tokenIndex { low = middle + 1 } else { high = middle }
      }
      return low
    }
    func mappingIndex(at position: Double) -> Int {
      var low = 0
      var high = mappings.count
      while low < high {
        let middle = low + (high - low) / 2
        if Double(mappings[middle].1) <= position {
          low = middle + 1
        } else {
          high = middle
        }
      }
      return max(0, low - 1)
    }
    /// Puts the session's Manual position on the guide. Used for every Manual alignment, running or
    /// not, so a pause holds the exact fraction; no easing, so Reduce Motion has nothing to remove.
    func alignManual(in scroll: NSScrollView) {
      guard !isHandScrolled, let position = manualPosition?() else { return }
      applyManualPosition(position, in: scroll)
    }
    func applyManualPosition(_ position: Double, in scroll: NSScrollView) {
      guard let target = manualScrollY(at: position, in: scroll) else { return }
      if endsVoiceAnimation {
        // Voice's easing may still be in flight from before the mode changed.
        scroll.contentView.layer?.removeAllAnimations()
        endsVoiceAnimation = false
      }
      let origin = scroll.contentView.bounds.origin
      guard abs(origin.y - target) > 0.01 else { return }
      scroll.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: target))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    /// The layout changed under the current word: Voice re-aligns on it, Manual on its position.
    func alignToCurrent(in scroll: NSScrollView) {
      if manualPosition != nil { alignManual(in: scroll) } else { align(scroll: scroll, tokenIndex: tokenIndex, guideFraction: guideFraction) }
    }
    /// Never while a hand is scrolling: a trackpad sends a continuous gesture, and snapping the
    /// nearest word onto the guide at each step fought the fingers and juddered (a mouse wheel's
    /// discrete clicks start no live scroll, so it never showed there). The end of the gesture
    /// settles it once.
    func align(scroll: NSScrollView, tokenIndex: Int, guideFraction: Double, eases: Bool? = nil) {
      guard !isLiveScrolling, (lastAligned != tokenIndex || lastGuideFraction != guideFraction) else { return }
      let slot = mappingLowerBound(tokenIndex)
      guard slot < mappings.count, mappings[slot].1 == tokenIndex,
        let (manager, container, guideY) = prepareGuide(scroll, fraction: guideFraction)
      else { return }
      let target = scrollY(of: mappings[slot].0, manager: manager, container: container, guideY: guideY)
      let animate = eases ?? (lastAligned != nil && isActivelyRunning && !snapNextAlignment && !Self.reducesMotion())
      let destination = NSPoint(x: scroll.contentView.bounds.origin.x, y: target)
      let isSameDestination = lastAlignmentDestination.map {
        abs($0.x - destination.x) <= 0.5 && abs($0.y - destination.y) <= 0.5
      } ?? false
      if !animate || !isSameDestination { Self.moveClip(scroll.contentView, destination, animate) }
      if !animate || !isSameDestination { scroll.reflectScrolledClipView(scroll.contentView) }
      lastAligned = tokenIndex
      lastGuideFraction = guideFraction
      lastAlignmentDestination = destination
      snapNextAlignment = false
    }
    /// The rendered range of a source range that maps character for character to `text`, else nil.
    private static func visibleRange(
      _ source: UTF16SourceRange, in visible: [Int: Int], matching text: String, in plain: NSString
    ) -> NSRange? {
      guard source.length > 0, let start = visible[source.location],
        let end = visible[source.location + source.length - 1], end - start == source.length - 1
      else { return nil }
      let range = NSRange(location: start, length: source.length)
      return plain.substring(with: range).compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        ? range : nil
    }
    private func cueRanges(
      in plain: NSString, document: PrompterDocument, blocks: [UUID: NSRange], visible: [Int: Int]
    ) -> [NSRange] {
      var result: [NSRange] = []
      for block in document.blocks {
        guard let bounds = blocks[block.id] else { continue }
        var cursor = bounds.location
        for cue in block.stageDirections {
          let bracketed = "[\(cue.text)]"
          if let range = Self.visibleRange(cue.sourceRange, in: visible, matching: bracketed, in: plain) {
            result.append(range)
            cursor = max(cursor, NSMaxRange(range))
            continue
          }
          guard cursor < NSMaxRange(bounds) else { continue }
          let search = NSRange(location: cursor, length: NSMaxRange(bounds) - cursor)
          let match = plain.range(of: bracketed, options: [.caseInsensitive, .diacriticInsensitive], range: search)
          let range = match.location == NSNotFound
            ? plain.range(of: cue.text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            : match
          if range.location != NSNotFound { result.append(range); cursor = NSMaxRange(range) }
        }
      }
      return result
    }
    private func punctuationRange(after range: NSRange, in text: NSString) -> NSRange {
      var end = range.upperBound
      while end < text.length,
        let scalar = UnicodeScalar(text.character(at: end)),
        CharacterSet.punctuationCharacters.contains(scalar)
      { end += 1 }
      return NSRange(location: range.location, length: end - range.location)
    }
    private func distance(_ point: Int, _ range: NSRange) -> Int {
      max(0, range.location - point, point - NSMaxRange(range))
    }
  }
}
private final class TrackingTextView: NSTextView {
  var onCharacterClick: ((Int) -> Void)?
  var onLayout: (() -> Void)?
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let manager = layoutManager, let container = textContainer {
      let adjusted = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
      let glyph = manager.glyphIndex(for: adjusted, in: container)
      guard glyph < manager.numberOfGlyphs else { super.mouseDown(with: event); return }
      let character = manager.characterIndexForGlyph(at: glyph)
      if character != NSNotFound {
        // Control-click is the context menu and shift-click extends a selection: neither seeks.
        guard event.modifierFlags.isDisjoint(with: [.control, .shift]) else { super.mouseDown(with: event); return }
        setSelectedRange(NSRange(location: 0, length: 0))
        // AppKit's own tracking runs until the button comes up: a drag leaves a selection for
        // the reference monitor, and a plain click still moves the reading position. A click
        // that wobbles over one character is still a click.
        super.mouseDown(with: event)
        if selectedRange().length <= 1 {
          setSelectedRange(NSRange(location: selectedRange().location, length: 0))
          onCharacterClick?(character)
        }
        return
      }
    }
    super.mouseDown(with: event)
  }
  override func setFrameSize(_ newSize: NSSize) {
    let sizeChanged = abs(newSize.width - frame.width) > 0.5 || abs(newSize.height - frame.height) > 0.5
    super.setFrameSize(newSize)
    if sizeChanged { onLayout?() }
  }
}

extension NSColor {
  /// "#RRGGBB", as the settings store colours.
  convenience init?(hex: String) {
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
    self.init(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
  }
  var hex: String {
    let c = usingColorSpace(.deviceRGB) ?? self
    return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
  }
}

extension NSTextAlignment {
  /// The settings' "Left", "Center" or "Right".
  init(setting: String) { self = setting == "Right" ? .right : setting == "Center" ? .center : .left }
}

/// An HStack that wraps onto further centred rows when its content is wider than it is offered.
struct WrapLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(for: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: width, height: height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(for: bounds.width, subviews: subviews) {
      var x = bounds.midX - row.width / 2
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }
  private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }
  private func rows(for maxWidth: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = [Row()]
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      if rows[rows.count - 1].width + extra > maxWidth, !rows[rows.count - 1].indices.isEmpty { rows.append(Row()) }
      let extraNow = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      rows[rows.count - 1].indices.append(index)
      rows[rows.count - 1].width += extraNow
      rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
    }
    return rows
  }
}
