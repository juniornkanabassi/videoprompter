import Foundation
import Security

/// Credentials leave preferences only after a successful Keychain write.
public final class PairingKeyStore {
  private let read: (String) -> Data?
  private let write: (String, Data) -> Bool
  public init(service: String) {
    // A notarised Developer ID release has no provisioning profile, so the data-protection keychain refuses
    // it (errSecMissingEntitlement); it then uses the login keychain, which trusts the same team-signed app
    // across updates. A build signed without a team (the locally signed Alpha) would be asked for the login
    // password after every rebuild, freezing launch, so only such builds keep keys in their own preferences.
    // shortcut: plain preferences for teamless test builds only; never for a team-signed release.
    let fallbackKey = { (key: String) in "\(service).\(key)" }
    func query(_ key: String, dataProtection: Bool) -> [String: Any] {
      var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: key]
      if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
      return query
    }
    func copy(_ key: String, dataProtection: Bool) -> Data? {
      var request = query(key, dataProtection: dataProtection)
      request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
      request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
      var value: CFTypeRef?
      return SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess ? value as? Data : nil
    }
    func store(_ key: String, _ data: Data, dataProtection: Bool) -> OSStatus {
      let request = query(key, dataProtection: dataProtection)
      var attributes: [String: Any] = [kSecValueData as String: data]
      if dataProtection { attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
      var result = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
      if result == errSecItemNotFound { result = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil) }
      return result
    }
    read = { key in
      if let data = copy(key, dataProtection: true) { return data }
      #if os(macOS)
      switch Self.macFallback {
      case .loginKeychain: return copy(key, dataProtection: false)
      case .preferences: return UserDefaults.standard.data(forKey: fallbackKey(key))
      }
      #else
      return nil
      #endif
    }
    write = { key, data in
      var result = store(key, data, dataProtection: true)
      #if os(macOS)
      if result == errSecMissingEntitlement {
        switch Self.macFallback {
        case .loginKeychain: result = store(key, data, dataProtection: false)
        case .preferences: UserDefaults.standard.set(data, forKey: fallbackKey(key)); return true
        }
      }
      #endif
      return result == errSecSuccess
    }
  }
  #if os(macOS)
  public enum MacFallback: Equatable, Sendable { case loginKeychain, preferences }
  /// Where keys go when the data-protection keychain is refused: only a build signed without a team uses preferences.
  public static func fallback(teamIdentifier: String?) -> MacFallback {
    (teamIdentifier?.isEmpty == false) ? .loginKeychain : .preferences
  }
  static let macFallback = fallback(teamIdentifier: ownTeamIdentifier())
  static func ownTeamIdentifier() -> String? {
    var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
    else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
  }
  #endif
  public init(read: @escaping (String) -> Data?, write: @escaping (String, Data) -> Bool) {
    self.read = read; self.write = write
  }
  public static func ephemeral() -> PairingKeyStore {
    var values: [String: Data] = [:]
    return PairingKeyStore(read: { values[$0] }, write: { values[$0] = $1; return true })
  }
  public func load<T: Codable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
    if let data = read(key), let value = try? JSONDecoder().decode(type, from: data) { return value }
    guard let old = defaults.object(forKey: key),
      let data = (old as? Data) ?? (try? JSONSerialization.data(withJSONObject: old, options: [.fragmentsAllowed])),
      let value = try? JSONDecoder().decode(type, from: data) else { return nil }
    if save(value, key: key) { defaults.removeObject(forKey: key) }
    return value
  }
  @discardableResult public func save<T: Codable>(_ value: T, key: String) -> Bool {
    guard let data = try? JSONEncoder().encode(value) else { return false }
    return write(key, data)
  }
}
