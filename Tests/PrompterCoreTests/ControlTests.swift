import AppKit
import Darwin
import PrompterCore
import XCTest
@testable import JuniorPrompter

@MainActor final class ControlTests: XCTestCase {
  func testActionsUseGUIStoreAndImportIsIdempotent() async throws {
    _ = NSApplication.shared
    OffscreenPanels.install(); defer { OffscreenPanels.uninstall() }
    let root = URL(fileURLWithPath: "/private/tmp/jpc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "ControlTests.\(UUID())")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await store.reload()
    let presenter = PresenterController()
    defer { presenter.closeNow() }
    let actions = ControlActions(store: store, presenter: presenter)
    for action in ["pause", "resume", "back_to_start"] {
      let reply = await actions.handle(action, [:])
      XCTAssertEqual((reply.body["error"] as? [String: String])?["code"], "no_active_script")
    }
    let file = root.deletingLastPathComponent().appendingPathComponent("import-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: file) }
    try "# Hello\n\nOne two three.".write(to: file, atomically: true, encoding: .utf8)
    async let first = actions.handle("script_import", ["path": file.path, "requestId": "one"])
    async let second = actions.handle("script_import", ["path": file.path, "requestId": "one"])
    let replies = await [first, second]
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertEqual(store.selectedID, store.scripts.first?.id)
    XCTAssertEqual(replies.compactMap { ($0.body["result"] as? [String: Any])?["repeated"] as? Bool }.filter { $0 }.count, 1)
    XCTAssertNotNil(store.scripts.first?.metadata.linkedPath)
    let id = try XCTUnwrap(store.selectedID).uuidString
    let title = store.scripts[0].metadata.title
    let reply1 = (await actions.handle("script_open", ["script": title]))
    XCTAssertEqual(reply1.body["ok"] as? Bool, true)
    let reply2 = (await actions.handle("script_open", ["script": id]))
    XCTAssertEqual(reply2.body["ok"] as? Bool, true)
    let reply3 = (await actions.handle("script_list", [:]))
    XCTAssertEqual(reply3.body["ok"] as? Bool, true)
    _ = await actions.handle("set_mode", ["mode": "manual"])
    XCTAssertEqual(store.settings.mode, "Manual")
    _ = await actions.handle("set_zoom", ["zoom": "150"])
    XCTAssertEqual(store.uiZoom, 1.5)
    let reply4 = (await actions.handle("set_zoom", ["zoom": "130"]))
    XCTAssertEqual(reply4.body["ok"] as? Bool, false)
    if !CameraModel.shared.presentsWithVideo {
      _ = await actions.handle("present", ["script": id])
      XCTAssertEqual(store.session.activeScriptID?.uuidString, id)
      XCTAssertEqual(OffscreenPanels.activations, 0)
      _ = await actions.handle("present", ["script": id, "show": "true"])
    }
    let status = (await actions.handle("status", [:])).body["result"] as? [String: Any]
    for key in ["running", "app", "version", "library", "scripts", "selected", "presenter", "script", "state", "mode", "position", "zoom", "textSize"] { XCTAssertNotNil(status?[key]) }
    _ = try await store.createScript(title: title.uppercased(), markdown: "duplicate")
    let reply5 = (await actions.handle("script_open", ["script": title]))
    XCTAssertEqual((reply5.body["error"] as? [String: Any])?["code"] as? String, "ambiguous_script")
    let reply6 = (await actions.handle("script_open", ["script": "absent"]))
    XCTAssertEqual((reply6.body["error"] as? [String: Any])?["code"] as? String, "script_not_found")
    for command in ControlProtocol.commands {
      let reply7 = (await actions.handle(command.action, [:]))
      XCTAssertNotEqual((reply7.body["error"] as? [String: Any])?["code"] as? String, "unknown_action")
    }
  }
  func testSocketPrivacyFramingAndOwnership() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/jpc-\(UUID().uuidString.prefix(8))")
    let path = root.appendingPathComponent("control.sock")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = ControlServer(socketURL: path) { action, _ in .ok(["action": action]) }
    try server.start(); defer { server.stop() }
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let other = ControlServer(socketURL: path) { _, _ in .ok([:]) }
    XCTAssertThrowsError(try other.start())
    other.stop()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    let responses = try await Task.detached {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
      var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.path.utf8) + [0]) }
      let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
      let bytes = Data("bad json\n{\"id\":\"2\",\"action\":\"status\"}\n".utf8)
      _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
      var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
      while result.filter({ $0 == 10 }).count < 2 {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw CocoaError(.fileReadUnknown) }; result.append(contentsOf: buffer.prefix(n))
      }
      return result
    }.value
    let lines = try responses.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    XCTAssertEqual((lines[0]["error"] as? [String: String])?["code"], "bad_request")
    XCTAssertEqual(lines[1]["id"] as? String, "2")
    server.stop()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.path.utf8) + [0]) }
    XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
    Darwin.close(fd)
    try server.start()
    server.stop()
    try "leave me".write(to: path, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try server.start())
    XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "leave me")
  }
}
