import PrompterCore
import SwiftUI
import UIKit

/// The presenter's colours: the Mac app's tokens, so the two read as one product.
private enum PresenterTheme {
  static let accent = Color(red: 0.961, green: 0.812, blue: 0.290)  // #f5cf4a
  static let ink = Color(red: 0.114, green: 0.090, blue: 0.016)  // #1d1704
  static let bar = Color(red: 0.118, green: 0.118, blue: 0.122)  // #1e1e1f
  static let card = Color(red: 0.149, green: 0.149, blue: 0.157)  // #262628
  static let card2 = Color(red: 0.184, green: 0.184, blue: 0.192)  // #2f2f31
  static let line = Color(red: 0.204, green: 0.204, blue: 0.216)  // #343437
  static let text = Color(red: 0.925, green: 0.925, blue: 0.925)  // #ececec
  static let muted = Color(red: 0.608, green: 0.608, blue: 0.608)  // #9b9b9b
  static let warn = Color(red: 0.898, green: 0.643, blue: 0.263)  // #e5a443
  static let good = Color(red: 0.373, green: 0.761, blue: 0.541)  // #5fc28a
  static let offFill = Color(red: 0.290, green: 0.122, blue: 0.110)  // #4a1f1c
  static let offText = Color(red: 1, green: 0.706, blue: 0.671)  // #ffb4ab
  static let lit = accent.opacity(0.16)
}

/// The full-screen presenter. Black behind the script by default (anything lighter shows as a
/// grey haze in teleprompter glass), the camera picture only when the picture mode asks for it.
/// The script, reading line, meter and presenter-facing notes turn with Mirror and Flip for the
/// glass; the controls never do. Setting up shows the full bar, reading a pill and a few small
/// buttons, clean full screen only the text, line and meter. A Bluetooth keyboard, clicker or
/// foot pedal drives it without touching the screen.
struct PresenterScreen: View {
  @EnvironmentObject private var store: PadStore
  @ObservedObject var session: SessionStore
  @ObservedObject var camera: PadCamera
  private let referencePicture: UIImage?
  private let snapshotPicker: Bool?
  @ScaledMetric(relativeTo: .body) private var preferredHUDScale = 1.0
  private var hudScale: Double { max(1, preferredHUDScale) }
  private let startsReading: Bool
  private var setup: Bool {
    get { store.presenterSetup }
    nonmutating set { store.presenterSetup = newValue }
  }
  private var showScript: Bool {
    get { store.scriptVisible }
    nonmutating set { store.scriptVisible = newValue }
  }
  @State private var showingLook = false
  @State private var keyExpanded = true
  private var falseColour: Bool { camera.guides.falseColour }
  private var focusActive: Bool { store.cleanScreen && store.cleanLook == .scriptOnly }
  @AppStorage("presenterExposureKey") private var showKey = true
  @State private var showingCamera = false
  @State private var hadMac = false
  @State private var editingRecord: ScriptRecord?
  @FocusState private var focused: Bool

  /// `startsReading` opens on the reading controls (snapshots and tests); Start does the same.
  init(session: SessionStore, camera: PadCamera, startsReading: Bool = false, referencePicture: UIImage? = nil, previouslyConnected: Bool = false, snapshotPicker: Bool? = nil) {
    self.snapshotPicker = snapshotPicker
    self.referencePicture = referencePicture
    _hadMac = State(initialValue: previouslyConnected)
    self.session = session
    self.camera = camera
    self.startsReading = startsReading
  }

  private var settings: PrompterSettings { store.settings }
  private var macConnected: Bool { camera.link.macName != nil }
  /// A Mac was here and went: reading paused where it was until the reader chooses.
  private var macLost: Bool { hadMac && !macConnected }
  private var lostPaused: Bool { macLost && !session.isActivelyRunning }
  private var counting: Bool { session.isCountingDown }
  private var isVoice: Bool { settings.mode == "Voice" }

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let turn = PadPresenterLayout.turn(mirror: store.mirror, flip: store.flip)
      ZStack {
        if store.pictureMode == .monitorOnly, !store.cameraOnly {
          // The confidence monitor replaces the presenter while the picture is monitor only.
          ConfidenceMonitorView(camera: camera, referencePicture: referencePicture)
        } else {
          ZStack {
            background
            if store.cameraOnly { cameraOnlyLayer(size) } else { scriptLayer(size) }
            if !store.cleanScreen && !focusActive {
              cameraCard(size: CGSize(width: size.width / hudScale, height: size.height / hudScale)).uiZoom(hudScale)
            }
          }
          .scaleEffect(x: turn.a, y: turn.d)
          if !store.cleanScreen {
            chrome.uiZoom(hudScale)
            if !counting {
              setupBar(width: size.width / hudScale).disabled(store.editing).uiZoom(hudScale)
            }
            if !store.cameraOnly { status }

          } else {
            cleanHandle
          }
          if counting { countdown(size) }
        }
        if let snapshotPicker {
          DevicePickerCards(store: store, microphone: snapshotPicker)
            .clipShape(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 140).padding(.bottom, 152)
        }
      }
    }
    .ignoresSafeArea()
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(phases: .down) { press in handle(press) }
    .onAppear {
      setup = !(startsReading || session.isActivelyRunning || session.isCountingDown)
      focused = true
      hadMac = hadMac || macConnected
      if referencePicture == nil { useOwnCameraWithoutMac() }
    }
    .onChange(of: camera.link.macName) { _, name in
      if name != nil { hadMac = true }
      useOwnCameraWithoutMac()
    }
    .onChange(of: store.cameraOnly) { _, _ in useOwnCameraWithoutMac() }
    .onChange(of: store.cleanLook) { _, _ in updateExposureVisibility() }
    .onChange(of: store.cleanScreen) { _, _ in updateExposureVisibility() }
    .onChange(of: setup, initial: true) { _, _ in updateExposureVisibility() }
    .onChange(of: store.editing) { _, _ in updateExposureVisibility() }
    .onChange(of: store.cameraOnly) { _, _ in updateExposureVisibility() }
    .onChange(of: store.pictureMode) { _, _ in updateExposureVisibility() }
    .onDisappear { camera.setExposureHidden(false) }
    .onChange(of: session.isActivelyRunning) { _, running in if running { setup = false } }
    // A linked Mac supplies the picture, so this iPad's own camera is the fallback only without one.
    .onChange(of: store.pictureMode) { _, mode in if mode == .behindScript, !macConnected || camera.isShowingMac { camera.isOn = true } }
    .fullScreenCover(
      isPresented: Binding(get: { editingRecord != nil }, set: { if !$0 { editingRecord = nil } }),
      onDismiss: { focused = true }
    ) {
      // Editing on the fly: only this Edit button opens it, so a remote presentation never starts it.
      if let record = editingRecord {
        ScriptEditorView(record: record, mode: .onTheFly) { editingRecord = nil }
          .id(record.metadata.id).environmentObject(store)
      }
    }
  }

  private func updateExposureVisibility() {
    camera.setExposureHidden(store.cleanScreen && !store.cleanLook.showsGuides)
  }

  // MARK: Behind and on the script

  @ViewBuilder private var background: some View {
    // Camera Only draws its own picture; one picture layer is never in two views.
    if let referencePicture, (store.pictureMode == .behindScript || store.cleanScreen), !focusActive, !store.cameraOnly {
      ExposureReferencePicture(image: referencePicture, guides: camera.previewGuides)
      Color(uiColor: ScriptRenderer.colour(settings.backgroundColorHex)).opacity(store.cleanScreen && store.cleanLook == .pictureOnly ? 0 : settings.videoDimming).ignoresSafeArea()
    } else if (store.pictureMode == .behindScript || store.cleanScreen), camera.isOn, !focusActive, !store.cameraOnly {
      Group {
        if camera.isShowingMac {
          LinkPreview(camera: camera, link: camera.link)
        } else {
          CameraPreview(camera: camera)
        }
      }
      .ignoresSafeArea()
      Color(uiColor: ScriptRenderer.colour(settings.backgroundColorHex)).opacity(store.cleanScreen && store.cleanLook == .pictureOnly ? 0 : settings.videoDimming).ignoresSafeArea()
    } else {
      Color.black.ignoresSafeArea()
      Color(uiColor: ScriptRenderer.colour(settings.backgroundColorHex)).opacity(settings.backgroundOpacity).ignoresSafeArea()
    }
  }

  /// The setting-up note beside Camera and Mic ("Camera off: ..."); it sits above the bar, so the script leaves room for it.
  private var showsOffNote: Bool { !store.cameraOn && macConnected || !store.micOn && !store.cameraOnly }

  /// Script, reading line, meter and the presenter-facing note: the part the glass shows back.
  /// While controls are visible the script scrolls inside a reading viewport between them, faded at
  /// both edges; clean screen gives the whole screen back. The viewport is worked out on the
  /// upright layer and turned once with the picture, so their relative positions stay unchanged.
  private func scriptLayer(_ size: CGSize) -> some View {
    let insets = PadPresenterLayout.scriptInsets(
      width: size.width / hudScale, cleanScreen: store.cleanScreen, setup: true, lostPaused: lostPaused, offNote: showsOffNote)
    let top = insets.top * hudScale
    let bottom = insets.bottom * hudScale
    let height = max(size.height - top - bottom, 1)
    let side = !store.cleanScreen ? min(256, size.width / 4 + 16) : 0
    let scriptWidth = max(1, size.width - side * 2)
    let lineY = min(max(size.height * settings.guideFraction, top + 54), top + height - 40)
    let showsMeter = !store.cleanScreen || store.keepMicMeter
    let fade = min(height, min(160, max(48, settings.fontSize * 1.6))) / height
    return ZStack(alignment: .topLeading) {
      if store.cleanScreen ? store.cleanLook.showsScript : showScript {
        ScriptCanvas(
          document: session.document, tokenIndex: session.tokenIndex,
          lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
          isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
          // The reading rule rests just under the current line, at lineY in the layer.
          layoutGuideFraction: (lineY - top) / height,
          style: ScriptStyle(settings, overVideo: store.pictureMode == .behindScript && cameraIsOn), textWidth: settings.textWidth,
          manualPosition: session.isManual ? { [session] in session.manualPosition() }
            : UIAccessibility.isReduceMotionEnabled ? nil : { [session] in session.voicePosition() },
          onSeek: { session.seek(to: $0) },
          onUserScroll: { session.seekFromUserScroll(to: $0) },
          onSingleTap: store.cleanScreen ? { store.setCleanScreen(false) } : nil)
        .frame(width: scriptWidth, height: height)
        .mask(
          LinearGradient(
            stops: [
              .init(color: .black, location: 0),
              .init(color: .black, location: 1 - fade), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .offset(x: side, y: top)
      }
      if showsMeter {
        PresenterMeter(meter: store.micMeter, name: microphoneName, isListening: store.micOn)
          .frame(width: MicMeterView.stripWidth(typeScale: 1))
          .frame(maxHeight: .infinity)
          // Clear of the controls and the Mac-lost card, wherever Flip puts them.
          .padding(.top, store.cleanScreen ? 48 : top + 12)
          .padding(.bottom, store.cleanScreen ? 80 : bottom + 8)
          .frame(width: size.width, height: size.height, alignment: .trailing)
          .padding(.trailing, 8)
          .allowsHitTesting(false)
      }
      if lostPaused {
        // Its own band under the top chrome, in the viewport's reserved space (turned with the layer).
        let band = PadPresenterLayout.lostNoticeBand
        Text("Paused · Mac disconnected")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(PresenterTheme.warn)
          .lineLimit(1).minimumScaleFactor(0.7)
          .padding(.leading, ScriptCanvas.sideInset(width: size.width, textWidth: settings.textWidth, fontSize: settings.fontSize))
          .frame(width: size.width, height: band, alignment: .leading)
          .offset(y: PadPresenterLayout.topChrome)
          .allowsHitTesting(false)
      }
    }
    .frame(width: size.width, height: size.height)
  }

  /// Camera Only: the picture alone, turned with Mirror and Flip like the confidence monitor, with
  /// the Mac's recording frame and its meter. Without a Mac the meter would read nothing, so it is left out.
  private func cameraOnlyLayer(_ size: CGSize) -> some View {
    let recording = macConnected ? store.recordingState : .standby
    return ZStack {
      Color.black
      Group {
      if let referencePicture {
        ExposureReferencePicture(image: referencePicture, guides: camera.previewGuides)
      } else if macConnected {
        if store.cameraOn { LinkPreview(camera: camera, link: camera.link) }
      } else if camera.isOn {
        CameraPreview(camera: camera)
      }
      }.clipShape(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner)).padding(16)
      if recording != .standby {
        RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).strokeBorder(recordingColour(recording), lineWidth: recording == .recording ? 8 : 5).padding(16)
      }
    }
    .frame(width: size.width, height: size.height)
    .contentShape(Rectangle())
    .onTapGesture { if store.cleanScreen { store.setCleanScreen(false) } }
    .overlay(alignment: .trailing) {
      if macConnected || referencePicture != nil {
        PresenterMeter(meter: store.micMeter, name: microphoneName, isListening: store.micOn)
          .frame(width: MicMeterView.stripWidth(typeScale: 1))
          .padding(.top, 96).padding(.bottom, 120).padding(.trailing, 8)
          .allowsHitTesting(false)
      }
    }
    .accessibilityLabel("Camera picture")
  }

  private func recordingColour(_ state: PadRemote.RecordingState) -> Color {
    state == .recording ? Color(red: 0.78, green: 0.18, blue: 0.15) : PresenterTheme.warn
  }

  private func useOwnCameraWithoutMac() { store.useOwnCameraWithoutMac() }

  private func countdown(_ size: CGSize) -> some View {
    let turn = PadPresenterLayout.turn(mirror: store.mirror, flip: store.flip)
    return ZStack {
      Color.black.opacity(0.6)
      Text("\(session.countdownRemaining)")
        .font(.system(size: 300, weight: .semibold))
        .foregroundStyle(PresenterTheme.accent)
        .frame(width: 420, height: 420)
        .overlay(Circle().strokeBorder(PresenterTheme.accent, lineWidth: 10))
        .scaleEffect(x: turn.a, y: turn.d)
    }
    .frame(width: size.width, height: size.height)
    .contentShape(Rectangle())
    // A tap cancels the count, as Pause does.
    .onTapGesture { session.pause() }
    .accessibilityLabel("Starting in \(session.countdownRemaining). Tap to cancel.")
  }

  // MARK: Chrome (operator side, never turned)

  private var chrome: some View {
    VStack {
      ZStack {
        HStack {
          PadButton("Library", icon: "chevron.left", kind: .card, height: 44) { store.closePresenter() }
            .keyboardShortcut(.cancelAction)
          Spacer()
          if !store.cameraOnly, let script = session.activeScriptID.flatMap(store.folder.script) {
            PadButton("Edit", icon: "pencil", kind: .card, showsTitle: false, height: 44) {
              session.pause()
              editingRecord = store.record(for: script)
            }
          }
        }
        if let chip = linkChip {
          HStack(spacing: 8) {
            Circle().fill(macLost ? PresenterTheme.warn : PresenterTheme.good).frame(width: 8, height: 8)
            Text(chip).lineLimit(1)
          }
          .font(.system(size: 16))
          .foregroundStyle(PresenterTheme.text)
          .padding(.horizontal, 16).frame(height: 44)
          .background(PresenterTheme.card, in: Capsule())
          .overlay(Capsule().strokeBorder(PresenterTheme.line))
          .accessibilityElement(children: .combine)
        }
      }
      .padding(.horizontal, 24).padding(.top, 24)
      Spacer()
    }
  }

  private var linkChip: String? {
    if macLost { return "Mac disconnected" }
    guard macConnected else { return nil }
    let name = store.macDisplayName ?? camera.link.macName ?? "the Mac"
    let rec = store.cameraOnly ? recordingText + " · " : ""
    return rec + "Controlled from \(name)" + (store.connectionKind.map { " · \($0)" } ?? "")
  }

  private var recordingText: String {
    switch store.recordingState {
    case .recording: return "REC"
    case .standby: return "Standby"
    case .unknown: return "REC unknown"
    }
  }

  /// A note about what the iPad has just noticed, such as an unsure match; bottom centre.
  @ViewBuilder private var status: some View {
    let message: String? = {
      if let notice = session.anchorNotice { return notice }
      if case .uncertain(let text) = session.state { return text }
      return nil
    }()
    if let message {
      VStack {
        Spacer()
        Text(message)
          .font(.callout)
          .foregroundStyle(PresenterTheme.text)
          .padding(.horizontal, 16).padding(.vertical, 8)
          .background(.ultraThinMaterial, in: Capsule())
          .padding(.bottom, setup ? 124 : 96)
      }
      .allowsHitTesting(false)
    }
  }

  // MARK: Reading controls

  private var statusPill: some View {
    HStack(spacing: 8) {
      Circle().fill(session.isActivelyRunning ? Color.green : .white.opacity(0.4)).frame(width: 8, height: 8)
      Text(statusText).lineLimit(1)
    }
    .font(.system(size: 14, weight: .medium))
    .foregroundStyle(.white.opacity(0.85))
    .padding(.horizontal, 16).frame(height: 44)
    .background(.white.opacity(0.07), in: Capsule())
    .accessibilityElement(children: .combine)
  }

  private var statusText: String {
    let words = session.document.spokenTokens.count
    return "\(session.isActivelyRunning ? "Reading" : "Paused") · word \(words > 0 ? session.tokenIndex + 1 : 0) of \(words)"
  }

  /// The warning when the Mac goes: reading stopped where it was, the way back is the reader's choice.
  private var lostCard: some View {
    HStack(spacing: 16) {
      Circle().fill(PresenterTheme.warn).frame(width: 12, height: 12)
      Text("Lost the Mac. Paused where you were.").fixedSize(horizontal: false, vertical: true)
      PadButton("iPad mic", kind: .plain, height: 44) {
        store.setMicOn(true)
        startReading()
      }
      .fixedSize()
      PadButton("Reconnect", kind: .primary, height: 44) { camera.link.start() }
        .fixedSize()
    }
    .font(.system(size: 18))
    .foregroundStyle(PresenterTheme.text)
    .padding(.horizontal, 20).padding(.vertical, 16)
    .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
    .overlay(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).strokeBorder(PresenterTheme.warn))
  }

  private var primaryTitle: String {
    if session.isActivelyRunning || counting { return "Pause" }
    return "Start reading"
  }

  private func primaryAction() {
    guard !store.cameraOnly else { return }
    if session.isActivelyRunning || counting { session.pause() } else {
      setup = false
      startReading()
    }
  }

  /// Voice follows nothing without a microphone; the off note beside Mic says why.
  private func startReading() {
    // No script is on screen in Camera Only, so nothing may read, or ask for the microphone.
    guard !store.cameraOnly, store.micOn || !isVoice else { return }
    store.startReading()
  }

  /// Mirror and Flip: two independent glass buttons, lit when on, always on screen while presenting.
  private var turnGroup: some View {
    PresenterTurnControls(mirror: Binding(get: { store.mirror }, set: store.setMirror),
      flip: Binding(get: { store.flip }, set: store.setFlip))
  }

  // MARK: Setting up

  private func setupBar(width: CGFloat) -> some View {
    VStack(spacing: Space.sm) {
      Spacer()
      if showsOffNote { offNote }
      PresenterSetupBar(scale: hudScale) {
        transport
      } devices: {
        devices
      } tools: {
        pictureTools
      } options: {
        turnGroup
        compactViewTools
      }
      .padding(.horizontal, Space.md)
      .background(PresenterBar.background)
    }
  }

  @ViewBuilder private var transport: some View {
    if !store.cameraOnly {
      Button(action: primaryAction) { BarLabel(title: primaryTitle, symbol: session.isActivelyRunning || counting ? "pause.fill" : "play.fill").frame(minWidth: 144) }
        .buttonStyle(BarButtonStyle(role: .prominent))
      Button { session.restart() } label: { BarLabel(title: "Back", symbol: "arrow.counterclockwise") }
        .buttonStyle(BarButtonStyle(role: .secondary))
      Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
  }

  private var devices: some View {
    BarGroup(label: "Camera, microphone and script") {
      cameraButton(compact: false)
      BarDivider()
      micButton(compact: false)
      PresenterLinkedLevel(meter: store.micMeter)
      if !store.cameraOnly {
        BarDivider()
        BarToggle(title: "Script", symbol: "text.alignleft", isOn: showScript) { showScript.toggle() }
      }
    }
  }

  private var viewTools: some View {
    HStack(spacing: 8) { turnGroup; compactViewTools }
  }

  private var compactViewTools: some View {
    HStack(spacing: 8) {
      if !store.cameraOnly {
        Button { showingLook = true } label: { BarLabel(title: "Text", symbol: "textformat.size") }
          .buttonStyle(BarButtonStyle())
          .popover(isPresented: $showingLook) { lookPopover }
      }
      BarToggle(title: "Key", symbol: "list.bullet.rectangle", isOn: showKey) { showKey.toggle() }
      PresenterCleanMenu(selected: store.cleanLook, active: store.cleanScreen,
        keepMicMeter: $store.keepMicMeter, choose: store.chooseCleanLook,
        leave: { store.setCleanScreen(false) })
    }
  }

  private var microphoneName: String {
    store.microphoneSources.first { $0.id == store.selectedMicrophone }?.name ?? (store.usesMacMic ? "Mac microphone" : "iPad microphone")
  }

  private func cameraCard(size: CGSize) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      if showKey && (cameraIsOn || referencePicture != nil) {
        PresenterExposureKey(guides: camera.previewGuides, expanded: $keyExpanded)
      }
      Button { showingCamera = true } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(camera.isShowingMac ? (store.cameraSources.first { $0.id == store.selectedCamera }?.name ?? "Mac camera")
            : (camera.devices.first { $0.id == camera.selectedID }?.name ?? "Camera"))
            .font(.system(size: 16, weight: .semibold))
          Text(cameraIsOn ? (camera.isShowingMac ? "From " + (store.macDisplayName ?? "Mac") : "This iPad") : "Camera off")
          if camera.isShowingMac, let source = store.cameraSources.first(where: { $0.id == store.selectedCamera }) {
            Text(source.detail)
          }
          if !camera.isShowingMac, let device = camera.devices.first(where: { $0.id == camera.selectedID }) {
            Text(device.isExternal ? "USB-C capture" : "Built-in")
            if let mode = camera.mode { Text(mode) }
            else { Text(PadRemote.Source(id: device.id, name: device.name, width: device.width, height: device.height, fps: device.fps).detail) }
          }
          Text(store.flip ? "Upside down" : "Landscape · Upright")
          if store.mirror { Text("Mirrored") }
        }
        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      }.buttonStyle(.plain)
        .popover(isPresented: $showingCamera) {
          VStack(alignment: .leading, spacing: 16) {
            Text("Camera and shot").font(.headline)
            cameraButton(compact: false)
            turnGroup
          }.padding(24).presentationCompactAdaptation(.popover)
        }
      Spacer()
    }
    .frame(width: min(240, size.width / 4))
    .padding(.leading, 16).padding(.top, 88).padding(.bottom, 160)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Beside the Camera button, not over the script.
  private var offNote: some View {
    Text(offText)
      .font(.system(size: 16))
      .foregroundStyle(PresenterTheme.muted)
      .padding(.horizontal, 16).padding(.vertical, 8)
      .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PresenterTheme.line))
  }

  private var offText: String {
    let camera = macConnected && !store.cameraOn ? (store.cameraOnly ? "Camera off." : "Camera off: black behind the script.") : nil
    let mic = !store.micOn && !store.cameraOnly ? "Mic off: the script won’t follow your voice." : nil
    return [camera, mic].compactMap { $0 }.joined(separator: " ")
  }

  private var cameraIsOn: Bool { camera.isShowingMac ? store.cameraOn : camera.isOn }

  private func cameraButton(compact: Bool) -> some View {
    let name = camera.isShowingMac ? store.cameraSources.first { $0.id == store.selectedCamera }?.name
      : camera.devices.first { $0.id == camera.selectedID }?.name
    // "Sony FX3 · HDMI capture" shows as "Sony FX3"; the menu holds the full name.
    let title = !cameraIsOn ? "Camera off" : (name?.components(separatedBy: " · ").first ?? "Camera")
    return BarDeviceControl(
      offIsWarning: false, title: "Camera", offTitle: "Camera off", onSymbol: "video.fill", offSymbol: "video.slash.fill", isOn: cameraIsOn,
      toggleHelp: title, menuLabel: "Choose camera", menuValue: title,
      toggle: {
        if camera.isShowingMac { store.setCameraOn(!store.cameraOn) } else { camera.isOn.toggle() }
      }
    ) {
      DevicePickerCards(store: store, microphone: false)

    }
  }

  private func micButton(compact: Bool) -> some View {
    let title = !store.micOn ? "Mic off" : store.usesMacMic ? "Mac mic" : "iPad mic"
    return BarDeviceControl(
      title: "Mic", onSymbol: "mic.fill", offSymbol: "mic.slash.fill", isOn: store.micOn,
      toggleHelp: title, menuLabel: "Choose microphone", menuValue: title, toggle: { store.setMicOn(!store.micOn) }
    ) {
      DevicePickerCards(store: store, microphone: true)

    }
  }

  // All picture tools share CameraGuides with the remote controls.
  private var zebras: Binding<Bool> { $camera.guides.manualExposure(\.zebras) }
  private var guides: Binding<Bool> {
    Binding(
      get: { camera.guides.thirds || camera.guides.axes || camera.guides.bullseye },
      set: { on in
        camera.guides.thirds = on
        if !on { camera.guides.axes = false; camera.guides.bullseye = false }
      })
  }

  private var pictureTools: some View {
    BarGroup(label: "Picture tools", raised: false) {
      BarToggle(title: "Zebras", symbol: "rectangle.pattern.checkered", isOn: zebras.wrappedValue) { zebras.wrappedValue.toggle() }
      BarToggle(title: "False colour", symbol: "circle.lefthalf.filled", isOn: falseColour) { camera.guides.changeExposure { $0.falseColour.toggle() } }
      BarToggle(title: "Guides", symbol: "squareshape.split.3x3", isOn: guides.wrappedValue) { guides.wrappedValue.toggle() }
    }
  }

  private var lookPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker("Font", selection: $store.settings.fontName) {
        ForEach(ScriptRenderer.presenterFonts, id: \.self) { Text($0).tag($0) }
      }
      Picker("Reading mode", selection: $store.settings.mode) {
        Text("Voice follow").tag("Voice"); Text("Automatic scroll").tag("Manual")
      }
      if !isVoice { Stepper("\(Int(settings.speed)) wpm", value: $store.settings.speed, in: 20...300, step: 10) }
      HStack {
        Text("Text size")
        Spacer(minLength: 24)
        stepper("Smaller text", "A−") { stepFont(-4) }
        Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(minWidth: 64)
        stepper("Larger text", "A+") { stepFont(4) }
      }
      HStack {
        Text("Margins")
        Spacer(minLength: 24)
        stepper("Wider margins", "−") { stepWidth(-0.05) }
        Text("\(Int((settings.textWidth * 100).rounded()))%").monospacedDigit().frame(minWidth: 64)
        stepper("Narrower margins", "+") { stepWidth(0.05) }
      }
    }
    .font(.system(size: 17))
    .foregroundStyle(PresenterTheme.text)
    .padding(16)
    .frame(width: 380)
    .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
    .presentationCompactAdaptation(.popover)
  }

  private func stepper(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(symbol).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
        .background(PresenterTheme.card2, in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  // MARK: Clean full screen

  /// Only text, line and meter; a tap anywhere, a swipe up or a tap on the handle brings the controls back.
  private var cleanHandle: some View {
    VStack {
      Spacer()
      Capsule().fill(.white.opacity(0.22)).frame(width: 80, height: 4)
        .frame(width: 160, height: 44)
        .contentShape(Rectangle())
        .onTapGesture { store.setCleanScreen(false) }
        .accessibilityLabel("Show controls")
        .accessibilityAddTraits(.isButton)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { store.setCleanScreen(false) }
    .padding(.bottom, 4)
    .overlay(alignment: .bottom) {
      Color.clear.frame(height: 64).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height < -30 { store.setCleanScreen(false) } })
    }
  }

  // MARK: Keys

  private func stepFont(_ delta: Double) {
    store.settings.fontSize = min(max(store.settings.fontSize + delta, 18), 120)
  }

  private func stepWidth(_ delta: Double) {
    store.settings.textWidth = PrompterSettings.clampedTextWidth(store.settings.textWidth + delta)
  }

  /// Keyboards, presentation clickers and foot pedals. Most clickers send Page Up and Page Down
  /// or the arrow keys; pedals are usually set to Space or the arrows.
  private func handle(_ press: KeyPress) -> KeyPress.Result {
    guard !store.editing else { return .ignored }
    if store.cameraOnly {
      // Only Escape, Mirror and Flip mean anything with no script; the reading keys are left alone.
      switch (press.key, press.characters) {
      case (.escape, _): if store.cleanScreen { store.setCleanScreen(false) } else { store.closePresenter() }
      case (_, "m"): store.setMirror(!store.mirror)
      case (_, "f"): store.setFlip(!store.flip)
      default: return .ignored
      }
      return .handled
    }
    switch press.key {
    case .space, .return:
      if session.isActivelyRunning || counting { session.pause() } else { startReading() }
    case .pageDown, .rightArrow, .downArrow:
      if session.isManual, press.key == .downArrow { store.settings.speed = min(store.settings.speed + 10, 300) }
      else { session.nextPassage() }
    case .pageUp, .leftArrow, .upArrow:
      if session.isManual, press.key == .upArrow { store.settings.speed = max(store.settings.speed - 10, 20) }
      else { session.previousPassage() }
    case .home:
      session.restart()
    case .escape:
      if store.cleanScreen { store.setCleanScreen(false) } else { store.closePresenter() }
    default:
      switch press.characters {
      case "+", "=": stepFont(4)
      case "-": stepFont(-4)
      case "m": store.setMirror(!store.mirror)
      case "f": store.setFlip(!store.flip)
      case "v": store.settings.mode = settings.mode == "Voice" ? "Manual" : "Voice"
      default: return .ignored
      }
    }
    return .handled
  }
}

// MARK: - Parts

/// Observes the meter itself, so a level arriving 20 times a second redraws only this.
private struct PresenterMeter: View {
  @ObservedObject var meter: RemoteMicMeter
  let name: String
  var isListening = true
  var showsHeading = true
  @State private var input = InputMeter()
  var body: some View {
    MicMeterView(meter: input, micName: name, showsHeading: showsHeading, isListening: isListening)
      .background { RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).fill(Surfaces.scrim).padding(.vertical, -Space.md) }
      .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
        input.show(peakDBFS: Float(meter.levelDB), isClipping: meter.levelDB >= -0.1)
      }
      .onChange(of: meter.levelDB, initial: true) { _, level in
        input.show(peakDBFS: Float(level), isClipping: level >= -0.1)
      }
  }
}

private enum PadKind { case plain, primary, lit, card }

private struct PadLabel: View {
  let title: String
  var icon: String?
  var text: String?
  var showsTitle = true
  var caret = false
  var maxTitleWidth: CGFloat?
  var body: some View {
    HStack(spacing: 8) {
      if let icon { Image(systemName: icon).font(.system(size: 18, weight: .medium)) }
      if let text { Text(text).font(.system(size: 18, weight: .semibold)) }
      if showsTitle, text == nil { Text(title).lineLimit(1).frame(maxWidth: maxTitleWidth, alignment: .leading) }
      if caret { Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)) }
    }
  }
}

extension View {
  fileprivate func padChrome(kind: PadKind, square: Bool = false, minWidth: CGFloat = 0, height: CGFloat = 52) -> some View {
    self
      .font(.system(size: 17, weight: kind == .primary ? .semibold : .regular))
      .foregroundStyle(kind == .primary ? PresenterTheme.ink : kind == .lit ? PresenterTheme.accent : PresenterTheme.text)
      .padding(.horizontal, square ? 0 : 16)
      .frame(minWidth: square ? height : minWidth, minHeight: height)
      .frame(width: square ? height : nil)
      .background(
        kind == .primary ? PresenterTheme.accent : kind == .lit ? Color.white.opacity(0.2) : kind == .card ? PresenterTheme.card : PresenterTheme.card2,
        in: RoundedRectangle(cornerRadius: 12))
      .overlay { if kind == .card { RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).strokeBorder(PresenterTheme.line) } }
      .contentShape(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
  }
}

/// A bar button: a title with an optional icon, or an icon alone (always labelled for VoiceOver).
private struct PadButton: View {
  let title: String
  var icon: String?
  var text: String?
  var kind: PadKind
  var showsTitle: Bool
  var minWidth: CGFloat
  var height: CGFloat
  let action: () -> Void

  init(
    _ title: String, icon: String? = nil, text: String? = nil, kind: PadKind = .plain, showsTitle: Bool = true,
    minWidth: CGFloat = 0, height: CGFloat = 52, action: @escaping () -> Void
  ) {
    self.title = title; self.icon = icon; self.text = text; self.kind = kind
    self.showsTitle = showsTitle; self.minWidth = minWidth; self.height = height; self.action = action
  }

  var body: some View {
    Button(action: action) {
      PadLabel(title: title, icon: icon, text: text, showsTitle: showsTitle)
        .padChrome(kind: kind, square: !showsTitle, minWidth: minWidth, height: height)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .hoverEffect(.highlight)
  }
}

private struct TurnButton: View {
  let title: String
  let symbol: String
  let isOn: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 20, weight: .medium))
        .foregroundStyle(isOn ? PresenterTheme.accent : PresenterTheme.text)
        .frame(width: 52, height: 48)
        .background(isOn ? PresenterTheme.lit : Color.clear, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
        .contentShape(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
  }
}

/// Touch-sized versions of the Mac Adjust cards. The source also chooses who follows the voice.
struct DevicePickerCards: View {
  @ObservedObject var store: PadStore
  let microphone: Bool
  @State private var showMeter = true
  @State private var connect = false
  @State private var channelRevision = 0
  @State private var contentHeight: CGFloat = 600
  var connected: Bool { store.camera.link.macName != nil }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(microphone ? "Microphone" : "Camera").font(.title2.bold())
          Spacer()
          if microphone { Toggle("Show meter", isOn: $showMeter).tint(.yellow).fixedSize() }
        }
        if !microphone { Text("Pick the camera, then make the picture upright.").foregroundStyle(.secondary) }
        heading("On " + (store.macDisplayName ?? "Mac"), symbol: "laptopcomputer", badge: connected ? "Mac" : "Not connected", active: connected)
        if connected {
          if microphone {
            card(.init(id: "", name: "System default", connection: "Use the Mac’s selected input"), mac: true)
            ForEach(store.macStatus.microphones ?? []) { card($0, mac: true) }
          } else { ForEach(store.cameraSources) { card($0, mac: true) } }
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text("Available when this iPad is connected to the Mac").foregroundStyle(.secondary)
            Button("Connect to a Mac") { connect = true }.frame(minHeight: 44)
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5])))
        }
        Divider().overlay(.white.opacity(0.25))
        heading("On " + store.camera.link.deviceName, symbol: "ipad", badge: "iPad", active: !store.usesMacMic)
        if microphone {
          if store.localMicrophones.isEmpty { card(.init(id: "", name: "iPad microphone", connection: "Built-in"), mac: false) }
          ForEach(store.localMicrophones) { card($0, mac: false) }
        } else {
          ForEach(store.camera.devices.filter { !$0.isMac }) { device in
            card(.init(id: device.id, name: device.name,
              connection: device.isExternal ? "USB-C capture" : "Built-in · faces away under the glass",
              width: device.width, height: device.height, fps: device.fps), mac: false)
          }
          CameraRotationMenu(angle: store.camera.guides.rotation.rawValue, choose: store.setCameraRotation)
          Text("Dim picture · \(Int(store.settings.videoDimming * 100))%").font(.headline)
          Slider(value: $store.settings.videoDimming, in: 0...1).accessibilityLabel("Dim picture")
          Text("Picture").font(.headline)
          HStack(spacing: 4) {
            picture("Off", .off); picture("Behind the script", .behindScript); picture("Monitor only", .monitorOnly)
          }
        }
        Text(microphone ? "Speak to check your level." : "Remembered for each camera.").font(.callout).foregroundStyle(.secondary)
      }.padding(20)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }.frame(width: 500, height: min(680, contentHeight))
      .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      .clipShape(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner)).preferredColorScheme(.dark)
      .onAppear { if microphone { store.showPickerMeter(showMeter) } }
      .onDisappear { if microphone { store.showPickerMeter(false) } }
      .onChange(of: showMeter) { _, value in if microphone { store.showPickerMeter(value) } }
      .onChange(of: store.selectedMicrophone) { _, _ in if microphone { store.showPickerMeter(showMeter) } }
      .onChange(of: store.micOn) { _, _ in if microphone { store.showPickerMeter(showMeter) } }
      .onChange(of: store.usesMacMic) { _, _ in if microphone { store.showPickerMeter(showMeter) } }
      .sheet(isPresented: $connect) { MacControlScreen(link: store.camera.link).environmentObject(store) }
  }
  private func heading(_ name: String, symbol: String, badge: String, active: Bool) -> some View {
    HStack { Label(name, systemImage: symbol).font(.headline); Text(badge).font(.caption.bold())
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(active ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.2), in: Capsule())
      .foregroundStyle(active ? .yellow : .secondary) }.padding(.top, 4)
  }
  private func selected(_ source: PadRemote.Source, mac: Bool) -> Bool {
    if microphone { return store.usesMacMic == mac && (store.selectedMicrophone ?? (mac ? "" : AudioCapture.defaultDevice()?.uid ?? "")) == source.id }
    return mac ? store.camera.isShowingMac && store.selectedCamera == source.id : store.camera.selectedID == source.id
  }
  private func card(_ source: PadRemote.Source, mac: Bool) -> some View {
    let chosen = selected(source, mac: mac)
    return VStack(alignment: .leading, spacing: 12) {
      Button {
        if microphone { store.chooseMicrophone(source.id, onMac: mac) }
        else if mac { store.camera.selectedID = PadCamera.macLinkID; store.selectCamera(source.id); store.setCameraOn(true); store.camera.isOn = true }
        else { store.camera.selectedID = source.id; store.camera.isOn = true }
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            DeviceChoiceLabel(name: source.name, selected: chosen).font(.body.bold())
            Text(source.detail).font(.callout).foregroundStyle(.white.opacity(0.75))
          }
          Spacer()
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
        .disabled(microphone && mac && store.macStatus.supportsMicSelection != true && !store.usesMacMic)
      if microphone && chosen {
        if showMeter { PresenterMeter(meter: store.micMeter, name: source.name, isListening: store.micOn, showsHeading: false).frame(height: 96) }
        if (source.channels ?? 1) > 1 || (mac ? store.macStatus.microphoneChannel ?? "Both" : AudioChannel.load(source.id).rawValue) != "Both" {
          HStack {
            Text("Channel")
            ForEach(["Both", "Left", "Right"], id: \.self) { value in
              let current = mac ? store.macStatus.microphoneChannel ?? "Both" : AudioChannel.load(source.id).rawValue
              Button(value) { store.chooseChannel(value, onMac: mac); channelRevision += 1; store.showPickerMeter(showMeter) }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(current == value ? Color.yellow.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
          }.id(channelRevision)
        }
      }
    }.padding(12).frame(minHeight: 64)
      .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(chosen ? Color.yellow : Color.white.opacity(0.12), lineWidth: chosen ? 2 : 1))
  }
  private func picture(_ label: String, _ mode: PadRemote.PictureMode) -> some View {
    Button(label) { store.setPictureMode(mode) }.font(.callout)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(store.pictureMode == mode ? Color.yellow.opacity(0.2) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
  }
}
