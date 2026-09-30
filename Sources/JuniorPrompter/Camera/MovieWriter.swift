import AVFoundation

 enum RecordingPreset: String, CaseIterable, Codable, Sendable {
  case standard, high, edit
  var label: String {
    switch self { case .standard: "Standard (H.264)"; case .high: "High (HEVC)"; case .edit: "Edit (ProRes 422)" }
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
  init(url: URL, width: Int, height: Int, transform: CGAffineTransform, preset: RecordingPreset, audio: AudioSpec?, floatAudio: Bool) throws {
    guard !FileManager.default.fileExists(atPath: url.path),
      (try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.type] as? FileAttributeType) == .typeDirectory,
      width > 0, height > 0, audio.map({ $0.sampleRate > 0 && $0.channels > 0 }) ?? true
    else { throw CocoaError(.fileWriteInvalidFileName) }
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
  func append(video buffer: CMSampleBuffer) {
    if !started {
      guard writer.startWriting() else { return }
      firstTime = CMSampleBufferGetPresentationTimeStamp(buffer)
      writer.startSession(atSourceTime: firstTime); started = true
    }
    if video.isReadyForMoreMediaData { if !video.append(buffer) { droppedFrames += 1 } }
    else { droppedFrames += 1 }
  }
  func append(audio buffer: CMSampleBuffer) {
    guard started, CMSampleBufferGetPresentationTimeStamp(buffer) >= firstTime, let audio, audio.isReadyForMoreMediaData else { return }
    _ = audio.append(buffer)
  }
  func finish() async throws -> URL {
    guard started, writer.status == .writing else {
      writer.cancelWriting(); throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
    video.markAsFinished(); audio?.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return writer.outputURL
  }
}
