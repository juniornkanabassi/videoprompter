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
  var isRecording: Bool { phase == .waitingForFrames || phase == .recording }
  var isBusy: Bool { phase == .preparing || phase == .saving }
  @Published var mirrorSavedVideo: Bool { didSet { defaults.set(mirrorSavedVideo, forKey: "mirrorSavedVideo") } }
  @Published private(set) var isTestingInput = false
  private var inputTest: RecordingAudioTest?
  private var inputTestStop: Task<Void, Never>?
  private var testGeneration = UUID()
  @Published private(set) var recordedDuration: TimeInterval = 0
  @Published private(set) var startedAt: Date?
  private(set) var recordingID: UUID?
  @Published private(set) var lastFile: URL?
  @Published var errorMessage: String? { didSet { if let errorMessage, errorMessage != oldValue { announce(errorMessage) } } }
  @Published var preset: RecordingPreset { didSet { defaults.set(preset.rawValue, forKey: "recordingPreset") } }
  @Published var floatAudio: Bool { didSet { if floatAudio != oldValue { stopInputTest() }; defaults.set(floatAudio, forKey: "recordingFloatAudio") } }
  @Published var takeLabel = ""
  @Published var microphoneUID: String? { didSet { if microphoneUID != oldValue { stopInputTest() }; defaults.set(microphoneUID, forKey: "recordingMicrophoneUID") } }
  private let defaults: UserDefaults
  private var sink: RecordingSink?
  private var cancelStart = false
  private var stopTask: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var lastFrameAt: Date?
  @Published private(set) var droppedFrames = 0
  @Published private(set) var activeMicrophoneName: String?
  @Published private(set) var audioChannels = 0
  let inputMeter = InputMeter()
  private var observers: [NSObjectProtocol] = []
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preset = defaults.string(forKey: "recordingPreset").flatMap(RecordingPreset.init) ?? .standard
    floatAudio = defaults.bool(forKey: "recordingFloatAudio")
    microphoneUID = defaults.string(forKey: "recordingMicrophoneUID")
    mirrorSavedVideo = defaults.bool(forKey: "mirrorSavedVideo")
    if let path = defaults.string(forKey: "lastRecording"), FileManager.default.fileExists(atPath: path) { lastFile = URL(fileURLWithPath: path) }
  }
  static func recordingsFolder(arguments: [String] = CommandLine.arguments,
                               movies: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]) -> URL {
    if let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count { return URL(fileURLWithPath: arguments[i + 1]).appendingPathComponent("Recordings") }
    return ControlProtocol.migrateLegacyFolder(in: movies)
  }
  static func fileURL(in folder: URL, date: Date = Date(), label: String = "") -> URL {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    let cleaned = label.components(separatedBy: CharacterSet(charactersIn: "/:\\|\n\r")).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = cleaned.isEmpty ? "Video Prompter" : String(cleaned.prefix(100))
    let stem = "\(prefix) \(formatter.string(from: date))"
    var url = folder.appendingPathComponent(stem + ".mov"); var number = 2
    while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(stem) \(number).mov"); number += 1 }
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
    if let uid = microphoneUID { return Self.microphones().first { $0.uniqueID == uid }?.localizedName ?? "Selected microphone unavailable" }
    return AVCaptureDevice.default(for: .audio)?.localizedName ?? "No microphone"
  }
  static func framesTimedOut(attachedAt: Date, lastFrameAt: Date?, now: Date) -> Bool {
    now.timeIntervalSince(lastFrameAt ?? attachedAt) > 5
  }
  func start(camera: CameraModel) async {
    guard !isBusy, !isRecording else { return }
    stopInputTest()
    phase = .preparing; cancelStart = false; errorMessage = nil
    recordingID = UUID()
    let takeID = recordingID
    recordedDuration = 0; droppedFrames = 0; inputMeter.reset(); lastFrameAt = nil
    activeMicrophoneName = nil; audioChannels = 0
    defer { if !isRecording { phase = .idle; recordingID = nil } }
    do {
      await inputTestStop?.value
      guard !cancelStart else { return }
      guard let uid = camera.selectedUID, AVCaptureDevice(uniqueID: uid) != nil else { throw recordingError("Choose an available camera first.") }
      if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
      guard !cancelStart else { return }
      guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw recordingError("Allow camera access in System Settings > Privacy & Security > Camera before recording.") }
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
      guard !cancelStart else { return }
      guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw recordingError("Allow microphone access in System Settings > Privacy & Security > Microphone before recording.") }
      let devices = Self.microphones()
      let microphone = microphoneUID.flatMap { id in devices.first { $0.uniqueID == id } } ?? (microphoneUID == nil ? AVCaptureDevice.default(for: .audio) : nil)
      guard let microphone else { throw recordingError("The selected microphone is unavailable. Open Recording settings and choose another microphone.") }
      if microphoneUID != nil { microphoneUID = microphone.uniqueID }
      let folder = Self.recordingsFolder()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
      guard Self.hasRecordingSpace(free) else { throw recordingError("Free at least 2 GB on the recording drive, then try Record again.") }
      activeMicrophoneName = microphone.localizedName
      let input = try AVCaptureDeviceInput(device: microphone)
      let format = CMAudioFormatDescriptionGetStreamBasicDescription(microphone.activeFormat.formatDescription)?.pointee
      let spec = AudioSpec(sampleRate: floatAudio ? (format?.mSampleRate ?? 48000) : min(format?.mSampleRate ?? 48000, 48000), channels: min(Int(format?.mChannelsPerFrame ?? 2), 2))
      audioChannels = spec.channels
      let sink = RecordingSink(url: Self.fileURL(in: folder, label: takeLabel), preset: preset, rotation: camera.guides.rotation, mirrored: mirrorSavedVideo, audio: spec, floatAudio: floatAudio, microphone: input, onFrame: { [weak self] duration in
        Task { @MainActor in
          guard let self, self.recordingID == takeID, self.isRecording else { return }
          if self.startedAt == nil { self.startedAt = Date(); self.phase = .recording }
          self.recordedDuration = duration
          self.lastFrameAt = Date()
        }
      }, onAudio: { [weak self] levels in
        Task { @MainActor in
          guard let self, self.recordingID == takeID, self.isRecording else { return }
          self.inputMeter.show(channelPeaks: levels)
        }
      }) { [weak self] error in
        Task { @MainActor [weak self] in
          guard let self, self.isRecording else { return }
          self.errorMessage = "Recording stopped after a writer failure: \(error.localizedDescription)"
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
      guard attached else { shared.release(); throw recordingError("This camera cannot start recording. Choose another camera or close other apps using it, then try again.") }
      self.sink = sink; phase = .waitingForFrames
      if cancelStart || camera.selectedUID != uid { await stop(); return }
      let attachedAt = Date()
      watchdog = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, let self, self.isRecording else { return }
          if Self.framesTimedOut(attachedAt: attachedAt, lastFrameAt: self.lastFrameAt, now: Date()) {
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
            guard let self, self.isRecording, lostUID == nil || lostUID == uid || lostUID == microphone.uniqueID else { return }
            self.errorMessage = "A recording device disconnected or capture was interrupted. Recording was stopped."
            await self.stop()
          }
        })
      }
    } catch { errorMessage = error.localizedDescription }
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
      do { let result = try await sink.finish(); lastFile = result.0; defaults.set(result.0.path, forKey: "lastRecording"); droppedFrames = result.1; announce("Saved recording \(result.0.lastPathComponent)" + (result.1 > 0 ? ". \(result.1) video frames were dropped." : "")) } catch { errorMessage = "No completed take was saved. Recording could not be finished: \(error.localizedDescription)" }
      shared.release(); self.sink = nil; startedAt = nil; recordingID = nil; phase = .idle
    }
    stopTask = task; await task.value; stopTask = nil
  }
  func startInputTest() async {
    guard !isRecording, !isBusy, !isTestingInput else { return }
    testGeneration = UUID()
    let generation = testGeneration
    isTestingInput = true; inputMeter.reset(); errorMessage = nil
    await inputTestStop?.value
    guard generation == testGeneration else { return }
    guard await AudioCapture.requestPermission(), generation == testGeneration else {
      if generation == testGeneration { isTestingInput = false; errorMessage = "Allow microphone access in System Settings > Privacy & Security > Microphone, then test again." }
      return
    }
    do {
      let device = microphoneUID.flatMap { id in Self.microphones().first { $0.uniqueID == id } }
        ?? (microphoneUID == nil ? AVCaptureDevice.default(for: .audio) : nil)
      guard let device else { throw recordingError("Open Recording settings and choose an available microphone.") }
      let test = try RecordingAudioTest(device: device, floatAudio: floatAudio) { [weak self] levels in
        Task { @MainActor in
          guard let self, self.testGeneration == generation, self.isTestingInput else { return }
          self.inputMeter.show(channelPeaks: levels)
        }
      }
      inputTest = test
      await test.start()
      if generation != testGeneration { await test.stop() }
    } catch { if generation == testGeneration { stopInputTest(); errorMessage = error.localizedDescription } }
  }
  func stopInputTest() {
    testGeneration = UUID(); isTestingInput = false; inputMeter.reset()
    if let test = inputTest { inputTestStop = Task { await test.stop() } }
    inputTest = nil
  }
  private func announce(_ message: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }
  private func recordingError(_ message: String) -> NSError { NSError(domain: "CameraRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// AVFoundation delegate callbacks and the writer belong exclusively to queue.
final class RecordingSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  let video = AVCaptureVideoDataOutput()
  let audio = AVCaptureAudioDataOutput()
  let microphone: AVCaptureDeviceInput
  private let queue = DispatchQueue(label: "VideoPrompter.recording")
  private let url: URL
  private let preset: RecordingPreset
  private let rotation: CameraRotation
  private let mirrored: Bool
  private let onFrame: @Sendable (TimeInterval) -> Void
  private let onAudio: @Sendable ([Float]) -> Void
  private var firstFrame: CMTime?
  private let spec: AudioSpec
  private let floatAudio: Bool
  private let onFailure: @Sendable (Error) -> Void
  private var writer: MovieWriter?
  private var failure: Error?
  init(url: URL, preset: RecordingPreset, rotation: CameraRotation, mirrored: Bool, audio: AudioSpec, floatAudio: Bool, microphone: AVCaptureDeviceInput, onFrame: @escaping @Sendable (TimeInterval) -> Void, onAudio: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @Sendable (Error) -> Void) {
    self.url = url; self.preset = preset; self.rotation = rotation; self.mirrored = mirrored; self.onFrame = onFrame; self.onAudio = onAudio; spec = audio; self.floatAudio = floatAudio; self.microphone = microphone; self.onFailure = onFailure
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
      } else {
        onAudio(RecordingAudioTest.channelPeaks(in: sampleBuffer))
        try writer?.append(audio: sampleBuffer)
      }
    } catch { failure = error; onFailure(error) }
  }
  static func recordingTransform(rotation: CameraRotation, mirrored: Bool) -> CGAffineTransform {
    CGAffineTransform(rotationAngle: rotation.radians).concatenating(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
  }
  func finish() async throws -> (URL, Int) {
    let value: MovieWriter = try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        if let failure { continuation.resume(throwing: failure) }
        else if let writer { continuation.resume(returning: writer) }
        else { continuation.resume(throwing: NSError(domain: "CameraRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No video frames arrived."])) }
      }
    }
    let file = try await value.finish()
    return (file, value.droppedFrames)
  }
}
