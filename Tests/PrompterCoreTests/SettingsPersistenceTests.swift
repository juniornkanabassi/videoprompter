import Foundation
import XCTest
@testable import VideoPrompter

@MainActor final class SettingsPersistenceTests: XCTestCase {
  func testSliderBurstPerformance() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID())")
    let suite = "SettingsPersistence.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await store.waitForInitialLoad()
    store.presets = (0..<100).map { index in
      var preset = PrompterSettings(); preset.name = "Saved appearance \(index)"; return preset
    }
    // The baseline is the previous implementation, replayed with the same data and writes.
    var legacySettings = store.settings
    let legacyStart = ContinuousClock.now
    for index in 0..<500 {
      legacySettings.fontSize = Double(18 + index % 100)
      defaults.set(try JSONEncoder().encode(legacySettings), forKey: "settings")
      defaults.set(try JSONEncoder().encode(store.presets), forKey: "presets")
      defaults.set(try JSONEncoder().encode(EditorTypographyPreferences()), forKey: "editorTypography")
      defaults.set(store.uiZoom, forKey: "uiZoom")
      defaults.set(store.simpleInterface, forKey: "simpleInterface")
    }
    let legacyElapsed = legacyStart.duration(to: .now)
    let start = ContinuousClock.now
    for index in 0..<500 { store.settings.fontSize = Double(18 + index % 100) }
    let elapsed = start.duration(to: .now)
    print("SETTINGS_BENCHMARK slider_updates=500 presets=100 legacy_main_actor=\(legacyElapsed) debounced_main_actor=\(elapsed)")
    let saved = await store.flushPendingSaves()
    XCTAssertTrue(saved)
    let data = try XCTUnwrap(defaults.data(forKey: "settings"))
    XCTAssertEqual(try JSONDecoder().decode(PrompterSettings.self, from: data).fontSize, 117)
  }
  func testBurstCoalescesAndFlushWritesLatestSnapshotOffMainThread() async throws {
    let suite = "SettingsPersistence.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    defer { TestDefaults.remove(suite) }
    let log = WriteLog()
    let writer = SettingsPersistence(defaults: defaults, delay: 60, onWrite: { log.record() })
    var settings = PrompterSettings()
    for index in 0..<500 {
      settings.fontSize = Double(index)
      writer.schedule(SettingsSnapshot(settings: settings, presets: [settings],
        typography: EditorTypographyPreferences(previewFontSize: 23), uiZoom: 1.5, simpleInterface: false))
    }
    await writer.flush()
    XCTAssertEqual(log.count, 1)
    XCTAssertFalse(log.wroteOnMainThread)
    let final = try JSONDecoder().decode(PrompterSettings.self, from: XCTUnwrap(defaults.data(forKey: "settings")))
    XCTAssertEqual(final.fontSize, 120, "decoding retains its existing clamp")
    XCTAssertEqual(defaults.double(forKey: "uiZoom"), 1.5)
    XCTAssertFalse(defaults.bool(forKey: "simpleInterface"))
    let type = try JSONDecoder().decode(EditorTypographyPreferences.self, from: XCTUnwrap(defaults.data(forKey: "editorTypography")))
    XCTAssertEqual(type.previewFontSize, 23)
    await writer.flush()
    XCTAssertEqual(log.count, 1, "flushing twice does not repeat the write")
  }

  func testWritesAfterQuietPeriodWithoutExplicitFlush() async throws {
    let suite = "SettingsPersistence.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    defer { TestDefaults.remove(suite) }
    let log = WriteLog()
    let writer = SettingsPersistence(defaults: defaults, delay: 0.02, onWrite: { log.record() })
    writer.schedule(SettingsSnapshot(settings: PrompterSettings(), presets: [],
      typography: EditorTypographyPreferences(), uiZoom: 1.75, simpleInterface: true))
    for _ in 0..<100 where defaults.object(forKey: "uiZoom") == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(defaults.double(forKey: "uiZoom"), 1.75)
    await writer.flush()
    XCTAssertEqual(log.count, 1)
    XCTAssertFalse(log.wroteOnMainThread)
  }

  func testReleasingWriterFlushesBeforeItsDelayedWrite() async throws {
    let suite = "SettingsPersistence.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    defer { TestDefaults.remove(suite) }
    var writer: SettingsPersistence? = SettingsPersistence(defaults: defaults, delay: 60)
    weak var releasedWriter = writer
    writer?.schedule(SettingsSnapshot(settings: PrompterSettings(), presets: [],
      typography: EditorTypographyPreferences(), uiZoom: 1.25, simpleInterface: false))
    writer = nil
    // schedule briefly owns the writer until its serial queue has accepted the snapshot.
    for _ in 0..<100 where releasedWriter != nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(releasedWriter)
    for _ in 0..<100 where defaults.object(forKey: "uiZoom") == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(defaults.double(forKey: "uiZoom"), 1.25)
    TestDefaults.remove(suite)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(defaults.object(forKey: "uiZoom"), "Teardown must cancel delayed writes before fixture cleanup")
  }

  func testControlSettingsResponsesAreAlreadyPersisted() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-control-\(UUID())")
    let suite = "SettingsPersistence.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let camera = CameraModel(defaults: defaults)
    let actions = ControlActions(store: store, presenter: PresenterController(camera: camera),
      camera: camera, recorder: CameraRecorder(defaults: defaults))
    let commands: [(String, [String: String])] = [
      ("set_mode", ["mode": "manual"]), ("set_zoom", ["zoom": "150"]),
      ("settings_set", ["speed": "150"]), ("preset_save", ["name": "Saved", "requestId": "saved"]),
      ("settings_set", ["speed": "200"]), ("preset_apply", ["preset": "Saved"])
    ]
    for (action, params) in commands {
      let reply = await actions.handle(action, params)
      XCTAssertEqual(reply.body["ok"] as? Bool, true, action)
      let saved = try JSONDecoder().decode(PrompterSettings.self, from: XCTUnwrap(defaults.data(forKey: "settings")))
      XCTAssertEqual(saved, store.settings, "\(action) must commit before success")
      XCTAssertEqual(defaults.double(forKey: "uiZoom"), store.uiZoom)
      let presets = try JSONDecoder().decode([PrompterSettings].self, from: XCTUnwrap(defaults.data(forKey: "presets")))
      XCTAssertEqual(presets, store.presets)
    }
  }


  /// Every successful command flushes, so a settings change pending from elsewhere is on disk
  /// before even a read-only reply.
  func testReadOnlyControlResponseFlushesPendingSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-status-\(UUID())")
    let suite = "SettingsPersistence.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let camera = CameraModel(defaults: defaults)
    let actions = ControlActions(store: store, presenter: PresenterController(camera: camera),
      camera: camera, recorder: CameraRecorder(defaults: defaults))
    await store.waitForInitialLoad()
    await store.flushSettings()
    store.settings.speed = 222
    let reply = await actions.handle("status", [:])
    XCTAssertEqual(reply.body["ok"] as? Bool, true)
    let saved = try JSONDecoder().decode(PrompterSettings.self, from: XCTUnwrap(defaults.data(forKey: "settings")))
    XCTAssertEqual(saved.speed, 222, "status must not reply before pending settings are saved")
  }

}

/// Counts the writer's actual writes from its own queue.
private final class WriteLog: @unchecked Sendable {
  private let lock = NSLock()
  private var writes = 0
  private var onMain = false
  var count: Int { lock.withLock { writes } }
  var wroteOnMainThread: Bool { lock.withLock { onMain } }
  func record() {
    let main = Thread.isMainThread
    lock.withLock { writes += 1; onMain = onMain || main }
  }
}
