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

  init(camera: CameraModel = .shared) {
    self.camera = camera
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
  var isEditing: Bool { draft?.isEditing == true }
  func present(store: AppStore, on screen: NSScreen? = nil, activate: Bool = true) {
    guard draft?.isEditing != true else {
      draft?.errorMessage = "Finish or cancel the open edit before presenting another script."
      if activate { panel?.makeKeyAndOrderFront(nil) } else { panel?.orderFrontRegardless() }
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
      if activate { panel.makeKey(); NSApp.activate(ignoringOtherApps: true) }
      return
    }
    let draft = PresenterDraft(record: store.session.activeRecord ?? script)
    self.draft = draft
    panel.contentView = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft))
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
    if isFullScreen { closesAfterFullScreen = true; panel?.toggleFullScreen(nil); return }
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
  @ObservedObject private var camera = CameraModel.shared
  @State private var editorNotice: String?
  /// False in Video only, unless a draft was already open: it must stay reachable to finish or cancel.
  private var showsScript: Bool { camera.displayMode != .videoOnly || draft.isEditing }
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
        GuideLine(settings: store.settings).offset(
          y: ScriptTextView.visualGuideY(height: geometry.size.height, fraction: store.settings.guideFraction))
        }
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
      .scaleEffect(store.uiZoom, anchor: .top)
    }
    .overlay(alignment: .bottom) {
      GeometryReader { geometry in
        // Laid out at the width the zoom leaves, so a narrow presenter wraps the capsule instead of overrunning it.
        WrapLayout(spacing: 8) {
          if draft.isEditing {
            Label("Editing", systemImage: "pencil")
              .font(.callout.weight(.semibold)).foregroundStyle(.orange)
              .padding(.horizontal, 6)
              .help("Editing the script in place. Finish with ⌘Return, or cancel.")
          }
          // Disabled, not hidden, while editing: the capsule keeps its shape and VoiceOver reads them as dimmed.
          Group {
            CapsuleButton("Previous passage", systemImage: "backward.end.fill", action: session.previousPassage)
            CapsuleButton(session.isActivelyRunning ? "Pause" : "Play",
                          systemImage: session.isActivelyRunning ? "pause.fill" : "play.fill", action: session.toggle)
              .buttonStyle(.borderedProminent)
            CapsuleButton("Next passage", systemImage: "forward.end.fill", action: session.nextPassage)
            CapsuleButton("Back to the start", systemImage: "arrow.counterclockwise", action: session.restart)
          }.disabled(!showsScript || draft.isEditing)
          CapsuleButton(camera.presentsWithVideo ? "Present without video" : "Present with video",
                        systemImage: camera.presentsWithVideo ? "video.fill" : "video.slash") {
            PresenterController.shared.toggleVideo()
          }
          CapsuleButton(draft.isEditing ? "Finish editing" : "Edit script",
                        systemImage: draft.isEditing ? "checkmark" : "pencil",
                        shortcut: draft.isEditing ? KeyboardShortcut(.return, modifiers: .command) : nil) {
            if draft.isEditing { Task { await draft.confirm(store: store) } } else { draft.begin(session: session) }
          }.disabled(draft.isSaving || !showsScript)
          if draft.isEditing {
            CapsuleButton("Cancel editing", systemImage: "xmark", shortcut: .cancelAction) { draft.requestCancel() }
              .disabled(draft.isSaving)
          } else {
            CapsuleButton("Close presenter", systemImage: "xmark") { PresenterController.shared.close() }
          }
        }
        .buttonStyle(.bordered).padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)).padding(10)
        .frame(maxWidth: geometry.size.width / store.uiZoom)
        .scaleEffect(store.uiZoom, anchor: .bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      }
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
    .overlay(alignment: .bottom) {
      if hasBottomNotice {
        GeometryReader { geometry in
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
          .padding(.bottom, 58).frame(maxWidth: min(560, geometry.size.width / store.uiZoom))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          .scaleEffect(store.uiZoom, anchor: .bottom)
        }
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
      alignment: NSTextAlignment(setting: settings.alignment))
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
    text.isEditable = false
    text.isSelectable = true
    text.drawsBackground = false
    text.textContainerInset = NSSize(width: horizontalMargin, height: 80)
    text.textContainer?.widthTracksTextView = true
    text.onCharacterClick = { context.coordinator.seek($0) }
    text.onLayout = { [weak scroll] in
      guard let scroll else { return }
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
        paragraphSpacing: paragraphSpacing, horizontalMargin: horizontalMargin,
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
      scrollObservers = [
        center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.isLiveScrolling = true
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
      paragraphSpacing: Double = 0.34, horizontalMargin: Double = 42, alignment: String = "Left",
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
      guard let first = values.min(), let last = values.max(),
        lastReadTokenIndex != tokenIndex || lastReadConfirmedTokenIndex != lastConfirmedTokenIndex
      else { return }
      // One edit transaction, so the text storage invalidates and redraws the changed span once
      // instead of once per word; a progress event can cover a dozen words.
      textView.textStorage?.beginEditing()
      for (range, index) in mappings where first...last ~= index {
        textView.textStorage?.addAttribute(.foregroundColor, value: readColour(index), range: range)
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
      if manualPosition != nil { pendingUserSeeks += 1 }
      (onUserScroll ?? onSeek)(nearest.1)
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
      snapToGuide()
    }
    func invalidateAlignment() {
      lastAligned = nil
      lastGuideFraction = nil
      lastAlignmentDestination = nil
    }
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
      manager.ensureLayout(for: container)
      return (manager, container, guideY)
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
      guard !isLiveScrolling, (lastAligned != tokenIndex || lastGuideFraction != guideFraction),
        let mapping = mappings.first(where: { $0.1 == tokenIndex }),
        let (manager, container, guideY) = prepareGuide(scroll, fraction: guideFraction)
      else { return }
      let target = scrollY(of: mapping.0, manager: manager, container: container, guideY: guideY)
      let animate = eases ?? (lastAligned != nil && isActivelyRunning && !snapNextAlignment && !Self.reducesMotion())
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
