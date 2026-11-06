import Darwin
import Foundation
import PrompterCore
import XCTest
@testable import VideoPrompter

@MainActor final class QAControlRegressionTests: XCTestCase {
  private var cli: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VideoPrompterCLI") }
  private var shim: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mcp/videoprompter-mcp.mjs") }

  private func run(_ executable: URL, _ arguments: [String], root: URL, input: Data? = nil, keepInputOpen: Bool = false) async throws -> Data {
    let output = root.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = executable; process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["VIDEOPROMPTER_CLI"] = cli.path
    environment["VIDEOPROMPTER_APP"] = root.appendingPathComponent("no-launch.app").path
    process.environment = environment
    let pipe = Pipe()
    process.standardInput = pipe; process.standardOutput = handle; process.standardError = handle
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? pipe.fileHandleForWriting.close() }
    if let input { try pipe.fileHandleForWriting.write(contentsOf: input) }
    if !keepInputOpen { try pipe.fileHandleForWriting.close() }
    let deadline = ContinuousClock.now + .seconds(8)
    while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertFalse(process.isRunning, "Command stalled: \(arguments)")
    if process.isRunning { process.terminate(); process.waitUntilExit() }
    XCTAssertEqual(process.terminationStatus, 0)
    return try Data(contentsOf: output)
  }

  func testLargeEscapedScriptReadThroughCLIAndMCP() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpq-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let markdown = "# Expansion\n" + String(repeating: "\t", count: 11 * 1024 * 1024)
    let server = ControlServer(socketURL: ControlProtocol.socketURL(dataRoot: root)) { _, _ in .ok(["markdown": markdown]) }
    try server.start(); defer { server.stop() }
    let reply = try await run(cli, ["--data-directory", root.path, "script", "read", "large", "--json"], root: root)
    XCTAssertGreaterThan(reply.count, 20 * 1024 * 1024)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    XCTAssertEqual((json["result"] as? [String: String])?["markdown"], markdown)
    let request = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"script_read\",\"arguments\":{\"script\":\"large\"}}}\n".utf8)
    let response = try await run(URL(fileURLWithPath: "/usr/bin/env"), ["node", shim.path, "--data-directory", root.path], root: root, input: request)
    let mcp = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    let result = try XCTUnwrap(mcp["result"] as? [String: Any])
    XCTAssertEqual(result["isError"] as? Bool, false)
    let content = try XCTUnwrap((result["content"] as? [[String: String]])?.first?["text"])
    let inner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    XCTAssertEqual((inner["result"] as? [String: String])?["markdown"], markdown)
  }

  func testLiteralDashThroughCLIAndMCPDoesNotReadStdinOrBlockPing() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpq-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = ControlServer(socketURL: ControlProtocol.socketURL(dataRoot: root)) { _, params in .ok(["markdown": params["text"] ?? ""]) }
    try server.start(); defer { server.stop() }
    let reply = try await run(cli, ["--data-directory", root.path, "script", "create", "--text=-", "--json"], root: root, keepInputOpen: true)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    XCTAssertEqual((json["result"] as? [String: String])?["markdown"], "-")
    let requests = Data("""
      {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"script_create","arguments":{"title":"Dash","text":"-"}}}
      {"jsonrpc":"2.0","id":2,"method":"ping"}

      """.utf8)
    let response = try await run(URL(fileURLWithPath: "/usr/bin/env"), ["node", shim.path, "--data-directory", root.path], root: root, input: requests)
    let rows = try response.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.last?["id"] as? Int, 2)
    let result = try XCTUnwrap(rows.first?["result"] as? [String: Any])
    XCTAssertEqual(result["isError"] as? Bool, false)
    XCTAssertTrue(((result["content"] as? [[String: String]])?.first?["text"] ?? "").contains("\"markdown\":\"-\""))
    let stdinReply = try await run(cli, ["--data-directory", root.path, "script", "create", "--text", "-", "--json"], root: root, input: Data("from stdin".utf8))
    XCTAssertTrue(String(decoding: stdinReply, as: UTF8.self).contains("from stdin"))
  }

  func testSlowSocketReaderCannotBlockOtherControlCommandsAndExpires() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpq-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = ControlProtocol.socketURL(dataRoot: root)
    let server = ControlServer(socketURL: path) { action, _ in
      .ok(["markdown": action == "script_read" ? String(repeating: "\t", count: 11 * 1024 * 1024) : "ready"])
    }
    try server.start(); defer { server.stop() }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.path.utf8) + [0]) }
    XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
    let request = Data("{\"id\":\"slow\",\"action\":\"script_read\"}\n".utf8)
    _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    try await Task.sleep(for: .milliseconds(300))
    let start = ContinuousClock.now
    let response = try await run(cli, ["--data-directory", root.path, "status", "--json"], root: root)
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("ready"))
    try await Task.sleep(for: .seconds(5))
    let expired = await Task.detached {
      var timeout = timeval(tv_sec: 1, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var buffer = [UInt8](repeating: 0, count: 8192)
      var count: Int
      repeat { count = recv(fd, &buffer, buffer.count, 0) } while count > 0
      return count == 0
    }.value
    XCTAssertTrue(expired, "The five-second send deadline must close a stalled reader")
  }
}
