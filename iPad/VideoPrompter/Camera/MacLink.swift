@preconcurrency import AVFoundation
import Network
import CryptoKit
import PrompterCore
import SwiftUI
import UIKit

/// Receives the camera a Mac sends with File › Send Camera to iPad, and the commands of its
/// File › Control iPad. Over USB-C the Mac reaches
/// the iPad through usbmuxd, the same channel Xcode and Finder use, so no network or pairing is
/// needed; the iPad only listens on its own loopback port. On Wi-Fi it advertises itself with
/// Bonjour, but only when Settings allows it, since that asks for local network access.
///
/// One Mac at a time: a new connection replaces the old one.
@MainActor final class MacLink: ObservableObject {
  /// The sending Mac's name while one is connected.
  @Published private(set) var macName: String?
  /// The picture's size as the Mac encodes it; nil while the Mac sends no camera.
  @Published private(set) var pictureSize: CGSize?
  @Published private(set) var pairingFailure: String?
  @Published private(set) var lastFrameTime: Date?
  @Published private(set) var framesSkipped = 0
  @Published private(set) var transportKind: String?

  struct PairingPermission: Identifiable {
    let id = UUID()
    let request: PairingExchange.Request
    let connection: NWConnection
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let peerPublicKey: Data
    let confirmationCode: String
    var consent = PairingConsent()
  }
  struct Credential: Codable {
    var name: String
    var code: String
  }
  @Published var pendingPermission: PairingPermission?
  @Published var scanStatus: String?
  var pairingAvailability = PairingAvailability()
  private var permissionConnections: [NWConnection] = []
  @Published private(set) var scannedOffer: PairingOffer?
  func setPairingScreen(open: Bool) {
    pairingAvailability.screenOpen = open
    if open { startPermissionListener() } else {
      permissionListener?.cancel(); permissionListener = nil
      permissionConnections.forEach { $0.cancel() }; permissionConnections.removeAll()
      approvePairing(false)
      scannedOffer = nil
    }
  }
  func setPresenting(_ value: Bool) {
    pairingAvailability.presenting = value
    if value { setPairingScreen(open: false) }
  }
  private var permissionListener: NWListener?
  private let credentialStore = PairingKeyStore(service: "VideoPrompter.camera-pairing")
  @Published private var credentials: [String: Credential] = {
    PairingKeyStore(service: "VideoPrompter.camera-pairing").load([String: Credential].self, key: "pairedMacCredentials", defaults: .standard) ?? [:]
  }()

  var pairedMacs: [(id: String, name: String)] {
    credentials.map { (id: $0.key, name: $0.value.name) }.sorted { $0.id < $1.id }
  }
  func forgetMac(id: String) {
    var remaining = credentials
    remaining[id] = nil
    guard credentialStore.save(remaining, key: "pairedMacCredentials") else {
      pairingFailure = "Could not forget this Mac. Unlock the iPad and try again."; return
    }
    credentials = remaining
    receiver.dropWiFi()
    wifi?.cancel(); wifi = nil; restartWiFi()
  }
  func forgetTypedKey() { newPairingCode() }
  private func remember(_ id: String, name: String, code: String) throws {
    var next = credentials
    next[id] = Credential(name: name, code: code)
    guard credentialStore.save(next, key: "pairedMacCredentials") else { throw PairingOffer.Failure.foreign }
    credentials = next
    KnownMacs.note(name: name, kind: "Wi-Fi")
    wifi?.cancel(); wifi = nil; restartWiFi()
  }
  func approvePairing(_ allow: Bool) {
    guard var permission = pendingPermission else { return }
    pendingPermission = nil
    if !allow { pairingAvailability.decline() }
    let connection = permission.connection
    guard pairingAvailability.allowsRequest(), permission.consent.consume(allow: allow) else { connection.cancel(); return }
    Task {
      defer { connection.cancel() }
      do {
        let privateKey = permission.privateKey
        let code = "QR:" + UUID().uuidString + UUID().uuidString
        let reply = PairingExchange.Reply(id: deviceID, name: deviceName, code: code)
        let sealed = try PairingExchange.seal(reply, key: PairingExchange.key(privateKey, peer: permission.peerPublicKey))
        // Install only after the local Allow tap, before the Mac starts its TLS connection.
        try remember(permission.request.id, name: permission.request.name, code: code)
        try await PairingExchange.send(sealed, on: connection)
      } catch { pairingFailure = "Could not connect to that Mac. Try again." }
    }
  }
  private func startPermissionListener() {
    guard allowsWiFi, pairingAvailability.allowsRequest(), permissionListener == nil,
      let listener = try? NWListener(using: .tcp) else { return }
    listener.service = .init(name: deviceID, type: PairingExchange.padService)
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        guard let self, self.pairingAvailability.allowsRequest(), self.permissionConnections.count < 2 else { connection.cancel(); return }
        self.permissionConnections.append(connection)
        defer { self.permissionConnections.removeAll { $0 === connection } }
        connection.start(queue: .main); PairingExchange.expire(connection)
        do {
          let request = try JSONDecoder().decode(PairingExchange.Request.self, from: await PairingExchange.receive(on: connection))
          guard self.allowsWiFi, self.pairingAvailability.allowsRequest(), self.pendingPermission == nil, UUID(uuidString: request.id) != nil,
            request.publicKeyCommitment.count == 32, !request.name.isEmpty, request.name.count <= 128 else { connection.cancel(); return }
          let privateKey = Curve25519.KeyAgreement.PrivateKey()
          // Commit before revealing either key, so an interceptor cannot choose matching numbers.
          try await PairingExchange.send(PairingExchange.commitment(privateKey.publicKey.rawRepresentation), on: connection)
          let peerPublicKey = try await PairingExchange.receive(on: connection)
          guard PairingExchange.commitment(peerPublicKey) == request.publicKeyCommitment else { connection.cancel(); return }
          let shared = try PairingExchange.key(privateKey, peer: peerPublicKey)
          try await PairingExchange.send(privateKey.publicKey.rawRepresentation, on: connection)
          guard self.allowsWiFi, self.pairingAvailability.allowsRequest(), self.pendingPermission == nil else { connection.cancel(); return }
          self.pendingPermission = PairingPermission(request: request, connection: connection, privateKey: privateKey, peerPublicKey: peerPublicKey,
            confirmationCode: PairingExchange.confirmationCode(shared))
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(55))
            if self.pendingPermission?.connection === connection { self.approvePairing(false) }
          }
        } catch { connection.cancel() }
      }
    }
    listener.start(queue: .main); permissionListener = listener
  }
  func scanPairingCode(_ value: String) async {
    do {
      scannedOffer = try PairingOffer.decode(value, clockSkew: 60)
      scanStatus = "Confirm the Mac to pair."
    } catch { scanStatus = "That code is invalid or expired. Scan a new code." }
  }

  func confirmScannedPairing(_ allow: Bool) async {
    guard let offer = scannedOffer else { return }
    scannedOffer = nil
    guard allow, !pairingAvailability.presenting else { scanStatus = "Pairing cancelled."; return }
    do {
      scanStatus = "Connecting to \(offer.name)…"
      allowsWiFi = true
      let connection = PairingExchange.connect(.service(name: offer.service, type: PairingExchange.macService, domain: "local.", interface: nil), code: offer.secret)
      defer { connection.cancel() }
      let key = Curve25519.KeyAgreement.PrivateKey()
      let request = PairingExchange.Request(id: deviceID, name: deviceName,
        publicKeyCommitment: PairingExchange.commitment(key.publicKey.rawRepresentation), offer: offer)
      try await PairingExchange.send(JSONEncoder().encode(request), on: connection)
      let publicKey = try await PairingExchange.receive(on: connection)
      let shared = try PairingExchange.key(key, peer: publicKey, salt: offer.secret)
      scanStatus = "Check \(PairingExchange.confirmationCode(shared)) matches on \(offer.name), then click Numbers match on the Mac."
      try await PairingExchange.send(key.publicKey.rawRepresentation, on: connection)
      // Install before acknowledging, so the Mac's first secure connection finds its key.
      try remember(offer.macID.uuidString, name: offer.name, code: PairingExchange.credential(shared))
      try await PairingExchange.send(PairingExchange.seal(.init(id: deviceID, name: deviceName, code: "installed"), key: shared), on: connection)
      let reply = try PairingExchange.open(await PairingExchange.receive(on: connection), key: shared)
      guard reply.id == offer.macID.uuidString, reply.code == "accepted" else { throw PairingOffer.Failure.foreign }
      scanStatus = "Paired with \(offer.name). Waiting for the connection…"
    } catch { scanStatus = "Can’t find that Mac on this Wi-Fi. Try scanning a new code." }
  }

  func disconnect() { receiver.disconnect() }

  let deviceID = PadIdentity(defaults: .standard).id
  @Published var deviceName = PadIdentity(defaults: .standard).name {
    didSet {
      let clean = PadIdentity.cleanName(deviceName)
      UserDefaults.standard.set(clean, forKey: "macLinkDeviceName")
      wifi?.cancel()
      wifi = nil
      restartWiFi()
    }
  }

  /// Commands from the Mac's remote.
  var onCommand: ((PadRemote.Command) -> Void)?
  @Published var allowsWiFi = (UserDefaults.standard.object(forKey: "macLinkWiFi") as? Bool ?? true) {
    didSet {
      UserDefaults.standard.set(allowsWiFi, forKey: "macLinkWiFi")
      restartWiFi()
    }
  }
  /// The key a Mac needs to send over Wi-Fi, shown in Settings. It keys the TLS that the Wi-Fi
  /// link runs over, so only a Mac given the key can connect and nothing else can read the
  /// picture. A new key unpairs every Mac. Stored under a new name, so a six-digit code from an
  /// earlier build is replaced.
  @Published private(set) var pairingCode: String = {
    let store = PairingKeyStore(service: "VideoPrompter.camera-pairing")
    if let code = store.load(String.self, key: "macLinkKey", defaults: .standard) { return code }
    let code = CameraLinkSecurity.newCode()
    store.save(code, key: "macLinkKey")
    return code
  }()

  func newPairingCode() {
    // Rotating the shared typed key does not revoke individually paired Macs.
    let next = CameraLinkSecurity.newCode()
    guard credentialStore.save(next, key: "macLinkKey") else {
      pairingFailure = "Could not change the key. Unlock the iPad and try again."; return
    }
    pairingCode = next
    if allowsWiFi {
      wifi?.cancel()
      wifi = nil
      receiver.dropWiFi()
      restartWiFi()
    }
  }

  /// Tells the Mac what the presenter shows. Dropped unless a Mac that reads it is connected.
  func send(_ command: PadRemote.Command) { receiver.send(.command(command)) }

  func send(_ state: PadRemote.State) { receiver.send(.state(state)) }

  /// Called when a Mac connects or goes, so the camera can switch to it and back.
  var onChange: (() -> Void)?

  /// Where the frames go. One layer for the app: the presenter's preview hosts it.
  let displayLayer = AVSampleBufferDisplayLayer()
  private let receiver: LinkReceiver
  private var usb: NWListener?
  private var wifi: NWListener?

  init() {
    displayLayer.videoGravity = .resize
    displayLayer.backgroundColor = UIColor.black.cgColor
    receiver = LinkReceiver(renderer: displayLayer.sampleBufferRenderer)
    receiver.onEvent = { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
  }

  /// Starts listening, or starts again after the app comes back from the background, where iOS
  /// may have torn the listeners down.
  #if DEBUG && targetEnvironment(simulator)
  private var qrFixtureStarted = false
  #endif
  func start() {
    #if DEBUG && targetEnvironment(simulator)
    if !qrFixtureStarted, ProcessInfo.processInfo.environment["VP_IPAD_E2E_QR"] == "1" {
      qrFixtureStarted = true
      // Exercise the iPad-only lifecycle and Forget paths on the disposable simulator.
      assert(permissionListener == nil)
      setPairingScreen(open: true)
      assert(permissionListener != nil)
      setPairingScreen(open: false)
      assert(permissionListener == nil)
      let firstID = UUID().uuidString, secondID = UUID().uuidString
      try! remember(firstID, name: "Same name", code: "QR:fixture-one")
      try! remember(secondID, name: "Same name", code: "QR:fixture-two")
      forgetMac(id: firstID)
      assert(credentials[firstID] == nil && credentials[secondID] != nil)
      forgetTypedKey()
      assert(credentials[secondID] != nil)
      forgetMac(id: secondID)
      Task { @MainActor in
        let file = URL.documentsDirectory.appendingPathComponent("vp-qr-payload.txt")
        for _ in 0..<1200 {
          if let value = try? String(contentsOf: file, encoding: .utf8) {
            try? FileManager.default.removeItem(at: file)
            await scanPairingCode(value)
            await confirmScannedPairing(true)
            try? Data((scanStatus ?? "No result").utf8).write(to: URL.documentsDirectory.appendingPathComponent("vp-qr-result.txt"))
            break
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    }
    #endif
    if usb == nil || Self.needsRestart(usb!.state) { usb = makeUSBListener() }
    restartWiFi()
  }

  private static func needsRestart(_ state: NWListener.State) -> Bool {
    switch state {
    case .failed, .cancelled: true
    default: false
    }
  }

  private func makeUSBListener() -> NWListener? {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true
    var portNumber = CameraLink.usbPort
    #if targetEnvironment(simulator)
    // Simulators share host loopback. The headless fixture supplies an isolated port.
    if let raw = ProcessInfo.processInfo.environment["VP_IPAD_E2E_PORT"],
      let fixturePort = UInt16(raw), fixturePort >= 1024 { portNumber = fixturePort }
    #endif
    guard let port = NWEndpoint.Port(rawValue: portNumber),
      let listener = try? NWListener(using: parameters, on: port)
    else { return nil }
    configure(listener)
    return listener
  }

  private func restartWiFi() {
    startPermissionListener()
    if !allowsWiFi {
      permissionListener?.cancel(); permissionListener = nil
      approvePairing(false)
      wifi?.cancel()
      wifi = nil
      // Turning Wi-Fi off also ends a Mac already sending over it; USB-C carries on.
      receiver.dropWiFi()
    } else if wifi == nil || Self.needsRestart(wifi!.state) {
      let parameters = CameraLinkSecurity.parameters(code: pairingCode, additionalCodes: credentials.values.map(\.code))
      parameters.includePeerToPeer = false
      guard let listener = try? NWListener(using: parameters) else { return }
      listener.service = NWListener.Service(name: PadIdentity(defaults: .standard).serviceName, type: CameraLink.bonjourType)
      // Before it starts, so the receiver knows it before any of its connections arrive.
      receiver.adoptWiFi(listener)
      configure(listener, wifi: true)
      wifi = listener
    }
  }

  private func configure(_ listener: NWListener, wifi: Bool = false) {
    let receiver = self.receiver
    listener.newConnectionHandler = { [weak listener] connection in
      receiver.accept(connection, overWiFi: wifi, from: listener)
    }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      guard case .failed = state else { return }
      listener?.cancel()
      // Usually the port coming back after the background; try again shortly.
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        self?.start()
      }
    }
    listener.start(queue: receiver.queue)
  }

  /// Why the last Mac went, "drop" or "replaced"; the end-to-end test reads it through PadStore.
  private(set) var lastEndReason = ""

  private func ended(_ reason: String) {
    guard macName != nil else { return }
    lastEndReason = reason
    macName = nil
    pictureSize = nil
    lastFrameTime = nil
    framesSkipped = 0
    transportKind = nil
    onChange?()
  }

  private func handle(_ event: LinkReceiver.Event) {
    switch event {
    case .connected(let name, let transport):
      pairingFailure = nil
      transportKind = transport
      macName = name
      if scanStatus != nil { scanStatus = "Connected to \(name)" }
      onChange?()
    case .format(let size):
      pictureSize = size
      if size == nil { lastFrameTime = nil; framesSkipped = 0 }
      onChange?()
    case .frame(let date, let skipped):
      if let date {
        lastFrameTime = date
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["VP_IPAD_E2E_PORT"] != nil {
          try? Data("decoded".utf8).write(to: URL.documentsDirectory.appendingPathComponent("vp-e2e-frame.txt"), options: .atomic)
        }
        #endif
      }
      framesSkipped = skipped
    case .pairingFailed(let reason): pairingFailure = reason
    case .command(let command):
      onCommand?(command)
    case .disconnected: ended("drop")
    case .replaced: ended("replaced")
    }
  }
}

/// The network side: reads messages and turns frames into sample buffers for the renderer, all on
/// one serial queue. `@unchecked Sendable` because every stored property is touched on `queue`
/// only, except `onEvent`, which is set once before the first connection.
final class LinkReceiver: @unchecked Sendable {
  enum Event: Sendable {
    case connected(String, String)
    case frame(Date?, Int)
    case pairingFailed(String)
    case format(CGSize?)
    case command(PadRemote.Command)
    case disconnected
    /// Another Mac took the link over while this one was connected.
    case replaced
  }

  let queue = DispatchQueue(label: "VideoPrompter.maclink", qos: .userInteractive)
  var onEvent: (@Sendable (Event) -> Void)?
  private let renderer: AVSampleBufferVideoRenderer
  private var connection: NWConnection?
  private var connectionIsWiFi = false
  /// The connected Mac's protocol version, from its hello.
  private var peerVersion = 0
  private var reader = CameraLink.Reader()
  private var format: CMVideoFormatDescription?
  /// After a connection or a decoder failure, frames wait for the next key frame.
  private var needsKeyFrame = true
  private var framesSkipped = 0
  private var senderFramesSkipped = 0

  init(renderer: AVSampleBufferVideoRenderer) {
    self.renderer = renderer
  }

  /// Connections still in their handshake, and whether each came over Wi-Fi.
  private var pending: [(connection: NWConnection, wifi: Bool)] = []

  /// The Wi-Fi listener in use. Cancelling a listener is not immediate, so a connection from one
  /// already replaced (Wi-Fi off, new pairing code) is refused here.
  private weak var wifiListener: NWListener?

  func adoptWiFi(_ listener: NWListener) {
    queue.async { [self] in wifiListener = listener }
  }

  /// Called on `queue`, where the listeners run.
  func accept(_ new: NWConnection, overWiFi: Bool, from listener: NWListener?) {
    if overWiFi, listener == nil || listener !== wifiListener {
      new.cancel()
      return
    }
    guard pending.count < 4 else { new.cancel(); return }
    // The current Mac stays until the newcomer is ready, so a peer that fails the pairing
    // handshake cannot knock it off.
    pending.append((new, overWiFi))
    new.stateUpdateHandler = { [weak self, weak new] state in
      guard let self, let new else { return }
      switch state {
      case .ready: self.promote(new, overWiFi: overWiFi)
      case .failed(let error):
        if overWiFi, self.pending.contains(where: { $0.connection === new }), case .tls = error {
          self.onEvent?(.pairingFailed("Pairing failed. Check the key on this iPad and try again."))
        }
        self.pending.removeAll { $0.connection === new }
        self.closed(new)
      case .cancelled:
        self.pending.removeAll { $0.connection === new }
        self.closed(new)
      default: break
      }
    }
    new.start(queue: queue)
    // A handshake that never finishes must not linger.
    queue.asyncAfter(deadline: .now() + 10) { [weak self, weak new] in
      guard let self, let new, self.pending.contains(where: { $0.connection === new }) else { return }
      // Out of `pending` first, so a `.ready` already queued cannot promote it.
      self.pending.removeAll { $0.connection === new }
      new.cancel()
    }
  }

  private func promote(_ new: NWConnection, overWiFi: Bool) {
    // Dropped while it shook hands: Wi-Fi was turned off or the pairing code changed.
    guard pending.contains(where: { $0.connection === new }) else { return }
    pending.removeAll { $0.connection === new }
    connection?.cancel()
    // The Mac that replaces it is a different sender: a disconnect first, so anything tied to the
    // old one (the Mac's voice relay) ends, and it may send no picture.
    if connection != nil { onEvent?(.replaced) }
    framesSkipped = 0
    senderFramesSkipped = 0
    connection = new
    connectionIsWiFi = overWiFi
    peerVersion = 0
    reader = CameraLink.Reader()
    format = nil
    needsKeyFrame = true
    renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    receive(on: new)
  }

  func disconnect() {
    queue.async { [self] in
      for waiting in pending { waiting.connection.cancel() }
      pending.removeAll()
      guard let current = connection else { return }
      current.send(content: CameraLink.Message.goodbye.encoded(), completion: .contentProcessed { _ in current.cancel() })
      closed(current)
    }
  }

  func dropWiFi() {
    queue.async { [self] in
      wifiListener = nil
      if connectionIsWiFi { connection?.cancel() }
      for waiting in pending where waiting.wifi { waiting.connection.cancel() }
      pending.removeAll { $0.wifi }
    }
  }

  /// A Mac from before version 2 never reads, so nothing is sent to it to pile up.
  func send(_ message: CameraLink.Message) {
    queue.async { [self] in
      guard peerVersion >= 2, let connection else { return }
      connection.send(content: message.encoded(), completion: .idempotent)
    }
  }

  private func receive(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      guard let self, connection === self.connection else { return }
      if let data, !data.isEmpty {
        do {
          for message in try self.reader.append(data) { self.handle(message) }
        } catch {
          connection.cancel()
          return
        }
      }
      if isComplete || error != nil {
        connection.cancel()
      } else {
        self.receive(on: connection)
      }
    }
  }

  private func closed(_ old: NWConnection) {
    guard old === connection else { return }
    connection = nil
    format = nil
    renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    onEvent?(.disconnected)
  }

  private func handle(_ message: CameraLink.Message) {
    switch message {
    case .hello(let name, let version):
      peerVersion = version
      onEvent?(.connected(name, connectionIsWiFi ? "Wi-Fi" : "USB-C"))
    case .format(let width, let height, let sets):
      senderFramesSkipped = 0
      if sets.isEmpty { framesSkipped = 0 }
      format = Self.formatDescription(sets)
      needsKeyFrame = true
      if sets.isEmpty { renderer.flush(removingDisplayedImage: true, completionHandler: nil) }
      onEvent?(.format(sets.isEmpty ? nil : CGSize(width: width, height: height)))
    case .frame(_, let keyFrame, let data):
      let shown = enqueue(data, keyFrame: keyFrame)
      if !shown { framesSkipped += 1 }
      onEvent?(.frame(shown ? Date() : nil, framesSkipped + senderFramesSkipped))
    case .goodbye:
      connection?.cancel()
    case .command(let command):
      if case .macStatus(let status) = command, let skipped = status.framesSkipped {
        senderFramesSkipped = min(10_000_000, max(0, skipped))
        onEvent?(.frame(nil, framesSkipped + senderFramesSkipped))
      }
      onEvent?(.command(command))
    case .state:
      break
    }
  }

  private func enqueue(_ data: Data, keyFrame: Bool) -> Bool {
    guard let format else { return false }
    if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
      renderer.flush()
      needsKeyFrame = true
    }
    if needsKeyFrame {
      guard keyFrame else { return false }
      needsKeyFrame = false
    }
    // A slow decoder must not build a queue: the picture is for framing, and a late frame is
    // worse than a dropped one.
    // A dropped frame breaks the ones that refer to it, so wait for the next key frame.
    guard renderer.isReadyForMoreMediaData || keyFrame, let sample = Self.sampleBuffer(data, format: format) else {
      needsKeyFrame = true
      return false
    }
    renderer.enqueue(sample)
    return true
  }

  private static func formatDescription(_ sets: [Data]) -> CMVideoFormatDescription? {
    guard sets.count >= 2 else { return nil }
    var description: CMVideoFormatDescription?
    let status = sets.withPointers { pointers, sizes in
      CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
        parameterSetPointers: pointers, parameterSetSizes: sizes,
        nalUnitHeaderLength: 4, formatDescriptionOut: &description)
    }
    return status == noErr ? description : nil
  }

  private static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
      let block,
      data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }) == noErr
    else { return nil }
    var sample: CMSampleBuffer?
    var size = data.count
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sample
    else { return nil }
    // No timing: each frame shows the moment it is decoded, which is the lowest delay there is.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}

extension Array where Element == Data {
  /// Pointers to every element's bytes at once, as the parameter-set API wants them.
  fileprivate func withPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
    let copies = map { [UInt8]($0) }
    var pointers: [UnsafePointer<UInt8>] = []
    func nest(_ index: Int) -> R {
      guard index < copies.count else { return body(pointers, copies.map(\.count)) }
      return copies[index].withUnsafeBufferPointer { buffer in
        pointers.append(buffer.baseAddress!)
        return nest(index + 1)
      }
    }
    return nest(0)
  }
}

/// The Mac's picture behind the script, fitted, turned and mirrored like a USB camera's, with
/// the same framing guides.
struct LinkPreview: UIViewRepresentable {
  @ObservedObject var camera: PadCamera
  @ObservedObject var link: MacLink

  func makeUIView(context: Context) -> LinkView { LinkView(displayLayer: link.displayLayer) }

  func updateUIView(_ view: LinkView, context: Context) {
    view.update(size: link.pictureSize, mirrored: camera.mirrored, guides: camera.guides)
  }

  final class LinkView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer
    private let guideLayer = CAShapeLayer()
    private let shadeLayer = CAShapeLayer()
    private var size: CGSize?
    private var mirrored = false
    private var guides = CameraGuides()

    init(displayLayer: AVSampleBufferDisplayLayer) {
      self.displayLayer = displayLayer
      super.init(frame: .zero)
      backgroundColor = .black
      shadeLayer.fillRule = .evenOdd
      guideLayer.fillColor = nil
      guideLayer.lineWidth = 1.5
      displayLayer.removeFromSuperlayer()
      layer.addSublayer(displayLayer)
      layer.addSublayer(shadeLayer)
      layer.addSublayer(guideLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(size: CGSize?, mirrored: Bool, guides: CameraGuides) {
      self.size = size
      self.mirrored = mirrored
      self.guides = guides
      setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      let aspect = size ?? CGSize(width: 16, height: 9)
      let picture = guides.rotation.fittedRect(aspect: aspect, in: bounds)
      // The layer is laid out unturned at the picture's own shape, then turned and flipped about
      // its centre to land on `picture`.
      let unturned = guides.rotation.swapsAxes
        ? CGSize(width: picture.height, height: picture.width) : picture.size
      displayLayer.transform = CATransform3DIdentity
      displayLayer.bounds = CGRect(origin: .zero, size: unturned)
      displayLayer.position = CGPoint(x: picture.midX, y: picture.midY)
      var transform = CATransform3DMakeRotation(guides.rotation.radians, 0, 0, 1)
      if mirrored { transform = CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), transform) }
      displayLayer.transform = transform
      shadeLayer.frame = bounds
      guideLayer.frame = bounds
      guideLayer.path = CameraOverlay.guidePath(picture: picture, guides: guides)
      guideLayer.strokeColor = guides.strokeColor
      shadeLayer.path = guides.marker == nil ? nil : CameraOverlay.shadePath(picture: picture, guides: guides)
      shadeLayer.fillColor = guides.shadeColor
      CATransaction.commit()
    }
  }
}
