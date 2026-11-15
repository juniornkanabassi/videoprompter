#if os(macOS)
import Foundation
import Combine
import Network

@MainActor
final class SpeechModelPrefetch: ObservableObject {
  @Published private(set) var status = ""
  @Published private(set) var isDownloading = false
  @Published private(set) var needsDownload = false
  private var task: Task<Void, Never>?
  private var selected = ""
  private var revision = 0
  private var started = false
  private var cancelled = false
  private var constrained = true
  private let monitor = NWPathMonitor()

  static func allowed(arguments: [String], environment: [String: String], underTest: Bool) -> Bool {
    !underTest && !arguments.contains("--agent-screen") && !arguments.contains("--list-camera-ids")
      && !environment.keys.contains(where: { $0.contains("SNAPSHOT") || $0.hasPrefix("XCTest") })
  }

  static func shouldDownload(engine: String, constrained: Bool) -> Bool {
    engine == "parakeet" && !constrained
  }

  func select(_ engine: String) {
    guard selected != engine else { return }
    selected = engine
    stop()
    cancelled = false
    guard engine == "parakeet", Self.allowed(arguments: ProcessInfo.processInfo.arguments,
      environment: ProcessInfo.processInfo.environment, underTest: NSClassFromString("XCTestCase") != nil) else { return }
    monitor.pathUpdateHandler = { [weak self] path in
      // No 833 MB download over Low Data Mode, a phone hotspot or no connection.
      let restricted = path.isConstrained || path.isExpensive || path.status != .satisfied
      Task { @MainActor in
        guard let self else { return }
        self.constrained = restricted
        if restricted {
          let wasCancelled = self.cancelled; self.stop(); self.cancelled = wasCancelled
          self.offerIfMissing("Download models when you are ready")
        }
        else if Self.shouldDownload(engine: self.selected, constrained: restricted), self.task == nil, !self.cancelled { self.download() }
      }
    }
    guard !started else { if constrained { offerIfMissing("Download models when you are ready") } else { download() }; return }
    started = true
    monitor.start(queue: DispatchQueue(label: "speech-model-network", qos: .utility))
  }

  func cancel() { stop(); offerIfMissing("") }

  private func stop() {
    cancelled = true
    revision += 1
    task?.cancel(); task = nil; isDownloading = false
    status = ""
    needsDownload = false
  }

  /// Offers Download now only when the models are missing; the check hashes them off the main thread.
  private func offerIfMissing(_ message: String) {
    guard selected == "parakeet" else { return }
    guard Self.allowed(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
      underTest: NSClassFromString("XCTestCase") != nil) else { status = message; needsDownload = true; return }
    let current = revision
    Task { [weak self] in
      let installed = await Task.detached(priority: .utility) {
        ParakeetModel.ready(at: ParakeetModel.root(unified: false), files: ParakeetModel.files)
          && ParakeetModel.ready(at: ParakeetModel.root(unified: true), files: UnifiedModel.files)
      }.value
      guard let self, !installed, self.revision == current, self.task == nil else { return }
      self.status = message
      self.needsDownload = true
    }
  }

  func download() {
    guard selected == "parakeet", task == nil,
      Self.allowed(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
        underTest: NSClassFromString("XCTestCase") != nil) else { return }
    cancelled = false
    let current = revision
    isDownloading = true
    needsDownload = false
    task = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
        for unified in [false, true] {
          try Task.checkCancellation()
          let root = ParakeetModel.root(unified: unified)
          let work = Task.detached(priority: .utility) {
            try await ParakeetModel.ensure(at: root,
              files: unified ? UnifiedModel.files : ParakeetModel.files,
              baseURL: unified ? UnifiedModel.baseURL : ParakeetModel.baseURL,
              name: unified ? "Parakeet Unified" : "Parakeet",
              progress: { [weak self] message in
                guard self?.revision == current else { return }
                self?.status = message
              })
          }
          try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
        guard self?.revision == current else { return }
        ParakeetModelPool.warm()
        self?.status = "Models ready · used next time you start reading"
      } catch is CancellationError { return }
      catch { guard self?.revision == current else { return }; self?.status = "Download paused · Apple is available"; self?.needsDownload = true }
      self?.isDownloading = false
      self?.task = nil
    }
  }
}
#endif
