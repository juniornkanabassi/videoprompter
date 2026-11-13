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
        if state.cameraOnly == true || state.presenting == nil {
          GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
              Color.black
              if let image = previewOverride ?? link.previewImage {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                  .scaleEffect(x: link.mirror ? -1 : 1, y: link.flip ? -1 : 1)
                  .frame(width: geometry.size.width, height: geometry.size.height)
              } else {
                Label("Camera preview unavailable", systemImage: "video")
                  .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
              }
              Text(state.cameraOnly == true ? "On the iPad · Camera Only" : "Open a script to begin")
                .font(.callout).padding(Space.md).background(.black.opacity(0.6))
            }.clipShape(RoundedRectangle(cornerRadius: Space.md))
          }
        } else {
          VStack(spacing: 0) {
            IPadReplicaView(state: state) { link.send(.seek(word: $0 + 1)) }
            HStack(spacing: Space.md) {
              Text("Reading position").font(.caption).foregroundStyle(.secondary)
              Slider(value: Binding(get: { dragging ?? Double(state.word) }, set: { dragging = $0 }), in: 1...Double(max(2, state.words))) { editing in
                if !editing, let value = dragging { link.send(.seek(word: Int(value.rounded()))); dragging = nil }
              }.labelsHidden().accessibilityLabel("Reading position")
                .disabled(state.words < 2 || state.editing == true)
            }.padding(.horizontal, Space.md).padding(.bottom, Space.sm)
          }.background(.black).clipShape(RoundedRectangle(cornerRadius: Space.md))
        }
        transport(state)
        if let reason = state.rejectionReason ?? message { Text(reason).foregroundStyle(.orange) }
        RelayNotice(relay: link.relay)
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
    .padding(Space.md)
    .background(Color(red: 30/255, green: 30/255, blue: 31/255))
    .tint(yellow).preferredColorScheme(.dark)
    .frame(minWidth: 760, idealWidth: 960, maxWidth: .infinity, minHeight: 500, idealHeight: 720, maxHeight: .infinity)
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

  private func status(_ state: PadRemote.State) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Space.sm) { deviceMenu(state); voiceMenu(state); cameraMenu; Spacer(minLength: 0); scriptMenu(state) }
      VStack(spacing: Space.sm) {
        HStack { deviceMenu(state); Spacer(); scriptMenu(state) }
        HStack { voiceMenu(state); cameraMenu; Spacer() }
      }
    }
  }
  private func deviceMenu(_ state: PadRemote.State) -> some View {
    Menu {
      Button("Disconnect") { link.disconnect() }
      Button("Connect another iPad") { link.disconnect(); link.controlsIPad = true }
    } label: {
      HStack(spacing: Space.sm) {
        Circle().fill(.green).frame(width: Space.sm, height: Space.sm)
        Text(state.deviceName ?? "iPad")
        Text(link.transport ?? "USB-C").foregroundStyle(.secondary)
      }.fixedSize()
    }.fixedSize()
  }
  private func voiceMenu(_ state: PadRemote.State) -> some View {
    Menu {
      Button("This Mac") { setVoice("mac", state) }
      Button("iPad") { setVoice("ipad", state) }
      Button("Off (scroll)") { setVoice("off", state) }
      Divider()
      Button(link.micOn ? "Turn microphone off" : "Turn microphone on") { link.setMicOn(!link.micOn) }
      ForEach(link.microphoneSources) { source in Button(source.name) { link.selectMicrophone(source.id) } }
    } label: {
      HStack(spacing: Space.sm) {
        Label(state.mode == "Voice" ? "Voice from \(state.voiceSource ?? "iPad")" : "Voice off", systemImage: "mic")
        if state.mode == "Voice", state.voiceSource == "Mac" { CompactRemoteMeter(meter: link.micMeter) }
      }.fixedSize()
    }.fixedSize()
  }
  private var cameraMenu: some View {
    Menu {
      Button(link.cameraOn ? "Turn camera off" : "Turn camera on") { link.setCameraOn(!link.cameraOn) }
      ForEach(link.cameraSources) { source in Button(source.name) { link.selectCamera(source.id) } }
    } label: { Label(link.cameraOn ? "Camera on" : "Camera off", systemImage: link.cameraOn ? "video" : "video.slash") }
      .fixedSize()
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
        VStack(alignment: .leading, spacing: Space.md) {
          if textPage {
            Button("Back", systemImage: "chevron.left") { textPage = false }
            lookSlider("Text size", value: state.look?.fontSize ?? 44, range: InputValidation.fontSize.range) { link.send(.look(.init(fontSize: $0))) }
            lookSlider("Text width", value: state.look?.textWidth ?? 1, range: InputValidation.textWidth.range) { link.send(.look(.init(textWidth: $0))) }
            lookSlider("Line spacing", value: state.look?.lineSpacing ?? 0.16, range: InputValidation.lineSpacing.range) { link.send(.look(.init(lineSpacing: $0))) }
            lookSlider("Reading line", value: state.look?.guideFraction ?? 0.35, range: InputValidation.guideFraction.range) { link.send(.look(.init(guideFraction: $0))) }
            if let presets = state.presets, !presets.isEmpty {
              Menu("Reading presets") { ForEach(presets, id: \.self) { name in Button(name) { link.send(.preset(name)) } } }
            }
          } else {
            Text("Picture on the iPad").font(.headline)
            Picker("Picture", selection: Binding(get: { link.pictureMode }, set: link.setPictureMode)) {
              Text("Off").tag(PadRemote.PictureMode.off)
              Text("Behind the script").tag(PadRemote.PictureMode.behindScript)
              Text("Monitor only").tag(PadRemote.PictureMode.monitorOnly)
            }.pickerStyle(.segmented)
            Picker("Quality", selection: Binding(get: { link.picturePriority }, set: link.setPicturePriority)) {
              Text("Real time 720p").tag(PadRemote.PicturePriority.realTime720p)
              Text("Sharper 1080p").tag(PadRemote.PicturePriority.sharper1080p)
            }
            Divider()
            Toggle("Mirror left to right", isOn: Binding(get: { link.mirror }, set: link.setMirror))
            Toggle("Flip upside down", isOn: Binding(get: { link.flip }, set: link.setFlip))
            Toggle("Clean screen", isOn: Binding(get: { link.cleanScreen }, set: link.setCleanScreen))
            Picker("Countdown", selection: Binding(get: { state.startDelay ?? 3 }, set: { link.send(.startDelay($0)) })) {
              Text("Off").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5)
            }
            Button("Text size, width, spacing and presets", systemImage: "chevron.right") { textPage = true }
          }
        }.padding(Space.lg).frame(width: 420).uiZoom(store.uiZoom)
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
      guard let id = state.scripts.first(where: { $0.id == state.presenting })?.macID, let record = store.scripts.first(where: { $0.id == id }) else { message = "Send the script from this Mac first"; return }
      message = nil
      link.relay.start(script: record, settings: store.settings)
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
    ProgressView(value: max(0, min(1, (meter.levelDB + 60) / 60)))
      .frame(width: 48).accessibilityLabel("Mac microphone level")
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
