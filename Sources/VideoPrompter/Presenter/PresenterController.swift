import AppKit
import Combine
import PrompterCore
import SwiftUI

@MainActor final class PresenterController: NSObject, NSWindowDelegate, ObservableObject {
  static let shared = PresenterController()
  /// Internal so a test can stand in for the panel.
  var panel: PresenterPanel?
  private var screenObserver: NSObjectProtocol?
  private weak var activeSession: SessionStore?
  private var draft: PresenterDraft?
  private let camera: CameraModel
  private let recorder: CameraRecorder
  @Published var asksToCloseRecording = false
  private var recordingWindow: NSPanel?
  private weak var presentationStore: AppStore?
  private var keepsRecordingOnClose = false
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

  init(camera: CameraModel = .shared, recorder: CameraRecorder = .shared, frameDefaults: UserDefaults? = PresenterFrameMemory.defaultStore()) {
    self.camera = camera
    self.recorder = recorder
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
    // The left button is held right now, and the event it belongs to is this window's: a click
    // released earlier, followed by a display dropping out, does not count.
    let leftHeld = NSEvent.pressedMouseButtons & 1 != 0
    let dragged = leftHeld && NSApp.currentEvent.map { event in
      event.window === window && [.leftMouseDown, .leftMouseDragged].contains(event.type)
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
    if keepsRecordingOnClose { closeWithoutRecordingPrompt() } else { close() }
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
    guard !isEditing else { return }
    guard let selection else {
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: "Select a passage first, then choose Pin Selected Text over Camera.", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
      return
    }
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
    if store.session.isActivelyRunning || store.session.isCountingDown { store.session.pause() } else if canStartReading { store.session.startReading() }
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
    if recorder.isRecording || recorder.isBusy { asksToCloseRecording = true; return false }
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
    presentationStore = store
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
    panel.title = "Video Prompter · Camera view in presenter"
    panel.settle()
    let draft = PresenterDraft()
    self.draft = draft
    let hosting = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, hasScript: false, camera: camera, recorder: recorder))
    hosting.sizingOptions = []
    panel.contentView = hosting
    recoverVisibleFrame(panel)
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func present(store: AppStore, on screen: NSScreen? = nil, activate: Bool = true) {
    presentationStore = store
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
    let hosting = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, hasScript: true, camera: camera, recorder: recorder))
    hosting.sizingOptions = []
    panel.contentView = hosting
    panel.makeFirstResponder(panel)
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
    if recorder.isRecording || recorder.isBusy { asksToCloseRecording = true; return }
    closeWithoutRecordingPrompt()
  }
  func stopAndClose() {
    Task {
      let previousError = recorder.errorMessage
      await recorder.stop()
      if recorder.errorMessage == previousError { showRecordingStatus(); closeNow() }
    }
  }
  func keepRecordingAndClose() {
    keepsRecordingOnClose = true
    showRecordingStatus()
    closeWithoutRecordingPrompt()
  }
  func windowDidMiniaturize(_ notification: Notification) {
    if recorder.isRecording || recorder.isBusy { showRecordingStatus() }
  }
  func preserveRecordingStatus() {
    if recorder.isRecording || recorder.isBusy { showRecordingStatus() }
  }
  func observeInterfaceSettings(_ store: AppStore) { presentationStore = store }

  private func showRecordingStatus() {
    if recordingWindow == nil {
      let window = NSPanel(contentRect: NSRect(x: 160, y: 160, width: 640, height: 400),
        styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
      window.title = "Camera recording"; window.level = .floating
      window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      if let store = presentationStore {
        window.contentView = NSHostingView(rootView: ScaledRecordingStatus(store: store, recorder: recorder, camera: camera) { [weak self] in self?.recordingWindow?.orderOut(nil) })
      } else {
        window.contentView = NSHostingView(rootView: RecordingStatusPanel(recorder: recorder, camera: camera) { [weak self] in self?.recordingWindow?.orderOut(nil) })
      }
      recordingWindow = window
    }
    recordingWindow?.orderFrontRegardless()
  }
  private func closeWithoutRecordingPrompt() {
    activeSession?.pause()
    // The flags go with the panel, so a present during the full-screen exit still rebuilds it.
    if isFullScreen { closesAfterFullScreen = true; panel?.toggleFullScreen(nil); return }
    keepsRecordingOnClose = false
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
    PresenterFrameMemory.clamp(rotation.fittedRect(aspect: picture, in: visibleFrame), into: visibleFrame)
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
    let size = NSSize(width: max(720, min(frame.width, area.width)), height: max(520, min(frame.height, area.height)))
    let x = min(max(frame.minX - max(0, size.width - frame.width) / 2, area.minX), area.maxX - size.width)
    let y = min(max(frame.minY - max(0, size.height - frame.height) / 2, area.minY), area.maxY - size.height)
    return NSRect(origin: NSPoint(x: x, y: y), size: size)
  }
}

/// The presenter window. At rest it is `.fullScreenAuxiliary`, which is what lets it float over
/// another app's full-screen Space (OBS, verified on 7 September). It turns `.fullScreenPrimary`
/// only for a full-screen Space of its own, and every way in comes through `toggleFullScreen`:
/// Prompter > Presenter Full Screen, View > Enter Full Screen (Ctrl-Cmd-F) and the green button.
class PresenterPanel: NSPanel {
  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    var frame = frameRect
    frame.size.width = max(720, frame.width)
    frame.size.height = max(520, frame.height)
    super.setFrame(frame, display: flag)
  }
  var onPassageKey: ((UInt16) -> Bool)?
  /// Bare arrows belong to the reading surface; every focused control keeps native key handling.
  func handlePassageKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, [123, 124].contains(event.keyCode),
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      firstResponder === self
    else { return false }
    return onPassageKey?(event.keyCode) == true
  }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown || event.type == .leftMouseDown {
      NotificationCenter.default.post(name: .init("VideoPrompter.presenterInteraction"), object: self)
    }
    super.sendEvent(event)
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
    minSize = NSSize(width: 720, height: 520)
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
      let title = store.scripts.first(where: { $0.id == recordID })?.metadata.title ?? "script"
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: "Changes saved to \(title)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
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

struct PresenterView: View {
  @Environment(\.openSettings) private var openSettings
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
  @Environment(\.offscreenRendering) private var offscreenRendering
  private var reduceTransparency: Bool { systemReduceTransparency || offscreenRendering }
  @ObservedObject private var controller = PresenterController.shared
  @ObservedObject var store: AppStore
  let session: SessionStore
  @StateObject private var presentation: PresenterSessionState
  @ObservedObject var draft: PresenterDraft
  /// False for the camera on its own; the session may still hold an earlier script, never shown.
  var hasScript = true
  @ObservedObject private var camera: CameraModel
  @ObservedObject private var monitor: ReferenceMonitor
  private let startsCamera: Bool

  init(store: AppStore, session: SessionStore, draft: PresenterDraft, hasScript: Bool = true,
       camera: CameraModel = .shared, monitor: ReferenceMonitor = .shared, startsCamera: Bool = true, recorder: CameraRecorder = .shared) {
    self.store = store
    self.session = session
    self.draft = draft
    self.hasScript = hasScript
    self.camera = camera
    self.monitor = monitor
    self.startsCamera = startsCamera
    self.recorder = recorder
    _presentation = StateObject(wrappedValue: PresenterSessionState(session: session))
  }
  @State private var countdown = 0
  @State private var editorNotice: String?
  @State private var showsMicrophone = false
  @State private var showsGuideSettings = false
  @State private var showsExposureSettings = false
  @State private var showsCameraOptions = false
  @State private var cameraSection = "Camera"
  @State private var settingsOrigin = "presenter-options"
  @State private var pointerOverControls = false
  @State private var controlsQuiet = false
  @State private var quietTask: Task<Void, Never>?
  @State private var showsSettings = false
  @State private var showsReadingControls = false
  @State private var showsTextControls = false
  @State private var showsCameraControls = false
  @State private var showsTakeDetails = false
  @Environment(\.openWindow) private var openWindow
  @State private var settingsTab = SettingsTab.reading
  @FocusState private var focusedTool: String?
  @Environment(\.undoManager) private var undoManager
  private var isTaking: Bool { session.isActivelyRunning || recorder.isRecording || recorder.isBusy }
  private var showsSetup: Bool { !isTaking || draft.isEditing }
  static func backdropOpacity(saved: Double, reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : saved }
  @State private var presenterWidth: CGFloat = 1000
  // Collapse secondary choices, never the user’s requested control size.
  static func controlZoom(_ zoom: Double) -> Double { zoom }
  private var controlZoom: Double { Self.controlZoom(store.uiZoom) }
  private var compactControls: Bool { presenterWidth / controlZoom < 1100 }
  private var popoverHeight: CGFloat { min(600, (controller.panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? 600) - 80 }
  @ObservedObject private var recorder: CameraRecorder
  /// The picker's fixed slot: a long camera name truncates instead of widening the bar.
  static let cameraPickerWidth: CGFloat = 120
  /// False in Video only, unless a draft was already open: it must stay reachable to finish or cancel.
  private var showsScript: Bool { !camera.cleanView && hasScript && (camera.displayMode != .videoOnly || draft.isEditing) }
  private var stage: some View {
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
            .task { if startsCamera { camera.start() } }
        }
        // Video only: the camera stage and its own guides, with no backdrop, script or reading guide.
        if showsScript {
        Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black)
          .opacity(Self.backdropOpacity(saved: store.settings.backdropOpacity(withVideo: camera.presentsWithVideo), reduceTransparency: reduceTransparency))
          .ignoresSafeArea()
        Group {
          if draft.isEditing {
            PresenterEditorView(session: session, draft: draft, settings: store.settings, sideInset: sideInset) {
              editorNotice = "That change could not be applied safely. Your text is unchanged. Try a smaller selection."
            }
          } else {
            PresenterScriptView(session: session, settings: store.settings, sideInset: sideInset, overVideo: camera.presentsWithVideo && !camera.cleanView)
          }
        }
        .scaleEffect(
          x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1
        ).rotationEffect(.degrees(Double(store.settings.rotation)))
        .clipped()
        GuideLine(settings: store.settings).offset(
          y: ScriptTextView.visualGuideY(height: geometry.size.height, fraction: store.settings.guideFraction))
        }
        if camera.presentsWithVideo && camera.needsRecovery {
          CameraRecoveryView(model: camera) { showsCameraControls = true }
            .uiZoom(controlZoom).padding(Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .environment(\.colorScheme, .dark)
        }
        if camera.presentsWithVideo && !camera.cleanView { ExposureLegend(model: camera).padding(Space.sm).frame(maxWidth: .infinity, alignment: .trailing) }
        if !hasScript, camera.displayMode != .videoOnly, !camera.cleanView {
          Text("No script yet. Choose one in the library and press Present to add it here.")
            .font(.title3).multilineTextAlignment(.center).foregroundStyle(.white)
            .padding(Space.lg).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Space.md))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

      }
    }.background(Color.clear)
  }
  private var trackedStage: some View {
    stage
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { presenterWidth = $0 }
    .onChange(of: store.settings) { _, value in
      session.updateSettings(value)
      recorder.useSettings(value)
    }
    .onReceive(session.$countdownRemaining.removeDuplicates()) { countdown = $0 }
    .onChange(of: session.isActivelyRunning) { _, _ in revealControls() }
    .onChange(of: session.seekRevision) { _, _ in revealControls() }
    .onReceive(NotificationCenter.default.publisher(for: .init("VideoPrompter.presenterInteraction"))) { _ in revealControls() }
    .onDisappear { quietTask?.cancel() }
    .onChange(of: camera.cleanView) { _, clean in
      if clean && session.isCountingDown { session.pause() }
      announce("Clean view " + (clean ? "on" : "off"))
    }
  }
  var body: some View {
    trackedStage
    .onAppear { recorder.useSettings(store.settings); camera.recorder = recorder; revealControls() }
    .onExitCommand {
      if showsMicrophone { showsMicrophone = false }
      else if showsGuideSettings { showsGuideSettings = false }
      else if showsExposureSettings { showsExposureSettings = false }
      else if showsReadingControls { showsReadingControls = false }
      else if showsTextControls { showsTextControls = false }
      else if showsCameraControls { showsCameraControls = false }
      else if showsSettings { showsSettings = false }
      else if camera.cleanView { camera.cleanView = false }
      else if draft.isEditing { draft.requestCancel() }
    }
    .onChange(of: camera.displayMode) { _, mode in
      monitor.displayModeDidChange(mode)
      if mode == .videoOnly { session.pause() }
    }
    .overlay(alignment: .top) {
      if showsSetup {
      HStack(spacing: Space.sm) {
      ZStack {
        Capsule().frame(width: 24, height: 4)
          .foregroundStyle(.primary)
        WindowDragHandle { window in
          guard store.settings.presenterSnappingEnabled else { return }
          PresenterController.shared.snapAfterDrag(window)
        }
      }
      .frame(width: 72, height: 12)
      .modifier(PresenterGlass(radius: 8))
      .padding(.top, 4)
      .accessibilityLabel("Drag presenter window")
      .accessibilityHint("Drag to move the presenter window")
      .help("Drag to move the presenter")
      .allowsHitTesting(!draft.isEditing)
      .accessibilityHidden(draft.isEditing)
      .fixedSize()
      }.frame(maxWidth: .infinity)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if let passage = monitor.passage, !showsScript, !camera.cleanView {
        PresenterReferenceCue(passage: passage, fontName: store.settings.fontName, readingSize: store.settings.fontSize, zoom: store.uiZoom) {
          PresenterController.shared.endMonitor()
        }
        .scaleEffect(x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1)
        .rotationEffect(.degrees(Double(store.settings.rotation)))
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      controlBar.environment(\.colorScheme, .dark)
    }
    .confirmationDialog("Close while a take is active?", isPresented: $controller.asksToCloseRecording) {
      Button("Stop and save, then close") { controller.stopAndClose() }
      Button("Keep recording") { controller.keepRecordingAndClose() }
      Button("Cancel", role: .cancel) {}
    } message: { Text("Keep recording leaves a recording status window with a Stop button.") }
    .confirmationDialog("Discard this presenter draft?", isPresented: $draft.closeRequested) {
      Button(draft.discardCloses ? "Discard Draft and Close" : "Discard Draft", role: .destructive) {
        draft.cancel(resuming: !draft.discardCloses)
        if draft.discardCloses { PresenterController.shared.closeNow() }
      }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("The draft has not been saved to the script library.")
    }
    .onChange(of: session.readingStatus) { _, value in if showsScript { announce(value) } }
    .onChange(of: session.anchorNotice) { _, value in if showsScript, let value { announce(value) } }
    .onChange(of: draft.errorMessage) { _, value in if let value { announce(value) } }
    .onChange(of: draft.markdown) { editorNotice = nil }
    .onChange(of: draft.isEditing) { _, isEditing in if isEditing { editorNotice = nil } }
  }

  private var controlBar: some View {
    Group {
      if reduceTransparency { barContent }
      else { GlassEffectContainer { barContent } }
    }.environment(\.colorScheme, .dark)
      .uiZoom(controlZoom).fixedSize(horizontal: false, vertical: true)
      .onHover { pointerOverControls = $0; revealControls() }
      .simultaneousGesture(TapGesture().onEnded { revealControls() })
      .popover(isPresented: $showsTakeDetails) {
        RecordingReceipt(recorder: recorder, camera: camera, zoom: controlZoom).padding(Space.md).uiZoom(controlZoom)
      }
      .popover(isPresented: $showsSettings) {
        PresenterSettingsPopover(store: store, initialTab: settingsTab, initialCameraSection: cameraSection)
      }
  }

  private var microphoneControls: some View {
    MicrophonePage(store: store, compact: true, startsMeter: startsCamera, recorder: recorder).uiZoom(controlZoom)
      .frame(width: 500, height: min(400, popoverHeight))
  }
  private var guideControls: some View {
    CameraGuideSettings(model: camera).uiZoom(controlZoom).frame(width: 500, height: min(500, popoverHeight))
  }
  private var exposureControls: some View {
    CameraExposureSettings(model: camera).uiZoom(controlZoom).frame(width: 500, height: min(500, popoverHeight))
  }
  private var hasOpenPopover: Bool {
    showsTakeDetails || showsSettings || showsReadingControls || showsTextControls || showsCameraControls
      || showsMicrophone || showsGuideSettings || showsExposureSettings
  }
  private func revealControls() {
    controlsQuiet = false
    quietTask?.cancel()
    guard session.isActivelyRunning else { return }
    quietTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      controlsQuiet = true
    }
  }
  private var secondaryOpacity: Double {
    controlsQuiet && !pointerOverControls && focusedTool == nil && !hasOpenPopover ? 0.75 : 1
  }
  private var barContent: some View {
    VStack(spacing: 0) {
      transport
      HStack(spacing: Space.sm) {
        if hasScript { readingModeButton }
        if recorder.isRecording {
          Text("REC " + String(format: "%02d:%02d", Int(recorder.recordedDuration) / 60, Int(recorder.recordedDuration) % 60))
            .foregroundStyle(.white).monospacedDigit()
            .padding(.horizontal, Space.xs).background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
        } else if recorder.isBusy {
          Text(recorder.phase == .saving ? "Saving…" : "Waiting for camera").lineLimit(1)
        }
        if recorder.isRecording {
          RecordingBarLevel(meter: recorder.inputMeter)
        }
        if recorder.isRecording || recorder.isBusy {
          RecordingHealthNotice(recorder: recorder, zoom: controlZoom)
        } else if recorder.savedTake != nil || recorder.takeFailure != nil { receipt }
        else if camera.presentsWithVideo && !hasScript {
          Text(camera.isReadyToRecord ? "Ready. Choose Record to save a video." : "Choose Camera to check the picture.").lineLimit(2)
        }
      }.font(.callout)
      if !camera.cleanView {
        tools.opacity(secondaryOpacity)
      }
    }.padding(Space.xs)
      .frame(maxWidth: .infinity)
      .modifier(PresenterGlass(radius: 20))
      .buttonStyle(PresenterButtonStyle()).font(.body).symbolRenderingMode(.hierarchical)
      .accessibilityIdentifier("presenter-control-bar")
  }

  private var receipt: some View {
    RecordingReceipt(recorder: recorder, camera: camera, configure: {
      settingsTab = recorder.recovery == .microphone ? .microphone : .camera
      cameraSection = recorder.recovery == .format ? "Recording" : "Camera"
      showsSettings = true
    }, zoom: controlZoom, compact: true)
    .frame(maxWidth: .infinity).layoutPriority(1)
  }

  private var transport: some View {
    HStack(spacing: Space.sm) {
      if draft.isEditing {
        Button("Save changes") { Task { await draft.confirm(store: store) } }
          .fixedSize()
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(draft.isSaving)
        Button("Cancel editing") { draft.requestCancel() }.fixedSize()
      } else if hasScript && (showsScript || camera.cleanView) {
        Button(action: session.toggle) {
          Text(countdown > 0 ? "Cancel countdown" : session.isActivelyRunning ? "Pause" : session.reachedEnd ? "Read again" : "Start reading")
            .fixedSize()
        }.accessibilityLabel(session.isCountingDown ? "Cancel countdown" : session.isActivelyRunning ? "Pause" : session.reachedEnd ? "Read again" : "Start reading")
          .buttonStyle(PresenterButtonStyle(prominent: true)).disabled(draft.isEditing)
        if !compactControls || (!session.isActivelyRunning && session.tokenIndex > 0) {
          Button("Back to start", systemImage: "arrow.counterclockwise", action: session.restart)
            .labelStyle(.iconOnly).accessibilityLabel("Back to start")
            .help("Back to start").disabled(draft.isEditing)
        }
      }
      if camera.presentsWithVideo {
        PresenterRecordButton(recorder: recorder, camera: camera, compact: true, showsStatus: false)
          .fixedSize()
          .help(camera.isReadyToRecord ? "Record a take. Reading starts separately." : "Choose a camera to record")

      } else {
        Button("Show camera") { camera.displayMode = .prompterWithVideo }
      }

      if camera.cleanView {
        Button("Exit clean view") { camera.cleanView = false }
      } else if !draft.isEditing { moreMenu }
    }.accessibilityIdentifier("presenter-transport")
  }

  private var readingStatusTitle: String {
    if draft.isEditing { return "Editing · not saved yet" }
    return "\(session.readingModeName) · \(session.readingStatus)" + (hasBottomNotice ? " · Check reading" : "")
  }

  private var readingModeButton: some View {
        Button { showsReadingControls.toggle() } label: {
          HStack(spacing: Space.xs) {
            ViewThatFits(in: .horizontal) {
              Text(readingStatusTitle).fixedSize()
              Text(draft.isEditing ? "Draft not saved" : "\(store.settings.mode == "Manual" ? "Auto" : "Voice") · \(hasBottomNotice ? "Check reading" : countdown > 0 ? "\(countdown)…" : session.readingStatus)").fixedSize()
            }.font(.callout)
            Image(systemName: "chevron.down")
          }
        }.accessibilityIdentifier("presenter-status")
          .accessibilityLabel("Reading mode")
          .accessibilityValue(draft.isEditing ? "Editing · not saved yet" : "\(session.readingModeName) · \(session.readingStatus). \(session.readingNextAction)" + (hasBottomNotice ? " " + (editorNotice ?? session.anchorNotice ?? draft.errorMessage ?? draft.noticeMessage ?? "Review draft before saving") : ""))
          .accessibilityHint(hasBottomNotice ? (editorNotice ?? session.anchorNotice ?? draft.errorMessage ?? draft.noticeMessage ?? "Review draft before saving") : "Choose reading mode and speed")
          .restoringPopoverFocus(isPresented: $showsReadingControls, identifier: "presenter-reading-mode")
          .popover(isPresented: $showsReadingControls) {
            if hasBottomNotice { bottomNotice.padding(Space.sm).uiZoom(controlZoom) } else { readingControls }
          }.buttonStyle(.plain)
  }

  private func viewMenu(compact: Bool) -> some View {
    Menu {
      Picker("View", selection: $camera.displayMode) {
        ForEach(PresenterDisplayMode.allCases) { Text($0.label).tag($0) }
      }.pickerStyle(.inline)
    } label: { if compact { Text("View") } else { Label("View", systemImage: camera.displayMode.systemImage) } }
      .menuIndicator(.visible)
      .accessibilityLabel("View").accessibilityValue(camera.displayMode.label)
      .focusable().focused($focusedTool, equals: "View")
  }
  private var readingControls: some View {
    Form {
      Picker("Mode", selection: $store.settings.mode) {
        Text("Voice follow").tag("Voice")
        Text("Automatic scroll").tag("Manual")
      }
      if store.settings.mode == "Manual" {
        AutomaticScrollDelay(session: session)
        LabeledContent("Reading speed") {
          Slider(value: $store.settings.speed, in: 30...300, step: 5)
            .accessibilityLabel("Reading speed").accessibilityValue("\(Int(store.settings.speed)) words per minute")
          Text("\(Int(store.settings.speed)) wpm")
        }
      } else {
        Text("Follows your voice. On first use, allow microphone and speech access when asked.").font(.callout)
      }
    }.formStyle(.grouped).frame(width: 400, height: 300).uiZoom(controlZoom)
  }

  private var textControls: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text("Reading text · \(Int(store.settings.fontSize)) points").font(.headline)
      HStack {
        Button("Smaller text") { changeReadingSize(-4) }
          .accessibilityValue("\(Int(store.settings.fontSize)) points").disabled(store.settings.fontSize <= 18)
        Button("Larger text") { changeReadingSize(4) }
          .accessibilityValue("\(Int(store.settings.fontSize)) points").disabled(store.settings.fontSize >= 120)
      }
    }.padding(Space.md).uiZoom(controlZoom).fixedSize()
  }

  private var cameraControls: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      if camera.recordingLocked {
        Text("Stop recording to change camera.").font(.callout)
      } else {
        CameraPickerList(model: camera, zoom: controlZoom, startsPreview: startsCamera) { showsCameraControls = false }
      }
      DisclosureGroup("Camera options", isExpanded: $showsCameraOptions) {
        Picker("Rotation", selection: Binding(get: { camera.guides.rotation }, set: { camera.setRotation($0) })) {
          ForEach(CameraRotation.allCases, id: \.self) { Text($0.label).tag($0) }
        }.disabled(camera.recordingLocked)
        Text("Rotation changes the preview and saved video.").font(.callout)
        Text(recorder.outputSummary(camera: camera)).font(.callout).fixedSize(horizontal: false, vertical: true)
        Button("Framing guides") { showsGuideSettings = true }
          .restoringPopoverFocus(isPresented: $showsGuideSettings, identifier: "presenter-camera-guides")
          .popover(isPresented: $showsGuideSettings) { guideControls }
        Button("Recording settings…") { settingsOrigin = "presenter-camera"; showsCameraControls = false; settingsTab = .camera; cameraSection = "Recording"; showsSettings = true }
        Button("Recordings folder") { recorder.openRecordingsFolder() }
        Button("Open Camera Monitor") { openWindow(id: "camera") }
        Text("An optional second window showing the same camera and recording.").font(.callout)
      }
    }.padding(Space.md).modifier(PresenterControlViewport(maxHeight: popoverHeight / controlZoom))
      .uiZoom(controlZoom)
  }

  private var tools: some View {
    HStack(spacing: Space.sm) {
      if showsScript {
        Button("Text") { showsTextControls.toggle() }
          .focused($focusedTool, equals: "Text")
          .restoringPopoverFocus(isPresented: $showsTextControls, identifier: "presenter-text")
          .accessibilityValue("\(Int(store.settings.fontSize)) points")
          .popover(isPresented: $showsTextControls) { textControls }
      }
      Button("Camera") { showsCameraControls.toggle() }
        .focused($focusedTool, equals: "Camera")
        .restoringPopoverFocus(isPresented: Binding(get: { showsCameraControls || (showsSettings && settingsOrigin == "presenter-camera") }, set: { if !$0 { showsCameraControls = false; showsSettings = false } }), identifier: "presenter-camera")
        .popover(isPresented: $showsCameraControls) { cameraControls }
      if camera.presentsWithVideo {
        Button("Exposure") { showsExposureSettings.toggle() }
          .focused($focusedTool, equals: "Exposure")
          .restoringPopoverFocus(isPresented: $showsExposureSettings, identifier: "presenter-exposure")
          .popover(isPresented: $showsExposureSettings) {
            VStack {
              Button("Clean view") { camera.cleanView = true; showsExposureSettings = false }
              exposureControls
            }.padding(Space.sm)
          }
      }
      Button("Microphone") { showsMicrophone.toggle() }
        .accessibilityValue(followingMicrophoneName).help(microphoneHelp)
        .focused($focusedTool, equals: "Microphone")
        .restoringPopoverFocus(isPresented: $showsMicrophone, identifier: "presenter-microphone")
        .popover(isPresented: $showsMicrophone) { microphoneControls }
    }.labelStyle(.titleOnly)
  }
  private var moreMenu: some View {
      Menu {
        viewMenu(compact: true)
        if showsScript {
          Button("Back to start", systemImage: "arrow.counterclockwise", action: session.restart)
            .help("Back to start (⌥⌘R)").disabled(draft.isEditing)
          if !draft.isEditing { Button("Edit script", systemImage: "pencil") { draft.begin(session: session) } }
        }
        Menu("Reading presets") {
          if store.presets.isEmpty { Text("No reading presets yet") }
          Button("Save current settings…") { settingsOrigin = "presenter-options"; settingsTab = .presets; showsSettings = true }
          Button("Manage reading presets…") { settingsOrigin = "presenter-options"; settingsTab = .presets; showsSettings = true }
          Divider()
          ForEach(store.presets) { preset in Button("\(preset.name)\n\(preset.readingSummary)") { store.applyPreset(preset, undoManager: undoManager) } }
        }
        if recorder.savedTake != nil || recorder.takeFailure != nil {
          Button("Take details…") { showsTakeDetails = true }
        }
        Button("Settings…") { settingsOrigin = "presenter-options"; settingsTab = showsScript ? .reading : .camera; cameraSection = "Camera"; showsSettings = true }
        Button("Pin Selected Text over Camera") { controller.monitorSelection(store: store) }.disabled(draft.isEditing)
        Button("Match Camera Size") { controller.matchCameraSize() }.disabled(!camera.presentsWithVideo)
        Button("Presenter Full Screen") { controller.toggleFullScreen() }
        Button("Close Presenter") { controller.close() }.keyboardShortcut("w")
      } label: { Text("More") }.accessibilityLabel("Presenter options").menuIndicator(.visible)
        .focused($focusedTool, equals: "Presenter options")
        .restoringPopoverFocus(isPresented: Binding(get: { (showsSettings && settingsOrigin == "presenter-options") || showsTakeDetails }, set: { if !$0 { showsSettings = false; showsTakeDetails = false } }), identifier: "presenter-options")
  }
  private var followingMicrophoneName: String {
    AudioCapture.inputDevices().first { $0.uid == store.settings.audioDeviceUID }?.name ?? "System default"
  }
  private var microphoneHelp: String {
    recorder.usesSeparateMicrophone ? "Microphone: \(followingMicrophoneName). Recording microphone: \(recorder.microphoneName)." : followingMicrophoneName
  }
  private func changeReadingSize(_ step: Double) {
    store.settings.fontSize = min(120, max(18, store.settings.fontSize + step))
    announce("Reading text \(Int(store.settings.fontSize)) points")
  }

  private func announce(_ message: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }

  private var bottomNotice: some View {
    VStack(spacing: Space.sm) {
      Button("Reading mode and speed") { settingsTab = .reading; showsSettings = true }
      if draft.isEditing, draft.hasExternalChange(in: store) {
        Text("This script changed outside Video Prompter. Finishing will keep this draft and show a conflict instead of overwriting it.")
          .foregroundStyle(.orange)
      }
      if let error = draft.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.primary)
        Button("Save as Separate Script") { Task { await draft.saveAsCopy(store: store) } }
          .disabled(draft.isSaving)
      }
      if let notice = editorNotice ?? session.anchorNotice ?? draft.noticeMessage { Text(notice) }
      if session.anchorNotice != nil && store.settings.mode == "Voice" {
        WrapLayout(spacing: Space.sm) {
          Button("Microphone") { settingsTab = .microphone; showsSettings = true }
          Button("Use Automatic scroll") { store.settings.mode = "Manual" }
          if session.anchorNotice?.contains("System Settings") == true {
            Button("Microphone permission…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
          }
        }
      }
    }
    .font(.callout).multilineTextAlignment(.leading)
    .fixedSize(horizontal: false, vertical: true)
    .padding(Space.sm).modifier(PresenterGlass(radius: 12))
    .frame(maxWidth: 560)
  }
  private var hasBottomNotice: Bool {
    editorNotice != nil || session.anchorNotice != nil || draft.noticeMessage != nil
      || draft.errorMessage != nil || (draft.isEditing && draft.hasExternalChange(in: store))
  }

}

/// Editing still observes reading position, independently of the camera and presenter controls.
struct PresenterEditorView: View {
  @ObservedObject var session: SessionStore
  @ObservedObject var draft: PresenterDraft
  let settings: PrompterSettings
  let sideInset: CGFloat
  var onUnsupportedEdit: () -> Void

  var body: some View {
    FormattedMarkdownEditor(
      markdown: $draft.markdown, fontName: settings.fontName, fontSize: settings.fontSize,
      onUnsupportedEdit: onUnsupportedEdit, focusesOnAppear: true,
      typography: presenterTypography(settings, sideInset: sideInset),
      anchorSourceOffset: session.activeToken?.sourceRange.location,
      guideFraction: settings.guideFraction,
      verticalMirror: settings.verticalMirror != (settings.rotation == 180),
      readThroughSourceOffset: session.lastConfirmedTokenIndex.flatMap { index in
        let tokens = session.document.spokenTokens
        return tokens.indices.contains(index) ? tokens[index].sourceRange.upperBound : nil
      })
      .background(PresenterLinkContrast(colour: NSColor(hex: settings.textColorHex) ?? .white))
  }
  private func presenterTypography(_ settings: PrompterSettings, sideInset: CGFloat) -> EditorTypography {
    EditorTypography(
      textColor: (NSColor(hex: settings.textColorHex) ?? .white)
        .withAlphaComponent(settings.textOpacity),
      lineSpacing: max(3, settings.fontSize * settings.lineSpacing),
      paragraphSpacing: max(10, settings.fontSize * settings.paragraphSpacing),
      horizontalInset: sideInset,
      alignment: NSTextAlignment(setting: settings.alignment))
  }
}

/// Word changes invalidate only the text representable, not the camera and presenter controls.
private struct PresenterScriptView: View {
  @ObservedObject var session: SessionStore
  let settings: PrompterSettings
  let sideInset: CGFloat
  var overVideo = false

  var body: some View {
    ScriptTextView(
      document: session.document, tokenIndex: session.tokenIndex,
      lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
      isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
      guideFraction: settings.guideFraction,
      verticalMirror: settings.verticalMirror != (settings.rotation == 180),
      fontName: settings.fontName,
      fontSize: settings.fontSize, textOpacity: settings.textOpacity,
      fontWeight: settings.fontWeight, textColorHex: settings.textColorHex,
      lineSpacing: settings.lineSpacing, paragraphSpacing: settings.paragraphSpacing,
      horizontalMargin: sideInset, alignment: settings.alignment,
      overVideo: overVideo, showCues: settings.showCues, highlightActiveWord: settings.highlightActiveWord,
      manualPosition: session.isManual ? { session.manualPosition() }
        : ScriptTextView.Coordinator.reducesMotion() ? nil : { session.voicePosition() },
      onSeek: session.seek, onUserScroll: session.seekFromUserScroll
    )
  }
}

/// The reading line across the presenter, drawn over the video too.
struct GuideLine: View {
  let settings: PrompterSettings
  var body: some View {
    HStack {
      Rectangle().frame(width: 12, height: 3)
      Spacer()
      Rectangle().frame(width: 12, height: 3)
    }.foregroundStyle(.cyan.opacity(settings.guideOpacity)).allowsHitTesting(false).accessibilityHidden(true)
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

/// Long recovery messages and enlarged controls stay reachable without consuming the script.
private struct PresenterControlViewport: ViewModifier {
  let maxHeight: CGFloat
  @State private var contentHeight: CGFloat = 200
  func body(content: Content) -> some View {
    ScrollView(.vertical) {
      content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .frame(height: min(contentHeight, maxHeight))
    .scrollDisabled(contentHeight <= maxHeight)
  }
}

/// The status window observes the same accommodation even after the presenter is closed.
private struct ScaledRecordingStatus: View {
  @ObservedObject var store: AppStore
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  var dismiss: () -> Void
  var body: some View {
    RecordingStatusPanel(recorder: recorder, camera: camera, zoom: store.uiZoom, dismiss: dismiss)
  }
}

/// Reserve room above the image instead of covering the composition with the pinned passage.
struct PresenterReferenceCue: View {
  let passage: String
  let fontName: String
  let readingSize: Double
  var zoom = 1.0
  var end: () -> Void
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack {
        Text("Pinned reference").font(.headline)
        Spacer()
        Button(expanded ? "Collapse passage" : "Expand passage") { expanded.toggle() }
        Button("Back to script", action: end).keyboardShortcut(.escape, modifiers: [])
      }.uiZoom(zoom)
      if expanded {
        ScrollView { Text(passage).font(.custom(fontName, size: readingSize)).frame(maxWidth: .infinity, alignment: .leading) }
          .frame(maxHeight: 160)
      } else {
        Text(passage).font(.custom(fontName, size: readingSize)).lineLimit(2)
          .help("Expand passage to read and scroll through all the pinned text")
      }
    }.padding(Space.md).foregroundStyle(.white).background(.black)
  }
}

private struct PresenterLinkContrast: NSViewRepresentable {
  let colour: NSColor
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    // SwiftUI updates the editor after the background; apply to its native sibling next turn.
    DispatchQueue.main.async {
      func update(_ node: NSView) {
        if let text = node as? NSTextView {
          text.linkTextAttributes = [.foregroundColor: colour, .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
        node.subviews.forEach(update)
      }
      if let root = view.window?.contentView { update(root) }
    }
  }
}

/// One dark glass treatment for presenter chrome, with a solid accessibility fallback.
struct PresenterGlass: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
  @Environment(\.offscreenRendering) private var offscreenRendering
  private var reduceTransparency: Bool { systemReduceTransparency || offscreenRendering }
  let radius: CGFloat
  func body(content: Content) -> some View {
    if reduceTransparency { content.background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: radius)) }
    else { content.glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: radius)) }
  }
}

struct PresenterButtonStyle: PrimitiveButtonStyle {
  @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
  @Environment(\.offscreenRendering) private var offscreenRendering
  private var reduceTransparency: Bool { systemReduceTransparency || offscreenRendering }
  var prominent = false
  func makeBody(configuration: Configuration) -> some View {
    if reduceTransparency {
      if prominent { Button(configuration).buttonStyle(.borderedProminent) }
      else { Button(configuration).buttonStyle(.bordered) }
    } else {
      if prominent { Button(configuration).buttonStyle(.glassProminent) }
      else { Button(configuration).buttonStyle(.glass) }
    }
  }
}

// Offscreen cacheDisplay cannot composite Liquid Glass. Fixtures exercise its solid fallback;
// real glass geometry is still checked by the native accessibility tests.
private struct OffscreenRenderingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var offscreenRendering: Bool {
    get { self[OffscreenRenderingKey.self] }
    set { self[OffscreenRenderingKey.self] = newValue }
  }
}

/// Observes the recording input already being captured, without starting another microphone.
private struct RecordingBarLevel: View {
  @ObservedObject var meter: InputMeter
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      HStack {
        InputLevelMeter(peakDBFS: meter.isFresh() ? meter.peakDBFS : -.infinity,
                        isClipping: meter.isClipping, showsScale: false)
      }.frame(width: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Recording microphone level")
        .accessibilityValue(meter.isFresh() ? String(format: "%.1f dBFS", meter.peakDBFS) : "No recent audio")
    }
  }
}
