import Foundation

struct EditorTypographyPreferences: Codable, Sendable {
  var sourceFontName = "Lexend Deca"
  var sourceFontSize = 17.0
  var previewFontName = "Lexend Deca"
  var previewFontSize = 18.0
}

struct SettingsSnapshot: Sendable {
  var settings: PrompterSettings
  var presets: [PrompterSettings]
  var typography: EditorTypographyPreferences
  var uiZoom: Double
  var simpleInterface: Bool
}

/// All encoding and defaults writes run in order, away from the UI thread.
/// Only the most recent value in a slider burst is written.
final class SettingsPersistence: @unchecked Sendable {
  private let queue = DispatchQueue(label: "VideoPrompter.settings", qos: .utility)
  private let defaults: UserDefaults
  private let delay: TimeInterval
  private var pending: SettingsSnapshot?
  private var work: DispatchWorkItem?
  private var writes = 0
  private var wroteOnMainThread = false

  init(defaults: UserDefaults, delay: TimeInterval = 0.3) {
    self.defaults = defaults
    self.delay = delay
  }

  func schedule(_ snapshot: SettingsSnapshot) {
    queue.async { [self] in
      pending = snapshot
      work?.cancel()
      let item = DispatchWorkItem { [weak self] in self?.writePending() }
      work = item
      queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func flush() async -> (writes: Int, wroteOnMainThread: Bool) {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        work?.cancel()
        work = nil
        writePending()
        continuation.resume(returning: (writes, wroteOnMainThread))
      }
    }
  }

  private func writePending() {
    guard let snapshot = pending else { return }
    pending = nil
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(snapshot.settings) { defaults.set(data, forKey: "settings") }
    if let data = try? encoder.encode(snapshot.presets) { defaults.set(data, forKey: "presets") }
    if let data = try? encoder.encode(snapshot.typography) { defaults.set(data, forKey: "editorTypography") }
    defaults.set(snapshot.uiZoom, forKey: "uiZoom")
    defaults.set(snapshot.simpleInterface, forKey: "simpleInterface")
    writes += 1
    wroteOnMainThread = wroteOnMainThread || Thread.isMainThread
  }
}
