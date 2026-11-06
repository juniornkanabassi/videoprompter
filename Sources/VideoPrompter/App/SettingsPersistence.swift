import Foundation
import PrompterCore

struct EditorTypographyPreferences: Codable, Sendable {
  var sourceFontName = "Lexend Deca"
  var sourceFontSize = 17.0
  var previewFontName = "Lexend Deca"
  var previewFontSize = 18.0

  init(sourceFontName: String = "Lexend Deca", sourceFontSize: Double = 17,
       previewFontName: String = "Lexend Deca", previewFontSize: Double = 18) {
    self.sourceFontName = sourceFontName; self.sourceFontSize = InputValidation.editorSize.repair(sourceFontSize)
    self.previewFontName = previewFontName; self.previewFontSize = InputValidation.editorSize.repair(previewFontSize)
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(sourceFontName: c.preference(.sourceFontName, default: "Lexend Deca"),
      sourceFontSize: c.preference(.sourceFontSize, default: 17),
      previewFontName: c.preference(.previewFontName, default: "Lexend Deca"),
      previewFontSize: c.preference(.previewFontSize, default: 18))
  }
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
  private let queueKey = DispatchSpecificKey<Bool>()
  private let defaults: UserDefaults
  private let delay: TimeInterval
  private var pending: SettingsSnapshot?
  private var work: DispatchWorkItem?
  /// A write not yet committed by `synchronize`, so an idle flush can skip it.
  private var unsynchronized = false
  /// Test seam: called on the writer's queue after each actual write.
  private let onWrite: (@Sendable () -> Void)?

  init(defaults: UserDefaults, delay: TimeInterval = 0.3, onWrite: (@Sendable () -> Void)? = nil) {
    self.defaults = defaults
    self.delay = delay
    self.onWrite = onWrite
    queue.setSpecific(key: queueKey, value: true)
  }

  deinit {
    work?.cancel()
    guard let snapshot = pending else { return }
    // Queue operations retain the writer, so teardown owns its remaining snapshot.
    nonisolated(unsafe) let savedDefaults = defaults
    let onWrite = onWrite
    if DispatchQueue.getSpecific(key: queueKey) == true {
      Self.write(snapshot, to: savedDefaults); onWrite?()
    } else {
      queue.async { Self.write(snapshot, to: savedDefaults); onWrite?() }
    }
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

  func flush() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [self] in
        finishPending()
        continuation.resume()
      }
    }
  }

  private func finishPending() {
    work?.cancel()
    work = nil
    writePending()
    // CLI responses and teardown need the defaults service to commit before returning.
    if unsynchronized { defaults.synchronize(); unsynchronized = false }
  }

  private func writePending() {
    guard let snapshot = pending else { return }
    pending = nil
    Self.write(snapshot, to: defaults)
    unsynchronized = true
    onWrite?()
  }

  private static func write(_ snapshot: SettingsSnapshot, to defaults: UserDefaults) {
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(snapshot.settings) { defaults.set(data, forKey: "settings") }
    if let data = try? encoder.encode(snapshot.presets) { defaults.set(data, forKey: "presets") }
    if let data = try? encoder.encode(snapshot.typography) { defaults.set(data, forKey: "editorTypography") }
    defaults.set(snapshot.uiZoom, forKey: "uiZoom")
    defaults.set(snapshot.simpleInterface, forKey: "simpleInterface")
  }
}
