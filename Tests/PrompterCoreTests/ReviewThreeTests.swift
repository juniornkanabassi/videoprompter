import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class ReviewThreeTests: XCTestCase {
  private func fixture(defaults: UserDefaults? = nil) -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Review3-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = defaults ?? freshDefaults("Review3")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    store.settings.mode = "Manual"
    return (store, camera, recorder)
  }

  func testApplicationQuitRequiresDraftDecisionAndCancelPreservesText() async throws {
    let (store, camera, recorder) = fixture()
    _ = try await store.createScript(title: "Quit", markdown: "Original words")
    let presenter = PresenterController(camera: camera, recorder: recorder, frameDefaults: nil)
    presenter.present(store: store, activate: false)
    defer { presenter.closeNow() }
    let draft = try XCTUnwrap(presenter.draft)
    let delegate = AppDelegate(presenter: presenter)
    draft.begin(session: store.session)
    draft.markdown = "Typing that must survive Command Q"
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
    XCTAssertTrue(draft.closeRequested)
    XCTAssertEqual(draft.markdown, "Typing that must survive Command Q")
    draft.keepEditing()
    XCTAssertFalse(draft.closeRequested)
    XCTAssertTrue(draft.isEditing)
    XCTAssertEqual(draft.markdown, "Typing that must survive Command Q")
    var quitCount = 0
    XCTAssertFalse(presenter.prepareToQuit { quitCount += 1 })
    draft.discardAndClose()
    XCTAssertEqual(quitCount, 1)
    XCTAssertFalse(draft.isEditing)
    XCTAssertEqual(store.scripts.first?.markdown, "Original words")
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
  }

  func testSaveBeforeQuitPersistsTextAndFailedSaveKeepsDraftOpen() async throws {
    let (store, camera, recorder) = fixture()
    let record = try await store.createScript(title: "Save", markdown: "Original")
    let presenter = PresenterController(camera: camera, recorder: recorder, frameDefaults: nil)
    presenter.present(store: store, activate: false)
    defer { presenter.closeNow() }
    let draft = try XCTUnwrap(presenter.draft)
    draft.begin(session: store.session)
    draft.markdown = "Save before quitting"
    var quitCount = 0
    XCTAssertFalse(presenter.prepareToQuit { quitCount += 1 })
    await draft.saveAndClose(store: store)
    XCTAssertEqual(quitCount, 1)
    XCTAssertFalse(draft.isEditing)
    let saved = try await XCTUnwrap(store.library).read(record.id)
    XCTAssertEqual(saved.markdown, "Save before quitting")
    draft.begin(session: store.session)
    draft.markdown = "Keep this conflicted draft"
    store.scripts.removeAll { $0.id == record.id }
    XCTAssertFalse(presenter.prepareToQuit { quitCount += 1 })
    await draft.saveAndClose(store: store)
    XCTAssertEqual(quitCount, 1)
    XCTAssertTrue(draft.isEditing)
    XCTAssertEqual(draft.markdown, "Keep this conflicted draft")
    XCTAssertNotNil(draft.errorMessage)
    draft.cancel(resuming: false)
  }

  func testTypingDuringQuitSaveAndRepeatedQuitNeverLoseTheNewText() async throws {
    let (store, camera, recorder) = fixture()
    _ = try await store.createScript(title: "Pending", markdown: "Original")
    let presenter = PresenterController(camera: camera, recorder: recorder, frameDefaults: nil)
    presenter.present(store: store, activate: false)
    defer { presenter.closeNow() }
    let draft = try XCTUnwrap(presenter.draft)
    draft.begin(session: store.session)
    draft.markdown = "Submitted text"
    var quitCount = 0
    XCTAssertFalse(presenter.prepareToQuit { quitCount += 1 })
    var release: CheckedContinuation<Void, Never>?
    store.presenterSaveReservationGate = { await withCheckedContinuation { release = $0 } }
    let save = Task { await draft.saveAndClose(store: store) }
    for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
    guard let release else { XCTFail("Save never reached the gate"); return }
    draft.markdown = "New words during the save"
    XCTAssertEqual(AppDelegate(presenter: presenter).applicationShouldTerminate(NSApplication.shared), .terminateCancel)
    draft.discardAndClose()
    XCTAssertTrue(draft.isEditing)
    release.resume()
    await save.value
    store.presenterSaveReservationGate = nil
    XCTAssertEqual(quitCount, 0)
    XCTAssertTrue(draft.isEditing)
    XCTAssertEqual(draft.markdown, "New words during the save")
    XCTAssertEqual(store.scripts.first?.markdown, "Submitted text")
    draft.keepEditing()
    draft.cancel(resuming: false)
  }

  func testShootSetupNamesAreUniqueAndRenameDeleteSurviveReload() throws {
    let defaults = freshDefaults("SetupNames")
    let (store, camera, recorder) = fixture(defaults: defaults)
    XCTAssertTrue(store.saveShootSetup(named: "  Studio  ", camera: camera, recorder: recorder))
    let first = try XCTUnwrap(store.shootSetups.first)
    XCTAssertFalse(store.saveShootSetup(named: "studio", camera: camera, recorder: recorder))
    XCTAssertFalse(store.saveShootSetup(named: " \n ", camera: camera, recorder: recorder))
    XCTAssertEqual(store.shootSetups.count, 1)
    XCTAssertTrue(store.saveShootSetup(named: "Portrait", camera: camera, recorder: recorder))
    XCTAssertFalse(store.renameShootSetup(first.id, to: "PORTRAIT"))
    XCTAssertFalse(store.renameShootSetup(first.id, to: "  "))
    XCTAssertEqual(store.shootSetups.first?.name, "Studio")
    XCTAssertTrue(store.renameShootSetup(first.id, to: "  Desk  "))
    XCTAssertEqual(store.shootSetups.first?.id, first.id)
    let before = store.settings
    store.deleteShootSetup(first.id)
    let (reloaded, _, _) = fixture(defaults: defaults)
    XCTAssertEqual(reloaded.shootSetups.map(\.name), ["Portrait"])
    XCTAssertEqual(store.settings, before)
  }

  func testOlderShapeShootSetupsKeepKnownFieldsAndDefaultMissingOrUnknownFields() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "shoot-setup-legacy", withExtension: "json", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    let defaults = freshDefaults("LegacySetups")
    defaults.set(data, forKey: "shootSetups")
    let (store, _, _) = fixture(defaults: defaults)
    XCTAssertEqual(store.shootSetups.count, 2)
    let legacy = try XCTUnwrap(store.shootSetups.first)
    XCTAssertEqual(legacy.name, "Legacy portrait")
    XCTAssertEqual(legacy.reading.fontSize, 68)
    XCTAssertTrue(legacy.reading.horizontalMirror)
    XCTAssertTrue(legacy.guides.thirds)
    XCTAssertEqual(legacy.guides.rotation, .quarter)
    XCTAssertEqual(legacy.format, .standard)
    XCTAssertEqual(legacy.displayMode, .prompterOnly)
    XCTAssertNil(legacy.cameraUID); XCTAssertNil(legacy.microphoneUID)
    XCTAssertFalse(legacy.mirrored); XCTAssertFalse(legacy.mirrorSavedVideo)
    XCTAssertFalse(legacy.separateMicrophone); XCTAssertFalse(legacy.floatAudio)
    let (reloaded, _, _) = fixture(defaults: defaults)
    XCTAssertEqual(reloaded.shootSetups.map(\.id), store.shootSetups.map(\.id))
    XCTAssertEqual(reloaded.shootSetups.map(\.name), ["Legacy portrait", "Oldest setup"])
    XCTAssertThrowsError(try JSONDecoder().decode(ShootSetup.self, from: Data("{}".utf8)))
  }

  func testSetupRejectionIsVisibleOnPresenterWithoutLibraryOrSetupPopover() async throws {
    let (store, camera, recorder) = fixture()
    let record = try await store.createScript(title: "Presenter error", markdown: "Read these words")
    store.session.present(record: record, settings: store.settings)
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder))
    defer { LibraryAX.close(window) }
    store.saveShootSetup(named: "Unavailable", camera: camera, recorder: recorder)
    var setup = try XCTUnwrap(store.shootSetups.first)
    setup.cameraUID = "missing-device"
    XCTAssertFalse(store.applyShootSetup(setup, camera: camera, recorder: recorder))
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let error = try XCTUnwrap(store.shootSetupError)
    XCTAssertFalse(LibraryAX.named(error, in: host).isEmpty, "The actual error text must be visible without opening another popover")
    let dismiss = try XCTUnwrap(LibraryAX.named("Dismiss shoot setup message", in: host).first)
    XCTAssertTrue(LibraryAX.bool(dismiss, "accessibilityPerformPress"))
    XCTAssertNil(store.shootSetupError)
  }

  func testCameraSelectionRefreshesAnEmptyInventoryWithoutStartingCapture() async throws {
    let (store, camera, recorder) = fixture()
    guard let connected = CameraModel.discovered().first else { throw XCTSkip("No connected camera to list") }
    XCTAssertTrue(camera.devices.isEmpty)
    let actions = ControlActions(store: store, camera: camera, recorder: recorder)
    let result = await actions.handle("camera_select", ["camera": connected.uid])
    XCTAssertEqual(result.body["ok"] as? Bool, true)
    XCTAssertEqual(camera.selectedUID, connected.uid)
    XCTAssertTrue(camera.devices.contains { $0.uid == connected.uid })
  }
}

extension AppearanceSnapshotTests {
  func testReviewThreeShootSetupManagement() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Review3Snapshots-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Review3Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    store.saveShootSetup(named: "Studio camera and voice", camera: camera, recorder: recorder)
    store.saveShootSetup(named: "Portrait recording", camera: camera, recorder: recorder)
    store.shootSetups[0].cameraUID = "disconnected-camera"
    _ = store.applyShootSetup(store.shootSetups[0], camera: camera, recorder: recorder)
    let record = try await store.createScript(title: "Setup not applied", markdown: "These words stay unchanged when a saved setup cannot be applied.")
    store.session.present(record: record, settings: store.settings)
    let scheme: ColorScheme = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      try await snapshot(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), name: "review3-presenter-error-\(Int(zoom * 100))-\(scheme == .dark ? "dark" : "light")", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
      try await snapshot(Form { ShootSetupSection(store: store, camera: camera, recorder: recorder) }.formStyle(.grouped).uiZoom(zoom), name: "review3-shoot-setups-\(Int(zoom * 100))-\(scheme == .dark ? "dark" : "light")", size: .init(width: 520 * zoom, height: 530 * zoom), scheme: scheme, destination: URL(fileURLWithPath: output))
    }
  }
}
