import Foundation

/// The Mac sends its camera to the iPad over this, H.264 from VideoToolbox, and drives the iPad's
/// presenter; the iPad answers with what it shows. Framed so either end can read it off a byte
/// stream. Over USB-C the stream is a usbmuxd tunnel to `usbPort` on the iPad; on Wi-Fi it is a
/// Bonjour TCP connection. Both carry the same messages.
///
/// Each message is a four-byte big-endian length, then a one-byte kind, then the payload. The
/// length counts the kind and the payload.
public enum CameraLink {
  /// The iPad listens here on its loopback interface; usbmuxd forwards the Mac's connection to it.
  public static let usbPort: UInt16 = 47_417
  /// The Bonjour service type the iPad advertises for the Wi-Fi link.
  public static let bonjourType = "_vpcamera._tcp"
  /// 2 added `command` and `state`. An iPad sends `state` only to a Mac that said 2 or more.
  public static let protocolVersion = 2
  /// Nothing legitimate comes close: a 1080p key frame is well under 2 MB.
  public static let maximumMessage = 16 * 1024 * 1024

  public enum Message: Equatable, Sendable {
    /// First on every connection: the Mac's name, shown on the iPad, and the protocol version.
    case hello(name: String, version: Int)
    /// The picture's size and the H.264 parameter sets (SPS then PPS), before the first frame
    /// and again whenever they change. None means the Mac stopped sending its camera but stays
    /// connected to control the iPad.
    case format(width: Int, height: Int, parameterSets: [Data])
    /// One encoded frame: NAL units each with a four-byte length (AVCC), as VideoToolbox writes
    /// them. `time` is the capture time in microseconds.
    case frame(time: UInt64, keyFrame: Bool, data: Data)
    /// The Mac has stopped sending; the iPad goes back to its own source.
    case goodbye
    /// Mac to iPad: do this in the presenter.
    case command(PadRemote.Command)
    /// iPad to Mac: what the iPad shows, after each change.
    case state(PadRemote.State)

    var kind: UInt8 {
      switch self {
      case .hello: 1
      case .format: 2
      case .frame: 3
      case .goodbye: 4
      case .command: 5
      case .state: 6
      }
    }

    public func encoded() -> Data {
      var payload = Data()
      switch self {
      case .hello(let name, let version):
        payload.append(UInt32(version))
        payload.append(Data(name.utf8))
      case .format(let width, let height, let sets):
        payload.append(UInt32(width))
        payload.append(UInt32(height))
        payload.append(UInt8(sets.count))
        for set in sets {
          payload.append(UInt16(set.count))
          payload.append(set)
        }
      case .frame(let time, let keyFrame, let data):
        payload.append(time)
        payload.append(UInt8(keyFrame ? 1 : 0))
        payload.append(data)
      case .goodbye:
        break
      case .command(let command):
        payload = (try? JSONEncoder().encode(command)) ?? Data()
      case .state(let state):
        payload = (try? JSONEncoder().encode(state)) ?? Data()
      }
      var message = Data()
      message.append(UInt32(payload.count + 1))
      message.append(kind)
      message.append(payload)
      return message
    }
  }

  public enum ReadError: Error, Equatable {
    case tooLong(Int)
    case malformed(kind: UInt8)
  }

  /// Collects bytes as they arrive and hands back whole messages. Unknown kinds are skipped, so a
  /// newer Mac can add messages without breaking an older iPad.
  public struct Reader: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Message] {
      buffer.append(bytes)
      var messages: [Message] = []
      while buffer.count >= 4 {
        let start = buffer.startIndex
        let length = Int(buffer.readUInt32(at: start))
        guard length >= 1, length <= CameraLink.maximumMessage else { throw ReadError.tooLong(length) }
        guard buffer.count >= 4 + length else { break }
        let kind = buffer[start + 4]
        let payload = buffer.subdata(in: (start + 5)..<(start + 4 + length))
        buffer.removeSubrange(start..<(start + 4 + length))
        if let message = try Self.decode(kind: kind, payload: payload) { messages.append(message) }
      }
      return messages
    }

    static func decode(kind: UInt8, payload p: Data) throws -> Message? {
      let s = p.startIndex
      switch kind {
      case 1:
        guard p.count >= 4 else { throw ReadError.malformed(kind: kind) }
        let name = String(decoding: p[(s + 4)...], as: UTF8.self)
        return .hello(name: name, version: Int(p.readUInt32(at: s)))
      case 2:
        guard p.count >= 9 else { throw ReadError.malformed(kind: kind) }
        var at = s + 9
        var sets: [Data] = []
        for _ in 0..<Int(p[s + 8]) {
          guard at + 2 <= p.endIndex else { throw ReadError.malformed(kind: kind) }
          let count = Int(p.readUInt16(at: at))
          at += 2
          guard at + count <= p.endIndex else { throw ReadError.malformed(kind: kind) }
          sets.append(p.subdata(in: at..<(at + count)))
          at += count
        }
        return .format(width: Int(p.readUInt32(at: s)), height: Int(p.readUInt32(at: s + 4)), parameterSets: sets)
      case 3:
        guard p.count >= 9 else { throw ReadError.malformed(kind: kind) }
        return .frame(time: p.readUInt64(at: s), keyFrame: p[s + 8] != 0, data: p.subdata(in: (s + 9)..<p.endIndex))
      case 4:
        return .goodbye
      // JSON, so a newer Mac's command an older iPad cannot read is skipped, not fatal.
      case 5:
        return (try? JSONDecoder().decode(PadRemote.Command.self, from: p)).map(Message.command)
      case 6:
        return (try? JSONDecoder().decode(PadRemote.State.self, from: p)).map(Message.state)
      default:
        return nil
      }
    }
  }
}

/// The Mac's remote for the iPad's presenter, carried by `CameraLink`.
public enum PadRemote {
  public enum Command: Codable, Equatable, Sendable {
    /// Opens a script from `State.scripts` in the presenter.
    case present(UUID)
    case close
    case play
    case pause
    case backToStart
    case nextPassage
    case previousPassage
    /// A word number from 1, as `State.word` counts them.
    case seek(word: Int)
    /// "Voice" or "Manual".
    case mode(String)
    /// Manual speed in words per minute, 20 to 300.
    case speed(Int)
  }

  public struct Script: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public init(id: UUID, title: String) { self.id = id; self.title = title }
  }

  public struct State: Codable, Equatable, Sendable {
    public var scripts: [Script]
    /// The script in the presenter, if it is open.
    public var presenting: UUID?
    public var running: Bool
    public var mode: String
    public var speed: Int
    /// The reading position from 1, and the script's length in words; 0 when nothing is open.
    public var word: Int
    public var words: Int
    public init(scripts: [Script], presenting: UUID?, running: Bool, mode: String, speed: Int, word: Int, words: Int) {
      self.scripts = scripts; self.presenting = presenting; self.running = running
      self.mode = mode; self.speed = speed; self.word = word; self.words = words
    }
  }
}

extension Data {
  fileprivate mutating func append<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
  fileprivate func readUInt16(at index: Index) -> UInt16 {
    self[index..<(index + 2)].reduce(0) { $0 << 8 | UInt16($1) }
  }
  fileprivate func readUInt32(at index: Index) -> UInt32 {
    self[index..<(index + 4)].reduce(0) { $0 << 8 | UInt32($1) }
  }
  fileprivate func readUInt64(at index: Index) -> UInt64 {
    self[index..<(index + 8)].reduce(0) { $0 << 8 | UInt64($1) }
  }
}
