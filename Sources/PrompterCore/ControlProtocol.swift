import Foundation

public struct ControlParam: Sendable {
  public let name: String
  public let kind: String
  public let required: Bool
  public let positional: Bool
  public let choices: [String]
  public let help: String
  public init(_ name: String, _ kind: String = "string", required: Bool = false, positional: Bool = false, choices: [String] = [], help: String = "") {
    self.name = name; self.kind = kind; self.required = required; self.positional = positional; self.choices = choices; self.help = help
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
  public static let commands: [ControlCommand] = [
    .init(action: "status", words: ["status"], summary: "Report app and presenter state without launching.", example: "vidprompt status --json", params: []),
    .init(action: "script_list", words: ["script", "list"], summary: "List library scripts.", example: "vidprompt script list", params: []),
    .init(action: "script_import", words: ["script", "import"], summary: "Import a file, keeping Markdown linked.", example: "vidprompt script import ./script.md --request-id take1", params: [.init("path", "path", required: true, positional: true), .init("requestId")]),
    .init(action: "script_open", words: ["script", "open"], summary: "Select a script by id or exact title.", example: "vidprompt script open 'My Script'", params: [.init("script", required: true, positional: true), .init("show", "boolean")]),
    .init(action: "present", words: ["present"], summary: "Present a script without taking focus.", example: "vidprompt present 'My Script'", params: [.init("script", positional: true), .init("show", "boolean")]),
    .init(action: "pause", words: ["pause"], summary: "Pause the presented script.", example: "vidprompt pause", params: []),
    .init(action: "resume", words: ["resume"], summary: "Resume the presented script.", example: "vidprompt resume", params: []),
    .init(action: "back_to_start", words: ["back-to-start"], summary: "Reset the reading position.", example: "vidprompt back-to-start", params: []),
    .init(action: "set_mode", words: ["set-mode"], summary: "Set tracking mode.", example: "vidprompt set-mode manual", params: [.init("mode", "choice", required: true, positional: true, choices: ["voice", "manual"])]),
    .init(action: "set_zoom", words: ["set-zoom"], summary: "Set the interface zoom percentage.", example: "vidprompt set-zoom 150", params: [.init("zoom", "integer", required: true, positional: true, choices: ["100", "110", "125", "150", "175", "200"])])
  ]
  public static func command(action: String) -> ControlCommand? { commands.first { $0.action == action } }
  public static func dataRoot(bundleIdentifier: String?, arguments: [String]) -> URL {
    if let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count { return URL(fileURLWithPath: arguments[i + 1]) }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("VidPrompt", isDirectory: true)
  }
  public static func socketURL(dataRoot: URL) -> URL { dataRoot.appendingPathComponent("control.sock") }
}
