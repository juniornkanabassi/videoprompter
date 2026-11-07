import AVFoundation

 enum RecordingPreset: String, CaseIterable, Codable, Sendable {
  case standard, high, edit
  var label: String {
    switch self { case .standard: "H.264 (most compatible)"; case .high: "HEVC (smaller files)"; case .edit: "ProRes 422 (for editing)" }
  }
  var codec: AVVideoCodecType {
    switch self { case .standard: .h264; case .high: .hevc; case .edit: .proRes422 }
  }
}
struct AudioSpec: Sendable { let sampleRate: Double; let channels: Int }
/// Confined to the caller's serial recording queue, including finish after its last append.
final class MovieWriter: @unchecked Sendable {
  private let writer: AVAssetWriter
  private let video: AVAssetWriterInput
  private let audio: AVAssetWriterInput?
  private var started = false
  private var firstTime = CMTime.invalid
  private(set) var droppedFrames = 0
  private(set) var droppedAudioBuffers = 0
  var audioReadyOverride: Bool?
  var videoReadyOverride: Bool?
  private(set) var writtenFrames = 0
  init(url: URL, width: Int, height: Int, transform: CGAffineTransform, preset: RecordingPreset, audio: AudioSpec?, floatAudio: Bool) throws {
    guard !FileManager.default.fileExists(atPath: url.path),
      (try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.type] as? FileAttributeType) == .typeDirectory,
      width > 0, height > 0, audio.map({ $0.sampleRate > 0 && $0.channels > 0 }) ?? true
    else { throw CocoaError(.fileWriteInvalidFileName) }
    if let audio, audio.channels > 2 || !audio.sampleRate.isFinite || (!floatAudio && audio.sampleRate > 48_000) {
      throw NSError(domain: "MovieWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording audio supports at most 2 channels and AAC sample rates up to 48 kHz."])
    }
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
    video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: preset.codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
    video.expectsMediaDataInRealTime = true; video.transform = transform
    guard writer.canAdd(video) else { throw CocoaError(.featureUnsupported) }; writer.add(video)
    if let spec = audio {
      var settings: [String: Any] = [AVFormatIDKey: floatAudio ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC, AVSampleRateKey: spec.sampleRate, AVNumberOfChannelsKey: spec.channels]
      if floatAudio {
        settings[AVLinearPCMBitDepthKey] = 32; settings[AVLinearPCMIsFloatKey] = true
        settings[AVLinearPCMIsBigEndianKey] = false; settings[AVLinearPCMIsNonInterleaved] = false
      } else { settings[AVEncoderBitRateKey] = spec.channels == 1 ? 128_000 : 256_000 }
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { throw CocoaError(.featureUnsupported) }; writer.add(input); self.audio = input
    } else { self.audio = nil }
  }
  @discardableResult
  func append(video buffer: CMSampleBuffer) throws -> Bool {
    if !started {
      guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
      firstTime = CMSampleBufferGetPresentationTimeStamp(buffer)
      writer.startSession(atSourceTime: firstTime); started = true
    }
    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    if videoReadyOverride ?? video.isReadyForMoreMediaData {
      if !video.append(buffer) {
        guard writer.status != .failed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        droppedFrames += 1
        return false
      }
      writtenFrames += 1
      return true
    } else { droppedFrames += 1; return false }
  }
  func append(audio buffer: CMSampleBuffer) throws {
    guard let audio else { return }
    guard started, CMSampleBufferGetPresentationTimeStamp(buffer) >= firstTime,
      audioReadyOverride ?? audio.isReadyForMoreMediaData else { droppedAudioBuffers += 1; return }
    if !audio.append(buffer) {
      droppedAudioBuffers += 1
      if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
  }
  func finish() async throws -> URL {
    guard started, writer.status == .writing else {
      writer.cancelWriting(); throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
    video.markAsFinished(); audio?.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    try await Self.verify(writer.outputURL, expectedFrames: writtenFrames, expectsAudio: audio != nil)
    return writer.outputURL
  }
  /// Check tracks and a bounded sample without scanning or buffering the entire take.
  static func verify(_ url: URL, expectedFrames: Int, expectsAudio: Bool) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    guard try await asset.load(.isPlayable), expectedFrames > 0, duration.isFinite, duration > 0 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard let video = videoTracks.first, !expectsAudio || !audioTracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    for track in [video] + (expectsAudio ? Array(audioTracks.prefix(1)) : []) {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
      reader.add(output)
      guard reader.startReading(), output.copyNextSampleBuffer() != nil, reader.status != .failed else {
        throw reader.error ?? CocoaError(.fileReadCorruptFile)
      }
      reader.cancelReading()
    }
  }

}
