#if os(macOS)
import SwiftUI

struct IPadConnectPanel: View {
  @ObservedObject var link: IPadCameraSender
  @State private var pairingKey = ""
  var body: some View {
    VStack(spacing: Space.lg) {
      Image(systemName: "ipad").font(.largeTitle)
      Text("Waiting for an iPad").font(.title2.bold())
      Text("Open Video Prompter on your iPad and connect it by USB-C, or pair over Wi-Fi.")
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
      Toggle("Connect over Wi-Fi", isOn: $link.usesWiFi)
      if link.wifiDevices.count > 1 {
        Picker("iPad", selection: $link.selectedWiFiID) {
          Text("Automatic").tag(String?.none)
          ForEach(link.wifiDevices) { Text($0.name).tag(Optional($0.id)) }
        }
      }
      if let name = link.unpairedDeviceName {
        Text("Pair with \(name)")
        HStack {
          TextField("Pairing key from the iPad", text: $pairingKey)
          Button("Pair") { link.pair(key: pairingKey) }.disabled(pairingKey.isEmpty)
        }
      }
      if let failure = link.pairingFailure { Text(failure).foregroundStyle(.orange) }
    }.padding(Space.lg).frame(maxWidth: 480)
  }
}
#endif
