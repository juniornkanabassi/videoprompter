import SwiftUI

struct InputCardStyle: ViewModifier {
  var selected: Bool
  func body(content: Content) -> some View {
    content.padding(Space.sm)
      .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      .overlay(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
      .overlay(alignment: .topTrailing) {
        if selected {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(AlphaStyle.accent)
            .padding(Space.xs).accessibilityHidden(true)
        }
      }
  }
}

struct MicrophoneCards: View {
  @ObservedObject var store: AppStore
  var devices: [AudioInputDevice]
  var willChange: () -> Void = {}
  @State private var revision = 0
  private var activeUID: String? { store.settings.audioDeviceUID ?? AudioCapture.resolvedInput(nil)?.uid }
  var body: some View {
    VStack(spacing: AlphaStyle.controlGap) {
      card("System default", detail: "Use the Mac’s selected input", uid: nil, device: devices.first { $0.uid == activeUID })
      ForEach(devices.filter { !$0.isOther }) { device in card(device.name, detail: device.detail, uid: device.uid, device: device) }
      if devices.contains(where: \.isOther) {
        Text("Other inputs").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        ForEach(devices.filter(\.isOther)) { device in card(device.name, detail: device.detail, uid: device.uid, device: device) }
      }
      if let uid = store.settings.audioDeviceUID, !devices.contains(where: { $0.uid == uid }) {
        card("Selected microphone unavailable", detail: "Reconnect it or choose another input", uid: uid, device: nil)
      }
    }
  }
  private func card(_ name: String, detail: String, uid: String?, device: AudioInputDevice?) -> some View {
    let selected = store.settings.audioDeviceUID == uid
    return VStack(alignment: .leading, spacing: AlphaStyle.controlGap) {
      Button {
        guard store.settings.audioDeviceUID != uid else { return }
        willChange(); store.settings.audioDeviceUID = uid
      } label: {
        HStack(spacing: Space.sm) {
          Image(systemName: "mic")
          VStack(alignment: .leading, spacing: Space.xs) {
            Text(name).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel(name).accessibilityValue(detail).accessibilityAddTraits(selected ? .isSelected : [])
      if selected, let device, device.channels > 1 {
        Picker("Channel", selection: Binding(get: { _ = revision; return AudioChannel.load(device.uid, defaults: store.defaults) }, set: {
          let testing = store.session.isTestingMicrophone
          willChange(); $0.save(device.uid, defaults: store.defaults); revision += 1
          store.audioChannelRevision += 1
          store.session.audioChannelDidChange()
          if testing { store.session.startMicrophoneTest(deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain) }
        })) {
          ForEach(AudioChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).frame(minHeight: AlphaStyle.minTarget)
      }
    }.modifier(InputCardStyle(selected: selected))
  }
}
