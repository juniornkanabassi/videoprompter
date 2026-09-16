@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// A video device as the picker shows it. `uid` is `AVCaptureDevice.uniqueID`, which is what
/// gets remembered: names repeat across identical cameras, unique IDs do not.
struct CameraDevice: Identifiable, Hashable, Sendable {
  let uid: String
  let name: String
  var id: String { uid }
}

@MainActor final class CameraModel: ObservableObject {
  @Published private(set) var devices: [CameraDevice] = []
  @Published var selectedUID: String? { didSet { defaults.set(selectedUID, forKey: "cameraDeviceUID") } }
  @Published var mirrored: Bool { didSet { defaults.set(mirrored, forKey: "cameraMirrored") } }
  @Published var showsThirds: Bool { didSet { defaults.set(showsThirds, forKey: "cameraShowsThirds") } }
  @Published var showsAxes: Bool { didSet { defaults.set(showsAxes, forKey: "cameraShowsAxes") } }
  @Published var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: "cameraAlwaysOnTop") } }
  @Published var authorization = AVCaptureDevice.authorizationStatus(for: .video)
  private let defaults: UserDefaults
  // nonisolated so `deinit` can take the observers back out again.
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    selectedUID = defaults.string(forKey: "cameraDeviceUID")
    mirrored = defaults.bool(forKey: "cameraMirrored")
    showsThirds = defaults.bool(forKey: "cameraShowsThirds")
    showsAxes = defaults.bool(forKey: "cameraShowsAxes")
    alwaysOnTop = defaults.bool(forKey: "cameraAlwaysOnTop")
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  /// Built-in, USB/Thunderbolt UVC, Continuity Camera and every virtual camera (OBS, Elgato,
  /// Blackmagic) that registers itself as an AVFoundation device — those arrive as `.external`.
  static func discovered() -> [CameraDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
      mediaType: .video, position: .unspecified
    ).devices.map { CameraDevice(uid: $0.uniqueID, name: $0.localizedName) }
  }

  /// Keep the remembered camera when it is still plugged in, otherwise take whatever is.
  static func resolve(_ savedUID: String?, in devices: [CameraDevice]) -> CameraDevice? {
    devices.first { $0.uid == savedUID } ?? devices.first
  }

  func start() {
    guard observers.isEmpty else { refresh(); return }
    for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      })
    }
    Task {
      if authorization == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
      }
      refresh()
    }
  }

  func refresh() {
    devices = Self.discovered()
    let resolved = Self.resolve(selectedUID, in: devices)?.uid
    if resolved != selectedUID { selectedUID = resolved }
  }
}

/// Live preview plus the composition overlay. Aspect-fit, so the overlay is drawn over the
/// video rectangle rather than the view's bounds.
final class CameraPreviewView: NSView {
  private let session = AVCaptureSession()
  private let preview = AVCaptureVideoPreviewLayer()
  private let overlay = CAShapeLayer()
  private let sessionQueue = DispatchQueue(label: "JuniorPrompter.camera.session")
  private var currentUID: String?
  private var mirrored = false
  private var thirds = false
  private var axes = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    preview.session = session
    preview.videoGravity = .resizeAspect
    overlay.fillColor = nil
    overlay.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
    overlay.lineWidth = 1
    layer?.addSublayer(preview)
    layer?.addSublayer(overlay)
  }
  required init?(coder: NSCoder) { nil }

  /// Straight lines only: two thirds lines each way, and the centre cross.
  static func overlayPath(in rect: CGRect, thirds: Bool, axes: Bool) -> CGPath {
    let path = CGMutablePath()
    func line(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
    if thirds {
      for step in 1...2 {
        let x = rect.minX + rect.width * CGFloat(step) / 3
        let y = rect.minY + rect.height * CGFloat(step) / 3
        line(CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY))
        line(CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y))
      }
    }
    if axes {
      line(CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY))
      line(CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY))
    }
    return path
  }

  func apply(uid: String?, mirrored: Bool, thirds: Bool, axes: Bool) {
    self.mirrored = mirrored
    self.thirds = thirds
    self.axes = axes
    if uid != currentUID {
      currentUID = uid
      select(uid)
    }
    preview.connection.map {
      $0.automaticallyAdjustsVideoMirroring = false
      $0.isVideoMirrored = mirrored
    }
    needsLayout = true
  }

  private func select(_ uid: String?) {
    let session = self.session
    let input = uid.flatMap { AVCaptureDevice(uniqueID: $0) }.flatMap { try? AVCaptureDeviceInput(device: $0) }
    sessionQueue.async {
      session.beginConfiguration()
      session.inputs.forEach(session.removeInput)
      if let input, session.canAddInput(input) { session.addInput(input) }
      session.commitConfiguration()
      if input == nil { session.stopRunning() } else if !session.isRunning { session.startRunning() }
    }
  }

  func stop() {
    let session = self.session
    sessionQueue.async { session.stopRunning() }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    preview.frame = bounds
    let video = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    overlay.frame = bounds
    overlay.path = Self.overlayPath(in: video.isEmpty ? bounds : video, thirds: thirds, axes: axes)
    CATransaction.commit()
  }
}

private struct CameraPreview: NSViewRepresentable {
  @ObservedObject var model: CameraModel
  func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView(frame: .zero) }
  func updateNSView(_ view: CameraPreviewView, context: Context) {
    view.apply(uid: model.selectedUID, mirrored: model.mirrored, thirds: model.showsThirds, axes: model.showsAxes)
    view.window?.level = model.alwaysOnTop ? .floating : .normal
  }
  static func dismantleNSView(_ view: CameraPreviewView, coordinator: ()) { view.stop() }
}

struct CameraView: View {
  @StateObject private var model = CameraModel()
  var body: some View {
    Group {
      switch model.authorization {
      case .denied, .restricted:
        VStack(spacing: 12) {
          Text("JuniorPrompter does not have permission to use the camera.")
          Button("Open System Settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
          }
        }.padding()
      default:
        if model.devices.isEmpty {
          Text("No camera found.").foregroundStyle(.secondary)
        } else {
          CameraPreview(model: model).background(.black)
        }
      }
    }
    .frame(minWidth: 320, minHeight: 200)
    .task { model.start() }
    .toolbar {
      ToolbarItem {
        Picker("Camera", selection: $model.selectedUID) {
          ForEach(model.devices) { Text($0.name).tag(Optional($0.uid)) }
        }.frame(minWidth: 180)
      }
      ToolbarItem {
        Toggle("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: $model.mirrored)
      }
      ToolbarItem { Toggle("Thirds", systemImage: "grid", isOn: $model.showsThirds) }
      ToolbarItem { Toggle("Centre", systemImage: "plus.viewfinder", isOn: $model.showsAxes) }
      ToolbarItem { Toggle("Always on Top", systemImage: "pin", isOn: $model.alwaysOnTop) }
    }
  }
}
