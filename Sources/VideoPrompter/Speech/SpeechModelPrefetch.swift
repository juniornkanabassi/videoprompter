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
    cancel()
    cancelled = false
    guard engine == "parakeet", Self.allowed(arguments: ProcessInfo.processInfo.arguments,
      environment: ProcessInfo.processInfo.environment, underTest: NSClassFromString("XCTestCase") != nil) else { return }
    monitor.pathUpdateHandler = { [weak self] path in
      let restricted = path.isConstrained || path.status != .satisfied
      Task { @MainActor in
        guard let self else { return }
        self.constrained = restricted
        if restricted { let wasCancelled = self.cancelled; self.cancel(); self.cancelled = wasCancelled; self.status = "Download models when you are ready"; self.needsDownload = true }
        else if Self.shouldDownload(engine: self.selected, constrained: restricted), self.task == nil, !self.cancelled { self.download() }
      }
    }
    guard !started else { if !constrained { download() }; return }
    started = true
    monitor.start(queue: DispatchQueue(label: "speech-model-network", qos: .utility))
  }

  func cancel() {
    cancelled = true
    revision += 1
    task?.cancel(); task = nil; isDownloading = false
    needsDownload = selected == "parakeet"
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
          let work = Task.detached(priority: .background) {
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
        self?.status = "Models ready · used next time you start reading"
      } catch is CancellationError { return }
      catch { guard self?.revision == current else { return }; self?.status = "Download paused · Apple is available"; self?.needsDownload = true }
      self?.isDownloading = false
      self?.task = nil
    }
  }
}
#endif
