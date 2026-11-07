import AppKit
import SwiftUI
import PrompterCore

struct PresenterView: View {
  @Environment(\.openSettings) private var openSettings
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
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
  @State private var awayFromStart = false
  @State private var editorNotice: String?
  @State private var showsCameraOptions = false
  @State private var cameraSection = "Camera"
  @State private var pointerOverControls = false
  @State private var controlsQuiet = false
  @State private var quietTask: Task<Void, Never>?
  @State private var showsSettings = false
  @State private var showsReadingControls = false
  @State private var showsCameraControls = false
  @State private var showsCameraRecovery = false
  @State private var showsRecordingStatus = false
  @State private var showsLastTake = false
  @State private var showsTools = false
  @State private var selectedToolSection: String?
  @State private var openedFromPicture = false
  @State private var showsHelp = false
  @State private var overflowTool: String?
  @Environment(\.openWindow) private var openWindow
  @State private var settingsTab = SettingsTab.reading
  @FocusState private var focusedTool: String?
  @Environment(\.undoManager) private var undoManager
  private var isTaking: Bool { session.isActivelyRunning || recorder.isRecording || recorder.isBusy }
  private var showsSetup: Bool { !isTaking || draft.isEditing }
  static func backdropOpacity(saved: Double, reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : saved }
  @State private var presenterWidth: CGFloat = 1000
  // Keep the requested size; the transport stays fixed and Tools holds secondary actions.
  static func controlZoom(_ zoom: Double) -> Double { zoom }
  private var controlZoom: Double { Self.controlZoom(store.uiZoom) }
  private var compactControls: Bool { presenterWidth / controlZoom < 720 }
  private var popoverHeight: CGFloat { min(600, (controller.panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? 600) - 80 }
  @ObservedObject private var recorder: CameraRecorder
  /// The picker's fixed slot: a long camera name truncates instead of widening the bar.
  static let cameraPickerWidth: CGFloat = 120
  /// False in Video only, unless a draft was already open: it must stay reachable to finish or cancel.
  private var showsScript: Bool { !camera.cleanView && hasScript && (camera.displayMode != .videoOnly || draft.isEditing) }
  private var stage: some View {
    VStack(spacing: 0) {
      readingStage
      if camera.presentsWithVideo && !camera.cleanView && camera.exposureIsConfigured && !camera.exposureBypassed {
        ExposureLegend(model: camera, zoom: controlZoom)
          .frame(maxWidth: .infinity).background(Surfaces.presenterPanel)
          .accessibilityIdentifier("presenter-exposure-strip")
      }
    }
  }
  private var readingStage: some View {
    GeometryReader { geometry in
      let sideInset = ScriptTextView.sideInset(width: geometry.size.width, textWidth: store.settings.textWidth)
      ZStack(alignment: .top) {
        if camera.presentsWithVideo {
          // The live picture is the bottom layer only. The background colour above it is the
          // script's backdrop, so colour, opacity, guide line, mirror, rotation and in-place
          // editing all keep working exactly as they do without video.
          CameraPreview(model: camera, presenter: true)
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
        if camera.presentsWithVideo && camera.needsRecovery && !showsScript {
          CameraRecoveryView(model: camera) { showsCameraControls = true }
            .uiZoom(controlZoom).padding(Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .environment(\.colorScheme, .dark)
        }
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
    .onReceive(session.$isPreparingVoice.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onReceive(session.$hasLiveRecognition.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onReceive(session.$manualCompleted.removeDuplicates().dropFirst()) { _ in presentation.objectWillChange.send() }
    .onReceive(session.$countdownRemaining.removeDuplicates()) { countdown = $0 }
    .onReceive(session.$tokenIndex.map { $0 > 0 }.removeDuplicates()) { awayFromStart = $0 }
    .onChange(of: session.isActivelyRunning) { _, _ in revealControls() }
    .onChange(of: recorder.phase) { _, _ in revealControls() }
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
      if showsLastTake { showsLastTake = false }
      else if showsHelp { showsHelp = false }
      else if showsReadingControls { showsReadingControls = false }
      else if showsCameraRecovery { showsCameraRecovery = false }
      else if showsCameraControls { showsCameraControls = false }
      else if showsTools { showsTools = false }
      else if showsSettings { showsSettings = false }
      else if overflowTool != nil { overflowTool = nil }
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
    Group {
      if reduceTransparency { barContent }
      else { GlassEffectContainer { barContent } }
    }.environment(\.colorScheme, .dark)
      .uiZoom(controlZoom).fixedSize(horizontal: false, vertical: true)
      .onHover { pointerOverControls = $0; revealControls() }
      .simultaneousGesture(TapGesture().onEnded { revealControls() })
      .popover(isPresented: Binding(get: { hasOpenPopover }, set: { if !$0 { dismissPopover() } })) {
        PresenterPopoverSurface(scheme: scheme) {
          if showsReadingControls {
            if hasBottomNotice { bottomNotice } else { readingControls }
          } else if showsHelp { PresenterHelp().uiZoom(controlZoom)
          } else if overflowTool == "Output" { outputControls
          } else if showsSettings {
            PresenterSettingsPopover(store: store, initialTab: settingsTab, initialCameraSection: cameraSection)
          } else if showsLastTake {
            lastTakeControls
          } else if showsRecordingStatus {
            RecordingStatusPanel(recorder: recorder, camera: camera, zoom: controlZoom) { showsRecordingStatus = false }.frame(width: 440, height: popoverHeight)
          } else if showsCameraRecovery {
            CameraRecoveryView(model: camera) {
              showsCameraRecovery = false; showsCameraControls = true
            }.padding(Space.md).uiZoom(controlZoom).environment(\.colorScheme, .dark)
          } else if showsCameraControls { cameraControls }
          else if overflowTool == "Microphone" { microphoneControls }
          else if overflowTool == "Guides" { guideControls }
          else if overflowTool == "Camera" { cameraControls }
          else { toolsSurface }
        }.popoverEntryFocus()
      }
  }

  private func dismissPopover() {
    showsReadingControls = false; showsSettings = false; showsRecordingStatus = false; showsLastTake = false
    showsCameraRecovery = false; showsCameraControls = false; overflowTool = nil; showsTools = false; showsHelp = false
  }

  private var microphoneControls: some View {
    MicrophonePage(store: store, compact: true, startsMeter: startsCamera, recorder: recorder).uiZoom(controlZoom)
      .frame(width: 500).fixedSize(horizontal: false, vertical: true).modifier(PresenterControlViewport(maxHeight: popoverHeight))
  }
  private var guideControls: some View {
    CameraGuideSettings(model: camera).uiZoom(controlZoom).frame(width: 500).fixedSize(horizontal: false, vertical: true).modifier(PresenterControlViewport(maxHeight: popoverHeight))
  }
  private var hasOpenPopover: Bool {
    overflowTool != nil || showsLastTake || showsRecordingStatus || showsSettings || showsReadingControls || showsCameraControls || showsCameraRecovery
      || showsTools || showsHelp
  }
  private func revealControls() {
    controlsQuiet = false
    quietTask?.cancel()
    guard isTaking else { return }
    quietTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      controlsQuiet = true
    }
  }
  private var secondaryOpacity: Double {
    controlsQuiet && !pointerOverControls && focusedTool == nil && !hasOpenPopover ? Palette.quietOpacity(contrast) : 1
  }
  private var showsReceipt: Bool { !recorder.receiptHidden && !recorder.isRecording && !recorder.isBusy && (recorder.savedTake != nil || recorder.takeFailure != nil) }
  /// A clean saved take keeps the Picture row and opens its receipt from a compact opener; problems stay prominent.
  private var showsCompactReceipt: Bool { showsReceipt && camera.presentsWithVideo && recorder.savedTake != nil && recorder.qualityWarning == nil }
  private var barContent: some View {
    VStack(spacing: 0) {
      transport
      HStack(alignment: .center, spacing: Space.sm) {
        if hasScript && camera.displayMode != .videoOnly {
          Button { showsReadingControls.toggle() } label: {
            HStack(spacing: Space.xs) {
              if hasBottomNotice { Image(systemName: "exclamationmark.triangle.fill") }
              readingStatusLabel
              Image(systemName: "chevron.down").imageScale(.small)
            }.frame(minHeight: 24).contentShape(Rectangle())
          }.buttonStyle(.plain).foregroundStyle(hasBottomNotice ? Color.orange : Color.primary).accessibilityLabel(hasBottomNotice ? "Check reading…" : "Reading status")
            .accessibilityValue(readingStatusTitle).help("Change reading mode and speed")
            .restoringPopoverFocus(isPresented: $showsReadingControls, identifier: "presenter-reading-status")
            // Sized after the output check but before the spacer, so it only wraps when it must.
            .layoutPriority(0.5)
        }
        if !hasScript || camera.displayMode == .videoOnly { Text("Camera view").fontWeight(.semibold) }
        Spacer(minLength: Space.sm)
        if camera.presentsWithVideo || recorder.isRecording || recorder.isBusy { recordingStateControl }
        moreMenu
      }.font(.body)
        .accessibilityIdentifier("presenter-state-band")
      Group {
        if camera.cleanView {
          Button("Exit clean view") { camera.cleanView = false }
            .help("Show the script and overlays again (⌥⌘K)")
        } else if let error = store.shootSetupError {
          HStack(spacing: Space.sm) {
            Button("Check shoot setup") { showsTools = false; openPresenterSettings(.shootSetups) }
              .help(error).accessibilityValue(error)
            Button("Hide") { store.shootSetupError = nil }.help("Hide shoot setup message")
          }
        } else if showsReceipt && !showsCompactReceipt { receipt }
        else if camera.presentsWithVideo { pictureRow }
      }.opacity(secondaryOpacity)
        .accessibilityIdentifier("presenter-context-band")
    }.padding(.horizontal, Space.sm).frame(maxWidth: .infinity)
      .modifier(PresenterGlass(radius: 20))
      .buttonStyle(PresenterButtonStyle()).font(.body).symbolRenderingMode(.hierarchical)
      .accessibilityIdentifier("presenter-control-bar")
  }

  var recordingStateTitle: String {
    if recorder.isRecording { return String(format: "REC %02d:%02d", Int(recorder.recordedDuration) / 60, Int(recorder.recordedDuration) % 60) }
    if recorder.isBusy { return recorder.phase == .saving ? "Saving…" : "Starting…" }
    if !camera.isReadyToRecord { return "Camera unavailable" }
    guard camera.pictureSize != nil else { return "Waiting for picture" }
    return "Ready · " + recorder.compactOutputConfirmation(camera: camera)
  }
  /// Neutral camera status recedes; active recording and recovery retain emphasis.
  private var recordingStateText: Text {
    Text(recordingStateTitle)
      .fontWeight(recorder.isRecording || recorder.isBusy || !camera.isReadyToRecord ? .semibold : .regular)
  }
  private func recordingAccessibilityValue(sound: String) -> String {
    if recorder.isRecording { return recordingStateTitle + " · " + sound }
    if camera.isReadyToRecord && camera.pictureSize != nil {
      return recordingStateTitle + " · " + recorder.preRecordConfirmation(camera: camera)
    }
    return recordingStateTitle
  }
  private var recordHelp: String {
    if recorder.isRecording { return "Stop recording and save the take (⇧⌘R)" }
    if recorder.isBusy { return "Recording is starting or saving" }
    if camera.isReadyToRecord { return "Record a take. Reading starts separately. " + recorder.preRecordConfirmation(camera: camera) }
    return camera.recordingBlockReason
  }

  private var recordingStateControl: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
      let health = RecordingHealth.measured(lastAudibleSampleAt: recorder.inputMeter.lastAudibleSampleAt,
        clipping: recorder.inputMeter.isClipping && recorder.inputMeter.isFresh())
      let problem = recorder.isRecording && (recorder.droppedAudioBuffers > 0 || health == .silence || health == .clipping)
      let sound = problem ? "Check microphone" : health.message
      let value = recordingAccessibilityValue(sound: sound)
      Button {
        if recorder.isRecording || recorder.isBusy { showsRecordingStatus = true }
        else if !camera.isReadyToRecord { showsCameraRecovery = true }
        else { overflowTool = "Output" }
      } label: {
        HStack(spacing: Space.xs) {
          if problem || (!camera.isReadyToRecord && !recorder.isBusy && !recorder.isRecording) {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.xs) {
              if recorder.isRecording { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
              recordingStateText.monospacedDigit().fixedSize(horizontal: false, vertical: true)
              if recorder.isRecording { RecordingBarLevel(meter: recorder.inputMeter, compact: true).frame(width: 12) }
            }
            if recorder.isRecording {
              Text(sound).font(.callout).fixedSize(horizontal: true, vertical: false)
            }
          }
          Image(systemName: "chevron.right").imageScale(.small)
        }.frame(minHeight: 24).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .font(recorder.isRecording || recorder.isBusy || !camera.isReadyToRecord ? .body : .callout)
        // The output check is sized first so it only wraps when the band truly cannot hold it.
        .layoutPriority(1)
        .foregroundStyle(problem || (!camera.isReadyToRecord && !recorder.isBusy && !recorder.isRecording) ? Color.orange : (recorder.isRecording || recorder.isBusy ? Color.primary : Palette.onDarkQuiet(contrast)))
        .accessibilityLabel("Recording status")
        .accessibilityValue(value)
        .accessibilityChildren {
          if recorder.isRecording { RecordingBarLevel(meter: recorder.inputMeter, compact: true) }
        }
        .accessibilityHint(recorder.preRecordConfirmation(camera: camera))
        .help(recorder.isRecording ? "Check recording and microphone" : recorder.preRecordConfirmation(camera: camera))
        .restoringPopoverFocus(isPresented: Binding(get: { showsRecordingStatus || showsCameraRecovery || overflowTool == "Output" }, set: { if !$0 { showsRecordingStatus = false; showsCameraRecovery = false; overflowTool = nil } }), identifier: "presenter-recording-status")
    }
  }

  @ViewBuilder private var lastTakeControls: some View {
    if recorder.savedTake != nil || (!recorder.isRecording && !recorder.isBusy && recorder.takeFailure != nil) {
      RecordingReceipt(recorder: recorder, camera: camera, zoom: controlZoom).padding(Space.md).uiZoom(controlZoom)
    } else if let file = recorder.lastFile {
      VStack(alignment: .leading, spacing: Space.sm) {
        Text(file.lastPathComponent).font(.headline).fixedSize(horizontal: false, vertical: true)
        Text(CameraRecorder.durationText(recorder.lastTakeDuration)).monospacedDigit()
        Button("Play") { NSWorkspace.shared.open(file) }.initialPopoverFocus()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
      }.padding(Space.md).frame(width: 360).uiZoom(controlZoom)
    }
  }

  private var receipt: some View {
    RecordingReceipt(recorder: recorder, camera: camera, configure: {
      settingsTab = recorder.recovery == .microphone ? .microphone : .camera
      cameraSection = recorder.recovery == .format ? "Recording" : "Camera"
      showsSettings = true
    }, zoom: controlZoom, compact: true)
    .layoutPriority(1)
  }

  private var transport: some View {
    HStack(spacing: Space.sm) {
      if !hasScript || camera.displayMode == .videoOnly {
        Spacer()
      }
      if draft.isEditing {
        Button("Save changes") { Task { await draft.confirm(store: store) } }
          .keyboardShortcut(.return, modifiers: .command).disabled(draft.isSaving)
          .help("Save the edited script (⌘↩)")
        Button("Cancel editing") { draft.requestCancel() }.disabled(draft.isSaving)
          .help("Discard the edit and keep the saved script")
      } else if hasScript && camera.displayMode != .videoOnly {
        Button(action: session.toggle) {
          Text(countdown > 0 ? "Cancel" : session.reachedEnd ? "Read again" : session.isActivelyRunning ? "Pause" : "Start reading")
        }.accessibilityLabel(session.isCountingDown ? "Cancel countdown" : session.reachedEnd ? "Read again" : session.isActivelyRunning ? "Pause" : "Start reading")
          .buttonStyle(PresenterButtonStyle(prominent: true))
          .help(session.isActivelyRunning && !session.reachedEnd ? "Pause reading (⌥⌘S)" : "Start reading (⌥⌘S)")
        Button("Back to start", action: session.restart)
          .disabled(session.isActivelyRunning || (!awayFromStart && !session.isCountingDown))
          .help("Return to the first word without stopping the recording")

      }
      Spacer(minLength: Space.sm)
      Group {
        if camera.presentsWithVideo {
          PresenterRecordButton(recorder: recorder, camera: camera, compact: true, showsStatus: false, defaultLabel: hasScript && camera.displayMode != .videoOnly ? session.activeRecord?.metadata.title ?? "" : "", secondary: !hasScript || camera.displayMode == .videoOnly)
            .help(recordHelp)
        } else {
          Button("Show camera") { camera.displayMode = .prompterWithVideo }.help("Show the camera beside the script (⇧⌘V)")
        }
      }
    }.lineLimit(1)
      .accessibilityIdentifier("presenter-transport")
  }

  private var visibleReadingStatusParts: (mode: String, state: String?) {
    if camera.cleanView { return ("Clean view", nil) }
    if draft.isEditing { return ("Editing", "not saved yet") }
    return (store.settings.mode == "Manual" ? "Automatic scroll" : "Voice follow", session.visibleReadingState)
  }
  private var visibleReadingStatus: String {
    let parts = visibleReadingStatusParts
    return parts.mode + (parts.state.map { " · " + $0 } ?? "")
  }
  /// The mode is semibold and the changing state regular, so the two read as different jobs.
  /// When the band is short of width the state drops to a second line whole, never mid-phrase.
  @ViewBuilder private var readingStatusLabel: some View {
    if hasBottomNotice { Text("Check reading").fontWeight(.semibold) } else {
      let parts = visibleReadingStatusParts
      ViewThatFits(in: .horizontal) {
        (Text(parts.mode).fontWeight(.semibold) + Text(parts.state.map { " · " + $0 } ?? "")).fixedSize()
        VStack(alignment: .leading, spacing: 0) {
          Text(parts.mode).fontWeight(.semibold)
          if let state = parts.state { Text(state) }
        }.fixedSize()
      }
    }
  }

  var outputControls: some View {
    Form {
      Section("Before recording") {
        LabeledContent("Picture", value: recorder.compactOutputConfirmation(camera: camera))
        if camera.pictureSize == nil { Text("Resolution unknown until a picture arrives.").font(.callout) }
        LabeledContent("Frame rate", value: recorder.frameRateConfirmation(camera: camera))
        LabeledContent("Microphone", value: recorder.microphoneName)
        LabeledContent("Format", value: recorder.recordingFormatName)
        LabeledContent("Saved video", value: (recorder.mirrorSavedVideo ? "Mirrored" : "Unmirrored") + " · " + camera.guides.rotation.label)
        LabeledContent("Saves to", value: CameraRecorder.recordingsFolder().path)
      }
      RecordingSettingsSections(defaultLabel: hasScript && camera.displayMode != .videoOnly ? session.activeRecord?.metadata.title ?? "" : "", recorder: recorder, camera: camera, zoom: controlZoom)
      RecordingFolderSection(recorder: recorder)
    }.formStyle(.grouped).environment(\.popoverEntryRequested, false)
      .frame(width: min(480, 640 / controlZoom), height: popoverHeight / controlZoom).uiZoom(controlZoom)
  }

  private var readingStatusTitle: String {
    if draft.isEditing { return "Editing · not saved yet" }
    if camera.cleanView { return "Clean view" }
    let mode = session.readingModeName
    let notice = editorNotice ?? session.anchorNotice ?? draft.errorMessage ?? draft.noticeMessage
    return "\(mode): \(session.visibleReadingState)" + (notice.map { ". " + $0 } ?? "")
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
      Text("Changes apply to all scripts.").font(.callout)
      Picker("Mode", selection: $store.settings.mode) {
        Text("Voice follow").tag("Voice")
        Text("Automatic scroll").tag("Manual")
      }.initialPopoverFocus()
      if store.settings.mode == "Manual" {
        AutomaticScrollDelay(session: session)
        LabeledContent("Reading speed") {
          ReadingSlider(value: $store.settings.speed, range: 20...300, title: "Reading speed",
            spokenValue: "\(Int(store.settings.speed)) words per minute")
          Text("\(Int(store.settings.speed)) wpm")
        }
      } else {
        Text("Follows your voice. On first use, allow microphone and speech access when asked.").font(.callout)
      }
    }.formStyle(.grouped).frame(width: 400).fixedSize(horizontal: false, vertical: true)
      .modifier(PresenterControlViewport(maxHeight: popoverHeight / controlZoom)).uiZoom(controlZoom)
  }

  private var cameraControls: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(recorder.inputAndFormatConfirmation).font(.callout).fixedSize(horizontal: false, vertical: true)
      // Builder B contract: the picker suppresses its recovery; this is the single owner.
      if camera.needsRecovery {
        CameraRecoveryView(model: camera) { showsCameraOptions = true }
          .environment(\.popoverEntryRequested, camera.devices.isEmpty)
      }
      if camera.recordingLocked {
        Text("Stop recording to change camera.").font(.callout)
      } else {
        CameraPickerList(model: camera, zoom: controlZoom, startsPreview: startsCamera, showsRecovery: false) { showsCameraControls = false; if overflowTool == "Camera" { overflowTool = nil } }
      }
      DisclosureGroup("Camera options", isExpanded: $showsCameraOptions) {
        Picker("Rotation", selection: Binding(get: { camera.guides.rotation }, set: { camera.setRotation($0) })) {
          ForEach(CameraRotation.allCases, id: \.self) { Text($0.label).tag($0) }
        }.disabled(camera.recordingLocked)
        Text("Rotation changes the preview and saved video.").font(.callout)
        Text(recorder.outputSummary(camera: camera)).font(.callout).fixedSize(horizontal: false, vertical: true)
        Button("Recording settings…") { showsCameraControls = false; overflowTool = nil; settingsTab = .camera; cameraSection = "Recording"; showsSettings = true }
        Button("Show Recordings Folder") { recorder.openRecordingsFolder() }
        Button("Open Second monitor window") { openWindow(id: "camera") }
        Text("An optional second window showing the same camera and recording.").font(.callout)
      }
    }.padding(Space.md).modifier(PresenterControlViewport(maxHeight: popoverHeight / controlZoom))
      .uiZoom(controlZoom).popoverEntryFocus()
  }

  private var moreMenu: some View {
    Button { openedFromPicture = false; showsTools.toggle() } label: {
      HStack(spacing: Space.xs) {
        Text("Tools").font(.callout)
        Image(systemName: "chevron.down").imageScale(.small)
      }.fixedSize().frame(minHeight: 24).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel("Tools")
      .accessibilityHint("Text, Camera, Exposure and Microphone controls").help("Text, camera, exposure and microphone controls")
      .focused($focusedTool, equals: "Tools")
      .restoringPopoverFocus(isPresented: Binding(get: {
        !openedFromPicture && (showsTools || showsSettings || showsHelp || showsLastTake || showsRecordingStatus || overflowTool != nil || showsReadingControls)
      }, set: { if !$0 {
        showsTools = false; showsSettings = false; showsHelp = false; showsRecordingStatus = false; showsLastTake = false; overflowTool = nil; showsReadingControls = false
      } }), identifier: "presenter-tools")
  }

  // The small row is for checking the picture. Configuration stays in Tools.
  var pictureRow: some View {
    HStack(spacing: Space.sm) {
      Button { camera.toggleFramingGuides() } label: { HStack(spacing: Space.xs) { if camera.framingIsVisible { Image(systemName: "checkmark").imageScale(.small) }; Text("Guides") }.fixedSize().frame(minHeight: 24).contentShape(Rectangle()) }
        .accessibilityLabel("Guides").accessibilityValue(camera.framingIsVisible ? "On" : "Off")
        .help("Show or hide framing guides. Choose the guides in Tools.")
        .tint(camera.framingIsVisible ? .accentColor : nil)
        .contextMenu { Button("Choose guides…") { overflowTool = "Guides" } }
        .onLongPressGesture { overflowTool = "Guides" }
      Button { camera.togglePictureExposureCheck() } label: { HStack(spacing: Space.xs) { if camera.exposureIsConfigured && !camera.exposureBypassed && !camera.cleanView { Image(systemName: "checkmark").imageScale(.small) }; Text("Exposure check") }.fixedSize().frame(minHeight: 24).contentShape(Rectangle()) }
        .accessibilityLabel("Exposure check").accessibilityValue(camera.exposureIsConfigured && !camera.exposureBypassed && !camera.cleanView ? "On" : "Off")
        .help("Show or hide exposure aids. With no aids selected, shows brightness colours.")
        .tint(camera.exposureIsConfigured && !camera.exposureBypassed && !camera.cleanView ? .accentColor : nil)
        .contextMenu { Button("Exposure settings…") { selectedToolSection = "Exposure"; showsTools = true } }
        .onLongPressGesture { selectedToolSection = "Exposure"; showsTools = true }
      Button { openedFromPicture = true; overflowTool = "Camera" } label: { Text("Switch camera").frame(minHeight: 24).contentShape(Rectangle()) }.layoutPriority(1)
        .disabled(camera.recordingLocked)
        .accessibilityValue(camera.devices.first(where: { $0.uid == camera.selectedUID })?.name ?? "No camera")
        .help(camera.recordingLocked ? "Stop recording to change camera" : "Choose a camera")
        .restoringPopoverFocus(isPresented: Binding(get: { openedFromPicture && overflowTool == "Camera" }, set: { if !$0 { overflowTool = nil } }), identifier: "picture-camera")
      Spacer(minLength: 0)
      if showsCompactReceipt, let file = recorder.savedTake {
        let duration = CameraRecorder.durationText(recorder.lastTakeDuration)
        Button { openedFromPicture = true; showsLastTake = true } label: {
          // Priority lets the duration show whenever the row has room; the picture checks never shrink.
          ViewThatFits(in: .horizontal) {
            receiptOpenerLabel("Saved " + duration)
            receiptOpenerLabel("Saved")
          }.layoutPriority(1)
        }.accessibilityLabel("Last take").accessibilityValue("Saved \(file.lastPathComponent) · \(duration)")
          .help("Saved \(file.path). Play, show in Finder or hide the receipt.")
          .restoringPopoverFocus(isPresented: Binding(get: { openedFromPicture && showsLastTake }, set: { if !$0 { showsLastTake = false } }), identifier: "picture-last-take")
      }
    }.font(.callout).foregroundStyle(Palette.onDarkQuiet(contrast)).buttonStyle(.plain).frame(minHeight: 24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain).accessibilityLabel("Picture")
      .accessibilityIdentifier("presenter-picture-row")
  }

  private func receiptOpenerLabel(_ title: String) -> some View {
    HStack(spacing: Space.xs) {
      Image(systemName: "checkmark.circle.fill")
      Text(title).monospacedDigit()
      Image(systemName: "chevron.right").imageScale(.small)
    }.fixedSize().frame(minHeight: 24).contentShape(Rectangle())
  }

  private var toolSection: String {
    let fallback = hasScript && camera.displayMode != .videoOnly ? "Text" : "Exposure"
    guard let selectedToolSection else { return fallback }
    if selectedToolSection == "Text" && (!hasScript || camera.displayMode == .videoOnly) { return fallback }
    if selectedToolSection == "Exposure" && !camera.presentsWithVideo { return fallback }
    return selectedToolSection
  }
  var toolsSurface: some View {
    Form {
      Picker("Tools section", selection: Binding(get: { toolSection }, set: { selectedToolSection = $0 })) {
        if hasScript && camera.displayMode != .videoOnly { Text("Text").tag("Text") }
        Text("Camera").tag("Camera")
        if camera.presentsWithVideo { Text("Exposure").tag("Exposure") }
        Text("Microphone").tag("Microphone")
      }.pickerStyle(.menu)
      toolContents(toolSection)
      // Each remaining job is named directly; a generic More menu hid the pre-record check.
      Section {
        Button("Before recording check…") { showsTools = false; overflowTool = "Output" }
          .help("Check picture, microphone, format, take name and folder before you record")
        Button("Shoot setups…") { showsTools = false; openPresenterSettings(.shootSetups) }
        Button("Presenter help…") { showsTools = false; showsHelp = true }
        Button("Last take") { showsTools = false; openedFromPicture = false; showsLastTake = true }
          .disabled(recorder.savedTake == nil && recorder.takeFailure == nil && recorder.lastFile == nil)
      }
    }.formStyle(.grouped).frame(width: min(520, 640 / controlZoom)).fixedSize(horizontal: false, vertical: true)
      .modifier(PresenterControlViewport(maxHeight: popoverHeight / controlZoom)).uiZoom(controlZoom)
  }

  @ViewBuilder func toolContents(_ section: String) -> some View {
    if section == "Text" {
      Section("Text") {
        WrapLayout(spacing: Space.sm) {
          Button("Smaller text") { changeReadingSize(-4) }.disabled(store.settings.fontSize <= 18)
          Button("Larger text") { changeReadingSize(4) }.disabled(store.settings.fontSize >= 120)
          Button("Reading mode…") { showsTools = false; showsReadingControls = true }
          Button("Edit this script") { showsTools = false; draft.begin(session: session) }.disabled(draft.isEditing)
        }
        Text("Reading text: \(Int(store.settings.fontSize)) points. Changes apply to all scripts.").font(.callout)
        Button("More text settings…") { showsTools = false; openPresenterSettings(.reading) }
      }
    } else if section == "Camera" {
      Section("Camera") {
        viewMenu(compact: true)
        Button("Choose camera…") { showsTools = false; overflowTool = "Camera" }
        Button("Framing guides…") { showsTools = false; overflowTool = "Guides" }
        Button("More camera settings…") { showsTools = false; openPresenterSettings(.camera) }
      }
    } else if section == "Exposure" {
      Section("Exposure") {
        ExposureToolToggles(model: camera).environment(\.popoverEntryRequested, false)
        Toggle("Clean presenter view", isOn: $camera.cleanView).help(CameraModel.cleanViewExplanation)
        Button("More exposure settings…") { showsTools = false; openPresenterSettings(.camera, section: "Exposure") }
      }
    } else {
      Section("Microphone") {
        Button("Check sound…") { showsTools = false; overflowTool = "Microphone" }
        Button("More microphone settings…") { showsTools = false; openPresenterSettings(.microphone) }
      }
    }
  }
  private func openPresenterSettings(_ tab: SettingsTab, section: String = "Camera") {
    settingsTab = tab; cameraSection = section; showsSettings = true
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
    .padding(Space.sm).background(LibraryAppearance.color(.windowBackgroundColor, scheme: scheme), in: RoundedRectangle(cornerRadius: 12))
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
      Rectangle().frame(width: 12, height: 3) // grid: ok Thin optical reading-line marker, not control spacing.
      Spacer()
      Rectangle().frame(width: 12, height: 3) // grid: ok Thin optical reading-line marker, not control spacing.
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
      .background(LibraryAppearance.color(.windowBackgroundColor, scheme: scheme))
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

/// Observes the recording input already being captured, without starting another microphone.
private struct RecordingBarLevel: View {
  @ObservedObject var meter: InputMeter
  var compact = false
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      HStack {
        InputLevelMeter(peakDBFS: meter.isFresh() ? meter.peakDBFS : -.infinity,
                        isClipping: meter.isClipping, showsScale: false)
      }.frame(width: compact ? 12 : 40)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Recording microphone level")
        .accessibilityValue(meter.isFresh() ? String(format: "%.1f dBFS", meter.peakDBFS) : "No recent audio")
    }
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
