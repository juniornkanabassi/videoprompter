import Combine
import Foundation
@preconcurrency import Network

public struct OBSSnapshot: Codable, Sendable {
  public struct TokenRange: Codable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
  }
  public struct Run: Codable, Sendable {
    public let text: String
    public let spokenTokenStart: Int
    public let spokenTokenCount: Int
    public let tokenRanges: [TokenRange]
    public init(text: String, spokenTokenStart: Int, spokenTokenCount: Int, tokenRanges: [TokenRange] = []) {
      self.text = text
      self.spokenTokenStart = spokenTokenStart
      self.spokenTokenCount = spokenTokenCount
      self.tokenRanges = tokenRanges
    }
  }
  public let runs: [Run]
  public let activeTokenIndex: Int
  public let fontSize: Double
  public let textOpacity: Double
  public let backgroundOpacity: Double
  public let mirrorX: Bool
  public let mirrorY: Bool
  public let rotation: Int
  public let guideFraction: Double
  public let fontName: String
  public init(
    runs: [Run] = [], activeTokenIndex: Int = 0, fontSize: Double = 44, textOpacity: Double = 1,
    backgroundOpacity: Double = 0.82, mirrorX: Bool = false, mirrorY: Bool = false,
    rotation: Int = 0, guideFraction: Double = 0.35, fontName: String = "SF Pro"
  ) {
    self.runs = runs
    self.activeTokenIndex = activeTokenIndex
    self.fontSize = fontSize
    self.textOpacity = textOpacity
    self.backgroundOpacity = backgroundOpacity
    self.mirrorX = mirrorX
    self.mirrorY = mirrorY
    self.rotation = rotation
    self.guideFraction = guideFraction
    self.fontName = fontName
  }
}

@MainActor public final class OBSServer: ObservableObject {
  public enum ServerError: Error { case alreadyRunning, failedToStart, invalidRequest }
  @Published public private(set) var url: URL?
  @Published public private(set) var status = "Stopped"
  private var listener: NWListener?
  private var startContinuation: CheckedContinuation<URL, Error>?
  private var token = ""
  private var snapshot = OBSSnapshot()
  private let encoder = JSONEncoder()
  private static let maximumHeaderBytes = 8192
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
  public init() {}
  public func start() async throws -> URL {
    guard listener == nil else { throw ServerError.alreadyRunning }
    token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host("127.0.0.1"), port: .any)
    let l = try NWListener(using: parameters)
    listener = l
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        startContinuation = continuation
        l.stateUpdateHandler = { [weak self] state in
          Task { @MainActor [weak self] in
            guard let self, self.listener === l else { return }
            if case .ready = state, let p = l.port {
              let u = URL(string: "http://127.0.0.1:\(p.rawValue)/\(self.token)/")!
              self.url = u
              self.status = "Running"
              self.completeStart(.success(u), listener: l)
            }
            if case .failed(let error) = state {
              self.status = "Failed"
              self.completeStart(.failure(error), listener: l)
              self.cancelConnections()
              l.cancel()
              self.listener = nil
              self.url = nil
            }
          }
        }
        l.newConnectionHandler = { [weak self] connection in
          Task { @MainActor [weak self] in
            guard let self, self.listener === l, self.connections.count < 8 else {
              connection.cancel()
              return
            }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
              Task { @MainActor [weak self] in
                if case .cancelled = state {
                  self?.removeConnection(id)
                }
              }
            }
            connection.start(queue: .main)
            self.scheduleTimeout(for: connection, id: id)
            self.receive(connection, Data())
          }
        }
        l.start(queue: .main)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.listener === l else { return }
        self?.stop()
      }
    }
  }
  public func stop() {
    if let listener {
      completeStart(.failure(CancellationError()), listener: listener)
      listener.cancel()
    }
    listener = nil
    url = nil
    status = "Stopped"
    cancelConnections()
  }
  private func completeStart(_ result: Result<URL, Error>, listener: NWListener) {
    guard let continuation = startContinuation else { return }
    startContinuation = nil
    continuation.resume(with: result)
  }
  public func update(snapshot: OBSSnapshot) { self.snapshot = snapshot }
  private func scheduleTimeout(for connection: NWConnection, id: ObjectIdentifier) {
    let timeout = DispatchWorkItem { [weak self, weak connection] in
      guard let connection else { return }
      Task { @MainActor [weak self] in
        guard let self, self.connections[id] != nil else { return }
        self.removeConnection(id)
        connection.cancel()
      }
    }
    connectionTimeouts[id] = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
  }
  private func removeConnection(_ id: ObjectIdentifier) {
    connectionTimeouts.removeValue(forKey: id)?.cancel()
    connections.removeValue(forKey: id)
  }
  private func cancelConnections() {
    connectionTimeouts.values.forEach { $0.cancel() }
    connectionTimeouts.removeAll()
    connections.values.forEach { $0.cancel() }
    connections.removeAll()
  }
  private func receive(_ c: NWConnection, _ data: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] chunk, _, complete, _ in
      var all = data
      all.append(chunk ?? Data())
      Task { @MainActor [weak self] in
        guard let self else {
          c.cancel()
          return
        }
        guard self.connections[ObjectIdentifier(c)] != nil else {
          c.cancel()
          return
        }
        let delimiter = Data("\r\n\r\n".utf8)
        if let headerEnd = all.range(of: delimiter)?.upperBound {
          if headerEnd > Self.maximumHeaderBytes {
            self.write(c, 413, "Payload Too Large", Data())
            return
          }
        } else if all.count >= Self.maximumHeaderBytes {
          self.write(c, 413, "Payload Too Large", Data())
          return
        }
        if all.range(of: delimiter) != nil {
          self.respond(c, all)
          return
        }
        if complete {
          self.removeConnection(ObjectIdentifier(c))
          c.cancel()
          return
        }
        self.receive(c, all)
      }
    }
  }
  private func respond(_ c: NWConnection, _ data: Data) {
    guard let request = String(data: data, encoding: .utf8),
      let first = request.components(separatedBy: "\r\n").first
    else {
      c.cancel()
      return
    }
    let parts = first.split(separator: " ")
    guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/") else {
      write(c, 400, "Bad Request", Data())
      return
    }
    let path = String(parts[1])
    guard path == "/\(token)/" || path == "/\(token)/state" || path == "/\(token)/script.js" else {
      write(c, 404, "Not Found", Data())
      return
    }
    let host =
      request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("host:") }).map {
        String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces)
      } ?? ""
    let origin = request.split(separator: "\r\n").first(where: {
      $0.lowercased().hasPrefix("origin:")
    }).map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
    let port = url?.port.map(String.init) ?? ""
    guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)",
      origin == nil || origin == "http://127.0.0.1:\(port)" || origin == "http://localhost:\(port)"
    else {
      write(c, 403, "Forbidden", Data())
      return
    }
    if path.hasSuffix("state") {
      guard let body = try? encoder.encode(snapshot) else {
        write(c, 500, "Error", Data())
        return
      }
      write(c, 200, "OK", body, "application/json")
    } else if path.hasSuffix("script.js") {
      write(c, 200, "OK", Data(Self.script.utf8), "text/javascript; charset=utf-8")
    } else {
      write(c, 200, "OK", Data(Self.html.utf8), "text/html; charset=utf-8")
    }
  }
  private func write(
    _ c: NWConnection, _ code: Int, _ text: String, _ body: Data, _ type: String = "text/plain"
  ) {
    let h =
      "HTTP/1.1 \(code) \(text)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    c.send(content: Data(h.utf8) + body, completion: .contentProcessed { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.removeConnection(ObjectIdentifier(c))
        c.cancel()
      }
    })
  }
  private static let html = """
     <!doctype html><meta charset=utf-8><meta http-equiv=Content-Security-Policy content="default-src 'none'; connect-src 'self'; script-src 'self'; style-src 'unsafe-inline'"><main id=root></main><script src="script.js"></script><style>html,body{margin:0;min-height:100%;background:transparent;color:white}body{display:flex;align-items:flex-start;justify-content:center}main{width:100%;padding:8vh 8vw;box-sizing:border-box;line-height:1.25}</style>
    """
  private static let script = """
    const root=document.getElementById('root');let key='';function el(t,c){const n=document.createElement(t);if(c)n.textContent=c;return n}function draw(s){const next=JSON.stringify([s.runs,s.fontSize,s.fontName,s.textOpacity,s.backgroundOpacity,s.mirrorX,s.mirrorY,s.rotation]);if(next!==key){key=next;root.replaceChildren();root.style.cssText=`font-family:${s.fontName};font-size:${s.fontSize}px;opacity:${s.textOpacity};background:rgba(0,0,0,${s.backgroundOpacity});transform:scaleX(${s.mirrorX?-1:1}) scaleY(${s.mirrorY?-1:1}) rotate(${s.rotation}deg)`;s.runs.forEach(r=>{const p=el('p');r.tokenRanges.forEach((x,i)=>{const w=el('span',r.text.slice(x.location,x.location+x.length)+' ');w.dataset.token=r.spokenTokenStart+i;p.append(w)});root.append(p)})}root.querySelectorAll('[data-token]').forEach(n=>n.classList.toggle('active',+n.dataset.token===s.activeTokenIndex));const active=root.querySelector('.active');if(active)active.scrollIntoView({block:'center'})}async function tick(){try{const r=await fetch('state',{cache:'no-store'});draw(await r.json())}catch(e){root.replaceChildren(el('p','JuniorPrompter is not connected'))}}setInterval(tick,250);tick()
    """
}
