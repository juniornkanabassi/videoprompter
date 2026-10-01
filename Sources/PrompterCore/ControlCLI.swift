import Foundation

public enum ControlCLI {
  public struct Invocation: Sendable {
    public var action: String
    public var params: [String: String]
    public var json: Bool
    public var dataDirectory: String?
  }
  public struct UsageError: Error, CustomStringConvertible { public let description: String }
  public static func parse(_ argv: [String]) throws -> Invocation {
    var words: [String] = []; var flags: [String: String] = [:]
    var json = false; var directory: String?; var show = false
    var i = 0
    while i < argv.count {
      let word = argv[i]; i += 1
      switch word {
      case "--json": json = true
      case "--show": show = true
      case "--help", "-h": return Invocation(action: "help", params: [:], json: json, dataDirectory: directory)
      default:
        if word.hasPrefix("--") {
          let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          let flag = String(parts[0])
          let value: String
          if parts.count == 2 { value = String(parts[1]) }
          else {
            guard i < argv.count, !argv[i].hasPrefix("--") else { throw UsageError(description: "Missing value for \(word)") }
            value = argv[i]; i += 1
          }
          if flag == "--data-directory" { directory = value }
          else {
            let name = flag == "--request-id" ? "requestId" : String(flag.dropFirst(2))
            guard flags[name] == nil else { throw UsageError(description: "Repeated flag \(flag)") }
            flags[name] = value
          }
        } else { words.append(word) }
      }
    }
    if words == ["mcp-manifest"], flags.isEmpty, !show { return Invocation(action: "mcp-manifest", params: [:], json: true, dataDirectory: directory) }
    guard let command = ControlProtocol.commands.first(where: { words.starts(with: $0.words) }) else { throw UsageError(description: "Unknown command. Use vidprompt --help.") }
    let values = Array(words.dropFirst(command.words.count)); let positional = command.params.filter(\.positional)
    guard values.count <= positional.count else { throw UsageError(description: "Too many arguments for \(command.words.joined(separator: " "))") }
    for (param, value) in zip(positional, values) {
      guard flags[param.name] == nil else { throw UsageError(description: "Supply \(param.name) once") }
      flags[param.name] = value
    }
    if show {
      guard command.params.contains(where: { $0.name == "show" }) else { throw UsageError(description: "--show is supported by script open and present") }
      flags["show"] = "true"
    }
    guard flags.keys.allSatisfy({ name in command.params.contains { $0.name == name } }) else { throw UsageError(description: "Unknown flag for \(command.words.joined(separator: " "))") }
    for p in command.params {
      guard let value = flags[p.name] else {
        if p.required { throw UsageError(description: "Missing \(p.name). Example: \(command.example)") }; continue
      }
      guard !value.isEmpty || !p.required, p.choices.isEmpty || p.choices.contains(value), p.kind != "boolean" || ["true", "false"].contains(value), p.kind != "integer" || Int(value) != nil else { throw UsageError(description: "Invalid \(p.name). Valid values: \(p.choices.joined(separator: ", "))") }
    }
    return Invocation(action: command.action, params: flags, json: json, dataDirectory: directory)
  }
  public static func help() -> String {
    "Usage: vidprompt <command> [options]\nOptions: --json --show (script open/present only) --data-directory <dir> --help\nExit: 0 success, 1 action/connection error, 2 usage error.\n" + ControlProtocol.commands.map { "\n\($0.words.joined(separator: " ")) — \($0.summary)\n  \($0.example)\n" + $0.params.map { "  --\($0.name)\($0.kind == "boolean" ? "" : " <value>")\($0.required ? " required" : " optional")\($0.positional ? " or positional" : "")\($0.choices.isEmpty ? "" : "; " + $0.choices.joined(separator: "|"))" }.joined(separator: "\n") }.joined(separator: "\n") + "\nmcp-manifest — print MCP tools JSON from this command table.\n  vidprompt mcp-manifest\n"
  }
  public static func manifest(version: String = "dev") -> [String: Any] {
    ["serverInfo": ["name": "vidprompt", "version": version], "tools": ControlProtocol.commands.map { command -> [String: Any] in
      var properties: [String: Any] = [:]
      for p in command.params {
        var spec: [String: Any] = ["type": p.kind == "integer" ? "integer" : p.kind == "boolean" ? "boolean" : "string", "description": p.help.isEmpty ? p.name : p.help]
        if !p.choices.isEmpty { spec["enum"] = p.kind == "integer" ? p.choices.compactMap(Int.init) as Any : p.choices }
        properties[p.name] = spec
      }
      return ["name": command.action, "description": command.summary, "command": command.words, "inputSchema": ["type": "object", "properties": properties, "required": command.params.filter(\.required).map(\.name), "additionalProperties": false]]
    }]
  }
}
