import Foundation
import Security

/// Credentials leave preferences only after a successful Keychain write.
public final class PairingKeyStore {
  private let read: (String) -> Data?
  private let write: (String, Data) -> Bool
  public init(service: String) {
    // A Mac build signed without a team (the locally signed Alpha) is refused the data-protection
    // keychain (errSecMissingEntitlement), and the login keychain asks for the password after every
    // rebuild, freezing launch. Such builds keep keys in their own preferences instead.
    // shortcut: plain preferences for teamless test builds only; team-signed releases never get here.
    let fallbackKey = { (key: String) in "\(service).\(key)" }
    read = { key in
      var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: key,
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseDataProtectionKeychain as String: true]
      query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
      var value: CFTypeRef?
      if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data { return data }
      #if os(macOS)
      return UserDefaults.standard.data(forKey: fallbackKey(key))
      #else
      return nil
      #endif
    }
    write = { key, data in
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: key,
        kSecUseDataProtectionKeychain as String: true]
      let attributes: [String: Any] = [kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
      var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if result == errSecItemNotFound { result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
      #if os(macOS)
      if result == errSecMissingEntitlement { UserDefaults.standard.set(data, forKey: fallbackKey(key)); return true }
      #endif
      return result == errSecSuccess
    }
  }
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
