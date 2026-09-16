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
    guard let panel else { return false }
    return panel.isVisible && !panel.isMiniaturized && !panel.isInFullScreen
  }

  init(camera: CameraModel = .shared) {
    self.camera = camera
    super.init()
    // The capsule button, Prompter > Present with Video and the inspector's Mode all flip this one
    // property. `dropFirst` skips the value the presenter opens with.
    videoObserver = camera.$presentsWithVideo.dropFirst().removeDuplicates().sink { [weak self] on in
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
    guard on, isWindowedOnScreen else { return }
    // The new preview selects the camera, and so learns its size, in this same update.
    DispatchQueue.main.async { self.matchCameraSize() }
  }
  /// The presenter capsule's video button.
  func toggleVideo() { camera.presentsWithVideo.toggle() }
  func toggleFullScreen() {
    guard let panel, panel.isVisible else { return }
    panel.toggleFullScreen(nil)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let draft, draft.isEditing { draft.requestClose(); return false }
    // The red button or Cmd-W in full screen: leave the Space first, then close.
    if isFullScreen { closeNow(); return false }
    activeSession?.pause()
    return true
  }
  func present(store: AppStore, on screen: NSScreen? = nil) {
    guard draft?.isEditing != true else {
      draft?.errorMessage = "Finish or cancel the open edit before presenting another script."
      panel?.makeKeyAndOrderFront(nil)
      return
    }
    guard let script = store.selected else { return }
    closesAfterFullScreen = false
    let panel = self.panel ?? makePanel()
    self.panel = panel
    // Present on the presenter already showing this script only brings it forward: a new hosting
    // view restarted the camera and threw the open edit away.
    let isShowing = panel.isVisible && store.session.activeScriptID == script.id
      && panel.contentView is NSHostingView<PresenterView>
    // For the script already presented this only passes on settings; the anchor stays.
    store.session.present(record: script, settings: store.settings)
    activeSession = store.session
    panel.title = "JuniorPrompter · \(script.metadata.title)"
    panel.settle()
    if isShowing {
      panel.orderFrontRegardless()
      panel.makeKey()
      return
    }
    let draft = PresenterDraft(record: store.session.activeRecord ?? script)
    self.draft = draft
    panel.contentView = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft))
    let targetScreen = screen ?? (CommandLine.arguments.contains("--agent-screen")
      ? (NSScreen.screens.first(where: { $0.localizedName == "Prompter XL" }) ?? NSScreen.screens.first(where: { $0.localizedName == "Agent Screen" }))
      : nil)
    if let targetScreen, !isFullScreen {
      let area = targetScreen.visibleFrame
      let size = NSSize(width: min(760, area.width), height: min(520, area.height))
      panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                            width: size.width, height: size.height), display: true)
    }
    recoverVisibleFrame(panel)
    if screen != nil || CommandLine.arguments.contains("--agent-screen") {
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
    if isFullScreen { closesAfterFullScreen = true; panel?.toggleFullScreen(nil); return }
    panel?.orderOut(nil)
    // The camera is already let go: the stage view stops holding it when `orderOut` clears the
    // window's `isVisible`. Dropping the hosting view also stops the hidden presenter observing the
    // store and session; `present` builds a fresh one every time.
    panel?.contentView = NSView()
  }

  /// Resize the presenter to the shape of the feed as it is shown — a feed turned 90° gives a
  /// vertical window — as large as the screen it is on allows.
  static func matchedCameraFrame(picture: CGSize, rotation: CameraRotation, in visibleFrame: NSRect)
    -> NSRect
  {
    rotation.fittedRect(aspect: picture, in: visibleFrame)
  }
  func matchCameraSize() {
    guard let panel, isWindowedOnScreen,
      let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    else { return }
    // Until the camera reports its size, the stage view draws 16:9 too.
    let picture = SharedCameraSession.shared.pictureSize ?? CGSize(width: 16, height: 9)
    panel.setFrame(
      Self.matchedCameraFrame(
        picture: picture, rotation: camera.guides.rotation,
        in: screen.visibleFrame), display: true)
  }
  private func makePanel() -> PresenterPanel {
    let value = PresenterPanel(captureVisible: CommandLine.arguments.contains("--capture-visible"))
    value.delegate = self
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
    var frame = panel.frame
    frame.size.width = min(frame.width, target.visibleFrame.width)
    frame.size.height = min(frame.height, target.visibleFrame.height)
    frame.origin = NSPoint(
      x: target.visibleFrame.midX - frame.width / 2, y: target.visibleFrame.midY - frame.height / 2)
    panel.setFrame(frame, display: true)
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

/// The presenter window. At rest it is `.fullScreenAuxiliary`, which is what lets it float over
/// another app's full-screen Space (OBS, verified on 7 September). It turns `.fullScreenPrimary`
/// only for a full-screen Space of its own, and every way in comes through `toggleFullScreen`:
/// Prompter > Presenter Full Screen, View > Enter Full Screen (Ctrl-Cmd-F) and the green button.
class PresenterPanel: NSPanel {
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
      isEditing = false
      closeRequested = false
      errorMessage = nil
      resumeTracking()
    } catch {
      errorMessage = "The script changed or could not be saved. Your presenter draft is still open. \(error)"
    }
  }
  func saveAsCopy(store: AppStore) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await store.savePresentedDraftAsCopy(markdown, for: recordID)
      isEditing = false
      closeRequested = false
      errorMessage = nil
      resumeTracking()
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
  @ObservedObject private var camera = CameraModel.shared
  @State private var editorNotice: String?
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
              verticalMirror: store.settings.verticalMirror != (store.settings.rotation == 180))
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
              onSeek: session.seek
            )
          }
        }
        .scaleEffect(
          x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1
        ).rotationEffect(.degrees(Double(store.settings.rotation)))
        GuideLine(settings: store.settings).offset(
          y: ScriptTextView.visualGuideY(height: geometry.size.height, fraction: store.settings.guideFraction))
      }
    }.background(Color.clear).onChange(of: store.settings) { _, value in
      session.updateSettings(value)
    }
    .onChange(of: camera.presentsWithVideo) { _, on in PresenterController.shared.videoDidChange(on) }
    .overlay(alignment: .top) {
      ZStack {
        Image(systemName: "line.3.horizontal")
          .font(.caption.weight(.semibold))
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
    }
    .overlay(alignment: .bottom) {
      HStack(spacing: 8) {
        // Disabled, not hidden, while editing: the capsule keeps its shape and VoiceOver reads them as dimmed.
        Group {
          CapsuleButton("Previous passage", systemImage: "backward.end.fill", action: session.previousPassage)
          CapsuleButton(session.isActivelyRunning ? "Pause" : "Play",
                        systemImage: session.isActivelyRunning ? "pause.fill" : "play.fill", action: session.toggle)
            .buttonStyle(.borderedProminent)
          CapsuleButton("Next passage", systemImage: "forward.end.fill", action: session.nextPassage)
          CapsuleButton("Back to the start", systemImage: "arrow.counterclockwise", action: session.restart)
        }.disabled(draft.isEditing)
        CapsuleButton(camera.presentsWithVideo ? "Present without video" : "Present with video",
                      systemImage: camera.presentsWithVideo ? "video.fill" : "video.slash") {
          PresenterController.shared.toggleVideo()
        }
        CapsuleButton(draft.isEditing ? "Finish editing" : "Edit script",
                      systemImage: draft.isEditing ? "checkmark" : "pencil",
                      shortcut: draft.isEditing ? KeyboardShortcut(.return, modifiers: .command) : nil) {
          if draft.isEditing { Task { await draft.confirm(store: store) } } else { draft.begin(session: session) }
        }.disabled(draft.isSaving)
        if draft.isEditing {
          CapsuleButton("Cancel editing", systemImage: "xmark", shortcut: .cancelAction) { draft.requestCancel() }
            .disabled(draft.isSaving)
        } else {
          CapsuleButton("Close presenter", systemImage: "xmark") { PresenterController.shared.close() }
        }
      }
      .buttonStyle(.bordered).padding(8)
      .background(.ultraThinMaterial, in: Capsule()).padding(10)
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
    .onChange(of: draft.markdown) { _, _ in editorNotice = nil }
    .onChange(of: draft.isEditing) { _, isEditing in
      if isEditing { editorNotice = nil }
    }
    .overlay(alignment: .bottom) {
      if hasBottomNotice {
      VStack(spacing: 6) {
        if draft.isEditing, draft.hasExternalChange(in: store) {
          Text("This script changed outside JuniorPrompter. Finishing will keep this draft and show a conflict instead of overwriting it.")
            .foregroundStyle(.orange)
        }
        if let error = draft.errorMessage {
          Text(error).foregroundStyle(.red)
          Button("Save as Separate Script") { Task { await draft.saveAsCopy(store: store) } }
            .disabled(draft.isSaving)
        }
        if let notice = editorNotice ?? session.anchorNotice ?? draft.noticeMessage {
          Text(notice)
        }
      }
      .font(.caption).multilineTextAlignment(.center)
      .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .padding(.bottom, 58).frame(maxWidth: 560)
      }
    }
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
      alignment: settings.alignment == "Right" ? .right : settings.alignment == "Center" ? .center : .left)
  }
}

/// An icon-only capsule button: the title is its tooltip and its VoiceOver label.
private struct CapsuleButton: View {
  let title: String
  let systemImage: String
  var shortcut: KeyboardShortcut?
  let action: () -> Void
  init(_ title: String, systemImage: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
    self.title = title; self.systemImage = systemImage; self.shortcut = shortcut; self.action = action
  }
  var body: some View {
    Button(action: action) { Label(title, systemImage: systemImage) }
      .labelStyle(.iconOnly)
      .keyboardShortcut(shortcut)
      .help(title)
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
  let lastConfirmedTokenIndex: Int?
  let isActivelyRunning: Bool
  let seekRevision: Int
  let guideFraction: Double
  let verticalMirror: Bool
  let fontName: String
  let fontSize: Double
  let textOpacity: Double
  let fontWeight: String
  let textColorHex: String
  let lineSpacing: Double
  let paragraphSpacing: Double
  let horizontalMargin: Double
  let alignment: String
  let showCues: Bool
  let highlightActiveWord: Bool
  let onSeek: (Int) -> Void
  init(document: PrompterDocument, tokenIndex: Int, lastConfirmedTokenIndex: Int? = nil, isActivelyRunning: Bool = false, seekRevision: Int = 0, guideFraction: Double, verticalMirror: Bool = false, fontName: String, fontSize: Double, textOpacity: Double, fontWeight: String = "Regular", textColorHex: String = "#FFFFFF", lineSpacing: Double = 0.16, paragraphSpacing: Double = 0.34, horizontalMargin: Double = 42, alignment: String = "Left", showCues: Bool = true, highlightActiveWord: Bool = false, onSeek: @escaping (Int) -> Void) {
    self.document = document; self.tokenIndex = tokenIndex; self.lastConfirmedTokenIndex = lastConfirmedTokenIndex; self.isActivelyRunning = isActivelyRunning; self.seekRevision = seekRevision; self.guideFraction = guideFraction; self.verticalMirror = verticalMirror; self.fontName = fontName; self.fontSize = fontSize; self.textOpacity = textOpacity; self.fontWeight = fontWeight; self.textColorHex = textColorHex; self.lineSpacing = lineSpacing; self.paragraphSpacing = paragraphSpacing; self.horizontalMargin = horizontalMargin; self.alignment = alignment; self.showCues = showCues; self.highlightActiveWord = highlightActiveWord; self.onSeek = onSeek
  }
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
  }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let text = TrackingTextView()
    text.isEditable = false
    text.isSelectable = true
    text.drawsBackground = false
    text.textContainerInset = NSSize(width: horizontalMargin, height: 80)
    text.textContainer?.widthTracksTextView = true
    text.onCharacterClick = { context.coordinator.seek($0) }
        text.onLayout = { [weak scroll] in
          guard let scroll else { return }
          context.coordinator.invalidateAlignment()
          context.coordinator.align(
            scroll: scroll, tokenIndex: context.coordinator.tokenIndex,
            guideFraction: context.coordinator.guideFraction)
        }
    scroll.documentView = text
    context.coordinator.textView = text
    context.coordinator.verticalMirror = verticalMirror
    context.coordinator.observeUserScrolls(in: scroll)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.setSideInset(horizontalMargin)
    context.coordinator.onSeek = onSeek
    context.coordinator.tokenIndex = tokenIndex
    context.coordinator.lastConfirmedTokenIndex = lastConfirmedTokenIndex
    context.coordinator.guideFraction = guideFraction
    if context.coordinator.verticalMirror != verticalMirror {
      context.coordinator.verticalMirror = verticalMirror
      context.coordinator.invalidateAlignment()
      context.coordinator.snapNextAlignment = true
    }
    if context.coordinator.seekRevision != seekRevision {
      context.coordinator.seekRevision = seekRevision
      context.coordinator.invalidateAlignment()
      context.coordinator.snapNextAlignment = true
    }
    context.coordinator.isActivelyRunning = isActivelyRunning
    let signature = "\(document.hashValue)|\(fontName)|\(fontSize)|\(textOpacity)|\(fontWeight)|\(textColorHex)|\(lineSpacing)|\(paragraphSpacing)|\(alignment)|\(showCues)|\(highlightActiveWord)"
    if context.coordinator.signature != signature {
      context.coordinator.signature = signature
      context.coordinator.render(
        document: document, fontName: fontName, fontSize: fontSize, textOpacity: textOpacity,
        fontWeight: fontWeight, textColorHex: textColorHex, lineSpacing: lineSpacing,
        paragraphSpacing: paragraphSpacing, horizontalMargin: horizontalMargin,
        alignment: alignment, showCues: showCues, highlightActiveWord: highlightActiveWord)
    }
    context.coordinator.updateGeneration &+= 1
    let generation = context.coordinator.updateGeneration
    DispatchQueue.main.async {
      guard context.coordinator.updateGeneration == generation else { return }
      context.coordinator.updateReadState()
      context.coordinator.align(
        scroll: scroll, tokenIndex: tokenIndex, guideFraction: guideFraction)
    }
  }
  @MainActor final class Coordinator {
    weak var textView: NSTextView?
    var onSeek: (Int) -> Void
    var mappings: [(NSRange, Int)] = []
    var signature = ""
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
    var seekRevision = 0
    var isActivelyRunning = false
    var snapNextAlignment = false
    private var scrollObservers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    init(onSeek: @escaping (Int) -> Void) { self.onSeek = onSeek }
    func stopObservingUserScrolls() {
      scrollObservers.forEach(NotificationCenter.default.removeObserver)
      scrollObservers.removeAll()
    }
    func observeUserScrolls(in scroll: NSScrollView) {
      stopObservingUserScrolls()
      let center = NotificationCenter.default
      scrollObservers = [
        center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.isLiveScrolling = true }
        },
        center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
          guard let self, let scroll else { return }
          MainActor.assumeIsolated { self.userDidScroll(scroll) }
        },
        center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.isLiveScrolling = false }
        },
      ]
    }
    func render(document: PrompterDocument, fontName: String, fontSize: Double, textOpacity: Double,
      fontWeight: String = "Regular", textColorHex: String = "#FFFFFF", lineSpacing: Double = 0.16,
      paragraphSpacing: Double = 0.34, horizontalMargin: Double = 42, alignment: String = "Left",
      showCues: Bool = true, highlightActiveWord: Bool = false)
    {
      guard let textView else { return }
      self.textOpacity = textOpacity
      self.highlightActiveWord = highlightActiveWord
      self.textColour = NSColor(hex: textColorHex) ?? .white
      let attributed = NSMutableAttributedString()
      let textColour = NSColor(hex: textColorHex) ?? .white
      var headingRanges: [NSRange] = []
      for (index, block) in document.blocks.enumerated() {
        let rendered: AttributedString
        if block.kind == .listItem {
          var lines = AttributedString()
          for (lineIndex, line) in block.rawMarkdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if lineIndex > 0 { lines.append(AttributedString("\n")) }
            lines.append((try? AttributedString(markdown: String(line), options: .init(interpretedSyntax: .full))) ?? AttributedString(String(line)))
          }
          rendered = lines
        } else {
          rendered = (try? AttributedString(
            markdown: block.rawMarkdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(block.rawMarkdown)
        }
        let part = NSMutableAttributedString(attributedString: NSAttributedString(rendered))
        part.addAttribute(.foregroundColor, value: textColour.withAlphaComponent(textOpacity), range: NSRange(location: 0, length: part.length))
        if block.kind == .heading {
          headingRanges.append(NSRange(location: attributed.length, length: part.length))
        }
        attributed.append(part)
        if index < document.blocks.count - 1 { attributed.append(NSAttributedString(string: "\n\n")) }
      }
      let full = NSRange(location: 0, length: attributed.length)
      // Presenter clicks seek within the script, including linked words.
      attributed.removeAttribute(.link, range: full)
      let base = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
      attributed.enumerateAttribute(.font, in: full) { value, range, _ in
        let existing = value as? NSFont
        let ratio = existing.map { max(0.8, min(1.6, $0.pointSize / 13)) } ?? 1
        let traits = existing.map { NSFontManager.shared.traits(of: $0) }
          ?? NSFontTraitMask()
        let family = existing.flatMap { $0.fontName.lowercased().contains("mono") ? $0.fontName : nil }
        let styledBase = family.flatMap { NSFont(name: $0, size: fontSize * ratio) } ?? base
        let requested = fontWeight == "Bold" ? traits.union(.boldFontMask) : traits
        let styled = NSFontManager.shared.convert(styledBase, toHaveTrait: requested)
        attributed.addAttribute(.font, value: styled, range: range)
      }
      for range in headingRanges {
        guard let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        else { continue }
        let heading = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        attributed.addAttribute(.font, value: NSFontManager.shared.convert(heading, toSize: fontSize * 1.35), range: range)
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = max(3, fontSize * lineSpacing)
      paragraph.paragraphSpacing = max(10, fontSize * paragraphSpacing)
      paragraph.alignment = alignment == "Right" ? .right : alignment == "Center" ? .center : .left
      attributed.addAttribute(.paragraphStyle, value: paragraph, range: full)
      mappings = []
      let plain = attributed.string as NSString
      let cueRanges = cueRanges(in: plain, document: document)
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
      textView.textStorage?.setAttributedString(attributed)
      lastReadTokenIndex = nil
      lastReadConfirmedTokenIndex = nil
      var cursor = 0
      for (index, token) in document.spokenTokens.enumerated() {
        var found = NSRange(location: NSNotFound, length: 0)
        while cursor < plain.length {
          let search = NSRange(location: cursor, length: plain.length - cursor)
          let candidate = plain.range(of: token.text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
          guard candidate.location != NSNotFound else { break }
          if cueRanges.contains(where: { NSIntersectionRange($0, candidate).length > 0 }) {
            cursor = candidate.location + candidate.length
          } else {
            found = candidate
            break
          }
        }
        if found.location != NSNotFound {
          let range = punctuationRange(after: found, in: plain)
          mappings.append((range, index))
          cursor = range.location + range.length
        }
      }
      textView.needsLayout = true
      lastAligned = nil
      lastGuideFraction = nil
      lastAlignmentDestination = nil
    }
    func updateReadState() {
      guard let textView else { return }
      let values = [lastReadTokenIndex, tokenIndex, lastReadConfirmedTokenIndex, lastConfirmedTokenIndex]
        .compactMap { $0 }
      guard let first = values.min(), let last = values.max(),
        lastReadTokenIndex != tokenIndex || lastReadConfirmedTokenIndex != lastConfirmedTokenIndex
      else { return }
      // One edit transaction, so the text storage invalidates and redraws the changed span once
      // instead of once per word; a progress event can cover a dozen words.
      textView.textStorage?.beginEditing()
      for (range, index) in mappings where first...last ~= index {
        let confirmed = lastConfirmedTokenIndex.map { index <= $0 } ?? false
        let alpha = confirmed ? textOpacity * 0.38 : textOpacity
        let color: NSColor = index == tokenIndex && !confirmed && highlightActiveWord ? .systemYellow.withAlphaComponent(alpha) : textColour.withAlphaComponent(alpha)
        textView.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
      }
      textView.textStorage?.endEditing()
      lastReadTokenIndex = tokenIndex
      lastReadConfirmedTokenIndex = lastConfirmedTokenIndex
    }
    func seek(_ character: Int) {
      guard
        let nearest = mappings.min(by: { distance(character, $0.0) < distance(character, $1.0) })
      else { return }
      onSeek(nearest.1)
    }
    func userDidScroll(_ scroll: NSScrollView) {
      guard isLiveScrolling, let textView,
        let manager = textView.layoutManager, let container = textView.textContainer
      else { return }
      manager.ensureLayout(for: container)
      let guide = scroll.contentView.bounds.origin.y
        + layoutGuideY(height: scroll.contentView.bounds.height, fraction: guideFraction) - textView.textContainerInset.height
      guard let nearest = mappings.min(by: { left, right in
        let leftGlyph = manager.glyphRange(forCharacterRange: left.0, actualCharacterRange: nil)
        let rightGlyph = manager.glyphRange(forCharacterRange: right.0, actualCharacterRange: nil)
        return abs(manager.boundingRect(forGlyphRange: leftGlyph, in: container).midY - guide)
          < abs(manager.boundingRect(forGlyphRange: rightGlyph, in: container).midY - guide)
      }) else { return }
      tokenIndex = nearest.1
      lastConfirmedTokenIndex = nil
      onSeek(nearest.1)
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
      invalidateAlignment()
      snapNextAlignment = true
    }
    func invalidateAlignment() {
      lastAligned = nil
      lastGuideFraction = nil
      lastAlignmentDestination = nil
    }
    func align(scroll: NSScrollView, tokenIndex: Int, guideFraction: Double) {
      guard (lastAligned != tokenIndex || lastGuideFraction != guideFraction), let textView,
        let mapping = mappings.first(where: { $0.1 == tokenIndex }),
        let manager = textView.layoutManager, let container = textView.textContainer
      else { return }
      let height = scroll.contentView.bounds.height
      let guideY = layoutGuideY(height: height, fraction: guideFraction)
      let edgeInset = max(80, max(guideY, height - guideY))
      // Same reason: re-laying the whole script out on every advance is the presenter's most
      // expensive recurring work, and the edge inset only changes when the window resizes.
      if abs(textView.textContainerInset.height - edgeInset) > 0.5 {
        textView.textContainerInset = NSSize(width: textView.textContainerInset.width, height: edgeInset)
      }
      manager.ensureLayout(for: container)
      let glyph = manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
      let target = max(
        0,
        rect.midY + textView.textContainerInset.height - guideY)
      let animate = lastAligned != nil && isActivelyRunning && !snapNextAlignment
        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      let destination = NSPoint(x: scroll.contentView.bounds.origin.x, y: target)
      let isSameDestination = lastAlignmentDestination.map {
        abs($0.x - destination.x) <= 0.5 && abs($0.y - destination.y) <= 0.5
      } ?? false
      if animate && !isSameDestination {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.60
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          scroll.contentView.animator().setBoundsOrigin(destination)
        }
      } else if !animate {
        scroll.contentView.layer?.removeAllAnimations()
        scroll.contentView.setBoundsOrigin(destination)
      }
      if !animate || !isSameDestination { scroll.reflectScrolledClipView(scroll.contentView) }
      lastAligned = tokenIndex
      lastGuideFraction = guideFraction
      lastAlignmentDestination = destination
      snapNextAlignment = false
    }
    private func cueRanges(in plain: NSString, document: PrompterDocument) -> [NSRange] {
      var result: [NSRange] = []
      var cursor = 0
      for cue in document.blocks.flatMap(\.stageDirections) {
        guard cursor <= plain.length else { break }
        let search = NSRange(location: cursor, length: plain.length - cursor)
        let bracketed = "[\(cue.text)]"
        let match = plain.range(of: bracketed, options: [.caseInsensitive, .diacriticInsensitive], range: search)
        let range = match.location == NSNotFound
          ? plain.range(of: cue.text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
          : match
        if range.location != NSNotFound { result.append(range); cursor = range.location + range.length }
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
      point < range.location
        ? range.location - point
        : point > range.location + range.length ? point - (range.location + range.length) : 0
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
        setSelectedRange(NSRange(location: 0, length: 0))
        onCharacterClick?(character)
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

private extension NSColor {
  convenience init?(hex: String) {
    var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
    self.init(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
  }
}
