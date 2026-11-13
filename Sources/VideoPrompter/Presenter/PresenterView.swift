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
  /// How long the "Zebras off while reading" note stays after reading starts (fixtures: 0 for the steady state).
  private let zebraChipSeconds: Double
  /// Fixtures: the inputs the Adjust mic card lists, so its selected input can be the one the side meter names.
  private let microphonesOverride: [AudioInputDevice]?
  private var sourceInfo: CameraSourceInfo? { sourceInfoOverride ?? camera.sourceInfo }

  init(store: AppStore, session: SessionStore, draft: PresenterDraft, hasScript: Bool = true,
       camera: CameraModel = .shared, monitor: ReferenceMonitor = .shared, startsCamera: Bool = true, recorder: CameraRecorder = .shared, shell: PresenterShell? = nil, referencePicture: NSImage? = nil, revealsCleanExit: Bool = false, sourceInfoOverride: CameraSourceInfo? = nil, microphoneNameOverride: String? = nil, microphonesOverride: [AudioInputDevice]? = nil, zebraChipSeconds: Double = 3) {
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
    self.zebraChipSeconds = zebraChipSeconds
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
  @State private var focusHintTask: Task<Void, Never>?
  @State private var focusHintVisible = false
  @State private var zebraChipTask: Task<Void, Never>?
  @State private var zebraChipVisible = false
  @State private var showsSettings = false
  @State private var showsReadingNotice = false
  @State private var cleanControlsRevealed = false
  @State private var barRevealed = false
  @State private var barHovered = false
  @State private var controlBarHeight: CGFloat = 0
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
  /// The words the setup bar shows. Every control keeps a word at every size: only the allowed short forms
  /// ("Colour", "Back", "Open") and, last, Key and Clean as icons (they have help text) give way. The bar takes the
  /// richest variant that fits, on one row; when no one-row variant fits, on two compact rows.
  struct SetupWords: Equatable {
    /// Once any word is short, every label gives up a little of its side room too.
    var snug: Bool { shortToolTitles || shortOpen || shortTransport }
    var viewTitles = true
    /// "False colour" is "Colour", as in the Adjust tab.
    var shortToolTitles = false
    /// "Open script" is "Open", with "Back to start" still in full.
    var shortOpen = false
    /// "Back to start" is "Back" and "Open script" is "Open".
    var shortTransport = false
    /// Two rows: the transport and the video-call group above, the picture tools and view options below.
    var twoRows = false
  }
  static let setupWordVariants: [SetupWords] = [
    SetupWords(),
    SetupWords(shortToolTitles: true),
    SetupWords(shortToolTitles: true, shortOpen: true),
    SetupWords(shortToolTitles: true, shortTransport: true),
    SetupWords(viewTitles: false, shortToolTitles: true, shortTransport: true),
    SetupWords(shortToolTitles: true, twoRows: true),
    SetupWords(shortToolTitles: true, shortTransport: true, twoRows: true),
    SetupWords(viewTitles: false, shortToolTitles: true, shortTransport: true, twoRows: true)
  ]
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
  private var meterReserved: Bool { showsMicLevel && !camera.cleanView && (shell.adjustTab == nil || viewport.width >= 1200) }
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
      // The key explains the picture's zebras or false colour, so it needs a picture.
      let keyVisible = exposureKeyEnabled && camera.presentsWithVideo && hasPicture && !camera.cleanView && camera.exposureIsConfigured && !camera.exposureBypassed && !editing && !focusActive
      let stripWidth = MicMeterView.stripWidth(typeScale: meterTypeScale)
      let meterWidth = meterReserved ? stripWidth * meterZoom : 0
      let setup = !shell.reading && !editing && !camera.cleanView && camera.presentsWithVideo
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
      // The current-line band reaches the same distance past the text column on both sides; the backing a little further.
      let bandWidth = max(1, min(regionWidth, regionWidth - 2 * columnInset + 2 * Space.xxl))
      let backingWidth = max(1, min(regionWidth, bandWidth + 2 * ReadingBacking.margin))
      let scriptTopInset = keyVisible && shell.reading ? (36 + Space.md * 2) * controlZoom : 0
      let bottomInset = Self.readingBottomInset + (barOverlays && !focusActive ? max(controlBarHeight, 60 * controlZoom) : 0)
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
              else { CameraPreview(model: camera, presenter: true, hidesExposureAids: shell.reading && !editing) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              // Focus keeps the picture running (a take may be on) but out of sight: no zebras, false colour or guides behind the words.
              .opacity(focusActive ? 0 : 1)
              .task { if startsCamera { camera.start() } }
          }
          if showsScript {
            Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black)
              .opacity(editing ? 1 : Self.backdropOpacity(saved: store.settings.backdropOpacity(withVideo: camera.presentsWithVideo), reduceTransparency: reduceTransparency))
            if !editing && camera.presentsWithVideo && !focusActive {
              ReadingBacking(opacity: reduceTransparency ? 0.96 : 0.93).frame(width: backingWidth).frame(maxHeight: .infinity)
            }
            // A soft band behind the current line and a clear full-width line under it, in the line gap.
            if !editing {
              PresenterReadingLine(settings: store.settings)
                .frame(width: bandWidth)
                .offset(y: scriptTopInset + ScriptTextView.visualGuideY(height: scriptHeight, fraction: guideFraction)
                  - PresenterReadingLine.bandHeight(fontSize: store.settings.fontSize) / 2)
            }
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
                .scaleEffect(x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1)
                .rotationEffect(.degrees(Double(store.settings.rotation))).clipped()
            }
          }
          if keyVisible && shell.reading && !editing {
            Button { keyExpanded.toggle() } label: {
              HStack(spacing: Space.sm) {
                if keyExpanded {
                  if camera.guides.falseColour {
                    HStack(spacing: 0) { ForEach([Color.pink, .red, Color(red: 1, green: 1, blue: 0), .green, .blue], id: \.self) { $0 } }.frame(width: 24, height: 16)
                  } else { PresenterZebraSwatch().frame(width: 24, height: 16) }
                  Text(camera.guides.falseColour ? "False colour off while reading" : "Zebras off while reading")
                } else { Text("Exposure key") }
                Image(systemName: keyExpanded ? "chevron.up" : "chevron.down")
              }.font(.system(size: 15, weight: .semibold))
                .frame(minHeight: ceil(AlphaStyle.minTarget / controlZoom)).padding(.horizontal, Space.sm)
                .background(.black.opacity(0.8), in: Capsule())
            }.buttonStyle(.plain).help(keyExpanded ? "Hide key" : "Show key")
              .accessibilityLabel(keyExpanded ? "Hide key" : "Show key")
              .uiZoom(controlZoom).frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
              .accessibilityIdentifier("presenter-exposure-legend")
              // A reminder on entering reading, then gone: it fades out (or just hides with Reduce Motion).
              .opacity(zebraChipVisible ? 1 : 0).allowsHitTesting(zebraChipVisible).accessibilityHidden(!zebraChipVisible)
              .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: zebraChipVisible)
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
    .onDisappear { quietTask?.cancel(); barTask?.cancel(); zebraChipTask?.cancel() }
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
        ZStack {
          focusHint
          exitPill("Exit Focus · ⌥⌘F", revealed: barRevealed) { focusMode = false }
        }
      }
    }
    .onChange(of: shell.reading && !draft.isEditing, initial: true) { _, reading in
      zebraChipTask?.cancel()
      zebraChipVisible = reading && zebraChipSeconds > 0
      guard zebraChipVisible else { return }
      zebraChipTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(zebraChipSeconds))
        guard !Task.isCancelled else { return }
        zebraChipVisible = false
      }
    }
    .onChange(of: focusActive, initial: true) { _, active in
      focusHintTask?.cancel()
      focusHintVisible = active
      guard active else { return }
      focusHintTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(3.5))
        guard !Task.isCancelled else { return }
        focusHintVisible = false
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

  /// On entering Focus: a small reminder of the way out, which fades after a few seconds.
  private var focusHint: some View {
    Text("Esc to exit").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
      .padding(.horizontal, Space.md).frame(minHeight: 32)
      .background(.black.opacity(0.6), in: Capsule())
      .opacity(focusHintVisible && !barRevealed ? 1 : 0)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: focusHintVisible)
      .padding(Space.xxl).allowsHitTesting(false).accessibilityHidden(true)
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
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlBarHeight = $0 }
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
        }.padding(Space.sm).padding(.top, Space.sm)
      }
      if hasBottomNotice {
        Group { if shell.reading { readingNotice } else { bottomNotice } }.padding(.top, Space.sm)
      }
      if !draft.isEditing {
        if shell.reading { readingBar } else { setupBar }
      }
    }.padding(.horizontal, viewport.width / controlZoom < 900 ? Space.sm : Space.lg)
      // The bar's rows carry their own vertical room, so a two-row bar can keep it tight.
      .padding(.bottom, draft.isEditing ? Space.md : 0).frame(maxWidth: .infinity)
      .background(PresenterBar.background)
      .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
      .buttonStyle(PresenterButtonStyle()).accessibilityIdentifier("presenter-control-bar")
  }

  // MARK: Setup bar

  /// One row: transport on the left, then the video-call group, then the picture tools. The words follow
  /// one rule (`setupWordVariants`, richest first): the first variant that fits shows; two compact rows when
  /// no single row fits; a wrapping layout only in a window too narrow even for that.
  private var setupBar: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(Array(Self.setupWordVariants.enumerated()), id: \.offset) { index, words in
        if words.twoRows { setupRows(words) } else { setupRow(words, spacious: index == 0).padding(.vertical, Space.md) }
      }
      WrapLayout(spacing: Space.sm, leading: true) {
        setupTransport(short: true, snug: true)
        callGroup(snug: true)
        toolsGroup(words: Self.setupWordVariants[Self.setupWordVariants.count - 1])
        viewGroup(titles: false)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Space.md)
    }
  }
  private func setupRow(_ words: SetupWords, spacious: Bool) -> some View {
    HStack(spacing: spacious ? PresenterBar.groupGap : words.snug ? Space.sm : Space.md) {
      HStack(spacing: Space.sm) { setupTransport(short: words.shortTransport, shortOpen: words.shortOpen, snug: words.snug) }
      Spacer(minLength: 0)
      callGroup(snug: words.snug)
      toolsGroup(words: words)
      viewGroup(titles: words.viewTitles)
    }
  }
  /// The second tier for large interface sizes: nothing loses its word, the bar gets taller but stays compact.
  private func setupRows(_ words: SetupWords) -> some View {
    VStack(spacing: Self.compactRowGap) {
      HStack(spacing: Space.md) {
        HStack(spacing: Space.sm) { setupTransport(short: words.shortTransport, shortOpen: words.shortOpen, snug: words.snug) }
        Spacer(minLength: Space.sm)
        callGroup(snug: words.snug)
      }
      // Right-aligned under the groups above, so the one gap sits where the first row's does (under the transport).
      HStack(spacing: Space.md) {
        Spacer(minLength: Space.sm)
        toolsGroup(words: words)
        viewGroup(titles: words.viewTitles)
      }
    }.environment(\.barControlHeight, Self.compactControlHeight(zoom: controlZoom)).padding(.vertical, Space.xs)
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
    Button { shell.reading = true; session.startReading() } label: { BarLabel(title: "Start reading", symbol: "play.fill", snug: snug) }
      .buttonStyle(BarButtonStyle(role: .prominent)).accessibilityLabel("Start reading")
      .help("Start reading (Space)").disabled(!hasScript || draft.isEditing)
    Button { session.restart() } label: { BarLabel(title: short ? "Back" : "Back to start", symbol: "arrow.counterclockwise", snug: snug) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Back to start")
      .help("Back to the first word (Home)").disabled(!hasScript)
    scriptButton(short: short || shortOpen, role: .secondary, snug: snug)
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
      BarDivider()
      BarToggle(title: "Script", symbol: "text.alignleft", isOn: shell.scriptPreview, showsTitle: true, snug: snug,
        help: shell.scriptPreview ? "Hide the script" : "Show the script over the picture") { shell.scriptPreview.toggle() }
        .disabled(!hasScript)
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

  private func toolsGroup(words: SetupWords) -> some View {
    let live = hasPicture
    let snug = words.shortToolTitles
    return BarGroup(label: "Picture tools", raised: false) {
      tool("Zebras", "rectangle.pattern.checkered", tab: .zebras, on: live && camera.effectiveZebras, snug: snug,
           help: live ? "Zebra stripes on the brightest areas (⌥⌘Z). Press and hold to adjust." : "Zebra stripes, once there is a camera picture (⌥⌘Z). Press and hold to adjust.") { toggleExposure(\.zebras) }
        .opacity(live ? 1 : 0.45)
      tool("False colour", "circle.lefthalf.filled", tab: .falseColour, on: live && camera.effectiveFalseColour, shortTitle: "Colour", snug: snug,
           help: live ? "False colour exposure (⌥⌘X). Press and hold to adjust." : "False colour exposure, once there is a camera picture (⌥⌘X). Press and hold to adjust.") { toggleExposure(\.falseColour) }
        .opacity(live ? 1 : 0.45)
      tool("Guides", "squareshape.split.3x3", tab: .guides, on: live && camera.framingIsVisible, snug: snug,
           help: "Framing guides. Press and hold to adjust.") { camera.toggleFramingGuides() }
        .opacity(live ? 1 : 0.45)
      BarDivider()
      tool("Adjust", "slider.horizontal.3", tab: .camera, on: shell.adjustTab != nil, snug: snug, adjustable: false,
           help: "Open the adjust panel", traits: [], value: shell.adjustTab == nil ? "Collapsed" : "Expanded") {
        shell.adjustTab = shell.adjustTab == nil ? .camera : nil
      }
    }
  }

  private func viewGroup(titles: Bool) -> some View {
    BarGroup(label: "View options", raised: false) {
      // Like the picture tools, the key has nothing to explain without a picture: dimmed, never shown as on.
      BarToggle(title: "Key", symbol: "list.bullet.rectangle", isOn: exposureKeyEnabled && hasPicture, showsTitle: titles, displayTitle: "Show key",
        help: exposureKeyEnabled ? "Hide the exposure key: what the zebras and colours mean" : "Show the exposure key: what the zebras and colours mean") { exposureKeyEnabled.toggle() }
        .disabled(!camera.exposureIsConfigured).opacity(hasPicture ? 1 : 0.45)
      BarToggle(title: "Clean", symbol: "rectangle", isOn: false, showsTitle: titles, displayTitle: nil,
                help: "Hide everything but the picture. Move the pointer to bring the controls back (⌥⌘K).", traits: [], value: nil) { camera.cleanView = true }
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

  // MARK: Reading bar

  /// One slim row: a status pill, the transport in the middle, the options on the right. Every control keeps its
  /// word and the Space hint stays. As the window narrows or the interface grows, Open script shortens to Open,
  /// the status shrinks to its short form, then the bar takes two compact rows (status and transport above, the options
  /// below). Only a window too narrow even for that drops the words, and the hint, to icons.
  private var readingBar: some View {
    ViewThatFits(in: .horizontal) {
      readingRow(pill: .full, hint: true).padding(.vertical, Space.sm)
      readingRow(pill: .full, hint: true, openShort: true).padding(.vertical, Space.sm)
      readingRow(pill: .compact, hint: true, openShort: true).padding(.vertical, Space.sm)
      readingRows(pill: .compact, hint: true)
      readingRows(pill: .dot, hint: false)
      readingRow(pill: nil, hint: false, titles: false).padding(.vertical, Space.sm)
    }
  }
  private func readingRow(pill: BarStatusPill.Style?, hint: Bool, titles: Bool = true, openShort: Bool = false) -> some View {
    HStack(spacing: Space.md) {
      // The options keep their full width (a variant only fits if they do), the status takes what is left
      // and the transport sits beside the options; without a status the transport floats in the room.
      if let pill { readingPill(pill).frame(maxWidth: .infinity, alignment: .leading) }
      else { Spacer(minLength: 0) }
      // A variant fits only if the transport keeps its width; the last one has nothing to give up, so it may squeeze.
      HStack(spacing: Space.sm) { readingTransport(titles: true, hint: hint) }.fixedSize(horizontal: pill != nil, vertical: false)
      if pill == nil { Spacer(minLength: Space.md) }
      readingOptions(titles: titles, micTitle: pill != nil, openShort: openShort).fixedSize()
    }
  }
  /// The status and the transport on one row, the options under them: the same words, a taller but compact bar.
  private func readingRows(pill: BarStatusPill.Style, hint: Bool) -> some View {
    VStack(spacing: Self.compactRowGap) {
      HStack(spacing: Space.md) {
        readingPill(pill)
        Spacer(minLength: Space.md)
        HStack(spacing: Space.sm) { readingTransport(titles: true, hint: hint) }
      }
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        readingOptions(titles: true, openShort: true)
      }
    }.environment(\.barControlHeight, Self.compactControlHeight(zoom: controlZoom)).padding(.vertical, Space.xs)
  }
  private func readingPill(_ style: BarStatusPill.Style) -> some View {
    BarStatusPill(text: readingPillText, shortText: readingPillShortText, isActive: session.isActivelyRunning, style: style)
  }
  private func readingOptions(titles: Bool, micTitle: Bool = true, openShort: Bool = false) -> some View {
    BarGroup(label: "Reading options") {
      micControl(titles: micTitle, snug: !titles)
      BarDivider()
      BarToggle(title: "Focus", symbol: "rectangle.expand.vertical", isOn: focusMode, showsTitle: titles,
                help: "Focus: only the text, the level meter and the reading line (⌥⌘F)") { focusMode.toggle() }
        .contextMenu { Toggle("Auto-hide these controls while reading", isOn: $autoHidesBar) }
      Button { settingsTab = .reading; showsSettings = true } label: { BarLabel(title: "Text", symbol: "textformat.size", showsTitle: titles) }
        .buttonStyle(BarButtonStyle()).help("Reading mode, speed and text size").accessibilityLabel("Reading settings")
      editButton(titled: titles)
      scriptButton(short: openShort, titled: titles)
    }
  }
  private var readingPillText: String {
    let state = session.visibleReadingState
    return store.settings.mode == "Voice" ? "Voice · \(state)" : "Automatic · \(Int(store.settings.speed)) wpm · \(state)"
  }
  /// The mode and the state, without the speed: "Voice · Listening" is already that short.
  private var readingPillShortText: String { (store.settings.mode == "Voice" ? "Voice" : "Auto") + " · " + session.visibleReadingState }

  @ViewBuilder private func readingTransport(titles: Bool, hint: Bool = true) -> some View {
    let running = session.isActivelyRunning || session.isCountingDown
    Button { session.restart() } label: { BarLabel(title: "Restart", symbol: "arrow.counterclockwise", showsTitle: titles) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Back to start").help("Back to the first word (Home)")
    Button { session.toggle() } label: {
      HStack(spacing: Space.sm) {
        BarLabel(title: running ? "Pause" : "Start reading", symbol: running ? "pause.fill" : "play.fill")
        if running && hint { KeyCap(text: "Space").padding(.trailing, Space.md) }
      }
    }.buttonStyle(BarButtonStyle(role: running ? .secondary : .prominent))
      .accessibilityLabel(running ? "Pause" : "Start reading").help((running ? "Pause" : "Start reading") + " (Space)")
    // Leaves reading for the setup screen (camera, picture tools, levels): named, since an icon alone read as a display setting.
    Button { session.pause(); shell.reading = false } label: { BarLabel(title: "Set up", symbol: "camera.viewfinder", showsTitle: titles) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Set up the shot")
      .help("Back to setting up the shot: camera, picture tools and microphone (Esc)")
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
      overVideo: overVideo, showCues: settings.showCues, highlightActiveWord: settings.highlightActiveWord,
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
