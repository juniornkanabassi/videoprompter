@preconcurrency import AVFoundation

public enum AudioChannel: String, CaseIterable, Sendable {
  case left = "Left", right = "Right", both = "Both"

  static func load(_ uid: String, defaults: UserDefaults = .standard) -> Self {
    Self(rawValue: (defaults.dictionary(forKey: "microphoneChannels")?[uid] as? String) ?? "") ?? .both
  }
  func save(_ uid: String, defaults: UserDefaults = .standard) {
    var choices = defaults.dictionary(forKey: "microphoneChannels") ?? [:]
    choices[uid] = rawValue
    defaults.set(choices, forKey: "microphoneChannels")
  }
  func extract(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard self != .both, source.format.channelCount > 1 else { return source }
    guard let data = source.floatChannelData,
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.format.sampleRate, channels: 1, interleaved: false),
      let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength),
      let target = result.floatChannelData else { return nil }
    result.frameLength = source.frameLength
    let channel = self == .right ? 1 : 0
    for frame in 0..<Int(source.frameLength) {
      target[0][frame] = source.format.isInterleaved ? data[0][frame * Int(source.format.channelCount) + channel] : data[channel][frame]
    }
    return result
  }

  func extract(_ source: CMSampleBuffer) -> CMSampleBuffer? {
    guard self != .both else { return source }
    guard let description = CMSampleBufferGetFormatDescription(source) else { return nil }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(source))) else { return nil }
    pcm.frameLength = pcm.frameCapacity
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(source, at: 0, frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList) == noErr,
      let selected = extract(pcm) else { return nil }
    var result: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source), decodeTimeStamp: .invalid)
    guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: selected.format.formatDescription, sampleCount: Int(selected.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr,
      let result, CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: selected.audioBufferList) == noErr else { return nil }
    CMSampleBufferSetDataReady(result)
    return result
  }
}
