#if os(macOS)
import AVFoundation
import CoreML
import CryptoKit
import FluidAudio
import Foundation
import PrompterCore
import Speech

/// The same 16 kHz PCM stream and candidate boundary as Apple. No microphone or matcher lives here.
actor ParakeetSpeechStream {
  private var manager: (any StreamingAsrManager)?
  private var poolKey = ""
  private var source = "parakeet"
  private var operation: UInt64 = 0
  /// `start` owns the manager while it runs; only a manager that finished cleanly goes back to the pool.
  private var running = false
  private var failed = false

  deinit {
    // A preparation cancelled after taking the models drops its stream without `stop`.
    if let manager, !failed { Task { [poolKey] in await ParakeetModelPool.shared.put(manager, key: poolKey) } }
  }

  func prepare(directory: URL?, unified: Bool = false, allowDownload: Bool = true, onPreparation: @escaping @MainActor @Sendable (String) -> Void) async throws {
    operation &+= 1
    let current = operation
    source = unified ? "unified" : "parakeet"
    let name = unified ? "Parakeet Unified" : "Parakeet"
    let root = directory ?? ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier,
      arguments: ProcessInfo.processInfo.arguments).appendingPathComponent(unified ? "Models/" + UnifiedModel.folder : "Models/parakeet-eou-160ms")
    if allowDownload {
      try await ParakeetModel.ensure(at: root, files: unified ? UnifiedModel.files : ParakeetModel.files,
        baseURL: unified ? UnifiedModel.baseURL : ParakeetModel.baseURL, name: name, progress: onPreparation)
    }
    try Task.checkCancellation()
    guard current == operation else { throw CancellationError() }
    poolKey = "\(unified)|\(root.standardizedFileURL.path)"
    if let loaded = await ParakeetModelPool.shared.take(poolKey) {
      guard current == operation, !Task.isCancelled else {
        await ParakeetModelPool.shared.put(loaded, key: poolKey)
        throw CancellationError()
      }
      manager = loaded
      await onPreparation("\(name) ready · on-device · English")
      return
    }
    await onPreparation("Preparing \(name) on this Mac…")
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    let loaded: any StreamingAsrManager
    if unified {
      let model = StreamingUnifiedAsrManager(configuration: configuration, config: .init(chunkFrames: UnifiedModel.chunkFrames, rightFrames: UnifiedModel.rightFrames))
      try await model.loadModels(from: root)
      loaded = model
    } else {
      let model = StreamingEouAsrManager(configuration: configuration, chunkSize: .ms160)
      try await model.loadModels(from: root)
      loaded = model
    }
    try Task.checkCancellation()
    guard current == operation else { throw CancellationError() }
    manager = loaded
    await onPreparation("\(name) ready · on-device · English")
  }

  func start<S: AsyncSequence>(input: S, generation: UInt64,
    onCandidate: @escaping @MainActor @Sendable (SpeechCandidate) -> Void
  ) async throws where S: Sendable, S.Element == AnalyzerInput {
    guard let manager else { throw SpeechProvider.Error.notPrepared }
    let current = operation
    running = true
    defer { running = false }
    do { try await run(manager, input: input, current: current, generation: generation, onCandidate: onCandidate) }
    catch is CancellationError { throw CancellationError() }
    catch { failed = true; throw error }
  }

  private func run<S: AsyncSequence>(_ manager: any StreamingAsrManager, input: S, current: UInt64, generation: UInt64,
    onCandidate: @escaping @MainActor @Sendable (SpeechCandidate) -> Void
  ) async throws where S: Sendable, S.Element == AnalyzerInput {
    var previous = ""
    var end = CMTime.zero
    for try await input in input {
      try Task.checkCancellation()
      guard current == operation else { throw CancellationError() }
      try await manager.appendAudio(input.buffer)
      try await manager.processBufferedAudio()
      end = CMTimeAdd(input.bufferStartTime ?? end,
        CMTime(seconds: Double(input.buffer.frameLength) / input.buffer.format.sampleRate, preferredTimescale: 16000))
      guard current == operation, !Task.isCancelled else { throw CancellationError() }
      let text = await manager.getPartialTranscript()
      if let candidate = Self.candidate(text: text, previous: previous, generation: generation, end: end, source: source) {
        previous = text
        await onCandidate(candidate)
      }
    }
    try Task.checkCancellation()
    guard current == operation else { throw CancellationError() }
    let text = try await manager.finish()
    guard current == operation, !Task.isCancelled else { throw CancellationError() }
    if let candidate = Self.candidate(text: text, previous: previous, generation: generation, end: end, source: source) {
      await onCandidate(candidate)
    }
  }

  static func candidate(text: String, previous: String, generation: UInt64, end: CMTime, source: String = "parakeet") -> SpeechCandidate? {
    guard !text.isEmpty, text != previous else { return nil }
    // shortcut: one cumulative revision for a reading session; segment it if long-form memory grows.
    // The existing seek baseline discards speech heard before a reanchor.
    // Range is submitted audio, not fabricated word alignment; A/B timing uses an external word track.
    return .init(replacementID: "\(generation)-\(source)", generation: generation,
      locale: Locale(identifier: "en-GB"), text: text,
      range: CMTimeRange(start: .zero, end: end), isFinal: false, source: source)
  }

  func stop() async {
    operation &+= 1
    guard let manager else { return }
    self.manager = nil
    // Its audio has already ended or been cancelled, so the loop returns within one buffer.
    for _ in 0..<50 where running { try? await Task.sleep(for: .milliseconds(10)) }
    // Still running or failed: dropped as before, never reset under a live loop or reused broken.
    guard !running, !failed else { return }
    await ParakeetModelPool.shared.put(manager, key: poolKey)
  }
}

/// Loaded Parakeet models outlive a stream. Every seek, pause and resume stops the speech provider
/// and prepares it again; reloading the CoreML models each time left Voice deaf for seconds. A
/// stopped stream hands its manager back here and the next preparation takes it. They are released
/// when the session ends or stops using Parakeet, on memory pressure, or after ten idle minutes.
actor ParakeetModelPool {
  static let shared = ParakeetModelPool()
  private var idle: [String: any StreamingAsrManager] = [:]
  private var expiry: Task<Void, Never>?
  private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))

  private init() {
    pressure.setEventHandler { Task { await ParakeetModelPool.shared.releaseAll() } }
    pressure.activate()
  }

  func take(_ key: String) -> (any StreamingAsrManager)? { idle.removeValue(forKey: key) }

  func put(_ manager: any StreamingAsrManager, key: String) async {
    // Same weights, fresh decoding and audio state.
    do { try await manager.reset() } catch { await manager.cleanup(); return }
    if let replaced = idle.updateValue(manager, forKey: key) { await replaced.cleanup() }
    expiry?.cancel()
    expiry = Task {
      try? await Task.sleep(for: .seconds(600))
      guard !Task.isCancelled else { return }
      await self.releaseAll()
    }
  }

  func releaseAll() async {
    let loaded = Array(idle.values)
    idle.removeAll()
    for manager in loaded { await manager.cleanup() }
  }

  var count: Int { idle.count }

  /// Loads both models in the background so the first Start reading after launch does not wait
  /// seconds for them (6 to 9 s each when measured cold). Released like any idle model if unused.
  nonisolated static func warm() {
    Task.detached(priority: .background) {
      for unified in [false, true] {
        let stream = ParakeetSpeechStream()
        do { try await stream.prepare(directory: ParakeetModel.root(unified: unified), unified: unified, allowDownload: false) { _ in } }
        catch { continue }
        await stream.stop()
      }
    }
  }
}

/// Immutable model revision and byte checks prevent partial or changed downloads being loaded.
enum ParakeetModel {
  static let revision = "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355"
  static let baseURL = "https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml/resolve/\(revision)/160ms/"
  struct File: Sendable, Hashable { let path: String; let size: Int; let sha256: String }
  static let files: [File] = [
    .init(path: "decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "3996975a8cbc1949159c55605b3132b39b2484f51acbd55d796d93c70de02b49"),
    .init(path: "decoder.mlmodelc/coremldata.bin", size: 497, sha256: "c3ccbff963d8cf07e2be2bd56ea3384a89ea49628922c6bd95ff62e2ae57dc34"),
    .init(path: "decoder.mlmodelc/metadata.json", size: 3283, sha256: "0977480649f2756894b0acfe2fdf4231a991f25e3fe02562bfb71b65ca944575"),
    .init(path: "decoder.mlmodelc/model.mil", size: 7409, sha256: "b7c084a35bdbc887d69d6226cd533e2c11b2792c37d7352cf878f9f6f3c13555"),
    .init(path: "decoder.mlmodelc/weights/weight.bin", size: 7873600, sha256: "0b4cacecdcd9df79ab1e56de67230baf5a8664d2afe0bb8f3408eefa972cb2f4"),
    .init(path: "joint_decision.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "5bca32ad130dcad6605cc00044c752aa5b45ef57d14c17f2d1a2fa49d6cf55b5"),
    .init(path: "joint_decision.mlmodelc/coremldata.bin", size: 493, sha256: "22d4abc4625b935ee035b5f8ce7cb28d1041b9b01c12173e287bf4b5f5d99625"),
    .init(path: "joint_decision.mlmodelc/metadata.json", size: 3181, sha256: "e970ae87137730020690d24d971813db3633bbdfed602d43b6a9c84deced6dc8"),
    .init(path: "joint_decision.mlmodelc/model.mil", size: 9608, sha256: "45e8590bc87e34c162b547e43a4f60e64db15b017f48395d7835a6867884804f"),
    .init(path: "joint_decision.mlmodelc/weights/weight.bin", size: 2794182, sha256: "7039b2010a269153f5a96edf28637f921a86ef8822f248f2d6712f7a6bce84b4"),
    .init(path: "streaming_encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "a981b257db79b4f86e6fa06a92562160a0ae71554746c24af24d8634b85f0356"),
    .init(path: "streaming_encoder.mlmodelc/coremldata.bin", size: 670, sha256: "e762abc60d999bcd10aab985b68191a602f2e8e03165cf08671c60f93936037a"),
    .init(path: "streaming_encoder.mlmodelc/metadata.json", size: 5327, sha256: "75be31534cdd91711b08ba3a46046523eb9be9909618cd569cce1ea79e842a95"),
    .init(path: "streaming_encoder.mlmodelc/model.mil", size: 639646, sha256: "709f9280eb0bba1fd698cc252275ba802885c2c53cdb60d399277281dac09b5d"),
    .init(path: "streaming_encoder.mlmodelc/weights/weight.bin", size: 212691776, sha256: "12cd781a4300b52b6687587b7d8e37e0ce5c8ccb1dbea036008275e6abf5070c"),
    .init(path: "vocab.json", size: 17437, sha256: "83fd42ad33dae1bd3ceee6c0bb6c625f314cf0b2dc8430be441ac1e2643d5c36"),
  ]
  static var size: Int { files.reduce(0) { $0 + $1.size } }

  static func root(unified: Bool) -> URL {
    ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier,
      arguments: ProcessInfo.processInfo.arguments).appendingPathComponent(
        unified ? "Models/" + UnifiedModel.folder : "Models/parakeet-eou-160ms")
  }

  private struct VerificationKey: Hashable {
    let root: URL
    let files: [File]
  }
  private final class VerificationCache: @unchecked Sendable {
    let lock = NSLock()
    var results: [VerificationKey: Bool] = [:]
  }
  private static let verification = VerificationCache()

  static func ready(at root: URL, files: [File]) -> Bool {
    let key = VerificationKey(root: root.standardizedFileURL, files: files)
    let sizesMatch = files.allSatisfy {
      (try? root.appendingPathComponent($0.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == $0.size
    }
    // Same-size external edits are rehashed next launch; downloads refresh this entry immediately.
    if let verified = verification.lock.withLock({ verification.results[key] }) { return verified && sizesMatch }
    // Hash ~830 MB outside the lock so Start never waits behind the launch prefetch's check.
    let verified = sizesMatch && files.allSatisfy { (try? valid(root.appendingPathComponent($0.path), file: $0)) == true }
    // A download that recorded its result meanwhile is newer than this hash.
    verification.lock.withLock { if verification.results[key] == nil { verification.results[key] = verified } }
    return verified
  }

  private static func invalidateVerification(at root: URL, files: [File]) {
    verification.lock.lock()
    defer { verification.lock.unlock() }
    verification.results.removeValue(forKey: VerificationKey(root: root.standardizedFileURL, files: files))
  }

  private static func recordVerification(at root: URL, files: [File]) {
    verification.lock.lock()
    defer { verification.lock.unlock() }
    verification.results[VerificationKey(root: root.standardizedFileURL, files: files)] = true
  }

  static func valid(_ url: URL, file: File) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path),
      try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.size else { return false }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
  }

  static func ensure(at root: URL, files: [File] = files, baseURL: String = baseURL, name: String = "Parakeet", progress: @escaping @MainActor @Sendable (String) -> Void) async throws {
    if ready(at: root, files: files) { return }
    invalidateVerification(at: root, files: files)
    var verified = false
    defer { if !verified { invalidateVerification(at: root, files: files) } }
    let size = files.reduce(0) { $0 + $1.size }
    var completed = 0
    for file in files {
      try Task.checkCancellation()
      let destination = root.appendingPathComponent(file.path)
      if try !valid(destination, file: file) {
        await progress("Downloading \(name): \(completed * 100 / size)% · \(file.path.components(separatedBy: "/").first!)")
        let (temporary, response) = try await URLSession.shared.download(from: URL(string: baseURL + file.path)!)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, try valid(temporary, file: file) else {
          throw SpeechProvider.Error.analysisFailed("\(name) download failed verification. Try again while online.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
          _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
      }
      completed += file.size
    }
    recordVerification(at: root, files: files)
    verified = true
  }
}
#endif
