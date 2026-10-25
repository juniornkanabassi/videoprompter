import Foundation
import PrompterCore
import XCTest

final class ControlCLITests: XCTestCase {
  func testCommandParsingHelpAndManifestShareTheTable() throws {
    // A valid value for any parameter, so every command parses from the table alone.
    func sample(_ p: ControlParam) -> String {
      if let choice = p.choices.first { return choice }
      if p.kind == "boolean" { return "true" }
      if p.kind == "integer" || p.kind == "number" { return String(Int(p.range?.lowerBound ?? 1)) }
      return "example"
    }
    for command in ControlProtocol.commands {
      let required = command.params.filter(\.required)
      let values = required.filter(\.positional).map(sample)
      let named = required.filter { !$0.positional }.flatMap { [$0.flag, sample($0)] }
      let invocation = try ControlCLI.parse(["--json"] + command.words + values + named + ["--data-directory", "/tmp/check"])
      XCTAssertEqual(invocation.action, command.action); XCTAssertTrue(invocation.json)
      XCTAssertEqual(invocation.dataDirectory, "/tmp/check")
      XCTAssertTrue(ControlCLI.help().contains(command.example))
      for p in command.params { XCTAssertTrue(ControlCLI.help().contains(p.flag), p.flag) }
      let flags = required.flatMap { ["--" + $0.name, sample($0)] }
      XCTAssertEqual(try ControlCLI.parse(command.words + flags).action, command.action)
      // Every example in the help parses as written.
      let example = command.example.replacingOccurrences(of: "'", with: "\"").components(separatedBy: "\"").enumerated().flatMap { pair -> [String] in
        pair.offset % 2 == 1 ? [pair.element] : pair.element.split(separator: " ").map(String.init)
      }
      XCTAssertEqual(example.first, "videoprompter")
      XCTAssertEqual(try ControlCLI.parse(Array(example.dropFirst())).action, command.action, command.example)
    }
    XCTAssertEqual(Set(ControlProtocol.commands.map(\.action)).count, ControlProtocol.commands.count)
    // Kebab and camel spellings, bare booleans and ranges.
    XCTAssertEqual(try ControlCLI.parse(["settings", "set", "--text-size", "60", "--textWidth=80"]).params, ["textSize": "60", "textWidth": "80"])
    XCTAssertEqual(try ControlCLI.parse(["script", "delete", "--yes", "My Script"]).params, ["yes": "true", "script": "My Script"])
    XCTAssertEqual(try ControlCLI.parse(["script", "delete", "My Script", "--yes", "true"]).params["yes"], "true")
    XCTAssertEqual(try ControlCLI.parse(["record", "start", "--yes", "--request-id", "take1"]).params, ["yes": "true", "requestId": "take1"])
    XCTAssertEqual(try ControlCLI.parse(["record", "stop", "--recording", "take1"]).params, ["recording": "take1"])
    XCTAssertEqual(try ControlCLI.parse(["record", "stop", "--force"]).params, ["force": "true"])
    XCTAssertEqual(try ControlCLI.parse(["script", "export", "Intro", "--path", "/tmp/export.md", "--replace", "--yes"]).params["yes"], "true")
    for command in ["next-passage", "previous-passage"] {
      XCTAssertEqual(try ControlCLI.parse([command, "--request-id", "step1"]).params, ["requestId": "step1"])
    }
    XCTAssertEqual(try ControlCLI.parse(["script", "create", "--text", "-"]).params["text"], "-")
    XCTAssertEqual(try ControlCLI.parse(["camera", "set", "only"]).params["view"], "only")
    XCTAssertEqual(try ControlCLI.parse(["seek", "12"]).params["word"], "12")
    for args in [["settings", "set", "--speed", "301"], ["settings", "set", "--speed", "fast"], ["settings", "set", "--mirror", "yes"], ["seek", "0"],
                 ["script", "delete", "My Script"], ["record", "start"], ["camera", "set", "sideways"], ["script", "rename", "My Script"], ["presenter", "close", "--show"]] {
      XCTAssertThrowsError(try ControlCLI.parse(args), args.joined(separator: " "))
    }
    for flag in ["--request-id", "--requestId"] { XCTAssertEqual(try ControlCLI.parse(["script", "import", "a.md", flag, "same"]).params["requestId"], "same") }
    XCTAssertEqual(try ControlCLI.parse(["script", "open", "--script=--Football"]).params["script"], "--Football")
    XCTAssertEqual(try ControlCLI.parse(["--show", "present"]).params["show"], "true")
    for args in [["script", "import"], ["unknown"], ["set-mode", "timed"], ["set-zoom", "130"], ["status", "--show"], ["present", "--unknown", "x"], ["script", "import", "a", "--path", "b"]] { XCTAssertThrowsError(try ControlCLI.parse(args)) }
    XCTAssertEqual(try ControlCLI.parse(["script", "import", "--help"]).action, "help")
    XCTAssertEqual(ControlProtocol.bundleID, "com.juniornkanabassi.VidPrompt")
    // A temporary parent stands in for Application Support so the test never migrates real data.
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("videoprompter-support-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }
    XCTAssertEqual(ControlProtocol.dataRoot(bundleIdentifier: nil, arguments: ["videoprompter"], applicationSupport: support).path, support.appendingPathComponent("Video Prompter").path)
    XCTAssertEqual(ControlProtocol.dataRoot(bundleIdentifier: nil, arguments: ["videoprompter", "--data-directory", "/tmp/check"], applicationSupport: support).path, "/tmp/check")
    XCTAssertEqual(ControlCLI.manifest()["serverInfo"] as? [String: String], ["name": "videoprompter", "version": "dev"])
    let tools = try XCTUnwrap(ControlCLI.manifest()["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, ControlProtocol.commands.count)
    for (tool, command) in zip(tools, ControlProtocol.commands) {
      XCTAssertEqual(tool["name"] as? String, command.action)
      let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
      XCTAssertEqual(schema["required"] as? [String], command.params.filter(\.required).map(\.name))
    }
    let names = tools.compactMap { $0["name"] as? String }
    for action in ["presenter_close", "next_passage", "previous_passage", "seek", "settings_get", "settings_set", "script_create", "script_read", "script_rename",
                   "script_delete", "script_restore", "folder_list", "script_move", "script_export", "camera_list", "camera_select", "camera_set", "camera_guides",
                   "record_start", "record_stop", "preset_apply", "microphone_list"] {
      XCTAssertTrue(names.contains(action), action)
    }
    let settings = try XCTUnwrap(tools.first { $0["name"] as? String == "settings_set" }?["inputSchema"] as? [String: Any])
    let speed = try XCTUnwrap((settings["properties"] as? [String: Any])?["speed"] as? [String: Any])
    XCTAssertEqual(speed["type"] as? String, "integer"); XCTAssertEqual(speed["minimum"] as? Int, 20); XCTAssertEqual(speed["maximum"] as? Int, 300)
    let record = try XCTUnwrap(tools.first { $0["name"] as? String == "record_start" }?["inputSchema"] as? [String: Any])
    XCTAssertEqual(record["required"] as? [String], ["yes"])
  }
  func testLegacyFolderMovesOnceToVideoPrompter() throws {
    let fileManager = FileManager.default
    let parent = fileManager.temporaryDirectory.appendingPathComponent("videoprompter-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: parent) }
    let legacy = parent.appendingPathComponent("VidPrompt"), current = parent.appendingPathComponent("Video Prompter")
    // Only the legacy folder exists: it moves with its contents.
    try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: legacy.appendingPathComponent("LibraryIndex.json"))
    XCTAssertEqual(ControlProtocol.migrateLegacyFolder(in: parent).path, current.path)
    XCTAssertFalse(fileManager.fileExists(atPath: legacy.path))
    XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("LibraryIndex.json"), encoding: .utf8), "old")
    // Idempotent: a second call changes nothing.
    XCTAssertEqual(ControlProtocol.migrateLegacyFolder(in: parent).path, current.path)
    XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("LibraryIndex.json"), encoding: .utf8), "old")
    // A new folder that already exists is left alone, and so is a reappeared legacy folder.
    try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: legacy.appendingPathComponent("LibraryIndex.json"))
    ControlProtocol.migrateLegacyFolder(in: parent)
    XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("LibraryIndex.json"), encoding: .utf8), "old")
    XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("LibraryIndex.json"), encoding: .utf8), "stale")
    // A symlinked legacy folder is never moved.
    let linked = parent.appendingPathComponent("linked", isDirectory: true), target = parent.appendingPathComponent("target", isDirectory: true)
    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: linked, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: linked.appendingPathComponent("VidPrompt"), withDestinationURL: target)
    XCTAssertEqual(ControlProtocol.migrateLegacyFolder(in: linked, move: { _, _ in
      XCTFail("A symlinked legacy folder must never be moved")
    }).path, linked.appendingPathComponent("Video Prompter").path)
    XCTAssertFalse(fileManager.fileExists(atPath: linked.appendingPathComponent("Video Prompter").path))
    XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: linked.appendingPathComponent("VidPrompt").path), target.path)
  }
  func testLegacySocketDefersMigrationUntilRemoved() throws {
    let fileManager = FileManager.default
    let parent = fileManager.temporaryDirectory.appendingPathComponent("videoprompter-migration-socket-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: parent) }
    let legacy = parent.appendingPathComponent("VidPrompt", isDirectory: true)
    let current = parent.appendingPathComponent("Video Prompter", isDirectory: true)
    let contents = Data("existing library".utf8)
    try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
    try contents.write(to: legacy.appendingPathComponent("LibraryIndex.json"))
    let marker = ControlProtocol.socketURL(dataRoot: legacy)
    try Data().write(to: marker)
    XCTAssertEqual(ControlProtocol.migrateLegacyFolder(in: parent, move: { _, _ in
      XCTFail("A legacy socket must prevent moving the folder")
    }).path, legacy.path)
    XCTAssertEqual(ControlProtocol.dataRoot(bundleIdentifier: nil, arguments: ["videoprompter", "status"], applicationSupport: parent).path, legacy.path)
    XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
    XCTAssertFalse(fileManager.fileExists(atPath: current.path))
    XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("LibraryIndex.json")), contents)
    try fileManager.removeItem(at: marker)
    XCTAssertEqual(ControlProtocol.dataRoot(bundleIdentifier: nil, arguments: ["videoprompter", "status"], applicationSupport: parent).path, current.path)
    XCTAssertFalse(fileManager.fileExists(atPath: legacy.path))
    XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("LibraryIndex.json")), contents)
  }
  func testFailedLegacyMoveKeepsDataAndRecordingsUsableAndRetries() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory.appendingPathComponent("videoprompter-migration-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: fixture) }
    // Both dataRoot and CameraRecorder.recordingsFolder use this shared migration path.
    for (folder, filename) in [("Application Support", "LibraryIndex.json"), ("Movies", "take.mov")] {
      let parent = fixture.appendingPathComponent(folder, isDirectory: true)
      let legacy = parent.appendingPathComponent("VidPrompt", isDirectory: true)
      let current = parent.appendingPathComponent("Video Prompter", isDirectory: true)
      let contents = Data("existing \(filename)".utf8)
      try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
      try contents.write(to: legacy.appendingPathComponent(filename))
      var attempts = 0
      let resolved = ControlProtocol.migrateLegacyFolder(in: parent, move: { source, destination in
        attempts += 1
        XCTAssertEqual(source.path, legacy.path)
        XCTAssertEqual(destination.path, current.path)
        throw CocoaError(.fileWriteNoPermission)
      })
      XCTAssertEqual(attempts, 1)
      XCTAssertEqual(resolved.path, legacy.path)
      // Callers create their resolved folder before using it. This must not create an empty replacement.
      try fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
      XCTAssertEqual(try Data(contentsOf: resolved.appendingPathComponent(filename)), contents)
      XCTAssertFalse(fileManager.fileExists(atPath: current.path))
      try Data("new content".utf8).write(to: resolved.appendingPathComponent("after-failure"))
      XCTAssertEqual(ControlProtocol.migrateLegacyFolder(in: parent).path, current.path)
      XCTAssertFalse(fileManager.fileExists(atPath: legacy.path))
      XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent(filename)), contents)
      XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("after-failure"), encoding: .utf8), "new content")
    }
  }
}
