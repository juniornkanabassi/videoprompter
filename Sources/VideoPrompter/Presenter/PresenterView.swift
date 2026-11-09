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

  init(store: AppStore, session: SessionStore, draft: PresenterDraft, hasScript: Bool = true,
       camera: CameraModel = .shared, monitor: ReferenceMonitor = .shared, startsCamera: Bool = true, recorder: CameraRecorder = .shared, shell: PresenterShell? = nil, referencePicture: NSImage? = nil) {
    self.store = store
    self.session = session
    self.draft = draft
    self.hasScript = hasScript
    self.camera = camera
    self.monitor = monitor
    self.startsCamera = startsCamera
    self.referencePicture = startsCamera ? nil : referencePicture
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
  @AppStorage("presenterMicLevel") private var showsMicLevel = true
  @State private var settingsTab = SettingsTab.reading
  @FocusState private var cleanExitFocused: Bool
  static func backdropOpacity(saved: Double, reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : saved }
  // Interface size applies to the entire shell, with named controls wrapping as needed.
  static func controlZoom(_ zoom: Double) -> Double { zoom }
  private var controlZoom: Double { Self.controlZoom(store.uiZoom) }
  @State private var stageWidth: CGFloat = 1600
  private var compactReading: Bool { shell.reading && stageWidth / controlZoom < 700 }
  @ObservedObject private var recorder: CameraRecorder
  /// False in Video only, unless a draft was already open: it must stay reachable to finish or cancel.
  private var showsScript: Bool { !camera.cleanView && hasScript && (shell.reading || draft.isEditing) }
  private var stage: some View { readingStage }
  private var readingStage: some View {
    GeometryReader { geometry in
      let sideInset = ScriptTextView.sideInset(width: geometry.size.width, textWidth: store.settings.textWidth)
      ZStack(alignment: .top) {
        if camera.presentsWithVideo || camera.cleanView {
          // The live picture is the bottom layer only. The background colour above it is the
          // script's backdrop, so colour, opacity, guide line, mirror, rotation and in-place
          // editing all keep working exactly as they do without video.
          Group {
            if let referencePicture {
              Image(nsImage: referencePicture).resizable().scaledToFit()
            } else { CameraPreview(model: camera, presenter: true) }
          }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, !shell.reading && !camera.cleanView && camera.exposureIsConfigured ? max(0, 2 * (300 * controlZoom - camera.guides.rotation.fittedRect(aspect: camera.pictureSize ?? CGSize(width: 16, height: 9), in: CGRect(origin: .zero, size: geometry.size)).minX)) : 0) // grid: ok Reserve room for the exposure key beside a 16:9 or portrait picture.
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
        if referencePicture == nil && camera.presentsWithVideo && camera.needsRecovery && !showsScript && !camera.cleanView {
          CameraRecoveryView(model: camera) { shell.adjustTab = .camera }
            .uiZoom(controlZoom).padding(Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .environment(\.colorScheme, .dark)
        }
        if camera.presentsWithVideo && !camera.cleanView && camera.exposureIsConfigured && !camera.exposureBypassed {
          Group {
            ExposureKey(guides: camera.guides, compact: shell.reading, zoom: controlZoom).frame(maxWidth: 280 * controlZoom, alignment: .leading)
              .padding(Space.md).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              .accessibilityIdentifier("presenter-exposure-legend")
          }

        }
        if micLevelVisible {
          MicMeterView(meter: recorder.inputMeter, micName: recorder.microphoneName)
            .frame(width: 120, height: geometry.size.height * 0.85 / controlZoom).uiZoom(controlZoom) // grid: ok Fit the scaled meter inside the stage.
            .frame(width: 120 * controlZoom, height: geometry.size.height * 0.85) // grid: ok The meter fits within the stage.
            .padding(Space.sm).background(.black.opacity(0.45), in: .rect(cornerRadius: 12))
            .padding(.trailing, Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .environment(\.colorScheme, .dark)
        }
        if !hasScript, camera.displayMode != .videoOnly, !camera.cleanView {
          Text("No script yet. Choose one in the library and press Present to add it here.")
            .font(.title3).multilineTextAlignment(.center).foregroundStyle(.white)
            .padding(Space.lg).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Space.md))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

      }
    }.background(Color(white: 0.035))
  }

  private var micLevelVisible: Bool { showsMicLevel && camera.presentsWithVideo && !camera.cleanView }
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
      if clean { shell.cleanEntered(session: session); showsReadingNotice = false; showsSettings = false }
      cleanControlsRevealed = false
      if clean { quietTask?.cancel() }
      announce("Clean view " + (clean ? "on" : "off"))
    }
  }
  var body: some View {
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
      if let tab = shell.adjustTab, !camera.cleanView {
        AdjustPanel(selection: Binding(get: { shell.adjustTab ?? tab }, set: { shell.adjustTab = $0 }), showsMic: $showsMicLevel,
                    camera: camera, store: store, startsMeter: startsCamera, zoom: controlZoom, recorder: recorder)
      }
    }
    .overlay(alignment: .top) {
      if camera.cleanView && (cleanControlsRevealed || cleanExitFocused) {
        Button("Exit Clean · Esc") { camera.cleanView = false }
          .buttonStyle(.plain).padding(.horizontal, 12).frame(minHeight: 44).background(.black.opacity(0.85), in: Capsule()).foregroundStyle(.white).focused($cleanExitFocused).padding(24)
      } else if !camera.cleanView && !shell.reading && camera.presentsWithVideo {
        HStack {
          Text(camera.sourceInfo?.summary ?? "Camera").padding(8).background(.black.opacity(0.8), in: Capsule())
          Text(camera.shotSummary).padding(8).background(.black.opacity(0.8), in: Capsule())
        }.font(.callout.weight(.semibold)).foregroundStyle(.white).padding(.top, 24)
      }
    }
    .onContinuousHover { phase in
      if camera.cleanView, case .active = phase { revealControls() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if showsChrome { controlBar.environment(\.colorScheme, .dark) }
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
        Text("Editing · not saved yet").font(.callout)
        HStack {
          Button("Save changes") { Task { await draft.confirm(store: store) } }.keyboardShortcut(.return, modifiers: .command).disabled(draft.isSaving)
          Button("Cancel editing") { draft.requestCancel() }.disabled(draft.isSaving)
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
      WrapLayout(spacing: 12, distributeAfter: shell.reading ? nil : 2) {
      if shell.reading {
        transportButton("Back to start", icon: "arrow.counterclockwise") { session.restart() }
        transportButton(session.isActivelyRunning || session.isCountingDown ? "Pause" : "Start reading", icon: session.isActivelyRunning || session.isCountingDown ? "pause.fill" : "play.fill", primary: true) { session.toggle() }
        transportButton("Set up the shot", icon: "display") { session.pause(); shell.reading = false }
      } else {
        transportButton("Start reading", icon: "play.fill", primary: true) { shell.reading = true; session.startReading() }.disabled(!hasScript || draft.isEditing)
        transportButton("Back to start", icon: "arrow.counterclockwise") { session.restart() }.disabled(!hasScript)
        shellTile("Camera", "video", tab: .camera, value: camera.guides.rotation == .none ? "Landscape" : "↻ Vertical") { shell.adjustTab = .camera }
        shellTile("Zebras", "circle.lefthalf.striped.horizontal", tab: .zebras, on: camera.guides.zebras, value: zebraDetail) { camera.exposureBinding(\.zebras).wrappedValue.toggle() }
        shellTile("False colour", "circle.lefthalf.filled", tab: .falseColour, on: camera.guides.falseColour) { camera.exposureBinding(\.falseColour).wrappedValue.toggle() }
        shellTile("Guides", "squareshape.split.3x3", tab: .guides, on: camera.framingIsVisible) { camera.toggleFramingGuides() }
        shellTile("Mic", "mic", tab: .mic, on: showsMicLevel) { showsMicLevel.toggle() }
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 72)
        shellTile("Adjust", "slider.horizontal.3", tab: .camera) { shell.adjustTab = shell.adjustTab == nil ? .camera : nil }
        shellTile("Clean", "rectangle", tab: .camera) { camera.cleanView = true }
      }
      }
      }
    }.padding(compactReading ? 8 : 16).frame(maxWidth: .infinity, minHeight: 132)
      .background(Color(nsColor: NSColor(white: 0.08, alpha: 1)))
      .buttonStyle(PresenterButtonStyle()).accessibilityIdentifier("presenter-control-bar")
  }

  private func transportButton(_ title: String, icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: icon).font(.system(size: 18, weight: .semibold))
        .fixedSize().padding(.horizontal, compactReading ? Space.sm : Space.lg)
        .frame(minWidth: compactReading ? 0 : 190, minHeight: compactReading ? 44 : 92) // grid: ok Match the large transport buttons in the approved mockup.
        .foregroundStyle(primary ? .black : .white)
        .background(primary ? Color.yellow : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }.buttonStyle(.plain).accessibilityLabel(title)
  }

  private func shellTile(_ title: String, _ symbol: String, tab: AdjustTab, on: Bool? = nil, value: String? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: symbol).font(.title2)
          .padding(.top, Space.sm)
        Text(title).font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

      }.frame(width: 104, height: 92)
        .overlay(alignment: .topTrailing) {
          if let value { Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(.yellow).padding(4).accessibilityHidden(true) }
        }
        .overlay(alignment: .topLeading) { if on == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.yellow).padding(4) } }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on == true ? Color.yellow : .clear, lineWidth: 2))
    }.buttonStyle(.plain).accessibilityLabel(title)
      .accessibilityValue(on.map { $0 ? "On" : "Off" } ?? ((title == "Camera" || title == "Adjust") ? camera.sourceInfo?.displayName ?? "No camera selected" : value ?? ""))
      .contextMenu { if title != "Clean" && title != "Adjust" { Button("Adjust \(title)") { shell.adjustTab = tab } } }
      .onLongPressGesture { if title != "Clean" && title != "Adjust" { shell.adjustTab = tab } }
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
      var x = distribute ? bounds.minX : bounds.midX - row.width / 2
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
