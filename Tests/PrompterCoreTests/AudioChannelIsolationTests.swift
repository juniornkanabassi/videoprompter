@preconcurrency import AVFoundation
import XCTest
@testable import VideoPrompter

/// Synthetic buffers only: no microphone, no permission prompt. A tone sits on one channel, the rest are silent.
final class AudioChannelIsolationTests: XCTestCase {
  enum Kind: CaseIterable { case float32, int16, int32 }
  static let amplitude: Float = 0.5

  static func format(_ kind: Kind, channels: Int, interleaved: Bool, rate: Double = 48_000) -> AVAudioFormat {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = rate
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mChannelsPerFrame = UInt32(channels)
    asbd.mFramesPerPacket = 1
    let bytes: UInt32 = kind == .int16 ? 2 : 4
    asbd.mBitsPerChannel = bytes * 8
    asbd.mFormatFlags = (kind == .float32 ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
      | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved)
    asbd.mBytesPerFrame = interleaved ? bytes * UInt32(channels) : bytes
    asbd.mBytesPerPacket = asbd.mBytesPerFrame
    let layout = channels > 2 ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) : nil
    return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)!
  }

  /// A 1 kHz tone on `toneChannel` only, written through the raw buffer list so every layout is covered the same way.
  static func buffer(_ kind: Kind, channels: Int, interleaved: Bool, toneChannel: Int, frames: Int = 960) -> AVAudioPCMBuffer {
    let format = format(kind, channels: channels, interleaved: interleaved)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    for frame in 0..<frames {
      let value = amplitude * Float(sin(2 * Double.pi * 1000 * Double(frame) / 48_000))
      let buf = list[interleaved ? 0 : toneChannel].mData!
      let index = interleaved ? frame * channels + toneChannel : frame
      switch kind {
      case .float32: buf.assumingMemoryBound(to: Float.self)[index] = value
      case .int16: buf.assumingMemoryBound(to: Int16.self)[index] = Int16(value * 32767)
      case .int32: buf.assumingMemoryBound(to: Int32.self)[index] = Int32(Double(value) * 2_147_483_647)
      }
    }
    return buffer
  }

  static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
    let data = buffer.floatChannelData![0]
    return (0..<Int(buffer.frameLength)).reduce(0) { max($0, abs(data[$1])) }
  }
  static func decibels(_ peak: Float) -> Float { AudioCapture.decibels(fullScalePeak: peak) }

  func testLeftAndRightKeepOnlyTheirOwnChannelInEveryLayout() throws {
    for channels in [2, 4] { for interleaved in [true, false] { for kind in Kind.allCases {
      for tone in 0..<channels {
        let input = Self.buffer(kind, channels: channels, interleaved: interleaved, toneChannel: tone)
        for channel in [AudioChannel.left, .right] {
          let label = "\(channels)ch interleaved=\(interleaved) \(kind) tone on \(tone), \(channel)"
          let output = try XCTUnwrap(channel.extract(input), label)
          XCTAssertEqual(output.format.channelCount, 1, label)
          XCTAssertEqual(output.frameLength, input.frameLength, label)
          let wanted = tone == (channel == .left ? 0 : 1)
          if wanted { XCTAssertEqual(Self.peak(output), Self.amplitude, accuracy: 0.01, label) }
          else { XCTAssertLessThan(Self.decibels(Self.peak(output)), -90, label) }
        }
      }
    } } }
  }

  func testBothAveragesChannelsOneAndTwoOnly() throws {
    for channels in [2, 4] { for interleaved in [true, false] { for kind in Kind.allCases {
      for tone in 0..<channels {
        let output = try XCTUnwrap(AudioChannel.both.mono(Self.buffer(kind, channels: channels, interleaved: interleaved, toneChannel: tone)))
        let label = "\(channels)ch interleaved=\(interleaved) \(kind) tone on \(tone)"
        if tone < 2 { XCTAssertEqual(Self.peak(output), Self.amplitude / 2, accuracy: 0.01, label) }
        else { XCTAssertLessThan(Self.decibels(Self.peak(output)), -90, label) }
      }
    } } }
  }

  func testMonoSourceKeepsItsOnlyChannelWhateverWasSaved() throws {
    for channel in AudioChannel.allCases {
      let output = try XCTUnwrap(channel.mono(Self.buffer(.float32, channels: 1, interleaved: false, toneChannel: 0)))
      XCTAssertEqual(Self.peak(output), Self.amplitude, accuracy: 0.01, "\(channel)")
    }
  }

  /// What the recogniser and the meter receive: the same isolated signal, with no energy from the other side.
  func testRecogniserAndMeterFollowOnlyTheChosenChannel() throws {
    let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    var device = AudioInputDevice(id: 1, uid: "fx3", name: "FX3 handle")
    device.channels = 2
    for kind in Kind.allCases { for interleaved in [true, false] {
      let leftTone = Self.buffer(kind, channels: 2, interleaved: interleaved, toneChannel: 0)
      let rightTone = Self.buffer(kind, channels: 2, interleaved: interleaved, toneChannel: 1)
      let monoLeft = try XCTUnwrap(AudioChannel.left.mono(leftTone)), monoRight = try XCTUnwrap(AudioChannel.right.mono(rightTone))
      for (channel, wanted, unwanted, expected) in [(AudioChannel.left, leftTone, rightTone, monoLeft), (.right, rightTone, leftTone, monoRight)] {
        let chosen = try XCTUnwrap(AudioCapture(device: device, outputFormat: output, channel: channel).prepared(48_000).process(wanted))
        let other = try XCTUnwrap(AudioCapture(device: device, outputFormat: output, channel: channel).prepared(48_000).process(unwanted))
        let label = "\(kind) interleaved=\(interleaved) \(channel)"
        XCTAssertGreaterThan(chosen.peak, 0.3, label)
        XCTAssertLessThan(Self.decibels(other.peak), -90, label)
        XCTAssertLessThan(Self.decibels(other.rms), -90, label)
        // The recogniser sees exactly what a mono source holding only that channel would give it.
        let direct = try XCTUnwrap(AudioCapture(device: device, outputFormat: output, channel: .both).prepared(48_000).process(expected))
        XCTAssertEqual(chosen.buffer.frameLength, direct.buffer.frameLength, label)
        for i in 0..<Int(chosen.buffer.frameLength) {
          XCTAssertEqual(chosen.buffer.floatChannelData![0][i], direct.buffer.floatChannelData![0][i], accuracy: 1e-6, label)
        }
      }
    } }
  }

  /// (selection, hardware channels, tap channels, plan): the decision capture takes on both platforms.
  func testCapturePlanFromHardwareTapAndSelection() {
    let table: [(AudioChannel, Int, Int, AudioChannel.CapturePlan)] = [
      (.left, 2, 2, .useTap), (.right, 2, 2, .useTap), (.left, 8, 8, .useTap), (.right, 4, 2, .useTap),
      // The tap shrank to one channel but the hardware has more: ask for channels 1 and 2 rather than refuse.
      (.left, 2, 1, .requestSeparateChannels), (.right, 2, 1, .requestSeparateChannels), (.right, 8, 1, .requestSeparateChannels),
      // Hardware itself reports one channel: Left is that channel, Right has nothing to pick.
      (.left, 1, 1, .useTap), (.right, 1, 1, .cannotIsolate),
      // Both never blocks anything.
      (.both, 2, 1, .useTap), (.both, 1, 1, .useTap), (.both, 8, 2, .useTap),
    ]
    for (selection, hardware, tap, plan) in table {
      XCTAssertEqual(selection.capturePlan(hardwareChannels: hardware, tapChannels: tap), plan, "\(selection) hw=\(hardware) tap=\(tap)")
    }
    XCTAssertTrue(AudioChannel.right.separateChannelsMessage.contains("two separate channels"))
  }

  /// Through the real writer: distinct tones on channels 1 to 4, Left or Right extracted, a file written and decoded.
  /// Both stays stereo in the file on purpose: the Alpha keeps stereo for Both, so nothing is mixed down there.
  func testRecordedFileHoldsOnlyTheChosenChannelsTone() async throws {
    let tones: [Double] = [440, 1000, 2000, 3000]
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("channel-file-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for (inputChannels, selection) in [(2, AudioChannel.left), (2, .right), (4, .left), (4, .right), (2, .both)] {
      let stereoFile = selection == .both
      let url = folder.appendingPathComponent("\(inputChannels)-\(selection.rawValue).mov")
      let writer = try MovieWriter(url: url, width: 320, height: 240, transform: .identity, preset: .edit,
        audio: AudioSpec(sampleRate: 48_000, channels: stereoFile ? 2 : 1), floatAudio: true)
      for chunk in 0..<30 {
        try writer.append(video: Self.videoFrame(chunk))
        let captured = try Self.sampleBuffer(Self.tones(tones, channels: inputChannels, start: chunk * 1600, frames: 1600), at: CMTime(value: Int64(chunk * 1600), timescale: 48_000))
        try writer.append(audio: try XCTUnwrap(selection.extract(captured)))
        try await Task.sleep(for: .milliseconds(35))
      }
      _ = try await writer.finish()
      let decoded = try await Self.decode(url)
      let label = "\(inputChannels)ch \(selection)"
      XCTAssertEqual(decoded.count, stereoFile ? 2 : 1, label)
      let expected: [Int] = selection == .left ? [0] : selection == .right ? [1] : [0, 1]
      for (index, samples) in decoded.enumerated() {
        for (toneIndex, tone) in tones.enumerated() {
          let level = Self.amplitude(of: tone, in: samples)
          if toneIndex == expected[index] { XCTAssertEqual(level, Self.amplitude, accuracy: 0.02, "\(label) file channel \(index) \(tone) Hz") }
          else { XCTAssertLessThan(level, 0.001, "\(label) file channel \(index) \(tone) Hz leaked") }  // -60 dBFS
        }
      }
    }
  }

  static func tones(_ tones: [Double], channels: Int, start: Int, frames: Int) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format(.float32, channels: channels, interleaved: true), frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
    for frame in 0..<frames { for channel in 0..<channels {
      data[frame * channels + channel] = amplitude * Float(sin(2 * Double.pi * tones[channel] * Double(start + frame) / 48_000))
    } }
    return buffer
  }

  static func videoFrame(_ frame: Int) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
    let image = try XCTUnwrap(pixel)
    CVPixelBufferLockBaseAddress(image, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(image) {
      memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), plane == 0 ? 80 : 128, CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample)
    return try XCTUnwrap(sample)
  }

  /// The file's audio as one float array per channel.
  static func decode(_ url: URL) async throws -> [[Float]] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var samples: [Float] = []
    var channels = 0
    while let buffer = output.copyNextSampleBuffer() {
      if channels == 0, let description = CMSampleBufferGetFormatDescription(buffer), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) { channels = Int(asbd.pointee.mChannelsPerFrame) }
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
      chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
      samples += chunk
    }
    XCTAssertGreaterThan(channels, 0)
    return (0..<channels).map { channel in stride(from: channel, to: samples.count, by: channels).map { samples[$0] } }
  }

  /// Amplitude of one frequency (Goertzel), ignoring the first 2400 frames while the encoder settles.
  static func amplitude(of frequency: Double, in samples: [Float]) -> Float {
    let slice = samples.dropFirst(2400)
    let w = 2 * Double.pi * frequency / 48_000, coefficient = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    for sample in slice { let s0 = Double(sample) + coefficient * s1 - s2; s2 = s1; s1 = s0 }
    let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
    return Float(2 * power.squareRoot() / Double(slice.count))
  }

  /// The recording and recording-test path: CMSampleBuffers as AVCaptureAudioDataOutput delivers them (interleaved).
  func testRecordingPathKeepsOnlyTheChosenChannel() throws {
    for (kind, channels) in [(Kind.float32, 2), (.float32, 4), (.int16, 2)] {
      for tone in 0..<channels {
        let sample = try Self.sampleBuffer(Self.buffer(kind, channels: channels, interleaved: true, toneChannel: tone))
        for channel in [AudioChannel.left, .right] {
          let label = "\(kind) \(channels)ch tone on \(tone), \(channel)"
          let selected = try XCTUnwrap(channel.extract(sample), label)
          let peaks = RecordingAudioTest.channelPeaks(in: selected)
          XCTAssertEqual(peaks.count, 1, label)
          let wanted = tone == (channel == .left ? 0 : 1)
          if wanted { XCTAssertEqual(peaks[0], Self.amplitude, accuracy: 0.01, label) }
          else { XCTAssertLessThan(Self.decibels(peaks[0]), -90, label) }
        }
      }
    }
  }

  static func sampleBuffer(_ input: AVAudioPCMBuffer, at time: CMTime = .zero) throws -> CMSampleBuffer {
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: input.format.formatDescription, sampleCount: Int(input.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
    let buffer = try XCTUnwrap(sample)
    XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: input.audioBufferList), noErr)
    CMSampleBufferSetDataReady(buffer)
    return buffer
  }
}

private extension AudioCapture {
  func prepared(_ rate: Double) throws -> AudioCapture { try prepareConverter(sampleRate: rate); return self }
}
