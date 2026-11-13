import AVFoundation
import PrompterCore
import SwiftUI
import UIKit

/// The full-screen presenter, built from the same parts as the Mac's (PresenterControls, MicMeter,
/// DesignTokens): a stage with the script, the reading line behind the words and the microphone
/// meter on the right edge, and one bar along the bottom. Before reading the bar is the setup bar;
/// while reading it is the slim reading bar. A Bluetooth keyboard, clicker or foot pedal drives it
/// without touching the screen.
struct PresenterScreen: View {
  @EnvironmentObject private var store: PadStore
  @ObservedObject var session: SessionStore
  @ObservedObject var camera: PadCamera
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var reading: Bool
  /// The setup preview: the script over the camera picture, or the picture alone to check the shot.
  @State private var scriptPreview = true
  @State private var barRevealed = false
  @State private var revealTask: Task<Void, Never>?
  @State private var showingSettings = false
  @State private var editing: FolderScript?
  @State private var microphones: [AudioInputDevice] = []
  @State private var micListening = true
  @State private var viewport = CGSize(width: 1180, height: 820)
  @AppStorage("presenterMicLevel251") private var showsMicLevel = true
  /// Reading with nothing but the text, the level meter and the reading line, as on the Mac.
  @AppStorage("presenterFocusMode") private var focusMode = false
  /// While reading, the bar slides away and a tap brings it back.
  @AppStorage("presenterAutoHideBar") private var autoHidesBar = false
  @FocusState private var focused: Bool

  /// The width of the slim microphone strip at the right edge, as on the Mac.
  static let meterWidth: CGFloat = 96

  init(session: SessionStore, camera: PadCamera, startsReading: Bool = false) {
    self.session = session
    self.camera = camera
    _reading = State(initialValue: startsReading || session.isActivelyRunning)
  }

  private var settings: PrompterSettings { store.settings }
  private var showsScript: Bool { reading || scriptPreview || !camera.isOn }
  private var focusActive: Bool { focusMode && reading }
  private var barOverlays: Bool { reading && (focusMode || autoHidesBar) }
  private var readingBarHidden: Bool {
    guard barOverlays, !barRevealed, !showingSettings, editing == nil else { return false }
    return focusMode || session.isActivelyRunning
  }
  private var inputName: String {
    MicMeterView.inputName(uid: settings.audioDeviceUID, devices: microphones, systemDefault: AudioCapture.defaultDevice()?.name)
  }
  private var notice: String? {
    if let notice = session.anchorNotice { return notice }
    if case .uncertain(let text) = session.state { return text }
    return nil
  }

  var body: some View {
    GeometryReader { geometry in
      stage
        .onAppear { viewport = geometry.size }
        .onChange(of: geometry.size) { _, size in viewport = size }
    }
    .background(Color(white: 0.035).ignoresSafeArea())
    .contentShape(Rectangle())
    .onTapGesture { if barOverlays { reveal() } }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !barOverlays { controlBar }
    }
    .overlay(alignment: .bottom) {
      if barOverlays && !readingBarHidden {
        controlBar.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }
    .overlay(alignment: .top) {
      if focusActive { exitPill("Exit Focus", revealed: barRevealed) { focusMode = false } }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: readingBarHidden)
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(phases: .down) { press in handle(press) }
    .onAppear {
      focused = true
      refreshMicrophones()
      micListening = session.listensToMicrophone
    }
    .onDisappear {
      revealTask?.cancel()
      if session.isTestingMicrophone { session.stopMicrophoneTest() }
    }
    .onReceive(session.$listensToMicrophone) { micListening = $0 }
    .onChange(of: session.isActivelyRunning) { _, active in
      if active { reading = true }
      reveal()
    }
    // Between takes the meter listens through the microphone test; Voice reading feeds it itself.
    .task(id: "\(showsMicLevel)-\(micListening)-\(session.isActivelyRunning && !session.isManual)-\(settings.audioDeviceUID ?? "")") {
      let voiceRunning = session.isActivelyRunning && !session.isManual
      // Never asks for the microphone here: Start does, when Voice needs it.
      guard showsMicLevel, micListening, !voiceRunning, AVAudioApplication.shared.recordPermission == .granted else {
        if session.isTestingMicrophone { session.stopMicrophoneTest() }
        return
      }
      session.startMicrophoneTest(deviceUID: settings.audioDeviceUID, gain: settings.inputGain)
    }
    .sheet(isPresented: $showingSettings, onDismiss: { focused = true }) {
      NavigationStack { SettingsScreen() }.environmentObject(store)
    }
    .sheet(item: $editing, onDismiss: { focused = true }) { script in
      ScriptEditor(script: script).environmentObject(store)
    }
  }

  // MARK: Stage

  private var stage: some View {
    GeometryReader { geometry in
      let meterWidth = showsMicLevel ? Self.meterWidth : 0
      let regionWidth = max(1, geometry.size.width - meterWidth)
      HStack(alignment: .top, spacing: 0) {
        region(width: regionWidth, height: geometry.size.height)
        if showsMicLevel {
          MicMeterView(meter: session.meter, micName: inputName, isListening: micListening)
            .frame(width: Self.meterWidth, height: max(0, geometry.size.height - 2 * Space.md))
            .padding(.vertical, Space.md)
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1).padding(.vertical, Space.md) }
        }
      }.foregroundStyle(.white)
    }
  }

  /// The picture region: the camera, a backing behind the words, the reading line, then the script.
  private func region(width: CGFloat, height: CGFloat) -> some View {
    ZStack(alignment: .top) {
      if camera.isOn {
        Group {
          if camera.isShowingMac { LinkPreview(camera: camera, link: camera.link) } else { CameraPreview(camera: camera) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if showsScript {
        Color(uiColor: ScriptRenderer.colour(settings.backgroundColorHex))
          .opacity(reduceTransparency ? 1 : settings.backdropOpacity(withVideo: camera.isOn))
        if camera.isOn {
          ReadingBacking(opacity: reduceTransparency ? 0.9 : 0.45)
            .frame(width: min(width, width * settings.textWidth + 2 * Space.xxl))
            .padding(.vertical, Space.sm)
        }
        // Behind the words, so the line shows where the reading is without striking them through.
        GuideLine(settings: settings)
          .offset(y: ScriptCanvas.visualGuideY(height: height, fraction: settings.guideFraction) - 1)
        ScriptCanvas(
          document: session.document, tokenIndex: session.tokenIndex,
          lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
          isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
          layoutGuideFraction: settings.verticalMirror ? 1 - settings.guideFraction : settings.guideFraction,
          verticalMirror: settings.verticalMirror,
          style: ScriptStyle(settings, overVideo: camera.isOn), textWidth: settings.textWidth,
          manualPosition: session.isManual ? { [session] in session.manualPosition() }
            : UIAccessibility.isReduceMotionEnabled ? nil : { [session] in session.voicePosition() },
          onSeek: { session.seek(to: $0) },
          onUserScroll: { session.seekFromUserScroll(to: $0) })
        .scaleEffect(x: settings.horizontalMirror ? -1 : 1, y: settings.verticalMirror ? -1 : 1)
      }
    }.frame(width: width, height: height).clipped()
  }

  // MARK: Bar

  private var controlBar: some View {
    VStack(spacing: Space.sm) {
      if let notice {
        Label(notice, systemImage: "exclamationmark.circle")
          .font(.callout).lineLimit(2).frame(maxWidth: 560, minHeight: AlphaStyle.minTarget)
          .accessibilityLabel(notice)
      }
      if reading { readingBar } else { setupBar }
    }
    .padding(.horizontal, viewport.width < 600 ? Space.sm : Space.lg)
    .padding(.vertical, reading ? Space.sm : Space.md)
    .frame(maxWidth: .infinity)
    .background(PresenterBar.background.ignoresSafeArea(edges: .bottom))
    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    .foregroundStyle(.white)
    .accessibilityIdentifier("presenter-control-bar")
  }

  /// One row: transport on the left, then the video-call group, then the picture tools. Words give way
  /// to icons, then the groups wrap, as the window narrows (Stage Manager, Split View).
  private var setupBar: some View {
    ViewThatFits(in: .horizontal) {
      setupRow(toolTitles: true, callTitles: true)
      setupRow(toolTitles: false, callTitles: true)
      setupRow(toolTitles: false, callTitles: false)
      VStack(alignment: .leading, spacing: Space.sm) {
        HStack(spacing: Space.sm) { setupTransport }
        HStack(spacing: Space.sm) { callGroup(titles: false); toolsGroup(titles: false) }
      }
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

  @ViewBuilder private var setupTransport: some View {
    Button { reading = true; session.startReading() } label: { BarLabel(title: "Start reading", symbol: "play.fill") }
      .buttonStyle(BarButtonStyle(role: .prominent)).accessibilityLabel("Start reading")
      .disabled(session.activeRecord == nil)
    Button { session.restart() } label: { BarLabel(title: "Back to start", symbol: "arrow.counterclockwise", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Back to start")
    closeButton(role: .secondary)
  }

  private func closeButton(role: BarButtonStyle.Role) -> some View {
    Button { store.closePresenter() } label: { BarLabel(title: "Close", symbol: "xmark", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: role)).accessibilityLabel("Close presenter")
  }

  // MARK: Video-call group: camera, microphone, script

  private var cameraValue: String { camera.devices.first { $0.id == camera.selectedID }?.name ?? "No camera chosen" }

  private func callGroup(titles: Bool) -> some View {
    BarGroup(label: "Camera, microphone and script") {
      BarDeviceControl(title: "Camera", onSymbol: "video.fill", offSymbol: "video.slash.fill", isOn: camera.isOn,
        showsTitle: titles, toggleHelp: camera.isOn ? "Turn the camera off to see just the script" : "Turn the camera on",
        menuLabel: "Choose camera", menuValue: cameraValue, toggle: toggleCamera) { cameraMenu }
      BarDivider()
      micControl(titles: titles)
      BarDivider()
      BarToggle(title: "Script", symbol: "text.alignleft", isOn: scriptPreview || !camera.isOn, showsTitle: titles,
        help: scriptPreview ? "Hide the script" : "Show the script over the picture") { scriptPreview.toggle() }
        .disabled(!camera.isOn)
    }
  }

  private func micControl(titles: Bool) -> some View {
    BarDeviceControl(title: "Mic", onSymbol: "mic.fill", offSymbol: "mic.slash.fill", isOn: micListening,
      showsTitle: titles,
      toggleHelp: micListening ? "Turn the microphone off: Video Prompter stops listening" : "Turn the microphone on",
      menuLabel: "Choose microphone", menuValue: inputName, toggle: toggleMicrophone) { micMenu }
  }

  private func toggleCamera() {
    let turningOff = camera.isOn
    camera.isOn.toggle()
    // Camera off leaves just the script, as in a video call with the picture switched off.
    if turningOff { scriptPreview = true }
    announce("Camera " + (turningOff ? "off" : "on"))
  }

  private func toggleMicrophone() {
    session.setListensToMicrophone(!micListening)
    announce("Microphone " + (micListening ? "off" : "on"))
  }

  @ViewBuilder private var cameraMenu: some View {
    if camera.devices.isEmpty { Text("No camera connected") }
    ForEach(camera.devices) { device in
      Toggle(device.isMac ? "\(device.name) (Mac link)" : device.isExternal ? "\(device.name) (USB-C)" : device.name,
        isOn: Binding(get: { device.id == camera.selectedID }, set: { on in
          guard on else { return }
          camera.selectedID = device.id
          if !camera.isOn { camera.isOn = true }
        }))
    }
    Divider()
    Button("Camera settings…") { showingSettings = true }
  }

  @ViewBuilder private var micMenu: some View {
    Section("Input") {
      ForEach(microphones) { device in
        Toggle(device.name, isOn: Binding(get: { settings.audioDeviceUID == device.uid }, set: { on in
          guard on, settings.audioDeviceUID != device.uid else { return }
          if session.isTestingMicrophone { session.stopMicrophoneTest() }
          store.settings.audioDeviceUID = device.uid
        }))
      }
    }
    Divider()
    Toggle("Show level meter", isOn: $showsMicLevel)
    Button("Microphone settings…") { showingSettings = true }
  }

  private func refreshMicrophones() { microphones = AudioCapture.inputDevices() }

  // MARK: Picture tools

  private func toolsGroup(titles: Bool) -> some View {
    BarGroup(label: "Picture tools") {
      BarToggle(title: "Guides", symbol: "squareshape.split.3x3", isOn: camera.guides.thirds, showsTitle: titles,
        help: "Rule of thirds over the picture") { camera.guides.thirds.toggle() }
      BarToggle(title: settings.horizontalMirror ? "Unmirror" : "Mirror", symbol: "flip.horizontal", isOn: settings.horizontalMirror,
        showsTitle: titles, help: "Mirror the text for teleprompter glass") { store.settings.horizontalMirror.toggle() }
      BarToggle(title: "Smaller text", symbol: "textformat.size.smaller", isOn: false, showsTitle: false,
        help: "Smaller text", traits: []) { stepFont(-4) }
      BarToggle(title: "Larger text", symbol: "textformat.size.larger", isOn: false, showsTitle: false,
        help: "Larger text", traits: []) { stepFont(4) }
      BarDivider()
      BarToggle(title: "Adjust", symbol: "slider.horizontal.3", isOn: false, showsTitle: titles,
        help: "Reading, text, camera and microphone settings", traits: []) { showingSettings = true }
    }
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
          help: "Focus: only the text, the level meter and the reading line") { focusMode.toggle() }
          .contextMenu { Toggle("Auto-hide these controls while reading", isOn: $autoHidesBar) }
        Button { showingSettings = true } label: { BarLabel(title: "Reading settings", symbol: "textformat.size", showsTitle: false) }
          .buttonStyle(BarButtonStyle()).accessibilityLabel("Reading settings")
        if let script = session.activeScriptID.flatMap(store.folder.script) {
          Button { session.pause(); editing = script } label: { BarLabel(title: "Edit script here", symbol: "pencil", showsTitle: false) }
            .buttonStyle(BarButtonStyle()).accessibilityLabel("Edit script")
        }
        closeButton(role: .plain)
      }.frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private var readingPillText: String {
    let state = session.visibleReadingState
    return settings.mode == "Voice" ? "Voice · \(state)" : "Automatic · \(Int(settings.speed)) wpm · \(state)"
  }

  @ViewBuilder private var readingTransport: some View {
    let running = session.isActivelyRunning || session.isCountingDown
    Button { session.restart() } label: { BarLabel(title: "Back to start", symbol: "arrow.counterclockwise", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Back to start")
    Button { session.previousPassage() } label: { BarLabel(title: "Previous passage", symbol: "chevron.up", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Previous passage")
    Button { session.toggle() } label: { BarLabel(title: running ? "Pause" : "Start reading", symbol: running ? "pause.fill" : "play.fill") }
      .buttonStyle(BarButtonStyle(role: running ? .secondary : .prominent))
      .accessibilityLabel(running ? "Pause" : "Start reading")
    Button { session.nextPassage() } label: { BarLabel(title: "Next passage", symbol: "chevron.down", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Next passage")
    Button { session.pause(); reading = false } label: { BarLabel(title: "Set up the shot", symbol: "display", showsTitle: false) }
      .buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Set up the shot")
  }

  /// The pill that leaves Focus: faded out until a tap, still reachable by keyboard.
  private func exitPill(_ title: String, revealed: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: "xmark")
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, Space.md).frame(minHeight: AlphaStyle.minTarget)
        .background(.black.opacity(0.85), in: Capsule()).foregroundStyle(.white)
        .opacity(revealed ? 1 : 0)
    }.buttonStyle(.plain).accessibilityLabel(title).padding(Space.xxl)
  }

  private func announce(_ message: String) {
    UIAccessibility.post(notification: .announcement, argument: message)
  }

  private func stepFont(_ delta: Double) {
    store.settings.fontSize = min(max(store.settings.fontSize + delta, 18), 120)
  }

  /// A tap or a state change brings the bar back for a moment when it hides itself.
  private func reveal() {
    revealTask?.cancel()
    guard barOverlays else { barRevealed = false; return }
    barRevealed = true
    revealTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2.5))
      guard !Task.isCancelled else { return }
      barRevealed = false
    }
  }

  /// Keyboards, presentation clickers and foot pedals. Most clickers send Page Up and Page Down
  /// or the arrow keys; pedals are usually set to Space or the arrows.
  private func handle(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .space, .return:
      session.toggle()
    case .pageDown, .rightArrow, .downArrow:
      if session.isManual, press.key == .downArrow { store.settings.speed = min(store.settings.speed + 10, 300) }
      else { session.nextPassage() }
    case .pageUp, .leftArrow, .upArrow:
      if session.isManual, press.key == .upArrow { store.settings.speed = max(store.settings.speed - 10, 20) }
      else { session.previousPassage() }
    case .home:
      session.restart()
    case .escape:
      if focusActive { focusMode = false } else { store.closePresenter() }
    default:
      switch press.characters {
      case "+", "=": stepFont(4)
      case "-": stepFont(-4)
      case "m": store.settings.horizontalMirror.toggle()
      case "f": focusMode.toggle()
      case "v": store.settings.mode = settings.mode == "Voice" ? "Manual" : "Voice"
      default: return .ignored
      }
    }
    return .handled
  }
}
