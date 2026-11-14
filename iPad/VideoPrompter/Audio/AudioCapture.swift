@preconcurrency import AVFoundation
import Foundation

/// The iPad's side of the Mac's AudioCapture: the same names and callbacks, so the shared
/// SessionStore drives either without knowing which. iPadOS routes audio through one shared
/// session, so a "device" here is an input port (built-in, USB-C, Bluetooth or headset).
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
  public var id: String { uid }
  public let uid: String
  public let name: String
  public init(uid: String, name: String) {
    self.uid = uid
    self.name = name
  }
}

public enum AudioCaptureError: Error, Equatable, Sendable, LocalizedError {
  case permissionDenied, deviceUnavailable, conversionUnavailable, deviceLost
  case engineFailure(String)
  public var errorDescription: String? {
    switch self {
    case .permissionDenied: "Microphone permission is required."
    case .deviceUnavailable: "The selected microphone is not connected."
    case .conversionUnavailable: "The microphone's audio format is not supported."
    case .deviceLost: "The selected microphone was disconnected."
    case .engineFailure(let reason): reason
    }
  }
}

public final class AudioCapture: @unchecked Sendable {
  public let selectedDevice: AudioInputDevice
  public let outputFormat: AVAudioFormat
  private let engine = AVAudioEngine()
  private let processingQueue = DispatchQueue(
    label: "VideoPrompter.audio.processing", qos: .userInitiated)
  private let stateLock = NSLock()
  private var running = false
  private var pendingBuffers = 0
  private var observers: [NSObjectProtocol] = []
  private let logsLatency = ProcessInfo.processInfo.environment["VIDEOPROMPTER_AUDIO_LATENCY"] == "1"
  private var converter: AVAudioConverter?
  private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime, Float, Float, Bool) -> Void)?
  private var stopHandler: ((AudioCaptureError?) -> Void)?
  private let channel: AudioChannel
  private var gain: Float

  public init(device: AudioInputDevice, outputFormat: AVAudioFormat, gain: Float = 1, channel: AudioChannel = .both) {
    self.channel = channel
    selectedDevice = device
    self.outputFormat = outputFormat
    self.gain = max(0, gain)
  }

  public static func requestPermission() async -> Bool {
    #if DEBUG && targetEnvironment(simulator)
    if ProcessInfo.processInfo.environment["VP_IPAD_E2E_PORT"] != nil { return false }
    #endif
    if AVAudioApplication.shared.recordPermission == .granted { return true }
    return await AVAudioApplication.requestRecordPermission()
  }

  /// Record-only with Bluetooth allowed, so a headset or wireless lavalier shows up as an input.
  /// Measurement mode turns off the voice processing that would smear the words the recogniser hears.
  static func configureSession() {
    let session = AVAudioSession.sharedInstance()
    guard session.category != .record || session.mode != .measurement else { return }
    try? session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
  }

  public static func inputDevices() -> [AudioInputDevice] {
    configureSession()
    let ports = AVAudioSession.sharedInstance().availableInputs ?? []
    return ports.map { AudioInputDevice(uid: $0.uid, name: $0.portName) }
  }

  /// The built-in microphone when it is there, otherwise whatever iPadOS lists first.
  public static func defaultDevice() -> AudioInputDevice? {
    configureSession()
    let ports = AVAudioSession.sharedInstance().availableInputs ?? []
    let port = ports.first { $0.portType == .builtInMic } ?? ports.first
    return port.map { AudioInputDevice(uid: $0.uid, name: $0.portName) }
  }

  /// The chosen port, or nil when it has gone, so a missing microphone fails safely as on the Mac.
  public static func resolvedInput(_ uid: String?) -> AudioInputDevice? {
    uid.map { selected in inputDevices().first { $0.uid == selected } } ?? defaultDevice()
  }

  public static func inputDeviceObserver(
    onChange: @escaping () -> Void
  ) -> AudioInputDeviceObserver {
    AudioInputDeviceObserver(onChange: onChange)
  }

  public static func decibels(fullScalePeak peak: Float) -> Float {
    guard peak > 0 else { return -.infinity }
    return 20 * log10(peak)
  }

  public func setGain(_ value: Float) { stateLock.withLock { gain = max(0, value) } }

  public func start(
    onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime, Float, Float, Bool) -> Void,
    onStop: @escaping (AudioCaptureError?) -> Void
  ) throws {
    guard AVAudioApplication.shared.recordPermission == .granted else {
      throw AudioCaptureError.permissionDenied
    }
    Self.configureSession()
    let session = AVAudioSession.sharedInstance()
    guard let port = session.availableInputs?.first(where: { $0.uid == selectedDevice.uid }) else {
      throw AudioCaptureError.deviceUnavailable
    }
    do {
      try session.setPreferredInput(port)
      try? session.setPreferredIOBufferDuration(0.005)
      try session.setActive(true)
    } catch { throw AudioCaptureError.engineFailure(error.localizedDescription) }
    // Ask for two input channels when the port has them, then check what really arrived: the session's
    // count and the tap format must both be 2 or more, or Right could silently be a mono or mixed stream.
    let available = session.maximumInputNumberOfChannels
    if channel != .both, available >= 2 { try? session.setPreferredInputNumberOfChannels(min(2, available)) }
    let node = engine.inputNode
    let native = node.outputFormat(forBus: 0)
    guard native.sampleRate > 0 else { throw AudioCaptureError.conversionUnavailable }
    let delivered = min(session.inputNumberOfChannels, Int(native.channelCount))
    guard channel.capturePlan(hardwareChannels: available, tapChannels: delivered) == .useTap else {
      throw AudioCaptureError.engineFailure(channel.separateChannelsMessage)
    }
    if logsLatency {
      NSLog("Voice input: rate=%.0f Hz requestedFrames=256 voiceProcessing=%d", native.sampleRate, node.isVoiceProcessingEnabled ? 1 : 0)
      NSLog("Voice session: category=%@ mode=%@ ioBuffer=%.3f ms inputLatency=%.3f ms", session.category.rawValue, session.mode.rawValue, session.ioBufferDuration * 1000, session.inputLatency * 1000)
    }
    try prepareConverter(sampleRate: native.sampleRate)
    bufferHandler = onBuffer
    stopHandler = onStop
    stateLock.withLock {
      running = true
      pendingBuffers = 0
    }
    node.installTap(onBus: 0, bufferSize: 256, format: native) { [weak self] buffer, time in
      self?.enqueue(buffer, time: time)
    }
    do { try engine.start() } catch {
      stateLock.withLock { running = false }
      node.removeTap(onBus: 0)
      engine.stop()
      processingQueue.sync {
        self.converter = nil
        self.bufferHandler = nil
        self.stopHandler = nil
      }
      throw AudioCaptureError.engineFailure(error.localizedDescription)
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in self?.checkRoute() })
    observers.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
    ) { [weak self] _ in self?.checkRoute() })
    // A phone or FaceTime call takes the microphone; the session pauses rather than going deaf.
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
    ) { [weak self] note in
      guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
      self?.stop(reason: .engineFailure("Another app took the microphone"))
    })
  }

  private func checkRoute() {
    let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
    guard inputs.contains(where: { $0.uid == selectedDevice.uid }) else {
      stop(reason: .deviceLost)
      return
    }
    if !engine.isRunning {
      stop(reason: .engineFailure("Audio engine stopped after configuration change"))
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
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
      // Preserve the previous nominal 85 ms processing allowance with 256-frame taps.
      guard running, pendingBuffers < 16 else { return false }
      pendingBuffers += 1
      return true
    }
    guard accepted, let copy = Self.deepCopy(source) else {
      if accepted { stateLock.withLock { pendingBuffers -= 1 } }
      return
    }
    let arrived = logsLatency ? ProcessInfo.processInfo.systemUptime : 0
    processingQueue.async { [weak self] in
      defer { self?.stateLock.withLock { self?.pendingBuffers -= 1 } }
      if self?.logsLatency == true {
        NSLog("Voice capture: frames=%d duration=%.3f ms queue=%.3f ms", copy.frameLength,
          Double(copy.frameLength) / copy.format.sampleRate * 1000,
          (ProcessInfo.processInfo.systemUptime - arrived) * 1000)
      }
      self?.convertAndDeliver(copy, time: time)
    }
  }

  /// Every consumer downstream gets the chosen channel as mono float, so the converter always starts from it.
  func prepareConverter(sampleRate: Double) throws {
    guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: mono, to: outputFormat) else { throw AudioCaptureError.conversionUnavailable }
    self.converter = converter
  }

  private func convertAndDeliver(_ input: AVAudioPCMBuffer, time: AVAudioTime) {
    let started = logsLatency ? ProcessInfo.processInfo.systemUptime : 0
    guard stateLock.withLock({ running }), let result = process(input) else { return }
    if logsLatency {
      NSLog("Voice conversion: frames=%d rate=%.0f Hz work=%.3f ms", result.buffer.frameLength,
        outputFormat.sampleRate, (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
    bufferHandler?(result.buffer, time, result.rms, result.peak, result.peak >= 0.98)
  }

  /// Chosen channel, then rate conversion, gain and the meter reading, in that order.
  func process(_ input: AVAudioPCMBuffer) -> (buffer: AVAudioPCMBuffer, rms: Float, peak: Float)? {
    guard let source = channel.mono(input), let converter else { return nil }
    let capacity =
      AVAudioFrameCount(
        ceil(Double(source.frameLength) * outputFormat.sampleRate / source.format.sampleRate)) + 2
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return nil
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
    if let error {
      stop(reason: .engineFailure("The microphone's audio could not be converted. \(error.localizedDescription)"))
      return nil
    }
    // Normal now and then: the converter keeps a few samples back for the next buffer.
    guard output.frameLength > 0 else { return nil }
    let currentGain = stateLock.withLock { gain }
    let levels = Self.applyGainAndMeasure(output, gain: currentGain)
    return (output, levels.rms, levels.peak)
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

  static func applyGainAndMeasure(_ buffer: AVAudioPCMBuffer, gain: Float) -> (
    rms: Float, peak: Float
  ) {
    var sum: Double = 0
    var peak: Float = 0
    var count = 0
    let planes = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
    let samplesPerPlane = Int(buffer.frameLength) * (buffer.format.isInterleaved
      ? Int(buffer.format.channelCount) : 1)
    if let channels = buffer.floatChannelData {
      for channel in 0..<planes {
        for sample in 0..<samplesPerPlane {
          let value = channels[channel][sample] * gain
          channels[channel][sample] = value
          sum += Double(value * value)
          peak = max(peak, abs(value))
          count += 1
        }
      }
    } else if let channels = buffer.int16ChannelData {
      for channel in 0..<planes {
        for sample in 0..<samplesPerPlane {
          let scaled = Float(channels[channel][sample]) * gain
          let clamped = max(Float(Int16.min), min(Float(Int16.max), scaled))
          channels[channel][sample] = Int16(clamped)
          let normal = clamped / Float(Int16.max)
          sum += Double(normal * normal)
          peak = max(peak, abs(normal))
          count += 1
        }
      }
    }
    return (Float(sqrt(sum / Double(max(1, count)))), peak)
  }

  deinit { stop() }
}

private final class InputSupply: @unchecked Sendable { var supplied = false }

/// Fires when a microphone is plugged in or taken away.
public final class AudioInputDeviceObserver: @unchecked Sendable {
  private var token: NSObjectProtocol?

  fileprivate init(onChange: @escaping () -> Void) {
    // Delivered on the main queue, where the session that passed `onChange` lives.
    nonisolated(unsafe) let onChange = onChange
    token = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { _ in onChange() }
  }

  deinit {
    if let token { NotificationCenter.default.removeObserver(token) }
  }
}
