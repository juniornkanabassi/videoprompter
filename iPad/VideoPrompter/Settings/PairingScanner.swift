@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Constructed only after the Scan tap. Simulator fixtures never request capture access.
struct PairingScanner: View {
  @ObservedObject var link: MacLink
  @Environment(\.dismiss) private var dismiss
  @State private var scanned = false
  @State private var allowed = false
  @State private var permissionFailed = false
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if allowed && !scanned {
        QRPreview { value in
          guard !scanned else { return }
          scanned = true
          Task { await link.scanPairingCode(value) }
        }.ignoresSafeArea()
      }
      VStack(spacing: 24) {
        Text("Point at the code in the Mac’s iPad Control window").font(.title2).padding(24)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        Spacer()
        if scanned || permissionFailed {
          Text(permissionFailed ? "Camera access is off. Enable it in Settings, or type the key on the Mac." : link.scanStatus ?? "Connecting…")
            .font(.title2).multilineTextAlignment(.center)
          if permissionFailed {
            Button("Done") { dismiss() }
          } else if link.scanStatus?.hasPrefix("Connected") == true {
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
          } else {
            Button("Scan again") { scanned = false; link.scanStatus = nil }
          }
        } else {
          RoundedRectangle(cornerRadius: 24).stroke(.white, lineWidth: 3).frame(width: 280, height: 280)
        }
        Spacer()
        Button("Cancel") { dismiss() }.buttonStyle(.bordered).padding(24)
      }.padding(32)
    }
    .alert("Pair with \(link.scannedOffer?.name ?? "Mac")?", isPresented: Binding(
      get: { link.scannedOffer != nil }, set: { _ in })) {
      Button("Pair") { Task { await link.confirmScannedPairing(true) } }
      Button("Cancel", role: .cancel) { Task { await link.confirmScannedPairing(false) } }
    }
    .task {
      #if !targetEnvironment(simulator)
      allowed = await AVCaptureDevice.requestAccess(for: .video)
      permissionFailed = !allowed
      #endif
    }
    .onChange(of: link.scanStatus) { _, value in
      if value?.hasPrefix("Connected") == true {
        Task { try? await Task.sleep(for: .seconds(3)); dismiss() }
      }
    }
  }
}

private struct QRPreview: UIViewRepresentable {
  var found: (String) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(found: found) }
  func makeUIView(context: Context) -> Preview {
    let view = Preview()
    context.coordinator.start(view)
    return view
  }
  func updateUIView(_ view: Preview, context: Context) {}
  static func dismantleUIView(_ view: Preview, coordinator: Coordinator) { coordinator.stop() }
  final class Preview: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  }
  final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "VideoPrompter.qr")
    let found: (String) -> Void
    init(found: @escaping (String) -> Void) { self.found = found }
    @MainActor func start(_ view: Preview) {
      (view.layer as? AVCaptureVideoPreviewLayer)?.session = session
      (view.layer as? AVCaptureVideoPreviewLayer)?.videoGravity = .resizeAspectFill
      queue.async { [self] in
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.startRunning()
      }
    }
    func stop() { queue.async { [self] in session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
      if let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue { found(value) }
    }
  }
}

struct PairingPermissionView: View {
  @ObservedObject var link: MacLink
  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "desktopcomputer").font(.system(size: 48))
      Text("Allow this Mac to connect?").font(.largeTitle.bold())
      Text(link.pendingPermission?.request.name ?? "Mac").font(.title2)
      Text(link.pendingPermission?.confirmationCode ?? "").font(.largeTitle.monospacedDigit())
      Text("Check this number matches the Mac before tapping Allow.")
      Text("It can send scripts, control reading and send its camera picture. Only allow the Mac you just chose to connect.")
        .multilineTextAlignment(.center).foregroundStyle(.secondary)
      HStack(spacing: 24) {
        Button("Don’t allow") { link.approvePairing(false) }.buttonStyle(.bordered)
        Button("Allow") { link.approvePairing(true) }.buttonStyle(.borderedProminent).foregroundStyle(.black)
      }.controlSize(.large)
    }.padding(40)
  }
}

struct PairingPresentation: ViewModifier {
  @ObservedObject var link: MacLink
  func body(content: Content) -> some View {
    content.accessibilityHidden(link.pendingPermission != nil).overlay {
      if link.pendingPermission != nil {
        ZStack {
          Color.black.opacity(0.65).ignoresSafeArea()
          PairingPermissionView(link: link)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
      }
    }
  }
}
