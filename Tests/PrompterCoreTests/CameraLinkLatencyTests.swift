@preconcurrency import AVFoundation
import Synchronization
import VideoToolbox
import XCTest

@testable import PrompterCore
@testable import VideoPrompter

/// Where the delay of the Mac to iPad picture goes, per frame, with synthetic frames and no camera
/// or window: encode (camera callback to the message queued), queue (queued to the transport starting
/// to write it) and decode (the iPad's decoder, here VideoToolbox's session). Showing the frame is
/// the iPad's display layer and can only be timed on the iPad. Every run prints `LATENCY` lines.
final class CameraLinkLatencyTests: XCTestCase {
  /// A transport that takes `rate` bytes a second and can stall once, recording when each frame
  /// was queued and when its write began.
  final class TimedPipe: LinkPipe, @unchecked Sendable {
    struct Frame { var queued = 0.0, writing = 0.0, key = false, data = Data() }
    private let queue = DispatchQueue(label: "test.timedpipe")
    private let state = Mutex((queued: [Double](), frames: [Int: Frame](), sets: [Data](), size: CGSize.zero))
    let bytesPerSecond: Double
    /// Wall-clock seconds (from `start`) at which writing freezes, and for how long.
    let stall: (at: Double, for: Double)?
    private let first = Mutex<Double?>(nil)
    private let stalled = Mutex(false)
    init(name: String, bytesPerSecond: Double, stall: (at: Double, for: Double)? = nil) {
      self.bytesPerSecond = bytesPerSecond
      self.stall = stall
      super.init(name: name)
    }
    override func queued(_ count: Int) {
      super.queued(count)
      state.withLock { $0.queued.append(CACurrentMediaTime()) }
    }
    override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
      let began = CACurrentMediaTime()
      let firstWrite = first.withLock { first -> Double in if first == nil { first = began }; return first! }
      let queuedAt = state.withLock { $0.queued.isEmpty ? began : $0.queued.removeFirst() }
      queue.async { [self] in
        var reader = CameraLink.Reader()
        for message in (try? reader.append(data)) ?? [] {
          switch message {
          case .format(let w, let h, let sets): state.withLock { $0.sets = sets; $0.size = CGSize(width: w, height: h) }
          case .frame(let time, let key, let payload):
            let index = Int((time * 30 + 500_000) / 1_000_000)
            state.withLock { $0.frames[index] = Frame(queued: queuedAt, writing: began, key: key, data: payload) }
          default: break
          }
        }
        if let stall, began - firstWrite >= stall.at, stalled.withLock({ defer { $0 = true }; return !$0 }) {
          Thread.sleep(forTimeInterval: stall.for)
        }
        Thread.sleep(forTimeInterval: Double(data.count) / bytesPerSecond)
        done()
      }
    }
    var frames: [Int: Frame] { state.withLock { $0.frames } }
    var sets: [Data] { state.withLock { $0.sets } }
    var size: CGSize { state.withLock { $0.size } }
  }

  /// One run: `seconds` of 30 fps frames into the encoder, then the per-stage report. Returns
  /// the encode, queue and decode delays in milliseconds, per frame that got through.
  @discardableResult
  private func run(
    _ label: String, camera: (Int, Int), over: String, megabits: Double, wifi: Bool,
    stall: (at: Double, for: Double)? = nil, seconds: Double = 3
  ) throws -> (encode: [Double], queue: [Double], decode: [Double], sent: Int, fed: Int, size: CGSize, frames: [Int: TimedPipe.Frame]) {
    let pipe = TimedPipe(name: over, bytesPerSecond: megabits * 125_000, stall: stall)
    let encoder = LinkEncoder()
    encoder.attach(pipe, bitRate: wifi ? 4_000_000 : 10_000_000, longSide: wifi ? 1280 : 1920)
    let fed = Int(seconds * 30)
    var feedTimes: [Double] = []
    var due = CACurrentMediaTime()
    for index in 0..<fed {
      let frame = try Self.noisyFrame(camera.0, camera.1, index)
      // Real time: a frame every 1/30 s after the last, so a slow first frame is no burst.
      while CACurrentMediaTime() < due { Thread.sleep(forTimeInterval: 0.0005) }
      due = CACurrentMediaTime() + 1.0 / 30
      feedTimes.append(CACurrentMediaTime())
      encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: frame, from: CameraLinkPipelineTests.connection)
    }
    try Self.drain(encoder, pipe)
    let frames = pipe.frames
    let order = frames.keys.sorted()
    // encode: the frame reached the pipe's queue; queue: until the transport began to write it.
    let encode = order.map { (frames[$0]!.queued - feedTimes[$0]) * 1000 }
    let queue = order.map { (frames[$0]!.writing - frames[$0]!.queued) * 1000 }
    let decode = try Self.timedDecode(order.map { frames[$0]!.data }, sets: pipe.sets)
    func stage(_ values: [Double]) -> String {
      func p(_ q: Double) -> String { String(format: "%6.1f", CameraLatency.percentile(values, q) ?? 0) }
      return "p50 \(p(0.5)) p95 \(p(0.95)) max \(p(1)) ms"
    }
    let sizes = order.map { Double(frames[$0]!.data.count) / 1000 }
    print("LATENCY \(label): \(Int(pipe.size.width))x\(Int(pipe.size.height)) over \(over), sent \(order.count) of \(fed) frames, "
      + "keys \(order.filter { frames[$0]!.key }.count), avg \(String(format: "%.1f", sizes.reduce(0, +) / Double(max(sizes.count, 1)))) KB")
    print("LATENCY   encode  \(stage(encode))")
    print("LATENCY   queue   \(stage(queue))")
    print("LATENCY   decode  \(stage(decode))")
    return (encode, queue, decode, order.count, fed, pipe.size, frames)
  }

  /// The three delays at the two sizes a confidence monitor sends, over each transport. The numbers
  /// are for reading; the checks are only that the picture arrives and the queue stays short.
  func testPerStageDelayAtTheTwoSizes() throws {
    let usb = try run("USB-C 1080p camera", camera: (1920, 1080), over: "USB-C", megabits: 480, wifi: false)
    let wifi1080 = try run("Wi-Fi 1080p camera", camera: (1920, 1080), over: "Wi-Fi", megabits: 40, wifi: true)
    let wifi720 = try run("Wi-Fi 720p camera", camera: (1280, 720), over: "Wi-Fi", megabits: 40, wifi: true)
    XCTAssertGreaterThan(usb.sent, 80)
    XCTAssertGreaterThan(wifi720.sent, 80)
    XCTAssertEqual(wifi1080.size.width, wifi720.size.width, "over Wi-Fi a 1080p camera is sent at 720p")
    XCTAssertLessThan(CameraLatency.percentile(wifi720.queue, 0.95) ?? 0, 50)
  }

  /// The transport freezes for 400 ms, as Wi-Fi does: the picture must come back at once, and no
  /// frame may have waited behind the stall for more than a frame or two.
  func testAStallDropsFramesInsteadOfQueueingThem() throws {
    let stalled = try run("Wi-Fi 720p, 400 ms stall", camera: (1280, 720), over: "Wi-Fi", megabits: 40, wifi: true, stall: (at: 1.5, for: 0.4))
    XCTAssertLessThan(stalled.sent, stalled.fed, "frames behind the stall are dropped")
    // The frame already waiting when the stall began is unavoidably late; nothing else may queue behind it.
    XCTAssertLessThanOrEqual(stalled.queue.filter { $0 > 100 }.count, 1, "at most one frame sat in the queue behind the stall")
    // The picture comes back: every frame after a gap is a key frame, and delivery goes on to the last
    // frame fed (run() has already decoded every frame that got through, each to a picture).
    let order = stalled.frames.keys.sorted()
    let gaps = zip(order, order.dropFirst()).filter { $1 != $0 + 1 }.map(\.1)
    XCTAssertFalse(gaps.isEmpty)
    for after in gaps { XCTAssertTrue(stalled.frames[after]!.key, "frame \(after) follows a dropped one") }
    XCTAssertEqual(order.last, stalled.fed - 1, "delivery continues to the last frame")
    XCTAssertGreaterThanOrEqual(order.filter { $0 >= (gaps.last ?? 0) }.count, 20, "a run of frames follows the stall")
  }

  /// Two frames arrive before either has left the encoder, with the transport stalled or not: the
  /// second is dropped before it is encoded, so only one frame's worth is ever in flight.
  func testASecondFrameIsNotAdmittedWhileOneIsStillEncoding() throws {
    let pipe = GatedPipe(name: "Wi-Fi")
    let encoder = LinkEncoder()
    encoder.attach(pipe, bitRate: 4_000_000, longSide: 1280)
    let connection = CameraLinkPipelineTests.connection
    // On its own thread: VideoToolbox may deliver the first frame on the calling thread, which the gate blocks.
    let first = try Self.noisyFrame(1280, 720, 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: first, from: connection)
      finished.signal()
    }
    // Frame 0's completion is now blocked inside the pipe, still counted as encoding.
    XCTAssertEqual(pipe.entered.wait(timeout: .now() + 10), .success, "frame 0 reached the pipe")
    XCTAssertEqual(encoder.framesEncoding, 1)
    encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try Self.noisyFrame(1280, 720, 1), from: connection)
    XCTAssertEqual(encoder.framesEncoding, 1, "frame 1 was not admitted")
    pipe.gate.signal()
    XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
    try Self.drain(encoder, pipe)
    XCTAssertEqual(encoder.framesEncoding, 0, "the slot is given back")
    // After a drop the next frame is let in, and is a key frame.
    encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try Self.noisyFrame(1280, 720, 2), from: connection)
    try Self.drain(encoder, pipe)
    XCTAssertEqual(pipe.frames.keys.sorted(), [0, 2])
    XCTAssertEqual(pipe.frames[2]?.key, true)
    XCTAssertEqual(encoder.framesEncoding, 0)
    XCTAssertEqual(try Self.timedDecode([0, 2].map { pipe.frames[$0]!.data }, sets: pipe.sets).count, 2)
  }

  /// Dropping a frame makes the next one a key frame, so the picture recovers without waiting
  /// for the periodic one.
  func testTheFrameAfterADropIsAKeyFrame() throws {
    let pipe = TimedPipe(name: "Wi-Fi", bytesPerSecond: 5_000_000, stall: (at: 0.5, for: 0.4))
    let encoder = LinkEncoder()
    encoder.attach(pipe, bitRate: 4_000_000, longSide: 1280)
    var due = CACurrentMediaTime()
    for index in 0..<45 {
      while CACurrentMediaTime() < due { Thread.sleep(forTimeInterval: 0.0005) }
      due = CACurrentMediaTime() + 1.0 / 30
      encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try Self.noisyFrame(1280, 720, index), from: CameraLinkPipelineTests.connection)
    }
    try Self.drain(encoder, pipe)
    let frames = pipe.frames
    let order = frames.keys.sorted()
    var gaps = 0
    for (before, after) in zip(order, order.dropFirst()) where after != before + 1 {
      gaps += 1
      XCTAssertTrue(frames[after]!.key, "frame \(after) follows a dropped one and must be a key frame")
    }
    XCTAssertGreaterThan(gaps, 0, "the stall dropped something")
    XCTAssertEqual(order.last, 44, "delivery continues to the last frame")
    // Every frame that got through, gaps and all, decodes to a picture: the key frames made it whole.
    XCTAssertEqual(try Self.timedDecode(order.map { frames[$0]!.data }, sets: pipe.sets).count, order.count)
  }

  /// Blocks the first message queued, on the encoder's output thread, until `gate` is signalled.
  final class GatedPipe: LinkPipe, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    private let first = Mutex(true)
    private let state = Mutex((frames: [Int: TimedPipe.Frame](), sets: [Data]()))
    override func queued(_ count: Int) {
      super.queued(count)
      if first.withLock({ defer { $0 = false }; return $0 }) {
        entered.signal()
        _ = gate.wait(timeout: .now() + 5)
      }
    }
    override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
      var reader = CameraLink.Reader()
      for message in (try? reader.append(data)) ?? [] {
        switch message {
        case .format(_, _, let sets): state.withLock { $0.sets = sets }
        case .frame(let time, let key, let payload):
          state.withLock { $0.frames[Int((time * 30 + 500_000) / 1_000_000)] = TimedPipe.Frame(key: key, data: payload) }
        default: break
        }
      }
      done()
    }
    var frames: [Int: TimedPipe.Frame] { state.withLock { $0.frames } }
    var sets: [Data] { state.withLock { $0.sets } }
  }

  // MARK: Helpers

  /// Waits for every frame fed to come out of the encoder, then for the transport to finish writing.
  static func drain(_ encoder: LinkEncoder, _ pipe: LinkPipe) throws {
    encoder.drain()
    let deadline = Date().addingTimeInterval(10)
    while pipe.pendingBytes > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    XCTAssertEqual(pipe.pendingBytes, 0, "the transport finished writing")
  }

  /// A 420v frame with a moving gradient and noise, so the encoder has real work to do.
  static func noisyFrame(_ width: Int, _ height: Int, _ index: Int) throws -> CMSampleBuffer {
    let image = try pooled(width, height, index % 6)
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
    return try XCTUnwrap(sample)
  }

  nonisolated(unsafe) private static var pool: [String: CVPixelBuffer] = [:]

  /// Filling a frame with noise is slow, so six per size are made and reused.
  private static func pooled(_ width: Int, _ height: Int, _ index: Int) throws -> CVPixelBuffer {
    if let made = pool["\(width)x\(height)/\(index)"] { return made }
    let made = try fill(width, height, index)
    pool["\(width)x\(height)/\(index)"] = made
    return made
  }

  private static func fill(_ width: Int, _ height: Int, _ index: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    var seed = UInt64(index &+ 1) &* 0x9E37_79B9_7F4A_7C15
    for plane in 0..<2 {
      let base = CVPixelBufferGetBaseAddressOfPlane(image, plane)!.assumingMemoryBound(to: UInt8.self)
      let rows = CVPixelBufferGetHeightOfPlane(image, plane)
      let columns = CVPixelBufferGetWidthOfPlane(image, plane) * (plane == 0 ? 1 : 2)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
      for row in 0..<rows {
        for column in 0..<columns {
          seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
          base[row * stride + column] = UInt8(truncatingIfNeeded: 16 + (column + row + index * 6) % 200 + Int(seed & 3))
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    return image
  }

  /// Milliseconds each frame takes to decode, one at a time, with the iPad's format description.
  /// Every submission and every callback must succeed with a picture of the stream's size, and every
  /// frame must come back: the result has one entry per frame, or the test fails.
  @discardableResult
  static func timedDecode(_ frames: [Data], sets: [Data]) throws -> [Double] {
    XCTAssertGreaterThanOrEqual(sets.count, 2, "the stream's parameter sets arrived")
    guard sets.count >= 2 else { return [] }
    var format: CMVideoFormatDescription?
    let copies = sets.map { [UInt8]($0) }
    let made = copies[0].withUnsafeBufferPointer { sps in
      copies[1].withUnsafeBufferPointer { pps in
        CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: nil, parameterSetCount: 2, parameterSetPointers: [sps.baseAddress!, pps.baseAddress!],
          parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
      }
    }
    XCTAssertEqual(made, noErr)
    let size = CMVideoFormatDescriptionGetDimensions(try XCTUnwrap(format))
    var session: VTDecompressionSession?
    XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session), noErr)
    defer { if let session { VTDecompressionSessionInvalidate(session) } }
    let pictures = Mutex(0)
    var times: [Double] = []
    for (index, data) in frames.enumerated() {
      var block: CMBlockBuffer?
      let bytes = [UInt8](data)
      CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
      CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count)
      var sample: CMSampleBuffer?
      var length = bytes.count
      CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &sample)
      let before = pictures.withLock { $0 }
      let began = CACurrentMediaTime()
      let submitted = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: try XCTUnwrap(sample), flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
        XCTAssertEqual(status, noErr)
        if let image, CVPixelBufferGetWidth(image) == Int(size.width), CVPixelBufferGetHeight(image) == Int(size.height) {
          pictures.withLock { $0 += 1 }
        }
      }
      XCTAssertEqual(submitted, noErr, "frame \(index) was accepted by the decoder")
      XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(session!), noErr)
      times.append((CACurrentMediaTime() - began) * 1000)
      XCTAssertEqual(pictures.withLock { $0 }, before + 1, "frame \(index) decoded to a picture of \(size.width)x\(size.height)")
    }
    XCTAssertEqual(pictures.withLock { $0 }, frames.count)
    return times
  }
}
