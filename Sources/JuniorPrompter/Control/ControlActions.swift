import AppKit
import PrompterCore

@MainActor final class ControlActions {
  private let store: AppStore
  private let presenter: PresenterController
  private var imports: [String: Task<ControlResult, Never>] = [:]
  init(store: AppStore, presenter: PresenterController = .shared) { self.store = store; self.presenter = presenter }
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
    return (matches.first, matches.isEmpty ? .error("script_not_found", "Script not found. Use juniorprompter script list.") : nil)
  }
  func handle(_ action: String, _ params: [String: String]) async -> ControlResult {
    await store.waitForInitialLoad()
    guard let command = ControlProtocol.command(action: action) else { return .error("unknown_action", "Use juniorprompter --help for supported actions.") }
    guard params.keys.allSatisfy({ key in command.params.contains { $0.name == key } }),
      command.params.allSatisfy({ p in
        guard let value = params[p.name] else { return !p.required }
        if p.required && value.isEmpty { return false }
        if p.kind == "boolean" { return ["true", "false", "1", "0"].contains(value) }
        return p.choices.isEmpty || p.choices.contains(value)
      }) else { return .error("invalid_params", "Invalid parameters for \(command.words.joined(separator: " ")). \(command.params.flatMap(\.choices).joined(separator: ", "))") }
    let show = ["true", "1"].contains(params["show"] ?? "false")
    switch action {
    case "status":
      var result: [String: Any] = ["running": true, "app": Bundle.main.bundleIdentifier ?? ControlProtocol.stableBundleID,
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev", "library": store.libraryAvailable, "scripts": store.scripts.count,
        "selected": store.selected.map(identity) as Any? ?? NSNull(), "presenter": presenter.isEditing ? "editing" : presenter.panel?.isVisible == true ? "visible" : "hidden",
        "script": store.session.activeRecord.map(identity) as Any? ?? NSNull(), "state": state, "mode": store.settings.mode.lowercased(), "position": position, "zoom": Int((store.uiZoom * 100).rounded()), "textSize": store.settings.fontSize]
      if case .uncertain(let notice) = store.session.state { result["notice"] = notice }
      else if let notice = store.session.anchorNotice { result["notice"] = notice }
      return .ok(result)
    case "script_list":
      guard store.libraryAvailable else { return .error("library_unavailable", "The script library is unavailable.") }
      return .ok(["scripts": store.scripts.map { record -> [String: Any] in
        ["id": record.id.uuidString, "title": record.metadata.title, "modified": ISO8601DateFormatter().string(from: record.metadata.modifiedAt), "linked": record.metadata.linkedPath != nil]
      }])
    case "script_import":
      guard store.libraryAvailable else { return .error("library_unavailable", "The script library is unavailable.") }
      if let requestID = params["requestId"], let pending = imports[requestID] {
        let result = await pending.value
        if var value = result.body["result"] as? [String: Any] { value["repeated"] = true; return .ok(value) }
        return result
      }
      let task = Task { @MainActor [self] () -> ControlResult in
        let url = URL(fileURLWithPath: params["path"]!)
        guard params["path"]!.hasPrefix("/"), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { return .error("invalid_params", "Import an absolute path to a regular file.") }
        do {
          let preview = try await DocumentImporter().preview(url: url)
          let target = AppStore.importTarget(for: preview)
          store.search = ""; store.selectedFolderID = nil
          let record = try await store.createScript(title: target.title, markdown: preview.markdown, linkTo: target.linkTo)
          return .ok(["id": record.id.uuidString, "title": record.metadata.title, "linked": record.metadata.linkedPath != nil, "warnings": preview.warnings, "repeated": false])
        } catch { return .error("import_failed", "The file could not be imported. Check its format, size and access permissions.") }
      }
      if let requestID = params["requestId"] { imports[requestID] = task }
      let result = await task.value; if result.body["ok"] as? Bool != true, let id = params["requestId"] { imports[id] = nil }; return result
    case "script_open", "present":
      guard store.libraryAvailable else { return .error("library_unavailable", "The script library is unavailable.") }
      if action == "present", presenter.isEditing { return .error("presenter_editing", "Finish or cancel the presenter edit first.") }
      let (record, error) = params["script"].map(lookup) ?? (store.selected, nil)
      if let error { return error }
      guard let record else { return .error("no_active_script", "Select a script first: juniorprompter script open <id|title>") }
      select(record)
      if action == "present" {
        presenter.present(store: store, activate: show)
        var value: [String: Any] = identity(record); value["presenter"] = "visible"; return .ok(value)
      }
      if show { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0 is NSPanel == false && $0.title.contains("JuniorPrompter") }?.makeKeyAndOrderFront(nil) }
      return .ok(identity(record))
    case "pause", "resume", "back_to_start":
      if presenter.isEditing { return .error("presenter_editing", "Finish or cancel the presenter edit first.") }
      guard store.session.activeRecord != nil, presenter.panel?.isVisible == true else { return .error("no_active_script", "Present a script first: juniorprompter present <id|title>") }
      if action == "pause" { store.session.pause() }
      else if action == "resume" { store.session.play() }
      else { store.session.restart() }
      return .ok(["state": state, "position": position])
    case "set_mode": store.settings.mode = params["mode"] == "manual" ? "Manual" : "Voice"; return .ok(["mode": store.settings.mode.lowercased()])
    case "set_zoom":
      guard let zoom = Double(params["zoom"] ?? ""), AppStore.uiZoomSteps.contains(zoom / 100) else { return .error("invalid_params", "Zoom must be 100, 110, 125, 150, 175 or 200.") }
      store.uiZoom = zoom / 100; return .ok(["zoom": Int(zoom)])
    default: return .error("unknown_action", "Unsupported action.")
    }
  }
}
