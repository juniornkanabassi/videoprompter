import Foundation

public enum ControlCLI {
  public struct Invocation: Sendable {
    public var action: String
    public var params: [String: String]
    public var json: Bool
    public var dataDirectory: String?
  }
  public struct UsageError: Error, CustomStringConvertible { public let description: String }
  /// `--text-size` and `--textSize` both name the `textSize` parameter.
  static func parameterName(flag: String) -> String {
    let parts = flag.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false)
    guard let first = parts.first else { return "" }
    return String(first) + parts.dropFirst().map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }.joined()
  }
  /// Parameters that may stand alone as `--yes`, without a value.
  private static let booleanNames = Set(ControlProtocol.commands.flatMap(\.params).filter { $0.kind == "boolean" }.map(\.name))
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
          let name = parameterName(flag: flag)
          let value: String
          if parts.count == 2 { value = String(parts[1]) }
          else if booleanNames.contains(name), !(i < argv.count && ["true", "false", "1", "0"].contains(argv[i])) { value = "true" }
          else {
            guard i < argv.count, !argv[i].hasPrefix("--") else { throw UsageError(description: "Missing value for \(word)") }
            value = argv[i]; i += 1
          }
          if flag == "--data-directory" { directory = value }
          else {
            guard flags[name] == nil else { throw UsageError(description: "Repeated flag \(flag)") }
            flags[name] = value
          }
        } else { words.append(word) }
      }
    }
    if words == ["mcp-manifest"], flags.isEmpty, !show { return Invocation(action: "mcp-manifest", params: [:], json: true, dataDirectory: directory) }
    guard let command = ControlProtocol.commands.first(where: { words.starts(with: $0.words) }) else { throw UsageError(description: "Unknown command. Use videoprompter --help.") }
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
    guard flags.keys.allSatisfy({ name in command.params.contains { $0.name == name } }) else { throw UsageError(description: "Unknown flag for \(command.words.joined(separator: " ")). Use videoprompter --help.") }
    for p in command.params {
      guard let value = flags[p.name] else {
        if p.required { throw UsageError(description: "Missing \(p.flag). Example: \(command.example)") }; continue
      }
      guard p.accepts(value) else { throw UsageError(description: "Invalid \(p.flag). Valid values: \(p.validValues)") }
    }
    return Invocation(action: command.action, params: flags, json: json, dataDirectory: directory)
  }
  private static func usage(_ p: ControlParam) -> String {
    var line = "  \(p.flag)\(p.kind == "boolean" ? "" : " <value>")\(p.required ? " required" : " optional")\(p.positional ? " or positional" : "")"
    if !p.choices.isEmpty { line += "; " + p.choices.joined(separator: "|") }
    else if p.range != nil { line += "; " + p.validValues }
    if !p.help.isEmpty { line += ". " + p.help }
    return line
  }
  public static func help() -> String {
    "Usage: videoprompter <command> [options]\nOptions: --json --show (script open/present only) --data-directory <dir> --help\nFlags can be written --text-size or --textSize, with a space or =.\nExit: 0 success, 1 action/connection error, 2 usage error.\n" + ControlProtocol.commands.map { "\n\($0.words.joined(separator: " ")): \($0.summary)\n  \($0.example)\n" + $0.params.map(usage).joined(separator: "\n") }.joined(separator: "\n") + "\nmcp-manifest: print MCP tools JSON from this command table.\n  videoprompter mcp-manifest\n"
  }
  public static func manifest(version: String = "dev") -> [String: Any] {
    ["serverInfo": ["name": "videoprompter", "version": version], "tools": ControlProtocol.commands.map { command -> [String: Any] in
      var properties: [String: Any] = [:]
      for p in command.params {
        let type = p.kind == "integer" ? "integer" : p.kind == "number" ? "number" : p.kind == "boolean" ? "boolean" : "string"
        var spec: [String: Any] = ["type": type, "description": p.help.isEmpty ? p.name : p.help]
        if !p.choices.isEmpty { spec["enum"] = p.kind == "integer" ? p.choices.compactMap(Int.init) as Any : p.choices }
        if let range = p.range {
          spec["minimum"] = p.kind == "integer" ? Int(range.lowerBound) as Any : range.lowerBound
          spec["maximum"] = p.kind == "integer" ? Int(range.upperBound) as Any : range.upperBound
        }
        properties[p.name] = spec
      }
      return ["name": command.action, "description": command.summary, "command": command.words, "inputSchema": ["type": "object", "properties": properties, "required": command.params.filter(\.required).map(\.name), "additionalProperties": false]]
    }]
  }
}
