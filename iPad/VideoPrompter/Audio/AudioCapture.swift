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
  private var converter: AVAudioConverter?
  private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime, Float, Float, Bool) -> Void)?
  private var stopHandler: ((AudioCaptureError?) -> Void)?
  private var gain: Float

  public init(device: AudioInputDevice, outputFormat: AVAudioFormat, gain: Float = 1) {
    selectedDevice = device
    self.outputFormat = outputFormat
    self.gain = max(0, gain)
  }

  public static func requestPermission() async -> Bool {
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
      try session.setActive(true)
    } catch { throw AudioCaptureError.engineFailure(error.localizedDescription) }
    let node = engine.inputNode
    let native = node.outputFormat(forBus: 0)
    guard native.sampleRate > 0, let converter = AVAudioConverter(from: native, to: outputFormat) else {
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
    if let error {
      stop(reason: .engineFailure("The microphone's audio could not be converted. \(error.localizedDescription)"))
      return
    }
    // Normal now and then: the converter keeps a few samples back for the next buffer.
    guard output.frameLength > 0 else { return }
    let currentGain = stateLock.withLock { gain }
    let levels = Self.applyGainAndMeasure(output, gain: currentGain)
    bufferHandler?(output, time, levels.rms, levels.peak, levels.peak >= 0.98)
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
