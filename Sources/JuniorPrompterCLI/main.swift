import Darwin
import Foundation
import PrompterCore

func emit(_ value: [String: Any], json: Bool) {
  if json { print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!) }
  else if let error = value["error"] as? [String: Any] { fputs("\(error["message"] ?? "Action failed")\n", stderr) }
  else if let result = value["result"] { print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed]), encoding: .utf8)!) }
}
func failure(_ message: String, code: String = "connection", json: Bool, exitCode: Int32 = 1) -> Never {
  emit(["ok": false, "error": ["code": code, "message": message]], json: json); exit(exitCode)
}
func connectSocket(_ path: String) -> Int32? {
  guard path.utf8.count <= 103 else { return nil }
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  var yes: Int32 = 1; var timeout = timeval(tv_sec: 30, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
  let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  var uid: uid_t = 0; var gid: gid_t = 0
  guard connected == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); return nil }
  return fd
}
let argv = Array(CommandLine.arguments.dropFirst())
var invocation: ControlCLI.Invocation
 do { invocation = try ControlCLI.parse(argv) }
 catch { failure(String(describing: error), code: "usage", json: argv.contains("--json"), exitCode: 2) }
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
let ownApp: URL? = contents.lastPathComponent == "Contents" && executable.deletingLastPathComponent().lastPathComponent == "Helpers" ? contents.deletingLastPathComponent() : nil
let info = ownApp.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
let bundleID = info?["CFBundleIdentifier"] as? String ?? (invocation.alpha ? ControlProtocol.alphaBundleID : ControlProtocol.stableBundleID)
let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
if invocation.action == "help" { print(ControlCLI.help()); exit(0) }
if invocation.action == "mcp-manifest" { print(String(data: try! JSONSerialization.data(withJSONObject: ControlCLI.manifest(version: version), options: [.sortedKeys]), encoding: .utf8)!); exit(0) }
var arguments = ["juniorprompter"]
if let dir = invocation.dataDirectory { arguments += ["--data-directory", URL(fileURLWithPath: dir).path] }
let root = ControlProtocol.dataRoot(bundleIdentifier: bundleID, arguments: arguments)
let path = ControlProtocol.socketURL(dataRoot: root).path
if path.utf8.count > 103 { failure("Control socket path exceeds 103 bytes. Use a shorter --data-directory.", json: invocation.json) }
if let value = invocation.params["path"] { invocation.params["path"] = URL(fileURLWithPath: value).path }
var fd = connectSocket(path)
if fd == nil && invocation.action == "status" { emit(["ok": true, "result": ["running": false, "app": bundleID, "socket": path]], json: invocation.json); exit(0) }
if fd == nil {
  let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  var launch = ["-g"]
  if let custom = ProcessInfo.processInfo.environment["JUNIORPROMPTER_APP"] { launch += ["-a", custom] }
  else if let ownApp { launch += ["-a", ownApp.path] }
  else { launch += ["-b", bundleID] }
  if invocation.dataDirectory != nil { launch += ["-n", "--args", "--data-directory", root.path] }
  process.arguments = launch
  process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
  do { try process.run(); process.waitUntilExit() } catch { failure("Could not launch JuniorPrompter in the background.", json: invocation.json) }
  let deadline = Date().addingTimeInterval(10)
  while fd == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.1); fd = connectSocket(path) }
}
guard let fd else { failure("JuniorPrompter is running but does not answer on \(path); it may be older than 1.0.0. Quit it and try again.", json: invocation.json) }
defer { Darwin.close(fd) }
let request: [String: Any] = ["id": UUID().uuidString, "action": invocation.action, "params": invocation.params]
let data = try JSONSerialization.data(withJSONObject: request) + Data([10])
guard data.count - 1 <= ControlProtocol.maxRequestBytes else { failure("Request exceeds 65536 bytes.", code: "usage", json: invocation.json, exitCode: 2) }
let sent = data.withUnsafeBytes { bytes -> Bool in
  var offset = 0
  while offset < bytes.count {
    let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
    if count < 0 && errno == EINTR { continue }
    guard count > 0 else { return false }; offset += count
  }
  return true
}
guard sent else { failure("The app closed the control connection.", json: invocation.json) }
var response = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
while !response.contains(10) {
  let count = recv(fd, &buffer, buffer.count, 0)
  if count < 0 && errno == EINTR { continue }
  guard count > 0, response.count < 20 * 1024 * 1024 else { failure("No valid response from JuniorPrompter within 30 seconds.", json: invocation.json) }
  response.append(contentsOf: buffer.prefix(count))
}
guard let end = response.firstIndex(of: 10), var value = try? JSONSerialization.jsonObject(with: response.prefix(upTo: end)) as? [String: Any] else { failure("Invalid app response.", json: invocation.json) }
value.removeValue(forKey: "id"); emit(value, json: invocation.json)
exit(value["ok"] as? Bool == true ? 0 : 1)
