import CryptoKit
import Foundation
import Network
import XCTest
@testable import PrompterCore
@testable import VideoPrompter

final class PairingTests: XCTestCase {
  func testOfferRoundTripExpiryForeignTamperAndReplay() throws {
    let now = Date()
    let id = UUID()
    let offer = PairingOffer(macID: id, name: "Studio Mac", service: id.uuidString, now: now)
    XCTAssertEqual(try PairingOffer.decode(offer.encoded(), now: now), offer)
    XCTAssertThrowsError(try PairingOffer.decode(offer.encoded(), now: now.addingTimeInterval(300)))
    XCTAssertEqual(try PairingOffer.decode(offer.encoded(), now: now.addingTimeInterval(359), clockSkew: 60), offer)
    XCTAssertThrowsError(try PairingOffer.decode(offer.encoded(), now: now.addingTimeInterval(360), clockSkew: 60))
    XCTAssertThrowsError(try PairingOffer.decode("https://example.com"))
    var foreign = offer; foreign.app = "OtherApp"
    XCTAssertThrowsError(try PairingOffer.decode(foreign.encoded(), now: now))
    var used = PairingRedemption()
    var tampered = offer; tampered.secret = String(repeating: "x", count: 72)
    XCTAssertThrowsError(try used.redeem(tampered, expected: offer, now: now))
    try used.redeem(offer, expected: offer, now: now)
    XCTAssertThrowsError(try used.redeem(offer, expected: offer, now: now))
  }
  func testAllowDeclineExpiryAndRepeatedDecisions() {
    let now = Date()
    var allow = PairingConsent(now: now)
    XCTAssertTrue(allow.consume(allow: true, now: now))
    XCTAssertFalse(allow.consume(allow: true, now: now))
    var denied = PairingConsent(now: now)
    XCTAssertFalse(denied.consume(allow: false, now: now))
    XCTAssertFalse(denied.consume(allow: true, now: now))
    var expired = PairingConsent(now: now)
    XCTAssertFalse(expired.consume(allow: true, now: now.addingTimeInterval(60)))
  }
  @MainActor func testApprovedHandshakeCredentialIsOnlyReadableByRequestingMac() throws {
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let pad = Curve25519.KeyAgreement.PrivateKey()
    let intruder = Curve25519.KeyAgreement.PrivateKey()
    XCTAssertEqual(try PairingExchange.confirmationCode(PairingExchange.key(mac, peer: pad.publicKey.rawRepresentation)),
      try PairingExchange.confirmationCode(PairingExchange.key(pad, peer: mac.publicKey.rawRepresentation)))
    let sealed = try PairingExchange.seal(.init(id: "pad", name: "Studio iPad", code: "QR:secret"),
      key: PairingExchange.key(pad, peer: mac.publicKey.rawRepresentation))
    let reply = try PairingExchange.open(sealed, key: PairingExchange.key(mac, peer: pad.publicKey.rawRepresentation))
    XCTAssertEqual(reply.code, "QR:secret")
    XCTAssertThrowsError(try PairingExchange.open(sealed, key: PairingExchange.key(intruder, peer: pad.publicKey.rawRepresentation)))
    var tampered = sealed; tampered[0] ^= 1
    XCTAssertThrowsError(try PairingExchange.open(tampered, key: PairingExchange.key(mac, peer: pad.publicKey.rawRepresentation)))
  }
  func testListenerIsLimitedToConnectionScreenAndDeclineCooldown() {
    var availability = PairingAvailability()
    let now = Date()
    XCTAssertFalse(availability.allowsRequest(now: now))
    availability.screenOpen = true
    XCTAssertTrue(availability.allowsRequest(now: now))
    availability.presenting = true
    XCTAssertFalse(availability.allowsRequest(now: now))
    availability.presenting = false
    availability.decline(now: now)
    XCTAssertFalse(availability.allowsRequest(now: now.addingTimeInterval(179)))
    XCTAssertTrue(availability.allowsRequest(now: now.addingTimeInterval(180)))
  }
  @MainActor func testFailedHandshakeRetainsStoredCredential() {
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.acceptedPairing(id: "pad", code: "QR:secret")
    sender.refusedPairing(id: "pad", name: "Impersonator")
    XCTAssertEqual(sender.pairingCode(id: "pad", name: "Impersonator"), "QR:secret")
  }
  @MainActor func testQRCredentialRequiresPrivateKeyAndSecret() throws {
    let mac = Curve25519.KeyAgreement.PrivateKey(), pad = Curve25519.KeyAgreement.PrivateKey()
    let shared = try PairingExchange.key(mac, peer: pad.publicKey.rawRepresentation, salt: "qr-secret")
    XCTAssertEqual(PairingExchange.credential(shared), try PairingExchange.credential(PairingExchange.key(pad, peer: mac.publicKey.rawRepresentation, salt: "qr-secret")))
    XCTAssertNotEqual(PairingExchange.credential(shared), try PairingExchange.credential(PairingExchange.key(pad, peer: mac.publicKey.rawRepresentation, salt: "other")))
    let intruder = Curve25519.KeyAgreement.PrivateKey()
    XCTAssertNotEqual(PairingExchange.credential(shared), try PairingExchange.credential(PairingExchange.key(intruder, peer: mac.publicKey.rawRepresentation, salt: "qr-secret")))
  }
  @MainActor func testForgetAndSelectionPersistence() {
    let defaults = freshDefaults(), store = PairingKeyStore.ephemeral()
    let sender = IPadCameraSender(defaults: defaults, credentialStore: store)
    sender.acceptedPairing(id: "one", code: "QR:one")
    sender.acceptedPairing(id: "two", code: "QR:two")
    sender.selectedWiFiID = "one"
    sender.wifiChanged([])
    XCTAssertEqual(sender.selectedWiFiID, "one")
    XCTAssertEqual(IPadCameraSender(defaults: defaults, credentialStore: store).selectedWiFiID, "one")
    sender.forgetIPad(id: "one")
    XCTAssertNil(sender.pairingCode(id: "one", name: "one"))
    XCTAssertEqual(sender.pairingCode(id: "two", name: "two"), "QR:two")
  }
  func testKeychainMigrationOnlyRemovesPreferencesAfterSuccessfulWrite() {
    let defaults = freshDefaults()
    defaults.set(["one": "secret"], forKey: "keys")
    let failed = PairingKeyStore(read: { _ in nil }, write: { _, _ in false })
    XCTAssertEqual(failed.load([String: String].self, key: "keys", defaults: defaults), ["one": "secret"])
    XCTAssertNotNil(defaults.object(forKey: "keys"))
    let store = PairingKeyStore.ephemeral()
    XCTAssertEqual(store.load([String: String].self, key: "keys", defaults: defaults), ["one": "secret"])
    XCTAssertNil(defaults.object(forKey: "keys"))
    defaults.set("typed-secret", forKey: "macLinkKey")
    XCTAssertEqual(store.load(String.self, key: "macLinkKey", defaults: defaults), "typed-secret")
    defaults.set(try! JSONEncoder().encode(["mac-id": ["name": "Mac", "code": "QR:secret"]]), forKey: "pairedMacCredentials")
    XCTAssertEqual(store.load([String: [String: String]].self, key: "pairedMacCredentials", defaults: defaults)?["mac-id"]?["code"], "QR:secret")
    XCTAssertNil(defaults.object(forKey: "pairedMacCredentials"))
    XCTAssertEqual(store.load([String: String].self, key: "keys", defaults: defaults), ["one": "secret"])
  }
  @MainActor func testFakeNearbyIPadCannotPairWithoutNumbersMatch() async throws {
    let id = UUID().uuidString
    let listener = try NWListener(using: .tcp)
    listener.service = .init(name: id, type: PairingExchange.padService)
    listener.newConnectionHandler = { connection in
      Task { @MainActor in
        connection.start(queue: .main)
        do {
          let request = try JSONDecoder().decode(PairingExchange.Request.self, from: await PairingExchange.receive(on: connection))
          let key = Curve25519.KeyAgreement.PrivateKey()
          try await PairingExchange.send(PairingExchange.commitment(key.publicKey.rawRepresentation), on: connection)
          let peer = try await PairingExchange.receive(on: connection)
          guard PairingExchange.commitment(peer) == request.publicKeyCommitment else { return }
          try await PairingExchange.send(key.publicKey.rawRepresentation, on: connection)
          let shared = try PairingExchange.key(key, peer: peer)
          try await PairingExchange.send(PairingExchange.seal(.init(id: id, name: "Fake iPad", code: "QR:fake"), key: shared), on: connection)
        } catch {}
        connection.cancel()
      }
    }
    listener.start(queue: .main)
    defer { listener.cancel() }
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    defer { sender.cancelPairingRequest(); sender.disconnect() }
    sender.requestPairing(.init(id: id, name: "Fake iPad"))
    for _ in 0..<100 where sender.pairingRequestCode == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(sender.pairingRequestCode)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertNil(sender.pairingCode(id: id, name: "Fake iPad"))
    sender.cancelPairingRequest()
    XCTAssertNil(sender.pairingCode(id: id, name: "Fake iPad"))
  }
  @MainActor func testKnownMacCredentialSurvivesRestart() {
    let defaults = freshDefaults()
    let padID = UUID().uuidString
    let store = PairingKeyStore.ephemeral()
    let first = IPadCameraSender(defaults: defaults, credentialStore: store)
    first.acceptedPairing(id: padID, code: "QR:known-secret")
    let restarted = IPadCameraSender(defaults: defaults, credentialStore: store)
    XCTAssertEqual(restarted.pairingCode(id: padID, name: "renamed iPad"), "QR:known-secret")
    XCTAssertNil(restarted.pairingCode(id: UUID().uuidString, name: "renamed iPad"))
  }
}

extension AppearanceSnapshotTests {
  func testPairingPanelShots() async throws {
    guard let path = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let link = IPadCameraSender(defaults: freshDefaults())
    link.refreshPairingOffer()
    for state in ["waiting", "nearby"] {
      if state == "nearby" {
        link.wifiChanged([.service(name: "Studio iPad [00000000-0000-0000-0000-000000000001]", type: "_vpcamera._tcp", domain: "local.", interface: nil)])
      }
      try await snapshot(IPadConnectPanel(link: link), name: "qr-mac-\(state)", size: .init(width: 960, height: 640), scheme: .dark, destination: URL(fileURLWithPath: path))
    }
  }
}
