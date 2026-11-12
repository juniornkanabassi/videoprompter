#if os(macOS)
import PrompterCore
import SwiftUI

/// File › Control iPad opens this: the iPad presenter's controls, showing what the iPad reports.
struct IPadRemoteView: View {
  @ObservedObject var link: IPadCameraSender
  var startsLink = true
  /// The slider's value while it is dragged; the iPad moves when it is let go.
  @State private var dragging: Double?

  var body: some View {
    Form {
      Toggle("Control iPad", isOn: $link.controlsIPad)
      Text(link.iPadState == nil && link.controlsIPad ? "\(link.status). Open Video Prompter on the iPad, connected by USB-C." : link.status)
        .foregroundStyle(.secondary)
      if let state = link.iPadState { controls(state) }
    }
    .formStyle(.grouped)
    .frame(minWidth: 380)
    .onAppear { if startsLink { link.controlsIPad = true } }
    .onDisappear { if startsLink { link.controlsIPad = false } }
  }

  @ViewBuilder private func controls(_ state: PadRemote.State) -> some View {
    Picker("Script", selection: Binding(get: { state.presenting }, set: { link.send($0.map(PadRemote.Command.present) ?? .close) })) {
      Text("None (presenter closed)").tag(UUID?.none)
      ForEach(state.scripts, id: \.id) { Text($0.title).tag(Optional($0.id)) }
    }
    Picker("Reading mode", selection: Binding(get: { state.mode }, set: { link.send(.mode($0)) })) {
      Text("Voice follow").tag("Voice")
      Text("Automatic scroll").tag("Manual")
    }
    .pickerStyle(.menu)
    Stepper("Speed \(state.speed) words a minute", value: Binding(get: { state.speed }, set: { link.send(.speed($0)) }), in: 20...300, step: 10)
    HStack {
      Button("Back to Start", systemImage: "backward.end.fill") { link.send(.backToStart) }
      Button("Previous Passage", systemImage: "chevron.up") { link.send(.previousPassage) }
      Button(state.running ? "Pause" : "Start", systemImage: state.running ? "pause.fill" : "play.fill") {
        link.send(state.running ? .pause : .play)
      }
      Button("Next Passage", systemImage: "chevron.down") { link.send(.nextPassage) }
    }
    .labelStyle(.iconOnly)
    .disabled(state.presenting == nil)
    LabeledContent("Word \(state.word) of \(state.words)") {
      Slider(value: Binding(get: { dragging ?? Double(state.word) }, set: { dragging = $0 }),
             in: 1...Double(max(state.words, 2))) { editing in
        guard !editing, let value = dragging else { return }
        link.send(.seek(word: Int(value.rounded())))
        dragging = nil
      }
    }
    .disabled(state.presenting == nil || state.words < 2)
  }
}
#endif
