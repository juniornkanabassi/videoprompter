import AppKit
@preconcurrency import AVFoundation
import Darwin
import PrompterCore
import XCTest
@testable import VideoPrompter

@MainActor final class ControlTests: XCTestCase {
  func testActionsUseGUIStoreAndImportIsIdempotent() async throws {
    _ = NSApplication.shared
    OffscreenPanels.install(); defer { OffscreenPanels.uninstall() }
    let root = URL(fileURLWithPath: "/private/tmp/vpc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "ControlTests.\(UUID())")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await store.reload()
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterOnly
    let presenter = PresenterController(camera: camera)
    defer { presenter.closeNow() }
    // Own camera and recorder models, so no command here writes the shared preferences.
    let actions = ControlActions(store: store, presenter: presenter, camera: camera, recorder: CameraRecorder(defaults: defaults))
    for action in ["pause", "resume", "back_to_start"] {
      let reply = await actions.handle(action, [:])
      XCTAssertEqual((reply.body["error"] as? [String: String])?["code"], "no_active_script")
    }
    let file = root.deletingLastPathComponent().appendingPathComponent("import-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: file) }
    let failedImport = await actions.handle("script_import", ["path": file.path, "requestId": "one"])
    XCTAssertEqual(failedImport.body["ok"] as? Bool, false)
    try "# Hello\n\nOne two three.".write(to: file, atomically: true, encoding: .utf8)
    async let first = actions.handle("script_import", ["path": file.path, "requestId": "one"])
    async let second = actions.handle("script_import", ["path": file.path, "requestId": "one"])
    let replies = await [first, second]
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertEqual(store.selectedID, store.scripts.first?.id)
    XCTAssertEqual(replies.compactMap { ($0.body["result"] as? [String: Any])?["repeated"] as? Bool }.filter { $0 }.count, 1)
    XCTAssertNotNil(store.scripts.first?.metadata.linkedPath)
    let id = try XCTUnwrap(store.selectedID).uuidString
    let title = store.scripts[0].metadata.title
    let reply1 = (await actions.handle("script_open", ["script": title]))
    XCTAssertEqual(reply1.body["ok"] as? Bool, true)
    let reply2 = (await actions.handle("script_open", ["script": id]))
    XCTAssertEqual(reply2.body["ok"] as? Bool, true)
    let reply3 = (await actions.handle("script_list", [:]))
    XCTAssertEqual(reply3.body["ok"] as? Bool, true)
    _ = await actions.handle("set_mode", ["mode": "manual"])
    XCTAssertEqual(store.settings.mode, "Manual")
    _ = await actions.handle("set_zoom", ["zoom": "150"])
    XCTAssertEqual(store.uiZoom, 1.5)
    let reply4 = (await actions.handle("set_zoom", ["zoom": "130"]))
    XCTAssertEqual(reply4.body["ok"] as? Bool, false)
    do {
      _ = await actions.handle("present", ["script": id])
      XCTAssertEqual(store.session.activeScriptID?.uuidString, id)
      XCTAssertEqual(OffscreenPanels.activations, 0)
      _ = await actions.handle("present", ["script": id, "show": "true"])
      XCTAssertGreaterThan(OffscreenPanels.activations, 0)
    }
    store.session.present(record: store.scripts[0], settings: store.settings)
    store.session.seek(to: 2)
    presenter.closeNow()
    let savedPosition = store.session.tokenIndex
    for action in ["pause", "resume", "back_to_start"] {
      let reply = await actions.handle(action, [:])
      XCTAssertEqual((reply.body["error"] as? [String: String])?["code"], "no_active_script")
      XCTAssertEqual(store.session.tokenIndex, savedPosition)
    }
    let status = (await actions.handle("status", [:])).body["result"] as? [String: Any]
    for key in ["running", "app", "version", "library", "scripts", "selected", "presenter", "script", "state", "mode", "position", "zoom", "textSize", "speed", "camera", "recording"] { XCTAssertNotNil(status?[key]) }
    _ = try await store.createScript(title: title.uppercased(), markdown: "duplicate")
    let reply5 = (await actions.handle("script_open", ["script": title]))
    XCTAssertEqual((reply5.body["error"] as? [String: Any])?["code"] as? String, "ambiguous_script")
    let reply6 = (await actions.handle("script_open", ["script": "absent"]))
    XCTAssertEqual((reply6.body["error"] as? [String: Any])?["code"] as? String, "script_not_found")
    for command in ControlProtocol.commands {
      let reply7 = (await actions.handle(command.action, [:]))
      XCTAssertNotEqual((reply7.body["error"] as? [String: Any])?["code"] as? String, "unknown_action")
    }
  }
  func testLibrarySettingsCameraAndRecordingActions() async throws {
    _ = NSApplication.shared
    OffscreenPanels.install(); defer { OffscreenPanels.uninstall() }
    let root = URL(fileURLWithPath: "/private/tmp/vpc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "ControlTests.\(UUID())")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await store.reload()
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterOnly
    let presenter = PresenterController(camera: camera)
    defer { presenter.closeNow() }
    let recorder = CameraRecorder(defaults: defaults)
    let actions = ControlActions(store: store, presenter: presenter, camera: camera, recorder: recorder)
    func code(_ reply: ControlResult) -> String? { (reply.body["error"] as? [String: Any])?["code"] as? String }
    func value(_ reply: ControlResult) -> [String: Any] { reply.body["result"] as? [String: Any] ?? [:] }
    let markdown = "# Intro\n\nOne two three four five six.\n\nSeven eight nine ten.\n\nEleven twelve thirteen.\n\nFourteen fifteen sixteen."

    // Creation acts once per request id, even for overlapping retries, and selects the new script.
    async let first = actions.handle("script_create", ["text": markdown, "title": "Intro", "requestId": "c1"])
    async let second = actions.handle("script_create", ["text": markdown, "title": "Intro", "requestId": "c1"])
    let created = await [first, second]
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertEqual(created.compactMap { value($0)["repeated"] as? Bool }.sorted { !$0 && $1 }, [false, true])
    let id = try XCTUnwrap(value(created[0])["id"] as? String)
    XCTAssertEqual(store.selectedID?.uuidString, id)
    let read = await actions.handle("script_read", ["script": "intro"])
    XCTAssertEqual(value(read)["markdown"] as? String, markdown)

    // Rename, tags, folders and move go through the library and show in the store.
    _ = await actions.handle("script_rename", ["script": id, "title": "Launch"])
    XCTAssertEqual(store.scripts.first?.metadata.title, "Launch")
    let reply1 = await actions.handle("script_rename", ["script": id, "title": "  "])
    XCTAssertEqual(code(reply1), "invalid_params")
    _ = await actions.handle("script_tag", ["script": "Launch", "tags": "b, a"])
    XCTAssertEqual(store.scripts.first?.metadata.tags, ["a", "b"])
    _ = await actions.handle("script_tag", ["script": "Launch", "tags": "none"])
    XCTAssertEqual(store.scripts.first?.metadata.tags, [])
    _ = await actions.handle("folder_create", ["name": "Drafts", "requestId": "f1"])
    let again = await actions.handle("folder_create", ["name": "Drafts", "requestId": "f1"])
    XCTAssertEqual(value(again)["repeated"] as? Bool, true)
    XCTAssertEqual(store.folders.count, 1)
    _ = await actions.handle("script_move", ["script": id, "folder": "drafts"])
    XCTAssertEqual(store.scripts.first?.metadata.folderID, store.folders.first?.id)
    _ = await actions.handle("folder_rename", ["folder": "Drafts", "name": "In progress"])
    XCTAssertEqual(store.folders.first?.name, "In progress")
    _ = await actions.handle("script_move", ["script": id, "folder": "none"])
    XCTAssertNil(store.scripts.first?.metadata.folderID)
    let reply2 = await actions.handle("script_move", ["script": id, "folder": "Absent"])
    XCTAssertEqual(code(reply2), "folder_not_found")

    // Export never replaces a file unless asked.
    let exported = root.appendingPathComponent("export.md")
    _ = await actions.handle("script_export", ["script": id, "path": exported.path])
    XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), markdown)
    let reply3 = await actions.handle("script_export", ["script": id, "path": exported.path])
    XCTAssertEqual(code(reply3), "file_exists")
    let unconfirmed = await actions.handle("script_export", ["script": id, "path": exported.path, "replace": "true"])
    XCTAssertEqual(code(unconfirmed), "confirmation_required")
    let declined = await actions.handle("script_export", ["script": id, "path": exported.path, "replace": "true", "yes": "false"])
    XCTAssertEqual(code(declined), "confirmation_required")
    let replaced = await actions.handle("script_export", ["script": id, "path": exported.path, "replace": "true", "yes": "true"])
    XCTAssertEqual(replaced.body["ok"] as? Bool, true)

    // Settings change the same values the Settings panel binds to, all or nothing.
    _ = await actions.handle("settings_set", ["speed": "150", "textSize": "60", "mirror": "on", "alignment": "centre", "textColour": "#ff0000", "readingLine": "40"])
    XCTAssertEqual(store.settings.speed, 150); XCTAssertEqual(store.settings.fontSize, 60)
    XCTAssertTrue(store.settings.horizontalMirror); XCTAssertEqual(store.settings.alignment, "Center")
    XCTAssertEqual(store.settings.textColorHex, "#FF0000"); XCTAssertEqual(store.settings.guideFraction, 0.4, accuracy: 0.001)
    let reply4 = await actions.handle("settings_set", ["speed": "200", "textColour": "red"])
    XCTAssertEqual(code(reply4), "invalid_params")
    XCTAssertEqual(store.settings.speed, 150)
    for bad in [[:], ["speed": "301"], ["mirror": "yes"], ["font": "Comic Sans Nonexistent"]] {
      let reply5 = await actions.handle("settings_set", bad)
      XCTAssertEqual(code(reply5), "invalid_params", "\(bad)")
    }
    let reply6 = await actions.handle("settings_get", [:])
    XCTAssertEqual(value(reply6)["speed"] as? Int, 150)
    let reply7 = await actions.handle("status", [:])
    XCTAssertEqual(value(reply7)["speed"] as? Int, 150)

    // Saved settings round trip.
    _ = await actions.handle("preset_save", ["name": "Studio", "requestId": "p1"])
    _ = await actions.handle("preset_save", ["name": "Studio", "requestId": "p1"])
    XCTAssertEqual(store.presets.count, 1)
    _ = await actions.handle("settings_set", ["speed": "200"])
    _ = await actions.handle("preset_apply", ["preset": "studio"])
    XCTAssertEqual(store.settings.speed, 150)

    // Reading position commands need a visible presenter, as pause and resume do.
    let reply8 = await actions.handle("presenter_close", [:])
    XCTAssertEqual(value(reply8)["changed"] as? Bool, false)
    for action in ["next_passage", "previous_passage"] {
      let reply9 = await actions.handle(action, [:])
      XCTAssertEqual(code(reply9), "no_active_script")
    }
    let reply10 = await actions.handle("seek", ["word": "2"])
    XCTAssertEqual(code(reply10), "no_active_script")
    do {
      camera.displayMode = .prompterOnly
      _ = await actions.handle("present", ["script": id])
      let seek = await actions.handle("seek", ["word": "3"])
      XCTAssertEqual((value(seek)["position"] as? [String: Int])?["word"], 3)
      let nextReply = await actions.handle("next_passage", ["requestId": "n1"])
      let repeatedNext = await actions.handle("next_passage", ["requestId": "n1"])
      XCTAssertEqual(value(repeatedNext)["repeated"] as? Bool, true)
      XCTAssertEqual(value(repeatedNext)["position"] as? [String: Int], value(nextReply)["position"] as? [String: Int])
      let next = (value(nextReply)["position"] as? [String: Int])?["word"] ?? 0
      XCTAssertGreaterThan(next, 3)
      let previousReply = await actions.handle("previous_passage", ["requestId": "p1"])
      let repeatedPrevious = await actions.handle("previous_passage", ["requestId": "p1"])
      XCTAssertEqual(value(repeatedPrevious)["repeated"] as? Bool, true)
      XCTAssertEqual(value(repeatedPrevious)["position"] as? [String: Int], value(previousReply)["position"] as? [String: Int])
      let previous = (value(previousReply)["position"] as? [String: Int])?["word"] ?? .max
      XCTAssertLessThan(previous, next)
      let reply11 = await actions.handle("seek", ["word": "999"])
      XCTAssertEqual(code(reply11), "invalid_params")
      let reply12 = await actions.handle("script_delete", ["script": id, "yes": "true"])
      XCTAssertEqual(code(reply12), "script_presented")
      let reply13 = await actions.handle("presenter_close", [:])
      XCTAssertEqual(value(reply13)["changed"] as? Bool, true)
      XCTAssertNotEqual(presenter.panel?.isVisible, true)
    }

    // Delete needs --yes, moves to Recently Deleted, and restore brings the script back.
    let reply14 = await actions.handle("script_delete", ["script": id])
    XCTAssertEqual(code(reply14), "invalid_params")
    let reply15 = await actions.handle("script_delete", ["script": id, "yes": "false"])
    XCTAssertEqual(code(reply15), "confirmation_required")
    presenter.closeNow()
    _ = await actions.handle("script_delete", ["script": id, "yes": "true"])
    XCTAssertTrue(store.scripts.isEmpty)
    let reply16 = await actions.handle("script_trash", [:])
    XCTAssertEqual((value(reply16)["scripts"] as? [[String: Any]])?.count, 1)
    _ = await actions.handle("script_restore", ["script": "Launch"])
    XCTAssertEqual(store.scripts.map(\.id.uuidString), [id])
    let copy = await actions.handle("script_duplicate", ["script": id, "requestId": "d1"])
    _ = await actions.handle("script_duplicate", ["script": id, "requestId": "d1"])
    XCTAssertEqual(store.scripts.count, 2)
    XCTAssertEqual(store.selectedID?.uuidString, value(copy)["id"] as? String)

    // Camera display, mirroring, rotation and guides change the shared camera model.
    let reply17 = await actions.handle("camera_set", [:])
    XCTAssertEqual(code(reply17), "invalid_params")
    _ = await actions.handle("camera_set", ["view": "off", "mirror": "on", "rotation": "90"])
    XCTAssertEqual(camera.displayMode, .prompterOnly); XCTAssertTrue(camera.mirrored); XCTAssertEqual(camera.guides.rotation, .quarter)
    _ = await actions.handle("camera_set", ["rotation": "auto"])
    XCTAssertTrue(camera.guides.automaticRotation)
    _ = await actions.handle("camera_guides", ["thirds": "on", "marker": "9:16", "colour": "#00ff00", "visibility": "50"])
    XCTAssertTrue(camera.guides.thirds); XCTAssertEqual(camera.guides.marker, CameraAspect(width: 9, height: 16))
    XCTAssertEqual(camera.guides.colorHex, "#00FF00"); XCTAssertEqual(camera.guides.opacity, 0.5, accuracy: 0.001)
    let reply18 = await actions.handle("camera_guides", ["marker": "wide", "thirds": "off"])
    XCTAssertEqual(code(reply18), "invalid_params")
    XCTAssertTrue(camera.guides.thirds)
    _ = await actions.handle("camera_guides", ["marker": "off"])
    XCTAssertNil(camera.guides.marker)

    // Recording needs --yes and a showing camera; it never raises a permission prompt.
    let reply19 = await actions.handle("record_start", [:])
    XCTAssertEqual(code(reply19), "invalid_params")
    let reply20 = await actions.handle("record_start", ["yes": "false"])
    XCTAssertEqual(code(reply20), "confirmation_required")
    let start = await actions.handle("record_start", ["yes": "true"])
    XCTAssertTrue(["permission_required", "camera_not_showing"].contains(code(start) ?? ""), "\(start.body)")
    XCTAssertFalse(recorder.isRecording)
    let reply21 = await actions.handle("record_stop", [:])
    XCTAssertEqual(code(reply21), "not_recording")
    _ = await actions.handle("record_set", ["quality": "high", "floatAudio": "on"])
    XCTAssertEqual(recorder.preset, .high); XCTAssertTrue(recorder.floatAudio)
    let statusReply = await actions.handle("status", [:])
    let status = value(statusReply)
    XCTAssertEqual((status["recording"] as? [String: Any])?["quality"] as? String, "high")
    XCTAssertEqual((status["camera"] as? [String: Any])?["view"] as? String, "off")
  }
  func testCreateInFolderIsRetrySafeAndPersists() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "ControlTests.\(UUID())")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await store.waitForInitialLoad()
    let folder = try await store.createLibraryFolder(named: "Drafts")
    let camera = CameraModel(defaults: defaults)
    let actions = ControlActions(store: store, presenter: PresenterController(camera: camera), camera: camera, recorder: CameraRecorder(defaults: defaults))
    let params = ["title": "Folder script", "text": "one two", "folder": folder.id.uuidString, "requestId": "folder-script"]
    async let first = actions.handle("script_create", params)
    async let second = actions.handle("script_create", params)
    let results = await [first, second]
    XCTAssertTrue(results.allSatisfy { $0.body["ok"] as? Bool == true })
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertEqual(store.selectedFolderID, folder.id)
    XCTAssertEqual(store.selected?.metadata.folderID, folder.id)
    await store.reload()
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertEqual(store.scripts.first?.metadata.folderID, folder.id)
  }

  func testDeleteRechecksPresenterAfterSaving() async throws {
    _ = NSApplication.shared
    OffscreenPanels.install(); defer { OffscreenPanels.uninstall() }
    let root = URL(fileURLWithPath: "/private/tmp/vpc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "ControlTests.\(UUID())")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.createScript(title: "Read", markdown: "one two")
    store.settings.mode = "Manual"
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterOnly
    let presenter = PresenterController(camera: camera)
    defer { presenter.closeNow() }
    let actions = ControlActions(store: store, presenter: presenter, camera: camera, recorder: CameraRecorder(defaults: defaults))
    store.saveGate = { presenter.present(store: store, activate: false) }
    store.updateMarkdown("one two three", for: record.id)
    let result = await actions.handle("script_delete", ["script": record.id.uuidString, "yes": "true"])
    XCTAssertEqual((result.body["error"] as? [String: Any])?["code"] as? String, "script_presented")
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertTrue(store.trash.isEmpty)
  }

  func testVoiceSettingsDoNotRequestPermission() async throws {
    _ = NSApplication.shared
    OffscreenPanels.install(); defer { OffscreenPanels.uninstall() }
    let root = URL(fileURLWithPath: "/private/tmp/vpc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "ControlTests.\(UUID())")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    _ = try await store.createScript(title: "Read", markdown: "one two")
    store.settings.mode = "Manual"
    var preset = store.settings; preset.mode = "Voice"; preset.name = "Voice preset"
    store.presets = [preset]
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterOnly
    let presenter = PresenterController(camera: camera)
    defer { presenter.closeNow() }
    presenter.present(store: store, activate: false)
    for (authorization, expected) in [(AVAuthorizationStatus.notDetermined, "permission_required"), (.denied, "microphone_denied"), (.restricted, "microphone_denied")] {
      let actions = ControlActions(store: store, presenter: presenter, camera: camera, recorder: CameraRecorder(defaults: defaults), audioAuthorization: { authorization })
      for (action, params) in [("set_mode", ["mode": "voice"]), ("preset_apply", ["preset": preset.id.uuidString])] {
        let result = await actions.handle(action, params)
        XCTAssertEqual((result.body["error"] as? [String: Any])?["code"] as? String, expected)
        XCTAssertEqual(store.settings.mode, "Manual")
      }
      // A settings update can restart an existing Voice session too.
      presenter.closeNow()
      store.settings.mode = "Voice"
      presenter.present(store: store, activate: false)
      let oldSpeed = store.settings.speed
      let result = await actions.handle("settings_set", ["speed": "201"])
      XCTAssertEqual((result.body["error"] as? [String: Any])?["code"] as? String, expected)
      XCTAssertEqual(store.settings.speed, oldSpeed)
      presenter.closeNow()
      store.settings.mode = "Manual"
      presenter.present(store: store, activate: false)
    }
    XCTAssertNil(ControlActions.voicePermissionError(authorization: .authorized))
  }

  func testCameraChangesRefuseActiveOrBusyRecording() {
    for (recording, busy) in [(true, false), (false, true), (true, true)] {
      let result = ControlActions.cameraChangeError(recording: recording, busy: busy)
      XCTAssertEqual((result?.body["error"] as? [String: Any])?["code"] as? String, "recording_active")
    }
    XCTAssertNil(ControlActions.cameraChangeError(recording: false, busy: false))
  }

  func testRecordingStopRequiresMatchingIDOrForce() {
    let id = UUID()
    for requested in [nil, UUID().uuidString] {
      let result = ControlActions.recordingStopError(recordingID: id, requested: requested, force: false)
      XCTAssertEqual((result?.body["error"] as? [String: Any])?["code"] as? String, "recording_owned")
    }
    XCTAssertNil(ControlActions.recordingStopError(recordingID: id, requested: id.uuidString, force: false))
    XCTAssertNil(ControlActions.recordingStopError(recordingID: id, requested: nil, force: true))
    XCTAssertNotNil(ControlActions.recordingStopError(recordingID: nil, requested: nil, force: false))
  }

  func testReplyOver64KBIsComplete() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpc-\(UUID().uuidString.prefix(8))")
    let path = root.appendingPathComponent("control.sock")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = ControlServer(socketURL: path) { action, _ in .ok(["payload": String(repeating: "x", count: 100_000)]) }
    try server.start(); defer { server.stop() }
    let responses = try await Task.detached {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
      var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.path.utf8) + [0]) }
      let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
      let bytes = Data("{\"id\":\"2\",\"action\":\"status\"}\n".utf8)
      _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
      var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
      while result.filter({ $0 == 10 }).count < 1 {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw CocoaError(.fileReadUnknown) }; result.append(contentsOf: buffer.prefix(n))
      }
      return result
    }.value
    let lines = try responses.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    XCTAssertGreaterThan(responses.count, 65_536)
    XCTAssertEqual((lines[0]["result"] as? [String: String])?["payload"], String(repeating: "x", count: 100_000))
  }
  func testSocketPrivacyFramingAndOwnership() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpc-\(UUID().uuidString.prefix(8))")
    let path = root.appendingPathComponent("control.sock")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = ControlServer(socketURL: path) { action, _ in .ok(["action": action]) }
    try server.start(); defer { server.stop() }
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let other = ControlServer(socketURL: path) { _, _ in .ok([:]) }
    XCTAssertThrowsError(try other.start())
    other.stop()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    let responses = try await Task.detached {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
      var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.path.utf8) + [0]) }
      let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
      let bytes = Data("bad json\n{\"id\":\"2\",\"action\":\"status\"}\n".utf8)
      _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
      var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
      while result.filter({ $0 == 10 }).count < 2 {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw CocoaError(.fileReadUnknown) }; result.append(contentsOf: buffer.prefix(n))
      }
      return result
    }.value
    let lines = try responses.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    XCTAssertEqual((lines[0]["error"] as? [String: String])?["code"], "bad_request")
    XCTAssertEqual(lines[1]["id"] as? String, "2")
    server.stop()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.path.utf8) + [0]) }
    XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
    Darwin.close(fd)
    try server.start()
    server.stop()
    try "leave me".write(to: path, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try server.start())
    XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "leave me")
  }
  func testIdleClientsExpireWithoutDroppingSlowWork() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpc-\(UUID().uuidString.prefix(8))")
    let path = root.appendingPathComponent("control.sock").path
    defer { try? FileManager.default.removeItem(at: root) }
    let server = ControlServer(socketURL: URL(fileURLWithPath: path), idleTimeout: .milliseconds(800)) { action, _ in
      if action == "slow" { try? await Task.sleep(for: .milliseconds(2000)) }
      return .ok(["action": action])
    }
    try server.start(); defer { server.stop() }
    @Sendable func client() throws -> Int32 {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      var yes: Int32 = 1; var timeout = timeval(tv_sec: 6, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
      let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      guard connected == 0 else { Darwin.close(fd); throw CocoaError(.fileReadUnknown) }
      return fd
    }
    @Sendable func write(_ fd: Int32, _ text: String) { _ = Data(text.utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) } }
    // One reply line; empty on server EOF, nil on error or receive timeout.
    @Sendable func reply(_ fd: Int32) -> Data? {
      var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
      while !result.contains(10) {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n == 0 { return result }
        guard n > 0 else { return nil }; result.append(contentsOf: buffer.prefix(n))
      }
      return result
    }
    let outcome = try await Task.detached { () throws -> [String] in
      var log: [String] = []
      let idle = try (0..<8).map { _ in try client() }
      defer { idle.forEach { Darwin.close($0) } }
      usleep(200_000)
      let ninth = try client(); defer { Darwin.close(ninth) }
      write(ninth, "{\"id\":\"9\",\"action\":\"status\"}\n")
      log.append("full:\(!(reply(ninth)?.contains(10) ?? false))")
      log.append("expired:\(idle.allSatisfy { reply($0)?.isEmpty == true })")
      let fresh = try client(); defer { Darwin.close(fresh) }
      write(fresh, "{\"id\":\"1\",\"action\":\"status\"}\n")
      log.append(String(decoding: reply(fresh) ?? Data(), as: UTF8.self))
      let trickle = try client(); defer { Darwin.close(trickle) }
      for part in ["{\"id\":\"2\",", "\"action\":", "\"status\"", "}"] { write(trickle, part); usleep(500_000) }
      write(trickle, "\n")
      log.append(String(decoding: reply(trickle) ?? Data(), as: UTF8.self))
      let slow = try client(); defer { Darwin.close(slow) }
      write(slow, "{\"id\":\"3\",\"action\":\"slow\"}\n")
      log.append(String(decoding: reply(slow) ?? Data(), as: UTF8.self))
      let start = ContinuousClock.now
      log.append("closedAfterReply:\(reply(slow)?.isEmpty == true && ContinuousClock.now - start < .seconds(3))")
      return log
    }.value
    XCTAssertEqual(outcome[0], "full:true")
    XCTAssertEqual(outcome[1], "expired:true")
    for (line, id) in zip(outcome[2...4], ["1", "2", "3"]) {
      let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      XCTAssertEqual(json?["id"] as? String, id); XCTAssertEqual(json?["ok"] as? Bool, true)
    }
    XCTAssertEqual(outcome[5], "closedAfterReply:true")
  }
}
