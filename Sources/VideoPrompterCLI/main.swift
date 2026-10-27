import Darwin
import Foundation
import PrompterCore

func emit(_ value: [String: Any], json: Bool) {
  if json { print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!) }
  else if let error = value["error"] as? [String: Any] { fputs("\(error["message"] ?? "Action failed")\n", stderr) }
  else if let result = value["result"] as? [String: Any] {
    if let scripts = result["scripts"] as? [[String: Any]] {
      if scripts.isEmpty { print("No scripts.") }
      for script in scripts { print("\(script["id"] ?? "")  \(script["title"] ?? "")") }
    } else if let key = ["folders", "presets", "cameras", "microphones"].first(where: { result[$0] is [[String: Any]] }), let rows = result[key] as? [[String: Any]] {
      if rows.isEmpty { print("No \(key).") }
      for row in rows { print("\(row["id"] ?? "")  \(row["name"] ?? "")\(row["selected"] as? Bool == true ? "  (selected)" : "")") }
    } else if let running = result["running"] as? Bool {
      if !running { print("Video Prompter is not running.") }
      else {
        let selected = result["selected"] as? [String: Any]
        let camera = (result["camera"] as? [String: Any])?["view"] ?? "off"
        let recording = (result["recording"] as? [String: Any])?["active"] as? Bool == true ? ", recording" : ""
        print("Video Prompter \(result["version"] ?? ""): \(result["state"] ?? "stopped"), \(result["mode"] ?? "voice"), speed \(result["speed"] ?? 120) wpm, zoom \(result["zoom"] ?? 100)%, camera \(camera)\(recording); selected: \(selected?["title"] ?? "none")")
      }
    } else if let markdown = result["markdown"] as? String {
      print(markdown)
    } else if let file = result["file"] as? String {
      print("Saved \(file)")
    } else if let title = result["title"] {
      print("\(title) (\(result["id"] ?? ""))\(result["linked"] as? Bool == true ? ", linked" : "")\(result["repeated"] as? Bool == true ? ", repeated" : "")")
    } else {
      print(result.keys.sorted().map { "\($0): \(result[$0]!)" }.joined(separator: ", "))
    }
  }
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
/// Whether a copy of the app is running already: a process whose executable is `exact` when given (this helper's
/// own app, so a test copy elsewhere never counts), else any `…/Contents/MacOS/<name>`. Costs well under a millisecond.
func appRunning(executable name: String, exact: String? = nil) -> Bool {
  var pids = [pid_t](repeating: 0, count: 4096)
  let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
  var path = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
  for pid in pids.prefix(max(0, count)) where pid > 0 && pid != getpid() {
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
    let running = String(cString: path)
    if exact.map({ running == $0 || running == "/private" + $0 }) ?? running.hasSuffix("/Contents/MacOS/" + name) { return true }
  }
  return false
}
let argv = Array(CommandLine.arguments.dropFirst())
var invocation: ControlCLI.Invocation
 do { invocation = try ControlCLI.parse(argv) }
 catch { failure(String(describing: error), code: "usage", json: argv.contains("--json"), exitCode: 2) }
var executablePathSize: UInt32 = 0
_ = _NSGetExecutablePath(nil, &executablePathSize)
var executablePath = [CChar](repeating: 0, count: Int(executablePathSize))
_ = _NSGetExecutablePath(&executablePath, &executablePathSize)
let executable = URL(fileURLWithPath: String(cString: executablePath)).resolvingSymlinksInPath()
let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
let ownApp: URL? = contents.lastPathComponent == "Contents" && executable.deletingLastPathComponent().lastPathComponent == "Helpers" ? contents.deletingLastPathComponent() : nil
let info = ownApp.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
let bundleID = info?["CFBundleIdentifier"] as? String ?? ControlProtocol.bundleID
let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
if invocation.action == "help" { print(ControlCLI.help()); exit(0) }
if invocation.action == "mcp-manifest" { print(String(data: try! JSONSerialization.data(withJSONObject: ControlCLI.manifest(version: version), options: [.sortedKeys]), encoding: .utf8)!); exit(0) }
var arguments = ["videoprompter"]
if let dir = invocation.dataDirectory { arguments += ["--data-directory", URL(fileURLWithPath: dir).path] }
let root = ControlProtocol.dataRoot(bundleIdentifier: bundleID, arguments: arguments)
let path = ControlProtocol.socketURL(dataRoot: root).path
if path.utf8.count > 103 { failure("Control socket path exceeds 103 bytes. Use a shorter --data-directory.", json: invocation.json) }
if let value = invocation.params["path"] { invocation.params["path"] = URL(fileURLWithPath: value).path }
// `--text -` reads the script from standard input; the request still has to fit in 64 KB.
if invocation.params["text"] == "-" {
  guard let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8), !text.isEmpty else {
    failure("Standard input was empty or not UTF-8 text.", code: "usage", json: invocation.json, exitCode: 2)
  }
  invocation.params["text"] = text
}
var fd = connectSocket(path)
if fd == nil && invocation.action == "status" { emit(["ok": true, "result": ["running": false, "app": bundleID, "socket": path]], json: invocation.json); exit(0) }
// A copy that is still starting (two MCP calls at once) or briefly refusing connections must not be opened again:
// macOS would send it a reopen, which shows the window. Wait for its socket instead. The lock makes CLIs that find
// the app closed at the same moment decide one at a time; it is let go once the socket answers, before the request,
// so a long command never holds up others.
var launchLock: Int32 = -1
if fd == nil {
  // A first launch has no data folder yet; make it (as the app would) so the lock always exists.
  try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  launchLock = Darwin.open(root.appendingPathComponent("cli-launch.lock").path, O_CREAT | O_RDWR, 0o600)
  guard launchLock >= 0, flock(launchLock, LOCK_EX) == 0 else { failure("Could not take the launch lock in \(root.path).", json: invocation.json) }
  fd = connectSocket(path)
}
if fd == nil && !(invocation.dataDirectory == nil && appRunning(executable: "VideoPrompter", exact: ownApp.map { $0.appendingPathComponent("Contents/MacOS/VideoPrompter").resolvingSymlinksInPath().path })) {
  let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  var launch = ["-g"]
  if let custom = ProcessInfo.processInfo.environment["VIDEOPROMPTER_APP"] { launch += ["-a", custom] }
  else if let ownApp { launch += ["-a", ownApp.path] }
  else { launch += ["-b", bundleID] }
  // --headless: no library window, Dock tile or update prompt; `present` still shows the presenter.
  if invocation.dataDirectory != nil { launch += ["-n", "--args", "--headless", "--data-directory", root.path] } else { launch += ["--args", "--headless"] }
  process.arguments = launch
  process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
  do { try process.run(); process.waitUntilExit() } catch { failure("Could not launch Video Prompter in the background.", json: invocation.json) }
}
if fd == nil {
  let deadline = Date().addingTimeInterval(10)
  // The socket appears a few hundred milliseconds into the launch; checking often answers as soon as it does.
  while fd == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02); fd = connectSocket(path) }
}
if launchLock >= 0 { Darwin.close(launchLock) }
guard let fd else { failure("Video Prompter is running but does not answer on \(path); it may be older than 1.0.0. Quit it and try again.", json: invocation.json) }
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
  guard count > 0, response.count < 20 * 1024 * 1024 else { failure("Video Prompter closed the connection, timed out, or returned an oversized response.", json: invocation.json) }
  response.append(contentsOf: buffer.prefix(count))
}
guard let end = response.firstIndex(of: 10), var value = try? JSONSerialization.jsonObject(with: response.prefix(upTo: end)) as? [String: Any] else { failure("Invalid app response.", json: invocation.json) }
value.removeValue(forKey: "id"); emit(value, json: invocation.json)
exit(value["ok"] as? Bool == true ? 0 : 1)
