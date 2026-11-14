import Foundation
import Security

/// Credentials leave preferences only after a successful Keychain write.
public final class PairingKeyStore {
  private let read: (String) -> Data?
  private let write: (String, Data) -> Bool
  public init(service: String) {
    // A Mac build signed without a team (the locally signed Alpha) is refused the data-protection
    // keychain with errSecMissingEntitlement, so it falls back to the login keychain.
    #if os(macOS)
    let keychains = [true, false]
    #else
    let keychains = [true]
    #endif
    read = { key in
      for dataProtection in keychains {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service, kSecAttrAccount as String: key,
          kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
          kSecUseDataProtectionKeychain as String: dataProtection]
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var value: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data { return data }
      }
      return nil
    }
    write = { key, data in
      for dataProtection in keychains {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service, kSecAttrAccount as String: key,
          kSecUseDataProtectionKeychain as String: dataProtection]
        let attributes: [String: Any] = [kSecValueData as String: data,
          kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound { result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        if result == errSecSuccess { return true }
        guard result == errSecMissingEntitlement else { return false }
      }
      return false
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
