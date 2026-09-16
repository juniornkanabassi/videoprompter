@preconcurrency import AVFoundation
import CoreGraphics
import QuartzCore
import Synchronization

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
    /// One range per `AVFrameRateRange`, as durations. A DeckLink lists each rate on its own.
    var frameDurations: [ClosedRange<CMTime>] = []
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
  /// bandwidth, and a preview layer cannot tell them apart. Same dimensions only: the size is
  /// `FormatChoice`'s decision.
  nonisolated static func preferredFormat(in formats: [VideoFormat], active: VideoFormat) -> Int? {
    let best = formats.enumerated()
      .filter { $0.element.width == active.width && $0.element.height == active.height }
      .min { $0.element.weight < $1.element.weight }
    guard let best, best.element.weight < active.weight else { return nil }
    return best.offset
  }

  /// What `select` asks of the device, and what it goes back to when that shows nothing.
  struct FormatChoice: Equatable, Sendable {
    /// An index into the device's formats, and a frame duration; `.invalid` is the format's own.
    struct Pick: Equatable, Sendable {
      let format: Int
      let frameDuration: CMTime
    }
    let wanted: Pick
    let fallback: Pick

    /// After the watchdog: the pick to go back to, or nil to keep what is running.
    func revert(sawFrame: Bool) -> Pick? { sawFrame || wanted == fallback ? nil : fallback }
    /// The fallback, with nothing left to check.
    var settled: FormatChoice { FormatChoice(wanted: fallback, fallback: fallback) }

    /// The signal's own duration when the format lists it, else the format's default: setting
    /// a duration the format does not list throws. A listed single rate gives the device's own
    /// value, so 2002/60000 goes in as the 1001/30000 the card offers.
    static func frameDuration(_ signal: CMTime, in format: VideoFormat) -> CMTime {
      guard signal.isNumeric, signal > .zero,
        let range = format.frameDurations.first(where: { $0.contains(signal) })
      else { return .invalid }
      return range.lowerBound == range.upperBound ? range.lowerBound : signal
    }
  }

  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "JuniorPrompter.camera.session")
  /// The format work and the frame watchdog, on `queue`. Internal for the stage view's latency log.
  private(set) lazy var probe = CameraFrameProbe(sessionQueue: queue)
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
    let probe = self.probe
    queue.async {
      // Before the session touches the device: this is the mode the card detected.
      let signal = device.map { (device: $0, format: $0.activeFormat, duration: $0.activeVideoMinFrameDuration) }
      session.beginConfiguration()
      session.inputs.forEach(session.removeInput)
      if let input, session.canAddInput(input) { session.addInput(input) }
      session.commitConfiguration()
      probe.pin(signal, in: session)
      if input == nil || !running {
        session.stopRunning()
      } else {
        probe.start(session)
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
    let probe = self.probe
    if !autoWanters.isEmpty, auto == nil {
      let detector = CameraAutoOrientation(onRotation: onRotation)
      auto = detector
      queue.async { probe.holdingFormat(session) { detector.attach(to: session) } }
    } else if autoWanters.isEmpty, let detector = auto {
      auto = nil
      queue.async { probe.holdingFormat(session) { detector.detach(from: session) } }
    }
  }
  /// For the test that covering one window must not stop the other's Auto.
  var isAutoOrienting: Bool { auto != nil }

  private func setRunning(_ on: Bool) {
    let session = self.session
    let probe = self.probe
    queue.async {
      if on {
        if !session.inputs.isEmpty, !session.isRunning { probe.start(session) }
      } else if session.isRunning {
        session.stopRunning()
      }
    }
  }
}

extension SharedCameraSession.FormatChoice {
  /// The preview's format: the signal's own shape at 1920x1080 at most, in its cheapest coding, at
  /// the signal's own frame rate. 1080p because it is what 0.8.1 showed on screen from a 4K Cam B
  /// (the `.high` preset re-picked it at every start), and because four times fewer pixels reach
  /// the app, where the preview layer converts and scales every frame to the window: 4K 10-bit
  /// conversion was the 20% idle CPU of 0.7.0. The signal's own rate because any other rate has
  /// the Desktop Video extension repeat or drop frames against its own clock. The fallback is the
  /// same format at its default rate. Nil when the signal's size is not in the table.
  init?(
    in formats: [SharedCameraSession.VideoFormat], signal: SharedCameraSession.VideoFormat,
    signalDuration: CMTime
  ) {
    func fits(_ f: SharedCameraSession.VideoFormat) -> Bool {
      Int64(f.width) * Int64(signal.height) == Int64(signal.width) * Int64(f.height)
        && f.width <= signal.width && max(f.width, f.height) <= 1920 && min(f.width, f.height) <= 1080
    }
    let target = formats.filter(fits).max { $0.width < $1.width } ?? signal
    guard
      let index = SharedCameraSession.preferredFormat(in: formats, active: target)
        ?? formats.firstIndex(of: target)
    else { return nil }
    self.init(
      wanted: Pick(format: index, frameDuration: Self.frameDuration(signalDuration, in: formats[index])),
      fallback: Pick(format: index, frameDuration: .invalid))
  }
}

/// The format `select` pins and holds, and the data output that checks it: attached only while a
/// pinned rate waits for its first frame, or while latency is logged. Late frames are dropped,
/// never queued, and buffers keep the device's own coding, so nothing is converted for it. The
/// picture itself stays on `AVCaptureVideoPreviewLayer`, which takes frames from the capture
/// pipeline into a Core Animation image queue with no app code per frame and no timebase.
///
/// `@unchecked Sendable`: `current`, `failed`, `generation` and `output` are touched on the
/// session's serial queue only, and what the sample callback shares sits behind `shared`.
final class CameraFrameProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  /// `JUNIORPROMPTER_CAMERA_LATENCY_LOG=1`: for ten seconds after the camera starts, log how
  /// long frames take from capture to the app and to the next screen refresh.
  static let logsLatency =
    ProcessInfo.processInfo.environment["JUNIORPROMPTER_CAMERA_LATENCY_LOG"] == "1"
  static let watchdog: TimeInterval = 1.5
  static let logWindow: TimeInterval = 10

  private struct Shared {
    var frames = 0
    /// Host-clock seconds; frames delivered before it are logged.
    var logUntil = 0.0
    /// Added to a presentation time to put it on the host clock.
    var toHost = 0.0
    var samples: [CameraLatency.Sample] = []
    var refreshes: [Double] = []
  }
  private let shared = Mutex(Shared())
  private let sessionQueue: DispatchQueue
  private let output = AVCaptureVideoDataOutput()
  private var current:
    (device: AVCaptureDevice, formats: [AVCaptureDevice.Format], choice: SharedCameraSession.FormatChoice)?
  /// Devices whose pinned rate showed nothing: they keep the format's default rate for this run.
  private var failed = Set<String>()
  private var generation = 0

  init(sessionQueue: DispatchQueue) {
    self.sessionQueue = sessionQueue
    super.init()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [:]
    output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "JuniorPrompter.camera.probe"))
  }

  /// Session queue only, right after the input is swapped. `signal` is the device with the format
  /// and frame duration it reported before the session touched it: the mode the card detected.
  ///
  /// Assigning `activeFormat`, always, is also what puts the session on input priority (macOS
  /// has no such preset constant). This must stay off the main actor: a main-actor version of it
  /// crashed 0.7.1 with `dispatch_assert_queue_fail`.
  func pin(
    _ signal: (device: AVCaptureDevice, format: AVCaptureDevice.Format, duration: CMTime)?,
    in session: AVCaptureSession
  ) {
    generation += 1
    current = nil
    guard let device = signal?.device else { return }
    let formats = device.formats
    guard let signal,
      var choice = SharedCameraSession.FormatChoice(
        in: formats.map(Self.row), signal: Self.row(signal.format), signalDuration: signal.duration)
    else { return }
    if failed.contains(device.uniqueID) { choice = choice.settled }
    current = (device, formats, choice)
    holdingFormat(session)
  }

  /// Session queue only: start with the format held, then check it.
  func start(_ session: AVCaptureSession) {
    if !session.isRunning { holdingFormat(session) { session.startRunning() } }
    watch(session)
  }

  /// Session queue only. Sets the pinned format and rate, then runs `change` (a start, or an
  /// output added or removed) with the device lock held, so the `.high` preset cannot re-pick
  /// them: 0.8.1's unified log shows every `startRunning` taking Cam B from the pinned 3840x2160
  /// back to 1920x1080. The lock is released straight after, since Apple warns that holding it
  /// can degrade other apps' capture from the same device.
  func holdingFormat(_ session: AVCaptureSession, force: Bool = false, _ change: () -> Void = {}) {
    guard let current, (try? current.device.lockForConfiguration()) != nil else { return change() }
    session.beginConfiguration()
    Self.set(current.choice.wanted, from: current.formats, on: current.device, force: force)
    session.commitConfiguration()
    change()
    current.device.unlockForConfiguration()
  }

  /// Session queue only, once the session runs. Attaches the output when a pinned rate needs its
  /// first frame or latency is logged; after `watchdog` seconds with no frame, the device goes
  /// back to the format's default rate for the rest of the run.
  func watch(_ session: AVCaptureSession) {
    guard let current, current.choice.wanted != current.choice.fallback || Self.logsLatency else {
      detach(from: session)
      return
    }
    generation += 1
    let generation = self.generation
    let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    let toHost = session.synchronizationClock.map { host - CMClockGetTime($0).seconds } ?? 0
    shared.withLock {
      $0.frames = 0
      $0.toHost = toHost
      if Self.logsLatency {
        $0.logUntil = host + Self.logWindow
        $0.samples = []
        $0.refreshes = []
      }
    }
    if !session.outputs.contains(output) {
      holdingFormat(session) {
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
      }
    }
    sessionQueue.asyncAfter(deadline: .now() + Self.watchdog) { [self] in
      guard generation == self.generation else { return }
      let sawFrame = shared.withLock { $0.frames > 0 }
      if session.isRunning, current.choice.revert(sawFrame: sawFrame) != nil {
        failed.insert(current.device.uniqueID)
        self.current?.choice = current.choice.settled
        holdingFormat(session, force: true)
        NSLog("JuniorPrompter camera: no frame in %.1f s, back to the format's default rate", Self.watchdog)
      }
      if !Self.logsLatency { detach(from: session) }
    }
    guard Self.logsLatency else { return }
    let pinned = current.choice.wanted.frameDuration
    sessionQueue.asyncAfter(deadline: .now() + Self.logWindow + 0.5) { [self] in
      guard generation == self.generation else { return }
      let (samples, refreshes) = shared.withLock { ($0.samples, $0.refreshes) }
      NSLog(
        "JuniorPrompter camera latency: %@; pinned frame duration %@", CameraLatency.report(samples, refreshes: refreshes),
        pinned.isValid ? String(format: "%.2f ms", pinned.seconds * 1000) : "default")
      detach(from: session)
    }
  }

  private func detach(from session: AVCaptureSession) {
    guard session.outputs.contains(output) else { return }
    holdingFormat(session) {
      session.beginConfiguration()
      session.removeOutput(output)
      session.commitConfiguration()
    }
  }

  /// Main thread, from a stage view's display link while latency is logged: the next refresh.
  func refreshed(at time: Double) {
    shared.withLock { if $0.refreshes.count < 2000 { $0.refreshes.append(time) } }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let delivered = CACurrentMediaTime()
    let presented = sampleBuffer.presentationTimeStamp.seconds
    shared.withLock {
      $0.frames += 1
      if delivered < $0.logUntil {
        $0.samples.append(.init(capture: presented + $0.toHost, delivered: delivered))
      }
    }
  }

  private static func row(_ format: AVCaptureDevice.Format) -> SharedCameraSession.VideoFormat {
    let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    return .init(
      width: d.width, height: d.height, subType: format.formatDescription.mediaSubType.rawValue,
      frameDurations: format.videoSupportedFrameRateRanges.map {
        min($0.minFrameDuration, $0.maxFrameDuration)...max($0.minFrameDuration, $0.maxFrameDuration)
      })
  }

  /// With the device locked, inside a begin/commit, as Apple documents. Only what differs is
  /// written, so a held start does not restart the stream; `force` also resets a default rate.
  /// A format the device no longer lists is skipped: assigning it would throw.
  private static func set(
    _ pick: SharedCameraSession.FormatChoice.Pick, from formats: [AVCaptureDevice.Format],
    on device: AVCaptureDevice, force: Bool
  ) {
    guard formats.indices.contains(pick.format), device.formats.contains(formats[pick.format]) else { return }
    let format = formats[pick.format]
    let newFormat = device.activeFormat != format
    if newFormat { device.activeFormat = format }
    let rateDiffers =
      pick.frameDuration.isValid
      && (device.activeVideoMinFrameDuration != pick.frameDuration
        || device.activeVideoMaxFrameDuration != pick.frameDuration)
    guard newFormat || force || rateDiffers else { return }
    device.activeVideoMinFrameDuration = pick.frameDuration
    device.activeVideoMaxFrameDuration = pick.frameDuration
  }
}

/// The latency log's arithmetic, apart from the capture so it can be tested.
enum CameraLatency {
  /// Host-clock seconds.
  struct Sample: Equatable, Sendable {
    let capture: Double
    let delivered: Double
  }

  /// Nearest rank; nil for nothing.
  static func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }

  /// Milliseconds from capture to the app, and to the first screen refresh at or after that,
  /// which is the earliest the preview layer can show the frame.
  static func delays(_ samples: [Sample], refreshes: [Double]) -> (delivered: [Double], shown: [Double]) {
    let refreshes = refreshes.sorted()
    return (
      samples.map { ($0.delivered - $0.capture) * 1000 },
      samples.compactMap { sample in
        refreshes.first { $0 >= sample.delivered }.map { ($0 - sample.capture) * 1000 }
      }
    )
  }

  static func report(_ samples: [Sample], refreshes: [Double]) -> String {
    let (delivered, shown) = delays(samples, refreshes: refreshes)
    let intervals = zip(samples.dropFirst(), samples).map { ($0.capture - $1.capture) * 1000 }
    func ms(_ values: [Double], _ p: Double) -> String {
      percentile(values, p).map { String(format: "%.1f", $0) } ?? "-"
    }
    return "\(samples.count) frames; capture to app p50 \(ms(delivered, 0.5)) ms p90 \(ms(delivered, 0.9)) ms; "
      + "capture to next refresh p50 \(ms(shown, 0.5)) ms p90 \(ms(shown, 0.9)) ms; "
      + "frame interval p50 \(ms(intervals, 0.5)) ms"
  }
}
