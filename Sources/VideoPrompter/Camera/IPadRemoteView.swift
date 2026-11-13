#if os(macOS)
import PrompterCore
import SwiftUI

struct IPadRemoteView: View {
  @ObservedObject var link: IPadCameraSender
  @ObservedObject var store: AppStore = .shared
  var stateOverride: PadRemote.State?
  private var currentState: PadRemote.State? { stateOverride ?? link.iPadState }
  var startsLink = true
  @State private var selectedMac: UUID?
  @State private var dragging: Double?
  @State private var lookOpen = false
  @State private var pictureOpen = true
  @State private var pendingSend: (UUID, String)?
  @State private var message: String?
  @State private var pairingKey = ""
  private let yellow = Color(red: 245/255, green: 207/255, blue: 74/255)

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        connection
        Group {
          if let state = currentState {
            replica(state)
            scripts(state)
            reading(state)
            picture
            look(state)
          } else {
            let empty = PadRemote.State(scripts: [], presenting: nil, running: false, mode: "Manual", speed: 120, word: 0, words: 0)
            Group { scripts(empty); reading(empty); picture; look(empty) }.disabled(true).opacity(0.4)
          }
        }
      }.padding(20)
    }
    .background(Color(red: 30/255, green: 30/255, blue: 31/255))
    .tint(yellow).preferredColorScheme(.dark)
    .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity)
    .frame(minHeight: 500, idealHeight: 848, maxHeight: 900)
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

  private func replica(_ state: PadRemote.State) -> some View {
    IPadReplicaView(state: state) { link.send(.seek(word: $0 + 1)) }
      .frame(height: 380)
      .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
      .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(red: 38/255, green: 38/255, blue: 40/255), in: RoundedRectangle(cornerRadius: 12))
  }
  private var connection: some View {
    card {
      HStack {
        Circle().fill(currentState == nil ? Color.orange : Color.green).frame(width: 12, height: 12)
        VStack(alignment: .leading) {
          Text(currentState == nil ? "Not connected" : currentState?.deviceName ?? "iPad connected").bold()
          Text(currentState == nil ? link.status : "Connected by \(link.transport ?? "USB-C") · Video Prompter \(currentState?.appVersion ?? "unknown")")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if currentState != nil { Button("Disconnect") { link.disconnect() } }
        else { Toggle("Wi-Fi", isOn: $link.usesWiFi).toggleStyle(.checkbox); if !link.controlsIPad { Button("Connect") { link.controlsIPad = true } } }
      }
      if currentState == nil, let name = link.unpairedDeviceName {
        Text("Pair with \(name)").font(.headline)
        HStack {
          TextField("Pairing key from the iPad", text: $pairingKey)
          Button("Pair") { link.pair(key: pairingKey) }.disabled(pairingKey.isEmpty)
        }
      }
      if let failure = link.pairingFailure { Text(failure).foregroundStyle(.orange) }
      if let state = currentState {
        HStack(spacing: 12) {
          if link.isOn, state.pictureMode != .off, let image = link.previewImage {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
              .scaleEffect(x: link.mirror ? -1 : 1, y: link.flip ? -1 : 1)
              .frame(width: 160, height: 92).clipped()
          }
          Text(state.scriptPreview ?? "No script open").lineLimit(3).foregroundStyle(.secondary)
        }.accessibilityLabel("Preview of the iPad")
      }
    }
  }
  private func scripts(_ state: PadRemote.State) -> some View {
    card {
      HStack {
        Text("On the iPad"); Spacer()
        Picker("On the iPad", selection: Binding(get: { state.presenting }, set: { link.send($0.map(PadRemote.Command.present) ?? .close) })) {
          Text("None").tag(UUID?.none)
          ForEach(state.scripts, id: \.id) { Text($0.title).tag(Optional($0.id)) }
        }.labelsHidden().frame(maxWidth: 300)
      }
      Divider()
      HStack {
        Text("Send from this Mac"); Spacer()
        Picker("Send from this Mac", selection: $selectedMac) {
          Text("Choose a script").tag(UUID?.none)
          ForEach(store.scripts) { Text($0.metadata.title).tag(Optional($0.id)) }
        }.labelsHidden().frame(maxWidth: 280)
        Button("Send and Open") { sendSelected() }.buttonStyle(.borderedProminent)
          .disabled(selectedMac == nil || state.editing == true)
      }
    }
  }
  private func sendSelected() {
    guard let record = store.scripts.first(where: { $0.id == selectedMac }), record.markdown.utf8.count <= PadRemote.Transfer.maximumMarkdownBytes, record.metadata.title.count <= PadRemote.Transfer.maximumTitleLength else { return }
    let sent = UserDefaults.standard.dictionary(forKey: "padRelaySentFingerprints") as? [String: String] ?? [:]
    pendingSend = (record.id, MarkdownLibrary.fingerprint(record.markdown))
    link.send(.sendScript(.init(macID: record.id, title: record.metadata.title, markdown: record.markdown, basis: sent[record.id.uuidString], present: true)))
  }
  private func reading(_ state: PadRemote.State) -> some View {
    card {
      HStack {
        Button(state.editing == true ? "Resume after save" : state.running ? "Pause" : "Resume") { link.send(state.running ? .pause : .play) }
          .buttonStyle(.borderedProminent).disabled(state.presenting == nil || state.editing == true)
        Button("Back to start") { link.send(.backToStart) }.disabled(state.presenting == nil || state.editing == true)
        Button("Previous passage", systemImage: "arrow.up") { link.send(.previousPassage) }.labelStyle(.iconOnly).disabled(state.presenting == nil || state.editing == true)
        Button("Next passage", systemImage: "arrow.down") { link.send(.nextPassage) }.labelStyle(.iconOnly).disabled(state.presenting == nil || state.editing == true)
      }
      if let reason = state.rejectionReason ?? message { Text(reason).foregroundStyle(.orange) }
      RelayNotice(relay: link.relay)
      HStack {
        Text("On the iPad").frame(width: 120, alignment: .leading)
        split("Camera", on: link.cameraOn, sources: link.cameraSources, toggle: link.setCameraOn, select: link.selectCamera)
        split("Mic", on: link.micOn, sources: link.microphoneSources, toggle: link.setMicOn, select: link.selectMicrophone)
        Button("Clean screen") { link.setCleanScreen(!link.cleanScreen) }.tint(link.cleanScreen ? yellow : .secondary)
      }
      HStack {
        Text("Follow voice from").frame(width: 120, alignment: .leading)
        Picker("Follow voice from", selection: Binding(get: { state.mode == "Manual" ? "off" : state.voiceSource == "Mac" ? "mac" : "ipad" }, set: { setVoice($0, state) })) {
          Text("This Mac").tag("mac"); Text("iPad").tag("ipad"); Text("Off (scroll)").tag("off")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 252)
      }
      HStack {
        Text("Mic level").frame(width: 120, alignment: .leading)
        Text(link.microphoneSources.first { $0.id == link.selectedMicrophone }?.name ?? "Microphone").foregroundStyle(.secondary)
        // The iPad does not report its own microphone level, so never show the Mac's under its name.
        if state.voiceSource == "iPad" {
          Text("Not sent to the Mac. Watch the meter on the iPad").foregroundStyle(.secondary)
        } else {
          MicMeterRow(meter: link.micMeter).frame(maxWidth: 352)
        }
      }
      HStack {
        Text("Scroll speed").frame(width: 120, alignment: .leading)
        Slider(value: Binding(get: { Double(state.speed) }, set: { link.send(.speed(Int($0))) }), in: 20...300, step: 10).disabled(state.mode == "Voice")
        Text("\(state.speed) wpm").monospacedDigit()
      }
      HStack {
        Text("Position").frame(width: 120, alignment: .leading)
        Slider(value: Binding(get: { dragging ?? Double(state.word) }, set: { dragging = $0 }), in: 1...Double(max(2, state.words))) { editing in
          if !editing, let value = dragging { link.send(.seek(word: Int(value.rounded()))); dragging = nil }
        }.disabled(state.presenting == nil || state.words < 2 || state.editing == true)
        Text("Word \(state.word) of \(state.words)").monospacedDigit()
      }
    }
  }
  private func split(_ title: String, on: Bool, sources: [PadRemote.Source], toggle: @escaping (Bool) -> Void, select: @escaping (String) -> Void) -> some View {
    HStack(spacing: 0) {
      Button(on ? title : "\(title) off") { toggle(!on) }
      Menu { ForEach(sources) { source in Button(source.name) { select(source.id) } } } label: { Image(systemName: "chevron.down") }
        .menuStyle(.borderlessButton).fixedSize()
    }
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
  private var picture: some View {
    card {
      Button { pictureOpen.toggle(); if pictureOpen { lookOpen = false } } label: {
        HStack { Text("Picture to the iPad").bold(); Spacer(); Text(pictureSummary).foregroundStyle(.secondary); Image(systemName: pictureOpen ? "chevron.down" : "chevron.right") }
      }.buttonStyle(.plain)
      if pictureOpen {
        Picker("Picture", selection: Binding(get: { link.pictureMode }, set: link.setPictureMode)) {
          Text("Off").tag(PadRemote.PictureMode.off); Text("Behind the script").tag(PadRemote.PictureMode.behindScript); Text("Monitor only").tag(PadRemote.PictureMode.monitorOnly)
        }.pickerStyle(.segmented)
        Picker("Source", selection: Binding(get: { link.selectedCamera ?? "" }, set: link.selectCamera)) {
          Text("Choose a source").tag(""); ForEach(link.cameraSources) { Text($0.name).tag($0.id) }
        }
        Picker("Priority", selection: Binding(get: { link.picturePriority }, set: link.setPicturePriority)) {
          Text("Real time 720p").tag(PadRemote.PicturePriority.realTime720p); Text("Sharper 1080p").tag(PadRemote.PicturePriority.sharper1080p)
        }.pickerStyle(.segmented)
      }
    }
  }
  private var pictureSummary: String {
    switch link.pictureMode { case .off: return "Off"; case .behindScript: return "Behind the script"; case .monitorOnly: return "Monitor only" }
  }
  private func look(_ state: PadRemote.State) -> some View {
    card {
      Button { lookOpen.toggle(); if lookOpen { pictureOpen = false } } label: {
        HStack { Text("Look on the iPad").bold(); Spacer(); Image(systemName: lookOpen ? "chevron.down" : "chevron.right") }
      }.buttonStyle(.plain)
      if lookOpen {
        HStack {
          Text("Turn the text").frame(width: 120, alignment: .leading)
          Toggle("Mirror left to right", isOn: Binding(get: { link.mirror }, set: link.setMirror))
          Toggle("Flip upside down", isOn: Binding(get: { link.flip }, set: link.setFlip))
        }.toggleStyle(.checkbox)
        lookSlider("Text size", value: state.look?.fontSize ?? 44, range: InputValidation.fontSize.range) { link.send(.look(.init(fontSize: $0))) }
        lookSlider("Text width", value: state.look?.textWidth ?? 1, range: InputValidation.textWidth.range) { link.send(.look(.init(textWidth: $0))) }
        lookSlider("Line spacing", value: state.look?.lineSpacing ?? 0.16, range: InputValidation.lineSpacing.range) { link.send(.look(.init(lineSpacing: $0))) }
        lookSlider("Reading line", value: state.look?.guideFraction ?? 0.35, range: InputValidation.guideFraction.range) { link.send(.look(.init(guideFraction: $0))) }
        Picker("Countdown", selection: Binding(get: { state.startDelay ?? 3 }, set: { link.send(.startDelay($0)) })) { Text("Off").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5) }
        if let presets = state.presets, !presets.isEmpty { Menu("Presets") { ForEach(presets, id: \.self) { name in Button(name) { link.send(.preset(name)) } } } }
      }
    }
  }
  private func lookSlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
    HStack { Text(title).frame(width: 120, alignment: .leading); Slider(value: Binding(get: { value }, set: set), in: range); Text(value.formatted(.number.precision(.fractionLength(0...2)))).frame(width: 56) }
  }
}

/// Why the Mac's voice is not following the iPad, shown once the relay has ended or been refused.
private struct RelayNotice: View {
  @ObservedObject var relay: PadVoiceRelay
  var body: some View {
    if !relay.isRelaying, !["Off", "Stopped"].contains(relay.status) { Text(relay.status).foregroundStyle(.orange) }
  }
}

/// Observes the meter itself, so level-only updates redraw just this.
private struct MicMeterRow: View {
  @ObservedObject var meter: RemoteMicMeter
  var body: some View { DBMeter(levelDB: meter.levelDB, axis: .horizontal) }
}
#endif
