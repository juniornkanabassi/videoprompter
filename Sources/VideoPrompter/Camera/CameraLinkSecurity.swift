import CryptoKit
import Foundation
import Network

/// Pairing for the Wi-Fi camera link. The iPad shows a pairing key; the Mac asks for it once per
/// iPad, and both ends use it as a TLS pre-shared key. A Mac without the code cannot send
/// to the iPad, a device that only borrows the iPad's name cannot complete the handshake, so it
/// never receives a frame, and the picture is encrypted on the network. Shared by both apps, so
/// they derive the same key. USB-C needs none of this: usbmuxd only reaches a trusted iPad.
enum CameraLinkSecurity {
  /// Crockford's base 32: no I, L, O or U, so what is read off the iPad is typed without doubt.
  private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  /// A fresh key for the iPad to show: 80 random bits as 16 characters in groups of four, such
  /// as "K7QF-2MZX-P9RT-W3HD". A PSK handshake can be attacked offline by anyone who records
  /// it, so the key must be too large to guess (RFC 4279, section 7.2); a six-digit code would
  /// fall in seconds. It is typed once per Mac.
  static func newCode() -> String {
    var generator = SystemRandomNumberGenerator()
    let characters = (0..<16).map { _ in alphabet[Int.random(in: 0..<32, using: &generator)] }
    return stride(from: 0, to: 16, by: 4).map { String(characters[$0..<$0 + 4]) }.joined(separator: "-")
  }

  /// What was typed, in the form `newCode` writes: case, spaces and dashes do not matter, and
  /// the letters people confuse with digits are read as those digits. Nil unless 16 characters.
  static func normalised(_ typed: String) -> String? {
    let mapped = typed.uppercased().compactMap { character -> Character? in
      switch character {
      case "O": return "0"
      case "I", "L": return "1"
      default: return alphabet.contains(character) ? character : nil
      }
    }
    guard mapped.count == 16 else { return nil }
    return stride(from: 0, to: 16, by: 4).map { String(mapped[$0..<$0 + 4]) }.joined(separator: "-")
  }

  /// TCP with TLS 1.2 PSK keyed by the pairing key, stretched through HMAC to full length.
  static func parameters(code: String) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let tls = NWProtocolTLS.Options()
    let salt = SymmetricKey(data: Data("Video Prompter camera link".utf8))
    let key = HMAC<SHA256>.authenticationCode(for: Data(code.utf8), using: salt)
    let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data("VideoPrompter".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(
      tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
    sec_protocol_options_append_tls_ciphersuite(
      tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    return NWParameters(tls: tls, tcp: tcp)
  }
}
