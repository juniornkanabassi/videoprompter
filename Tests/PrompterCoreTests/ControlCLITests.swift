import Foundation
import PrompterCore
import XCTest

final class ControlCLITests: XCTestCase {
  func testCommandParsingHelpAndManifestShareTheTable() throws {
    for command in ControlProtocol.commands {
      let values = command.params.filter(\.required).map { $0.choices.first ?? "example" }
      let invocation = try ControlCLI.parse(["--json"] + command.words + values + ["--alpha", "--data-directory", "/tmp/check"])
      XCTAssertEqual(invocation.action, command.action); XCTAssertTrue(invocation.json); XCTAssertTrue(invocation.alpha)
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
    let tools = try XCTUnwrap(ControlCLI.manifest()["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, ControlProtocol.commands.count)
    for (tool, command) in zip(tools, ControlProtocol.commands) {
      XCTAssertEqual(tool["name"] as? String, command.action)
      let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
      XCTAssertEqual(schema["required"] as? [String], command.params.filter(\.required).map(\.name))
    }
  }
}
