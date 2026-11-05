import Foundation
import XCTest
@testable import VideoPrompter

@MainActor final class SettingsPersistenceTests: XCTestCase {
  func testSliderBurstPerformance() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/bama/build-prompter/settings-\(UUID())")
    let suite = "SettingsPersistence.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
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
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let writer = SettingsPersistence(defaults: defaults, delay: 60)
    var settings = PrompterSettings()
    for index in 0..<500 {
      settings.fontSize = Double(index)
      writer.schedule(SettingsSnapshot(settings: settings, presets: [settings],
        typography: EditorTypographyPreferences(previewFontSize: 23), uiZoom: 1.5, simpleInterface: false))
    }
    let result = await writer.flush()
    XCTAssertEqual(result.writes, 1)
    XCTAssertFalse(result.wroteOnMainThread)
    let final = try JSONDecoder().decode(PrompterSettings.self, from: XCTUnwrap(defaults.data(forKey: "settings")))
    XCTAssertEqual(final.fontSize, 120, "decoding retains its existing clamp")
    XCTAssertEqual(defaults.double(forKey: "uiZoom"), 1.5)
    XCTAssertFalse(defaults.bool(forKey: "simpleInterface"))
    let type = try JSONDecoder().decode(EditorTypographyPreferences.self, from: XCTUnwrap(defaults.data(forKey: "editorTypography")))
    XCTAssertEqual(type.previewFontSize, 23)
    let emptyFlush = await writer.flush()
    XCTAssertEqual(emptyFlush.writes, 1, "flushing twice does not repeat the write")
  }

  func testWritesAfterQuietPeriodWithoutExplicitFlush() async throws {
    let suite = "SettingsPersistence.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let writer = SettingsPersistence(defaults: defaults, delay: 0.02)
    writer.schedule(SettingsSnapshot(settings: PrompterSettings(), presets: [],
      typography: EditorTypographyPreferences(), uiZoom: 1.75, simpleInterface: true))
    for _ in 0..<100 where defaults.object(forKey: "uiZoom") == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(defaults.double(forKey: "uiZoom"), 1.75)
    let result = await writer.flush()
    XCTAssertEqual(result.writes, 1)
    XCTAssertFalse(result.wroteOnMainThread)
  }
}
