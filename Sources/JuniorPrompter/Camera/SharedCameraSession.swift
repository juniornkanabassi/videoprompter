@preconcurrency import AVFoundation
import CoreGraphics

/// Start when the first holder arrives, stop when the last one leaves.
struct CameraHolders {
  private(set) var count = 0
  /// True when the session should start now.
  mutating func retain() -> Bool {
    count += 1
    return count == 1
  }
  /// True when the session should stop now.
  mutating func release() -> Bool {
    guard count > 0 else { return false }
    count -= 1
    return count == 0
  }
}

/// One capture session for both windows. The Camera window and the presenter's video background
/// show the same camera, and a DeckLink cannot be opened twice, so there is one session, one
/// input, a preview layer each, and a holder count that stops the capture when neither window is
/// showing it.
@MainActor final class SharedCameraSession {
  static let shared = SharedCameraSession()
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "JuniorPrompter.camera.session")
  private var holders = CameraHolders()
  private var currentUID: String?
  private var auto: CameraAutoOrientation?
  var holderCount: Int { holders.count }
  /// The picture's own size, before rotation, for the aspect-fit of a turned feed.
  private(set) var pictureSize: CGSize?

  /// A window that shows the camera holds the session while it is visible and lets go when it
  /// closes or is fully covered: a 4K capture is not free.
  func retain() { if holders.retain() { setRunning(true) } }
  func release() { if holders.release() { setRunning(false) } }

  func select(_ uid: String?) {
    guard uid != currentUID else { return }
    currentUID = uid
    let session = self.session
    let device = uid.flatMap { AVCaptureDevice(uniqueID: $0) }
    let input = device.flatMap { try? AVCaptureDeviceInput(device: $0) }
    let running = holders.count > 0
    queue.async {
      session.beginConfiguration()
      session.inputs.forEach(session.removeInput)
      if let input, session.canAddInput(input) { session.addInput(input) }
      session.commitConfiguration()
      if let device { Self.pinFormat(of: device) }
      if input == nil || !running {
        session.stopRunning()
      } else if !session.isRunning {
        session.startRunning()
      }
    }
    pictureSize = device.map {
      let d = CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
      return CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
    }
  }

  /// Auto orientation runs only while it is switched on and something is showing the camera.
  func setAutoOrientation(_ enabled: Bool, onRotation: @escaping @Sendable (CameraRotation) -> Void) {
    if enabled, auto == nil {
      let detector = CameraAutoOrientation(onRotation: onRotation)
      auto = detector
      detector.attach(to: session)
    } else if !enabled, let detector = auto {
      detector.detach(from: session)
      auto = nil
    }
  }

  private func setRunning(_ on: Bool) {
    let session = self.session
    queue.async {
      if on {
        if !session.inputs.isEmpty, !session.isRunning { session.startRunning() }
      } else if session.isRunning {
        session.stopRunning()
      }
    }
  }

  /// Pin the device's format. Always, even when `preferredFormat` has nothing better: assigning
  /// `activeFormat` is what puts the session on input priority (macOS has no such preset
  /// constant), and without it the default `.high` preset re-picks the format and a DeckLink
  /// loses the signal it auto-detected, falling back to 720x486 NTSC.
  private static func pinFormat(of device: AVCaptureDevice) {
    func row(_ format: AVCaptureDevice.Format) -> CameraPreviewView.VideoFormat {
      let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return CameraPreviewView.VideoFormat(
        width: d.width, height: d.height, subType: format.formatDescription.mediaSubType.rawValue)
    }
    let active = device.activeFormat
    let pick =
      CameraPreviewView.preferredFormat(in: device.formats.map(row), active: row(active))
      .map { device.formats[$0] } ?? active
    guard (try? device.lockForConfiguration()) != nil else { return }
    device.activeFormat = pick
    device.unlockForConfiguration()
  }
}
