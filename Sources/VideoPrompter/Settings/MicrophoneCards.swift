import SwiftUI

extension View {
  /// Card captions ("Built-in", "Thunderbolt · 2 channels"): quieter than the name but easy to read, 14 points at about 75% contrast.
  func cardCaption() -> some View {
    font(.system(size: 14)).foregroundStyle(.primary.opacity(0.75))
  }
  /// The name on a card: a step above its caption, and the size the check badge matches.
  func cardTitle() -> some View { font(.system(size: 15, weight: .semibold)) }
}

struct InputCardStyle: ViewModifier {
  var selected: Bool
  /// False where the card draws its own check, as the camera rows do beside Rename.
  var showsBadge = true
  /// Content and the check badge both sit this far inside the border, clear of the rounded corner.
  static let inset = Space.md
  func body(content: Content) -> some View {
    content.padding(Self.inset)
      .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      .overlay(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
      .overlay(alignment: .topTrailing) {
        if selected && showsBadge {
          // Title-sized, so it shares the title row's height and line.
          Image(systemName: "checkmark.circle.fill").cardTitle().foregroundStyle(AlphaStyle.accent)
            .padding(Self.inset).accessibilityHidden(true)
        }
      }
  }
}

struct MicrophoneCards: View {
  @ObservedObject var store: AppStore
  var devices: [AudioInputDevice]
  var willChange: () -> Void = {}
  /// When set, the selected input's card shows this live level under its channel picker.
  var meter: InputMeter? = nil
  @State private var revision = 0
  private var activeUID: String? { store.settings.audioDeviceUID ?? AudioCapture.resolvedInput(nil)?.uid }
  var body: some View {
    VStack(spacing: AlphaStyle.controlGap) {
      card("System default", detail: "Use the Mac’s selected input", uid: nil, device: devices.first { $0.uid == activeUID })
      ForEach(devices.filter { !$0.isOther }) { device in card(device.name, detail: device.detail, uid: device.uid, device: device) }
      if devices.contains(where: \.isOther) {
        Text("Other inputs").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary.opacity(0.75)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.xs)
        ForEach(devices.filter(\.isOther)) { device in card(device.name, detail: device.detail, uid: device.uid, device: device) }
      }
      if let uid = store.settings.audioDeviceUID, !devices.contains(where: { $0.uid == uid }) {
        card("Selected microphone unavailable", detail: "Reconnect it or choose another input", uid: uid, device: nil)
      }
    }
  }
  private func card(_ name: String, detail: String, uid: String?, device: AudioInputDevice?) -> some View {
    let selected = store.settings.audioDeviceUID == uid
    let hasControls = selected && (device != nil || meter != nil)
    return VStack(alignment: .leading, spacing: Space.xs) {
      Button {
        guard store.settings.audioDeviceUID != uid else { return }
        willChange(); store.settings.audioDeviceUID = uid
      } label: {
        HStack(alignment: .top, spacing: Space.sm) {
          Image(systemName: "mic").frame(width: Space.xxl, height: Space.xxl)
          VStack(alignment: .leading, spacing: Space.xs) {
            Text(name).cardTitle().fixedSize(horizontal: false, vertical: true)
            Text(detail).cardCaption().fixedSize(horizontal: false, vertical: true)
          }.padding(.trailing, Space.xxl)
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: hasControls ? 0 : 60, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel(name).accessibilityValue(detail).accessibilityAddTraits(selected ? .isSelected : [])
      // Channel and meter line up with the input's name, one icon width in.
      if hasControls {
        VStack(alignment: .leading, spacing: AlphaStyle.controlGap) {
          // A saved Left or Right stays changeable even if the input now reports one channel.
          if let device, device.channels > 1 || AudioChannel.load(device.uid, defaults: store.defaults) != .both { channelPicker(device) }
          if let meter { MicMeterView(meter: meter, micName: meterName(name, uid: uid, device: device), showsHeading: false).frame(height: 96).padding(.horizontal, -InputCardStyle.inset) }
        }.padding(.leading, Space.xxl + Space.sm)
      }
    }.modifier(InputCardStyle(selected: selected))
  }
  /// The input actually listening, never the generic "System default" label.
  private func meterName(_ name: String, uid: String?, device: AudioInputDevice?) -> String {
    device?.name ?? (uid == nil ? AudioCapture.resolvedInput(nil)?.name : nil) ?? name
  }
  private func channelPicker(_ device: AudioInputDevice) -> some View {
    let channel = Binding(get: { _ = revision; return AudioChannel.load(device.uid, defaults: store.defaults) }, set: {
      let testing = store.session.isTestingMicrophone
      willChange(); $0.save(device.uid, defaults: store.defaults); revision += 1
      store.audioChannelRevision += 1
      store.session.audioChannelDidChange()
      if testing { store.session.startMicrophoneTest(deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain) }
    })
    // One full-width control with 44 point segments, its right edge in line with the card's.
    return HStack(spacing: Space.sm) {
      Text("Channel").cardCaption()
      HStack(spacing: 3) { // grid: ok Segments sit 3 points apart inside their track.
        ForEach(AudioChannel.allCases, id: \.self) { option in
          let chosen = channel.wrappedValue == option
          Button { channel.wrappedValue = option } label: {
            Text(option.rawValue).font(.system(size: 15, weight: .semibold)).lineLimit(1)
              .foregroundStyle(chosen ? AlphaStyle.onAccent : .primary)
              .frame(maxWidth: .infinity, minHeight: AlphaStyle.minTarget - 6).contentShape(Rectangle()) // grid: ok Track padding.
              .background(chosen ? AlphaStyle.accent : .clear, in: RoundedRectangle(cornerRadius: Space.sm + 1)) // grid: ok Inner radius.
          }.buttonStyle(.plain)
        }
      }.padding(3) // grid: ok Track padding.
        .background(.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: Space.md))
        .accessibilityRepresentation {
          Picker("Channel", selection: channel) { ForEach(AudioChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
        }
    }
  }
}
