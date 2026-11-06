import Darwin
import Foundation
import PrompterCore

/// All descriptors and connection state belong to queue; only the handler runs on the main actor.
final class ControlServer: @unchecked Sendable {
  typealias Handler = @MainActor @Sendable (String, [String: String]) async -> ControlResult
  private let socketURL: URL
  private let handler: Handler
  /// Connections that make no read progress for this long are dropped, so idle peers cannot hold all eight slots.
  private let idleTimeout: DispatchTimeInterval
  private let queue = DispatchQueue(label: "VideoPrompter.control")
  private var listener: DispatchSourceRead?
  private var inode: ino_t?
  // Mutable state is accessed exclusively on the server queue.
  private final class Connection: @unchecked Sendable {
    let fd: Int32
    var source: DispatchSourceRead?
    var timer: DispatchSourceTimer?
    var buffer = Data()
    var lines: [Data] = []
    var busy = false
    var writer: DispatchSourceWrite?
    var reply: Data?
    var reservedBytes = 0
    var sent = 0
    init(_ fd: Int32) { self.fd = fd }
  }
  private var clients: [Int32: Connection] = [:]
  private var reservedReplyBytes = 0
  init(socketURL: URL, idleTimeout: DispatchTimeInterval = .seconds(30), handler: @escaping Handler) {
    self.socketURL = socketURL; self.idleTimeout = idleTimeout; self.handler = handler
  }
  private func failure(_ message: String) -> NSError { NSError(domain: "ControlServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message]) }
  func start() throws {
    try queue.sync {
      guard listener == nil else { return }
      let path = socketURL.path
      guard path.utf8.count <= 103 else { throw failure("Control socket path exceeds 103 bytes") }
      let parent = socketURL.deletingLastPathComponent().path
      var info = stat()
      if lstat(parent, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw failure("Unsafe control directory") }
      }
      try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard chmod(parent, 0o700) == 0 else { throw failure("Cannot protect control directory") }
      let lockPath = socketURL.deletingLastPathComponent().appendingPathComponent("control.lock").path
      let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
      guard lockFD >= 0 else { throw failure("Cannot open control socket lock") }
      guard flock(lockFD, LOCK_EX) == 0 else { Darwin.close(lockFD); throw failure("Cannot lock control socket") }
      defer { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
      var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: Array(path.utf8) + [0]) }
      func connectTo(_ fd: Int32) -> Int32 {
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      }
      if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw failure("Existing control path is not our socket") }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw failure("Cannot probe control socket") }
        let answer = connectTo(probe); let reason = errno; Darwin.close(probe)
        guard answer != 0, reason == ECONNREFUSED else { throw failure("Control socket belongs to a live instance") }
        guard unlink(path) == 0 else { throw failure("Cannot remove stale socket") }
      }
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw failure("Cannot create control socket") }
      var bound = false
      do {
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw failure("Cannot protect socket") }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw failure("Cannot bind control socket") }; bound = true
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw failure("Cannot listen on private socket") }
        guard lstat(path, &info) == 0 else { throw failure("Cannot identify socket") }; inode = info.st_ino
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source; source.resume()
      } catch { Darwin.close(fd); if bound { unlink(path) }; throw error }
    }
  }
  func stop() {
    queue.sync {
      for client in Array(clients.values) { close(client) }
      listener?.cancel(); listener = nil
      var info = stat()
      if let inode, lstat(socketURL.path, &info) == 0, info.st_ino == inode, info.st_mode & S_IFMT == S_IFSOCK { unlink(socketURL.path) }
      inode = nil
    }
  }
  private func acceptClients(_ fd: Int32) {
    while true {
      let peer = accept(fd, nil, nil)
      guard peer >= 0 else { return }
      var uid: uid_t = 0; var gid: gid_t = 0; var yes: Int32 = 1
      guard clients.count < 8, getpeereid(peer, &uid, &gid) == 0, uid == getuid(),
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0
      else { Darwin.close(peer); continue }
      guard fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) | O_NONBLOCK) == 0 else { Darwin.close(peer); continue }
      let client = Connection(peer)
      let source = DispatchSource.makeReadSource(fileDescriptor: peer, queue: queue)
      let timer = DispatchSource.makeTimerSource(queue: queue)
      client.source = source; client.timer = timer; clients[peer] = client
      source.setEventHandler { [weak self] in self?.read(client) }
      source.setCancelHandler { Darwin.close(peer) }
      // An in-flight handler is not idleness; its reply re-arms the deadline.
      timer.setEventHandler { [weak self, weak client] in
        guard let self, let client, self.clients[client.fd] === client, (!client.busy || client.reply != nil) else { return }
        self.close(client)
      }
      arm(client); timer.resume(); source.resume()
    }
  }
  private func arm(_ client: Connection) { client.timer?.schedule(deadline: .now() + idleTimeout) }
  private func close(_ client: Connection) {
    guard clients[client.fd] === client else { return }
    // An encoder still running off-queue releases its reservation when it returns.
    if client.reply != nil { releaseReplyBudget(client) }
    clients.removeValue(forKey: client.fd); client.writer?.cancel(); client.writer = nil; client.reply = nil; client.timer?.cancel(); client.timer = nil; client.source?.cancel(); client.source = nil
  }
  private func read(_ client: Connection) {
    var bytes = [UInt8](repeating: 0, count: 8192)
    let count = recv(client.fd, &bytes, bytes.count, 0)
    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
    guard count > 0 else { close(client); return }
    if client.reply == nil { arm(client) }
    client.buffer.append(contentsOf: bytes.prefix(count))
    while let end = client.buffer.firstIndex(of: 10) {
      let line = client.buffer.prefix(upTo: end)
      guard line.count <= ControlProtocol.maxRequestBytes, client.lines.count < 8 else { close(client); return }
      client.lines.append(Data(line)); client.buffer.removeSubrange(...end)
    }
    guard client.buffer.count <= ControlProtocol.maxRequestBytes else { close(client); return }
    process(client)
  }
  private func process(_ client: Connection) {
    guard !client.busy, !client.lines.isEmpty, clients[client.fd] === client else { return }
    client.busy = true
    let line = client.lines.removeFirst()
    var id = ""
    var action: String?
    var params: [String: String] = [:]
    if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let value = json["id"] as? String, let name = json["action"] as? String {
      id = value; action = name
      if let raw = json["params"] {
        if let raw = raw as? [String: Any], raw.values.allSatisfy({ $0 is String || $0 is NSNumber }) { params = raw.mapValues { String(describing: $0) } }
        else { action = nil }
      }
    }
    let requestID = id; let requestedAction = action; let values = params
    Task { [self] in
      let result = if let requestedAction { await handler(requestedAction, values) } else { ControlResult.error("bad_request", "Send an id, action and scalar params as newline-delimited JSON.") }
      // Encode off the socket queue, reserving shared capacity before allocating escaped JSON.
      let reply = result.wire(id: requestID) { bytes in
        queue.sync {
          guard clients[client.fd] === client, bytes <= ControlProtocol.maxResponseBytes - reservedReplyBytes else { return false }
          reservedReplyBytes += bytes
          client.reservedBytes += bytes
          return true
        }
      }
      queue.async { [self] in
        guard clients[client.fd] === client else { releaseReplyBudget(client); return }
        client.reply = reply
        guard !reply.isEmpty else { close(client); return }
        client.sent = 0
        client.timer?.schedule(deadline: .now() + .seconds(5))
        let writer = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        writer.setEventHandler { [weak self] in self?.write(client) }
        client.writer = writer
        writer.resume()
      }
    }
  }
  private func releaseReplyBudget(_ client: Connection) {
    reservedReplyBytes -= client.reservedBytes
    client.reservedBytes = 0
  }
  private func write(_ client: Connection) {
    guard clients[client.fd] === client, let reply = client.reply else { return }
    // Nonblocking sends and a bounded chunk keep slow peers off the shared control queue.
    let count = reply.withUnsafeBytes { raw in
      send(client.fd, raw.baseAddress!.advanced(by: client.sent), min(262_144, raw.count - client.sent), 0)
    }
    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
    guard count > 0 else { close(client); return }
    client.sent += count
    guard client.sent == reply.count else { return }
    client.writer?.cancel(); client.writer = nil; client.reply = nil
    releaseReplyBudget(client)
    client.busy = false; arm(client); process(client)
  }

}

struct ControlResult: @unchecked Sendable {
  let body: [String: Any]
  static func ok(_ result: [String: Any]) -> Self { .init(body: ["ok": true, "result": result]) }
  static func error(_ code: String, _ message: String, candidates: [[String: String]] = []) -> Self {
    var error: [String: Any] = ["code": code, "message": message]
    if !candidates.isEmpty { error["candidates"] = candidates }
    return .init(body: ["ok": false, "error": error])
  }
  func wire(id: String, maxBytes: Int = ControlProtocol.maxResponseBytes, reserving: (Int) -> Bool = { _ in true }) -> Data {
    var value = body; value["id"] = id
    // Count escaped JSON before serialisation, so an oversized string is never expanded in memory.
    if let size = Self.jsonSize(value, budget: maxBytes - 1), size < maxBytes, reserving(size + 1) {
      var data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
      data.append(10)
      if data.count <= maxBytes { return data }
    }
    let error = Self.error("response_too_large", "Reply exceeds the available 128 MiB response budget. Export the script to a file or retry when other requests finish.")
    var fallback = error.body; fallback["id"] = id
    let failure = (try! JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys])) + Data([10])
    return failure.count <= maxBytes && reserving(failure.count) ? failure : Data()
  }
  private static func jsonSize(_ value: Any, budget: Int) -> Int? {
    guard budget >= 0 else { return nil }
    var count = 0
    func add(_ amount: Int) -> Bool {
      guard amount <= budget - count else { return false }
      count += amount
      return true
    }
    if let text = value as? String {
      guard add(2) else { return nil }
      for scalar in text.unicodeScalars {
        let bytes: Int
        switch scalar.value {
        case 8, 9, 10, 12, 13, 34, 92: bytes = 2
        case 0...31, 0x2028, 0x2029: bytes = 6
        default: bytes = scalar.utf8.count
        }
        guard add(bytes) else { return nil }
      }
    } else if let object = value as? [String: Any] {
      guard add(2 + max(0, object.count - 1)) else { return nil }
      for (key, item) in object {
        guard let keySize = jsonSize(key, budget: budget - count), add(keySize), add(1),
          let itemSize = jsonSize(item, budget: budget - count), add(itemSize) else { return nil }
      }
    } else if let array = value as? [Any] {
      guard add(2 + max(0, array.count - 1)) else { return nil }
      for item in array {
        guard let size = jsonSize(item, budget: budget - count), add(size) else { return nil }
      }
    } else if value is NSNull {
      guard add(4) else { return nil }
    } else if let number = value as? NSNumber,
      let bytes = try? JSONSerialization.data(withJSONObject: [number]), add(bytes.count - 2) {
      // Foundation handles booleans and numeric formatting identically in the final reply.
    } else { return nil }
    return count
  }

}
