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
  private(set) var draft: PresenterDraft?
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
  func windowDidMove(_ notification: Notification) {
    if let panel = notification.object as? PresenterPanel, let screen = panel.screen { panel.updateMinimum(for: screen.visibleFrame) }
    rememberFrame(notification)
  }
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
  var hasSelectedText: Bool { ReferenceMonitor.focusedSelection() != nil }

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

  /// Cancels termination until the draft has been saved or explicitly discarded.
  func prepareToQuit(then quit: @escaping () -> Void) -> Bool {
    guard let draft, draft.isEditing, draft.hasEdits || draft.isSaving else { return true }
    draft.requestClose(then: quit)
    panel?.makeKeyAndOrderFront(nil)
    return false
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
    panel.title = "Camera view"
    panel.settle()
    let draft = PresenterDraft()
    self.draft = draft
    let hosting = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, hasScript: false, camera: camera, recorder: recorder))
    hosting.sizingOptions = []
    panel.contentView = hosting
    recoverVisibleFrame(panel)
    panel.makeKeyAndOrderFront(nil)
    NSApp.activateUnlessAgentScreen()
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
      self.moveReading { session in
        switch direction {
        case 49: session.toggle()
        case 115: session.restart()
        case 123, 116: session.previousPassage()
        default:
          if session.isActivelyRunning { session.nextPassage() } else { session.startReading() }
        }
      }
      return true
    }
    panel.title = script.metadata.title
    panel.settle()
    if isShowing {
      panel.orderFrontRegardless()
      if activate && !AgentMode.isOn { panel.makeKey(); NSApp.activateUnlessAgentScreen() }
      return
    }
    let draft = PresenterDraft(record: store.session.activeRecord ?? script)
    self.draft = draft
    let hosting = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, hasScript: true, camera: camera, recorder: recorder))
    hosting.sizingOptions = []
    panel.contentView = hosting
    panel.makeFirstResponder(panel)
    let targetScreen = screen ?? (AgentMode.isOn ? NSScreen.agentScreen : nil)
    if let area = targetScreen?.visibleFrame, !isFullScreen {
      panel.setFrame(area.centred(NSSize(width: min(760, area.width), height: min(520, area.height))), display: true)
    }
    recoverVisibleFrame(panel)
    if !activate {
      panel.orderFrontRegardless()
    } else if screen != nil || AgentMode.isOn {
      panel.orderFrontRegardless()
      panel.makeKey()
    } else {
      panel.makeKeyAndOrderFront(nil)
      NSApp.activateUnlessAgentScreen()
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
      window.title = "Camera Recording"; window.level = .floating
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
      MainActor.assumeIsolated {
        if let panel = self?.panel {
          if let screen = panel.screen { panel.updateMinimum(for: screen.visibleFrame) }
          self?.recoverVisibleFrame(panel)
        }
      }
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
    guard NSClassFromString("XCTestCase") == nil, !AgentMode.isOn else { return nil }
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
    guard [offset.origin.x, offset.origin.y, offset.width, offset.height].allSatisfy({ $0.isFinite }),
      offset.width >= 100, offset.height >= 100 else { return nil }
    return clamp(offset.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), into: screen.visibleFrame)
  }

  static func minimumSize(in area: NSRect) -> NSSize {
    NSSize(width: min(area.width, 720), height: min(area.height, 520))
  }

  static func clamp(_ frame: NSRect, into area: NSRect) -> NSRect {
    let minimum = minimumSize(in: area)
    let size = NSSize(width: min(area.width, max(minimum.width, frame.width)), height: min(area.height, max(minimum.height, frame.height)))
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
    if let screen = NSScreen.screens.max(by: { $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area }) {
      updateMinimum(for: screen.visibleFrame)
    }
    frame.size.width = max(minSize.width, frame.width)
    frame.size.height = max(minSize.height, frame.height)
    super.setFrame(frame, display: flag)
  }
  func updateMinimum(for area: NSRect) { minSize = PresenterFrameMemory.minimumSize(in: area) }
  var onPassageKey: ((UInt16) -> Bool)?
  /// The key presenter owns reading commands unless a text field or script is being edited.
  func handlePassageKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, [123, 124, 116, 121, 115, 49].contains(event.keyCode),
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      event.windowNumber == windowNumber
    else { return false }
    if event.keyCode == 49, firstResponder !== self, !(firstResponder is TrackingTextView) { return false }
    if let text = firstResponder as? NSTextView, text.isEditable { return false }
    if let field = firstResponder as? NSTextField, field.isEditable { return false }
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
    minSize = PresenterFrameMemory.minimumSize(in: (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 720, height: 520))
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
  private var closeAction: (() -> Void)?
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
    guard !isSaving, let record = session.activeRecord else { return }
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
    guard !isSaving else { return }
    finishEditing(resuming: resuming)
  }
  private func finishEditing(resuming: Bool = true) {
    isEditing = false
    closeRequested = false
    closeAction = nil
    errorMessage = nil
    if resuming { resumeTracking() } else { resumeAfterEdit = false }
  }
  /// Editing pauses recognition; finishing it carries on from the remapped anchor.
  private func resumeTracking() {
    guard resumeAfterEdit else { return }
    resumeAfterEdit = false
    session?.play()
  }
  func requestClose(then action: @escaping () -> Void = { PresenterController.shared.closeNow() }) {
    guard !isSaving else {
      errorMessage = "Wait for the save to finish before closing the presenter."
      return
    }
    discardCloses = true
    closeAction = action
    closeRequested = true
  }
  /// Escape used to throw typed edits away without asking. Typing goes through the same
  /// confirmation the close button uses; an untouched draft still cancels straight away.
  func requestCancel() {
    guard !isSaving else { return }
    guard hasEdits else { cancel(); return }
    discardCloses = false
    closeAction = nil
    closeRequested = true
  }
  func keepEditing() {
    closeRequested = false
    closeAction = nil
  }
  func discardAndClose() {
    guard !isSaving else { return }
    let action = closeAction
    cancel(resuming: !discardCloses)
    action?()
  }
  func saveAndClose(store: AppStore) async {
    let action = closeAction
    await confirm(store: store, resuming: !discardCloses)
    // A failed save or typing added during the save must keep the app open.
    if !isEditing { action?() }
  }
  func confirm(store: AppStore, resuming: Bool = true) async {
    guard !isSaving else { return }
    let submitted = markdown
    isSaving = true
    defer { isSaving = false }
    do {
      try await store.savePresentedMarkdown(
        submitted, for: recordID, expectedFingerprint: expectedFingerprint,
        expectedRevision: expectedRevision)
      if let saved = store.scripts.first(where: { $0.id == recordID }) {
        expectedFingerprint = saved.metadata.contentFingerprint
        expectedRevision = saved.metadata.revision
      }
      originalMarkdown = submitted
      if markdown == submitted { finishEditing(resuming: resuming) }
      let title = store.scripts.first(where: { $0.id == recordID })?.metadata.title ?? "script"
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: "Changes saved to \(title)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    } catch {
      errorMessage = "The script changed or could not be saved. Your presenter draft is still open. \(error)"
    }
  }
  func saveAsCopy(store: AppStore) async {
    guard !isSaving else { return }
    let submitted = markdown
    isSaving = true
    defer { isSaving = false }
    do {
      try await store.savePresentedDraftAsCopy(submitted, for: recordID)
      if markdown == submitted { finishEditing() }
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
