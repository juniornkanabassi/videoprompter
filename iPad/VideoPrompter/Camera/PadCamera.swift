@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The picture behind the script. Under teleprompter glass the iPad's own cameras face the
/// ceiling, so the useful source there is a USB-C camera or HDMI capture adapter carrying the
/// studio camera's feed; the front camera is for when the iPad stands on its own.
@MainActor final class PadCamera: ObservableObject {
  @Published var isOn = false { didSet { isOn ? start() : stop() } }
  @Published private(set) var devices: [Device] = []
  @Published var selectedID: String? { didSet { if isOn, selectedID != oldValue { configure() } } }
  @Published var mirrored = false { didSet { UserDefaults.standard.set(mirrored, forKey: "cameraMirrored") } }
  @Published var guides = CameraGuides() { didSet { guideStore.set(guides, for: selectedID) } }
  @Published private(set) var notice: String?

  struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let isExternal: Bool
  }

  nonisolated let capture = CaptureBox()
  private let guideStore = CameraGuideStore()
  private var tokens: [NSObjectProtocol] = []

  init() {
    mirrored = UserDefaults.standard.bool(forKey: "cameraMirrored")
    refreshDevices()
    for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
      tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.devicesChanged() }
      })
    }
  }

  static func discover() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external, .builtInWideAngleCamera, .builtInUltraWideCamera],
      mediaType: .video, position: .unspecified
    ).devices
  }

  func refreshDevices() {
    devices = Self.discover().map {
      Device(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external)
    }.sorted { $0.isExternal && !$1.isExternal }
    if selectedID.map({ id in devices.contains { $0.id == id } }) != true {
      selectedID = devices.first?.id
    }
    guides = guideStore.guides(for: selectedID)
  }

  /// Plugging a capture adapter in switches to it at once; pulling it out falls back.
  private func devicesChanged() {
    let previous = selectedID
    let hadExternal = devices.contains { $0.isExternal }
    refreshDevices()
    if !hadExternal, let external = devices.first(where: \.isExternal) { selectedID = external.id }
    if isOn, selectedID != previous { configure() }
  }

  private func start() {
    Task {
      let allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        ? true : await AVCaptureDevice.requestAccess(for: .video)
      guard allowed else {
        notice = "Allow camera access in Settings › Privacy & Security › Camera."
        isOn = false
        return
      }
      configure()
    }
  }

  private func configure() {
    guard let id = selectedID, let device = Self.discover().first(where: { $0.uniqueID == id }) else {
      notice = "No camera found. Plug in a USB-C camera or capture adapter."
      return
    }
    notice = nil
    guides = guideStore.guides(for: id)
    capture.use(device) { [weak self] message in
      Task { @MainActor in self?.notice = message }
    }
  }

  private func stop() { capture.stop() }
}

/// The capture session lives on its own queue; nothing on the main thread waits for it.
final class CaptureBox: @unchecked Sendable {
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "VideoPrompter.camera")

  func use(_ device: AVCaptureDevice, onError: @escaping @Sendable (String) -> Void) {
    queue.async { [session] in
      session.beginConfiguration()
      session.inputs.forEach { session.removeInput($0) }
      do {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
      } catch {
        onError("Could not open \(device.localizedName): \(error.localizedDescription)")
      }
      session.commitConfiguration()
      if !session.isRunning { session.startRunning() }
    }
  }

  func stop() {
    queue.async { [session] in if session.isRunning { session.stopRunning() } }
  }
}

/// The live picture, filling the presenter behind the text, with the Mac's framing guides.
struct CameraPreview: UIViewRepresentable {
  @ObservedObject var camera: PadCamera

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = camera.capture.session
    view.previewLayer.videoGravity = .resizeAspect
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) {
    view.apply(deviceID: camera.selectedID, mirrored: camera.mirrored, guides: camera.guides)
  }

  final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let guideLayer = CAShapeLayer()
    private let shadeLayer = CAShapeLayer()
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private var deviceID: String?
    private var mirrored = false
    private var guides = CameraGuides()

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .black
      shadeLayer.fillRule = .evenOdd
      guideLayer.fillColor = nil
      guideLayer.lineWidth = 1.5
      layer.addSublayer(shadeLayer)
      layer.addSublayer(guideLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(deviceID: String?, mirrored: Bool, guides: CameraGuides) {
      if deviceID != self.deviceID {
        self.deviceID = deviceID
        observation = nil
        coordinator = nil
        // A built-in camera turns with the iPad; an external feed is shown as it arrives, turned
        // by the guides' rotation like the Mac's Cam B.
        if let device = PadCamera.discover().first(where: { $0.uniqueID == deviceID }),
          device.deviceType != .external
        {
          let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
          self.coordinator = coordinator
          observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.applyConnection() }
          }
        }
      }
      self.mirrored = mirrored
      self.guides = guides
      applyConnection()
      setNeedsLayout()
    }

    private func applyConnection() {
      guard let connection = previewLayer.connection else { return }
      let angle = coordinator?.videoRotationAngleForHorizonLevelPreview ?? CGFloat(guides.rotation.rawValue)
      if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      shadeLayer.frame = bounds
      guideLayer.frame = bounds
      let picture = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
      let rect = picture.isEmpty || picture.isInfinite ? bounds : picture
      guideLayer.path = CameraOverlay.guidePath(picture: rect, guides: guides)
      guideLayer.strokeColor = guides.strokeColor
      shadeLayer.path = guides.marker == nil ? nil : CameraOverlay.shadePath(picture: rect, guides: guides)
      shadeLayer.fillColor = guides.shadeColor
    }
  }
}
