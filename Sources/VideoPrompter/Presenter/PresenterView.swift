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
  private var sourceInfo: CameraSourceInfo? { sourceInfoOverride ?? camera.sourceInfo }

  init(store: AppStore, session: SessionStore, draft: PresenterDraft, hasScript: Bool = true,
       camera: CameraModel = .shared, monitor: ReferenceMonitor = .shared, startsCamera: Bool = true, recorder: CameraRecorder = .shared, shell: PresenterShell? = nil, referencePicture: NSImage? = nil, revealsCleanExit: Bool = false, sourceInfoOverride: CameraSourceInfo? = nil, microphoneNameOverride: String? = nil) {
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
  @State private var barTask: Task<Void, Never>?
  @State private var showsSettings = false
  @State private var showsReadingNotice = false
  @State private var cleanControlsRevealed = false
  @State private var barRevealed = false
  @State private var barHovered = false
  @StateObject private var shell: PresenterShell
  private var showsChrome: Bool { !camera.cleanView }
  @AppStorage("presenterExposureKey") private var exposureKeyEnabled = true
  @State private var adjustOpener = "Adjust"
  // A new key enables the meter once for existing installs, then remembers their choice.
  @AppStorage("presenterMicLevel251") private var showsMicLevel = true
  /// Reading with nothing but the text, the audio meter and the reading line. Also in View > Focus Mode.
  @AppStorage("presenterFocusMode") private var focusMode = false
  /// While reading, the bottom bar slides away and returns on mouse movement.
  @AppStorage("presenterAutoHideBar") private var autoHidesBar = false
  @State private var microphones: [AudioInputDevice] = []
  @State private var defaultMicrophoneName: String?
  @State private var micListening = true
  @State private var settingsTab = SettingsTab.reading
  @FocusState private var cleanExitFocused: Bool
  static func backdropOpacity(saved: Double, reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : saved }
  // Interface size applies to the entire shell, with named controls wrapping as needed.
  static func controlZoom(_ zoom: Double) -> Double { zoom }
  /// A window of 4K size gets proportionally larger chrome, so it reads like a laptop one: 1 up to
  /// 2400 points wide (before the interface zoom), then growing with the window, to 1.5 at most.
  static func sizeBoost(width: CGFloat) -> Double { min(1.5, max(1, Double(width) / 2400)) }
  private var controlZoom: Double {
    Self.controlZoom(store.uiZoom) * Self.sizeBoost(width: viewport.width / Self.controlZoom(store.uiZoom))
  }
  /// The width of the slim microphone strip at the right edge, before zoom.
  static let meterWidth: CGFloat = 96
  @State private var viewport = CGSize(width: 1600, height: 1000)
  @AppStorage("presenterExposureKeyExpanded") private var keyExpanded = true
  @ObservedObject private var recorder: CameraRecorder
  /// The script is on screen: reading, editing, the setup preview, or the camera being off.
  private var showsScript: Bool { !camera.cleanView && hasScript && (shell.reading || draft.isEditing || shell.scriptPreview) }
  /// Clean full screen while reading: only the text, the meter and the reading line.
  private var focusActive: Bool { focusMode && shell.reading && !draft.isEditing && !camera.cleanView }
  private var barOverlays: Bool { shell.reading && !draft.isEditing && (focusMode || autoHidesBar) }
  private var readingBarHidden: Bool {
    guard barOverlays else { return false }
    if focusMode { return true }
    return session.isActivelyRunning && !barRevealed && !barHovered && shell.adjustTab == nil
      && !showsSettings && !showsReadingNotice && !hasBottomNotice
  }
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
      let keyVisible = exposureKeyEnabled && camera.presentsWithVideo && !camera.cleanView && camera.exposureIsConfigured && !camera.exposureBypassed && !editing && !focusActive
      let meterWidth = micLevelVisible ? Self.meterWidth * controlZoom : 0
      let setup = !shell.reading && !editing && !camera.cleanView && camera.presentsWithVideo
      let pictureSize = referencePicture?.size ?? camera.pictureSize ?? CGSize(width: 16, height: 9)
      let pictureAspect = referencePicture != nil ? pictureSize.width / max(1, pictureSize.height) :
        (camera.guides.rotation.swapsAxes ? pictureSize.height / max(1, pictureSize.width) : pictureSize.width / max(1, pictureSize.height))
      let pictureWidth = min(geometry.size.width, geometry.size.height * pictureAspect)
      let availableGutter = (geometry.size.width - pictureWidth) / 2
      let roomyGutter = availableGutter >= (280 * controlZoom + Space.md * 2)
      let columnWidth = (roomyGutter ? 280 : 144) * controlZoom + Space.md * 2
      let gutterWidth = setup ? max(meterWidth, min(columnWidth, pictureAspect > 1 ? geometry.size.width * 0.25 : columnWidth)) : 0
      // The script sits in the picture region: the stage less the setup gutters and the meter.
      let regionWidth = max(1, setup ? geometry.size.width - 2 * gutterWidth : geometry.size.width - meterWidth)
      let columnInset = ScriptTextView.sideInset(width: regionWidth, textWidth: store.settings.textWidth)
      let scriptTopInset = keyVisible && shell.reading ? (36 + Space.md * 2) * controlZoom : 0
      HStack(alignment: .top, spacing: 0) {
        if setup {
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
          }.frame(width: gutterWidth, height: geometry.size.height, alignment: .topLeading)
        }
        ZStack(alignment: .top) {
          if camera.presentsWithVideo || camera.cleanView {
            Group {
              if let referencePicture { Image(nsImage: referencePicture).resizable().scaledToFit() }
              else { CameraPreview(model: camera, presenter: true) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              .task { if startsCamera { camera.start() } }
          }
          if showsScript {
            Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black)
              .opacity(editing ? 1 : Self.backdropOpacity(saved: store.settings.backdropOpacity(withVideo: camera.presentsWithVideo), reduceTransparency: reduceTransparency))
            if !editing && camera.presentsWithVideo {
              ReadingBacking(opacity: reduceTransparency ? 0.9 : 0.45)
                .frame(width: min(regionWidth, regionWidth * store.settings.textWidth + 2 * Space.xxl))
                .padding(.vertical, Space.sm)
            }
            // Behind the words, so the line shows where the reading is without striking them through.
            if !editing {
              GuideLine(settings: store.settings)
                .offset(y: scriptTopInset + ScriptTextView.visualGuideY(height: geometry.size.height - scriptTopInset, fraction: store.settings.guideFraction) - 1)
            }
            Group {
              if editing {
                PresenterEditingSurface(session: session, draft: draft, settings: store.settings, width: regionWidth, zoom: controlZoom) {
                  editorNotice = "That change could not be applied safely. Your text is unchanged. Try a smaller selection."
                }
              } else {
                PresenterScriptView(session: session, settings: store.settings,
                  sideInset: columnInset,
                  overVideo: camera.presentsWithVideo,
                  topInset: scriptTopInset)
              }
            }.scaleEffect(x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1)
              .rotationEffect(.degrees(Double(store.settings.rotation))).clipped()
          }
          if keyVisible && shell.reading && !editing {
            Button { keyExpanded.toggle() } label: {
              HStack(spacing: Space.sm) {
                if keyExpanded {
                  if camera.guides.falseColour {
                    HStack(spacing: 0) { ForEach([Color.pink, .red, Color(red: 1, green: 1, blue: 0), .green, .blue], id: \.self) { $0 } }.frame(width: 24, height: 16)
                  } else { PresenterZebraSwatch().frame(width: 24, height: 16) }
                  Text(camera.guides.falseColour ? "False colour on" : "Zebras on")
                } else { Text("Exposure key") }
                Image(systemName: keyExpanded ? "chevron.up" : "chevron.down")
              }.font(.system(size: 15, weight: .semibold))
                .frame(minHeight: ceil(AlphaStyle.minTarget / controlZoom)).padding(.horizontal, Space.sm)
                .background(.black.opacity(0.8), in: Capsule())
            }.buttonStyle(.plain).help(keyExpanded ? "Hide key" : "Show key")
              .accessibilityLabel(keyExpanded ? "Hide key" : "Show key")
              .uiZoom(controlZoom).frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
              .accessibilityIdentifier("presenter-exposure-legend")
          }
          if referencePicture == nil && camera.presentsWithVideo && camera.needsRecovery && !showsScript && !camera.cleanView {
            CameraRecoveryView(model: camera, prominent: true) { adjustOpener = "Camera"; shell.adjustTab = .camera }
              .uiZoom(controlZoom).frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if setup { Color.clear.frame(width: max(0, gutterWidth - meterWidth)) }
        if micLevelVisible {
          MicMeterView(meter: recorder.inputMeter, micName: inputName, isListening: micListening)
            .frame(width: Self.meterWidth, height: max(0, geometry.size.height / controlZoom - 32)).uiZoom(controlZoom)
            .frame(width: meterWidth).padding(.vertical, Space.md)
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1).padding(.vertical, Space.md) }
        }
      }.foregroundStyle(.white)
        .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-visible-stage")
    }.background(camera.cleanView ? Color.black : Color(white: 0.035))

  }

  static func usesAdjustSheet(width: CGFloat, zoom: Double) -> Bool { width < 470 * zoom + 400 }
  private var adjustIsSheet: Bool { Self.usesAdjustSheet(width: viewport.width, zoom: controlZoom) }
  private func adjustPanel(width: CGFloat) -> some View {
    AdjustPanel(selection: Binding(get: { shell.adjustTab ?? .camera }, set: { shell.adjustTab = $0 }),
      showsMic: $showsMicLevel, camera: camera, store: store, startsMeter: startsCamera,
      zoom: controlZoom, width: width, close: { shell.adjustTab = nil }, recorder: recorder)
      .popoverEntryFocus()
      .onExitCommand { shell.adjustTab = nil }
  }

  /// One card for the camera in use, in the same dark card as the exposure key above it.
  @ViewBuilder private var sourceStatus: some View {
    if sourceInfo != nil {
    Button { adjustOpener = "Camera"; shell.adjustTab = .camera } label: {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(sourceInfo?.displayName ?? "").fontWeight(.semibold)
        if let connection = sourceInfo?.connectionDescription { Text(connection).foregroundStyle(.white.opacity(0.7)) }
        if let format = sourceInfo?.videoFormat { Text(format).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.6) }
        Text(shotLabel).foregroundStyle(AlphaStyle.accent)
      }.font(.system(size: 14, weight: .regular)).multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
        .background(Surfaces.presenterPanel, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
    }.buttonStyle(.plain).uiZoom(controlZoom).help("Camera and shot settings")
      .accessibilityLabel("Camera: " + (sourceInfo?.displayName ?? "") + ", " + shotLabel)
    }
  }

  private var shotLabel: String {
    if camera.guides.automaticRotation { return "Automatic" }
    switch camera.guides.rotation {
    case .none: return "Landscape"
    case .quarter: return "Turned left for vertical"
    case .threeQuarters: return "Turned right for vertical"
    case .half: return "Upside down"
    }
  }

  private var micLevelVisible: Bool { showsMicLevel && !camera.cleanView && !draft.isEditing && (shell.adjustTab == nil || viewport.width >= 1200) }
  private var trackedStage: some View {
    stage
    // Between takes the meter listens through the recording microphone's test; a take feeds it itself.
    .task(id: "\(showsMicLevel && !camera.cleanView && startsCamera && micListening && !draft.isEditing)-\(recorder.isRecording || recorder.isBusy)-\(store.settings.audioDeviceUID ?? "")-\(store.audioChannelRevision)") {
      guard showsMicLevel && !camera.cleanView && startsCamera && micListening && !draft.isEditing else { if recorder.isTestingInput { recorder.stopInputTest() }; return }
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
    .onChange(of: session.isActivelyRunning) { _, active in if active && !camera.cleanView { shell.reading = true } }
    .onReceive(NotificationCenter.default.publisher(for: .init("VideoPrompter.presenterInteraction"))) { _ in revealControls() }
    .onDisappear { quietTask?.cancel(); barTask?.cancel() }
    .onChange(of: camera.cleanView) { _, clean in
      if clean { shell.cleanEntered(session: session); showsReadingNotice = false; showsSettings = false }
      cleanControlsRevealed = false
      if clean { quietTask?.cancel() }
      announce("Clean view " + (clean ? "on" : "off"))
    }
    .onChange(of: focusMode) { _, on in announce("Focus mode " + (on ? "on" : "off")) }
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
      if focusActive { focusMode = false }
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
    .safeAreaInset(edge: .top, spacing: 0) {
      if draft.isEditing && showsChrome {
        PresenterEditingBand(isSaving: draft.isSaving, compact: viewport.width / controlZoom < 700,
          save: { Task { await draft.confirm(store: store) } }, cancel: { draft.requestCancel() })
          .uiZoom(controlZoom).fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, .dark)
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
      } else if focusActive {
        exitPill("Exit Focus · ⌥⌘F", revealed: barRevealed) { focusMode = false }
      }
    }
    .onContinuousHover { phase in
      guard case .active = phase else { return }
      if camera.cleanView { revealControls() } else if barOverlays { revealControls() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if showsChrome && !barOverlays && hasBarContent { controlBar.environment(\.colorScheme, .dark) }
    }
    .overlay(alignment: .bottom) {
      if showsChrome && barOverlays && !readingBarHidden {
        controlBar.environment(\.colorScheme, .dark)
          .onHover { barHovered = $0 }
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: readingBarHidden)
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

  /// The pill that leaves Clean or Focus: faded out until the pointer moves, still reachable by keyboard.
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

  /// Pointer or key activity: Clean's exit pill, and the bar while it is sliding away.
  private func revealControls() {
    if camera.cleanView {
      cleanControlsRevealed = true
      quietTask?.cancel()
      quietTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        cleanControlsRevealed = false
      }
    } else if barOverlays {
      barRevealed = true
      barTask?.cancel()
      barTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled else { return }
        barRevealed = false
      }
    }
  }
  private var barContent: some View {
    VStack(spacing: Space.sm) {
      if let error = store.shootSetupError {
        HStack {
          Text(error).fixedSize(horizontal: false, vertical: true)
          Button("Hide") { store.shootSetupError = nil }.frame(minHeight: 44)
        }.padding(Space.sm)
      }
      if hasBottomNotice {
        if shell.reading { readingNotice } else { bottomNotice }
      }
      if !draft.isEditing {
        if shell.reading { readingBar } else { setupBar }
      }
    }.padding(.horizontal, viewport.width / controlZoom < 600 ? Space.sm : Space.lg)
      .padding(.vertical, shell.reading ? Space.sm : Space.md).frame(maxWidth: .infinity)
      .background(PresenterBar.background)
      .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
      .buttonStyle(PresenterButtonStyle()).accessibilityIdentifier("presenter-control-bar")
  }

  // MARK: Setup bar

  /// One row: transport on the left, then the video-call group, then the picture tools. Words give way
  /// to icons, then the groups wrap, as the window narrows or the interface size grows.
  private var setupBar: some View {
    ViewThatFits(in: .horizontal) {
      setupRow(toolTitles: true, callTitles: true)
      setupRow(toolTitles: false, callTitles: true)
      setupRow(toolTitles: false, callTitles: false)
      WrapLayout(spacing: Space.sm, leading: true) {
        setupTransport
        callGroup(titles: false)
        toolsGroup(titles: false)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func setupRow(toolTitles: Bool, callTitles: Bool) -> some View {
    HStack(spacing: PresenterBar.groupGap) {
      HStack(spacing: Space.sm) { setupTransport }
      Spacer(minLength: Space.md)
      callGroup(titles: callTitles)
      toolsGroup(titles: toolTitles)
    }
  }

  private var scriptButton: some View {
    Button { controller.openScript(store: store) } label: { BarLabel(title: "Open script", symbol: "doc.text", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Open script")
      .help("Open this script in the library")
  }

  @ViewBuilder private var setupTransport: some View {
    Button { shell.reading = true; session.startReading() } label: { BarLabel(title: "Start reading", symbol: "play.fill") }
      .buttonStyle(BarButtonStyle(role: .prominent)).accessibilityLabel("Start reading")
      .help("Start reading (Space)").disabled(!hasScript || draft.isEditing)
    Button { session.restart() } label: { BarLabel(title: "Back to start", symbol: "arrow.counterclockwise") }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Back to start")
      .help("Back to the first word (Home)").disabled(!hasScript)
    scriptButton
  }

  // MARK: Video-call group: camera, microphone, script

  private var recorderBusy: Bool { recorder.isRecording || recorder.isBusy }
  private var cameraValue: String { "\(sourceInfo?.displayName ?? "No camera chosen"), \(shotLabel)" }

  private func callGroup(titles: Bool) -> some View {
    BarGroup(label: "Camera, microphone and script") {
      BarDeviceControl(title: "Camera", onSymbol: "video.fill", offSymbol: "video.slash.fill", isOn: camera.presentsWithVideo,
        showsTitle: titles, isEnabled: hasScript,
        toggleHelp: camera.presentsWithVideo ? "Turn the camera off to see just the script" : "Turn the camera on",
        menuLabel: "Choose camera", menuValue: cameraValue, toggle: toggleCamera) { cameraMenu }
      BarDivider()
      micControl(titles: titles)
      BarDivider()
      BarToggle(title: "Script", symbol: "text.alignleft", isOn: shell.scriptPreview, showsTitle: titles,
        help: shell.scriptPreview ? "Hide the script" : "Show the script over the picture") { shell.scriptPreview.toggle() }
        .disabled(!hasScript)
    }
  }

  private func micControl(titles: Bool) -> some View {
    BarDeviceControl(title: "Mic", onSymbol: "mic.fill", offSymbol: "mic.slash.fill", isOn: micListening,
      showsTitle: titles,
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

  private func toolsGroup(titles: Bool) -> some View {
    BarGroup(label: "Picture tools") {
      tool("Zebras", "rectangle.pattern.checkered", tab: .zebras, on: camera.effectiveZebras, titles: titles,
           help: "Zebra stripes on the brightest areas (⌥⌘Z). Press and hold to adjust.") { toggleExposure(\.zebras) }
      tool("False colour", "circle.lefthalf.filled", tab: .falseColour, on: camera.effectiveFalseColour, titles: titles,
           help: "False colour exposure (⌥⌘X). Press and hold to adjust.") { toggleExposure(\.falseColour) }
      tool("Guides", "squareshape.split.3x3", tab: .guides, on: camera.framingIsVisible, titles: titles,
           help: "Framing guides. Press and hold to adjust.") { camera.toggleFramingGuides() }
      BarToggle(title: "Key", symbol: "list.bullet.rectangle", isOn: exposureKeyEnabled && camera.exposureIsConfigured, showsTitle: titles,
                help: camera.exposureIsConfigured ? "Show or hide the exposure key" : "Turn on Zebras or False colour to use the key") {
        exposureKeyEnabled.toggle()
      }.disabled(!camera.exposureIsConfigured)
      BarDivider()
      tool("Adjust", "slider.horizontal.3", tab: .camera, on: shell.adjustTab != nil, titles: titles, adjustable: false,
           help: "Open the adjust panel", traits: [], value: shell.adjustTab == nil ? "Collapsed" : "Expanded") {
        shell.adjustTab = shell.adjustTab == nil ? .camera : nil
      }
      BarToggle(title: "Clean", symbol: "rectangle", isOn: false, showsTitle: titles,
                help: CameraModel.cleanViewExplanation, traits: [], value: nil) { camera.cleanView = true }
    }
  }

  /// A picture tool: tapping toggles it, pressing and holding (or the context menu) opens its Adjust tab.
  private func tool(_ title: String, _ symbol: String, tab: AdjustTab, on: Bool, titles: Bool, adjustable: Bool = true,
                    help: String, traits: AccessibilityTraits = .isToggle, value: String? = nil,
                    action: @escaping () -> Void) -> some View {
    BarToggle(title: title, symbol: symbol, isOn: on, showsTitle: titles, help: help, traits: traits, value: value) {
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

  // MARK: Reading bar

  /// One slim row: a status pill, the transport in the middle, quiet options on the right.
  private var readingBar: some View {
    ViewThatFits(in: .horizontal) {
      readingRow(showsPill: true)
      readingRow(showsPill: false)
    }
  }
  private func readingRow(showsPill: Bool) -> some View {
    HStack(spacing: Space.md) {
      Group {
        if showsPill { BarStatusPill(text: readingPillText, isActive: session.isActivelyRunning) } else { Color.clear.frame(width: 0, height: 0) }
      }.frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: Space.sm) { readingTransport }
      BarGroup(label: "Reading options") {
        micControl(titles: false)
        BarToggle(title: "Focus", symbol: "rectangle.expand.vertical", isOn: focusMode, showsTitle: false,
                  help: "Focus: only the text, the level meter and the reading line (⌥⌘F)") { focusMode.toggle() }
          .contextMenu { Toggle("Auto-hide these controls while reading", isOn: $autoHidesBar) }
        Button { settingsTab = .reading; showsSettings = true } label: { BarLabel(title: "Reading settings", symbol: "textformat.size", showsTitle: false) }
          .buttonStyle(BarButtonStyle()).help("Reading mode, speed and text").accessibilityLabel("Reading settings")
        scriptButton
      }.frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
  private var readingPillText: String {
    let state = session.visibleReadingState
    return store.settings.mode == "Voice" ? "Voice · \(state)" : "Automatic · \(Int(store.settings.speed)) wpm · \(state)"
  }

  @ViewBuilder private var readingTransport: some View {
    let running = session.isActivelyRunning || session.isCountingDown
    Button { session.restart() } label: { BarLabel(title: "Back to start", symbol: "arrow.counterclockwise", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Back to start").help("Back to the first word (Home)")
    Button { session.toggle() } label: {
      HStack(spacing: Space.sm) {
        BarLabel(title: running ? "Pause" : "Start reading", symbol: running ? "pause.fill" : "play.fill")
        if running { Text("Space").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5)).padding(.trailing, Space.md) }
      }
    }.buttonStyle(BarButtonStyle(role: running ? .secondary : .prominent))
      .accessibilityLabel(running ? "Pause" : "Start reading").help((running ? "Pause" : "Start reading") + " (Space)")
    Button { session.pause(); shell.reading = false } label: { BarLabel(title: "Set up the shot", symbol: "display", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Set up the shot").help("Back to setting up the shot (Esc)")
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
        Label("This script changed outside Video Prompter. Finishing will keep this draft and show a conflict instead of overwriting it.", systemImage: "exclamationmark.triangle.fill")
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

/// The script being edited, on a visible editable surface with a normal top margin, so it reads as a
/// text field and not as the reading view with a caret in it. Editing behaviour is `PresenterEditorView`'s.
struct PresenterEditingSurface: View {
  @ObservedObject var session: SessionStore
  @ObservedObject var draft: PresenterDraft
  let settings: PrompterSettings
  let width: CGFloat
  var zoom = 1.0
  var onUnsupportedEdit: () -> Void

  var body: some View {
    let margin = max(Space.xl, width * (1 - CGFloat(settings.textWidth)) / 2 - Space.xl)
    let shape = RoundedRectangle(cornerRadius: AlphaStyle.cardCorner)
    PresenterEditorView(session: session, draft: draft, settings: settings, sideInset: Space.xl, onUnsupportedEdit: onUnsupportedEdit)
      .padding(.top, Space.md)
      .background(shape.fill(.white.opacity(0.06)))
      .clipShape(shape)
      .overlay(shape.stroke(AlphaStyle.accent.opacity(0.45), lineWidth: 1.5))
      .padding(.horizontal, margin).padding(.top, Space.xxl).padding(.bottom, Space.xl)
      .accessibilityIdentifier("presenter-editing-surface")
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
  var topInset: CGFloat = 0

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
      .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-script-content")
      .padding(.top, topInset)
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
  var distributeAfter: Int? = nil
  var leading = false
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(for: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: distributeAfter != nil && rows.count == 1 ? proposal.width ?? width : width, height: height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    let rows = rows(for: bounds.width, subviews: subviews)
    for row in rows {
      let distribute = rows.count == 1 && distributeAfter != nil
      var x = (distribute || leading) ? bounds.minX : bounds.midX - row.width / 2
      for index in row.indices {
        if distribute, index == distributeAfter { x += max(0, bounds.width - row.width) }
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

struct PresenterZebraSwatch: View {
  var body: some View {
    Canvas { context, size in
      let picture = CGRect(origin: .zero, size: size)
      context.fill(Path(picture), with: .color(.white))
      context.stroke(Path(CameraOverlay.zebraPath(picture: picture)), with: .color(.black),
                     lineWidth: CameraOverlay.zebraLineWidth(picture: picture))
    }.clipShape(RoundedRectangle(cornerRadius: 4))
      .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.6)))
  }
}
