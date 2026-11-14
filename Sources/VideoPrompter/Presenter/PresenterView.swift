import AppKit
import SwiftUI
import PrompterCore

struct PresenterView: View {
  @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.offscreenRendering) private var offscreenRendering
  @Environment(\.presenterReduceTransparency) private var transparencyOverride
  private var reduceTransparency: Bool { transparencyOverride ?? (systemReduceTransparency || offscreenRendering) }
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
  private let referencePicture: NSImage?
  private let revealsCleanExit: Bool
  private let sourceInfoOverride: CameraSourceInfo?
  private let microphoneNameOverride: String?
  /// Fixtures: the inputs the Adjust mic card lists, so its selected input can be the one the side meter names.
  private let microphonesOverride: [AudioInputDevice]?
  private var sourceInfo: CameraSourceInfo? { sourceInfoOverride ?? camera.sourceInfo }

  init(store: AppStore, session: SessionStore, draft: PresenterDraft, hasScript: Bool = true,
       camera: CameraModel = .shared, monitor: ReferenceMonitor = .shared, startsCamera: Bool = true, recorder: CameraRecorder = .shared, shell: PresenterShell? = nil, referencePicture: NSImage? = nil, revealsCleanExit: Bool = false, sourceInfoOverride: CameraSourceInfo? = nil, microphoneNameOverride: String? = nil, microphonesOverride: [AudioInputDevice]? = nil) {
    self.store = store
    self.session = session
    self.draft = draft
    self.hasScript = hasScript
    self.camera = camera
    self.monitor = monitor
    self.startsCamera = startsCamera
    self.referencePicture = startsCamera ? nil : referencePicture
    self.revealsCleanExit = revealsCleanExit
    self.sourceInfoOverride = sourceInfoOverride
    self.microphoneNameOverride = microphoneNameOverride
    self.microphonesOverride = microphonesOverride
    self.recorder = recorder
    // Read now, so the meter's caption never flashes "unavailable" before the devices load.
    _microphones = State(initialValue: startsCamera ? AudioCapture.inputDevices() : [])
    _defaultMicrophoneName = State(initialValue: startsCamera ? AudioCapture.resolvedInput(nil)?.name : nil)
    _shell = StateObject(wrappedValue: shell ?? PresenterShell(reading: session.isActivelyRunning))
    _presentation = StateObject(wrappedValue: PresenterSessionState(session: session))
  }
  @State private var editorNotice: String?
  @State private var cameraSection = "Camera"
  @State private var quietTask: Task<Void, Never>?
  @State private var showsSettings = false
  @State private var showsReadingNotice = false
  @State private var cleanControlsRevealed = false
  @StateObject private var shell: PresenterShell
  private var showsChrome: Bool { !camera.cleanView }
  @AppStorage("presenterExposureKey") private var exposureKeyEnabled = true
  @State private var adjustOpener = "Adjust"
  // A new key enables the meter once for existing installs, then remembers their choice.
  @AppStorage("presenterMicLevel251") private var showsMicLevel = true
  @State private var microphones: [AudioInputDevice] = []
  @State private var defaultMicrophoneName: String?
  @State private var micListening = true
  @State private var settingsTab = SettingsTab.reading
  @FocusState private var cleanExitFocused: Bool
  static func backdropOpacity(saved: Double, reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : saved }
  // Interface size applies to the entire shell, with named controls wrapping as needed.
  static func controlZoom(_ zoom: Double) -> Double { zoom }
  /// A window of 4K size gets proportionally larger chrome, so it reads like a laptop one: 1 up to
  /// 1920 points wide (before the interface zoom), then growing with the window, to 2.4 at 4K (a little more than in proportion, so it reads next to the picture).
  static func sizeBoost(width: CGFloat) -> Double { min(2.4, max(1, 1 + 1.4 * (Double(width) / 1920 - 1))) }
  private var controlZoom: Double {
    Self.controlZoom(store.uiZoom) * Self.sizeBoost(width: viewport.width / Self.controlZoom(store.uiZoom))
  }
  /// The mic strip grows with the interface size only up to 150%, so at 200% the text keeps the room.
  static func meterZoom(controlZoom: Double, uiZoom: Double) -> Double { controlZoom * min(1, 1.5 / max(1, uiZoom)) }
  private var meterZoom: Double { Self.meterZoom(controlZoom: controlZoom, uiZoom: store.uiZoom) }
  /// What the strip's zoom holds back, given back to its type: at 200% the strip is capped at 150% but its
  /// numbers and zone words are the size of the rest of the interface.
  static func meterTypeScale(controlZoom: Double, uiZoom: Double) -> CGFloat {
    CGFloat(controlZoom / meterZoom(controlZoom: controlZoom, uiZoom: uiZoom))
  }
  private var meterTypeScale: CGFloat { Self.meterTypeScale(controlZoom: controlZoom, uiZoom: store.uiZoom) }
  /// The width of the slim microphone strip at the right edge, before zoom: dB numbers, bar and zone words.
  static let meterWidth: CGFloat = 120
  /// One width for the side cards (exposure key, camera), with their padding, so they line up. It is a
  /// share of the window (12%, between 188 and 300 points before zoom), so the column stays in
  /// proportion from a laptop to a 4K screen instead of leaving a wide empty strip.
  static func cardColumnWidth(width: CGFloat, zoom: Double) -> CGFloat {
    min(300, max(188, width / zoom * 0.12)) * zoom + Space.md * 2
  }
  /// A two-row bar at a large interface size (150% and up) uses a 36 pt control (54 pt or more on screen) and a tight row gap, so it
  /// stays a small share of the window at 200%. At 100% it keeps the 44 pt target.
  static func compactControlHeight(zoom: Double) -> CGFloat { zoom >= 1.5 ? 36 : PresenterBar.height } // grid: ok
  static let compactRowGap: CGFloat = 6 // grid: ok
  /// The text runs down to the bar and fades out over `ScriptTextView.fadeHeight` (a line and a half),
  /// so no extra room is kept under it and upcoming words stay in view at every interface size.
  static let readingBottomInset: CGFloat = 0
  /// A short window raises the reading line, never lowers it: under the line there is room for about five and a half
  /// lines of the script before the bottom fade, so the next words are not lost in it. The saved position (and the
  /// reading anchor, which uses that) is untouched; only where the line is drawn moves.
  static func readingGuideFraction(saved: Double, height: CGFloat, fontSize: Double) -> Double {
    let needed = ScriptTextView.fadeHeight(fontSize: fontSize) + PresenterReadingLine.bandHeight(fontSize: fontSize) / 2 + 5.5 * fontSize * 1.45
    return min(saved, max(0.2, Double((height - needed) / max(1, height))))
  }
  /// The strip stays reserved while editing, so the editor wraps its lines exactly as reading does.
  private var meterReserved: Bool { (camera.cleanView ? camera.keepCleanMicMeter : showsMicLevel) && (shell.adjustTab == nil || viewport.width >= 1200) }
  @State private var viewport = CGSize(width: 1600, height: 1000)
  @AppStorage("presenterExposureKeyExpanded") private var keyExpanded = true
  @ObservedObject private var recorder: CameraRecorder
  /// The script is on screen: reading, editing, the setup preview, or the camera being off.
  private var showsScript: Bool { hasScript && (camera.cleanView ? camera.cleanLook.showsScript : (draft.isEditing || shell.scriptPreview)) }
  /// Clean full screen while reading: only the text, the meter and the reading line.
  private var focusActive: Bool { camera.cleanView && camera.cleanLook == .scriptOnly }
  private var stage: some View { readingStage }
  private var inputName: String {
    microphoneNameOverride ?? (Features.recording && recorder.usesSeparateMicrophone
      ? recorder.microphoneName
      : MicMeterView.inputName(uid: store.settings.audioDeviceUID, devices: microphones, systemDefault: defaultMicrophoneName))
  }
  private func refreshMicrophones() {
    microphones = AudioCapture.inputDevices()
    defaultMicrophoneName = AudioCapture.resolvedInput(nil)?.name
  }
  private var readingStage: some View {
    GeometryReader { geometry in
      let editing = draft.isEditing
      // The key explains the picture's zebras or false colour, so it needs a picture.
      let keyVisible = exposureKeyEnabled && camera.presentsWithVideo && hasPicture && !camera.cleanView && camera.exposureIsConfigured && !camera.exposureBypassed && !editing && !focusActive
      let stripWidth = MicMeterView.stripWidth(typeScale: meterTypeScale)
      let meterWidth = meterReserved ? stripWidth * meterZoom : 0
      let setup = !editing && !camera.cleanView && camera.presentsWithVideo
      let pictureSize = referencePicture?.size ?? camera.pictureSize ?? CGSize(width: 16, height: 9)
      let pictureAspect = referencePicture != nil ? pictureSize.width / max(1, pictureSize.height) :
        (camera.guides.rotation.swapsAxes ? pictureSize.height / max(1, pictureSize.width) : pictureSize.width / max(1, pictureSize.height))
      // Setup keeps equal sides so the picture stays centred: the card column on the left, the meter (plus any rest) on the right.
      let fixedColumn = setup && (keyVisible || sourceInfo != nil) ? Self.cardColumnWidth(width: geometry.size.width, zoom: controlZoom) : 0
      let cardColumn = setup ? max(meterWidth, min(fixedColumn, pictureAspect > 1 ? geometry.size.width * 0.25 : fixedColumn)) : 0
      // The script sits in the picture region: the stage less the setup sides, or less the meter while reading.
      let regionWidth = max(1, setup ? geometry.size.width - 2 * cardColumn : geometry.size.width - meterWidth)
      let measure = ScriptTextView.measureCappedFraction(width: regionWidth, textWidth: store.settings.textWidth, fontSize: store.settings.fontSize)
      let columnInset = ScriptTextView.sideInset(width: regionWidth, textWidth: measure)
      let scriptTopInset: CGFloat = 0
      let bottomInset = Self.readingBottomInset
      let scriptHeight = max(1, geometry.size.height - scriptTopInset - bottomInset)
      let guideFraction = Self.readingGuideFraction(saved: store.settings.guideFraction, height: scriptHeight, fontSize: store.settings.fontSize)
      HStack(alignment: .top, spacing: 0) {
        if cardColumn > 0 {
          ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: Space.md) {
            if keyVisible {
          PresenterExposureKey(guides: camera.guides, expanded: $keyExpanded, zoom: controlZoom)
            .accessibilityIdentifier("presenter-exposure-legend")
            }
            sourceStatus.fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("presenter-source-status")
          }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)
          }.frame(width: cardColumn, height: geometry.size.height, alignment: .topLeading)
        }
        ZStack(alignment: .top) {
          if camera.presentsWithVideo || camera.cleanView {
            Group {
              if let referencePicture { Image(nsImage: referencePicture).resizable().scaledToFit() }
              else { CameraPreview(model: camera, presenter: true, hidesExposureAids: false) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              // Focus keeps the picture running (a take may be on) but out of sight: no zebras, false colour or guides behind the words.
              .opacity(focusActive ? 0 : 1)
              .task { if startsCamera { camera.start() } }
          }
          if showsScript {
            Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black)
              .opacity(editing ? 1 : Self.backdropOpacity(saved: store.settings.backdropOpacity(withVideo: camera.presentsWithVideo), reduceTransparency: reduceTransparency))
            if editing {
              // Save and Cancel stay upright; only the text itself follows the mirror and rotation settings.
              PresenterEditingSurface(session: session, draft: draft, settings: store.settings, width: regionWidth, centreShift: meterWidth / 2, zoom: controlZoom,
                isSaving: draft.isSaving, save: { Task { await draft.confirm(store: store) } }, cancel: { draft.requestCancel() }) {
                editorNotice = "That change could not be applied safely. Your text is unchanged. Try a smaller selection."
              }
            } else {
              PresenterScriptView(session: session, settings: store.settings,
                guideFraction: guideFraction,
                sideInset: columnInset,
                overVideo: camera.presentsWithVideo,
                topInset: scriptTopInset, bottomInset: bottomInset)
                .clipped()
            }
          }
          if referencePicture == nil && camera.presentsWithVideo && camera.needsRecovery && !showsScript && !camera.cleanView {
            // Give the zoom wrapper an explicit picture-sized frame to centre within.
            CameraRecoveryView(model: camera, prominent: true) { adjustOpener = "Camera"; shell.adjustTab = .camera }
              .frame(width: regionWidth / controlZoom, height: geometry.size.height / controlZoom)
              .uiZoom(controlZoom)
          }
          if !hasScript, camera.displayMode != .videoOnly, !camera.cleanView {
            Text("No script yet. Choose one in the library, then open the prompter.")
              .font(.title3).multilineTextAlignment(.center).padding(Space.lg)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          if hasScript, !camera.presentsWithVideo, !showsScript, !camera.cleanView {
            VStack(spacing: Space.sm) {
              Text("Camera and script are off").font(.system(size: 22, weight: .semibold))
              Text("Turn the camera or the script back on.").font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
            }.multilineTextAlignment(.center).padding(Space.lg).frame(maxWidth: .infinity, maxHeight: .infinity)
              .uiZoom(controlZoom)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-picture-region")
        if setup { Color.clear.frame(width: max(0, cardColumn - meterWidth)) }
        if micLevelVisible {
          MicMeterView(meter: recorder.inputMeter, micName: inputName, isListening: micListening, typeScale: meterTypeScale, showsClipBadge: shell.adjustTab != .mic)
            .frame(width: stripWidth, height: max(0, geometry.size.height / meterZoom - 32)).uiZoom(meterZoom)
            .frame(width: meterWidth).padding(.vertical, Space.md)
        } else if meterWidth > 0 {
          // Editing keeps the strip, so the text wraps as in reading; it takes the editor's backdrop.
          Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black).frame(width: meterWidth)
        }
      }.foregroundStyle(.white)
        .scaleEffect(x: !editing && store.settings.horizontalMirror ? -1 : 1, y: !editing && store.settings.verticalMirror ? -1 : 1)
        .rotationEffect(.degrees(editing ? 0 : Double(store.settings.rotation)))
        .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-visible-stage")
    }.background(Color.black) // One colour under the picture, the side columns and the meter: no grey strip beside a black picture.

  }

  static func usesAdjustSheet(width: CGFloat, zoom: Double) -> Bool { width < 470 * zoom + 400 }
  private var adjustIsSheet: Bool { Self.usesAdjustSheet(width: viewport.width, zoom: controlZoom) }
  private func adjustPanel(width: CGFloat) -> some View {
    AdjustPanel(selection: Binding(get: { shell.adjustTab ?? .camera }, set: { shell.adjustTab = $0 }),
      showsMic: $showsMicLevel, camera: camera, store: store, startsMeter: startsCamera,
      zoom: controlZoom, width: width, close: { shell.adjustTab = nil }, microphonesOverride: microphonesOverride, recorder: recorder)
      .popoverEntryFocus()
      .onExitCommand { shell.adjustTab = nil }
  }

  /// One card for the camera in use, in the same dark card as the exposure key above it.
  @ViewBuilder private var sourceStatus: some View {
    if sourceInfo != nil {
    Button { adjustOpener = "Camera"; shell.adjustTab = .camera } label: {
      VStack(alignment: .leading, spacing: Space.xs) {
        // The camera's name is the headline; the connection, format and shot are quieter detail, each on its own line.
        Text(sourceInfo?.displayName ?? "").font(.system(size: 16, weight: .semibold))
        Group {
          if let connection = sourceInfo?.connectionDescription { Text(connection) }
          if let format = sourceInfo?.videoFormat { Text(format).lineLimit(1).minimumScaleFactor(0.6) }
          ForEach(shotLabel.components(separatedBy: " · "), id: \.self) { Text($0) }
        }.font(.system(size: 14)).foregroundStyle(.white.opacity(0.62))
      }.font(.system(size: 15, weight: .regular)).multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
        .background(Surfaces.presenterPanel, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
    }.buttonStyle(.plain).uiZoom(controlZoom).help("Camera and shot settings")
      .accessibilityLabel("Camera: " + (sourceInfo?.displayName ?? "") + ", " + shotLabel)
    }
  }

  private var shotLabel: String {
    if camera.guides.automaticRotation { return "Automatic" }
    switch camera.guides.rotation {
    case .none: return "Landscape · Upright"
    // The words of the Adjust Camera shot cards.
    case .quarter: return "Vertical left · Top on the left"
    case .threeQuarters: return "Vertical right · Top on the right"
    case .half: return "Upside down · Top at the bottom"
    }
  }

  private var micLevelVisible: Bool { meterReserved && !draft.isEditing }
  private var trackedStage: some View {
    stage
    // Between takes the meter listens through the recording microphone's test; a take feeds it itself.
    .task(id: "\((camera.cleanView ? camera.keepCleanMicMeter : showsMicLevel) && startsCamera && micListening && !draft.isEditing)-\(recorder.isRecording || recorder.isBusy)-\(store.settings.audioDeviceUID ?? "")-\(store.audioChannelRevision)") {
      guard (camera.cleanView ? camera.keepCleanMicMeter : showsMicLevel) && startsCamera && micListening && !draft.isEditing else { if recorder.isTestingInput { recorder.stopInputTest() }; return }
      if !recorder.isRecording && !recorder.isBusy {
        recorder.stopInputTest()
        recorder.useSettings(store.settings)
        await recorder.startInputTest()
      }
    }
    .onAppear { if startsCamera { refreshMicrophones() }; micListening = session.listensToMicrophone }
    .onReceive(session.$listensToMicrophone) { micListening = $0 }
    .onChange(of: store.settings.audioDeviceUID) { _, _ in if startsCamera { refreshMicrophones() } }
    .onChange(of: store.settings) { _, value in
      session.updateSettings(value)
      recorder.useSettings(value)
    }
    .onReceive(session.$isPreparingVoice.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onReceive(session.$hasLiveRecognition.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onReceive(session.$manualCompleted.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onChange(of: session.isActivelyRunning) { _, active in shell.reading = active }
    .onReceive(NotificationCenter.default.publisher(for: .init("VideoPrompter.presenterInteraction"))) { _ in revealControls() }
    .onDisappear { quietTask?.cancel() }
    .onChange(of: camera.cleanView) { _, clean in
      if clean { shell.cleanEntered(session: session); showsReadingNotice = false; showsSettings = false }
      cleanControlsRevealed = false
      if clean { quietTask?.cancel() }
      announce("Clean view " + (clean ? "on" : "off"))
    }
  }
  var body: some View {
    GeometryReader { geometry in
      presenterContent
        .onAppear { viewport = geometry.size }
        .onChange(of: geometry.size) { _, size in viewport = size }
    }
  }
  private var presenterContent: some View {
    trackedStage
    .onAppear { recorder.useSettings(store.settings); camera.recorder = recorder; if camera.cleanView { shell.cleanEntered(session: session) } }
    .onExitCommand {
      if camera.cleanView { camera.cleanView = false }
      else if shell.escape(camera: camera, session: session) {}
      else if showsSettings { showsSettings = false }
      else if draft.isEditing { draft.requestCancel() }
    }
    .onChange(of: camera.displayMode) { _, mode in
      monitor.displayModeDidChange(mode)
      if mode == .videoOnly { session.pause() }
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
    .safeAreaInset(edge: .trailing, spacing: 0) {
      if shell.adjustTab != nil, !camera.cleanView, !adjustIsSheet {
        adjustPanel(width: 470 * controlZoom)
      }
    }
    .overlay(alignment: .top) {
      if camera.cleanView {
        exitPill("Exit Clean · Esc", revealed: cleanControlsRevealed || cleanExitFocused || revealsCleanExit) { camera.cleanView = false }
          .focused($cleanExitFocused)

      }
    }
    .onContinuousHover { phase in
      guard case .active = phase else { return }
      if camera.cleanView { revealControls() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if showsChrome && hasBarContent { controlBar.environment(\.colorScheme, .dark) }
    }
    .overlay {
      if shell.adjustTab != nil, !camera.cleanView, adjustIsSheet {
        adjustPanel(width: viewport.width)
      }
    }
    .popover(isPresented: $showsSettings) {
      PresenterSettingsPopover(store: store, initialTab: settingsTab, initialCameraSection: cameraSection)
    }
    .confirmationDialog("Close while a take is active?", isPresented: $controller.asksToCloseRecording) {
      Button("Stop and save, then close") { controller.stopAndClose() }
      Button("Keep recording") { controller.keepRecordingAndClose() }
      Button("Cancel", role: .cancel) {}
    } message: { Text("Keep recording leaves a recording status window with a Stop button.") }
    .confirmationDialog("Save changes to this script?", isPresented: $draft.closeRequested) {
      Button("Save") { Task { await draft.saveAndClose(store: store) } }.disabled(draft.isSaving)
      Button("Discard", role: .destructive) { draft.discardAndClose() }.disabled(draft.isSaving)
      Button("Cancel", role: .cancel) { draft.keepEditing() }
    } message: {
      Text("The draft has not been saved to the script library.")
    }
    .onChange(of: session.readingStatus) { _, value in if showsScript { announce(value) } }
    .onChange(of: session.anchorNotice) { _, value in if showsScript, let value { announce(value) } }
    .onChange(of: draft.errorMessage) { _, value in if let value { announce(value) } }
    .onChange(of: draft.markdown) { editorNotice = nil }
    .onChange(of: draft.isEditing) { _, isEditing in if isEditing { editorNotice = nil } }
  }

  /// A keyboard-accessible exit that appears on pointer activity.
  private func exitPill(_ title: String, revealed: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: "xmark")
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, Space.md).frame(minHeight: 44)
        .background(.black.opacity(0.85), in: Capsule()).foregroundStyle(.white)
        .opacity(revealed ? 1 : 0)
    }.buttonStyle(.plain).accessibilityLabel(title).padding(Space.xxl)
  }

  private var hasBarContent: Bool { !draft.isEditing || store.shootSetupError != nil || hasBottomNotice }
  private var controlBar: some View {
    barContent.environment(\.colorScheme, .dark)
      .uiZoom(controlZoom).fixedSize(horizontal: false, vertical: true)
  }

  /// Pointer or key activity reveals Clean's exit pill.
  private func revealControls() {
    if camera.cleanView {
      cleanControlsRevealed = true
      quietTask?.cancel()
      quietTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        cleanControlsRevealed = false
      }
    }
  }

  private var barContent: some View {
    VStack(spacing: Space.sm) {
      if let error = store.shootSetupError {
        HStack {
          Text(error).fixedSize(horizontal: false, vertical: true)
          Button("Hide") { store.shootSetupError = nil }.frame(minHeight: 44)
        }.padding(Space.sm).padding(.top, Space.sm)
      }
      if hasBottomNotice {
        Group { if shell.reading { readingNotice } else { bottomNotice } }.padding(.top, Space.sm)
      }
      if !draft.isEditing {
        setupBar
      }
    }.padding(.horizontal, viewport.width / controlZoom < 900 ? Space.sm : Space.lg)
      // The bar's rows carry their own vertical room, so a two-row bar can keep it tight.
      .padding(.bottom, draft.isEditing ? Space.md : 0).frame(maxWidth: .infinity)
      .background(PresenterBar.background)
      .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
      .buttonStyle(PresenterButtonStyle()).accessibilityIdentifier("presenter-control-bar")
  }

  // MARK: Setup bar

  /// Setup uses the same ordered rows as the iPad and linked-iPad console.
  private var setupBar: some View {
    PresenterSetupBar(scale: controlZoom) {
      setupTransport(short: true)
    } devices: {
      callGroup()
    } tools: {
      toolsGroup()
    } options: {
      PresenterTurnControls(mirror: $store.settings.horizontalMirror, flip: $store.settings.verticalMirror)
      Button { settingsTab = .reading; showsSettings = true } label: { BarLabel(title: "Text", symbol: "textformat.size") }
        .buttonStyle(BarButtonStyle())
      viewGroup(titles: true)
    }
  }

  /// Opens the script in the library. Plain among the quiet options, so it never looks switched on.
  private func scriptButton(short: Bool = false, titled: Bool = true, role: BarButtonStyle.Role = .plain, snug: Bool = false) -> some View {
    Button { controller.openScript(store: store) } label: { BarLabel(title: short ? "Open" : "Open script", symbol: "doc.text", showsTitle: titled, snug: snug) }
      .buttonStyle(BarButtonStyle(role: role)).accessibilityLabel("Open script")
      .help("Open this script in the library to edit its title and details")
  }
  /// Editing where the script is read: the same editor as the library, saved with Save changes.
  private func editButton(titled: Bool = true) -> some View {
    Button { controller.beginEditing() } label: { BarLabel(title: "Edit", symbol: "pencil", showsTitle: titled) }
      .buttonStyle(BarButtonStyle()).accessibilityLabel("Edit script here")
      .help("Edit the script here (⌥⌘E)").disabled(!hasScript || draft.isEditing)
  }

  /// Every transport button has its word; Back to start and Open script may take their short forms.
  @ViewBuilder private func setupTransport(short: Bool, shortOpen: Bool = false, snug: Bool = false) -> some View {
    Button { session.toggle() } label: { BarLabel(title: session.isActivelyRunning || session.isCountingDown ? "Pause" : "Start reading", symbol: session.isActivelyRunning || session.isCountingDown ? "pause.fill" : "play.fill", snug: snug).frame(minWidth: 144) }
      .buttonStyle(BarButtonStyle(role: .prominent)).accessibilityLabel(session.isCountingDown ? "Pause, cancel countdown" : session.isActivelyRunning ? "Pause" : "Start reading")
      .help(session.isCountingDown ? "Pause and cancel countdown (Space)" : session.isActivelyRunning ? "Pause (Space)" : "Start reading (Space)").disabled(!hasScript || draft.isEditing)
    Button { session.restart() } label: { BarLabel(title: short ? "Back" : "Back to start", symbol: "arrow.counterclockwise", snug: snug) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Back to start")
      .help("Back to the first word (Home)").disabled(!hasScript)
    Text("\(session.isActivelyRunning ? "Reading" : "Paused") · word \(session.document.spokenTokens.isEmpty ? 0 : session.tokenIndex + 1) of \(session.document.spokenTokens.count)")
      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
  }

  // MARK: Video-call group: camera, microphone, script

  private var recorderBusy: Bool { recorder.isRecording || recorder.isBusy }
  private var cameraValue: String { "\(sourceInfo?.displayName ?? "No camera chosen"), \(shotLabel)" }

  /// Camera, Mic and Script always show their words.
  private func callGroup(snug: Bool = false) -> some View {
    BarGroup(label: "Camera, microphone and script") {
      BarDeviceControl(offIsWarning: false, title: "Camera", offTitle: "Camera off", onSymbol: "video.fill", offSymbol: "video.slash.fill", isOn: camera.presentsWithVideo,
        showsTitle: true, snug: snug, isEnabled: hasScript,
        toggleHelp: camera.presentsWithVideo ? "Turn the camera off to see just the script" : "Turn the camera on",
        menuLabel: "Choose camera", menuValue: cameraValue, toggle: toggleCamera) { cameraMenu }
      BarDivider()
      micControl(titles: true, snug: snug)
      PresenterInputLevel(meter: recorder.inputMeter)
      BarDivider()
      BarToggle(title: "Script", symbol: "text.alignleft", isOn: shell.scriptPreview, showsTitle: true, snug: snug,
        help: shell.scriptPreview ? "Hide the script" : "Show the script over the picture") { shell.scriptPreview.toggle() }
        .disabled(!hasScript)
        .contextMenu { scriptButton() }
      Menu { scriptButton() } label: { Image(systemName: "chevron.down") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Script options")
      editButton()
    }
  }

  private func micControl(titles: Bool, snug: Bool = false) -> some View {
    BarDeviceControl(title: "Mic", onSymbol: "mic.fill", offSymbol: "mic.slash.fill", isOn: micListening,
      showsTitle: titles, snug: snug,
      toggleHelp: micListening ? "Turn the microphone off: Video Prompter stops listening" : "Turn the microphone on",
      menuLabel: "Choose microphone", menuValue: inputName, toggle: toggleMicrophone) { micMenu }
  }

  private func toggleCamera() {
    let turningOff = camera.presentsWithVideo
    camera.presentsWithVideo.toggle()
    // Camera off leaves just the script, as in a video call with the picture switched off.
    if turningOff { shell.scriptPreview = true }
    announce("Camera " + (turningOff ? "off" : "on"))
  }

  private func toggleMicrophone() {
    session.setListensToMicrophone(!micListening)
    announce("Microphone " + (micListening ? "off" : "on"))
  }

  @ViewBuilder private var cameraMenu: some View {
    let selected = CameraModel.resolve(camera.selectedUID, in: camera.devices)?.uid
    if camera.devices.isEmpty {
      Text("No camera connected")
    }
    ForEach(camera.devices, id: \.uid) { device in
      Toggle(device.displayName, isOn: Binding(get: { device.uid == selected }, set: { on in
        guard on, !recorderBusy else { return }
        camera.selectedUID = device.uid
        if !camera.presentsWithVideo { camera.presentsWithVideo = true }
        LibraryAnnouncement.post("Camera selected: " + device.displayName)
      })).disabled(recorderBusy)
    }
    Divider()
    CameraRotationMenu(angle: camera.guides.rotation.rawValue) { if let rotation = CameraRotation(rawValue: $0) { camera.setRotation(rotation) } }
    Text("Dim picture · \(Int(store.settings.videoDimming * 100))%")
    Slider(value: $store.settings.videoDimming, in: 0...1).accessibilityLabel("Dim picture")
    Button("Refresh cameras") { camera.refresh() }
    Button("Camera settings…") { adjustOpener = "Camera"; shell.adjustTab = .camera }
  }

  private func microphoneBinding(_ uid: String?) -> Binding<Bool> {
    Binding(get: { store.settings.audioDeviceUID == uid }, set: { on in
      guard on, store.settings.audioDeviceUID != uid else { return }
      store.session.stopMicrophoneTest(); recorder.stopInputTest()
      store.settings.audioDeviceUID = uid
    })
  }
  private func channelBinding(_ device: AudioInputDevice) -> Binding<AudioChannel> {
    Binding(get: { _ = store.audioChannelRevision; return AudioChannel.load(device.uid, defaults: store.defaults) }, set: {
      store.session.stopMicrophoneTest(); recorder.stopInputTest()
      $0.save(device.uid, defaults: store.defaults)
      store.audioChannelRevision += 1
      store.session.audioChannelDidChange()
    })
  }

  @ViewBuilder private var micMenu: some View {
    Section("Input") {
      Toggle("System default", isOn: microphoneBinding(nil))
      ForEach(microphones.filter { !$0.isOther }) { Toggle($0.name, isOn: microphoneBinding($0.uid)) }
    }
    if microphones.contains(where: \.isOther) {
      Section("Other inputs") { ForEach(microphones.filter(\.isOther)) { Toggle($0.name, isOn: microphoneBinding($0.uid)) } }
    }
    if let device = microphones.first(where: { $0.uid == store.settings.audioDeviceUID }), device.channels > 1 {
      Picker("Channel", selection: channelBinding(device)) {
        ForEach(AudioChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
    }
    Divider()
    Toggle("Show level meter", isOn: $showsMicLevel)
    Button("Microphone settings…") { adjustOpener = "Mic"; shell.adjustTab = .mic }
  }

  // MARK: Picture tools

  /// The picture exists: a reference image, or frames from the camera. Without it the exposure and
  /// guide tools have nothing to act on, so they are dimmed (still reachable) and never show as on.
  private var hasPicture: Bool { referencePicture != nil || camera.pictureSize != nil }

  private func toolsGroup() -> some View {
    let live = hasPicture
    let snug = false
    return BarGroup(label: "Picture tools", raised: false) {
      tool("Zebras", "rectangle.pattern.checkered", tab: .zebras, on: live && camera.effectiveZebras, snug: snug,
           help: live ? "Zebra stripes on the brightest areas (⌥⌘Z). Press and hold to adjust." : "Zebra stripes, once there is a camera picture (⌥⌘Z). Press and hold to adjust.") { toggleExposure(\.zebras) }
        .opacity(live ? 1 : 0.45)
      tool("False colour", "circle.lefthalf.filled", tab: .falseColour, on: live && camera.effectiveFalseColour, snug: snug,
           help: live ? "False colour exposure (⌥⌘X). Press and hold to adjust." : "False colour exposure, once there is a camera picture (⌥⌘X). Press and hold to adjust.") { toggleExposure(\.falseColour) }
        .opacity(live ? 1 : 0.45)
      tool("Guides", "squareshape.split.3x3", tab: .guides, on: live && camera.framingIsVisible, snug: snug,
           help: "Framing guides. Press and hold to adjust.") { camera.toggleFramingGuides() }
        .opacity(live ? 1 : 0.45)

    }
  }

  private func viewGroup(titles: Bool) -> some View {
    HStack(spacing: 0) {
      // Like the picture tools, the key has nothing to explain without a picture: dimmed, never shown as on.
      BarToggle(title: "Key", symbol: "list.bullet.rectangle", isOn: exposureKeyEnabled && hasPicture, showsTitle: titles, displayTitle: "Key",
        help: exposureKeyEnabled ? "Hide the exposure key: what the zebras and colours mean" : "Show the exposure key: what the zebras and colours mean") { exposureKeyEnabled.toggle() }
        .disabled(!camera.exposureIsConfigured).opacity(hasPicture ? 1 : 0.45)
      PresenterCleanMenu(selected: camera.cleanLook, active: camera.cleanView,
        keepMicMeter: $camera.keepCleanMicMeter, choose: { look in
          camera.chooseCleanLook(look)
        }, leave: { camera.cleanView = false }, fullScreen: { controller.toggleFullScreen() })
    }
  }

  /// A picture tool: tapping toggles it, pressing and holding (or the context menu) opens its Adjust tab.
  private func tool(_ title: String, _ symbol: String, tab: AdjustTab, on: Bool, shortTitle: String? = nil, snug: Bool = false, adjustable: Bool = true,
                    help: String, traits: AccessibilityTraits = .isToggle, value: String? = nil,
                    action: @escaping () -> Void) -> some View {
    BarToggle(title: title, symbol: symbol, isOn: on, displayTitle: shortTitle, snug: snug, help: help, traits: traits, value: value) {
      adjustOpener = title; action()
    }
    .restoringPopoverFocus(isPresented: Binding(get: { shell.adjustTab != nil && adjustOpener == title }, set: { if !$0 { shell.adjustTab = nil } }), identifier: "adjust-opener-\(title)")
    .contextMenu { if adjustable { Button("Adjust \(title)") { adjustOpener = title; shell.adjustTab = tab } } }
    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in if adjustable { adjustOpener = title; shell.adjustTab = tab } })
  }

  private func toggleExposure(_ key: WritableKeyPath<CameraGuides, Bool>) {
    let enabled = camera.exposureBinding(key).wrappedValue
    camera.exposureBinding(key).wrappedValue = !enabled
  }

  private func announce(_ message: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }

  private var readingNotice: some View {
    let message = editorNotice ?? session.anchorNotice ?? draft.errorMessage ?? draft.noticeMessage ?? "Check reading"
    return Button { showsReadingNotice = true } label: {
      Label(message, systemImage: "exclamationmark.circle")
        .font(.callout).lineLimit(2).frame(maxWidth: 560, minHeight: 44)
    }.buttonStyle(.plain).accessibilityLabel(message)
      .accessibilityHint("Open reading controls and the full message")
      .popover(isPresented: $showsReadingNotice) { bottomNotice.padding(Space.md) }
  }

  private var bottomNotice: some View {
    VStack(spacing: Space.sm) {
      Button("Reading mode and speed") { settingsTab = .reading; showsSettings = true }.initialPopoverFocus()
      if draft.isEditing, draft.hasExternalChange(in: store) {
        Label("Updated outside Video Prompter. Saving merges it with your changes, or keeps this draft and shows a conflict if they touch the same lines.", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.primary)
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
    .padding(Space.sm).background(LibraryAppearance.color(.windowBackgroundColor, scheme: .dark), in: RoundedRectangle(cornerRadius: 12))
    .frame(maxWidth: 560)
  }
  private var hasBottomNotice: Bool {
    editorNotice != nil || session.anchorNotice != nil || draft.noticeMessage != nil
      || draft.errorMessage != nil || (draft.isEditing && draft.hasExternalChange(in: store))
  }

}

/// The script being edited, on a visible editable surface, so it reads as a text field and not as the
/// reading view with a caret in it. Its text has exactly the reading column's width, font, size and
/// spacing, so no line re-wraps when switching; the box fills the room, so no empty black is left below it.
/// Editing behaviour is `PresenterEditorView`'s.
struct PresenterEditingSurface: View {
  @ObservedObject var session: SessionStore
  @ObservedObject var draft: PresenterDraft
  let settings: PrompterSettings
  /// The width the reading text column is centred in.
  let width: CGFloat
  /// The empty meter strip beside the editor: the box moves over by half of it, so it sits in the middle of
  /// the stage and not of the stage less that strip. Its text keeps the reading column's width.
  var centreShift: CGFloat = 0
  var zoom = 1.0
  var isSaving = false
  var save: () -> Void = {}
  var cancel: () -> Void = {}
  var onUnsupportedEdit: () -> Void
  private static let inset = Space.xl
  /// The header row above the text: the same height as the Save and Cancel buttons plus their padding.
  static let headerHeight = PresenterBar.height + 2 * Space.sm

  var body: some View {
    let measure = ScriptTextView.measureCappedFraction(width: width, textWidth: settings.textWidth, fontSize: settings.fontSize)
    let columnInset = ScriptTextView.sideInset(width: width, textWidth: measure)
    let shape = RoundedRectangle(cornerRadius: AlphaStyle.cardCorner)
    let boxWidth = max(1, width - 2 * max(0, columnInset - Self.inset))
    let sidePadding = max(0, columnInset - Self.inset)
    let shift = min(centreShift, sidePadding)
    GeometryReader { geometry in
      let header = Self.headerHeight * zoom
      let available = max(1, geometry.size.height - Space.xl - Space.xxl - header)
      // One box: its header (Save and Cancel at the editor's own right edge), then the text.
      VStack(spacing: 0) {
        PresenterEditingBand(isSaving: isSaving, compact: boxWidth / zoom < 560, save: save, cancel: cancel)
          .uiZoom(zoom).fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, .dark)
        PresenterEditorView(session: session, draft: draft, settings: settings, sideInset: Self.inset, onUnsupportedEdit: onUnsupportedEdit)
          .scaleEffect(x: settings.horizontalMirror ? -1 : 1, y: settings.verticalMirror ? -1 : 1)
          .rotationEffect(.degrees(Double(settings.rotation)))
          // With the text container's own 8 pt, the first line's letters sit about as far below the header as from the left edge.
          .padding(.top, Space.sm)
          .frame(height: available)
      }
      .background(shape.fill(.white.opacity(0.1)))
      .clipShape(shape)
      // A plain 1 pt edge, and a soft yellow ring for focus, so Save keeps the strongest yellow.
      .overlay(shape.stroke(.white.opacity(0.3), lineWidth: 1))
      .overlay(shape.inset(by: -3).stroke(AlphaStyle.accent.opacity(0.3), lineWidth: 2))
      .padding(.leading, sidePadding + shift).padding(.trailing, sidePadding - shift)
      .padding(.top, Space.xl)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }.accessibilityElement(children: .contain).accessibilityIdentifier("presenter-editing-surface")
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
      alignment: NSTextAlignment(setting: settings.alignment),
      bold: settings.fontWeight == "Bold")
  }
}

/// Word changes invalidate only the text representable, not the camera and presenter controls.
private struct PresenterScriptView: View {
  @ObservedObject var session: SessionStore
  let settings: PrompterSettings
  /// Where the reading line is drawn (the saved position, raised in a short window).
  let guideFraction: Double
  let sideInset: CGFloat
  var overVideo = false
  var topInset: CGFloat = 0
  var bottomInset: CGFloat = 0

  var body: some View {
    ScriptTextView(
      document: session.document, tokenIndex: session.tokenIndex,
      lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
      isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
      guideFraction: guideFraction,
      verticalMirror: settings.verticalMirror != (settings.rotation == 180),
      fontName: settings.fontName,
      fontSize: settings.fontSize, textOpacity: settings.textOpacity,
      fontWeight: settings.fontWeight, textColorHex: settings.textColorHex,
      lineSpacing: settings.lineSpacing, paragraphSpacing: settings.paragraphSpacing,
      horizontalMargin: sideInset, alignment: settings.alignment,
      overVideo: overVideo, showCues: settings.showCues, readingBandOpacity: settings.readingBandOpacity, highlightActiveWord: settings.highlightActiveWord,
      manualPosition: session.isManual ? { session.manualPosition() }
        : ScriptTextView.Coordinator.reducesMotion() ? nil : { session.voicePosition() },
      onSeek: session.seek, onUserScroll: session.seekFromUserScroll
    )
      .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-script-content")
      .padding(.top, topInset).padding(.bottom, bottomInset)
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
/// The bar is always dark; its popovers belong to the system appearance. Resolve both
/// sides of the pair and reset the inherited button style before AppKit hosts the popover.
struct PresenterPopoverSurface<Content: View>: View {
  let scheme: ColorScheme
  @ViewBuilder var content: () -> Content
  var body: some View {
    content()
      .buttonStyle(.bordered)
      .foregroundStyle(LibraryAppearance.color(.labelColor, scheme: scheme))
      .background(LibraryAppearance.color(.windowBackgroundColor, scheme: .dark))
      .environment(\.colorScheme, scheme)
      .preferredColorScheme(scheme)
  }
}

struct PresenterGlass: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
  @Environment(\.offscreenRendering) private var offscreenRendering
  @Environment(\.presenterReduceTransparency) private var transparencyOverride
  private var reduceTransparency: Bool { transparencyOverride ?? (systemReduceTransparency || offscreenRendering) }
  let radius: CGFloat
  func body(content: Content) -> some View {
    if reduceTransparency { content.background(Surfaces.presenterPanel, in: RoundedRectangle(cornerRadius: radius)) }
    else { content.glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: radius)) }
  }
}

struct PresenterButtonStyle: PrimitiveButtonStyle {
  @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
  @Environment(\.offscreenRendering) private var offscreenRendering
  @Environment(\.presenterReduceTransparency) private var transparencyOverride
  private var reduceTransparency: Bool { transparencyOverride ?? (systemReduceTransparency || offscreenRendering) }
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

private struct PresenterTransparencyOverride: EnvironmentKey {
  static let defaultValue: Bool? = nil
}
extension EnvironmentValues {
  /// Fixtures can exercise both chrome paths without changing macOS accessibility settings.
  var presenterReduceTransparency: Bool? {
    get { self[PresenterTransparencyOverride.self] }
    set { self[PresenterTransparencyOverride.self] = newValue }
  }
}
