#if os(macOS)
@preconcurrency import AVFoundation
import AppKit
import Darwin
import Network
import PrompterCore
import SwiftUI
import Synchronization
import VideoToolbox

/// File › Send Camera to iPad and File › Control iPad. The camera this Mac shows goes to Video
/// Prompter on an iPad, which puts it behind the script, and the iPad's presenter can be driven
/// from here. Both share one connection, kept open while either is on. Over USB-C it travels through usbmuxd, the channel Finder and Xcode
/// use to talk to an iPad, so it needs no network and no pairing beyond "Trust This Computer".
/// An iPad that allows it is also found on the same Wi-Fi with Bonjour. USB-C wins when both are
/// there: it is faster and nothing else shares it.
///
/// The camera is the one the Camera window shows, from the same shared session, so a DeckLink
/// or ATEM feed is opened once. Frames are encoded to H.264 in hardware at up to 1080p.
@MainActor final class IPadCameraSender: ObservableObject {
  static let shared = IPadCameraSender()

  /// Sends the camera.
  @Published var isOn = false { didSet { if isOn != oldValue { isOn ? startCamera() : stopCamera() } } }
  /// Keeps the link open for the iPad Remote window and the CLI, camera or not.
  @Published var controlsIPad = false { didSet { if controlsIPad != oldValue { updateLink() } } }
  /// What the iPad's presenter shows, while an iPad that reports it is connected.
  @Published private(set) var iPadState: PadRemote.State?
  /// What the menu shows under the toggles.
  @Published private(set) var status = "Off"
  /// Off by default: USB-C needs no trust decision, while Wi-Fi is unencrypted and anything on
  /// the network can advertise itself as an iPad.
  @Published var usesWiFi = UserDefaults.standard.bool(forKey: "sendCameraOverWiFi") {
    didSet {
      UserDefaults.standard.set(usesWiFi, forKey: "sendCameraOverWiFi")
      if linkOn { usesWiFi ? startBrowsing() : stopBrowsing() }
    }
  }
  /// The pairing code for each iPad the user has paired over Wi-Fi, by its Bonjour name.
  private var codes = UserDefaults.standard.dictionary(forKey: "sendCameraPairingCodes") as? [String: String] ?? [:] {
    didSet { UserDefaults.standard.set(codes, forKey: "sendCameraPairingCodes") }
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
  /// Bumped by every start and stop, so a connection begun under one run never attaches to the
  /// next or survives the switch being turned off.
  private var generation = 0
  private var retry: Task<Void, Never>?
  private var linkOn = false
  /// CLI and MCP calls under way, each keeping the link open while it runs.
  private var calls = 0
  /// An iPad from before version 2 answered without its state: it cannot be controlled, and a
  /// link without a picture would leave it on a black Mac camera, so none is kept open.
  private var oldIPad = false

  /// Drives the iPad's presenter. Nothing happens unless an iPad is connected.
  func send(_ command: PadRemote.Command) {
    pipe?.send(CameraLink.Message.command(command).encoded())
  }

  /// Keeps the link open for `body`, as the window does while it is open.
  func whileLinked<T>(_ body: () async -> T) async -> T {
    calls += 1
    updateLink()
    defer {
      calls -= 1
      updateLink()
    }
    return await body()
  }

  /// The iPad answered but is too old to be controlled.
  var iPadIsOld: Bool { oldIPad }

  private func updateLink() {
    let wanted = isOn || controlsIPad || calls > 0
    guard wanted != linkOn else { return }
    linkOn = wanted
    wanted ? startLink() : stopLink()
  }

  private func startCamera() {
    oldIPad = false
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
    if let pipe { attachCamera(pipe) }
    updateLink()
    // The link may already be up but idle, after an older iPad was let go.
    connectIfNeeded()
  }

  private func stopCamera() {
    if let pipe {
      if iPadState != nil {
        // Still connected for the remote: the iPad goes back to its own camera once the last
        // frame in flight has gone.
        encoder.finish(pipe)
      } else {
        encoder.attach(nil)
        pipe.send(CameraLink.Message.goodbye.encoded())
        pipe.close()
      }
    } else {
      encoder.attach(nil)
    }
    let output = self.output
    let shared = SharedCameraSession.shared
    shared.reconfigure { session in
      session.beginConfiguration()
      session.removeOutput(output)
      session.commitConfiguration()
    }
    shared.release()
    if let pipe { status = Self.connected(over: pipe.name, sending: false) }
    updateLink()
  }

  private func startLink() {
    generation += 1
    oldIPad = false
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

  private func stopLink() {
    generation += 1
    retry?.cancel()
    mux?.stop()
    mux = nil
    stopBrowsing()
    usbDevices = []
    declinedNames = []
    pipe?.send(CameraLink.Message.goodbye.encoded())
    pipe?.close()
    pipe = nil
    iPadState = nil
    status = "Off"
  }

  private func usbChanged(_ devices: [Int]) {
    // A plugged or swapped iPad may be an updated one.
    if devices != usbDevices { oldIPad = false }
    usbDevices = devices
    connectIfNeeded()
  }

  /// Only paired iPads are sent to. A new one is paired once, with the code its Settings show.
  private func wifiChanged(_ endpoints: [NWEndpoint]) {
    // A headless launch, for the CLI, never stops to ask.
    for name in endpoints.compactMap(Self.serviceName) where codes[name] == nil && !declinedNames.contains(name) && !Headless.shared.active {
      if let code = Self.askForCode(name) { codes[name] = code } else { declinedNames.insert(name) }
    }
    wifiTargets = endpoints.filter { Self.serviceName($0).map { codes[$0] != nil } ?? false }
    connectIfNeeded()
  }

  private static func askForCode(_ name: String) -> String? {
    let alert = NSAlert()
    alert.messageText = "Pair with “\(name)” over Wi-Fi"
    alert.informativeText = "Type the pairing key shown on the iPad in Settings › Camera from a Mac. Only pair with your own iPad; the picture is encrypted with this key."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.placeholderString = "XXXX-XXXX-XXXX-XXXX"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.addButton(withTitle: "Pair")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return CameraLinkSecurity.normalised(field.stringValue)
  }

  private static func serviceName(_ endpoint: NWEndpoint) -> String? {
    if case .service(let name, _, _, _) = endpoint { return name }
    return nil
  }

  /// Tries each USB-C device, then each iPad on Wi-Fi, until one answers. An iPhone, or an iPad
  /// without Video Prompter open, refuses the port and the next is tried.
  private func connectIfNeeded() {
    guard linkOn, pipe == nil, !connecting, isOn || !oldIPad else { return }
    connecting = true
    let usb = usbDevices
    let wifi = wifiTargets
    let run = generation
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
          guard let name = Self.serviceName(endpoint), let code = codes[name] else { continue }
          switch await NetworkPipe.open(endpoint, code: code) {
          case .opened(let pipe):
            opened = pipe
          case .refused:
            // The iPad has a different code now: pair again next time it is seen.
            codes[name] = nil
          case .unreachable:
            break
          }
          if opened != nil { break }
        }
      }
      connecting = false
      // Turned off, restarted, or Wi-Fi switched off while this was connecting: drop it.
      guard linkOn, run == generation, opened?.name != "Wi-Fi" || usesWiFi else {
        opened?.close()
        if linkOn { connectIfNeeded() }
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
    status = Self.connected(over: pipe.name, sending: isOn)
    pipe.onClose = { [weak self, weak pipe] in
      Task { @MainActor in if let pipe { self?.lost(pipe) } }
    }
    pipe.onMessage = { [weak self, weak pipe] message in
      guard case .state(var state) = message else { return }
      // Whatever the iPad says, the window's slider and the CLI get sane numbers.
      state.words = min(max(state.words, 0), 10_000_000)
      state.word = min(max(state.word, 0), state.words)
      Task { @MainActor in if let self, let pipe, self.pipe === pipe { self.iPadState = state } }
    }
    pipe.startReading()
    let name = Host.current().localizedName ?? "Mac"
    pipe.send(CameraLink.Message.hello(name: name, version: CameraLink.protocolVersion).encoded())
    if isOn { attachCamera(pipe) }
    // A current iPad answers the hello at once.
    Task { [weak self, weak pipe] in
      try? await Task.sleep(for: .seconds(3))
      guard let self, let pipe, self.pipe === pipe, iPadState == nil, !isOn else { return }
      oldIPad = true
      pipe.send(CameraLink.Message.goodbye.encoded())
      pipe.close()
    }
  }

  private func attachCamera(_ pipe: LinkPipe) {
    encoder.attach(pipe, bitRate: pipe.name == "USB-C" ? 10_000_000 : 4_000_000)
    status = Self.connected(over: pipe.name, sending: true)
  }

  private static func connected(over transport: String, sending: Bool) -> String {
    sending ? "Sending to iPad over \(transport)" : "Connected to iPad over \(transport)"
  }

  /// How the iPad is connected, while it is.
  var transport: String? { pipe?.name }

  private func lost(_ old: LinkPipe) {
    guard pipe === old else { return }
    encoder.attach(nil)
    pipe = nil
    iPadState = nil
    guard linkOn else { return }
    if oldIPad, !isOn {
      status = "Update Video Prompter on the iPad, then open Control iPad again"
      return
    }
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

/// File › Send Camera to iPad and Control iPad, with what the link is doing underneath.
struct IPadCameraCommands: Commands {
  @ObservedObject var sender: IPadCameraSender
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    CommandGroup(after: .importExport) {
      Toggle("Send Camera to iPad", isOn: $sender.isOn)
        .help("Shows this Mac's camera behind the script in Video Prompter on an iPad connected by USB-C")
      Button("Control iPad…") { openWindow(id: "ipad-remote") }
        .help("Chooses the script on the iPad, starts and pauses it, and sets its mode, speed and place")
      Toggle("Also Connect over Wi-Fi", isOn: $sender.usesWiFi)
        .help("Also looks for your iPad on the same Wi-Fi, paired with the key its Settings show. The link is encrypted with that key.")
      if sender.isOn || sender.controlsIPad { Text(sender.status) }
    }
  }
}

/// File › Control iPad opens this: the iPad presenter's controls, showing what the iPad reports.
struct IPadRemoteView: View {
  @ObservedObject var link: IPadCameraSender
  /// The slider's value while it is dragged; the iPad moves when it is let go.
  @State private var dragging: Double?

  var body: some View {
    Form {
      Toggle("Control iPad", isOn: $link.controlsIPad)
      Text(link.iPadState == nil && link.controlsIPad ? "\(link.status). Open Video Prompter on the iPad, connected by USB-C." : link.status)
        .foregroundStyle(.secondary)
      if let state = link.iPadState { controls(state) }
    }
    .formStyle(.grouped)
    .frame(minWidth: 380)
    .onAppear { link.controlsIPad = true }
    .onDisappear { link.controlsIPad = false }
  }

  @ViewBuilder private func controls(_ state: PadRemote.State) -> some View {
    Picker("Script", selection: Binding(get: { state.presenting }, set: { link.send($0.map(PadRemote.Command.present) ?? .close) })) {
      Text("None (presenter closed)").tag(UUID?.none)
      ForEach(state.scripts, id: \.id) { Text($0.title).tag(Optional($0.id)) }
    }
    Picker("Follow", selection: Binding(get: { state.mode }, set: { link.send(.mode($0)) })) {
      Text("Voice").tag("Voice")
      Text("Manual").tag("Manual")
    }
    .pickerStyle(.segmented)
    Stepper("Speed \(state.speed) words a minute", value: Binding(get: { state.speed }, set: { link.send(.speed($0)) }), in: 20...300, step: 10)
    HStack {
      Button("Back to Start", systemImage: "backward.end.fill") { link.send(.backToStart) }
      Button("Previous Passage", systemImage: "chevron.up") { link.send(.previousPassage) }
      Button(state.running ? "Pause" : "Start", systemImage: state.running ? "pause.fill" : "play.fill") {
        link.send(state.running ? .pause : .play)
      }
      Button("Next Passage", systemImage: "chevron.down") { link.send(.nextPassage) }
    }
    .labelStyle(.iconOnly)
    .disabled(state.presenting == nil)
    LabeledContent("Word \(state.word) of \(state.words)") {
      Slider(value: Binding(get: { dragging ?? Double(state.word) }, set: { dragging = $0 }),
             in: 1...Double(max(state.words, 2))) { editing in
        guard !editing, let value = dragging else { return }
        link.send(.seek(word: Int(value.rounded())))
        dragging = nil
      }
    }
    .disabled(state.presenting == nil || state.words < 2)
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

  /// Stops sending to `pipe`, and once the frames in flight have gone, tells the iPad the
  /// picture has ended. On the capture queue, after any frame being encoded.
  func finish(_ pipe: LinkPipe) {
    attach(nil)
    captureQueue.async { [self] in
      tearDown()
      pipe.send(CameraLink.Message.format(width: 0, height: 0, parameterSets: []).encoded())
    }
  }

  private func tearDown() {
    if let session {
      // Delivers every frame still in the encoder first, so none follows the end of the picture.
      VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(session)
    }
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
  private let messageHandler = Mutex<(@Sendable (CameraLink.Message) -> Void)?>(nil)
  private let reader = Mutex(CameraLink.Reader())
  var pendingBytes: Int { pending.load(ordering: .relaxed) }
  var onClose: (@Sendable () -> Void)? {
    get { closeHandler.withLock { $0 } }
    set { closeHandler.withLock { $0 = newValue } }
  }
  /// What the iPad sends back, from `startReading` on.
  var onMessage: (@Sendable (CameraLink.Message) -> Void)? {
    get { messageHandler.withLock { $0 } }
    set { messageHandler.withLock { $0 = newValue } }
  }

  init(name: String) { self.name = name }
  func send(_ data: Data) {}
  func close() {}
  func startReading() {}

  /// Hands whole messages to `onMessage`; false when the bytes make no sense and the pipe
  /// should close.
  func received(_ bytes: Data) -> Bool {
    guard let messages = try? reader.withLock({ try $0.append(bytes) }) else { return false }
    let handler = onMessage
    for message in messages { handler?(message) }
    return true
  }

  func queued(_ count: Int) { pending.add(count, ordering: .relaxed) }
  func sent(_ count: Int) { pending.subtract(count, ordering: .relaxed) }
  func closed() { closeHandler.withLock { $0 }?() }
}

/// The usbmuxd tunnel: a plain socket written from one serial queue and read on its own thread.
final class SocketPipe: LinkPipe, @unchecked Sendable {
  private let socket: Int32
  private let queue = DispatchQueue(label: "VideoPrompter.ipadlink.usb", qos: .userInteractive)
  /// The writing queue holds the socket, and so does the reading thread once it starts. The last
  /// to let go closes it, so neither ever touches a descriptor already closed and reused.
  private let state = Mutex((open: true, holders: 1))

  init(socket: Int32, name: String) {
    self.socket = socket
    super.init(name: name)
  }

  override func send(_ data: Data) {
    queued(data.count)
    queue.async { [self] in
      defer { sent(data.count) }
      guard state.withLock({ $0.open }) else { return }
      if !USBMux.writeAll(socket, data) { shut() }
    }
  }

  override func close() {
    // Unblocks a write stuck on an iPad that stopped reading, and the reading thread; the queue
    // then lets go of the socket.
    state.withLock { if $0.open { Darwin.shutdown(socket, SHUT_RDWR) } }
    queue.async { [self] in shut() }
  }

  override func startReading() {
    guard state.withLock({ state in
      guard state.open else { return false }
      state.holders += 1
      return true
    }) else { return }
    Thread.detachNewThread { [self] in
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while true {
        let count = Darwin.read(socket, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0, received(Data(buffer[0..<count])) else { break }
      }
      close()
      release()
    }
  }

  private func shut() {
    guard state.withLock({ state in
      defer { state.open = false }
      if state.open { Darwin.shutdown(socket, SHUT_RDWR) }
      return state.open
    }) else { return }
    release()
    closed()
  }

  private func release() {
    state.withLock { state in
      state.holders -= 1
      if state.holders == 0 { Darwin.close(socket) }
    }
  }
}

/// The Wi-Fi connection to an iPad found with Bonjour.
final class NetworkPipe: LinkPipe, @unchecked Sendable {
  private let connection: NWConnection

  private init(_ connection: NWConnection) {
    self.connection = connection
    super.init(name: "Wi-Fi")
  }

  enum Outcome {
    case opened(NetworkPipe)
    /// The TLS handshake failed: the codes do not match.
    case refused
    case unreachable
  }

  static func open(_ endpoint: NWEndpoint, code: String) async -> Outcome {
    let connection = NWConnection(to: endpoint, using: CameraLinkSecurity.parameters(code: code))
    let state = await withCheckedContinuation { (continuation: CheckedContinuation<State, Never>) in
      let once = Once(continuation)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: once.finish(.ready)
        case .failed(.tls), .waiting(.tls): once.finish(.refused)
        case .failed, .cancelled, .waiting: once.finish(.unreachable)
        default: break
        }
      }
      connection.start(queue: DispatchQueue(label: "VideoPrompter.ipadlink.wifi"))
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.finish(.unreachable) }
    }
    guard state == .ready else {
      connection.cancel()
      return state == .refused ? .refused : .unreachable
    }
    let pipe = NetworkPipe(connection)
    connection.stateUpdateHandler = { [weak pipe] state in
      switch state {
      case .failed, .cancelled: pipe?.closed()
      default: break
      }
    }
    return .opened(pipe)
  }

  private enum State { case ready, refused, unreachable }

  /// Resumes the continuation with the first answer only: ready, failed or timed out.
  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<State, Never>?
    init(_ continuation: CheckedContinuation<State, Never>) { self.continuation = continuation }
    func finish(_ value: State) {
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

  override func startReading() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty, !self.received(data) { return self.connection.cancel() }
      if isComplete || error != nil { self.connection.cancel() } else { self.startReading() }
    }
  }
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
  private let socket = Mutex<(fd: Int32?, stopped: Bool)>((nil, false))

  init(onChange: @escaping @Sendable ([Int]) -> Void) { self.onChange = onChange }

  func start() {
    Thread.detachNewThread { [self] in
      guard let fd = USBMux.openSocket() else { return }
      // Only this thread closes the socket, after unpublishing it, so `stop` never shuts a
      // reused descriptor. A `stop` that came first leaves nothing listening.
      defer { Darwin.close(fd) }
      guard socket.withLock({ state in
        guard !state.stopped else { return false }
        state.fd = fd
        return true
      }) else { return }
      defer { socket.withLock { $0.fd = nil } }
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
    // Shutting the socket ends the read loop, and its thread closes it.
    socket.withLock { state in
      state.stopped = true
      if let fd = state.fd { Darwin.shutdown(fd, SHUT_RDWR) }
    }
  }
}
#endif
