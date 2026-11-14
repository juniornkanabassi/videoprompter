#if os(macOS)
import PrompterCore
import SwiftUI

struct IPadRemoteView: View {
  @ObservedObject var link: IPadCameraSender
  @ObservedObject var store: AppStore = .shared
  var stateOverride: PadRemote.State?
  private var currentState: PadRemote.State? { stateOverride ?? link.iPadState }
  private var focusActive: Bool {
    currentState?.look?.focusMode == true && currentState?.look?.presenterSetup != true && currentState?.cameraOnly != true
  }
  var startsLink = true
  var previewOverride: CGImage?
  var panelOverride: String?
  var devicesOverride: [IPadCameraSender.WiFiDevice]?
  @State private var devicesOpen = false
  @State private var renaming = false
  @State private var newName = ""
  @State private var selectedMac: UUID?
  @State private var dragging: Double?
  @State private var textOpen = false
  @State private var pendingSend: (UUID, String)?
  @State private var message: String?
  private let yellow = AlphaStyle.accent

  var body: some View {
    GeometryReader { geometry in
    VStack(spacing: Space.md) {
      if let state = currentState {
        status(state)
        ZStack(alignment: .bottomTrailing) {
          if state.cameraOnly == true || state.presenting == nil || state.pictureMode == .monitorOnly || state.look?.scriptVisible == false {
            liveCamera
          } else {
            if state.pictureMode == .behindScript && !focusActive { liveCamera.opacity(1 - InputValidation.videoDimming.repair(state.look?.videoDimming ?? 0.5)) }
            VStack(spacing: 0) {
              IPadReplicaView(state: state) { link.send(.seek(word: $0 + 1)) }
              if state.cleanScreen != true {
              HStack(spacing: Space.md) {
                Text("Reading position").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { dragging ?? Double(state.word) }, set: { dragging = $0 }), in: 1...Double(max(2, state.words))) { editing in
                  if !editing, let value = dragging { link.send(.seek(word: Int(value.rounded()))); dragging = nil }
                }.labelsHidden().accessibilityLabel("Reading position")
                  .disabled(state.words < 2 || state.editing == true)
              }.padding(.horizontal, Space.md).padding(.bottom, Space.sm)
              }
            }
            if state.pictureMode != .behindScript && state.pictureMode != .off && !focusActive {
              liveCamera.frame(width: 192, height: 108).padding(Space.md) // grid: ok 16:9 camera thumbnail
            }
          }
        }
        .overlay(alignment: .trailing) {
          IPadReplicaMeter(meter: state.voiceSource == "iPad" ? link.iPadMicMeter : link.micMeter,
            name: Self.microphoneName(state), isListening: state.micOn ?? true)
            .frame(width: MicMeterView.stripWidth(typeScale: 1))
            .padding(.top, 48).padding(.bottom, 48).padding(.trailing, Space.sm)
            .allowsHitTesting(false)
        }.background(.black).clipShape(RoundedRectangle(cornerRadius: Space.md))

        if let reason = state.rejectionReason ?? message { Text(reason).foregroundStyle(.orange) }
        RelayNotice(relay: link.relay)
        if (state.look?.presenterSetup ?? !state.running) || state.cameraOnly == true { setupBar(state) }
        else { readingControls(state) }
      } else {
        IPadConnectPanel(link: link).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background {
      if let state = currentState, state.presenting != nil, state.cameraOnly != true {
        HStack {
          Button("Previous passage") { link.send(.previousPassage) }.keyboardShortcut(.leftArrow, modifiers: [])
          Button("Next passage") { link.send(.nextPassage) }.keyboardShortcut(.rightArrow, modifiers: [])
          Button("Previous paragraph") { link.send(.previousPassage) }.keyboardShortcut(.upArrow, modifiers: [])
          Button("Next paragraph") { link.send(.nextPassage) }.keyboardShortcut(.downArrow, modifiers: [])
        }.hidden().disabled(state.editing == true).accessibilityHidden(true)
      }
    }
    .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .overlay(alignment: .bottomTrailing) {
      if let state = currentState, let panelOverride {
        Group {
          if panelOverride == "devices" { deviceChoices(state).padding(Space.lg).frame(width: 400) }
          else if panelOverride == "camera" { VStack(alignment: .leading, spacing: Space.md) { cameraMenu(state) }.padding(Space.lg).frame(width: 400) }
          else if panelOverride == "microphone" { VStack(alignment: .leading, spacing: Space.md) { voiceMenu(state) }.padding(Space.lg).frame(width: 400) }
          else { ScrollView { adjustControls(state).padding(Space.lg) }.frame(width: 460, height: 560) }
        }.background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: Space.md))
          .shadow(radius: Space.md).padding(Space.lg)
      }
    }
    .padding(Space.md)
    .background(Color(red: 30/255, green: 30/255, blue: 31/255))
    .tint(yellow).preferredColorScheme(.dark)
    .frame(minWidth: 760, idealWidth: 960, maxWidth: .infinity, minHeight: 500, idealHeight: 720, maxHeight: .infinity)
    .alert("Rename iPad", isPresented: $renaming) {
      TextField("iPad name", text: $newName)
      Button("Rename") { link.send(.rename(PadIdentity.cleanName(newName))) }
      Button("Cancel", role: .cancel) {}
    } message: { Text("The name is saved on the iPad and shown to nearby Macs.") }
    .onAppear { if startsLink { link.controlsIPad = true } }
    .onDisappear { if startsLink { link.controlsIPad = false } }
    .onReceive(link.$iPadState) { state in
      guard let (id, fingerprint) = pendingSend, let state, state.scripts.contains(where: { $0.macID == id && $0.id == state.presenting && $0.fingerprint == fingerprint }) else { return }
      var sent = UserDefaults.standard.dictionary(forKey: "padRelaySentFingerprints") as? [String: String] ?? [:]
      sent[id.uuidString] = fingerprint
      UserDefaults.standard.set(sent, forKey: "padRelaySentFingerprints")
      pendingSend = nil
    }
  }

  private func setupBar(_ state: PadRemote.State) -> some View {
    PresenterSetupBar(scale: store.uiZoom) {
      deviceMenu(state)
      Button {
        link.send(.look(.init(presenterSetup: false)))
        link.send(.play)
      } label: { BarLabel(title: "Start reading", symbol: "play.fill") }
        .buttonStyle(BarButtonStyle(role: .prominent)).keyboardShortcut(.space, modifiers: [])
        .disabled(state.presenting == nil || state.cameraOnly == true || state.editing == true)
      Button { link.send(.backToStart) } label: { BarLabel(title: "Back", symbol: "arrow.counterclockwise") }
        .buttonStyle(BarButtonStyle(role: .secondary)).keyboardShortcut(.home, modifiers: [])
    } devices: {
      BarGroup(label: "Camera, microphone and script") {
        BarDeviceControl(offIsWarning: false, title: "Camera", offTitle: "Camera off", onSymbol: "video.fill", offSymbol: "video.slash.fill",
          isOn: state.cameraUsesMac == false ? state.localCameraOn ?? false : state.macStatus?.cameraOn ?? link.cameraOn,
          toggleHelp: "Turn camera on or off", menuLabel: "Choose camera", menuValue: state.localCameraID ?? state.macStatus?.selectedCamera ?? "Default",
          toggle: { link.send(.cameraOn(!(state.cameraUsesMac == false ? state.localCameraOn ?? false : state.macStatus?.cameraOn ?? link.cameraOn))) }) { cameraMenu(state) }
        BarDivider()
        micControl(state)
        PresenterLinkedLevel(meter: state.voiceSource == "iPad" ? link.iPadMicMeter : link.micMeter)
        BarDivider()
        BarToggle(title: "Script", symbol: "text.alignleft", isOn: state.look?.scriptVisible ?? true) {
          link.send(.look(.init(scriptVisible: !(state.look?.scriptVisible ?? true))))
        }.disabled(state.cameraOnly == true)
      }
    } tools: {
      BarGroup(label: "Picture tools", raised: false) {
        BarToggle(title: "Zebras", symbol: "rectangle.pattern.checkered", isOn: state.guides?.zebras ?? false) {
          link.send(.cameraGuides(.init(zebras: !(state.guides?.zebras ?? false))))
        }
        BarToggle(title: "False colour", symbol: "circle.lefthalf.filled", isOn: state.guides?.falseColour ?? false) {
          link.send(.cameraGuides(.init(falseColour: !(state.guides?.falseColour ?? false))))
        }
        BarToggle(title: "Guides", symbol: "squareshape.split.3x3", isOn: state.guides?.thirds == true || state.guides?.centre == true) {
          let on = state.guides?.thirds != true && state.guides?.centre != true
          link.send(.cameraGuides(.init(thirds: on, centre: false)))
        }.contextMenu {
          Toggle("Thirds", isOn: Binding(get: { state.guides?.thirds ?? false }, set: { link.send(.cameraGuides(.init(thirds: $0))) }))
          Toggle("Centre", isOn: Binding(get: { state.guides?.centre ?? false }, set: { link.send(.cameraGuides(.init(centre: $0))) }))
          Picker("Frame marker", selection: Binding(get: { state.guides?.marker ?? "Off" }, set: { link.send(.cameraGuides(.init(marker: $0))) })) {
            Text("Off").tag("Off")
            ForEach(CameraAspect.presets) { Text($0.label).tag($0.label) }
          }
        }
      }
    } options: {
      PresenterTurnControls(mirror: Binding(get: { state.look?.horizontalMirror ?? false }, set: link.setMirror),
        flip: Binding(get: { state.look?.verticalMirror ?? false }, set: link.setFlip))
      textButton(state)
      BarToggle(title: "Key", symbol: "list.bullet.rectangle", isOn: state.guides?.exposureKey ?? true) {
        link.send(.cameraGuides(.init(exposureKey: !(state.guides?.exposureKey ?? true))))
      }
      BarToggle(title: "Clean", symbol: "rectangle", isOn: state.cleanScreen ?? false) { link.setCleanScreen(!(state.cleanScreen ?? false)) }
    }
    .padding(.horizontal, Space.md).background(PresenterBar.background)
  }
  private func micControl(_ state: PadRemote.State) -> some View {
    BarDeviceControl(title: "Mic", onSymbol: "mic.fill", offSymbol: "mic.slash.fill", isOn: state.micOn ?? true,
      toggleHelp: "Turn microphone on or off", menuLabel: "Choose microphone", menuValue: state.selectedMicrophone ?? "Default",
      toggle: { link.setMicOn(!(state.micOn ?? true)) }) { voiceMenu(state) }
  }
  private func textButton(_ state: PadRemote.State) -> some View {
    Button { textOpen.toggle() } label: { BarLabel(title: "Text", symbol: "textformat.size") }
      .buttonStyle(BarButtonStyle())
      .popover(isPresented: $textOpen) { ScrollView { adjustControls(state).padding(Space.lg) }.frame(width: 460, height: 560).uiZoom(store.uiZoom) }
  }
  private var liveCamera: some View {
    Group {
      if currentState?.pictureMode == .off && currentState?.cameraOnly != true {
        Color.black
      } else if let id = currentState?.localCameraID {
        Color.black.overlay {
          Label(currentState?.localCameras?.first(where: { $0.id == id })?.name ?? "Camera on iPad", systemImage: "ipad")
            .foregroundStyle(.secondary)
        }
      } else if let image = previewOverride {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
          .overlay {
            GeometryReader { geometry in
              let guides = currentState.map { Self.replicaGuides($0) } ?? CameraGuides()
              let picture = guides.rotation.fittedRect(aspect: CGSize(width: image.width, height: image.height), in: CGRect(origin: .zero, size: geometry.size))
              Path(CameraOverlay.guidePath(picture: picture, guides: guides)).stroke(Color(cgColor: guides.strokeColor), lineWidth: 1)
            }
          }
      } else if startsLink && link.cameraOn {
        CameraPreview(model: CameraModel.shared, presenter: true,
          guidesOverride: currentState.map { Self.replicaGuides($0, base: CameraModel.shared.guides) })
      } else {
        Color.black.overlay { Label("Camera off", systemImage: "video.slash").foregroundStyle(.secondary) }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
  }
  private func status(_ state: PadRemote.State) -> some View {
    HStack { Text(state.deviceName ?? "iPad").font(.headline); Spacer(); scriptMenu(state) }
  }
  private func deviceChoices(_ state: PadRemote.State) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text("iPads").font(.headline)
      ForEach(devicesOverride ?? link.pairingDevices) { device in
        HStack {
          Button { devicesOpen = false; link.requestPairing(device) } label: {
            Label(link.displayName(for: device), systemImage: "ipad")
          }
          Spacer()
          if link.pairingCode(id: device.id, name: device.name) != nil {
            Button("Forget") { link.forgetIPad(id: device.id) }
          }
        }
      }
      Divider()
      HStack {
        Button("Rename…") { devicesOpen = false; newName = state.deviceName ?? "iPad"; renaming = true }
        Spacer()
        Button("Disconnect") { devicesOpen = false; link.disconnect() }
      }
    }.frame(minWidth: 320)
  }
  private func deviceMenu(_ state: PadRemote.State) -> some View {
    Button { if startsLink { link.usesWiFi = true }; devicesOpen.toggle() } label: {
      HStack { Label(state.deviceName ?? "iPad", systemImage: "ipad"); Image(systemName: "chevron.down") }
    }.fixedSize()
      .popover(isPresented: $devicesOpen) { deviceChoices(state).padding(Space.lg).uiZoom(store.uiZoom) }
  }
  private func cameraMenu(_ state: PadRemote.State) -> some View {
    Group {
      Section {
        ForEach(state.macStatus?.cameras ?? link.cameraSources) { source in
          deviceChoice(source.name, onIPad: false, selected: state.cameraUsesMac != false && state.macStatus?.selectedCamera == source.id) {
            link.chooseCamera(source.id, onIPad: false)
          }
        }
      } header: { Label("On this Mac", systemImage: "laptopcomputer") }
      Divider()
      Section {
        ForEach(state.localCameras ?? []) { source in
          deviceChoice(source.name, onIPad: true, selected: state.localCameraID == source.id) { link.chooseCamera(source.id, onIPad: true) }
        }
        if state.localCameras == nil { Text("Update the iPad app to list its cameras") }
      } header: { Label("On " + (state.deviceName ?? "iPad"), systemImage: "ipad") }
      Divider()
      CameraRotationMenu(angle: state.cameraUsesMac != false ? link.macStatus.cameraRotation ?? CameraModel.shared.guides.rotation.rawValue : state.guides?.rotation ?? 0) {
        link.setCameraRotation($0)
      }
      Picker("Picture", selection: Binding(get: { state.pictureMode ?? .off }, set: link.setPictureMode)) {
        Text("Off").tag(PadRemote.PictureMode.off)
        Text("Behind the script").tag(PadRemote.PictureMode.behindScript)
        Text("Monitor only").tag(PadRemote.PictureMode.monitorOnly)
      }
      lookSlider("Dim picture", value: state.look?.videoDimming ?? 0.5, range: 0...1, percentage: true) { link.send(.look(.init(videoDimming: $0))) }
      Picker("Quality", selection: Binding(get: { state.picturePriority ?? .realTime720p }, set: link.setPicturePriority)) {
        Text("Real time 720p").tag(PadRemote.PicturePriority.realTime720p)
        Text("Sharper 1080p").tag(PadRemote.PicturePriority.sharper1080p)
      }
    }
  }
  /// A menu row with the device's Mac or iPad icon and the native tick on the one that is live.
  private func deviceChoice(_ name: String, onIPad: Bool, selected: Bool, choose: @escaping () -> Void) -> some View {
    Toggle(isOn: Binding(get: { selected }, set: { if $0 { choose() } })) {
      Label(name, systemImage: onIPad ? "ipad" : "laptopcomputer")
    }
  }
  private func voiceMenu(_ state: PadRemote.State) -> some View {
    Group {
      Section {
        ForEach(state.macStatus?.microphones ?? link.macStatus.microphones ?? []) { source in
          deviceChoice(source.name, onIPad: false, selected: state.voiceSource == "Mac" && state.selectedMicrophone == source.id) {
            link.chooseMicrophone(source.id, onIPad: false)
          }
        }
      } header: { Label("On this Mac", systemImage: "laptopcomputer") }
      Divider()
      Section {
        if let microphones = state.localMicrophones, !microphones.isEmpty {
          ForEach(microphones) { source in
            deviceChoice(source.name, onIPad: true, selected: state.voiceSource == "iPad" && state.selectedMicrophone == source.id) {
              link.chooseMicrophone(source.id, onIPad: true)
            }
          }
        } else {
          deviceChoice("iPad microphone", onIPad: true, selected: state.voiceSource == "iPad") { link.chooseMicrophone("", onIPad: true) }
        }
      } header: { Label("On " + (state.deviceName ?? "iPad"), systemImage: "ipad") }
    }
  }
  private func scriptMenu(_ state: PadRemote.State, title: String? = nil) -> some View {
    Menu {
      ForEach(state.scripts, id: \.id) { script in Button(script.title) { link.send(.present(script.id)) } }
      if !store.scripts.isEmpty {
        Section("Send from this Mac") {
          ForEach(store.scripts) { script in Button(script.metadata.title) { selectedMac = script.id; sendSelected() } }
        }
      }
      if state.presenting != nil { Divider(); Button("Close script") { link.send(.close) } }
    } label: { Label(title ?? state.scripts.first(where: { $0.id == state.presenting })?.title ?? "No script", systemImage: "doc.text") }
      .disabled(state.editing == true).fixedSize()
  }
  private func readingControls(_ state: PadRemote.State) -> some View {
    WrapLayout(spacing: Space.sm, distributeAfter: 2, leading: true) {
      deviceMenu(state)
      BarStatusPill(text: (state.mode == "Voice" ? "Voice" : "Automatic") + (state.running ? " · Reading" : " · Paused"), isActive: state.running)
      Button { link.send(.backToStart) } label: { BarLabel(title: "Restart", symbol: "arrow.counterclockwise") }
        .buttonStyle(BarButtonStyle(role: .secondary)).keyboardShortcut(.home, modifiers: [])
      Button { link.send(state.running ? .pause : .play) } label: {
        BarLabel(title: state.running ? "Pause" : "Start reading", symbol: state.running ? "pause.fill" : "play.fill")
      }.buttonStyle(BarButtonStyle(role: .secondary)).keyboardShortcut(.space, modifiers: [])
      Button { link.send(.pause); link.send(.look(.init(presenterSetup: true))) } label: { BarLabel(title: "Set up", symbol: "camera.viewfinder") }
        .buttonStyle(BarButtonStyle(role: .secondary))
      BarGroup(label: "Reading options") {
        micControl(state)
        PresenterLinkedLevel(meter: state.voiceSource == "iPad" ? link.iPadMicMeter : link.micMeter)
        BarDivider()
        BarToggle(title: "Focus", symbol: "rectangle.expand.vertical", isOn: state.look?.focusMode ?? false) {
          link.send(.look(.init(focusMode: !(state.look?.focusMode ?? false))))
        }
        textButton(state)
      }
    }.padding(Space.sm).background(PresenterBar.background).disabled(state.editing == true)
  }
  func adjustControls(_ state: PadRemote.State) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Picker("Reading mode", selection: Binding(get: { state.mode }, set: { setVoice($0 == "Voice" ? (state.voiceSource == "Mac" ? "mac" : "ipad") : "off", state) })) {
        Text("Voice follow").tag("Voice"); Text("Automatic scroll").tag("Manual")
      }
      if state.mode != "Voice" {
        Stepper("\(state.speed) wpm", value: Binding(get: { state.speed }, set: { link.send(.speed($0)) }), in: 20...300, step: 10)
      }
      Picker("Font", selection: Binding(get: { state.look?.fontName ?? "Lexend Deca" }, set: { link.send(.look(.init(fontName: $0))) })) {
        ForEach(Array(Set(AvailableFonts.presenter + [state.look?.fontName ?? "Lexend Deca"])).sorted(), id: \.self) { Text($0).tag($0) }
      }
      lookSlider("Text size", value: state.look?.fontSize ?? 44, range: InputValidation.fontSize.range) { link.send(.look(.init(fontSize: $0))) }
      lookSlider("Margins", value: state.look?.textWidth ?? 1, range: InputValidation.textWidth.range) { link.send(.look(.init(textWidth: $0))) }
      lookSlider("Line spacing", value: state.look?.lineSpacing ?? 0.16, range: InputValidation.lineSpacing.range) { link.send(.look(.init(lineSpacing: $0))) }
      lookSlider("Paragraph spacing", value: state.look?.paragraphSpacing ?? 0.34, range: InputValidation.paragraphSpacing.range) { link.send(.look(.init(paragraphSpacing: $0))) }
      DisclosureGroup("Advanced") {
        lookSlider("Reading band (0 = off)", value: state.look?.readingBandOpacity ?? 0.12, range: 0...1) { link.send(.look(.init(readingBandOpacity: $0))) }
      }
      lookSlider("Reading line", value: state.look?.guideFraction ?? 0.35, range: InputValidation.guideFraction.range) { link.send(.look(.init(guideFraction: $0))) }
      Picker("Countdown", selection: Binding(get: { state.startDelay ?? 3 }, set: { link.send(.startDelay($0)) })) {
        Text("Off").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5)
      }
      if let presets = state.presets, !presets.isEmpty {
        Menu("Reading presets") { ForEach(presets, id: \.self) { name in Button(name) { link.send(.preset(name)) } } }
      }
    }
  }
  private func sendSelected() {
    guard let record = store.scripts.first(where: { $0.id == selectedMac }), record.markdown.utf8.count <= PadRemote.Transfer.maximumMarkdownBytes, record.metadata.title.count <= PadRemote.Transfer.maximumTitleLength else { return }
    let sent = UserDefaults.standard.dictionary(forKey: "padRelaySentFingerprints") as? [String: String] ?? [:]
    pendingSend = (record.id, MarkdownLibrary.fingerprint(record.markdown))
    link.send(.sendScript(.init(macID: record.id, title: record.metadata.title, markdown: record.markdown, basis: sent[record.id.uuidString], present: true)))
  }
  private func setVoice(_ value: String, _ state: PadRemote.State) {
    if value == "mac" {
      message = nil
      if state.markdown != nil { link.relay.startFromIPad(settings: store.settings) }
      else if let id = state.scripts.first(where: { $0.id == state.presenting })?.macID,
        let record = store.scripts.first(where: { $0.id == id }) {
        link.relay.start(script: record, settings: store.settings)
      } else { message = "Send the script from this Mac first" }
    } else {
      if link.relay.isRelaying { link.relay.stop() }
      if value == "ipad" { link.setVoiceSource("iPad"); link.send(.mode("Voice")) }
      else { link.send(.mode("Manual")) }
    }
  }
  private func lookSlider(_ title: String, value: Double, range: ClosedRange<Double>, percentage: Bool = false, set: @escaping (Double) -> Void) -> some View {
    HStack { Text(title).frame(width: 120, alignment: .leading); Slider(value: Binding(get: { value }, set: set), in: range); Text(percentage ? "\(Int(value * 100))%" : value.formatted(.number.precision(.fractionLength(0...2)))).frame(width: 56) }
  }
}

private struct RelayNotice: View {
  @ObservedObject var relay: PadVoiceRelay
  var body: some View {
    if !relay.isRelaying, !["Off", "Stopped"].contains(relay.status) { Text(relay.status).foregroundStyle(.orange) }
  }
}

struct IPadButton: View {
  @ObservedObject var link = IPadCameraSender.shared
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Button { openWindow(id: "ipad-remote") } label: {
      HStack(spacing: Space.sm) {
        Label("iPad Control", systemImage: "ipad")
        if link.iPadState != nil { Circle().fill(.green).frame(width: Space.sm, height: Space.sm) }
      }
    }.help("Open iPad Control (⌥⌘I)").accessibilityValue(link.iPadState == nil ? "Not connected" : "Connected")
  }
}
#endif

#if os(macOS)
/// Opt the console into AppKit's standard green-button, View menu and Globe-F actions.
struct IPadWindowConfigurator: NSViewRepresentable {
  static func configure(_ window: NSWindow) {
    window.collectionBehavior.remove([.fullScreenAuxiliary, .fullScreenNone])
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.styleMask.remove(.nonactivatingPanel)
    window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
    window.level = .normal
    if let button = window.standardWindowButton(.zoomButton) {
      button.target = window
      button.action = #selector(NSWindow.toggleFullScreen(_:))
    }
  }
  final class Anchor: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { IPadWindowConfigurator.configure(window) }
    }
  }
  func makeNSView(context: Context) -> NSView { Anchor() }
  func updateNSView(_ view: NSView, context: Context) {
    if let window = view.window { Self.configure(window) }
  }
}
#endif
