#if os(macOS)
@preconcurrency import AVFoundation
import AppKit
import Darwin
import Network
import PrompterCore
import SwiftUI
import Synchronization
import VideoToolbox

/// File › Send Camera to iPad. The camera this Mac shows goes to Video Prompter on an iPad, which
/// puts it behind the script. Over USB-C it travels through usbmuxd, the channel Finder and Xcode
/// use to talk to an iPad, so it needs no network and no pairing beyond "Trust This Computer".
/// An iPad that allows it is also found on the same Wi-Fi with Bonjour. USB-C wins when both are
/// there: it is faster and nothing else shares it.
///
/// The camera is the one the Camera window shows, from the same shared session, so a DeckLink
/// or ATEM feed is opened once. Frames are encoded to H.264 in hardware at up to 1080p.
@MainActor final class IPadCameraSender: ObservableObject {
  static let shared = IPadCameraSender()

  @Published var isOn = false { didSet { if isOn != oldValue { isOn ? start() : stop() } } }
  /// What the menu shows under the toggle.
  @Published private(set) var status = "Off"
  /// Off by default: USB-C needs no trust decision, while Wi-Fi is unencrypted and anything on
  /// the network can advertise itself as an iPad.
  @Published var usesWiFi = UserDefaults.standard.bool(forKey: "sendCameraOverWiFi") {
    didSet {
      UserDefaults.standard.set(usesWiFi, forKey: "sendCameraOverWiFi")
      if isOn { usesWiFi ? startBrowsing() : stopBrowsing() }
    }
  }
  /// iPads the user has agreed to send to over Wi-Fi, by their Bonjour name.
  private var trustedNames = Set(UserDefaults.standard.stringArray(forKey: "sendCameraTrustedIPads") ?? []) {
    didSet { UserDefaults.standard.set(Array(trustedNames), forKey: "sendCameraTrustedIPads") }
  }
  /// Asked about and refused in this run, so the question is not repeated.
  private var declinedNames = Set<String>()

  private let output = AVCaptureVideoDataOutput()
  private let encoder = LinkEncoder()
  private var mux: USBMuxListener?
  private var browser: NWBrowser?
  private var wifiTargets: [NWEndpoint] = []
  private var usbDevices: [Int] = []
  private var pipe: LinkPipe?
  private var connecting = false
  private var retry: Task<Void, Never>?

  private func start() {
    let camera = CameraModel.shared
    camera.start()
    guard let uid = camera.selectedUID else {
      status = "Choose a camera in the Camera window first"
      isOn = false
      return
    }
    let shared = SharedCameraSession.shared
    shared.select(uid)
    shared.retain()
    let output = self.output
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    output.setSampleBufferDelegate(encoder, queue: encoder.captureQueue)
    shared.reconfigure { session in
      session.beginConfiguration()
      if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
      session.commitConfiguration()
    }
    status = "Looking for an iPad…"
    let mux = USBMuxListener { [weak self] devices in
      Task { @MainActor in self?.usbChanged(devices) }
    }
    mux.start()
    self.mux = mux
    if usesWiFi { startBrowsing() }
  }

  private func startBrowsing() {
    guard browser == nil else { return }
    let browser = NWBrowser(for: .bonjour(type: CameraLink.bonjourType, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let endpoints = results.map(\.endpoint)
      Task { @MainActor in self?.wifiChanged(endpoints) }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  private func stopBrowsing() {
    browser?.cancel()
    browser = nil
    wifiTargets = []
    if pipe?.name == "Wi-Fi" { pipe?.close() }
  }

  private func stop() {
    retry?.cancel()
    mux?.stop()
    mux = nil
    stopBrowsing()
    usbDevices = []
    declinedNames = []
    pipe?.send(CameraLink.Message.goodbye.encoded())
    pipe?.close()
    pipe = nil
    encoder.attach(nil)
    let output = self.output
    let shared = SharedCameraSession.shared
    shared.reconfigure { session in
      session.beginConfiguration()
      session.removeOutput(output)
      session.commitConfiguration()
    }
    shared.release()
    status = "Off"
  }

  private func usbChanged(_ devices: [Int]) {
    usbDevices = devices
    connectIfNeeded()
  }

  /// Only iPads the user has named as theirs are sent to. A new one is asked about once, with
  /// the warning that Wi-Fi carries the picture unencrypted.
  private func wifiChanged(_ endpoints: [NWEndpoint]) {
    for name in endpoints.compactMap(Self.serviceName) where !trustedNames.contains(name) && !declinedNames.contains(name) {
      let alert = NSAlert()
      alert.messageText = "Send this Mac's camera to “\(name)” over Wi-Fi?"
      alert.informativeText = "Only say yes if this is your iPad. On Wi-Fi the picture is not encrypted, so use it on a network you trust; a USB-C cable needs no question."
      alert.addButton(withTitle: "Send to This iPad")
      alert.addButton(withTitle: "Not Now")
      if alert.runModal() == .alertFirstButtonReturn { trustedNames.insert(name) } else { declinedNames.insert(name) }
    }
    wifiTargets = endpoints.filter { Self.serviceName($0).map(trustedNames.contains) ?? false }
    connectIfNeeded()
  }

  private static func serviceName(_ endpoint: NWEndpoint) -> String? {
    if case .service(let name, _, _, _) = endpoint { return name }
    return nil
  }

  /// Tries each USB-C device, then each iPad on Wi-Fi, until one answers. An iPhone, or an iPad
  /// without Video Prompter open, refuses the port and the next is tried.
  private func connectIfNeeded() {
    guard isOn, pipe == nil, !connecting else { return }
    connecting = true
    let usb = usbDevices
    let wifi = wifiTargets
    Task {
      var opened: LinkPipe?
      for device in usb {
        if let socket = await USBMux.connect(device: device, port: CameraLink.usbPort) {
          opened = SocketPipe(socket: socket, name: "USB-C")
          break
        }
      }
      if opened == nil {
        for endpoint in wifi {
          if let pipe = await NetworkPipe.open(endpoint) {
            opened = pipe
            break
          }
        }
      }
      connecting = false
      guard isOn else {
        opened?.close()
        return
      }
      guard let opened else {
        status = usb.isEmpty && wifi.isEmpty
          ? "Looking for an iPad…"
          : "Open Video Prompter on the iPad"
        // A device is there but the app was not listening yet: try again shortly.
        if !usb.isEmpty || !wifi.isEmpty { scheduleRetry() }
        return
      }
      use(opened)
    }
  }

  private func use(_ pipe: LinkPipe) {
    self.pipe = pipe
    status = "Sending to iPad over \(pipe.name)"
    pipe.onClose = { [weak self, weak pipe] in
      Task { @MainActor in if let pipe { self?.lost(pipe) } }
    }
    let name = Host.current().localizedName ?? "Mac"
    pipe.send(CameraLink.Message.hello(name: name, version: CameraLink.protocolVersion).encoded())
    encoder.attach(pipe, bitRate: pipe.name == "USB-C" ? 10_000_000 : 4_000_000)
  }

  private func lost(_ old: LinkPipe) {
    guard pipe === old else { return }
    encoder.attach(nil)
    pipe = nil
    guard isOn else { return }
    status = "Looking for an iPad…"
    scheduleRetry()
  }

  private func scheduleRetry() {
    retry?.cancel()
    retry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.connectIfNeeded()
    }
  }
}

/// File › Send Camera to iPad, with what it is doing underneath.
struct IPadCameraCommands: Commands {
  @ObservedObject var sender: IPadCameraSender
  var body: some Commands {
    CommandGroup(after: .importExport) {
      Toggle("Send Camera to iPad", isOn: $sender.isOn)
        .help("Shows this Mac's camera behind the script in Video Prompter on an iPad connected by USB-C")
      Toggle("Also Send over Wi-Fi", isOn: $sender.usesWiFi)
        .help("Also looks for your iPad on the same Wi-Fi. The picture is not encrypted on Wi-Fi.")
      if sender.isOn { Text(sender.status) }
    }
  }
}

// MARK: - Encoding

/// Camera frames in, H.264 messages out. Works on its own queues; `@unchecked Sendable` because
/// the session's state belongs to `captureQueue`, and what VideoToolbox's callback thread shares
/// sits behind a mutex.
final class LinkEncoder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  let captureQueue = DispatchQueue(label: "VideoPrompter.ipadlink.capture", qos: .userInteractive)
  private struct Target {
    var pipe: LinkPipe?
    var bitRate = 10_000_000
    var generation = 0
  }
  private let target = Mutex(Target())
  private var session: VTCompressionSession?
  private var sessionSize: CMVideoDimensions?
  private var sessionGeneration = -1
  /// The parameter sets last sent, so they go again only when they change.
  private let lastSets = Mutex<[Data]>([])
  private var forceKeyFrame = false

  func attach(_ pipe: LinkPipe?, bitRate: Int = 10_000_000) {
    target.withLock {
      $0.pipe = pipe
      $0.bitRate = bitRate
      $0.generation += 1
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    let (pipe, bitRate, generation) = target.withLock { ($0.pipe, $0.bitRate, $0.generation) }
    guard let pipe, let image = sampleBuffer.imageBuffer else {
      if session != nil { tearDown() }
      return
    }
    // The cable or Wi-Fi is behind: skip this frame rather than queue it, and start the next
    // one clean so the iPad never shows a smeared picture.
    if pipe.pendingBytes > 3_000_000 {
      forceKeyFrame = true
      return
    }
    let size = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(image)), height: Int32(CVPixelBufferGetHeight(image)))
    if session == nil || generation != sessionGeneration || sessionSize.map({ $0.width != size.width || $0.height != size.height }) == true {
      tearDown()
      makeSession(size: size, bitRate: bitRate)
      sessionGeneration = generation
    }
    guard let session else { return }
    let options: CFDictionary? = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
    forceKeyFrame = false
    VTCompressionSessionEncodeFrame(
      session, imageBuffer: image, presentationTimeStamp: sampleBuffer.presentationTimeStamp,
      duration: .invalid, frameProperties: options, infoFlagsOut: nil
    ) { [weak self] status, _, encoded in
      guard status == noErr, let encoded, let self else { return }
      self.send(encoded, to: pipe)
    }
  }

  /// The output picture: the camera's own shape, no larger than 1920 on its long side.
  static func encodedSize(_ size: CMVideoDimensions) -> CMVideoDimensions {
    let long = max(size.width, size.height)
    guard long > 1920 else { return size }
    let scale = 1920 / Double(long)
    // H.264 wants even sizes.
    func even(_ value: Int32) -> Int32 { Int32((Double(value) * scale / 2).rounded()) * 2 }
    return CMVideoDimensions(width: even(size.width), height: even(size.height))
  }

  private func makeSession(size: CMVideoDimensions, bitRate: Int) {
    let out = Self.encodedSize(size)
    var made: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
    guard
      VTCompressionSessionCreate(
        allocator: nil, width: out.width, height: out.height, codecType: kCMVideoCodecType_H264,
        encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr,
      let made
    else { return }
    let properties: [CFString: Any] = [
      kVTCompressionPropertyKey_RealTime: true,
      kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
      kVTCompressionPropertyKey_AllowFrameReordering: false,
      kVTCompressionPropertyKey_AverageBitRate: bitRate,
      // A key frame every second, so a dropped frame or a fresh connection recovers quickly.
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
      kVTCompressionPropertyKey_ExpectedFrameRate: 30,
    ]
    for (key, value) in properties { VTSessionSetProperty(made, key: key, value: value as CFTypeRef) }
    VTCompressionSessionPrepareToEncodeFrames(made)
    session = made
    sessionSize = size
    lastSets.withLock { $0 = [] }
  }

  private func tearDown() {
    if let session { VTCompressionSessionInvalidate(session) }
    session = nil
    sessionSize = nil
  }

  /// Called by VideoToolbox on its own thread, in order.
  private func send(_ sample: CMSampleBuffer, to pipe: LinkPipe) {
    guard let format = sample.formatDescription, let data = try? sample.dataBuffer?.dataBytes() else { return }
    let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first
    let keyFrame = !(attachments?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    if keyFrame {
      let sets = Self.parameterSets(format)
      let changed = lastSets.withLock { last in
        defer { last = sets }
        return last != sets
      }
      if changed {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        pipe.send(CameraLink.Message.format(width: Int(size.width), height: Int(size.height), parameterSets: sets).encoded())
      }
    }
    let micros = UInt64(max(0, sample.presentationTimeStamp.seconds * 1_000_000))
    pipe.send(CameraLink.Message.frame(time: micros, keyFrame: keyFrame, data: data).encoded())
  }

  private static func parameterSets(_ format: CMFormatDescription) -> [Data] {
    var count = 0
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
      parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
    return (0..<count).compactMap { index in
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      guard
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
          parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
        let pointer
      else { return nil }
      return Data(bytes: pointer, count: size)
    }
  }
}

// MARK: - Transport

/// A one-way byte pipe to the iPad. `pendingBytes` lets the encoder drop frames instead of
/// building a backlog when the connection is slower than the camera.
class LinkPipe: @unchecked Sendable {
  let name: String
  private let pending = Atomic<Int>(0)
  private let closeHandler = Mutex<(@Sendable () -> Void)?>(nil)
  var pendingBytes: Int { pending.load(ordering: .relaxed) }
  var onClose: (@Sendable () -> Void)? {
    get { closeHandler.withLock { $0 } }
    set { closeHandler.withLock { $0 = newValue } }
  }

  init(name: String) { self.name = name }
  func send(_ data: Data) {}
  func close() {}

  func queued(_ count: Int) { pending.add(count, ordering: .relaxed) }
  func sent(_ count: Int) { pending.subtract(count, ordering: .relaxed) }
  func closed() { closeHandler.withLock { $0 }?() }
}

/// The usbmuxd tunnel: a plain socket written from one serial queue.
final class SocketPipe: LinkPipe, @unchecked Sendable {
  private let socket: Int32
  private let queue = DispatchQueue(label: "VideoPrompter.ipadlink.usb", qos: .userInteractive)
  private var isOpen = true

  init(socket: Int32, name: String) {
    self.socket = socket
    super.init(name: name)
  }

  override func send(_ data: Data) {
    queued(data.count)
    queue.async { [self] in
      defer { sent(data.count) }
      guard isOpen else { return }
      if !USBMux.writeAll(socket, data) { shut() }
    }
  }

  override func close() { queue.async { [self] in shut() } }

  private func shut() {
    guard isOpen else { return }
    isOpen = false
    Darwin.close(socket)
    closed()
  }
}

/// The Wi-Fi connection to an iPad found with Bonjour.
final class NetworkPipe: LinkPipe, @unchecked Sendable {
  private let connection: NWConnection

  private init(_ connection: NWConnection) {
    self.connection = connection
    super.init(name: "Wi-Fi")
  }

  static func open(_ endpoint: NWEndpoint) async -> NetworkPipe? {
    let parameters = NWParameters.tcp
    if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
    let connection = NWConnection(to: endpoint, using: parameters)
    let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let once = Once(continuation)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: once.finish(true)
        case .failed, .cancelled, .waiting: once.finish(false)
        default: break
        }
      }
      connection.start(queue: DispatchQueue(label: "VideoPrompter.ipadlink.wifi"))
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.finish(false) }
    }
    guard ready else {
      connection.cancel()
      return nil
    }
    let pipe = NetworkPipe(connection)
    connection.stateUpdateHandler = { [weak pipe] state in
      switch state {
      case .failed, .cancelled: pipe?.closed()
      default: break
      }
    }
    return pipe
  }

  /// Resumes the continuation with the first answer only: ready, failed or timed out.
  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
      let waiting = lock.withLock {
        defer { continuation = nil }
        return continuation
      }
      waiting?.resume(returning: value)
    }
  }

  override func send(_ data: Data) {
    queued(data.count)
    connection.send(content: data, completion: .contentProcessed { [weak self] error in
      self?.sent(data.count)
      if error != nil { self?.connection.cancel() }
    })
  }

  override func close() { connection.cancel() }
}

/// The client side of usbmuxd's plist protocol, as libimobiledevice and Peertalk speak it: a
/// 16-byte little-endian header (length, version 1, type 8 for a plist, tag), then an XML plist.
enum USBMux {
  static let socketPath = "/var/run/usbmuxd"

  static func openSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in path.prefix(buffer.count - 1).enumerated() { buffer[index] = UInt8(bitPattern: byte) }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    guard connected == 0 else {
      Darwin.close(fd)
      return nil
    }
    return fd
  }

  static func request(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    extra.merging([
      "MessageType": type, "ClientVersionString": "VideoPrompter", "ProgName": "VideoPrompter",
    ]) { a, _ in a }
  }

  static func write(_ message: [String: Any], to fd: Int32, tag: UInt32 = 1) -> Bool {
    guard let body = try? PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0) else {
      return false
    }
    var packet = Data()
    for field in [UInt32(16 + body.count), 1, 8, tag] {
      Swift.withUnsafeBytes(of: field.littleEndian) { packet.append(contentsOf: $0) }
    }
    packet.append(body)
    return writeAll(fd, packet)
  }

  static func read(from fd: Int32) -> [String: Any]? {
    guard let header = readExactly(fd, 16) else { return nil }
    let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    guard length >= 16, length < 1 << 20, let body = readExactly(fd, Int(length) - 16) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
  }

  static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += written
      }
      return true
    }
  }

  static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var data = Data(count: count)
    let ok = data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        let got = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
        if got < 0, errno == EINTR { continue }
        guard got > 0 else { return false }
        offset += got
      }
      return true
    }
    return ok ? data : nil
  }

  /// A socket tunnelled to `port` on the device, or nil when the device refuses (nothing is
  /// listening there) or usbmuxd is not reachable.
  static func connect(device: Int, port: UInt16) async -> Int32? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        guard let fd = openSocket() else { return continuation.resume(returning: nil) }
        let message = request("Connect", ["DeviceID": device, "PortNumber": Int(port.bigEndian)])
        guard write(message, to: fd), let reply = read(from: fd), reply["Number"] as? Int == 0 else {
          Darwin.close(fd)
          return continuation.resume(returning: nil)
        }
        continuation.resume(returning: fd)
      }
    }
  }
}

/// Keeps a usbmuxd "Listen" open and reports the devices attached over USB. Wi-Fi sync devices
/// are left out: the Wi-Fi path finds those through Bonjour instead.
final class USBMuxListener: @unchecked Sendable {
  private let onChange: @Sendable ([Int]) -> Void
  private let socket = Mutex<Int32?>(nil)

  init(onChange: @escaping @Sendable ([Int]) -> Void) { self.onChange = onChange }

  func start() {
    Thread.detachNewThread { [self] in
      guard let fd = USBMux.openSocket() else { return }
      socket.withLock { $0 = fd }
      guard USBMux.write(USBMux.request("Listen"), to: fd) else { return }
      var devices: [Int] = []
      while let message = USBMux.read(from: fd) {
        let id = message["DeviceID"] as? Int
        switch message["MessageType"] as? String {
        case "Attached":
          let properties = message["Properties"] as? [String: Any]
          if let id, properties?["ConnectionType"] as? String == "USB", !devices.contains(id) { devices.append(id) }
        case "Detached":
          devices.removeAll { $0 == id }
        default:
          continue
        }
        onChange(devices)
      }
    }
  }

  func stop() {
    // Closing the socket ends the read loop on its thread.
    if let fd = socket.withLock({ value -> Int32? in defer { value = nil }; return value }) {
      Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
    }
  }
}
#endif
