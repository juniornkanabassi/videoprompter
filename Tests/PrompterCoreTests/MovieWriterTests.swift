import AVFoundation
import XCTest
@testable import VidPrompt

final class MovieWriterTests: XCTestCase {
  func testUnsupportedAudioThrowsBeforeCreatingWriter() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for (spec, floatAudio) in [(AudioSpec(sampleRate: 96000, channels: 16), false), (AudioSpec(sampleRate: 48000, channels: 16), true), (AudioSpec(sampleRate: 96000, channels: 2), false)] {
      XCTAssertThrowsError(try MovieWriter(url: folder.appendingPathComponent("invalid.mov"), width: 320, height: 240, transform: .identity, preset: .standard, audio: spec, floatAudio: floatAudio)) { error in
        XCTAssertTrue(error.localizedDescription.contains("2 channels"))
      }
    }
  }
  private func video(_ frame: Int) throws -> CMSampleBuffer {
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
  private func audio(_ frame: Int) throws -> CMSampleBuffer {
    let count = 1600
    var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 8, flags: 0, blockBufferOut: &block)
    let data = (0..<count * 2).map { Float(sin(Double($0 / 2 + frame * count) * 2 * .pi * 440 / 48000) * 0.1) }
    data.withUnsafeBytes { bytes in _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(frame * count), timescale: 48000), decodeTimeStamp: .invalid)
    var size = 8; var sample: CMSampleBuffer?
    CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    return try XCTUnwrap(sample)
  }
  func testPlayableCodecsAndFloatAudioWithoutHardware() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for preset in RecordingPreset.allCases {
      let url = folder.appendingPathComponent("\(preset.rawValue).mov")
      let hasAudio = preset != .high
      let writer = try MovieWriter(url: url, width: 320, height: 240, transform: .identity, preset: preset, audio: hasAudio ? AudioSpec(sampleRate: 48000, channels: 2) : nil, floatAudio: preset == .edit)
      for i in 0..<30 {
        try writer.append(video: video(i))
        if hasAudio { try writer.append(audio: audio(i)) }
        try await Task.sleep(for: .milliseconds(35))
      }
      _ = try await writer.finish()
      let asset = AVURLAsset(url: url)
      let playable = try await asset.load(.isPlayable)
      XCTAssertTrue(playable)
      let duration = try await asset.load(.duration)
      XCTAssertEqual(duration.seconds, 1, accuracy: 0.1)
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, hasAudio ? 1 : 0)
      if preset == .edit {
        let formats = try await audioTracks[0].load(.formatDescriptions)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(try XCTUnwrap(formats.first)))
        XCTAssertNotEqual(asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat, 0)
        XCTAssertEqual(asbd.pointee.mBitsPerChannel, 32)
      }
      let original = try Data(contentsOf: url)
      XCTAssertThrowsError(try MovieWriter(url: url, width: 320, height: 240, transform: .identity, preset: preset, audio: nil, floatAudio: false))
      XCTAssertEqual(try Data(contentsOf: url), original)
    }
  }
}
