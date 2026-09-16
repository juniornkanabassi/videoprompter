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
  private var windowObservers: [NSObjectProtocol] = []
  /// What the window wants: the session only runs while the view is in a visible window.
  private var wantsRunning = false
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


  /// One row of a device's format table, reduced to what the choice actually turns on.
  struct VideoFormat: Equatable, Sendable {
    let width: Int32
    let height: Int32
    let subType: FourCharCode
    /// Bytes per pixel on the wire. DeckLink offers the same picture in several codings.
    var weight: Double {
      switch subType {
      case FourCharCode(kCVPixelFormatType_422YpCbCr8), FourCharCode(kCVPixelFormatType_422YpCbCr8_yuvs): return 2
      case FourCharCode(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
           FourCharCode(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange): return 1.5
      case FourCharCode(kCVPixelFormatType_422YpCbCr10): return 8.0 / 3
      default: return 4  // BGRA, ARGB, r210
      }
    }
  }

  /// Index of a cheaper coding of the picture the device already auto-detected, or nil to
  /// leave it alone. A DeckLink advertises every signal it can take and lands on 10-bit
  /// `v210` (4K v210 is about 1 GB/s); its 8-bit 4:2:2 twin is the same picture at half the
  /// bandwidth, and a preview layer cannot tell them apart. Same dimensions only — changing
  /// those would fight the card's own signal detection.
  static func preferredFormat(in formats: [VideoFormat], active: VideoFormat) -> Int? {
    let best = formats.enumerated()
      .filter { $0.element.width == active.width && $0.element.height == active.height }
      .min { $0.element.weight < $1.element.weight }
    guard let best, best.element.weight < active.weight else { return nil }
    return best.offset
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
    let device = uid.flatMap { AVCaptureDevice(uniqueID: $0) }
    let input = device.flatMap { try? AVCaptureDeviceInput(device: $0) }
    let wanted = wantsRunning
    sessionQueue.async {
      session.beginConfiguration()
      session.inputs.forEach(session.removeInput)
      if let input, session.canAddInput(input) { session.addInput(input) }
      session.commitConfiguration()
      if let device { Self.lightenFormat(of: device) }
      if input == nil || !wanted { session.stopRunning() } else if !session.isRunning { session.startRunning() }
    }
  }

  /// Pin the device's format. Always, even when `preferredFormat` has nothing better: assigning
  /// `activeFormat` is what puts the session on input priority (macOS has no such preset
  /// constant), and without it the default `.high` preset re-picks the format and a DeckLink
  /// loses the signal it auto-detected, falling back to 720x486 NTSC.
  private static func lightenFormat(of device: AVCaptureDevice) {
    func row(_ format: AVCaptureDevice.Format) -> VideoFormat {
      let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return VideoFormat(width: d.width, height: d.height, subType: format.formatDescription.mediaSubType.rawValue)
    }
    let active = device.activeFormat
    let pick = preferredFormat(in: device.formats.map(row), active: row(active)).map { device.formats[$0] } ?? active
    guard (try? device.lockForConfiguration()) != nil else { return }
    device.activeFormat = pick
    device.unlockForConfiguration()
  }

  /// Nothing runs while the window is closed or fully hidden: a 4K capture is not free.
  private func setRunning(_ on: Bool) {
    guard on != wantsRunning else { return }
    wantsRunning = on
    let session = self.session
    sessionQueue.async {
      if on {
        if !session.inputs.isEmpty, !session.isRunning { session.startRunning() }
      } else if session.isRunning {
        session.stopRunning()
      }
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers = []
    guard let window else { setRunning(false); return }
    for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
      windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
        MainActor.assumeIsolated {
          self?.setRunning(name == NSWindow.didChangeOcclusionStateNotification
            && (note.object as? NSWindow)?.occlusionState.contains(.visible) == true)
        }
      })
    }
    setRunning(window.occlusionState.contains(.visible))
  }

  func stop() {
    setRunning(false)
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers = []
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
