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
  nonisolated static func preferredFormat(in formats: [VideoFormat], active: VideoFormat) -> Int? {
    let best = formats.enumerated()
      .filter { $0.element.width == active.width && $0.element.height == active.height }
      .min { $0.element.weight < $1.element.weight }
    guard let best, best.element.weight < active.weight else { return nil }
    return best.offset
  }
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "JuniorPrompter.camera.session")
  private var holders = CameraHolders()
  private var currentUID: String?
  private var auto: CameraAutoOrientation?
  private var autoWanters = Set<ObjectIdentifier>()
  var holderCount: Int { holders.count }
  /// The camera actually attached, for the retry test.
  var attachedUID: String? { currentUID }
  /// The picture's own size, before rotation, for the aspect-fit of a turned feed.
  private(set) var pictureSize: CGSize?

  /// A window that shows the camera holds the session while it is on screen and lets go when it
  /// is ordered out, closed or minimised: a 4K capture is not free.
  func retain() { if holders.retain() { setRunning(true) } }
  func release() { if holders.release() { setRunning(false) } }

  func select(_ uid: String?) {
    guard uid != currentUID else { return }
    let session = self.session
    let device = uid.flatMap { AVCaptureDevice(uniqueID: $0) }
    let input = device.flatMap { try? AVCaptureDeviceInput(device: $0) }
    // Remember the camera only once it is really attached: selected before access was granted,
    // the input fails, and remembering it anyway left the picture black until relaunch.
    currentUID = input != nil && AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? uid : nil
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
  ///
  /// Two stage views can ask at once — the Camera window and the presenter's video background —
  /// so `owner` identifies which one is asking and the detector goes away only when neither
  /// wants it. Without that, covering one window took Auto away from the other.
  ///
  /// Attach and detach reconfigure the session, so they go on the session's own serial queue
  /// like `select` does. Running `beginConfiguration` from the main actor while the queue is
  /// inside its own begin/commit is two threads in one configuration block.
  func setAutoOrientation(
    _ enabled: Bool, for owner: AnyObject,
    onRotation: @escaping @Sendable (CameraRotation) -> Void
  ) {
    let id = ObjectIdentifier(owner)
    if enabled { autoWanters.insert(id) } else { autoWanters.remove(id) }
    let session = self.session
    if !autoWanters.isEmpty, auto == nil {
      let detector = CameraAutoOrientation(onRotation: onRotation)
      auto = detector
      queue.async { detector.attach(to: session) }
    } else if autoWanters.isEmpty, let detector = auto {
      auto = nil
      queue.async { detector.detach(from: session) }
    }
  }
  /// For the test that covering one window must not stop the other's Auto.
  var isAutoOrienting: Bool { auto != nil }

  /// Runs `change` on the session's own serial queue. The camera picker joins its preview layer
  /// through here, so nothing reconfigures this session from any other thread.
  func reconfigure(_ change: @escaping @Sendable (AVCaptureSession) -> Void) {
    let session = self.session
    queue.async { change(session) }
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
  ///
  /// `nonisolated`, and it must stay that way: this runs on the session's own serial queue, and a
  /// main-actor-isolated version of it is what crashed 0.7.1 with `dispatch_assert_queue_fail`. It
  /// touches the device only, never this class's state.
  nonisolated private static func pinFormat(of device: AVCaptureDevice) {
    func row(_ format: AVCaptureDevice.Format) -> VideoFormat {
      let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return VideoFormat(
        width: d.width, height: d.height, subType: format.formatDescription.mediaSubType.rawValue)
    }
    let active = device.activeFormat
    let pick =
      Self.preferredFormat(in: device.formats.map(row), active: row(active))
      .map { device.formats[$0] } ?? active
    guard (try? device.lockForConfiguration()) != nil else { return }
    device.activeFormat = pick
    device.unlockForConfiguration()
  }
}
