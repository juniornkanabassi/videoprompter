import Foundation
import Network
import CryptoKit
import PrompterCore

/// Pairing messages never enter the camera/remote-command decoder.
@MainActor enum PairingExchange {
  static let macService = "_vppairmac._tcp"
  static let padService = "_vppairpad._tcp"
  struct Request: Codable {
    var id: String
    var name: String
    var publicKeyCommitment: Data
    var offer: PairingOffer?
    var code: String?
  }
  struct Reply: Codable {
    var id: String
    var name: String
    var code: String
  }
  static func key(_ privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data) throws -> SymmetricKey {
    try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peer))
      .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("VP pairing v1".utf8), sharedInfo: Data(), outputByteCount: 32)
  }
  static func commitment(_ publicKey: Data) -> Data { Data(SHA256.hash(data: publicKey)) }
  static func confirmationCode(_ key: SymmetricKey) -> String {
    let digest = key.withUnsafeBytes { SHA256.hash(data: Data($0)) }
    let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
    return String(format: "%06d", number)
  }
  static func seal(_ reply: Reply, key: SymmetricKey) throws -> Data {
    try AES.GCM.seal(JSONEncoder().encode(reply), using: key).combined!
  }
  static func open(_ data: Data, key: SymmetricKey) throws -> Reply {
    try JSONDecoder().decode(Reply.self, from: AES.GCM.open(.init(combined: data), using: key))
  }
  static func connect(_ endpoint: NWEndpoint, code: String? = nil) -> NWConnection {
    let connection = NWConnection(to: endpoint, using: code.map { CameraLinkSecurity.parameters(code: $0) } ?? .tcp)
    connection.start(queue: .main)
    expire(connection)
    return connection
  }
  static func expire(_ connection: NWConnection) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { connection.cancel() }
  }
  static func send(_ data: Data, on connection: NWConnection) async throws {
    var size = UInt32(data.count).bigEndian
    var packet = withUnsafeBytes(of: &size) { Data($0) }
    packet.append(data)
    try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
      connection.send(content: packet, completion: .contentProcessed { error in
        if let error { result.resume(throwing: error) } else { result.resume() }
      })
    }
  }
  private static func read(_ count: Int, on connection: NWConnection) async throws -> Data {
    var buffer = Data()
    while buffer.count < count {
      let needed = count - buffer.count
      let part: Data = try await withCheckedThrowingContinuation { result in
        connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { data, _, _, error in
          if let data, !data.isEmpty { result.resume(returning: data) }
          else { result.resume(throwing: error ?? NWError.posix(.ECONNRESET)) }
        }
      }
      buffer.append(part)
    }
    return buffer
  }
  static func receive(on connection: NWConnection) async throws -> Data {
    let header = try await read(4, on: connection)
    let count = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
    guard count > 0, count <= 8192 else { throw PairingOffer.Failure.foreign }
    return try await read(count, on: connection)
  }
}
