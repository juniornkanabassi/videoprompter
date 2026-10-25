import CryptoKit
import Foundation
import Network

/// Pairing for the Wi-Fi camera link. The iPad shows a six-digit code; the Mac asks for it once
/// per iPad, and both ends use it as a TLS pre-shared key. A Mac without the code cannot send
/// to the iPad, a device that only borrows the iPad's name cannot complete the handshake, so it
/// never receives a frame, and the picture is encrypted on the network. Shared by both apps, so
/// they derive the same key. USB-C needs none of this: usbmuxd only reaches a trusted iPad.
enum CameraLinkSecurity {
  /// A fresh code for the iPad to show.
  static func newCode() -> String {
    String(format: "%06d", Int.random(in: 0...999_999))
  }

  /// TCP with TLS 1.2 PSK keyed by the code. The code is stretched through HMAC so the key is
  /// full length; its strength is still the code's, which is enough to keep a studio network
  /// honest but is not a password.
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
