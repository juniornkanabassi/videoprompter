// Watches every copy of one executable for anything a person would see: a window on screen (any layer, not fully
// transparent) or a Dock tile. Samples every 5 ms, so a window that flashes up for a single frame is still caught.
// Usage: swift checks/watch-headless.swift <executable path> <seconds>; prints READY, then the worst it saw:
// WINDOWS <largest number on screen at once> DOCK <yes|no>
import AppKit
import CoreGraphics
import Darwin

let executable = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
let deadline = Date().addingTimeInterval(Double(CommandLine.arguments[2])!)
var paths: [pid_t: String] = [:]
func path(_ pid: pid_t) -> String {
  if let known = paths[pid] { return known }
  var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  let found = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
  paths[pid] = found
  return found
}
func ours(_ pid: pid_t) -> Bool {
  let found = path(pid)
  return found == executable || "/private" + found == executable || found == "/private" + executable
}
var mostWindows = 0
var dock = false
print("READY")
fflush(stdout)
while Date() < deadline {
  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  let shown = windows.filter { window in
    guard let pid = window[kCGWindowOwnerPID as String] as? Int, ours(pid_t(pid)) else { return false }
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 && (bounds["Width"] ?? 0) > 1 && (bounds["Height"] ?? 0) > 1
  }
  mostWindows = max(mostWindows, shown.count)
  for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    if ours(app.processIdentifier) { dock = true }
  }
  RunLoop.current.run(until: Date().addingTimeInterval(0.005))
}
print("WINDOWS \(mostWindows) DOCK \(dock ? "yes" : "no")")
