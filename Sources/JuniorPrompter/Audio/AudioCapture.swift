@preconcurrency import AVFoundation
import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
  public let id: AudioDeviceID
  public let uid: String
  public let name: String
  public init(id: AudioDeviceID, uid: String, name: String) {
    self.id = id
    self.uid = uid
    self.name = name
  }
}

public enum AudioCaptureError: Error, Equatable, Sendable {
  case permissionDenied, deviceUnavailable, conversionUnavailable, deviceLost
  case engineFailure(String)
}

public final class AudioCapture: @unchecked Sendable {
  public let selectedDevice: AudioInputDevice
  public let outputFormat: AVAudioFormat
  private let engine = AVAudioEngine()
  private let processingQueue = DispatchQueue(
    label: "JuniorPrompter.audio.processing", qos: .userInitiated)
  private let stateLock = NSLock()
  private var running = false
  private var pendingBuffers = 0
  private var observer: NSObjectProtocol?
  private var converter: AVAudioConverter?
  private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime, Float, Bool) -> Void)?
  private var stopHandler: ((AudioCaptureError?) -> Void)?
  private var gain: Float

  public init(device: AudioInputDevice, outputFormat: AVAudioFormat, gain: Float = 1) {
    selectedDevice = device
    self.outputFormat = outputFormat
    self.gain = max(0, gain)
  }

  public static func requestPermission() async -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    return await AVCaptureDevice.requestAccess(for: .audio)
  }

  public static func inputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var byteCount: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr
    else { return [] }
    var ids = Array(
      repeating: AudioDeviceID(0), count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &ids) == noErr
    else { return [] }
    return ids.compactMap { id in
      var streams = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
      var streamBytes: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamBytes) == noErr,
        streamBytes > 0,
        let uid = deviceString(id, selector: kAudioDevicePropertyDeviceUID)
      else { return nil }
      return AudioInputDevice(
        id: id, uid: uid, name: deviceString(id, selector: kAudioObjectPropertyName) ?? uid)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func setGain(_ value: Float) { stateLock.withLock { gain = max(0, value) } }

  public func start(
    onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime, Float, Bool) -> Void,
    onStop: @escaping (AudioCaptureError?) -> Void
  ) throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw AudioCaptureError.permissionDenied
    }
    guard Self.inputDevices().contains(where: { $0.uid == selectedDevice.uid }) else {
      throw AudioCaptureError.deviceUnavailable
    }
    let node = engine.inputNode
    var id = selectedDevice.id
    guard let unit = node.audioUnit,
      AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
        UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    else { throw AudioCaptureError.deviceUnavailable }
    let native = node.outputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: native, to: outputFormat) else {
      throw AudioCaptureError.conversionUnavailable
    }
    self.converter = converter
    bufferHandler = onBuffer
    stopHandler = onStop
    stateLock.withLock {
      running = true
      pendingBuffers = 0
    }
    node.installTap(onBus: 0, bufferSize: 1024, format: native) { [weak self] buffer, time in
      self?.enqueue(buffer, time: time)
    }
    do { try engine.start() } catch {
      stateLock.withLock { running = false }
      node.removeTap(onBus: 0)
      engine.stop()
      self.converter = nil
      bufferHandler = nil
      stopHandler = nil
      throw AudioCaptureError.engineFailure(error.localizedDescription)
    }
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      guard let self, !Self.inputDevices().contains(where: { $0.uid == self.selectedDevice.uid })
      else { return }
      self.stop(reason: .deviceLost)
    }
  }

  public func stop(reason: AudioCaptureError? = nil) {
    let shouldStop = stateLock.withLock { () -> Bool in
      let value = running
      running = false
      return value
    }
    guard shouldStop else { return }
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    processingQueue.async { [weak self] in
      guard let self else { return }
      let callback = self.stopHandler
      self.stopHandler = nil
      self.bufferHandler = nil
      self.converter = nil
      callback?(reason)
    }
  }

  private func enqueue(_ source: AVAudioPCMBuffer, time: AVAudioTime) {
    let accepted = stateLock.withLock { () -> Bool in
      guard running, pendingBuffers < 4 else { return false }
      pendingBuffers += 1
      return true
    }
    guard accepted, let copy = Self.deepCopy(source) else {
      if accepted { stateLock.withLock { pendingBuffers -= 1 } }
      return
    }
    processingQueue.async { [weak self] in
      defer { self?.stateLock.withLock { self?.pendingBuffers -= 1 } }
      self?.convertAndDeliver(copy, time: time)
    }
  }

  private func convertAndDeliver(_ source: AVAudioPCMBuffer, time: AVAudioTime) {
    guard stateLock.withLock({ running }), let converter else { return }
    let capacity =
      AVAudioFrameCount(
        ceil(Double(source.frameLength) * outputFormat.sampleRate / source.format.sampleRate)) + 2
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return
    }
    let supply = InputSupply()
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supply.supplied {
        status.pointee = .noDataNow
        return nil
      }
      supply.supplied = true
      status.pointee = .haveData
      return source
    }
    guard error == nil, output.frameLength > 0 else { return }
    let currentGain = stateLock.withLock { gain }
    let levels = Self.applyGainAndMeasure(output, gain: currentGain)
    bufferHandler?(output, time, levels.rms, levels.peak >= 0.98)
  }

  private static func deepCopy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
    else { return nil }
    copy.frameLength = source.frameLength
    let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let targetList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in 0..<min(sourceList.count, targetList.count) {
      if let sourceData = sourceList[index].mData, let targetData = targetList[index].mData {
        memcpy(targetData, sourceData, Int(sourceList[index].mDataByteSize))
        targetList[index].mDataByteSize = sourceList[index].mDataByteSize
      }
    }
    return copy
  }

  private static func applyGainAndMeasure(_ buffer: AVAudioPCMBuffer, gain: Float) -> (
    rms: Float, peak: Float
  ) {
    var sum: Double = 0
    var peak: Float = 0
    var count = 0
    if let channels = buffer.floatChannelData {
      for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
          let value = channels[channel][frame] * gain
          channels[channel][frame] = value
          sum += Double(value * value)
          peak = max(peak, abs(value))
          count += 1
        }
      }
    } else if let channels = buffer.int16ChannelData {
      for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
          let scaled = Float(channels[channel][frame]) * gain
          let clamped = max(Float(Int16.min), min(Float(Int16.max), scaled))
          channels[channel][frame] = Int16(clamped)
          let normal = clamped / Float(Int16.max)
          sum += Double(normal * normal)
          peak = max(peak, abs(normal))
          count += 1
        }
      }
    }
    return (Float(sqrt(sum / Double(max(1, count)))), peak)
  }

  private static func deviceString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value?.takeUnretainedValue() as String?
  }

  deinit { stop() }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

private final class InputSupply: @unchecked Sendable { var supplied = false }
