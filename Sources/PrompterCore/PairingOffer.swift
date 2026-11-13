import Foundation

/// A short-lived capability, never a stored camera-link credential.
public struct PairingOffer: Codable, Equatable, Sendable {
  public var app = "VideoPrompter.pair.v1"
  public var id: UUID
  public var macID: UUID
  public var name: String
  public var secret: String
  public var expires: Date
  public var service: String

  public init(macID: UUID, name: String, service: String, now: Date = Date()) {
    id = UUID(); self.macID = macID; self.name = name; self.service = service
    secret = UUID().uuidString + UUID().uuidString
    expires = now.addingTimeInterval(300)
  }
  public func encoded() throws -> String { "videoprompter://pair/" + (try JSONEncoder().encode(self)).base64EncodedString() }
  public static func decode(_ value: String, now: Date = Date(), clockSkew: TimeInterval = 0) throws -> Self {
    guard value.hasPrefix("videoprompter://pair/"), value.count < 4096,
      let data = Data(base64Encoded: String(value.dropFirst(21))) else { throw Failure.foreign }
    let offer: Self
    do { offer = try JSONDecoder().decode(Self.self, from: data) } catch { throw Failure.foreign }
    guard offer.app == "VideoPrompter.pair.v1", offer.secret.count == 72,
      offer.service == offer.macID.uuidString, !offer.name.isEmpty else { throw Failure.foreign }
    guard offer.expires > now.addingTimeInterval(-clockSkew), offer.expires <= now.addingTimeInterval(300 + clockSkew) else { throw Failure.expired }
    return offer
  }
  public enum Failure: Error { case foreign, expired, replay }
}

public struct PairingRedemption: Sendable {
  private var used: Set<UUID> = []
  public init() {}
  public mutating func redeem(_ received: PairingOffer, expected: PairingOffer, now: Date = Date()) throws {
    guard received == expected else { throw PairingOffer.Failure.foreign }
    guard received.expires > now else { throw PairingOffer.Failure.expired }
    guard used.insert(received.id).inserted else { throw PairingOffer.Failure.replay }
  }
}

/// One local decision per request; a delayed tap cannot authorise an expired request.
public struct PairingConsent: Sendable {
  private let expires: Date
  private var decided = false
  public init(now: Date = Date()) { expires = now.addingTimeInterval(60) }
  public mutating func consume(allow: Bool, now: Date = Date()) -> Bool {
    guard !decided else { return false }
    decided = true
    return allow && now < expires
  }
}

/// Pairing is available only in the connection screen; declining silences repeat requests.
public struct PairingAvailability: Sendable {
  public var screenOpen = false
  public var presenting = false
  private var blockedUntil = Date.distantPast
  public init() {}
  public func allowsRequest(now: Date = Date()) -> Bool {
    screenOpen && !presenting && now >= blockedUntil
  }
  public mutating func decline(now: Date = Date()) { blockedUntil = now.addingTimeInterval(180) }
}
