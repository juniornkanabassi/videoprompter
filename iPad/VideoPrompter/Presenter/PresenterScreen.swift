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
  @State private var setup = true
  @State private var showScript = true
  @State private var showingLook = false
  @State private var falseColour = false
  @State private var hadMac = false
  @State private var editingRecord: ScriptRecord?
  @FocusState private var focused: Bool

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
      ZStack {
        background
        if store.pictureMode == .monitorOnly, !store.cameraOnly {
          // The confidence monitor replaces the presenter while the picture is monitor only.
          ConfidenceMonitorView(camera: camera)
        } else {
          if store.cameraOnly { cameraOnlyLayer(size) } else { scriptLayer(size) }
          if !store.cleanScreen {
            chrome
            if !counting {
              if setup || store.cameraOnly { setupBar(width: size.width) } else { readingControls }
            }
            if !store.cameraOnly { status }
          } else {
            cleanHandle
          }
          if counting { countdown(size) }
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
      focused = true
      hadMac = macConnected
      useOwnCameraWithoutMac()
    }
    .onChange(of: camera.link.macName) { _, name in
      if name != nil { hadMac = true }
      useOwnCameraWithoutMac()
    }
    .onChange(of: store.cameraOnly) { _, _ in useOwnCameraWithoutMac() }
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

  // MARK: Behind and on the script

  @ViewBuilder private var background: some View {
    // Camera Only draws its own picture; one picture layer is never in two views.
    if store.pictureMode == .behindScript, camera.isOn, !store.cameraOnly {
      Group {
        if camera.isShowingMac {
          LinkPreview(camera: camera, link: camera.link)
        } else {
          CameraPreview(camera: camera)
        }
      }
      .ignoresSafeArea()
      Color(uiColor: ScriptRenderer.colour(settings.backgroundColorHex)).opacity(settings.videoDimming).ignoresSafeArea()
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
  /// operator's screen and handed to the turned layer the right way round, so Flip never carries
  /// the text under the controls.
  private func scriptLayer(_ size: CGSize) -> some View {
    let turn = PadPresenterLayout.turn(mirror: store.mirror, flip: store.flip)
    let insets = PadPresenterLayout.scriptInsets(
      width: size.width, cleanScreen: store.cleanScreen, setup: setup, lostPaused: lostPaused, offNote: showsOffNote)
    // In the turned layer's own coordinates: Flip swaps top and bottom.
    let top = store.flip ? insets.bottom : insets.top
    let bottom = store.flip ? insets.top : insets.bottom
    let height = max(size.height - top - bottom, 1)
    let lineY = min(max(size.height * settings.guideFraction, top + 40), top + height - 40)
    let showsLine = !setup && showScript
    let showsMeter = store.micOn && isVoice
    let fade = store.cleanScreen ? 0 : min(40, height / 4) / height
    return ZStack(alignment: .topLeading) {
      if showScript {
        ScriptCanvas(
          document: session.document, tokenIndex: session.tokenIndex,
          lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
          isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
          // The reading rule rests just under the current line, at lineY in the layer.
          layoutGuideFraction: (lineY - top) / height,
          style: ScriptStyle(settings), textWidth: settings.textWidth,
          manualPosition: session.isManual ? { [session] in session.manualPosition() }
            : UIAccessibility.isReduceMotionEnabled ? nil : { [session] in session.voicePosition() },
          onSeek: { session.seek(to: $0) },
          onUserScroll: { session.seekFromUserScroll(to: $0) },
          onSingleTap: store.cleanScreen ? { store.setCleanScreen(false) } : nil)
        .frame(width: size.width, height: height)
        .mask(
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0), .init(color: .black, location: fade),
              .init(color: .black, location: 1 - fade), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .offset(y: top)
      }
      if showsLine {
        ReadingLine(opacity: settings.guideOpacity * 0.75, trailing: showsMeter ? 96 : 24)
          .frame(width: size.width, height: 24)
          .offset(y: lineY - 12)
          .allowsHitTesting(false)
      }
      if showsMeter {
        PresenterMeter(meter: store.micMeter)
          .frame(width: 64)
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
          .padding(.leading, ScriptCanvas.sideInset(width: size.width, textWidth: settings.textWidth))
          .frame(width: size.width, height: band, alignment: .leading)
          .offset(y: store.flip ? size.height - PadPresenterLayout.topChrome - band : PadPresenterLayout.topChrome)
          .allowsHitTesting(false)
      }
    }
    .frame(width: size.width, height: size.height)
    .scaleEffect(x: turn.a, y: turn.d)
  }

  /// Camera Only: the picture alone, turned with Mirror and Flip like the confidence monitor, with
  /// the Mac's recording frame and its meter. Without a Mac the meter would read nothing, so it is left out.
  private func cameraOnlyLayer(_ size: CGSize) -> some View {
    let turn = PadPresenterLayout.turn(mirror: store.mirror, flip: store.flip)
    let recording = macConnected ? store.recordingState : .standby
    return ZStack {
      Color.black
      if macConnected {
        if store.cameraOn { LinkPreview(camera: camera, link: camera.link) }
      } else if camera.isOn {
        CameraPreview(camera: camera)
      }
      if recording != .standby {
        Rectangle().strokeBorder(recordingColour(recording), lineWidth: recording == .recording ? 8 : 5)
      }
    }
    .frame(width: size.width, height: size.height)
    .scaleEffect(x: turn.a, y: turn.d)
    .contentShape(Rectangle())
    .onTapGesture { if store.cleanScreen { store.setCleanScreen(false) } }
    .overlay(alignment: .trailing) {
      if macConnected {
        PresenterMeter(meter: store.micMeter)
          .frame(width: 64)
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

  private var readingControls: some View {
    GeometryReader { geometry in
      // Narrow screens give the recovery card a row of its own above the transport.
      let stacked = lostPaused && PadPresenterLayout.lostCardStacks(width: geometry.size.width)
      VStack(alignment: .leading, spacing: 8) {
        Spacer()
        if stacked { lostCard }
        if !lostPaused, PadPresenterLayout.statusStacks(width: geometry.size.width) { statusPill }
        HStack(spacing: 8) {
          if lostPaused { if !stacked { lostCard } } else if !PadPresenterLayout.statusStacks(width: geometry.size.width) { statusPill }
          Spacer(minLength: 12)
          turnGroup
          PadButton("Back to start", icon: "arrow.counterclockwise", kind: .card, showsTitle: false) { session.restart() }
          PadButton(primaryTitle, kind: .primary, minWidth: 128, action: primaryAction)
          PadButton("Show controls", icon: "ellipsis", kind: .card, showsTitle: false) { setup = true }
        }
        .padding(.trailing, store.micOn && isVoice ? 112 : 24)
      }
      .padding(.leading, 24)
      .padding(.bottom, 24)
    }
  }

  private var statusPill: some View {
    HStack(spacing: 8) {
      Circle().fill(PresenterTheme.accent).frame(width: 8, height: 8)
      Text(statusText).lineLimit(1)
    }
    .font(.system(size: 16))
    .foregroundStyle(PresenterTheme.text)
    .padding(.horizontal, 16).frame(height: 44)
    .background(PresenterTheme.card, in: Capsule())
    .overlay(Capsule().strokeBorder(PresenterTheme.line))
    .accessibilityElement(children: .combine)
  }

  private var statusText: String {
    let words = session.document.spokenTokens.count
    return PadPresenterLayout.statusText(
      countdown: session.countdownRemaining, running: session.isActivelyRunning, manual: session.isManual,
      speed: Int(settings.speed.rounded()), micOn: store.micOn, macMic: session.followsRemote,
      word: words > 0 ? session.tokenIndex + 1 : 0, words: words)
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
    .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PresenterTheme.warn))
  }

  private var primaryTitle: String {
    if session.isActivelyRunning || counting { return "Pause" }
    return session.hasStartedReading ? "Resume" : "Start reading"
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
    session.startReading()
  }

  /// Mirror and Flip: two independent glass buttons, lit when on, always on screen while presenting.
  private var turnGroup: some View {
    HStack(spacing: 4) {
      TurnButton(
        title: "Mirror left to right",
        symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: store.mirror
      ) { store.setMirror(!store.mirror) }
      TurnButton(
        title: "Flip upside down",
        symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", isOn: store.flip
      ) { store.setFlip(!store.flip) }
    }
    .padding(4)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PresenterTheme.line))
  }

  // MARK: Setting up

  private func setupBar(width: CGFloat) -> some View {
    let folded = PadPresenterLayout.foldsPictureTools(width: width)
    let compact = PadPresenterLayout.iconOnly(width: width)
    return VStack(alignment: .leading, spacing: 0) {
      Spacer()
      if showsOffNote {
        offNote.padding(.leading, compact ? 24 : 288).padding(.bottom, 12)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          if !store.cameraOnly {
            PadButton(primaryTitle, kind: .primary, minWidth: compact ? 0 : 160, action: primaryAction)
            PadButton("Back to start", icon: "arrow.counterclockwise", kind: .plain, showsTitle: false) { session.restart() }
            Rectangle().fill(PresenterTheme.line).frame(width: 1, height: 48).padding(.horizontal, 8)
          }
          cameraButton(compact: compact)
          micButton(compact: compact)
          if !store.cameraOnly {
            PadButton("Script", icon: "doc.text", kind: showScript ? .lit : .plain, showsTitle: !compact) {
              showScript.toggle()
            }
          }
          Spacer(minLength: 12)
          if folded { pictureMenu(compact: compact) } else { pictureTools }
          turnGroup
          if !store.cameraOnly {
            PadButton("Look: text size and margins", icon: nil, text: "Aa", kind: .plain, showsTitle: false) { showingLook = true }
              .popover(isPresented: $showingLook) { lookPopover }
          }
          PadButton("Clean screen", icon: "arrow.up.left.and.arrow.down.right", kind: .plain, showsTitle: false) {
            store.setCleanScreen(true)
          }
        }
        .padding(.horizontal, 24)
        .frame(minWidth: width)
        .frame(height: 100)
      }
      .scrollBounceBehavior(.basedOnSize)
      .background(PresenterTheme.bar)
      .overlay(alignment: .top) { Rectangle().fill(PresenterTheme.line).frame(height: 1) }
    }
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

  private var cameraIsOn: Bool { macConnected ? store.cameraOn : camera.isOn }

  private func cameraButton(compact: Bool) -> some View {
    let name = store.cameraSources.first { $0.id == store.selectedCamera }?.name
    // "Sony FX3 · HDMI capture" shows as "Sony FX3"; the menu holds the full name.
    let title = !cameraIsOn ? "Camera off" : (name?.components(separatedBy: " · ").first ?? "Camera")
    return SplitButton(
      title: title, icon: cameraIsOn ? "video" : "video.slash", showsTitle: !compact, isOff: !cameraIsOn,
      caretLabel: "Choose camera",
      action: {
        if macConnected { store.setCameraOn(!store.cameraOn) } else { camera.isOn.toggle() }
      }
    ) {
      Section("Camera picture from the Mac") {
        if macConnected {
          ForEach(store.cameraSources) { source in
            Button { store.selectCamera(source.id) } label: {
              if source.id == store.selectedCamera { Label(source.name, systemImage: "checkmark") } else { Text(source.name) }
            }
          }
        } else {
          ForEach(camera.devices, id: \.id) { device in
            Button { camera.selectedID = device.id } label: {
              if device.id == camera.selectedID { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
            }
          }
        }
      }
      if !store.cameraOnly {
        Picker("Picture", selection: Binding(get: { store.pictureMode }, set: { store.setPictureMode($0) })) {
          Text("Off (black behind the script)").tag(PadRemote.PictureMode.off)
          Text("Behind the script").tag(PadRemote.PictureMode.behindScript)
          Text("Monitor only").tag(PadRemote.PictureMode.monitorOnly)
        }
      }
    }
  }

  private func micButton(compact: Bool) -> some View {
    let title = !store.micOn ? "Mic off" : store.usesMacMic ? "Mac mic" : "iPad mic"
    return SplitButton(
      title: title, icon: store.micOn ? "mic" : "mic.slash", showsTitle: !compact, isOff: !store.micOn,
      caretLabel: "Choose microphone", action: { store.setMicOn(!store.micOn) }
    ) {
      if macConnected, !store.cameraOnly {
        Picker("Voice from", selection: Binding(get: { store.voiceSource }, set: { store.setVoiceSource($0) })) {
          // The iPad cannot start the Mac's voice relay; choosing the Mac here would leave it waiting for words.
          // Once the Mac has started it (voiceSource is Mac), it stays selectable.
          Text(store.voiceSource == "Mac" ? "The Mac" : "The Mac (start it from the Mac)").tag("Mac")
            .disabled(store.voiceSource != "Mac")
          Text("This iPad").tag("iPad")
        }
      }
      Section("Microphone") {
        ForEach(store.microphoneSources) { source in
          Button { store.selectMicrophone(source.id) } label: {
            if source.id == store.selectedMicrophone { Label(source.name, systemImage: "checkmark") } else { Text(source.name) }
          }
        }
      }
    }
  }

  // Zebras and Guides keep their state on the camera's guides; False colour is kept here.
  private var zebras: Binding<Bool> { Binding(get: { camera.guides.zebras }, set: { camera.guides.zebras = $0 }) }
  private var guides: Binding<Bool> {
    Binding(
      get: { camera.guides.thirds || camera.guides.axes || camera.guides.bullseye },
      set: { on in
        camera.guides.thirds = on
        if !on { camera.guides.axes = false; camera.guides.bullseye = false }
      })
  }

  private var pictureTools: some View {
    HStack(spacing: 4) {
      ToolButton(title: "Zebras", symbol: "rectangle.pattern.checkered", isOn: zebras)
      ToolButton(title: "False colour", symbol: "circle.lefthalf.filled", isOn: $falseColour)
      ToolButton(title: "Guides", symbol: "grid", isOn: guides)
    }
    .padding(4)
    .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: 16))
  }

  /// The same three tools folded into one menu on narrower screens.
  private func pictureMenu(compact: Bool) -> some View {
    Menu {
      Toggle("Zebras", isOn: zebras)
      Toggle("False colour", isOn: $falseColour)
      Toggle("Guides", isOn: guides)
    } label: {
      PadLabel(title: "Picture", icon: "slider.horizontal.3", showsTitle: !compact, caret: !compact)
        .padChrome(kind: .plain, square: compact)
    }
    .accessibilityLabel("Picture tools")
  }

  private var lookPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("LOOK").font(.system(size: 13)).tracking(0.8).foregroundStyle(PresenterTheme.muted)
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
    .background(PresenterTheme.card)
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
    if store.cameraOnly {
      // Only Escape, Mirror and Flip mean anything with no script; the reading keys are left alone.
      switch (press.key, press.characters) {
      case (.escape, _): store.closePresenter()
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
      store.closePresenter()
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

/// The reading line: a full-width rule under the current line with a marker at the reader's side.
/// It sits in the turned layer, so Mirror puts the marker on the right.
private struct ReadingLine: View {
  var opacity: Double
  var trailing: CGFloat
  var body: some View {
    ZStack(alignment: .leading) {
      Rectangle().fill(PresenterTheme.accent.opacity(opacity)).frame(height: 4)
        .padding(.trailing, trailing)
      Triangle().fill(PresenterTheme.accent).frame(width: 16, height: 24)
    }
  }
}

private struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// Observes the meter itself, so a level arriving 20 times a second redraws only this.
private struct PresenterMeter: View {
  @ObservedObject var meter: RemoteMicMeter
  var body: some View { DBMeter(levelDB: meter.levelDB, axis: .vertical) }
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
        kind == .primary ? PresenterTheme.accent : kind == .lit ? PresenterTheme.lit : kind == .card ? PresenterTheme.card : PresenterTheme.card2,
        in: RoundedRectangle(cornerRadius: 16))
      .overlay { if kind == .card { RoundedRectangle(cornerRadius: 16).strokeBorder(PresenterTheme.line) } }
      .contentShape(RoundedRectangle(cornerRadius: 16))
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

/// Camera and Mic: tapping the main part switches the device off (red, slashed icon) and on again,
/// the caret opens its source menu.
private struct SplitButton<Content: View>: View {
  let title: String
  let icon: String
  let showsTitle: Bool
  let isOff: Bool
  let caretLabel: String
  let action: () -> Void
  @ViewBuilder let menu: () -> Content

  var body: some View {
    HStack(spacing: 0) {
      Button(action: action) {
        PadLabel(title: title, icon: icon, showsTitle: showsTitle, maxTitleWidth: 96)
          .padding(.horizontal, showsTitle ? 16 : 0)
          .frame(minWidth: showsTitle ? 0 : 52, minHeight: 52)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      Rectangle().fill(isOff ? PresenterTheme.offText.opacity(0.25) : PresenterTheme.line).frame(width: 1, height: 52)
      Menu(content: menu) {
        Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)).frame(width: 48, height: 52)
      }
      .accessibilityLabel(caretLabel)
    }
    .font(.system(size: 17))
    .foregroundStyle(isOff ? PresenterTheme.offText : PresenterTheme.text)
    .background(isOff ? PresenterTheme.offFill : PresenterTheme.card2, in: RoundedRectangle(cornerRadius: 16))
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
        .background(isOn ? PresenterTheme.lit : Color.clear, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
  }
}

private struct ToolButton: View {
  let title: String
  let symbol: String
  @Binding var isOn: Bool
  var body: some View {
    Button { isOn.toggle() } label: {
      VStack(spacing: 4) {
        Image(systemName: symbol).font(.system(size: 20))
        Text(title).font(.system(size: 13)).lineLimit(1).fixedSize()
      }
      .foregroundStyle(isOn ? PresenterTheme.accent : PresenterTheme.text)
      .frame(minWidth: 68, minHeight: 44)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(isOn ? PresenterTheme.lit : Color.clear, in: RoundedRectangle(cornerRadius: 12))
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
  }
}
