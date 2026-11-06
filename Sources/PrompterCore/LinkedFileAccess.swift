import Foundation
import Synchronization

/// Wait for file presenters off the library actor. A late grant after timeout never accesses the file.
final class LinkedFileAccess: @unchecked Sendable {
  struct Waiting: Error, LocalizedError {
    let url: URL
    var errorDescription: String? { "Waiting for \(url.lastPathComponent). Save or close it in the other editor to finish syncing." }
  }
  let url: URL
  private let coordinator = NSFileCoordinator()
  private let release = DispatchSemaphore(value: 0)
  private let pending = Mutex<CheckedContinuation<LinkedFileAccess, Error>?>(nil)
  private init(url: URL) { self.url = url }

  static func acquire(_ url: URL, writing: Bool) async throws -> LinkedFileAccess {
    let access = LinkedFileAccess(url: url)
    return try await withCheckedThrowingContinuation { continuation in
      access.pending.withLock { $0 = continuation }
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        let pending = access.pending.withLock { value in defer { value = nil }; return value }
        if let pending {
          access.coordinator.cancel()
          pending.resume(throwing: Waiting(url: url))
        }
      }
      DispatchQueue.global().async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        let granted: (URL) -> Void = { target in
          let pending = access.pending.withLock { value in defer { value = nil }; return value }
          guard let pending else { return }
          // The actor owns all reads, writes and index changes while this reservation is held.
          access.target = target
          pending.resume(returning: access)
          access.release.wait()
        }
        if writing {
          access.coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &error, byAccessor: granted)
        } else {
          access.coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error, byAccessor: granted)
        }
        let pending = access.pending.withLock { value in defer { value = nil }; return value }
        pending?.resume(throwing: error ?? Waiting(url: url) as NSError)
      }
    }
  }
  // Published before the continuation resumes; thereafter only read by its owning actor.
  private(set) var target: URL!
  func finish() { release.signal() }
}

/// The importer and linked-file reader must agree; writes retain the original UTF-16 encoding.
public enum MarkdownText {
  public static func decode(_ data: Data) -> String? {
    if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
      return String(data: data, encoding: .utf16)
    }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
      ?? String(data: data, encoding: .utf16LittleEndian) ?? String(data: data, encoding: .utf16BigEndian)
  }
  static func encode(_ text: String, like original: Data) -> Data {
    if original.starts(with: [0xff, 0xfe]) { return Data([0xff, 0xfe]) + text.data(using: .utf16LittleEndian)! }
    if original.starts(with: [0xfe, 0xff]) { return Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)! }
    return Data(text.utf8)
  }
  static func read(_ url: URL) throws -> String {
    guard let text = decode(try Data(contentsOf: url)) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
    return text
  }
}
