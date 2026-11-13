import Foundation

/// An install identity, independent of iPadOS's generic device name or a user's rename.
public struct PadIdentity: Equatable, Sendable {
  public let id: String
  public let name: String

  public init(defaults: UserDefaults, modelName: String = "iPad") {
    let id = defaults.string(forKey: "macLinkDeviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
    self.id = id.uuidString
    defaults.set(self.id, forKey: "macLinkDeviceID")
    name = defaults.string(forKey: "macLinkDeviceName") ?? Self.cleanName(modelName)
  }

  /// Model families from Xcode's device profiles. Unknown future models retain the generic name.
  public static func modelName(machine: String) -> String {
    let pro: [String: ClosedRange<Int>] = ["iPad6": 3...8, "iPad7": 1...4, "iPad8": 1...12,
      "iPad13": 4...11, "iPad14": 3...6, "iPad16": 3...6, "iPad17": 1...4]
    let parts = machine.split(separator: ",")
    guard parts.count == 2, let number = Int(parts[1]), let range = pro[String(parts[0])], range.contains(number),
      machine != "iPad6,5", machine != "iPad6,6" else { return "iPad" }
    return "iPad Pro"
  }

  public static func cleanName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // Bonjour names are at most 63 bytes; leave room for the identity suffix.
    var name = String(trimmed.prefix(24))
    while name.utf8.count > 24 { name.removeLast() }
    return name.isEmpty ? "iPad" : name
  }

  public var serviceName: String { "\(Self.cleanName(name)) [\(id)]" }

  public static func peer(serviceName: String) -> (id: String, name: String) {
    if serviceName.count >= 39, serviceName.hasSuffix("]") {
      let suffix = String(serviceName.suffix(38).dropFirst().dropLast())
      if let uuid = UUID(uuidString: suffix), serviceName.dropLast(38).hasSuffix(" ") {
        return (uuid.uuidString, String(serviceName.dropLast(39)))
      }
    }
    return (serviceName, serviceName)
  }
}
