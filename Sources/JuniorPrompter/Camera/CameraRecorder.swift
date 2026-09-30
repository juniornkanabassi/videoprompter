@preconcurrency import AVFoundation
import Combine
import PrompterCore

@MainActor final class CameraRecorder: ObservableObject {
  static let shared = CameraRecorder(defaults: AppStore.preferences())
  @Published private(set) var isRecording = false
  @Published private(set) var isBusy = false
  @Published private(set) var startedAt: Date?
  @Published private(set) var lastFile: URL?
  @Published var errorMessage: String?
  @Published var preset: RecordingPreset { didSet { defaults.set(preset.rawValue, forKey: "recordingPreset") } }
  @Published var floatAudio: Bool { didSet { defaults.set(floatAudio, forKey: "recordingFloatAudio") } }
  @Published var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: "recordingMicrophoneUID") } }
  private let defaults: UserDefaults
  private var sink: RecordingSink?
  private var cancelStart = false
  private var stopTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preset = defaults.string(forKey: "recordingPreset").flatMap(RecordingPreset.init) ?? .standard
    floatAudio = defaults.bool(forKey: "recordingFloatAudio")
    microphoneUID = defaults.string(forKey: "recordingMicrophoneUID")
  }
  static func recordingsFolder(arguments: [String] = CommandLine.arguments) -> URL {
    if let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count { return URL(fileURLWithPath: arguments[i + 1]).appendingPathComponent("Recordings") }
    return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("JuniorPrompter")
  }
  static func fileURL(in folder: URL, date: Date = Date()) -> URL {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    let stem = "JuniorPrompter \(formatter.string(from: date))"
    var url = folder.appendingPathComponent(stem + ".mov"); var number = 2
    while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(stem) \(number).mov"); number += 1 }
    return url
  }
  static func hasRecordingSpace(_ bytes: Int64) -> Bool { bytes >= 2_000_000_000 }
  static func microphones() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
  }
  func start(camera: CameraModel) async {
    guard !isBusy, !isRecording else { return }
    isBusy = true; cancelStart = false; errorMessage = nil
    defer { isBusy = false }
    do {
      guard let uid = camera.selectedUID, AVCaptureDevice(uniqueID: uid) != nil else { throw recordingError("Choose an available camera first.") }
      if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
      guard !cancelStart else { return }
      guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw recordingError("Allow camera access in System Settings > Privacy & Security > Camera before recording.") }
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
      guard !cancelStart else { return }
      guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw recordingError("Allow microphone access in System Settings > Privacy & Security > Microphone before recording.") }
      let devices = Self.microphones()
      let microphone = microphoneUID.flatMap { id in devices.first { $0.uniqueID == id } } ?? (microphoneUID == nil ? AVCaptureDevice.default(for: .audio) : nil)
      guard let microphone else { throw recordingError("The selected microphone is unavailable. Choose another explicitly.") }
      microphoneUID = microphone.uniqueID
      let folder = Self.recordingsFolder()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
      guard Self.hasRecordingSpace(free) else { throw recordingError("Recording needs at least 2 GB of free space.") }
      let input = try AVCaptureDeviceInput(device: microphone)
      let format = CMAudioFormatDescriptionGetStreamBasicDescription(microphone.activeFormat.formatDescription)?.pointee
      let spec = AudioSpec(sampleRate: format?.mSampleRate ?? 48000, channels: Int(format?.mChannelsPerFrame ?? 2))
      let sink = RecordingSink(url: Self.fileURL(in: folder), preset: preset, rotation: camera.guides.rotation, audio: spec, floatAudio: floatAudio, microphone: input)
      let shared = SharedCameraSession.shared
      shared.retain()
      let attached = await withCheckedContinuation { continuation in
        shared.reconfigure { session in
          session.beginConfiguration()
          var success = false
          if session.canAddInput(input) {
            session.addInput(input)
            if session.canAddOutput(sink.video), session.canAddOutput(sink.audio) {
              session.addOutput(sink.video); session.addOutput(sink.audio); success = true
            } else { session.removeInput(input) }
          }
          session.commitConfiguration(); continuation.resume(returning: success)
        }
      }
      guard attached else { shared.release(); throw recordingError("The camera session cannot add recording outputs with this device.") }
      self.sink = sink; isRecording = true; startedAt = Date()
      if cancelStart || camera.selectedUID != uid { await stop(); return }
      for name in [AVCaptureDevice.wasDisconnectedNotification, AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
          let lostUID = (notification.object as? AVCaptureDevice)?.uniqueID
          Task { @MainActor [weak self] in
            guard let self, self.isRecording, lostUID == nil || lostUID == uid || lostUID == self.microphoneUID else { return }
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
    isBusy = true; isRecording = false
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
      do { lastFile = try await sink.finish() } catch { errorMessage = "Recording could not be finished: \(error.localizedDescription)" }
      shared.release(); self.sink = nil; startedAt = nil; isBusy = false
    }
    stopTask = task; await task.value; stopTask = nil
  }
  private func recordingError(_ message: String) -> NSError { NSError(domain: "CameraRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// AVFoundation delegate callbacks and the writer belong exclusively to queue.
private final class RecordingSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  let video = AVCaptureVideoDataOutput()
  let audio = AVCaptureAudioDataOutput()
  let microphone: AVCaptureDeviceInput
  private let queue = DispatchQueue(label: "JuniorPrompter.recording")
  private let url: URL
  private let preset: RecordingPreset
  private let rotation: CameraRotation
  private let spec: AudioSpec
  private let floatAudio: Bool
  private var writer: MovieWriter?
  private var failure: Error?
  init(url: URL, preset: RecordingPreset, rotation: CameraRotation, audio: AudioSpec, floatAudio: Bool, microphone: AVCaptureDeviceInput) {
    self.url = url; self.preset = preset; self.rotation = rotation; spec = audio; self.floatAudio = floatAudio; self.microphone = microphone
    super.init()
    video.alwaysDiscardsLateVideoFrames = false
    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: preset == .edit ? kCVPixelFormatType_422YpCbCr8 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    self.audio.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: audio.channels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
    video.setSampleBufferDelegate(self, queue: queue); self.audio.setSampleBufferDelegate(self, queue: queue)
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard failure == nil else { return }
    do {
      if output === video {
        if writer == nil {
          guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
          let dimensions = CMVideoFormatDescriptionGetDimensions(format)
          writer = try MovieWriter(url: url, width: Int(dimensions.width), height: Int(dimensions.height), transform: CGAffineTransform(rotationAngle: rotation.radians), preset: preset, audio: spec, floatAudio: floatAudio)
        }
        writer?.append(video: sampleBuffer)
      } else { writer?.append(audio: sampleBuffer) }
    } catch { failure = error }
  }
  func finish() async throws -> URL {
    let value: MovieWriter = try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        if let failure { continuation.resume(throwing: failure) }
        else if let writer { continuation.resume(returning: writer) }
        else { continuation.resume(throwing: NSError(domain: "CameraRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No video frames arrived."])) }
      }
    }
    return try await value.finish()
  }
}
