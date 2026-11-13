import Foundation

/// An install identity, independent of iPadOS's generic device name or a user's rename.
public struct PadIdentity: Equatable, Sendable {
  public let id: String
  public let name: String

  public init(defaults: UserDefaults) {
    let id = defaults.string(forKey: "macLinkDeviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
    self.id = id.uuidString
    defaults.set(self.id, forKey: "macLinkDeviceID")
    name = defaults.string(forKey: "macLinkDeviceName") ?? "iPad \(self.id.prefix(4))"
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
