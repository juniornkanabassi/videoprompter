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

  func testChannelsMustBeSeparableOrTheChoiceIsRefused() {
    XCTAssertFalse(AudioChannel.left.canIsolate(tapChannels: 1, deviceChannels: 2))
    XCTAssertFalse(AudioChannel.right.canIsolate(tapChannels: 1, deviceChannels: 4))
    XCTAssertTrue(AudioChannel.left.canIsolate(tapChannels: 2, deviceChannels: 2))
    XCTAssertTrue(AudioChannel.both.canIsolate(tapChannels: 1, deviceChannels: 2))
    XCTAssertTrue(AudioChannel.right.canIsolate(tapChannels: 1, deviceChannels: 1))
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

  static func sampleBuffer(_ input: AVAudioPCMBuffer) throws -> CMSampleBuffer {
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
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
