@preconcurrency import AVFoundation
import CoreGraphics
import QuartzCore
import Synchronization

extension Notification.Name {
  static let cameraPictureSizeDidChange = Notification.Name("VideoPrompter.cameraPictureSizeDidChange")
}

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
    /// The listed duration nearest the mean gap between delivered frames' presentation times
    /// (seconds), counting only gaps near the median so a missed frame does not count; nil with
    /// too few frames to tell. After a re-pin the rate `pin` used is the one it wrote itself, so
    /// the frames are the only trustworthy measure of the signal's own rate.
    static func measuredDuration(_ times: [Double], in format: VideoFormat) -> CMTime? {
      let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
      guard gaps.count >= 3 else { return nil }
      let median = gaps[gaps.count / 2]
      let near = gaps.filter { abs($0 - median) < median * 0.25 }
      let mean = near.reduce(0, +) / Double(near.count)
      return format.frameDurations.flatMap { [$0.lowerBound, $0.upperBound] }
        .min { abs($0.seconds - mean) < abs($1.seconds - mean) }
    }
    /// Whether a DeckLink's delivered picture is a new signal: neither the size `pin` read as the
    /// signal nor the pinned format. The pinned format arriving is the preview working, so a re-pin
    /// it causes cannot cause another.
    static func isNewSignal(
      delivered: CMVideoDimensions, signal: CMVideoDimensions, pinned: CMVideoDimensions
    ) -> Bool {
      func same(_ a: CMVideoDimensions, _ b: CMVideoDimensions) -> Bool { a.width == b.width && a.height == b.height }
      return !same(delivered, signal) && !same(delivered, pinned)
    }
    static func frameDuration(_ signal: CMTime, in format: VideoFormat) -> CMTime {
      guard signal.isNumeric, signal > .zero,
        let range = format.frameDurations.first(where: { $0.contains(signal) })
      else { return .invalid }
      return range.lowerBound == range.upperBound ? range.lowerBound : signal
    }
  }

  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "VideoPrompter.camera.session")
  /// The format work and the frame watchdog, on `queue`. Internal for the stage view's latency log.
  private(set) lazy var probe = CameraFrameProbe(sessionQueue: queue)
  private var holders = CameraHolders()
  private var auto: CameraAutoOrientation?
  private var autoWanters = Set<ObjectIdentifier>()
  var holderCount: Int { holders.count }
  /// The camera actually attached.
  private(set) var attachedUID: String?
  /// The picture's own size, before rotation, for the aspect-fit of a turned feed. First the
  /// device's active format, then the frame the input port really delivers: a DeckLink hands over
  /// whatever the signal is (UHD, not the camera's 3:2 open gate), and a signal change moves it.
  /// Stage views relayout on `.cameraPictureSizeDidChange`.
  /// Internal so the geometry test can stand in for a delivered frame.
  var pictureSize: CGSize? {
    didSet { if pictureSize != oldValue { NotificationCenter.default.post(name: .cameraPictureSizeDidChange, object: self) } }
  }

  init() {
    NotificationCenter.default.addObserver(
      forName: AVCaptureInput.Port.formatDescriptionDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDeliveredSize() } }
  }

  /// The delivered frame's presentation size (pixel aspect applied, nothing cropped), read on the
  /// session queue and applied only if the camera is still the one asked about.
  private func refreshDeliveredSize() {
    let session = self.session
    let uid = attachedUID
    let probe = self.probe
    queue.async {
      let port = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
        .flatMap(\.ports).first { $0.mediaType == .video }
      guard let description = port?.formatDescription else { return }
      probe.follow(
        delivered: CMVideoFormatDescriptionGetDimensions(description),
        subType: description.mediaSubType.rawValue, in: session)
      let size = CMVideoFormatDescriptionGetPresentationDimensions(
        description, usePixelAspectRatio: true, useCleanAperture: false)
      Task { @MainActor in
        guard self.attachedUID == uid, size.width > 0, size.height > 0 else { return }
        self.pictureSize = size
      }
    }
  }

  /// A window that shows the camera holds the session while it is on screen and lets go when it
  /// is ordered out, closed or minimised: a 4K capture is not free.
  func retain() { if holders.retain() { setRunning(true) } }
  func release() { if holders.release() { setRunning(false) } }

  func select(_ uid: String?) {
    guard uid != attachedUID else { return }
    let session = self.session
    let device = uid.flatMap { AVCaptureDevice(uniqueID: $0) }
    let input = device.flatMap { try? AVCaptureDeviceInput(device: $0) }
    // Remember the camera only once it is really attached: selected before access was granted,
    // the input fails, and remembering it anyway left the picture black until relaunch.
    attachedUID = input != nil && AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? uid : nil
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
    // Queued behind the swap above, so it reads the pinned format's real frame.
    refreshDeliveredSize()
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

  /// Runs `change` on the session's own serial queue. The camera picker joins its preview layer
  /// through here, so nothing reconfigures this session from any other thread.
  func reconfigure(_ change: @escaping @Sendable (AVCaptureSession) -> Void) {
    let session = self.session
    let probe = self.probe
    // Held like every other reconfiguration, or adding a preview connection resets the format.
    queue.async { probe.holdingFormat(session) { change(session) } }
  }

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
    signalDuration: CMTime, useNativeFormat: Bool = false
  ) {
    func fits(_ f: SharedCameraSession.VideoFormat) -> Bool {
      Int64(f.width) * Int64(signal.height) == Int64(signal.width) * Int64(f.height)
        && f.width <= signal.width && max(f.width, f.height) <= 1920 && min(f.width, f.height) <= 1080
    }
    let target = useNativeFormat ? signal : formats.filter(fits).max { $0.width < $1.width } ?? signal
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
  /// `VIDEOPROMPTER_CAMERA_LATENCY_LOG=1`: for ten seconds after the camera starts, log how
  /// long frames take from capture to the app and to the next screen refresh.
  static let logsLatency =
    ProcessInfo.processInfo.environment["VIDEOPROMPTER_CAMERA_LATENCY_LOG"] == "1"
  static let usesNativeFormat =
    ProcessInfo.processInfo.environment["VIDEOPROMPTER_CAMERA_NATIVE_FORMAT"] == "1"
  static let watchdog: TimeInterval = 1.5
  static let logWindow = CameraLatency.logWindow(ProcessInfo.processInfo.environment["VIDEOPROMPTER_CAMERA_LATENCY_SECONDS"])

  private struct Shared {
    var frames = 0
    var dropped = 0
    /// Host-clock seconds; frames delivered before it are logged.
    var logUntil = 0.0
    /// The configured probe window's exact host-clock bounds.
    var logStart = 0.0
    /// Added to a presentation time to put it on the host clock.
    var toHost = 0.0
    var samples: [CameraLatency.Sample] = []
    var refreshes: [Double] = []
    /// Presentation times of the first frames after a re-pin, while the rate is measured.
    var rateTimes: [Double] = []
    var measuresRate = false
  }
  private let shared = Mutex(Shared())
  private let sessionQueue: DispatchQueue
  private let output = AVCaptureVideoDataOutput()
  private var current:
    (device: AVCaptureDevice, formats: [AVCaptureDevice.Format], choice: SharedCameraSession.FormatChoice)?
  /// Devices whose pinned rate showed nothing: they keep the format's default rate for this run.
  private var failed = Set<String>()
  private var generation = 0
  /// The signal's size as `pin` read it, so `follow` can tell a different delivered picture.
  private var signalSize: CMVideoDimensions?
  /// Set by `follow` for the pin it just made: watches measure the signal's rate from the frames
  /// until one completes the measurement. `pin` clears it, so it never outlives its device.
  private var measuresRate = false

  init(sessionQueue: DispatchQueue) {
    self.sessionQueue = sessionQueue
    super.init()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [:]
    output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "VideoPrompter.camera.probe"))
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
    signalSize = nil
    measuresRate = false
    guard let device = signal?.device else { return }
    let formats = device.formats
    guard let signal,
      var choice = SharedCameraSession.FormatChoice(
        in: formats.map(Self.row), signal: Self.row(signal.format), signalDuration: signal.duration,
        useNativeFormat: Self.usesNativeFormat)
    else { return }
    if failed.contains(device.uniqueID) { choice = choice.settled }
    current = (device, formats, choice)
    signalSize = CMVideoFormatDescriptionGetDimensions(signal.format.formatDescription)
    holdingFormat(session)
  }

  /// Session queue only, whenever the input port's format changes. A DeckLink that has streamed
  /// nothing yet reports its 720x486 default as the mode it detected, and `pin` held that: on
  /// 25 October Cam B's 4K signal showed in standard definition for the whole session. When the
  /// port then delivers a picture that is neither the signal `pin` saw nor the pinned format, the
  /// card has a new signal, larger or smaller, so pin again from it. The pinned format arriving
  /// (the normal 4K signal shown at 1080p) changes nothing, so this cannot loop. DeckLink only:
  /// other cameras deliver sizes that differ from their active format for their own reasons.
  func follow(delivered: CMVideoDimensions, subType: FourCharCode, in session: AVCaptureSession) {
    guard let current, let signalSize, current.device.modelID == "DeckLink",
      current.formats.indices.contains(current.choice.wanted.format),
      SharedCameraSession.FormatChoice.isNewSignal(
        delivered: delivered, signal: signalSize,
        pinned: CMVideoFormatDescriptionGetDimensions(current.formats[current.choice.wanted.format].formatDescription))
    else { return }
    let sameSize = current.device.formats.filter {
      let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
      return d.width == delivered.width && d.height == delivered.height
    }
    guard let format = sameSize.first(where: { $0.formatDescription.mediaSubType.rawValue == subType }) ?? sameSize.first
    else { return }
    NSLog("Video Prompter camera: the signal is %dx%d, not the %dx%d first reported; choosing the format again",
          delivered.width, delivered.height, signalSize.width, signalSize.height)
    // The pinned rate came from the same card, so it is the signal's rate unless the new format lacks it.
    pin((device: current.device, format: format, duration: current.device.activeVideoMinFrameDuration), in: session)
    // That duration is the one pin wrote for the default mode, not the signal's: measure it.
    measuresRate = true
    if session.isRunning { watch(session) }
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
    guard let current, current.choice.wanted != current.choice.fallback || Self.logsLatency || measuresRate else {
      detach(from: session)
      return
    }
    generation += 1
    let generation = self.generation
    let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    let toHost = session.synchronizationClock.map { host - CMClockGetTime($0).seconds } ?? 0
    let measuresRate = self.measuresRate
    shared.withLock {
      $0.frames = 0
      $0.toHost = toHost
      $0.rateTimes = []
      $0.measuresRate = measuresRate
      if Self.logsLatency {
        $0.logStart = host
        $0.logUntil = host + Self.logWindow
        $0.samples = []
        $0.refreshes = []
        $0.dropped = 0
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
      let (sawFrame, rateTimes) = shared.withLock {
        defer { $0.measuresRate = false }
        return ($0.frames > 0, $0.rateTimes)
      }
      // This watch ran to its end, so its measurement is done, whatever it found.
      if measuresRate { self.measuresRate = false }
      if session.isRunning, current.choice.revert(sawFrame: sawFrame) != nil {
        failed.insert(current.device.uniqueID)
        self.current?.choice = current.choice.settled
        holdingFormat(session, force: true)
        NSLog("Video Prompter camera: no frame in %.1f s, back to the format's default rate", Self.watchdog)
      } else if measuresRate, session.isRunning, current.formats.indices.contains(current.choice.wanted.format),
        let measured = SharedCameraSession.FormatChoice.measuredDuration(
          rateTimes, in: Self.row(current.formats[current.choice.wanted.format]))
      {
        let pinned = current.choice.wanted.frameDuration.isValid
          ? current.choice.wanted.frameDuration : current.device.activeVideoMinFrameDuration
        if abs(measured.seconds - pinned.seconds) > pinned.seconds * 0.05 {
          let format = current.choice.wanted.format
          self.current?.choice = .init(wanted: .init(format: format, frameDuration: measured), fallback: current.choice.fallback)
          holdingFormat(session)
          NSLog("Video Prompter camera: frames arrive every %.2f ms, not %.2f ms; pinning that rate",
                measured.seconds * 1000, pinned.seconds * 1000)
          // A rate like any other: check it shows frames, and keep the output for that check.
          return watch(session)
        }
      }
      if !Self.logsLatency { detach(from: session) }
    }
    guard Self.logsLatency else { return }
    let pinned = current.choice.wanted.frameDuration
    sessionQueue.asyncAfter(deadline: .now() + Self.logWindow + 0.5) { [self] in
      guard generation == self.generation else { return }
      let (samples, refreshes, dropped, measured) = shared.withLock {
        ($0.samples, $0.refreshes, $0.dropped, $0.logUntil - $0.logStart)
      }
      let format = current.choice.wanted.format
      let selected = current.formats.indices.contains(format) ? Self.row(current.formats[format]) : nil
      NSLog(
        "Video Prompter camera latency: %@; selected %@; pinned frame duration %@",
        CameraLatency.report(
          samples, refreshes: refreshes, dropped: dropped,
          duration: measured > 0 ? measured : Self.logWindow, pinned: pinned),
        selected.map { "\($0.width)x\($0.height) \($0.subType)" } ?? "unknown",
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
      if $0.measuresRate, $0.rateTimes.count < 12 { $0.rateTimes.append(presented) }
      if delivered < $0.logUntil {
        $0.samples.append(.init(capture: presented + $0.toHost, delivered: delivered))
      }
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let now = CACurrentMediaTime()
    shared.withLock { if now < $0.logUntil { $0.dropped += 1 } }
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
  static func logWindow(_ raw: String?) -> Double {
    guard let value = raw.flatMap(Double.init), value.isFinite else { return 10 }
    return min(max(value, 1), 60)
  }

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

  /// `duration` is the measured window, and `pinned` the frame duration the format was pinned to:
  /// an interval over 1.5 times it counts as a late frame.
  static func report(
    _ samples: [Sample], refreshes: [Double], dropped: Int = 0, duration: Double = 1,
    pinned: CMTime = .invalid
  ) -> String {
    let (delivered, shown) = delays(samples, refreshes: refreshes)
    let intervals = zip(samples.dropFirst(), samples).map { ($0.capture - $1.capture) * 1000 }
    func ms(_ values: [Double], _ p: Double) -> String {
      percentile(values, p).map { String(format: "%.1f", $0) } ?? "-"
    }
    let dropRate = String(format: "%.2f", Double(dropped) / max(duration, 1e-9))
    let late = pinned.isValid ? intervals.filter { $0 > pinned.seconds * 1500 }.count : nil
    let lateText = late.map { "late intervals \($0) (\(String(format: "%.2f", Double($0) / max(duration, 1e-9)))/s); " } ?? ""
    return "\(samples.count) frames; AVCapture output drops \(dropped) (\(dropRate)/s); " + lateText
      + "capture to app p50 \(ms(delivered, 0.5)) ms p90 \(ms(delivered, 0.9)) ms; "
      + "capture to next refresh p50 \(ms(shown, 0.5)) ms p90 \(ms(shown, 0.9)) ms; "
      + "frame interval p50 \(ms(intervals, 0.5)) ms"
  }
}
