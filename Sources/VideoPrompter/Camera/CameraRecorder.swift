@preconcurrency import AVFoundation
import Combine
import AppKit
import PrompterCore

@MainActor final class CameraRecorder: ObservableObject {
  static let shared = CameraRecorder(defaults: AppStore.preferences())
  enum Phase: String {
    case idle, preparing, waitingForFrames, recording, saving
    var message: String {
      switch self {
      case .idle: "Ready to record"
      case .preparing: "Preparing camera and microphone…"
      case .waitingForFrames: "Waiting for the first camera frame…"
      case .recording: "Recording started"
      case .saving: "Saving recording…"
      }
    }
  }
  // Internal so offscreen fixtures can exercise every lifecycle without opening hardware.
  @Published var phase = Phase.idle {
    didSet { if phase != oldValue && phase != .idle { announce(phase.message) } }
  }
  var isRecording: Bool { phase == .recording }
  var isBusy: Bool { phase == .preparing || phase == .waitingForFrames || phase == .saving }
  var isCapturing: Bool { phase == .waitingForFrames || phase == .recording }
  @Published private var storedMirrorSavedVideo: Bool
  var mirrorSavedVideo: Bool {
    get { storedMirrorSavedVideo }
    set {
      guard !settingsLocked, newValue != storedMirrorSavedVideo else { return }

      storedMirrorSavedVideo = newValue
      defaults.set(newValue, forKey: "mirrorSavedVideo")
    }
  }
  @Published private(set) var isTestingInput = false
  private var inputTest: RecordingAudioTest?
  private var inputTestStop: Task<Void, Never>?
  private var testGeneration = UUID()
  @Published private(set) var recordedDuration: TimeInterval = 0
  @Published private(set) var startedAt: Date?
  private(set) var recordingID: UUID?
  @Published private(set) var lastFile: URL?
  /// Receipt belongs to the latest attempt, never to an older successful take.
  @Published var savedTake: URL?
  @Published private(set) var takeFailure: String?
  @Published private(set) var incompleteTake: URL?
  enum Recovery: Equatable { case cameraPrivacy, microphonePrivacy, camera, microphone, storage, format, retry }
  @Published private(set) var recovery = Recovery.retry
  @Published var errorMessage: String? {
    didSet {
      if let errorMessage, errorMessage != oldValue {
        if isCapturing || isBusy { takeFailure = errorMessage }
        announce(errorMessage, priority: .high)
      }
    }
  }
  @Published private var storedPreset: RecordingPreset
  var preset: RecordingPreset {
    get { storedPreset }
    set {
      guard !settingsLocked, newValue != storedPreset else { return }

      storedPreset = newValue
      defaults.set(newValue.rawValue, forKey: "recordingPreset")
    }
  }
  @Published private var storedFloatAudio: Bool
  var floatAudio: Bool {
    get { storedFloatAudio }
    set {
      guard !settingsLocked, newValue != storedFloatAudio else { return }
      stopInputTest()
      storedFloatAudio = newValue
      defaults.set(newValue, forKey: "recordingFloatAudio")
    }
  }
  @Published private var storedTakeLabel = ""
  var takeLabel: String {
    get { storedTakeLabel }
    set { if !settingsLocked { storedTakeLabel = newValue } }
  }
  @Published private var storedMicrophoneUID: String?
  var microphoneUID: String? {
    get { storedMicrophoneUID }
    set {
      guard !settingsLocked, newValue != storedMicrophoneUID else { return }
      stopInputTest()
      storedMicrophoneUID = newValue
      defaults.set(newValue, forKey: "recordingMicrophoneUID")
    }
  }
  var settingsLocked: Bool { isRecording || isBusy }
  @Published private var storedUsesSeparateMicrophone: Bool
  var usesSeparateMicrophone: Bool {
    get { storedUsesSeparateMicrophone }
    set {
      guard !settingsLocked else { return }
      storedUsesSeparateMicrophone = newValue
      defaults.set(newValue, forKey: "recordingUsesSeparateMicrophone")
    }
  }
  var followingMicrophoneUID: String?
  var resolvedMicrophoneUID: String? { usesSeparateMicrophone ? microphoneUID : followingMicrophoneUID }
  func useSettings(_ settings: PrompterSettings) {
    // A separate recording input stays locked, while the Voice choice remains editable.
    if !settingsLocked || usesSeparateMicrophone { followingMicrophoneUID = settings.audioDeviceUID }
  }
  private let defaults: UserDefaults
  private var sink: RecordingSink?
  private var cancelStart = false
  private var stopTask: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var lastFrameAt: Date?
  @Published var droppedFrames = 0
  @Published var droppedAudioBuffers = 0 {
    didSet {
      if oldValue == 0 && droppedAudioBuffers > 0 { announce("Sound dropped from the file", priority: .high) }
    }
  }
  @Published private(set) var activeMicrophoneName: String?
  @Published private(set) var audioChannels = 0
  let inputMeter = InputMeter()
  private var observers: [NSObjectProtocol] = []
  init(defaults: UserDefaults = .standard, followingMicrophoneUID: String? = nil) {
    self.defaults = defaults
    self.followingMicrophoneUID = followingMicrophoneUID ?? defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(PrompterSettings.self, from: $0).audioDeviceUID }
    if let saved = defaults.object(forKey: "recordingUsesSeparateMicrophone") as? Bool { storedUsesSeparateMicrophone = saved }
    else {
      let recording = defaults.string(forKey: "recordingMicrophoneUID")
      let following = followingMicrophoneUID ?? defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(PrompterSettings.self, from: $0).audioDeviceUID }
      let separate = recording != nil && recording != following
      storedUsesSeparateMicrophone = separate
      defaults.set(separate, forKey: "recordingUsesSeparateMicrophone")
    }
    storedPreset = defaults.string(forKey: "recordingPreset").flatMap(RecordingPreset.init) ?? .standard
    storedFloatAudio = defaults.bool(forKey: "recordingFloatAudio")
    storedMicrophoneUID = defaults.string(forKey: "recordingMicrophoneUID")
    storedMirrorSavedVideo = defaults.bool(forKey: "mirrorSavedVideo")
    if let path = defaults.string(forKey: "lastRecording"), FileManager.default.fileExists(atPath: path) { lastFile = URL(fileURLWithPath: path) }
  }
  static func recordingsFolder(arguments: [String] = CommandLine.arguments,
                               movies: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]) -> URL {
    if let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count { return URL(fileURLWithPath: arguments[i + 1]).appendingPathComponent("Recordings") }
    return ControlProtocol.migrateLegacyFolder(in: movies)
  }
  static func fileURL(in folder: URL, date: Date = Date(), label: String = "") -> URL {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    let stamp = " " + formatter.string(from: date)
    var url = folder.appendingPathComponent(InputValidation.filename(label, fallback: "Video Prompter", suffix: stamp + ".mov", separator: " "))
    var number = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent(InputValidation.filename(label, fallback: "Video Prompter", suffix: stamp + " \(number).mov", separator: " "))
      number += 1
    }
    return url
  }
  func openRecordingsFolder() {
    let folder = Self.recordingsFolder()
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      if !NSWorkspace.shared.open(folder) { errorMessage = "Could not open the recordings folder. In Finder, choose Go > Go to Folder and enter \(folder.path)." }
    } catch { errorMessage = "The recordings folder is unavailable. Check free space and folder permissions, then try again." }
  }
  static func hasRecordingSpace(_ bytes: Int64) -> Bool { bytes >= 2_000_000_000 }
  static func microphones() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
  }
  var microphoneName: String {
    if isRecording || isBusy, let activeMicrophoneName { return activeMicrophoneName }
    if let uid = resolvedMicrophoneUID { return Self.microphones().first { $0.uniqueID == uid }?.localizedName ?? "Selected microphone unavailable" }
    return AVCaptureDevice.default(for: .audio)?.localizedName ?? "No microphone"
  }
  static func framesTimedOut(attachedAt: Date, lastFrameAt: Date?, now: Date) -> Bool {
    now.timeIntervalSince(lastFrameAt ?? attachedAt) > 5
  }
  func start(camera: CameraModel) async {
    guard !isBusy, !isRecording else { return }
    stopInputTest()
    phase = .preparing; cancelStart = false; errorMessage = nil; savedTake = nil; takeFailure = nil; incompleteTake = nil
    recordingID = UUID()
    let takeID = recordingID
    recordedDuration = 0; droppedFrames = 0; droppedAudioBuffers = 0; inputMeter.reset(); lastFrameAt = nil
    activeMicrophoneName = nil; audioChannels = 0
    defer { if !isCapturing { phase = .idle; recordingID = nil } }
    do {
      await inputTestStop?.value
      guard !cancelStart else { return }
      guard let uid = camera.selectedUID, AVCaptureDevice(uniqueID: uid) != nil else { throw recordingError("Choose an available camera first.", recovery: .camera) }
      _ = await CaptureAccess.request(.video)
      guard !cancelStart else { return }
      guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw recordingError("Allow camera access in System Settings > Privacy & Security > Camera before recording.", recovery: .cameraPrivacy) }
      _ = await CaptureAccess.request(.audio)
      guard !cancelStart else { return }
      guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw recordingError("Allow microphone access in System Settings > Privacy & Security > Microphone before recording.", recovery: .microphonePrivacy) }
      let devices = Self.microphones()
      let microphone = resolvedMicrophoneUID.flatMap { id in devices.first { $0.uniqueID == id } } ?? (resolvedMicrophoneUID == nil ? AVCaptureDevice.default(for: .audio) : nil)
      guard let microphone else { throw recordingError("The selected microphone is unavailable. Open Microphone settings and choose another microphone.", recovery: .microphone) }
      recovery = .storage
      let folder = Self.recordingsFolder()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
      guard Self.hasRecordingSpace(free) else { throw recordingError("Free at least 2 GB on the recording drive, then try Record again.", recovery: .storage) }
      activeMicrophoneName = microphone.localizedName
      recovery = .microphone
      let input = try AVCaptureDeviceInput(device: microphone)
      let format = CMAudioFormatDescriptionGetStreamBasicDescription(microphone.activeFormat.formatDescription)?.pointee
      let spec = AudioSpec(sampleRate: floatAudio ? (format?.mSampleRate ?? 48000) : min(format?.mSampleRate ?? 48000, 48000), channels: min(Int(format?.mChannelsPerFrame ?? 2), 2))
      audioChannels = spec.channels
      let sink = RecordingSink(url: Self.fileURL(in: folder, label: takeLabel), preset: preset, rotation: camera.guides.rotation, mirrored: mirrorSavedVideo, audio: spec, floatAudio: floatAudio, microphone: input, onFrame: { [weak self] duration in
        Task { @MainActor in
          guard let self, self.recordingID == takeID, self.isCapturing else { return }
          if self.startedAt == nil { self.startedAt = Date(); self.phase = .recording }
          self.recordedDuration = duration
          self.lastFrameAt = Date()
        }
      }, onAudio: { [weak self] levels in
        Task { @MainActor in
          guard let self, self.recordingID == takeID, self.isCapturing else { return }
          self.inputMeter.show(channelPeaks: levels)
        }
      }, onVideoDrop: { [weak self] count in
        Task { @MainActor in
          guard let self, self.recordingID == takeID else { return }
          self.droppedFrames = count
        }
      }, onAudioDrop: { [weak self] count in
        Task { @MainActor in
          guard let self, self.recordingID == takeID else { return }
          self.droppedAudioBuffers = count
        }
      }) { [weak self] error in
        Task { @MainActor [weak self] in
          guard let self, self.isCapturing else { return }
          self.recovery = Self.recovery(for: error)
          self.errorMessage = "Recording stopped. The take could not be completed. " + Self.recoveryMessage(for: error)
          await self.stop()
        }
      }
      let shared = SharedCameraSession.shared
      shared.select(uid)
      shared.retain()
      let attached = await withCheckedContinuation { continuation in
        shared.reconfigure { session in
          session.beginConfiguration()
          var success = false
          let cameraAttached = session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == uid }
          if cameraAttached, session.canAddInput(input) {
            session.addInput(input)
            if session.canAddOutput(sink.video), session.canAddOutput(sink.audio) {
              session.addOutput(sink.video); session.addOutput(sink.audio); success = true
            } else { session.removeInput(input) }
          }
          session.commitConfiguration(); continuation.resume(returning: success)
        }
      }
      guard attached else { shared.release(); throw recordingError("This camera cannot start recording. Choose another camera or close other apps using it, then try again.", recovery: .camera) }
      self.sink = sink; phase = .waitingForFrames
      if cancelStart || camera.selectedUID != uid { await stop(); return }
      let attachedAt = Date()
      watchdog = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, let self, self.isCapturing else { return }
          if Self.framesTimedOut(attachedAt: attachedAt, lastFrameAt: self.lastFrameAt, now: Date()) {
            self.recovery = .camera
            self.errorMessage = "No camera frames received for 5 seconds. Check the camera connection and try again."
            await self.stop()
            return
          }
        }
      }
      for name in [AVCaptureDevice.wasDisconnectedNotification, AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
          let lostUID = (notification.object as? AVCaptureDevice)?.uniqueID
          Task { @MainActor [weak self] in
            guard let self, self.isCapturing, lostUID == nil || lostUID == uid || lostUID == microphone.uniqueID else { return }
            self.recovery = lostUID == microphone.uniqueID ? .microphone : .camera
            self.errorMessage = "A recording device disconnected or capture was interrupted. Recording was stopped."
            await self.stop()
          }
        })
      }
    } catch {
      errorMessage = Self.recoveryMessage(for: error)
      takeFailure = errorMessage
    }
  }
  func stop() async {
    if let stopTask { await stopTask.value; return }
    guard let sink else {
      if isBusy {
        cancelStart = true
        while isBusy { try? await Task.sleep(for: .milliseconds(20)) }
      }
      return
    }
    watchdog?.cancel(); watchdog = nil
    phase = .saving
    let task = Task { @MainActor [self] in
      for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
      let shared = SharedCameraSession.shared
      await withCheckedContinuation { continuation in
        shared.reconfigure { session in
          sink.video.setSampleBufferDelegate(nil, queue: nil)
          sink.audio.setSampleBufferDelegate(nil, queue: nil)
          session.beginConfiguration()
          if session.outputs.contains(sink.video) { session.removeOutput(sink.video) }
          if session.outputs.contains(sink.audio) { session.removeOutput(sink.audio) }
          if session.inputs.contains(sink.microphone) { session.removeInput(sink.microphone) }
          session.commitConfiguration(); continuation.resume()
        }
      }
      do {
        let result = try await sink.finish()
        lastFile = result.0; savedTake = result.0
        defaults.set(result.0.path, forKey: "lastRecording")
        droppedFrames = result.1
        droppedAudioBuffers = result.2
        announce("Saved \(result.0.lastPathComponent)" + (result.1 > 0 ? ". \(result.1) video frames were dropped." : ""))
      } catch {
        recovery = Self.recovery(for: error)
        incompleteTake = FileManager.default.fileExists(atPath: sink.fileURL.path) ? sink.fileURL : nil
        errorMessage = "No completed take was saved. " + Self.recoveryMessage(for: error)
      }
      if let errorMessage { takeFailure = errorMessage }

      shared.release(); self.sink = nil; startedAt = nil; recordingID = nil; phase = .idle
      announce("Recording stopped")
    }
    stopTask = task; await task.value; stopTask = nil
  }
  static func recoveryMessage(for error: Error) -> String {
    let detail = error as NSError
    NSLog("Recording failure: %@", detail.localizedDescription)
    if detail.domain == "CameraRecorder", detail.code == 1 { return detail.localizedDescription }
    return switch recovery(for: error) {
    case .cameraPrivacy: "Allow camera access in System Settings, then try again."
    case .microphonePrivacy: "Allow microphone access in System Settings, then try again."
    case .camera: "Reconnect or choose another camera, then try again."
    case .microphone: "Reconnect or choose another microphone, then try again."
    case .storage: "Check free space and access to the Recordings folder, then try again."
    case .format: "Choose another recording format, then try again."
    case .retry: "Check the camera and microphone, then try recording again."
    }
  }
  var qualityWarning: String? {
    var parts: [String] = []
    if let takeFailure { parts.append(takeFailure) }
    if droppedFrames > 0 { parts.append("Video frames dropped (\(droppedFrames)). The picture may stutter.") }
    if droppedAudioBuffers > 0 { parts.append("Sound dropped from the file (\(droppedAudioBuffers) times).") }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  func startInputTest() async {
    guard !isRecording, !isBusy, !isTestingInput else { return }
    testGeneration = UUID()
    let generation = testGeneration
    isTestingInput = true; inputMeter.reset(); errorMessage = nil
    await inputTestStop?.value
    guard generation == testGeneration else { return }
    guard await AudioCapture.requestPermission(), generation == testGeneration else {
      if generation == testGeneration { isTestingInput = false; recovery = .microphonePrivacy; errorMessage = "Allow microphone access in System Settings > Privacy & Security > Microphone, then test again." }
      return
    }
    do {
      let device = resolvedMicrophoneUID.flatMap { id in Self.microphones().first { $0.uniqueID == id } }
        ?? (resolvedMicrophoneUID == nil ? AVCaptureDevice.default(for: .audio) : nil)
      guard let device else { throw recordingError("Open Microphone settings and choose an available microphone.", recovery: .microphone) }
      let test = try RecordingAudioTest(device: device, floatAudio: floatAudio) { [weak self] levels in
        Task { @MainActor in
          guard let self, self.testGeneration == generation, self.isTestingInput else { return }
          self.inputMeter.show(channelPeaks: levels)
        }
      }
      inputTest = test
      await test.start()
      if generation != testGeneration { await test.stop() }
    } catch { if generation == testGeneration { stopInputTest(); errorMessage = Self.recoveryMessage(for: error) } }
  }
  func stopInputTest() {
    testGeneration = UUID(); isTestingInput = false
    if !isRecording && !isBusy { inputMeter.reset() }
    if let test = inputTest { inputTestStop = Task { await test.stop() } }
    inputTest = nil
  }
  private func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: priority.rawValue])
  }
  static func recovery(for error: Error) -> Recovery {
    let error = error as NSError
    if error.domain == "CameraRecorder", error.code == 2 { return .camera }
    if error.domain == "MovieWriter", error.code == 1 { return .microphone }
    if error.domain == NSCocoaErrorDomain {
      if error.code == CocoaError.featureUnsupported.rawValue { return .format }
      if (512...640).contains(error.code) { return .storage }
    }
    return .retry
  }

  private func recordingError(_ message: String, recovery: Recovery = .retry) -> NSError {
    self.recovery = recovery
    return NSError(domain: "CameraRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

/// AVFoundation delegate callbacks and the writer belong exclusively to queue.
final class RecordingSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  let video = AVCaptureVideoDataOutput()
  let audio = AVCaptureAudioDataOutput()
  let microphone: AVCaptureDeviceInput
  private let queue = DispatchQueue(label: "VideoPrompter.recording")
  private let url: URL
  var fileURL: URL { url }
  private let preset: RecordingPreset
  private let rotation: CameraRotation
  private let mirrored: Bool
  private let onFrame: @Sendable (TimeInterval) -> Void
  private let onAudio: @Sendable ([Float]) -> Void
  private let onAudioDrop: @Sendable (Int) -> Void
  private let onVideoDrop: @Sendable (Int) -> Void
  private var captureVideoDrops = 0
  private var earlyAudioDrops = 0
  private var firstFrame: CMTime?
  private let spec: AudioSpec
  private let floatAudio: Bool
  private let onFailure: @Sendable (Error) -> Void
  private var writer: MovieWriter?
  private var failure: Error?
  init(url: URL, preset: RecordingPreset, rotation: CameraRotation, mirrored: Bool, audio: AudioSpec, floatAudio: Bool, microphone: AVCaptureDeviceInput, onFrame: @escaping @Sendable (TimeInterval) -> Void, onAudio: @escaping @Sendable ([Float]) -> Void, onVideoDrop: @escaping @Sendable (Int) -> Void = { _ in }, onAudioDrop: @escaping @Sendable (Int) -> Void = { _ in }, onFailure: @escaping @Sendable (Error) -> Void) {
    self.url = url; self.preset = preset; self.rotation = rotation; self.mirrored = mirrored; self.onFrame = onFrame; self.onAudio = onAudio; spec = audio; self.floatAudio = floatAudio; self.microphone = microphone; self.onFailure = onFailure; self.onAudioDrop = onAudioDrop; self.onVideoDrop = onVideoDrop
    super.init()
    video.alwaysDiscardsLateVideoFrames = false
    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: preset == .edit ? kCVPixelFormatType_422YpCbCr8 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    self.audio.audioSettings = RecordingAudioTest.settings(sampleRate: audio.sampleRate, channels: audio.channels)
    video.setSampleBufferDelegate(self, queue: queue); self.audio.setSampleBufferDelegate(self, queue: queue)
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard failure == nil else { return }
    do {
      if output === video {
        if writer == nil {
          guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
          let dimensions = CMVideoFormatDescriptionGetDimensions(format)
          writer = try MovieWriter(url: url, width: Int(dimensions.width), height: Int(dimensions.height), transform: Self.recordingTransform(rotation: rotation, mirrored: mirrored), preset: preset, audio: spec, floatAudio: floatAudio)
        }
        if try writer?.append(video: sampleBuffer) == true {
          let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          if firstFrame == nil { firstFrame = time }
          onFrame(max(0, (time - firstFrame!).seconds))
        }
        onVideoDrop(captureVideoDrops + (writer?.droppedFrames ?? 0))
      } else {
        onAudio(RecordingAudioTest.channelPeaks(in: sampleBuffer))
        if let writer { try writer.append(audio: sampleBuffer) } else { earlyAudioDrops += 1 }
        onAudioDrop(earlyAudioDrops + (writer?.droppedAudioBuffers ?? 0))
      }
    } catch { failure = error; onFailure(error) }
  }
  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if output === video {
      captureVideoDrops += 1
      onVideoDrop(captureVideoDrops + (writer?.droppedFrames ?? 0))
      return
    }
    guard output === audio else { return }
    earlyAudioDrops += 1
    onAudioDrop(earlyAudioDrops + (writer?.droppedAudioBuffers ?? 0))
  }
  static func recordingTransform(rotation: CameraRotation, mirrored: Bool) -> CGAffineTransform {
    CGAffineTransform(rotationAngle: rotation.radians).concatenating(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
  }
  func finish() async throws -> (URL, Int, Int) {
    let value: MovieWriter = try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        if let failure { continuation.resume(throwing: failure) }
        else if let writer { continuation.resume(returning: writer) }
        else { continuation.resume(throwing: NSError(domain: "CameraRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No video frames arrived."])) }
      }
    }
    let file = try await value.finish()
    return (file, captureVideoDrops + value.droppedFrames, earlyAudioDrops + value.droppedAudioBuffers)
  }
}
