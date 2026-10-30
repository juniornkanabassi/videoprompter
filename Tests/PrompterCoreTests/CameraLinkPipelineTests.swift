@preconcurrency import AVFoundation
import Network
import Synchronization
import VideoToolbox
import XCTest

@testable import PrompterCore
@testable import VideoPrompter

/// The Mac half of the iPad link, end to end on this Mac: camera frames of any shape through the
/// encoder, over each transport, read back and decoded the way the iPad does.
final class CameraLinkPipelineTests: XCTestCase {
  /// A pipe that keeps what is sent.
  final class CollectingPipe: LinkPipe, @unchecked Sendable {
    let bytes = Mutex(Data())
    override func send(_ data: Data) { bytes.withLock { $0.append(data) } }
  }

  /// What the Camera window can hand over: a UVC webcam or ATEM at 720p or 1080p, a DeckLink
  /// at UHD, and a camera turned on its side. The capture output always asks for 420v.
  func testEveryCameraShapeArrivesDecodable() throws {
    for (width, height, expected) in [(1280, 720, (1280, 720)), (1920, 1080, (1920, 1080)), (3840, 2160, (1920, 1080)), (1080, 1920, (1080, 1920))] {
      let pipe = CollectingPipe(name: "test")
      let encoder = LinkEncoder()
      encoder.attach(pipe)
      for index in 0..<15 { encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try Self.frame(width, height, index), from: Self.connection) }
      let messages = try Self.wait(for: pipe, frames: 15)
      guard case .format(let w, let h, let sets) = messages.first else { return XCTFail("\(width)×\(height): no format first") }
      XCTAssertEqual(w, expected.0, "\(width)×\(height)")
      XCTAssertEqual(h, expected.1, "\(width)×\(height)")
      let frames = messages.compactMap { message -> (Bool, Data)? in
        if case .frame(_, let key, let data) = message { return (key, data) }
        return nil
      }
      XCTAssertEqual(frames.first?.0, true, "\(width)×\(height): starts on a key frame")
      XCTAssertEqual(try Self.decode(frames.map(\.1), sets: sets), frames.count, "\(width)×\(height): every frame decodes")
    }
  }

  /// Turning the camera off while the remote stays: the end of the picture comes after every
  /// frame, so the iPad never goes back to a frozen Mac picture.
  func testTheEndOfThePictureFollowsTheLastFrame() throws {
    let pipe = CollectingPipe(name: "test")
    let encoder = LinkEncoder()
    encoder.attach(pipe)
    for index in 0..<5 { encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try Self.frame(1920, 1080, index), from: Self.connection) }
    encoder.finish(pipe)
    encoder.captureQueue.sync {}
    // A frame the camera delivers after the switch is not sent.
    encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try Self.frame(1920, 1080, 5), from: Self.connection)
    var reader = CameraLink.Reader()
    let messages = try reader.append(pipe.bytes.withLock { $0 })
    XCTAssertEqual(messages.last, .format(width: 0, height: 0, parameterSets: []))
    XCTAssertEqual(messages.filter { if case .frame = $0 { true } else { false } }.count, 5)
  }

  /// Closed before it ever read: the socket is still let go of exactly once.
  func testASocketPipeClosedBeforeReadingStillEnds() {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let pipe = SocketPipe(socket: fds[0], name: "USB-C")
    let ended = expectation(description: "closed")
    pipe.onClose = { ended.fulfill() }
    pipe.close()
    pipe.startReading()
    wait(for: [ended], timeout: 2)
    var byte: UInt8 = 0
    XCTAssertEqual(Darwin.read(fds[1], &byte, 1), 0, "the Mac end is closed")
    Darwin.close(fds[1])
  }

  /// The USB-C path: a socket the iPad answers on.
  func testTheSocketPipeCarriesBothWaysAndReportsTheEnd() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let pipe = SocketPipe(socket: fds[0], name: "USB-C")
    let received = Mutex<[CameraLink.Message]>([])
    let ended = expectation(description: "closed")
    pipe.onMessage = { message in received.withLock { $0.append(message) } }
    pipe.onClose = { ended.fulfill() }
    pipe.startReading()
    let state = PadRemote.State(scripts: [], presenting: nil, running: false, mode: "Voice", speed: 120, word: 0, words: 0)
    // Split across writes, as a stream may deliver it.
    let bytes = CameraLink.Message.state(state).encoded()
    XCTAssertTrue(USBMux.writeAll(fds[1], bytes.prefix(3)))
    XCTAssertTrue(USBMux.writeAll(fds[1], bytes.dropFirst(3)))
    pipe.send(CameraLink.Message.command(.play).encoded())
    var reader = CameraLink.Reader()
    var back: [CameraLink.Message] = []
    while back.isEmpty, let chunk = USBMux.readExactly(fds[1], 1) { back += try reader.append(chunk) }
    XCTAssertEqual(back, [.command(.play)])
    Darwin.close(fds[1])
    wait(for: [ended], timeout: 2)
    XCTAssertEqual(received.withLock { $0 }, [.state(state)])
  }

  /// The Wi-Fi path: TLS keyed by the pairing key, both ways, and a wrong key refused.
  func testTheWiFiPipeNeedsTheKeyAndCarriesBothWays() async throws {
    let code = CameraLinkSecurity.newCode()
    let listener = try NWListener(using: CameraLinkSecurity.parameters(code: code), on: .any)
    let queue = DispatchQueue(label: "test.ipad")
    let fromMac = Mutex(Data())
    let state = PadRemote.State(scripts: [], presenting: nil, running: true, mode: "Manual", speed: 200, word: 3, words: 9)
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      connection.send(content: CameraLink.Message.state(state).encoded(), completion: .idempotent)
      func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, _ in
          if let data { fromMac.withLock { $0.append(data) } }
          if !done { read() }
        }
      }
      read()
    }
    let ready = expectation(description: "listening")
    listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
    listener.start(queue: queue)
    await fulfillment(of: [ready], timeout: 3)
    defer { listener.cancel() }
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: listener.port!)

    guard case .refused = await NetworkPipe.open(endpoint, code: CameraLinkSecurity.newCode()) else { return XCTFail("a wrong key connected") }
    guard case .opened(let pipe) = await NetworkPipe.open(endpoint, code: code) else { return XCTFail("the right key did not connect") }
    let got = expectation(description: "state")
    pipe.onMessage = { if $0 == .state(state) { got.fulfill() } }
    pipe.startReading()
    pipe.send(CameraLink.Message.command(.nextPassage).encoded())
    await fulfillment(of: [got], timeout: 3)
    for _ in 0..<30 where fromMac.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
    var reader = CameraLink.Reader()
    XCTAssertEqual(try reader.append(fromMac.withLock { $0 }), [.command(.nextPassage)])
    pipe.close()
  }

  // MARK: Helpers

  static let connection = AVCaptureConnection(inputPorts: [], output: AVCaptureVideoDataOutput())

  static func frame(_ width: Int, _ height: Int, _ index: Int) throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    for plane in 0..<2 {
      let base = CVPixelBufferGetBaseAddressOfPlane(image, plane)!.assumingMemoryBound(to: UInt8.self)
      let rows = CVPixelBufferGetHeightOfPlane(image, plane)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
      for row in 0..<rows { memset(base + row * stride, Int32((row + index * 8) % 200 + 16), stride) }
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
    return try XCTUnwrap(sample)
  }

  /// Every message once `frames` frames have arrived, waiting up to five seconds.
  static func wait(for pipe: CollectingPipe, frames: Int) throws -> [CameraLink.Message] {
    var messages: [CameraLink.Message] = []
    for _ in 0..<50 {
      var reader = CameraLink.Reader()
      messages = try reader.append(pipe.bytes.withLock { $0 })
      if messages.filter({ if case .frame = $0 { true } else { false } }).count >= frames { break }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return messages
  }

  /// Decodes with the format the iPad builds from the same parameter sets; returns how many did.
  static func decode(_ frames: [Data], sets: [Data]) throws -> Int {
    var format: CMVideoFormatDescription?
    let copies = sets.map { [UInt8]($0) }
    let status = copies[0].withUnsafeBufferPointer { sps in
      copies[1].withUnsafeBufferPointer { pps in
        CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: nil, parameterSetCount: 2, parameterSetPointers: [sps.baseAddress!, pps.baseAddress!],
          parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
      }
    }
    XCTAssertEqual(status, noErr)
    var session: VTDecompressionSession?
    XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session), noErr)
    let size = CMVideoFormatDescriptionGetDimensions(format!)
    var decoded = 0
    for data in frames {
      var block: CMBlockBuffer?
      let bytes = [UInt8](data)
      CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
      CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count)
      var sample: CMSampleBuffer?
      var length = bytes.count
      CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &sample)
      VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
        if status == noErr, let image, CVPixelBufferGetWidth(image) == Int(size.width), CVPixelBufferGetHeight(image) == Int(size.height) { decoded += 1 }
      }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session!)
    VTDecompressionSessionInvalidate(session!)
    return decoded
  }
}
