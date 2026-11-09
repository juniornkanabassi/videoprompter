import AppKit
import SwiftUI
import PrompterCore

struct PresenterView: View {
  @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
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
  private var sourceInfo: CameraSourceInfo? { sourceInfoOverride ?? camera.sourceInfo }

  init(store: AppStore, session: SessionStore, draft: PresenterDraft, hasScript: Bool = true,
       camera: CameraModel = .shared, monitor: ReferenceMonitor = .shared, startsCamera: Bool = true, recorder: CameraRecorder = .shared, shell: PresenterShell? = nil, referencePicture: NSImage? = nil, revealsCleanExit: Bool = false, sourceInfoOverride: CameraSourceInfo? = nil) {
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
    self.recorder = recorder
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
  @AppStorage("presenterMicLevel") private var showsMicLevel = true
  @State private var settingsTab = SettingsTab.reading
  @FocusState private var cleanExitFocused: Bool
  static func backdropOpacity(saved: Double, reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : saved }
  // Interface size applies to the entire shell, with named controls wrapping as needed.
  static func controlZoom(_ zoom: Double) -> Double { zoom }
  private var controlZoom: Double { Self.controlZoom(store.uiZoom) }
  @State private var stageWidth: CGFloat = 1600
  @State private var viewport = CGSize(width: 1600, height: 1000)
  @State private var showsExposureKey = false
  private var barFit: PresenterBarFit { PresenterBarFit(size: viewport, zoom: controlZoom) }
  private var narrowReading: Bool { shell.reading && viewport.width / controlZoom < 480 }
  private var compactReading: Bool { shell.reading && stageWidth / controlZoom < 700 }
  @ObservedObject private var recorder: CameraRecorder
  /// False in Video only, unless a draft was already open: it must stay reachable to finish or cancel.
  private var showsScript: Bool { !camera.cleanView && hasScript && (shell.reading || draft.isEditing) }
  private var stage: some View { readingStage }
  private var readingStage: some View {
    GeometryReader { geometry in
      let keyVisible = exposureKeyEnabled && camera.presentsWithVideo && !camera.cleanView && camera.exposureIsConfigured && !camera.exposureBypassed
      let meterWidth = micLevelVisible ? 120 * controlZoom : 0
      let setup = !shell.reading && !draft.isEditing && !camera.cleanView && camera.presentsWithVideo
      let pictureSize = referencePicture?.size ?? camera.pictureSize ?? CGSize(width: 16, height: 9)
      let pictureAspect = referencePicture != nil ? pictureSize.width / max(1, pictureSize.height) :
        (camera.guides.rotation.swapsAxes ? pictureSize.height / max(1, pictureSize.width) : pictureSize.width / max(1, pictureSize.height))
      let pictureWidth = min(geometry.size.width, geometry.size.height * pictureAspect)
      let availableGutter = (geometry.size.width - pictureWidth) / 2
      let keyFits = setup && availableGutter >= (280 * controlZoom + Space.md * 2) && geometry.size.height >= (camera.guides.falseColour ? 520 : 180) * controlZoom + Space.md * 2
      let columnWidth = (keyFits ? 280 : 144) * controlZoom + Space.md * 2
      let gutterWidth = setup ? max(meterWidth, min(columnWidth, pictureAspect > 1 ? geometry.size.width * 0.25 : columnWidth)) : 0
      HStack(alignment: .top, spacing: 0) {
        if setup {
          ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: Space.md) {
            if keyVisible {
          Group {
            if keyFits { ExposureKey(guides: camera.guides, compact: false, zoom: controlZoom).fixedSize(horizontal: false, vertical: true) }
            else {
              Button { showsExposureKey = true } label: {
                Label("Exposure key", systemImage: "list.bullet.rectangle")
                  .font(.system(size: 14, weight: .semibold)).frame(minHeight: 44 / controlZoom) // uiZoom scales it back to a 44 pt target
              }.buttonStyle(.plain).uiZoom(controlZoom)
            }
          }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .contain).accessibilityIdentifier("presenter-exposure-legend")
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
              .opacity(Self.backdropOpacity(saved: store.settings.backdropOpacity(withVideo: camera.presentsWithVideo), reduceTransparency: reduceTransparency))
            Group {
              if draft.isEditing {
                GeometryReader { editor in
                  PresenterEditorView(session: session, draft: draft, settings: store.settings,
                    sideInset: ScriptTextView.sideInset(width: editor.size.width, textWidth: store.settings.textWidth)) {
                      editorNotice = "That change could not be applied safely. Your text is unchanged. Try a smaller selection."
                    }
                }
              } else {
                PresenterScriptView(session: session, settings: store.settings,
                  sideInset: ScriptTextView.sideInset(width: geometry.size.width - meterWidth, textWidth: store.settings.textWidth),
                  overVideo: camera.presentsWithVideo,
                  topInset: keyVisible && shell.reading ? (36 + Space.md * 2) * controlZoom : 0)
              }
            }.scaleEffect(x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1)
              .rotationEffect(.degrees(Double(store.settings.rotation))).clipped()
            GuideLine(settings: store.settings).offset(y: ScriptTextView.visualGuideY(height: geometry.size.height, fraction: store.settings.guideFraction))
          }
          if keyVisible && shell.reading && !draft.isEditing {
            HStack(spacing: Space.sm) {
              if camera.guides.falseColour {
                HStack(spacing: 0) { ForEach([Color.pink, .red, Color(red: 1, green: 1, blue: 0), .green, .blue], id: \.self) { $0 } }.frame(width: 24, height: 16)
              } else { PresenterZebraSwatch().frame(width: 24, height: 16) }
              Text(camera.guides.falseColour ? "False colour on" : "Zebras on")
            }
              .font(.system(size: 15, weight: .semibold)).padding(Space.sm)
              .background(.black.opacity(0.8), in: Capsule()).uiZoom(controlZoom)
              .frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
              .accessibilityIdentifier("presenter-exposure-legend")
          }
          if referencePicture == nil && camera.presentsWithVideo && camera.needsRecovery && !showsScript && !camera.cleanView {
            CameraRecoveryView(model: camera) { shell.adjustTab = .camera }.uiZoom(controlZoom).padding(Space.md)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          }
          if !hasScript, camera.displayMode != .videoOnly, !camera.cleanView {
            Text("No script yet. Choose one in the library, then open the prompter.")
              .font(.title3).multilineTextAlignment(.center).padding(Space.lg)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-picture-region")
        if setup { Color.clear.frame(width: max(0, gutterWidth - meterWidth)) }
        if micLevelVisible {
          MicMeterView(meter: recorder.inputMeter, micName: recorder.microphoneName)
            .frame(width: 120, height: max(0, geometry.size.height / controlZoom - 32)).uiZoom(controlZoom)
            .frame(width: meterWidth).padding(.vertical, Space.md)
        }
      }.foregroundStyle(.white)
        .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-visible-stage")
    }.background(camera.cleanView ? Color.black : Color(white: 0.035))
      .onChange(of: exposureKeyEnabled) { _, enabled in if !enabled { showsExposureKey = false } }
      .popover(isPresented: $showsExposureKey) {
        ScrollView { ExposureKey(guides: camera.guides, compact: false, zoom: controlZoom).padding(Space.md) }
          .frame(width: min(viewport.width, 360 * controlZoom), height: min(viewport.height * 0.8, 640 * controlZoom)) // grid: ok Keep the popover within the available height.
      }
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

  private var sourceStatus: some View {
    Button { adjustOpener = "Camera"; shell.adjustTab = .camera } label: {
      VStack(alignment: .leading, spacing: Space.xs) {
        sourcePill(parts: sourceInfo.map { [$0.displayName, $0.connectionDescription] } ?? ["No camera chosen"])
        if let format = sourceInfo?.videoFormat { sourcePill(parts: [format], singleLine: true) }
        sourcePill(parts: [shotLabel])
      }.font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }.buttonStyle(.plain).uiZoom(controlZoom)
  }
  private func sourcePill(parts: [String], singleLine: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
        Text(part).lineLimit(singleLine ? 1 : nil).minimumScaleFactor(singleLine ? 0.6 : 1)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
      .padding(Space.sm)
      .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: Space.md))
  }

  private var shotBadge: String {
    if camera.guides.automaticRotation { return "Auto" }
    switch camera.guides.rotation {
    case .none: return "Landscape"
    case .quarter: return "↺ Vertical"
    case .threeQuarters: return "↻ Vertical"
    case .half: return "Upside down"
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

  private var micLevelVisible: Bool { showsMicLevel && !camera.cleanView && (shell.adjustTab == nil || viewport.width >= 1200) }
  private var trackedStage: some View {
    stage
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stageWidth = $0 }
    // Between takes the meter listens through the recording microphone's test; a take feeds it itself.
    .task(id: [micLevelVisible && startsCamera, recorder.isRecording || recorder.isBusy]) {
      guard micLevelVisible && startsCamera else { if recorder.isTestingInput { recorder.stopInputTest() }; return }
      if !recorder.isRecording && !recorder.isBusy { await recorder.startInputTest() }
    }
    .onChange(of: store.settings) { _, value in
      session.updateSettings(value)
      recorder.useSettings(value)
    }
    .onReceive(session.$isPreparingVoice.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onReceive(session.$hasLiveRecognition.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onReceive(session.$manualCompleted.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onChange(of: session.isActivelyRunning) { _, active in if active && !camera.cleanView { shell.reading = true } }
    .onReceive(NotificationCenter.default.publisher(for: .init("VideoPrompter.presenterInteraction"))) { _ in revealControls() }
    .onDisappear { quietTask?.cancel() }
    .onChange(of: camera.cleanView) { _, clean in
      if clean { shell.cleanEntered(session: session); showsReadingNotice = false; showsSettings = false; showsExposureKey = false }
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
      if shell.escape(camera: camera, session: session) {}
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
        Button { camera.cleanView = false } label: {
          Label("Exit Clean · Esc", systemImage: "xmark")
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, Space.md).frame(minHeight: 44)
            .background(.black.opacity(0.85), in: Capsule()).foregroundStyle(.white)
            .opacity(cleanControlsRevealed || cleanExitFocused || revealsCleanExit ? 1 : 0)
        }.buttonStyle(.plain).accessibilityLabel("Exit Clean · Esc")
          .focused($cleanExitFocused).padding(Space.xxl)
      }
    }
    .onContinuousHover { phase in
      if camera.cleanView, case .active = phase { revealControls() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if showsChrome { controlBar.environment(\.colorScheme, .dark) }
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

  private var controlBar: some View {
    barContent.environment(\.colorScheme, .dark)
      .uiZoom(controlZoom).fixedSize(horizontal: false, vertical: true)
  }

  private func revealControls() {
    guard camera.cleanView else { return }
    cleanControlsRevealed = true
    quietTask?.cancel()
    quietTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      cleanControlsRevealed = false
    }
  }
  private var barContent: some View {
    VStack(spacing: Space.sm) {
      if draft.isEditing {
        Text("Editing · not saved yet").font(.system(size: 15)).foregroundStyle(.white)
        HStack {
          transportButton(compactEditing ? "Save" : "Save changes", icon: "checkmark", primary: true) { Task { await draft.confirm(store: store) } }.accessibilityLabel("Save changes").keyboardShortcut(.return, modifiers: .command).disabled(draft.isSaving)
          transportButton(compactEditing ? "Cancel" : "Cancel editing", icon: "xmark") { draft.requestCancel() }.accessibilityLabel("Cancel editing").disabled(draft.isSaving)
        }.frame(minHeight: 44)
      }
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
      if shell.reading {
        if narrowReading {
          ScrollView(.horizontal) { HStack(spacing: Space.md) { readingTransport } }
            .scrollIndicators(.hidden).frame(height: 44)
        } else {
          HStack(spacing: Space.md) { Spacer(minLength: 0); readingTransport; Spacer(minLength: 0) }
        }
        ViewThatFits(in: .horizontal) {
          HStack { readingStatus; readingSettings; keyboardHint }
          VStack(spacing: Space.xs) { HStack { readingStatus; readingSettings }; keyboardHint }
        }
      } else if barFit.twoRows {
        HStack(spacing: Space.sm) { setupTransport }
        HStack(spacing: Space.sm) { setupTiles }
      } else {
        HStack(spacing: Space.md) { setupTransport; Spacer(minLength: 0); setupTiles }
      }
      }
    }.padding(narrowReading ? Space.xs : Space.md).frame(maxWidth: .infinity)
      .background(Color(nsColor: NSColor(white: 0.08, alpha: 1)))
      .buttonStyle(PresenterButtonStyle()).accessibilityIdentifier("presenter-control-bar")
  }

  @ViewBuilder private var setupTransport: some View {
    transportButton("Start reading", icon: "play.fill", primary: true) { shell.reading = true; session.startReading() }.disabled(!hasScript || draft.isEditing)
    transportButton("Back to start", icon: "arrow.counterclockwise") { session.restart() }.disabled(!hasScript)
  }
  @ViewBuilder private var readingTransport: some View {
    transportButton("Back to start", icon: "arrow.counterclockwise") { session.restart() }
    transportButton(session.isActivelyRunning || session.isCountingDown ? "Pause" : "Start reading", icon: session.isActivelyRunning || session.isCountingDown ? "pause.fill" : "play.fill", primary: true) { session.toggle() }
    transportButton("Set up the shot", icon: "display") { session.pause(); shell.reading = false }
  }
  private var readingStatus: some View {
    Text(store.settings.mode == "Voice" ? "Voice follow · \(session.isActivelyRunning ? "Listening" : "Paused")" : "Automatic scroll · \(Int(store.settings.speed)) wpm · \(session.isActivelyRunning ? "Running" : "Paused")")
      .font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
  }
  private var keyboardHint: some View {
    Text("Space: pause or resume · Esc: set up the shot").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
      .fixedSize(horizontal: false, vertical: true)
  }
  private var readingSettings: some View {
    Button("Reading settings") { settingsTab = .reading; showsSettings = true }.buttonStyle(.plain)
      .font(.system(size: 14, weight: .semibold)).frame(minHeight: 44)
  }
  @ViewBuilder private var setupTiles: some View {
    shellTile("Camera", "video", tab: .camera, value: shotBadge) { shell.adjustTab = .camera }
    shellTile("Zebras", "rectangle.pattern.checkered", tab: .zebras, on: camera.effectiveZebras, value: zebraDetail) { toggleExposure(\.zebras) }
    shellTile("False colour", "circle.lefthalf.filled", tab: .falseColour, on: camera.effectiveFalseColour) { toggleExposure(\.falseColour) }
    if !barFit.movesTools {
      shellTile("Guides", "squareshape.split.3x3", tab: .guides, on: camera.framingIsVisible) { camera.toggleFramingGuides() }
      shellTile("Mic", "mic", tab: .mic, on: showsMicLevel) { showsMicLevel.toggle() }
      Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 72)
    }
    shellTile("Adjust", "slider.horizontal.3", tab: .camera, on: shell.adjustTab != nil, value: barFit.movesTools ? "2 more" : nil) { shell.adjustTab = shell.adjustTab == nil ? .camera : nil }
    shellTile("Clean", "rectangle", tab: .camera) { camera.cleanView = true }
  }
  private func toggleExposure(_ key: WritableKeyPath<CameraGuides, Bool>) {
    let enabled = camera.exposureBinding(key).wrappedValue
    camera.exposureBinding(key).wrappedValue = !enabled
  }

  private var compactEditing: Bool { draft.isEditing && viewport.width / controlZoom < 700 }

  private func transportButton(_ title: String, icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: icon).font(.system(size: compactEditing ? 18 : (primary ? 22 : (compactReading ? 16 : 18)), weight: primary ? .bold : .semibold))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, draft.isEditing ? Space.md : Space.sm)
        .frame(minWidth: shell.reading && primary ? (compactReading ? 160 : 240) : (compactEditing || compactReading ? 0 : barFit.transportWidth),
               maxWidth: shell.reading ? (primary ? (compactReading ? 160 : 240) : (compactReading ? 140 : 192)) : nil, minHeight: compactEditing ? 44 : (shell.reading ? (narrowReading ? 44 : 56) : barFit.transportHeight))
        .foregroundStyle(primary ? AlphaStyle.onAccent : .white)
        .background(primary ? AlphaStyle.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }.buttonStyle(.plain).accessibilityLabel(title)
      .fixedSize(horizontal: narrowReading, vertical: false)
  }

  private func shellTile(_ title: String, _ symbol: String, tab: AdjustTab, on: Bool? = nil, value: String? = nil, action: @escaping () -> Void) -> some View {
    Button { adjustOpener = title; action() } label: {
      VStack(spacing: Space.xs) {
        Text(value ?? " ").font(.system(size: 13, weight: .semibold)).foregroundStyle(AlphaStyle.accent)
          .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
          .padding(.leading, on == true ? 24 : 0).frame(height: 16).accessibilityHidden(true)
        Group {
          if title == "Zebras" { PresenterZebraSwatch().frame(width: 24, height: 24) }
          else { Image(systemName: symbol).font(.system(size: 24)) }
        }.frame(height: 28)
        Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
          .multilineTextAlignment(.center).padding(.horizontal, Space.xs)
          .frame(minHeight: 24)
      }.frame(width: barFit.tileWidth, height: barFit.tileHeight)
        .overlay(alignment: .topLeading) { if on == true { Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(AlphaStyle.accent).padding(Space.sm) } }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on == true ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
    }.buttonStyle(.plain).restoringPopoverFocus(isPresented: Binding(get: { shell.adjustTab != nil && adjustOpener == title }, set: { if !$0 { shell.adjustTab = nil } }), identifier: "adjust-opener-\(title)").accessibilityLabel(title)
      .accessibilityValue(title == "Adjust" ? (shell.adjustTab == nil ? "Collapsed" : "Expanded") : on.map { $0 ? "On" : "Off" } ?? (title == "Camera" ? "\(sourceInfo?.displayName ?? "No camera chosen"), \(shotLabel)" : value ?? ""))
      .accessibilityAddTraits(on != nil && title != "Adjust" ? .isToggle : [])
      .contextMenu { if title != "Clean" && title != "Adjust" { Button("Adjust \(title)") { adjustOpener = title; shell.adjustTab = tab } } }
      .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in if title != "Clean" && title != "Adjust" { adjustOpener = title; shell.adjustTab = tab } })
  }

  private var zebraDetail: String {
    camera.guides.zebraRange == 0 ? "\(camera.guides.zebraLevel)+" : "\(camera.guides.zebraLevel) ±\(camera.guides.zebraRange)"
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

/// The reading line across the presenter, drawn over the video too.
struct GuideLine: View {
  let settings: PrompterSettings
  var body: some View {
    HStack {
      Rectangle().frame(width: 12, height: 3) // grid: ok Thin optical reading-line marker, not control spacing.
      Spacer()
      Rectangle().frame(width: 12, height: 3) // grid: ok Thin optical reading-line marker, not control spacing.
    }.foregroundStyle(.cyan.opacity(settings.guideOpacity)).allowsHitTesting(false).accessibilityHidden(true)
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

/// Fit in this order: full row, narrower row, secondary tools in Adjust, then two rows.
struct PresenterBarFit {
  let movesTools: Bool
  let twoRows: Bool
  let tileWidth: CGFloat
  let tileHeight: CGFloat
  let transportWidth: CGFloat
  let transportHeight: CGFloat
  init(size: CGSize, zoom: Double) {
    let width = size.width / zoom - 32
    if width >= 1260 {
      movesTools = false; twoRows = false; tileWidth = 104; tileHeight = 112; transportWidth = 190; transportHeight = 112
    } else if width >= 1100 {
      movesTools = false; twoRows = false; tileWidth = 88; tileHeight = 112; transportWidth = 160; transportHeight = 112
    } else {
      movesTools = true; twoRows = width < 844
      tileWidth = twoRows ? max(80, min(104, (width - 32) / 5)) : 88
      let short = size.height / zoom < 440
      tileHeight = short ? 88 : 112
      transportHeight = twoRows ? (short ? 44 : 56) : tileHeight
      transportWidth = 160
    }
  }
}

private struct PresenterZebraSwatch: View {
  var body: some View {
    Canvas { context, size in
      var stripes = Path()
      for x in stride(from: -size.height, through: size.width, by: 8) {
        stripes.move(to: CGPoint(x: x, y: 0))
        stripes.addLine(to: CGPoint(x: x + size.height, y: size.height))
      }
      context.stroke(stripes, with: .color(.white), lineWidth: 4)
    }.clipShape(RoundedRectangle(cornerRadius: 4))
      .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.6)))
  }
}
