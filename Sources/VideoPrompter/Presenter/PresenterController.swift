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
    panel.contentView = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, hasScript: false, camera: camera, recorder: recorder))
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
    panel.contentView = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, hasScript: true, camera: camera, recorder: recorder))
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
      if recorder.errorMessage == previousError { closeNow() }
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
  private func showRecordingStatus() {
    if recordingWindow == nil {
      let window = NSPanel(contentRect: NSRect(x: 160, y: 160, width: 520, height: 160),
        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
      window.title = "Camera recording"; window.level = .floating
      window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.contentView = NSHostingView(rootView: RecordingStatusPanel(recorder: recorder, camera: camera) { [weak self] in self?.recordingWindow?.orderOut(nil) })
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
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown { NotificationCenter.default.post(name: .init("VideoPrompter.revealControls"), object: self) }
    super.sendEvent(event)
  }
  /// Bare arrows belong to the reading surface; every focused control keeps native key handling.
  func handlePassageKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, [123, 124].contains(event.keyCode),
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      firstResponder === self
    else { return false }
    NotificationCenter.default.post(name: .init("VideoPrompter.revealControls"), object: self)
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

struct PresenterView: View {
  @Environment(\.openSettings) private var openSettings
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
  @State private var editorNotice: String?
  @State private var showsCameraSettings = false
  @State private var showsGuideSettings = false
  @State private var showsReadingSettings = false
  @State private var showsExposureSettings = false
  @State private var controlsRevealed = false
  @State private var pointerInControls = false
  @State private var revealGeneration = 0
  private var isTaking: Bool { session.isActivelyRunning || recorder.isRecording || recorder.isBusy }
  private var showsSetup: Bool { !isTaking || controlsRevealed || draft.isEditing || showsReadingSettings || showsCameraSettings || showsGuideSettings || showsExposureSettings }
  static func backdropOpacity(saved: Double, reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : saved }
  @State private var presenterWidth: CGFloat = 1000
  @State private var presenterHeight: CGFloat = 600
  private var compactControls: Bool { presenterWidth / store.uiZoom < 600 }
  @ObservedObject private var recorder: CameraRecorder
  /// The picker's fixed slot: a long camera name truncates instead of widening the bar.
  static let cameraPickerWidth: CGFloat = 120
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
            PresenterScriptView(session: session, settings: store.settings, sideInset: sideInset)
          }
        }
        .scaleEffect(
          x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1
        ).rotationEffect(.degrees(Double(store.settings.rotation)))
        .clipped()
        GuideLine(settings: store.settings).offset(
          y: ScriptTextView.visualGuideY(height: geometry.size.height, fraction: store.settings.guideFraction))
        }
        if camera.presentsWithVideo { ExposureLegend(model: camera).padding(Space.sm).frame(maxWidth: .infinity, alignment: .trailing) }
        if !hasScript, camera.displayMode != .videoOnly {
          Text("No script yet. Choose one in the library and press Present to add it here.")
            .font(.title3).multilineTextAlignment(.center).foregroundStyle(.white)
            .padding(16).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Space.md))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let passage = monitor.passage, !showsScript {
          ReferenceMonitorCaption(passage: passage, fontName: store.settings.fontName, readingSize: store.settings.fontSize, zoom: store.uiZoom) {
            PresenterController.shared.endMonitor()
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          .padding(.bottom, 8)
          // Read through the same glass as the script.
          .scaleEffect(x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1)
          .rotationEffect(.degrees(Double(store.settings.rotation)))
        }
      }
    }.background(Color.clear)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { presenterWidth = $0 }
    .onChange(of: store.settings) { _, value in
      session.updateSettings(value)
    }
    .onChange(of: camera.displayMode) { _, mode in
      monitor.displayModeDidChange(mode)
      if mode == .videoOnly { session.pause() }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if showsSetup {
      HStack(spacing: Space.sm) {
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
      }.frame(maxWidth: .infinity)
      }
    }
    // Both notices and controls reserve their actual wrapped height for reading and editing.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        if camera.presentsWithVideo, let message = camera.unavailableMessage {
          Label(message, systemImage: "video.slash").font(.callout)
          if camera.authorization == .denied {
            Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }
          }
        }
        if showsScript, let detail = session.readingDetail, session.isActivelyRunning {
          Text(detail).font(.callout)
        }
        if showsScript && hasBottomNotice {
          bottomNotice.padding(.horizontal, Space.md).padding(.top, Space.sm)
        }
        WrapLayout(spacing: 8) {
          if showsScript {
          Label(draft.isEditing ? "Editing" : session.readingStatus,
                systemImage: draft.isEditing ? "pencil" : session.isActivelyRunning ? (session.isManual ? "text.line.first.and.arrowtriangle.forward" : "mic.fill") : "pause.circle")
            .font(.caption.weight(.semibold))
            .fixedSize()
            .foregroundStyle(Color.primary)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
            .background((draft.isEditing ? Color.orange : session.isActivelyRunning ? Color.accentColor : Color.secondary).opacity(0.14), in: Capsule())
            .help(draft.isEditing ? "Editing the script. Finish with ⌘Return, or cancel." : session.isActivelyRunning ? session.readingStatus : "Press Start reading to begin or continue")
          // Disabled, not hidden, while editing: the capsule keeps its shape and VoiceOver reads them as dimmed.
          Group {
            CapsuleButton(session.isActivelyRunning ? "Pause" : "Start reading",
                          systemImage: session.isActivelyRunning ? "pause.fill" : "play.fill", showsTitle: true, help: "Start or pause following at the current position (⌥⌘S)", action: session.toggle)
              .buttonStyle(.borderedProminent)
            if showsSetup {
              CapsuleButton("Back to start", systemImage: "arrow.counterclockwise", help: "Return to the first word of the script (⌥⌘R)", action: session.restart)
            }
          }.disabled(!showsScript || draft.isEditing)
          if showsSetup {
          Button("Reading", systemImage: "textformat.size") { showsReadingSettings = true }
            .help("Change reading mode, speed and text size")
            .popover(isPresented: $showsReadingSettings) {
              InspectorView(store: store, camera: camera).frame(width: 400, height: 540).uiZoom(store.uiZoom)
            }
          }
          }
          if isTaking {
            Button(showsSetup ? "Hide controls" : "Show controls", systemImage: "slider.horizontal.3") { controlsRevealed.toggle() }
          }
          if camera.presentsWithVideo || recorder.isRecording || recorder.isBusy {
            RecordingControls(recorder: recorder, camera: camera, compact: compactControls, showsSetup: false, zoom: store.uiZoom)
          }
        }.buttonStyle(.bordered).padding(Space.sm)
        if showsSetup {

        if camera.presentsWithVideo {
        WrapLayout(spacing: 8) {
          RecordingSetupSummary(recorder: recorder, camera: camera, zoom: store.uiZoom)
        }.buttonStyle(.bordered).padding(8)

        }
        WrapLayout(spacing: 8) {
          // A conventional menu keeps the whole View label predictable.
          Menu {
            Picker("What to show", selection: $camera.displayMode) {
              ForEach(PresenterDisplayMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode)
              }
            }.pickerStyle(.inline)
            Divider()
            Button("Pin Selected Text over Camera") { PresenterController.shared.monitorSelection(store: store) }
              .disabled(draft.isEditing || ReferenceMonitor.focusedSelection() == nil)
              .help("Drag across a passage first; it is pinned over the camera picture")
            Button("Camera Settings…") { showsCameraSettings = true }
              .disabled(!camera.presentsWithVideo)
          } label: {
            // A titled label: an icon-only one dropped the menu from the accessibility tree, and a
            // Text image drew as a blank square in the bordered bar.
            Label("View", systemImage: camera.displayMode.systemImage).labelStyle(.titleAndIcon)
          }
          .menuStyle(.button).menuIndicator(.visible).fixedSize().frame(width: 88)
          .accessibilityLabel("Presenter view")
          .accessibilityValue(camera.displayMode.label)
          .help("Choose a view, Camera Settings or the reference monitor. \(camera.displayMode.label) now")
          .background {
            Color.clear.popover(isPresented: $showsCameraSettings, arrowEdge: .top) {
              CameraSettingsPanel(model: camera, zoom: store.uiZoom).frame(width: 320).uiZoom(store.uiZoom).disabled(recorder.isRecording || recorder.isBusy)
            }
          }
          // Camera setup is available only while showing a camera.
          if camera.presentsWithVideo {
            CameraPicker(model: camera, zoom: store.uiZoom, darkSurface: true).frame(width: Self.cameraPickerWidth).disabled(recorder.isRecording || recorder.isBusy)
            CapsuleButton("Framing guides", systemImage: "squareshape.split.3x3", displayTitle: compactControls ? "Guides" : nil,
                          help: camera.presentsWithVideo ? "Choose composition lines and an output frame marker" : "Show the camera with View to use framing guides") {
              showsGuideSettings = true
            }
            .popover(isPresented: $showsGuideSettings, arrowEdge: .top) {
              CameraGuideSettings(model: camera).frame(width: 300).padding().uiZoom(store.uiZoom)
            }
            Button("Exposure", systemImage: "sun.max") { showsExposureSettings = true }
              .popover(isPresented: $showsExposureSettings) {
                CameraExposureSettings(model: camera).frame(width: 360, height: 500).uiZoom(store.uiZoom)
              }
          }
          if showsScript {
          CapsuleButton(draft.isEditing ? "Finish editing" : "Edit script",
                        systemImage: draft.isEditing ? "checkmark" : "pencil", displayTitle: compactControls ? (draft.isEditing ? "Finish" : "Edit") : nil,
                        shortcut: draft.isEditing ? KeyboardShortcut(.return, modifiers: .command) : nil, help: "Edit the script here; Finish editing saves your changes") {
            if draft.isEditing { Task { await draft.confirm(store: store) } } else { draft.begin(session: session) }
          }.disabled(draft.isSaving || !showsScript)
          }
          if draft.isEditing {
            CapsuleButton("Cancel editing", systemImage: "xmark", shortcut: .cancelAction, help: "Leave editing; confirm before discarding an unsaved draft") { draft.requestCancel() }
              .disabled(draft.isSaving)
          } else {
            CapsuleButton("Close presenter", systemImage: "xmark", displayTitle: compactControls ? "Close" : nil, help: "Close the presenter and pause following") { PresenterController.shared.close() }
          }
        }
        .buttonStyle(.bordered).padding(8)

        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        }
      }.background(.regularMaterial)
        .onHover { inside in pointerInControls = inside; revealControls() }
        .frame(maxWidth: .infinity, alignment: .center)
        .controlSize(compactControls ? .small : .regular)
        .uiZoom(store.uiZoom)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .modifier(PresenterControlViewport(maxHeight: presenterHeight * 0.55))
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { presenterHeight = $0 }
    .onReceive(NotificationCenter.default.publisher(for: .init("VideoPrompter.revealControls"))) { notification in
      if (notification.object as? NSWindow) === controller.panel { revealControls() }
    }
    .task(id: revealGeneration) {
      guard controlsRevealed else { return }
      try? await Task.sleep(for: .seconds(4))
      if !Task.isCancelled && !pointerInControls { controlsRevealed = false }
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

  private func revealControls() { controlsRevealed = true; revealGeneration += 1 }

  private func announce(_ message: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }

  private var bottomNotice: some View {
    VStack(spacing: Space.sm) {
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
        WrapLayout(spacing: 8) {
          Button("Voice settings…") { AppSettingsView.requestVoiceTab(); openSettings() }
          Button("Use Manual") { store.settings.mode = "Manual" }
          if session.anchorNotice?.contains("System Settings") == true {
            Button("Microphone permission…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
          }
        }
      }
    }
    .font(.callout).multilineTextAlignment(.leading)
    .fixedSize(horizontal: false, vertical: true)
    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: Space.md))
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
      showCues: settings.showCues, highlightActiveWord: settings.highlightActiveWord,
      manualPosition: session.isManual ? { session.manualPosition() }
        : ScriptTextView.Coordinator.reducesMotion() ? nil : { session.voicePosition() },
      onSeek: session.seek, onUserScroll: session.seekFromUserScroll
    )
  }
}

/// Core actions show their titles; secondary actions keep their tooltips and VoiceOver labels.
private struct CapsuleButton: View {
  let title: String
  let systemImage: String
  var displayTitle: String?
  var shortcut: KeyboardShortcut?
  var showsTitle = false
  var width: CGFloat?
  var help: String?
  let action: () -> Void
  init(_ title: String, systemImage: String, displayTitle: String? = nil, shortcut: KeyboardShortcut? = nil, showsTitle: Bool = true, width: CGFloat? = nil, help: String? = nil, action: @escaping () -> Void) {
    self.title = title; self.systemImage = systemImage; self.displayTitle = displayTitle; self.shortcut = shortcut; self.showsTitle = showsTitle; self.width = width; self.help = help; self.action = action
  }
  var body: some View {
    Button(action: action) {
      if showsTitle { Label(displayTitle ?? title, systemImage: systemImage).labelStyle(.titleAndIcon).frame(width: width) }
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
