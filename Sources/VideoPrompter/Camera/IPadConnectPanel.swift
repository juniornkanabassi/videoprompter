#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PrompterCore
import SwiftUI

struct IPadConnectPanel: View {
  @ObservedObject var link: IPadCameraSender
  @State private var typing = false
  @State private var key = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("Connect an iPad").font(.largeTitle.bold())
      HStack(alignment: .top, spacing: 32) {
        VStack(spacing: 16) {
          Text("Scan with the iPad").font(.title2.bold())
          Text("On the iPad, open Settings › Connect to a Mac, then point the camera at this code.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if typing {
            TextField("Pairing key from the iPad", text: $key)
            Button("Connect") { link.pair(key: key) }.buttonStyle(.borderedProminent)
            Button("Back to the code") { typing = false }
          } else if let offer = link.pairingOffer {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              if offer.expires > context.date, let image = qr(offer) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                  .frame(width: 224, height: 224).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                  .accessibilityLabel("Pairing QR code")
              } else {
                Text("This code has expired")
                Button("New code") { link.refreshPairingOffer() }
              }
            }
            Button("Type a key instead") { typing = true; link.usesWiFi = true }
          }
        }.frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 16) {
          Text("Nearby iPads").font(.title2.bold())
          Text("Or choose an iPad, then tap Allow on it.").foregroundStyle(.secondary)
          if link.wifiDevices.isEmpty { Text("Looking for iPads on this Wi-Fi…").foregroundStyle(.secondary) }
          ForEach(link.pairingDevices) { device in
            HStack {
              Image(systemName: "ipad")
              VStack(alignment: .leading) {
                Text(link.displayName(for: device))
                if link.pairingRequestName == device.name { Text(link.pairingRequestCode.map { "Check \($0) matches, then tap Allow" } ?? "Waiting for the iPad…").font(.caption).foregroundStyle(.secondary) }
              }
              Spacer()
              if link.pairingCode(id: device.id, name: device.name) != nil {
                Button("Forget") { link.forgetIPad(id: device.id) }
              }
              if link.pairingRequestName == device.name {
                Button("Cancel") { link.cancelPairingRequest() }
              } else {
                Button("Connect") { link.requestPairing(device) }
              }
            }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
          }
          Divider()
          HStack {
            Image(systemName: "cable.connector")
            VStack(alignment: .leading) {
              Text("USB-C cable")
              Text("Plug the iPad into this Mac. No code needed.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Automatic").foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity)
      }
      if let name = link.pairingRequestName, let number = link.pairingRequestCode {
        HStack(spacing: 16) {
          Text("Pair with \(name)? Check \(number) matches the iPad.").monospacedDigit()
          Spacer()
          Button("Cancel") { link.cancelPairingRequest() }
          Button("Numbers match") { link.confirmPairingRequest() }.buttonStyle(.borderedProminent)
        }
      }
      if let failure = link.pairingFailure { Text(failure).foregroundStyle(.orange) }
    }
    .padding(32)
    .background(PairingPrivateWindow())
    .onAppear { link.usesWiFi = true; link.refreshPairingOffer() }
    .onDisappear { link.stopPairingOffer() }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if !Task.isCancelled, let offer = link.pairingOffer, offer.expires <= Date() { link.refreshPairingOffer() }
      }
    }
  }
  private func qr(_ offer: PairingOffer) -> CGImage? {
    guard let value = try? offer.encoded() else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8); filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    return CIContext().createCGImage(output, from: output.extent)
  }
}
private struct PairingPrivateWindow: NSViewRepresentable {
  final class View: NSView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.sharingType = .none }
  }
  func makeNSView(context: Context) -> View { View() }
  func updateNSView(_ view: View, context: Context) { view.window?.sharingType = .none }
}
#endif
