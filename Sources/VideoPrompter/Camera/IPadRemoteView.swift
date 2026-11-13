#if os(macOS)
import PrompterCore
import SwiftUI

struct IPadRemoteView: View {
  @ObservedObject var link: IPadCameraSender
  @ObservedObject var store: AppStore = .shared
  var stateOverride: PadRemote.State?
  private var currentState: PadRemote.State? { stateOverride ?? link.iPadState }
  var startsLink = true
  var previewOverride: CGImage?
  var panelOverride: String?
  var devicesOverride: [IPadCameraSender.WiFiDevice]?
  @State private var devicesOpen = false
  @State private var renaming = false
  @State private var newName = ""
  @State private var selectedMac: UUID?
  @State private var dragging: Double?
  @State private var moreOpen = false
  @State private var textPage = false
  @State private var pendingSend: (UUID, String)?
  @State private var message: String?
  private let yellow = AlphaStyle.accent

  var body: some View {
    GeometryReader { geometry in
    VStack(spacing: Space.md) {
      if let state = currentState {
        status(state)
        ZStack(alignment: .bottomTrailing) {
          if state.cameraOnly == true || state.presenting == nil || state.pictureMode == .monitorOnly {
            liveCamera
          } else {
            if state.pictureMode == .behindScript { liveCamera.opacity(0.55) }
            VStack(spacing: 0) {
              IPadReplicaView(state: state) { link.send(.seek(word: $0 + 1)) }
              HStack(spacing: Space.md) {
                Text("Reading position").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { dragging ?? Double(state.word) }, set: { dragging = $0 }), in: 1...Double(max(2, state.words))) { editing in
                  if !editing, let value = dragging { link.send(.seek(word: Int(value.rounded()))); dragging = nil }
                }.labelsHidden().accessibilityLabel("Reading position")
                  .disabled(state.words < 2 || state.editing == true)
              }.padding(.horizontal, Space.md).padding(.bottom, Space.sm)
            }
            if state.pictureMode != .behindScript {
              liveCamera.frame(width: 192, height: 108).padding(Space.md) // grid: ok 16:9 camera thumbnail
            }
          }
        }.background(.black).clipShape(RoundedRectangle(cornerRadius: Space.md))

        transport(state)
        if let reason = state.rejectionReason ?? message { Text(reason).foregroundStyle(.orange) }
        RelayNotice(relay: link.relay)
        setupBar(state)
      } else {
        IPadConnectPanel(link: link).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background {
      if let state = currentState, state.presenting != nil, state.cameraOnly != true {
        HStack {
          Button("Previous passage") { link.send(.previousPassage) }.keyboardShortcut(.leftArrow, modifiers: [])
          Button("Next passage") { link.send(.nextPassage) }.keyboardShortcut(.rightArrow, modifiers: [])
        }.hidden().disabled(state.editing == true).accessibilityHidden(true)
      }
    }
    .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .overlay(alignment: .bottomTrailing) {
      if let state = currentState, let panelOverride {
        Group {
          if panelOverride == "devices" { deviceChoices(state).padding(Space.lg).frame(width: 400) }
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
        HStack(spacing: Space.md) {
          BarGroup(label: "Camera and microphone") {
            BarDeviceControl(offIsWarning: false, title: "Camera", onSymbol: "video.fill", offSymbol: "video.slash.fill", isOn: link.cameraOn,
              showsTitle: true, toggleHelp: "Turn camera on or off", menuLabel: "Choose camera", menuValue: link.selectedCamera ?? "Default",
              toggle: { link.setCameraOn(!link.cameraOn) }) {
              ForEach(link.cameraSources) { source in Button(source.name) { link.selectCamera(source.id) } }
            }
            BarDivider()
            BarDeviceControl(title: "Mic", onSymbol: "mic.fill", offSymbol: "mic.slash.fill", isOn: state.micOn ?? true,
              showsTitle: true, toggleHelp: "Turn microphone on or off", menuLabel: "Choose microphone", menuValue: link.selectedMicrophone ?? "Default",
              toggle: { link.setMicOn(!link.micOn) }) { voiceMenu(state) }
          }
          CompactRemoteMeter(meter: state.voiceSource == "iPad" ? link.iPadMicMeter : link.micMeter)
          Spacer(minLength: 0)
          deviceMenu(state)
        }.padding(Space.sm).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Space.md))
  }
  private var liveCamera: some View {
    Group {
      if let image = previewOverride {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
      } else if startsLink && link.cameraOn {
        CameraPreview(model: CameraModel.shared, presenter: true)
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
  private func voiceMenu(_ state: PadRemote.State) -> some View {
    Group {
      Button("This Mac") { setVoice("mac", state) }
      Button("iPad") { setVoice("ipad", state) }
      Button("Off (scroll)") { setVoice("off", state) }
      Divider()
      ForEach(link.microphoneSources) { source in Button(source.name) { link.selectMicrophone(source.id) } }
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
  private func transport(_ state: PadRemote.State) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Space.sm) { readingControls(state); moreButton(state) }
      VStack(spacing: Space.sm) { readingControls(state); moreButton(state) }
    }
  }
  @ViewBuilder private func readingControls(_ state: PadRemote.State) -> some View {
    if state.presenting != nil && state.cameraOnly != true {
      HStack(spacing: Space.sm) {
        Button(state.running ? "Pause" : "Start reading", systemImage: state.running ? "pause.fill" : "play.fill") { link.send(state.running ? .pause : .play) }
          .keyboardShortcut(.space, modifiers: []).buttonStyle(.borderedProminent)
          .tint(state.running ? Color.gray : yellow)
        Button("Back to start") { link.send(.backToStart) }.keyboardShortcut(.home, modifiers: [])
        Button("Previous", systemImage: "arrow.up") { link.send(.previousPassage) }.keyboardShortcut(.upArrow, modifiers: [])
        Button("Next", systemImage: "arrow.down") { link.send(.nextPassage) }.keyboardShortcut(.downArrow, modifiers: [])
      }.disabled(state.editing == true)
      Spacer(minLength: 0)
      Menu(state.mode == "Voice" ? "Voice follow" : "Automatic scroll") {
        Button("Voice follow") { setVoice(state.voiceSource == "Mac" ? "mac" : "ipad", state) }
        Button("Automatic scroll") { setVoice("off", state) }
      }.fixedSize()
      if state.mode != "Voice" {
        Stepper("\(state.speed) wpm", value: Binding(get: { state.speed }, set: { link.send(.speed($0)) }), in: 20...300, step: 10).fixedSize()
      }
    } else {
      scriptMenu(state, title: "Open a script")
      Spacer(minLength: 0)
    }
  }
  private func moreButton(_ state: PadRemote.State) -> some View {
    Button("More", systemImage: "slider.horizontal.3") { moreOpen.toggle() }.fixedSize()
      .popover(isPresented: $moreOpen) {
        ScrollView { adjustControls(state).padding(Space.lg) }
          .frame(width: 460, height: textPage ? 340 : 560).uiZoom(store.uiZoom)
      }
  }
  func adjustControls(_ state: PadRemote.State) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
          if textPage || panelOverride == "text" {
            Button("Back", systemImage: "chevron.left") { textPage = false }
            Picker("Font", selection: Binding(get: { state.look?.fontName ?? "Lexend Deca" }, set: { link.send(.look(.init(fontName: $0))) })) {
              ForEach(Array(Set(AvailableFonts.presenter + [state.look?.fontName ?? "Lexend Deca"])).sorted(), id: \.self) { Text($0).tag($0) }
            }
            lookSlider("Paragraph spacing", value: state.look?.paragraphSpacing ?? 0.34, range: InputValidation.paragraphSpacing.range) { link.send(.look(.init(paragraphSpacing: $0))) }
            lookSlider("Text size", value: state.look?.fontSize ?? 44, range: InputValidation.fontSize.range) { link.send(.look(.init(fontSize: $0))) }
            lookSlider("Text width", value: state.look?.textWidth ?? 1, range: InputValidation.textWidth.range) { link.send(.look(.init(textWidth: $0))) }
            lookSlider("Line spacing", value: state.look?.lineSpacing ?? 0.16, range: InputValidation.lineSpacing.range) { link.send(.look(.init(lineSpacing: $0))) }
            lookSlider("Reading line", value: state.look?.guideFraction ?? 0.35, range: InputValidation.guideFraction.range) { link.send(.look(.init(guideFraction: $0))) }
            if let presets = state.presets, !presets.isEmpty {
              Menu("Reading presets") { ForEach(presets, id: \.self) { name in Button(name) { link.send(.preset(name)) } } }
            }
          } else {
            Text("Picture on the iPad").font(.headline)
            Picker("Picture", selection: Binding(get: { state.pictureMode ?? .off }, set: link.setPictureMode)) {
              Text("Off").tag(PadRemote.PictureMode.off)
              Text("Behind the script").tag(PadRemote.PictureMode.behindScript)
              Text("Monitor only").tag(PadRemote.PictureMode.monitorOnly)
            }.pickerStyle(.segmented).labelsHidden()
            Picker("Quality", selection: Binding(get: { state.picturePriority ?? .realTime720p }, set: link.setPicturePriority)) {
              Text("Real time 720p").tag(PadRemote.PicturePriority.realTime720p)
              Text("Sharper 1080p").tag(PadRemote.PicturePriority.sharper1080p)
            }
            Divider()
            Toggle("Zebras", isOn: Binding(get: { state.guides?.zebras ?? false }, set: { link.send(.cameraGuides(.init(zebras: $0))) }))
            Toggle("False colour", isOn: Binding(get: { state.guides?.falseColour ?? false }, set: { link.send(.cameraGuides(.init(falseColour: $0))) }))
            Toggle("Thirds", isOn: Binding(get: { state.guides?.thirds ?? false }, set: { link.send(.cameraGuides(.init(thirds: $0))) }))
            Toggle("Centre", isOn: Binding(get: { state.guides?.centre ?? false }, set: { link.send(.cameraGuides(.init(centre: $0))) }))
            Picker("Frame marker", selection: Binding(get: { state.guides?.marker ?? "Off" }, set: { link.send(.cameraGuides(.init(marker: $0))) })) {
              Text("Off").tag("Off")
              ForEach(CameraAspect.presets) { Text($0.label).tag($0.label) }
            }
            Toggle("Show key", isOn: Binding(get: { state.guides?.exposureKey ?? true }, set: { link.send(.cameraGuides(.init(exposureKey: $0))) }))
            Divider()
            Toggle("Mirror left to right", isOn: Binding(get: { state.look?.horizontalMirror ?? false }, set: link.setMirror))
            Toggle("Flip upside down", isOn: Binding(get: { state.look?.verticalMirror ?? false }, set: link.setFlip))
            Toggle("Clean screen", isOn: Binding(get: { state.cleanScreen ?? false }, set: link.setCleanScreen))
            Picker("Countdown", selection: Binding(get: { state.startDelay ?? 3 }, set: { link.send(.startDelay($0)) })) {
              Text("Off").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5)
            }
            Button("Text size, width, spacing and presets", systemImage: "chevron.right") { textPage = true }
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
  private func lookSlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
    HStack { Text(title).frame(width: 120, alignment: .leading); Slider(value: Binding(get: { value }, set: set), in: range); Text(value.formatted(.number.precision(.fractionLength(0...2)))).frame(width: 56) }
  }
}

private struct RelayNotice: View {
  @ObservedObject var relay: PadVoiceRelay
  var body: some View {
    if !relay.isRelaying, !["Off", "Stopped"].contains(relay.status) { Text(relay.status).foregroundStyle(.orange) }
  }
}
private struct CompactRemoteMeter: View {
  @ObservedObject var meter: RemoteMicMeter
  var body: some View {
    DBMeter(levelDB: meter.levelDB, axis: .horizontal, showsScale: false)
      .frame(width: 96).accessibilityLabel("Microphone level")
  }
}

struct IPadButton: View {
  @ObservedObject var link = IPadCameraSender.shared
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Button { openWindow(id: "ipad-remote") } label: {
      HStack(spacing: Space.sm) {
        Label("iPad", systemImage: "ipad")
        if link.iPadState != nil { Circle().fill(.green).frame(width: Space.sm, height: Space.sm) }
      }
    }.help("Open iPad (⌥⌘I)").accessibilityValue(link.iPadState == nil ? "Not connected" : "Connected")
  }
}
#endif
