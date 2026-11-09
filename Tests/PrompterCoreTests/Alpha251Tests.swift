import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class Alpha251Tests: XCTestCase {
  func testMicMigrationOpenerAndKeyPersistence() async throws {
    for legacy in [nil, false] as [Bool?] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Alpha251")
    if let legacy { defaults.set(legacy, forKey: "presenterMicLevel") }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .videoOnly
    camera.guides.falseColour = true
    let recorder = CameraRecorder(defaults: defaults)
    let shell = PresenterShell()
    func view() -> some View {
      PresenterView(store: store, session: store.session, draft: PresenterDraft(), hasScript: false,
                    camera: camera, startsCamera: false, recorder: recorder, shell: shell).defaultAppStorage(defaults)
    }
    let (window, host) = await LibraryAX.host(view(), size: .init(width: 1600, height: 1000))
    XCTAssertFalse(LibraryAX.named("Open script", in: host).isEmpty)
    let mic = try XCTUnwrap(LibraryAX.named("Mic", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
    XCTAssertEqual(LibraryAX.value(mic, "accessibilityValue"), recorder.microphoneName)
    XCTAssertFalse(LibraryAX.named("Hide key", in: host).isEmpty)
    let hide = try XCTUnwrap(LibraryAX.named("Hide key", in: host).first)
    XCTAssertTrue(LibraryAX.bool(hide, "accessibilityPerformPress"))
    XCTAssertFalse(defaults.bool(forKey: "presenterExposureKeyExpanded"))
    XCTAssertTrue(LibraryAX.bool(mic, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(shell.adjustTab, .mic)
    let meter = try XCTUnwrap(LibraryAX.elements(host).first { LibraryAX.value($0, "accessibilityIdentifier") == "show-mic-meter" && ["AXCheckBox", "AXSwitch"].contains(LibraryAX.value($0, "accessibilityRole")) })
    XCTAssertEqual((meter.value(forKey: "accessibilityValue") as? NSNumber)?.intValue, 1, "Old off preference must migrate to on")
    _ = LibraryAX.bool(meter, "accessibilityPerformPress")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(defaults.object(forKey: "presenterMicLevel251") as? Bool, false)
    LibraryAX.close(window)
    shell.adjustTab = nil
    let (reopened, nextHost) = await LibraryAX.host(view(), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(reopened) }
    XCTAssertFalse(LibraryAX.named("Show key", in: nextHost).isEmpty)
    XCTAssertTrue(LibraryAX.named("Hide key", in: nextHost).isEmpty)
    shell.reading = true
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(LibraryAX.named("Open script", in: nextHost).isEmpty)
    let readingKey = try XCTUnwrap(LibraryAX.named("Show key", in: nextHost).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
    XCTAssertTrue(LibraryAX.bool(readingKey, "accessibilityPerformPress"))
    XCTAssertTrue(defaults.bool(forKey: "presenterExposureKeyExpanded"))
    camera.cleanView = true
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(LibraryAX.named("Open script", in: nextHost).isEmpty)
  }

  }

  func testSelectingCurrentMicrophoneKeepsMeterRunning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Alpha251SameMic")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    store.settings.audioDeviceUID = nil
    let recorder = CameraRecorder(defaults: defaults)
    recorder.inputMeter.show(peakDBFS: -12, isClipping: false)
    let view = AdjustPanel(selection: .constant(.mic), showsMic: .constant(true), camera: CameraModel(defaults: defaults),
      store: store, startsMeter: false, recorder: recorder)
    let (window, host) = await LibraryAX.host(view)
    defer { LibraryAX.close(window) }
    let current = try XCTUnwrap(LibraryAX.named("System default", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
    XCTAssertTrue(LibraryAX.bool(current, "accessibilityPerformPress"))
    XCTAssertEqual(recorder.inputMeter.peakDBFS, -12)
  }

  func testOpenScriptKeepsPresenterAndSelectsCurrentScript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Alpha251Script")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Current", markdown: "Current words")
    store.session.present(record: record, settings: store.settings)
    let other = try await store.createScript(title: "Other", markdown: "Other words")
    XCTAssertEqual(store.selectedID, other.id)
    let controller = PresenterController(camera: CameraModel(defaults: defaults), recorder: CameraRecorder(defaults: defaults), frameDefaults: defaults)
    var reveals = 0
    controller.openScript(store: store, reveal: { reveals += 1 })
    XCTAssertEqual(reveals, 1)
    XCTAssertEqual(store.selectedID, record.id)
    XCTAssertEqual(store.session.activeRecord?.id, record.id)
    XCTAssertEqual(store.editorScriptRequest, record.id)
    let (window, _) = await LibraryAX.host(LibraryView(store: store), size: .init(width: 1100, height: 752))
    defer { LibraryAX.close(window) }
    XCTAssertNil(store.editorScriptRequest)
    XCTAssertEqual(store.selectedID, record.id)
    controller.openScript(store: store, reveal: { reveals += 1 })
    XCTAssertEqual(reveals, 2)
  }
}

extension AppearanceSnapshotTests {
  func testAlpha251Snapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Alpha251Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .videoOnly
    camera.guides.falseColour = true
    let recorder = CameraRecorder(defaults: defaults)
    let picture = NSImage(contentsOf: Bundle.module.url(forResource: "presenter-clean", withExtension: "png", subdirectory: "Fixtures")!)
    for state in ["key-shown", "key-collapsed", "adjust-mic"] {
      defaults.set(state != "key-collapsed", forKey: "presenterExposureKeyExpanded")
      let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(), hasScript: false,
        camera: camera, startsCamera: false, recorder: recorder,
        shell: PresenterShell(adjustTab: state == "adjust-mic" ? .mic : nil), referencePicture: picture).defaultAppStorage(defaults)
      try await snapshot(view, name: "alpha-251-\(state)", size: .init(width: 1600, height: 1000), scheme: .dark, destination: URL(fileURLWithPath: output), settleDelay: .milliseconds(500))
    }
  }
}
