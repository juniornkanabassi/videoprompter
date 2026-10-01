// Read-only, PID-targeted accessibility evidence; never performs an action or activates a window.
import AppKit
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)
_ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
var seen = Set<AXUIElement>()
func attribute(_ element: AXUIElement, _ name: String) -> Any? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func walk(_ element: AXUIElement, depth: Int = 0) -> [[String: String]] {
  guard depth < 30, seen.count < 5000, seen.insert(element).inserted else { return [] }
  var row: [String: String] = [:]
  for name in ["AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue", "AXSelected", "AXPlaceholderValue", "AXHelp"] {
    if let value = attribute(element, name) { row[name] = String(describing: value) }
  }
  // SwiftUI Forms often name controls through a separate native title element.
  if let raw = attribute(element, "AXTitleUIElement"), CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() {
    let title = raw as! AXUIElement
    row["labelledBy"] = ["AXTitle", "AXDescription", "AXValue"].compactMap {
      attribute(title, $0) as? String
    }.first { !$0.isEmpty }
  }
  if let raw = attribute(element, "AXSize"), CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() {
    let value = raw as! AXValue
    var size = CGSize.zero
    if AXValueGetValue(value, .cgSize, &size) { row["width"] = String(Double(size.width)); row["height"] = String(Double(size.height)) }
  }
  let children = attribute(element, "AXChildren") as? [AXUIElement] ?? []
  return [row] + children.flatMap { walk($0, depth: depth + 1) }
}
let windows = attribute(app, "AXWindows") as? [AXUIElement] ?? []
let result: [String: Any] = ["pid": pid, "trusted": AXIsProcessTrusted(), "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, "windows": windows.flatMap { walk($0) }]
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
