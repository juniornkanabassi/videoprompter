@preconcurrency import AVFoundation
import AppKit
import PrompterCore
import Speech

/// Runs CLI and MCP requests through the same models, methods and library calls the GUI uses, so
/// every change shows in the running app. Library changes await the library and report failures
/// to the caller instead of the app's error alert.
@MainActor final class ControlActions {
  private let store: AppStore
  private let presenter: PresenterController
  private let camera: CameraModel
  private let recorder: CameraRecorder
  private let audioAuthorization: () -> AVAuthorizationStatus
  /// Requests by action and request id, so a retry returns the first result.
  private var requests: [String: Task<ControlResult, Never>] = [:]
  init(store: AppStore, presenter: PresenterController = .shared, camera: CameraModel = .shared, recorder: CameraRecorder = .shared, audioAuthorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }) {
    self.store = store; self.presenter = presenter; self.camera = camera; self.recorder = recorder
    self.audioAuthorization = audioAuthorization
  }
  private func identity(_ script: ScriptRecord) -> [String: String] { ["id": script.id.uuidString, "title": script.metadata.title] }
  private var position: [String: Int] { ["word": store.session.document.spokenTokens.isEmpty ? 0 : store.session.tokenIndex + 1, "words": store.session.document.spokenTokens.count] }
  private var state: String {
    switch store.session.state {
    case .stopped: "stopped"
    case .paused: "paused"
    case .running: "running"
    case .uncertain: "uncertain"
    }
  }
  private func select(_ record: ScriptRecord) { store.search = ""; store.selectedFolderID = nil; store.selectedID = record.id }
  private func lookup(_ name: String) -> (ScriptRecord?, ControlResult?) {
    if let id = UUID(uuidString: name), let script = store.scripts.first(where: { $0.id == id }) { return (script, nil) }
    let matches = store.scripts.filter { $0.metadata.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    if matches.count > 1 { return (nil, .error("ambiguous_script", "Use a script id to choose between these titles.", candidates: matches.prefix(5).map(identity))) }
    return (matches.first, matches.isEmpty ? .error("script_not_found", "Script not found. Use videoprompter script list.") : nil)
  }
  /// Finds a folder, preset, camera, microphone or deleted script by id or exact name.
  private func choose<T>(_ name: String, in items: [T], id: (T) -> String, title: (T) -> String, kind: String, list: String) -> (T?, ControlResult?) {
    if let exact = items.first(where: { id($0).caseInsensitiveCompare(name) == .orderedSame }) { return (exact, nil) }
    let matches = items.filter { title($0).compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    if matches.count > 1 { return (nil, .error("ambiguous_\(kind)", "Use an id to choose between these names.", candidates: matches.prefix(5).map { ["id": id($0), "name": title($0)] })) }
    guard let match = matches.first else { return (nil, .error("\(kind)_not_found", "No \(kind) has that id or name. Use videoprompter \(list).")) }
    return (match, nil)
  }
  private func folder(named name: String) -> (ScriptFolder?, ControlResult?) {
    choose(name, in: store.folders, id: { $0.id.uuidString }, title: { $0.name }, kind: "folder", list: "folder list")
  }
  private func details(_ record: ScriptRecord) -> [String: Any] {
    var value: [String: Any] = ["id": record.id.uuidString, "title": record.metadata.title, "tags": record.metadata.tags,
      "linked": record.metadata.linkedPath != nil, "modified": ISO8601DateFormatter().string(from: record.metadata.modifiedAt)]
    let folder = record.metadata.folderID.flatMap { id in store.folders.first { $0.id == id } }
    value["folder"] = folder.map { ["id": $0.id.uuidString, "name": $0.name] } as Any? ?? NSNull()
    return value
  }
  private func isTrue(_ value: String?) -> Bool { ["true", "1"].contains(value ?? "false") }
  private func on(_ value: Bool) -> String { value ? "on" : "off" }
  private func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
  private func number(_ params: [String: String], _ key: String) -> Double? { params[key].flatMap(Double.init) }
  private static func hexColour(_ value: String) -> String? {
    let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
    return "#" + digits.uppercased()
  }
  private var unavailable: ControlResult { .error("library_unavailable", "The script library is unavailable.") }
  private var editing: ControlResult { .error("presenter_editing", "Finish or cancel the presenter edit first.") }
  private var notPresenting: ControlResult { .error("no_active_script", "Present a script first: videoprompter present <id|title>") }

  /// Runs `work` once per action and request id. A repeat, even one that arrives while the first is
  /// still running, gets the first result marked `repeated`; a failure can be retried.
  private func once(_ action: String, _ params: [String: String], _ work: @escaping @MainActor @Sendable () async -> ControlResult) async -> ControlResult {
    guard let requestID = params["requestId"] else {
      let result = await work()
      return Self.marked(result, repeated: false)
    }
    let key = action + "\n" + requestID
    if let pending = requests[key] {
      let result = await pending.value
      return Self.marked(result, repeated: true)
    }
    let task = Task { @MainActor in await work() }
    requests[key] = task
    let result = await task.value
    if result.body["ok"] as? Bool != true { requests[key] = nil }
    return Self.marked(result, repeated: false)
  }
  private static func marked(_ result: ControlResult, repeated: Bool) -> ControlResult {
    guard var value = result.body["result"] as? [String: Any] else { return result }
    value["repeated"] = repeated
    return .ok(value)
  }

  func handle(_ action: String, _ params: [String: String]) async -> ControlResult {
    Headless.shared.begin(); defer { Headless.shared.end() }
    await store.waitForInitialLoad()
    guard let command = ControlProtocol.command(action: action) else { return .error("unknown_action", "Use videoprompter --help for supported actions.") }
    let words = command.words.joined(separator: " ")
    if let unknown = params.keys.first(where: { key in !command.params.contains { $0.name == key } }) {
      return .error("invalid_params", "Unknown parameter \(unknown) for \(words).")
    }
    if let bad = command.params.first(where: { p in params[p.name].map { !p.accepts($0) } ?? p.required }) {
      return .error("invalid_params", params[bad.name] == nil ? "Missing \(bad.name) for \(words). Example: \(command.example)" : "Invalid \(bad.name). Valid values: \(bad.validValues)")
    }
    let show = isTrue(params["show"])
    switch action {
    case "status":
      var result: [String: Any] = ["running": true, "headless": Headless.shared.active, "app": Bundle.main.bundleIdentifier ?? ControlProtocol.bundleID,
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev", "library": store.libraryAvailable, "scripts": store.scripts.count,
        "selected": store.selected.map(identity) as Any? ?? NSNull(), "presenter": presenter.isEditing ? "editing" : presenter.panel?.isVisible == true ? "visible" : "hidden",
        "script": store.session.activeRecord.map(identity) as Any? ?? NSNull(), "state": state, "mode": store.settings.mode.lowercased(), "position": position, "zoom": Int((store.uiZoom * 100).rounded()), "textSize": store.settings.fontSize]
      result["speed"] = Int(store.settings.speed.rounded())
      result["camera"] = cameraState
      result["recording"] = recordingState
      if case .uncertain(let notice) = store.session.state { result["notice"] = notice }
      else if let notice = store.session.anchorNotice { result["notice"] = notice }
      return .ok(result)
    case "script_list":
      guard store.libraryAvailable else { return unavailable }
      return .ok(["scripts": store.scripts.map { record -> [String: Any] in
        ["id": record.id.uuidString, "title": record.metadata.title, "modified": ISO8601DateFormatter().string(from: record.metadata.modifiedAt), "linked": record.metadata.linkedPath != nil,
         "folder": record.metadata.folderID?.uuidString as Any? ?? NSNull()]
      }])
    case "script_read":
      guard store.libraryAvailable else { return unavailable }
      let (record, error) = lookup(params["script"]!)
      if let error { return error }
      guard let record else { return unavailable }
      var value = details(record); value["markdown"] = record.markdown
      return .ok(value)
    case "script_create":
      guard store.libraryAvailable else { return unavailable }
      return await once(action, params) { [self] () -> ControlResult in
        let folderID: UUID?
        if let name = params["folder"] {
          let (found, error) = folder(named: name)
          if let error { return error }
          folderID = found?.id
        } else { folderID = nil }
        let title = (params["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
          store.search = ""; store.selectedFolderID = folderID
          let record = try await store.createScript(title: title.isEmpty ? "Untitled Script" : title, markdown: params["text"]!)
          return .ok(details(record))
        } catch { return .error("create_failed", "The script could not be created. Check the title and that the library folder is writable.") }
      }
    case "script_import":
      guard store.libraryAvailable else { return unavailable }
      return await once(action, params) { [self] () -> ControlResult in
        let url = URL(fileURLWithPath: params["path"]!)
        guard params["path"]!.hasPrefix("/"), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { return .error("invalid_params", "Import an absolute path to a regular file.") }
        do {
          let preview = try await DocumentImporter().preview(url: url)
          let target = AppStore.importTarget(for: preview)
          store.search = ""; store.selectedFolderID = nil
          let record = try await store.createScript(title: target.title, markdown: preview.markdown, linkTo: target.linkTo)
          return .ok(["id": record.id.uuidString, "title": record.metadata.title, "linked": record.metadata.linkedPath != nil, "warnings": preview.warnings])
        } catch { return .error("import_failed", "The file could not be imported. Check its format, size and access permissions.") }
      }
    case "script_open", "present":
      guard store.libraryAvailable else { return unavailable }
      if action == "present", presenter.isEditing { return editing }
      let (record, error) = params["script"].map(lookup) ?? (store.selected, nil)
      if let error { return error }
      guard let record else { return .error("no_active_script", "Select a script first: videoprompter script open <id|title>") }
      guard !store.deletingIDs.contains(record.id) else { return .error("script_deleting", "This script is being deleted.") }
      select(record)
      if action == "present" {
        presenter.present(store: store, activate: show)
        // --show makes it the ordinary app around the presenter; without it a headless copy stays headless.
        if show { Headless.shared.promote() }
        var value: [String: Any] = identity(record); value["presenter"] = "visible"; return .ok(value)
      }
      if show {
        Headless.shared.reveal()
        NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0 is NSPanel == false && $0.title.contains("Video Prompter") }?.makeKeyAndOrderFront(nil)
      }
      return .ok(identity(record))
    case "script_rename", "script_tag", "script_move":
      // Resolved inside the retry guard: a retry never renames a different script that took the old name.
      return await once(action, params) { [self] () -> ControlResult in
        guard store.libraryAvailable else { return unavailable }
        let (record, error) = lookup(params["script"]!)
        if let error { return error }
        guard let record else { return unavailable }
        do {
          switch action {
          case "script_rename":
            let title = params["title"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return .error("invalid_params", "Titles cannot be empty.") }
            try await store.updateScriptMetadata(record.id, title: title)
          case "script_tag":
            let raw = params["tags"]!
            let tags: [String] = raw.trimmingCharacters(in: .whitespaces).lowercased() == "none" ? [] : raw.split(separator: ",").map(String.init)
            try await store.updateScriptMetadata(record.id, tags: tags)
          default:
            var folderID: UUID?
            if params["folder"]!.lowercased() != "none" {
              let (found, error) = folder(named: params["folder"]!)
              if let error { return error }
              folderID = found?.id
            }
            try await store.moveScripts([record.id], to: folderID)
          }
        } catch { return .error("library_failed", "The library could not be updated. Nothing was changed.") }
        return .ok(details(store.scripts.first(where: { $0.id == record.id }) ?? record))
      }
    case "script_duplicate":
      return await once(action, params) { [self] () -> ControlResult in
        guard store.libraryAvailable else { return unavailable }
        let (record, error) = lookup(params["script"]!)
        if let error { return error }
        guard let record else { return unavailable }
        do {
          let item = try await store.duplicateScript(record.id)
          return .ok(details(item))
        } catch let error as AppStore.PendingEditsError { return .error("unsaved_edits", error.description) }
        catch { return .error("library_failed", "The script could not be duplicated.") }
      }
    case "script_export":
      return await once(action, params) { [self] () -> ControlResult in
        guard store.libraryAvailable else { return unavailable }
        let (record, error) = lookup(params["script"]!)
        if let error { return error }
        guard let record else { return unavailable }
        let path = params["path"]!
        guard path.hasPrefix("/") else { return .error("invalid_params", "Export to an absolute path.") }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
          return .error("invalid_params", "The destination folder does not exist.")
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
          guard isTrue(params["replace"]) else { return .error("file_exists", "A file already exists there. Pass --replace to overwrite it.") }
          guard isTrue(params["yes"]) else { return .error("confirmation_required", "Pass --replace --yes to overwrite an existing file.") }
          guard attributes[.type] as? FileAttributeType == .typeRegular else { return .error("invalid_params", "Only a regular file can be replaced.") }
        }
        do { try record.markdown.write(to: url, atomically: true, encoding: .utf8) }
        catch { return .error("export_failed", "Could not export the script. \(error.localizedDescription)") }
        var value: [String: Any] = identity(record); value["path"] = url.path
        return .ok(value)
      }
    case "script_delete":
      guard isTrue(params["yes"]) else { return .error("confirmation_required", "Pass --yes to move this script to Recently Deleted.") }
      return await once(action, params) { [self] () -> ControlResult in
        guard store.libraryAvailable else { return unavailable }
        let (record, error) = lookup(params["script"]!)
        if let error { return error }
        guard let record else { return unavailable }
        if let error = deletionError(record.id) { return error }
        do {
          try await store.deleteScript(record.id) {
            if let error = deletionError(record.id) { throw Refusal(result: error) }
          }
        } catch let error as Refusal { return error.result }
        catch let error as AppStore.PendingEditsError { return .error("unsaved_edits", error.description) }
        catch { return .error("library_failed", "The script could not be moved to Recently Deleted. Nothing was changed.") }
        var value: [String: Any] = identity(record); value["deleted"] = true
        value["restore"] = "videoprompter script restore \(record.id.uuidString)"
        return .ok(value)
      }
    case "script_trash":
      guard store.libraryAvailable else { return unavailable }
      if let library = store.library { store.trash = await library.listTrash() }
      return .ok(["scripts": store.trash.map { entry -> [String: Any] in
        ["id": entry.id.uuidString, "title": entry.metadata.title, "deleted": ISO8601DateFormatter().string(from: entry.deletedAt)]
      }])
    case "script_restore":
      return await once(action, params) { [self] () -> ControlResult in
        guard store.libraryAvailable, let library = store.library else { return unavailable }
        store.trash = await library.listTrash()
        let (entry, error) = choose(params["script"]!, in: store.trash, id: { $0.id.uuidString }, title: { $0.metadata.title }, kind: "script", list: "script trash")
        if let error { return error }
        guard let entry else { return unavailable }
        do { try await store.restoreScript(entry.id) }
        catch PrompterCoreError.destinationExists { return .error("library_failed", "A script file with the same name is already in the library. Nothing was changed.") }
        catch { return .error("library_failed", "The script could not be restored. Nothing was changed.") }
        guard let restored = store.scripts.first(where: { $0.id == entry.id }) else { return .ok(["id": entry.id.uuidString, "title": entry.metadata.title]) }
        return .ok(details(restored))
      }
    case "folder_list":
      guard store.libraryAvailable else { return unavailable }
      return .ok(["folders": store.folders.map { folder -> [String: Any] in
        ["id": folder.id.uuidString, "name": folder.name, "scripts": store.scripts.filter { $0.metadata.folderID == folder.id }.count]
      }])
    case "folder_create":
      guard store.libraryAvailable else { return unavailable }
      let name = params["name"]!.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return .error("invalid_params", "Folder names cannot be empty.") }
      return await once(action, params) { [self] () -> ControlResult in
        do {
          let folder = try await store.createLibraryFolder(named: name)
          return .ok(["id": folder.id.uuidString, "name": folder.name])
        } catch { return .error("library_failed", "The folder could not be created.") }
      }
    case "folder_rename":
      return await once(action, params) { [self] () -> ControlResult in
        guard store.libraryAvailable else { return unavailable }
        let (found, error) = folder(named: params["folder"]!)
        if let error { return error }
        guard let found else { return unavailable }
        let name = params["name"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .error("invalid_params", "Folder names cannot be empty.") }
        do { try await store.renameLibraryFolder(found.id, name: name) }
        catch { return .error("library_failed", "The folder could not be renamed. Nothing was changed.") }
        return .ok(["id": found.id.uuidString, "name": name])
      }
    case "presenter_close":
      if presenter.isEditing { return editing }
      guard presenter.panel?.isVisible == true else { return .ok(["presenter": "hidden", "changed": false, "state": state]) }
      presenter.close()
      return .ok(["presenter": presenter.panel?.isVisible == true ? "closing" : "hidden", "changed": true, "state": state])
    case "pause", "resume", "back_to_start", "next_passage", "previous_passage", "seek":
      if action == "next_passage" || action == "previous_passage" {
        return await once(action, params) { [self] in navigate(action, params) }
      }
      return navigate(action, params)
    case "set_mode":
      let mode = params["mode"] == "manual" ? "Manual" : "Voice"
      if let error = voicePermissionError(mode: mode) { return error }
      store.settings.mode = mode
      return .ok(["mode": store.settings.mode.lowercased()])
    case "set_zoom":
      guard let zoom = Double(params["zoom"] ?? ""), AppStore.uiZoomSteps.contains(zoom / 100) else { return .error("invalid_params", "Zoom must be 100, 110, 125, 150, 175 or 200.") }
      store.uiZoom = zoom / 100; return .ok(["zoom": Int(zoom)])
    case "settings_get": return .ok(settingsSnapshot)
    case "settings_set": return await setSettings(params, example: command.example)
    case "preset_list":
      return .ok(["presets": store.presets.map { ["id": $0.id.uuidString, "name": $0.name] }])
    case "preset_apply":
      let (preset, error) = choose(params["preset"]!, in: store.presets, id: { $0.id.uuidString }, title: { $0.name }, kind: "preset", list: "preset list")
      if let error { return error }
      guard let preset else { return .error("preset_not_found", "Use videoprompter preset list.") }
      if let error = voicePermissionError(mode: PrompterSettings.normalisedMode(preset.mode)) { return error }
      store.applyPreset(preset)
      return .ok(["id": preset.id.uuidString, "name": preset.name, "settings": settingsSnapshot])
    case "preset_save":
      let name = params["name"]!.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return .error("invalid_params", "Preset names cannot be empty.") }
      return await once(action, params) { [self] () -> ControlResult in
        store.savePreset(named: name)
        guard let preset = store.presets.last else { return .error("preset_failed", "The settings could not be saved.") }
        return .ok(["id": preset.id.uuidString, "name": preset.name])
      }
    case "camera_list":
      camera.refresh()
      var value = cameraState
      value["cameras"] = camera.devices.map { device -> [String: Any] in ["id": device.uid, "name": device.name, "selected": device.uid == camera.selectedUID] }
      value["access"] = Self.access(AVCaptureDevice.authorizationStatus(for: .video))
      return .ok(value)
    case "camera_select":
      if let error = Self.cameraChangeError(recording: recorder.isRecording, busy: recorder.isBusy) { return error }
      camera.refresh()
      let (device, error) = choose(params["camera"]!, in: camera.devices, id: { $0.uid }, title: { $0.name }, kind: "camera", list: "camera list")
      if let error { return error }
      guard let device else { return .error("camera_not_found", "Use videoprompter camera list.") }
      camera.selectedUID = device.uid
      return .ok(cameraState)
    case "camera_set":
      // Rotation and guides are saved per camera: a retry must not apply them to a camera selected since.
      return await once(action, params) { [self] () -> ControlResult in
        if let error = Self.cameraChangeError(recording: recorder.isRecording, busy: recorder.isBusy) { return error }
        guard params.keys.contains(where: { $0 != "requestId" }) else { return .error("invalid_params", "Give at least one of view, mirror or rotation. Example: \(command.example)") }
        if let view = params["view"], view != "off" {
          switch AVCaptureDevice.authorizationStatus(for: .video) {
          case .authorized: break
          case .notDetermined: return .error("permission_required", "macOS has not asked for camera access yet. Show the camera once in Video Prompter so a person can answer the prompt.")
          default: return .error("camera_denied", "Camera access is off. Allow Video Prompter in System Settings > Privacy & Security > Camera.")
          }
        }
        if let mirror = params["mirror"] { camera.mirrored = mirror == "on" }
        if let rotation = params["rotation"] {
          if rotation == "auto" { camera.guides.automaticRotation = true }
          else if let degrees = Int(rotation), let value = CameraRotation(rawValue: degrees) { camera.setRotation(value) }
        }
        if let view = params["view"] { camera.displayMode = view == "on" ? .prompterWithVideo : view == "only" ? .videoOnly : .prompterOnly }
        return .ok(cameraState)
      }
    case "camera_guides": return await once(action, params) { [self] in setGuides(params, example: command.example) }
    case "microphone_list":
      let voice = AudioCapture.inputDevices()
      let recording = CameraRecorder.microphones()
      var rows: [[String: Any]] = voice.map { device -> [String: Any] in
        ["id": device.uid, "name": device.name, "voice": true, "recording": recording.contains { $0.uniqueID == device.uid }]
      }
      for device in recording where !voice.contains(where: { $0.uid == device.uniqueID }) {
        rows.append(["id": device.uniqueID, "name": device.localizedName, "voice": false, "recording": true])
      }
      return .ok(["microphones": rows, "voiceMicrophone": store.settings.audioDeviceUID as Any? ?? NSNull(), "recordingMicrophone": recorder.microphoneUID ?? "default"])
    case "record_start":
      guard isTrue(params["yes"]) else { return .error("confirmation_required", "Pass --yes to start recording.") }
      return await once(action, params) { [self] () -> ControlResult in await startRecording() }
    case "record_stop":
      return await once(action, params) { [self] () -> ControlResult in
        guard recorder.isRecording || recorder.isBusy else { return .error("not_recording", "Nothing is recording.") }
        if let error = Self.recordingStopError(recordingID: recorder.recordingID, requested: params["recording"], force: isTrue(params["force"])) { return error }
        let wasRecording = recorder.isRecording
        let previous = recorder.lastFile
        await recorder.stop()
        if let file = recorder.lastFile, file != previous { return .ok(["active": false, "file": file.path]) }
        if !wasRecording && recorder.errorMessage == nil { return .ok(["active": false, "cancelled": true]) }
        return .error("recording_failed", recorder.errorMessage ?? "The recording could not be finished.")
      }
    case "record_set":
      guard !params.isEmpty else { return .error("invalid_params", "Give at least one of quality, microphone or float audio. Example: \(command.example)") }
      guard !recorder.isRecording, !recorder.isBusy else { return .error("recording_active", "Recording settings cannot change while recording.") }
      var microphoneUID = recorder.microphoneUID
      if let name = params["microphone"] {
        if name.lowercased() == "default" { microphoneUID = nil }
        else {
          let (device, error) = choose(name, in: CameraRecorder.microphones(), id: { $0.uniqueID }, title: { $0.localizedName }, kind: "microphone", list: "microphone list")
          if let error { return error }
          microphoneUID = device?.uniqueID
        }
      }
      if params["microphone"] != nil { recorder.microphoneUID = microphoneUID }
      if let quality = params["quality"].flatMap(RecordingPreset.init(rawValue:)) { recorder.preset = quality }
      if let float = params["floatAudio"] { recorder.floatAudio = float == "on" }
      return .ok(recordingSettings)
    case "ipad": return await iPad(params)
    default: return .error("unknown_action", "Unsupported action.")
    }
  }

  /// Opens the link for the call if it is closed, as File › Control iPad does, sends what was
  /// asked in order, and reports what the iPad then shows, or that it did not do it.
  private func iPad(_ params: [String: String]) async -> ControlResult {
    let link = IPadCameraSender.shared
    let wasOn = link.controlsIPad
    link.controlsIPad = true
    defer { if !wasOn { link.controlsIPad = false } }
    for _ in 0..<50 where link.iPadState == nil { try? await Task.sleep(for: .milliseconds(100)) }
    guard let before = link.iPadState else {
      return .error("ipad_not_found", "No iPad answered. Connect it by USB-C, trust this Mac and open Video Prompter on it. For Wi-Fi, pair it first with File › Also Connect over Wi-Fi.")
    }
    if before.presenting == nil, params["present"] == nil, ["move", "word", "run"].contains(where: { params[$0] != nil }) {
      return .error("ipad_not_presenting", "Nothing is open on the iPad. Add --present <id|title>.")
    }
    var commands: [PadRemote.Command] = []
    var wanted: [(PadRemote.State) -> Bool] = []
    if let name = params["present"] {
      let (script, error) = choose(name, in: before.scripts, id: { $0.id.uuidString }, title: { $0.title }, kind: "script", list: "ipad")
      guard let script else { return error! }
      commands.append(.present(script.id))
      wanted.append { $0.presenting == script.id && $0.words > 0 }
    }
    if let mode = params["mode"].map({ $0 == "manual" ? "Manual" : "Voice" }) {
      commands.append(.mode(mode))
      wanted.append { $0.mode == mode }
    }
    if let speed = params["speed"].flatMap(Int.init) {
      commands.append(.speed(speed))
      wanted.append { $0.speed == speed }
    }
    switch params["move"] {
    case "start": commands.append(.backToStart)
    case "next": commands.append(.nextPassage)
    case "previous": commands.append(.previousPassage)
    default: break
    }
    if let word = params["word"].flatMap(Int.init) {
      if params["present"] == nil, word > before.words { return .error("invalid_params", "Word must be from 1 to \(before.words).") }
      commands.append(.seek(word: word))
      // Reading on moves it at once, so only a paused script must land exactly.
      if params["run"] != "on" { wanted.append { $0.word == word } }
    }
    if let run = params["run"] {
      commands.append(run == "on" ? .play : .pause)
      wanted.append { $0.running == (run == "on") }
    }
    if isTrue(params["close"]) {
      commands.append(.close)
      wanted.append { $0.presenting == nil }
    }
    for command in commands { link.send(command) }
    // A passage move has no target to check: any change after it will do.
    if params["move"] != nil { wanted.append { $0 != before } }
    if !wanted.isEmpty {
      for _ in 0..<30 where !(link.iPadState.map { state in wanted.allSatisfy { $0(state) } } ?? false) {
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    guard let state = link.iPadState else { return .error("ipad_not_found", "The iPad disconnected.") }
    let title = { (id: UUID) in state.scripts.first { $0.id == id }.map { ["id": id.uuidString, "title": $0.title] } }
    let result: [String: Any] = ["over": link.transport ?? "", "scripts": state.scripts.map { ["id": $0.id.uuidString, "title": $0.title] },
      "script": state.presenting.flatMap(title) as Any? ?? NSNull(),
      "state": state.presenting == nil ? "closed" : state.running ? "running" : "paused",
      "mode": state.mode.lowercased(), "speed": state.speed, "position": ["word": state.word, "words": state.words]]
    guard wanted.allSatisfy({ $0(state) }) else {
      return .error("ipad_unconfirmed", "The iPad did not show the change within three seconds. Its state now: \(result["state"]!), \(state.mode.lowercased()), \(state.speed) words a minute, word \(state.word) of \(state.words).")
    }
    return .ok(result)
  }

  private func navigate(_ action: String, _ params: [String: String]) -> ControlResult {
    if presenter.isEditing { return editing }
    guard store.session.activeRecord != nil, presenter.panel?.isVisible == true else { return notPresenting }
    switch action {
    case "pause": store.session.pause()
    case "resume":
      guard !ReferenceMonitor.shared.isActive else { return .error("monitor_active", "A passage is pinned over the camera. Press Back to script in the presenter first.") }
      guard !presenter.isShowingWithoutScript else { return .error("camera_only_view", "The presenter shows only the camera. Present a script first: videoprompter present <id|title>") }
      guard presenter.panel?.isMiniaturized != true else { return .error("presenter_minimised", "The presenter is minimised. Restore its window first.") }
      guard presenter.canStartReading else { return .error("camera_only_view", "The presenter shows only the camera. Show the script first: videoprompter camera set on") }
      store.session.play()
    case "back_to_start": store.session.restart()
    default:
      // The Prompter menu's passage items, which do nothing while only the camera shows.
      guard camera.displayMode != .videoOnly else { return .error("camera_only_view", "The presenter shows only the camera. Show the script first: videoprompter camera set on") }
      if action == "seek" {
        let count = store.session.document.spokenTokens.count
        guard let word = Int(params["word"]!), word >= 1, word <= count else { return .error("invalid_params", "Word must be from 1 to \(count).") }
        presenter.moveReading { $0.seek(to: word - 1) }
      } else if action == "next_passage" {
        presenter.moveReading { $0.nextPassage() }
      } else {
        presenter.moveReading { $0.previousPassage() }
      }
    }
    return .ok(["state": state, "position": position])
  }

  private struct Refusal: Error { let result: ControlResult }
  private func deletionError(_ id: UUID) -> ControlResult? {
    guard store.session.activeScriptID == id else { return nil }
    if presenter.isEditing { return editing }
    if presenter.panel?.isVisible == true { return .error("script_presented", "This script is being presented. Close the presenter first: videoprompter presenter close") }
    return nil
  }
  private func voicePermissionError(mode: String) -> ControlResult? {
    guard mode == "Voice", presenter.panel?.isVisible == true else { return nil }
    return Self.voicePermissionError(authorization: audioAuthorization())
  }
  static func voicePermissionError(authorization: AVAuthorizationStatus) -> ControlResult? {
    switch authorization {
    case .authorized: return nil
    case .notDetermined: return .error("permission_required", "Start Voice mode once in Video Prompter so a person can answer the microphone permission prompt.")
    default: return .error("microphone_denied", "Microphone access is off. Allow Video Prompter in System Settings > Privacy & Security > Microphone.")
    }
  }
  static func cameraChangeError(recording: Bool, busy: Bool) -> ControlResult? {
    guard recording || busy else { return nil }
    return .error("recording_active", "Stop recording before changing the camera: use record stop --recording <id> or --force.")
  }
  static func recordingStopError(recordingID: UUID?, requested: String?, force: Bool) -> ControlResult? {
    guard !force else { return nil }
    if let recordingID, requested == recordingID.uuidString { return nil }
    return .error("recording_owned", "Pass --recording <id returned by record start> or --force to stop this recording.")
  }

  // MARK: Settings

  private var settingsSnapshot: [String: Any] {
    let s = store.settings
    var value: [String: Any] = ["mode": s.mode.lowercased(), "speed": Int(s.speed.rounded()), "textSize": Int(s.fontSize.rounded()),
      "font": s.fontName, "fonts": AvailableFonts.presenter, "weight": s.fontWeight.lowercased(),
      "alignment": s.alignment == "Center" ? "centre" : s.alignment.lowercased(), "rotation": s.rotation]
    value["mirror"] = on(s.horizontalMirror)
    value["mirrorVertical"] = on(s.verticalMirror)
    value["textWidth"] = percent(s.textWidth)
    value["textVisibility"] = percent(s.textOpacity)
    value["backgroundDarkness"] = percent(s.backdropOpacity(withVideo: camera.presentsWithVideo))
    value["readingLine"] = percent(s.guideFraction)
    value["readingLineVisibility"] = percent(s.guideOpacity)
    value["lineSpacing"] = percent(s.lineSpacing)
    value["paragraphSpacing"] = percent(s.paragraphSpacing)
    value["textColour"] = s.textColorHex
    value["backgroundColour"] = s.backgroundColorHex
    value["stageDirections"] = on(s.showCues)
    value["highlightWord"] = on(s.highlightActiveWord)
    value["followRepeats"] = on(s.allowsBackwardVoiceTracking)
    value["language"] = s.speechLanguage
    value["microphone"] = s.audioDeviceUID as Any? ?? NSNull()
    value["microphoneVolume"] = percent(s.inputGain)
    value["zoom"] = Int((store.uiZoom * 100).rounded())
    return value
  }

  /// Validates everything first, then writes the settings once, as the Settings panel's bindings do.
  private func setSettings(_ params: [String: String], example: String) async -> ControlResult {
    guard !params.isEmpty else { return .error("invalid_params", "Give at least one setting. Example: \(example)") }
    var language: String?
    if let requested = params["language"] {
      if let named = ["mixed": "Mixed", "automatic": "Automatic", "english": "English", "french": "French"][requested.lowercased()] { language = named }
      else {
        let normalised = { (identifier: String) in identifier.replacingOccurrences(of: "_", with: "-").lowercased() }
        let locales = await SpeechTranscriber.supportedLocales
        guard let locale = locales.first(where: { normalised($0.identifier) == normalised(requested) }) else {
          return .error("invalid_params", "Unsupported language. Use Mixed, Automatic, English, French or a supported locale id such as de-DE.")
        }
        language = locale.identifier
      }
    }
    // Read after the await, so a change made meanwhile is not overwritten.
    var s = store.settings
    if let language { s.speechLanguage = language }
    if let value = number(params, "speed") { s.speed = value }
    if let value = number(params, "textSize") { s.fontSize = value }
    if let font = params["font"] {
      guard let match = AvailableFonts.presenter.first(where: { $0.caseInsensitiveCompare(font) == .orderedSame }) else {
        return .error("invalid_params", "Unknown font. Valid values: \(AvailableFonts.presenter.joined(separator: ", "))")
      }
      s.fontName = match
    }
    if let weight = params["weight"] { s.fontWeight = weight == "bold" ? "Bold" : "Regular" }
    if let alignment = params["alignment"] { s.alignment = alignment == "left" ? "Left" : alignment == "right" ? "Right" : "Center" }
    if let mirror = params["mirror"] { s.horizontalMirror = mirror == "on" }
    if let mirror = params["mirrorVertical"] { s.verticalMirror = mirror == "on" }
    if let rotation = params["rotation"].flatMap(Int.init) { s.rotation = rotation }
    if let value = number(params, "textWidth") { s.textWidth = value / 100 }
    if let value = number(params, "textVisibility") { s.textOpacity = value / 100 }
    if let value = number(params, "backgroundDarkness") {
      let withVideo = camera.presentsWithVideo
      guard PrompterSettings.backdropOpacityRange(withVideo: withVideo).contains(value / 100) else {
        return .error("invalid_params", "Background darkness over the camera goes up to 90.")
      }
      s.setBackdropOpacity(value / 100, withVideo: withVideo)
    }
    if let value = number(params, "readingLine") { s.guideFraction = value / 100 }
    if let value = number(params, "readingLineVisibility") { s.guideOpacity = value / 100 }
    if let value = number(params, "lineSpacing") { s.lineSpacing = value / 100 }
    if let value = number(params, "paragraphSpacing") { s.paragraphSpacing = value / 100 }
    if let colour = params["textColour"] {
      guard let hex = Self.hexColour(colour) else { return .error("invalid_params", "Invalid textColour. Use #RRGGBB.") }
      s.textColorHex = hex
    }
    if let colour = params["backgroundColour"] {
      guard let hex = Self.hexColour(colour) else { return .error("invalid_params", "Invalid backgroundColour. Use #RRGGBB.") }
      s.backgroundColorHex = hex
    }
    if let value = params["stageDirections"] { s.showCues = value == "on" }
    if let value = params["highlightWord"] { s.highlightActiveWord = value == "on" }
    if let value = params["followRepeats"] { s.allowsBackwardVoiceTracking = value == "on" }
    if let name = params["microphone"] {
      if name.lowercased() == "none" { s.audioDeviceUID = nil }
      else {
        let (device, error) = choose(name, in: AudioCapture.inputDevices(), id: { $0.uid }, title: { $0.name }, kind: "microphone", list: "microphone list")
        if let error { return error }
        s.audioDeviceUID = device?.uid
      }
    }
    if let value = number(params, "microphoneVolume") { s.inputGain = value / 100 }
    if let error = voicePermissionError(mode: s.mode) { return error }
    // The Settings panel stops a running microphone test when the microphone changes.
    if params["microphone"] != nil { store.session.stopMicrophoneTest() }
    store.settings = s
    return .ok(settingsSnapshot)
  }

  // MARK: Camera and recording

  private var cameraView: String {
    switch camera.displayMode {
    case .prompterOnly: "off"
    case .prompterWithVideo: "on"
    case .videoOnly: "only"
    }
  }
  private var cameraState: [String: Any] {
    let selected = camera.selectedUID.map { uid in ["id": uid, "name": camera.devices.first { $0.uid == uid }?.name ?? uid] }
    return ["view": cameraView, "selected": selected as Any? ?? NSNull(), "mirror": on(camera.mirrored),
            "rotation": camera.guides.automaticRotation ? "auto" : String(camera.guides.rotation.rawValue), "guides": guidesSnapshot]
  }
  private var guidesSnapshot: [String: Any] {
    let g = camera.guides
    return ["thirds": on(g.thirds), "centreCross": on(g.axes), "centreTarget": on(g.bullseye), "marker": g.marker?.label ?? "off",
            "colour": g.colorHex, "visibility": percent(g.opacity), "shade": percent(g.shadeOpacity)]
  }
  private static func access(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
  }
  private func setGuides(_ params: [String: String], example: String) -> ControlResult {
    guard params.keys.contains(where: { $0 != "requestId" }) else { return .error("invalid_params", "Give at least one guide setting. Example: \(example)") }
    var g = camera.guides
    if let value = params["thirds"] { g.thirds = value == "on" }
    if let value = params["centreCross"] { g.axes = value == "on" }
    if let value = params["centreTarget"] { g.bullseye = value == "on" }
    if let marker = params["marker"] {
      if marker.lowercased() == "off" { g.marker = nil }
      else {
        let parts = marker.split(separator: ":")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
          width > 0, height > 0, width <= 100, height <= 100 else { return .error("invalid_params", "Marker must be off or W:H, such as 9:16.") }
        g.marker = CameraAspect(width: width, height: height)
      }
    }
    if let colour = params["colour"] {
      guard let hex = Self.hexColour(colour) else { return .error("invalid_params", "Invalid colour. Use #RRGGBB.") }
      g.colorHex = hex
    }
    if let value = number(params, "visibility") { g.opacity = value / 100 }
    if let value = number(params, "shade") { g.shadeOpacity = value / 100 }
    camera.guides = g
    return .ok(cameraState)
  }
  private var recordingSettings: [String: Any] {
    ["quality": recorder.preset.rawValue, "microphone": recorder.microphoneUID ?? "default", "floatAudio": on(recorder.floatAudio)]
  }
  private var recordingState: [String: Any] {
    var value = recordingSettings
    value["active"] = recorder.isRecording
    value["busy"] = recorder.isBusy
    if let id = recorder.recordingID { value["recording"] = id.uuidString }
    if let started = recorder.startedAt { value["startedAt"] = ISO8601DateFormatter().string(from: started) }
    if let file = recorder.lastFile { value["lastFile"] = file.path }
    if let message = recorder.errorMessage { value["error"] = message }
    return value
  }
  /// The Camera window's Record button, with the checks a person would see answered on screen
  /// made up front: no permission prompt is raised, and the camera must already be showing.
  private func startRecording() async -> ControlResult {
    if recorder.isRecording { return .error("already_recording", "A recording is already running. Stop it first: videoprompter record stop") }
    guard !recorder.isBusy else { return .error("recording_busy", "A recording is starting or finishing. Try again in a moment.") }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      return .error("permission_required", "Recording needs camera and microphone access. Record once in the Camera window so a person can answer the macOS prompts, or allow access in System Settings > Privacy & Security.")
    }
    let session = SharedCameraSession.shared
    guard let uid = camera.selectedUID, session.holderCount > 0, session.attachedUID == uid else {
      return .error("camera_not_showing", "Show the camera first: open the Camera window, or present with videoprompter camera set on.")
    }
    await recorder.start(camera: camera)
    guard recorder.isRecording else { return .error("recording_failed", recorder.errorMessage ?? "Recording could not start.") }
    var value = recordingState
    value["folder"] = CameraRecorder.recordingsFolder().path
    return .ok(value)
  }
}
