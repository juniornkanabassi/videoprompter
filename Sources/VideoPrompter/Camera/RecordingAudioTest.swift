@preconcurrency import AVFoundation

/// Uses the recording capture API and channel layout, without creating a file or playing sound.
final class RecordingAudioTest: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "VideoPrompter.recording-input-test")
  private let onLevels: @Sendable ([Float]) -> Void

  init(device: AVCaptureDevice, floatAudio: Bool, onLevels: @escaping @Sendable ([Float]) -> Void) throws {
    self.onLevels = onLevels
    super.init()
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureAudioDataOutput()
    let format = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
    output.audioSettings = Self.settings(sampleRate: (floatAudio ? (format?.mSampleRate ?? 48000) : min(format?.mSampleRate ?? 48000, 48000)), channels: min(Int(format?.mChannelsPerFrame ?? 2), 2))
    guard session.canAddInput(input), session.canAddOutput(output) else {
      throw NSError(domain: "RecordingAudioTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "This microphone cannot be tested. Choose another recording microphone and try again."])
    }
    session.addInput(input); session.addOutput(output)
    output.setSampleBufferDelegate(self, queue: queue)
  }
  func start() async {
    await withCheckedContinuation { continuation in
      queue.async { self.session.startRunning(); continuation.resume() }
    }
  }
  func stop() async {
    await withCheckedContinuation { continuation in
      queue.async { self.session.stopRunning(); continuation.resume() }
    }
  }
  static func settings(sampleRate: Double, channels: Int) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
     AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
  }
  static func channelPeaks(in buffer: CMSampleBuffer) -> [Float] {
    guard let format = CMSampleBufferGetFormatDescription(buffer),
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
      let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
    let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
    var samples = [Float](repeating: 0, count: count)
    let result = samples.withUnsafeMutableBytes { bytes in
      guard let pointer = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
      return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: pointer)
    }
    guard result == kCMBlockBufferNoErr else { return [] }
    return channelPeaks(samples: samples, channels: Int(description.pointee.mChannelsPerFrame))
  }
  static func channelPeaks(samples: [Float], channels: Int) -> [Float] {
    guard channels > 0 else { return [] }
    var peaks = [Float](repeating: 0, count: channels)
    for (index, sample) in samples.enumerated() where sample.isFinite {
      peaks[index % channels] = max(peaks[index % channels], abs(sample))
    }
    return peaks
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    onLevels(Self.channelPeaks(in: buffer))
  }
}
