import Foundation
import PrompterCore
import XCTest

final class ControlCLITests: XCTestCase {
  func testCommandParsingHelpAndManifestShareTheTable() throws {
    for command in ControlProtocol.commands {
      let values = command.params.filter(\.required).map { $0.choices.first ?? "example" }
      let invocation = try ControlCLI.parse(["--json"] + command.words + values + ["--data-directory", "/tmp/check"])
      XCTAssertEqual(invocation.action, command.action); XCTAssertTrue(invocation.json)
      XCTAssertEqual(invocation.dataDirectory, "/tmp/check")
      XCTAssertTrue(ControlCLI.help().contains(command.example))
      let flags = command.params.filter(\.required).flatMap { ["--" + $0.name, $0.choices.first ?? "example"] }
      XCTAssertEqual(try ControlCLI.parse(command.words + flags).action, command.action)
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
