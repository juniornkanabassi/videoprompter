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
  /// Left and Right keep one hardware channel (1 or 2) and nothing else. Both is stereo for recording.
  func extract(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard self != .both, source.format.channelCount > 1 else { return source }
    return mono(source)
  }

  /// One mono float buffer for the recogniser: Left or Right alone, Both the average of channels 1 and 2.
  /// Channels 3 and up of a multichannel interface never reach it. Handles float32, int16 and int32,
  /// interleaved or planar, so no format can fall through to an unselected channel.
  func mono(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.format.sampleRate, channels: 1, interleaved: false),
      let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, source.frameLength)),
      let target = result.floatChannelData?[0],
      mix(UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList), source.format.streamDescription.pointee, frames: Int(source.frameLength), into: target)
    else { return nil }
    result.frameLength = source.frameLength
    return result
  }

  /// False when the tap delivers fewer channels than the interface has, so Left or Right cannot be told apart.
  func canIsolate(tapChannels: Int, deviceChannels: Int) -> Bool {
    self == .both || deviceChannels < 2 || tapChannels >= 2
  }

  private func mix(_ list: UnsafeMutableAudioBufferListPointer, _ asbd: AudioStreamBasicDescription, frames: Int, into target: UnsafeMutablePointer<Float>) -> Bool {
    let channels = Int(asbd.mChannelsPerFrame)
    let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let signed = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
    guard asbd.mFormatID == kAudioFormatLinearPCM, channels > 0, list.count >= (planar ? channels : 1),
      (isFloat && asbd.mBitsPerChannel == 32) || (signed && [16, 32].contains(asbd.mBitsPerChannel)) else { return false }
    var picks = self == .both ? [0, 1] : [self == .right ? 1 : 0]
    picks = picks.filter { $0 < channels }
    if picks.isEmpty { picks = [0] }  // a mono source keeps its only channel, whatever was saved
    func sample(_ frame: Int, _ channel: Int) -> Float {
      guard let data = list[planar ? channel : 0].mData else { return 0 }
      let index = planar ? frame : frame * channels + channel
      if isFloat { return data.assumingMemoryBound(to: Float.self)[index] }
      if asbd.mBitsPerChannel == 16 { return Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768 }
      return Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
    }
    for frame in 0..<frames { target[frame] = picks.reduce(0) { $0 + sample(frame, $1) } / Float(picks.count) }
    return true
  }

  func extract(_ source: CMSampleBuffer) -> CMSampleBuffer? {
    guard self != .both else { return source }
    guard let description = CMSampleBufferGetFormatDescription(source) else { return nil }
    guard var stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee, stream.mChannelsPerFrame > 1 else { return source }
    // More than two channels need an explicit layout, or the format cannot be built at all.
    let layout = stream.mChannelsPerFrame > 2 ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | stream.mChannelsPerFrame) : nil
    guard let format = AVAudioFormat(streamDescription: &stream, channelLayout: layout) else { return nil }
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(source))) else { return nil }
    pcm.frameLength = pcm.frameCapacity
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(source, at: 0, frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList) == noErr,
      let selected = mono(pcm) else { return nil }
    var result: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source), decodeTimeStamp: .invalid)
    guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: selected.format.formatDescription, sampleCount: Int(selected.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr,
      let result, CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: selected.audioBufferList) == noErr else { return nil }
    CMSampleBufferSetDataReady(result)
    return result
  }
}
