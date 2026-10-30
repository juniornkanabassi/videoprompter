import Foundation

public struct ControlParam: Sendable {
  public let name: String
  public let kind: String
  public let required: Bool
  public let positional: Bool
  public let choices: [String]
  /// Inclusive bounds for an integer or number parameter.
  public let range: ClosedRange<Double>?
  public let help: String
  public init(_ name: String, _ kind: String = "string", required: Bool = false, positional: Bool = false, choices: [String] = [], range: ClosedRange<Double>? = nil, help: String = "") {
    self.name = name; self.kind = kind; self.required = required; self.positional = positional; self.choices = choices; self.range = range; self.help = help
  }
  /// The CLI spelling: `textSize` is `--text-size`. Both spellings parse.
  public var flag: String {
    "--" + name.reduce(into: "") { result, character in
      if character.isUppercase { result += "-" + character.lowercased() } else { result.append(character) }
    }
  }
  /// One rule for the CLI, the app and the manifest. Booleans also accept 1 and 0.
  public func accepts(_ value: String) -> Bool {
    if value.isEmpty { return !required && choices.isEmpty && (kind == "string" || kind == "path") }
    guard choices.isEmpty || choices.contains(value) else { return false }
    switch kind {
    case "boolean": return ["true", "false", "1", "0"].contains(value)
    case "integer":
      guard let number = Int(value) else { return false }
      return range.map { $0.contains(Double(number)) } ?? true
    case "number":
      guard let number = Double(value), number.isFinite else { return false }
      return range.map { $0.contains(number) } ?? true
    default: return true
    }
  }
  /// What `accepts` allows, for error messages.
  public var validValues: String {
    if !choices.isEmpty { return choices.joined(separator: ", ") }
    if let range {
      let format = { (value: Double) in value == value.rounded() ? String(Int(value)) : String(value) }
      return "\(kind == "integer" ? "a whole number" : "a number") from \(format(range.lowerBound)) to \(format(range.upperBound))"
    }
    switch kind {
    case "boolean": return "true or false"
    case "integer": return "a whole number"
    case "number": return "a number"
    default: return required ? "a non-empty value" : "any text"
    }
  }
}
public struct ControlCommand: Sendable {
  public let action: String
  public let words: [String]
  public let summary: String
  public let example: String
  public let params: [ControlParam]
}
public enum ControlProtocol {
  public static let bundleID = "com.juniornkanabassi.VidPrompt"
  public static let maxRequestBytes = 65_536
  private static let onOff = ["on", "off"]
  private static let script = ControlParam("script", required: true, positional: true, help: "Script id or exact title")
  private static let requestID = ControlParam("requestId", help: "Retry key: a repeated id returns the first result instead of acting again")
  private static let confirm = ControlParam("yes", "boolean", required: true, help: "Confirms this significant action")
  public static let commands: [ControlCommand] = [
    .init(action: "status", words: ["status"], summary: "Report app, presenter, camera and recording state without launching.", example: "videoprompter status --json", params: []),
    // Library
    .init(action: "script_list", words: ["script", "list"], summary: "List library scripts.", example: "videoprompter script list", params: []),
    .init(action: "script_read", words: ["script", "read"], summary: "Return a script's Markdown text, folder and tags.", example: "videoprompter script read 'My Script'", params: [script]),
    .init(action: "script_create", words: ["script", "create"], summary: "Create a script from Markdown text and select it, once per request id.", example: "videoprompter script create --title Intro --text '# Intro' --request-id intro1", params: [
      .init("text", required: true, help: "Markdown text. On the command line, - reads standard input"),
      .init("title", help: "Title; defaults to Untitled Script"),
      .init("folder", help: "Folder id or exact name to create the script in"), requestID]),
    .init(action: "script_import", words: ["script", "import"], summary: "Import a file, keeping Markdown linked.", example: "videoprompter script import ./script.md --request-id take1", params: [.init("path", "path", required: true, positional: true), requestID]),
    .init(action: "script_open", words: ["script", "open"], summary: "Select a script by id or exact title.", example: "videoprompter script open 'My Script'", params: [.init("script", required: true, positional: true), .init("show", "boolean")]),
    .init(action: "script_rename", words: ["script", "rename"], summary: "Rename a script.", example: "videoprompter script rename 'My Script' --title 'Launch video'", params: [script, .init("title", required: true, help: "New title"), requestID]),
    .init(action: "script_tag", words: ["script", "tag"], summary: "Replace a script's tags; none clears them.", example: "videoprompter script tag 'My Script' --tags 'launch, draft'", params: [script, .init("tags", required: true, help: "Comma separated tags, or none"), requestID]),
    .init(action: "script_move", words: ["script", "move"], summary: "Move a script to a folder, or to All Scripts with none.", example: "videoprompter script move 'My Script' --folder Drafts", params: [script, .init("folder", required: true, help: "Folder id or exact name, or none for All Scripts"), requestID]),
    .init(action: "script_duplicate", words: ["script", "duplicate"], summary: "Duplicate a script and select the copy, once per request id.", example: "videoprompter script duplicate 'My Script' --request-id copy1", params: [script, requestID]),
    .init(action: "script_export", words: ["script", "export"], summary: "Save a script's Markdown to a file; never replaces one unless asked.", example: "videoprompter script export 'My Script' --path ./my-script.md", params: [script, .init("path", "path", required: true, help: "Destination file"), .init("replace", "boolean", help: "Replace an existing file; also requires --yes"), .init("yes", "boolean", help: "Confirm replacing an existing file"), requestID]),
    .init(action: "script_delete", words: ["script", "delete"], summary: "Move a script to Recently Deleted, where script restore brings it back.", example: "videoprompter script delete 'My Script' --yes", params: [script, confirm, requestID]),
    .init(action: "script_trash", words: ["script", "trash"], summary: "List scripts in Recently Deleted.", example: "videoprompter script trash", params: []),
    .init(action: "script_restore", words: ["script", "restore"], summary: "Restore a script from Recently Deleted.", example: "videoprompter script restore 'My Script'", params: [.init("script", required: true, positional: true, help: "Deleted script id or exact title"), requestID]),
    .init(action: "folder_list", words: ["folder", "list"], summary: "List library folders.", example: "videoprompter folder list", params: []),
    .init(action: "folder_create", words: ["folder", "create"], summary: "Create a folder, once per request id.", example: "videoprompter folder create Drafts --request-id drafts1", params: [.init("name", required: true, positional: true, help: "Folder name"), requestID]),
    .init(action: "folder_rename", words: ["folder", "rename"], summary: "Rename a folder.", example: "videoprompter folder rename Drafts --name 'In progress'", params: [.init("folder", required: true, positional: true, help: "Folder id or exact name"), .init("name", required: true, help: "New name"), requestID]),
    // Presenter
    .init(action: "present", words: ["present"], summary: "Present a script without taking focus.", example: "videoprompter present 'My Script'", params: [.init("script", positional: true), .init("show", "boolean")]),
    .init(action: "presenter_close", words: ["presenter", "close"], summary: "Close the presenter and pause following.", example: "videoprompter presenter close", params: []),
    .init(action: "pause", words: ["pause"], summary: "Pause the presented script.", example: "videoprompter pause", params: []),
    .init(action: "resume", words: ["resume"], summary: "Resume the presented script.", example: "videoprompter resume", params: []),
    .init(action: "back_to_start", words: ["back-to-start"], summary: "Reset the reading position.", example: "videoprompter back-to-start", params: []),
    .init(action: "next_passage", words: ["next-passage"], summary: "Move the reading position to the next passage.", example: "videoprompter next-passage", params: [requestID]),
    .init(action: "previous_passage", words: ["previous-passage"], summary: "Move the reading position to the previous passage.", example: "videoprompter previous-passage", params: [requestID]),
    .init(action: "seek", words: ["seek"], summary: "Move the reading position to a word number, as status counts them.", example: "videoprompter seek 120", params: [.init("word", "integer", required: true, positional: true, range: 1...10_000_000, help: "Word number, from 1")]),
    .init(action: "set_mode", words: ["set-mode"], summary: "Set tracking mode.", example: "videoprompter set-mode manual", params: [.init("mode", "choice", required: true, positional: true, choices: ["voice", "manual"])]),
    .init(action: "set_zoom", words: ["set-zoom"], summary: "Set the interface zoom percentage.", example: "videoprompter set-zoom 150", params: [.init("zoom", "integer", required: true, positional: true, choices: ["100", "110", "125", "150", "175", "200"])]),
    // Settings
    .init(action: "settings_get", words: ["settings", "get"], summary: "Report every presenter setting that settings set can change.", example: "videoprompter settings get", params: []),
    .init(action: "settings_set", words: ["settings", "set"], summary: "Change presenter settings, as the Settings panel does. Give at least one.", example: "videoprompter settings set --speed 150 --text-size 60 --mirror on", params: [
      .init("speed", "integer", range: 20...300, help: "Manual speed in words per minute"),
      .init("textSize", "integer", range: 18...120, help: "Presenter text size in points"),
      .init("font", help: "Presenter font; settings get lists the choices"),
      .init("weight", "choice", choices: ["regular", "bold"], help: "Text weight"),
      .init("alignment", "choice", choices: ["left", "centre", "center", "right"], help: "Text alignment"),
      .init("mirror", "choice", choices: onOff, help: "Mirror left to right for teleprompter glass"),
      .init("mirrorVertical", "choice", choices: onOff, help: "Mirror text top to bottom"),
      .init("rotation", "integer", choices: ["0", "180"], help: "Text rotation in degrees"),
      .init("textWidth", "integer", range: 30...100, help: "Script column width as a percentage of the presenter"),
      .init("textVisibility", "integer", range: 20...100, help: "Text opacity percentage"),
      .init("backgroundDarkness", "integer", range: 0...100, help: "Backdrop opacity percentage for the current view; at most 90 over the camera"),
      .init("readingLine", "integer", range: 10...85, help: "Reading line position as a percentage of the height"),
      .init("readingLineVisibility", "integer", range: 0...100, help: "Reading line opacity percentage; 0 hides it"),
      .init("lineSpacing", "integer", range: 0...50, help: "Line spacing percentage"),
      .init("paragraphSpacing", "integer", range: 0...100, help: "Paragraph spacing percentage"),
      .init("textColour", help: "Text colour as #RRGGBB"),
      .init("backgroundColour", help: "Background colour as #RRGGBB"),
      .init("stageDirections", "choice", choices: onOff, help: "Show bracketed stage directions"),
      .init("highlightWord", "choice", choices: onOff, help: "Highlight the active word"),
      .init("followRepeats", "choice", choices: onOff, help: "Voice follows you back when you repeat earlier words"),
      .init("language", help: "Spoken language: Mixed, Automatic, English, French or a locale id such as de-DE"),
      .init("microphone", help: "Voice microphone id from microphone list, or none"),
      .init("microphoneVolume", "integer", range: 25...400, help: "Voice microphone gain percentage")]),
    .init(action: "preset_list", words: ["preset", "list"], summary: "List saved settings.", example: "videoprompter preset list", params: []),
    .init(action: "preset_apply", words: ["preset", "apply"], summary: "Apply saved settings by id or exact name.", example: "videoprompter preset apply Studio", params: [.init("preset", required: true, positional: true, help: "Saved settings id or exact name")]),
    .init(action: "preset_save", words: ["preset", "save"], summary: "Save the current settings under a name, once per request id.", example: "videoprompter preset save Studio --request-id studio1", params: [.init("name", required: true, positional: true, help: "Name for these settings"), requestID]),
    // Camera and recording
    .init(action: "camera_list", words: ["camera", "list"], summary: "List cameras with the view, mirroring, rotation and framing guides.", example: "videoprompter camera list", params: []),
    .init(action: "camera_select", words: ["camera", "select"], summary: "Choose the camera by id or exact name.", example: "videoprompter camera select 'FaceTime HD Camera'", params: [.init("camera", required: true, positional: true, help: "Camera id or exact name from camera list")]),
    .init(action: "camera_set", words: ["camera", "set"], summary: "Show or hide the camera behind the script, mirror or rotate it. Give at least one.", example: "videoprompter camera set on --rotation auto", params: [
      .init("view", "choice", positional: true, choices: ["off", "on", "only"], help: "off: script only; on: script over the camera; only: camera alone"),
      .init("mirror", "choice", choices: onOff, help: "Mirror the camera picture"),
      .init("rotation", "choice", choices: ["0", "90", "180", "270", "auto"], help: "Camera rotation in degrees, or auto"), requestID]),
    .init(action: "camera_guides", words: ["camera", "guides"], summary: "Set framing guides for the selected camera. Give at least one.", example: "videoprompter camera guides --thirds on --marker 9:16", params: [
      .init("thirds", "choice", choices: onOff, help: "Rule of thirds"),
      .init("centreCross", "choice", choices: onOff, help: "Centre cross"),
      .init("centreTarget", "choice", choices: onOff, help: "Centre target"),
      .init("marker", help: "Frame marker shape such as 9:16, 16:9, 4:5, 1:1, 4:3 or any W:H, or off"),
      .init("colour", help: "Guide colour as #RRGGBB"),
      .init("visibility", "integer", range: 0...100, help: "Guide opacity percentage; 0 hides them"),
      .init("shade", "integer", range: 0...100, help: "Darkening outside the frame marker, as a percentage"), requestID]),
    .init(action: "microphone_list", words: ["microphone", "list"], summary: "List microphones for Voice and for recording.", example: "videoprompter microphone list", params: []),
    .init(action: "record_start", words: ["record", "start"], summary: "Start recording the shown camera and microphone; returns a recording id and needs --yes.", example: "videoprompter record start --yes --request-id take1", params: [confirm, requestID]),
    .init(action: "record_stop", words: ["record", "stop"], summary: "Stop recording with its recording id or --force, and report the saved file.", example: "videoprompter record stop --recording <id>", params: [.init("recording", help: "Recording id returned by record start"), .init("force", "boolean", help: "Stop any active recording"), requestID]),
    .init(action: "record_set", words: ["record", "set"], summary: "Set recording quality, microphone and audio format while not recording. Give at least one.", example: "videoprompter record set --quality high --float-audio off", params: [
      .init("quality", "choice", choices: ["standard", "high", "edit"], help: "standard: H.264; high: HEVC; edit: ProRes 422"),
      .init("microphone", help: "Recording microphone id from microphone list, or default"),
      .init("floatAudio", "choice", choices: onOff, help: "32-bit float audio")]),
    // iPad
    .init(action: "ipad", words: ["ipad"], summary: "Drive Video Prompter on an iPad linked by USB-C or paired Wi-Fi, then report its scripts and presenter. With no options it only reports.", example: "videoprompter ipad --present 'My Script' --mode manual --speed 150 --run on", params: [
      .init("present", help: "Open this script on the iPad, by id or exact title from the iPad's own list"),
      .init("mode", "choice", choices: ["voice", "manual"], help: "Tracking mode"),
      .init("speed", "integer", range: 20...300, help: "Manual speed in words per minute"),
      .init("move", "choice", choices: ["start", "next", "previous"], help: "Back to the start, or to the next or previous passage"),
      .init("word", "integer", range: 1...10_000_000, help: "Move the reading position to this word number"),
      .init("run", "choice", choices: onOff, help: "Start or pause reading"),
      .init("close", "boolean", help: "Close the iPad's presenter")])
  ]
  public static func command(action: String) -> ControlCommand? { commands.first { $0.action == action } }
  public static func dataRoot(bundleIdentifier: String?, arguments: [String],
                              applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
    if let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count { return URL(fileURLWithPath: arguments[i + 1]) }
    return migrateLegacyFolder(in: applicationSupport)
  }
  /// The app was called VidPrompt before 2.0. Moves `<parent>/VidPrompt` to `<parent>/Video Prompter`
  /// once, only when the new folder is absent and the old one is a real folder (not a symlink).
  /// Best effort: a failed move keeps callers on the existing legacy folder so migration can retry.
  @discardableResult public static func migrateLegacyFolder(
    in parent: URL,
    move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
  ) -> URL {
    let current = parent.appendingPathComponent("Video Prompter", isDirectory: true)
    let legacy = parent.appendingPathComponent("VidPrompt", isDirectory: true)
    let fileManager = FileManager.default
    // attributesOfItem does not follow symlinks, so a linked legacy folder is left alone.
    if !fileManager.fileExists(atPath: current.path),
       (try? fileManager.attributesOfItem(atPath: legacy.path)[.type] as? FileAttributeType) == .typeDirectory {
      // Defer even stale sockets until cleanup so a live legacy daemon keeps its data root.
      if fileManager.fileExists(atPath: socketURL(dataRoot: legacy).path) { return legacy }
      do { try move(legacy, current) }
      catch { return legacy }
    }
    return current
  }
  public static func socketURL(dataRoot: URL) -> URL { dataRoot.appendingPathComponent("control.sock") }
}
