#if os(macOS)
@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import CryptoKit
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
/// The camera is the one the Second monitor window shows, from the same shared session, so a DeckLink
/// or ATEM feed is opened once. Frames are encoded to H.264 in hardware at up to 1080p.
@MainActor final class IPadCameraSender: ObservableObject, PadRelayLink {
  static let shared = IPadCameraSender()

  /// UI API mirrors PadStore: Bool mirror/flip/editing/cleanScreen/micOn, pictureMode/priority
  /// enums, source lists and selection, recordingState, micMeter.levelDB. Observe micMeter
  /// directly so level updates redraw only the meter. Use the set/select methods
  /// to send intent; iPad-owned values change when its State acknowledges them.
  var mirror: Bool { iPadState?.look?.horizontalMirror ?? false }
  var flip: Bool { iPadState?.look?.verticalMirror ?? false }
  var editing: Bool { iPadState?.editing ?? false }
  var cleanScreen: Bool { iPadState?.cleanScreen ?? false }
  var pictureMode: PadRemote.PictureMode { iPadState?.pictureMode ?? .off }
  var picturePriority: PadRemote.PicturePriority { iPadState?.picturePriority ?? .realTime720p }
  @Published private(set) var macMicOn = true
  var micOn: Bool { iPadState?.micOn ?? macMicOn }
  @Published private(set) var macStatus = PadRemote.MacStatus()
  var cameraSources: [PadRemote.Source] { macStatus.cameras ?? [] }
  var selectedCamera: String? { macStatus.selectedCamera }
  var cameraOn: Bool { isOn }
  var microphoneSources: [PadRemote.Source] {
    iPadState?.voiceSource == "iPad" ? (iPadState?.microphoneSources ?? []) : (macStatus.microphones ?? [])
  }
  var selectedMicrophone: String? {
    iPadState?.voiceSource == "iPad" ? iPadState?.selectedMicrophone : macStatus.selectedMicrophone
  }
  var recordingState: PadRemote.RecordingState { macStatus.recording ?? .unknown }
  let micMeter = RemoteMicMeter()
  func setVoiceSource(_ value: String) { send(.voiceSource(value)) }
  func setMirror(_ value: Bool) { send(.look(.init(horizontalMirror: value))) }
  func setFlip(_ value: Bool) { send(.look(.init(verticalMirror: value))) }
  func beginEditing() { send(.editing(true)) }
  func endEditing() { send(.editing(false)) }
  func setPictureMode(_ value: PadRemote.PictureMode) { send(.pictureMode(value)) }
  func setPicturePriority(_ value: PadRemote.PicturePriority) { send(.picturePriority(value)) }
  func setCleanScreen(_ value: Bool) { send(.cleanScreen(value)) }
  func setCameraOn(_ value: Bool) { cameraOwnedByIPad = false; isOn = value; publishMacStatus() }
  private var cameraOwnedByIPad = false
  private var receivingCameraRequest = false
  func selectCamera(_ id: String) {
    let camera = CameraModel.shared
    camera.refreshDevices()
    guard camera.devices.contains(where: { $0.uid == id }), !camera.recordingLocked else { return }
    camera.selectedUID = id
    if cameraOwnedByIPad && !isOn {
      receivingCameraRequest = true
      isOn = true
      receivingCameraRequest = false
    }
    if isOn { SharedCameraSession.shared.select(id) }
    publishMacStatus()
  }
  func selectMicrophone(_ id: String) {
    if iPadState?.voiceSource == "iPad" { send(.selectMicrophone(id)); return }
    selectMacMicrophone(id)
  }
  private func selectMacMicrophone(_ id: String) {
    guard AudioCapture.inputDevices().contains(where: { $0.uid == id }) else { return }
    AppStore.shared.settings.audioDeviceUID = id
    if let session = relay.session {
      var settings = session.settings
      settings.audioDeviceUID = id
      session.updateSettings(settings)
    }
    publishMacStatus()
  }
  func setMicOn(_ value: Bool) {
    send(.micOn(value))
    if iPadState?.voiceSource != "iPad" {
      macMicOn = value
      value ? relay.resumeForMic() : relay.pauseForMic()
    }
    publishMacStatus()
  }

  private var statusTimer: AnyCancellable?
  private var statusTicks = 0
  private var lastResponse = Date()
  private var meterCapture: AudioCapture?
  private let setupMeter = InputMeter()
  private var macName = "Mac"
  private var microphones: [PadRemote.Source] = []
  private weak var sampledMeter: InputMeter?
  private var meterSubscription: AnyCancellable?
  private var pendingPeak: Double = -60

  /// Retain every observed peak until the 15 Hz status tick consumes it.
  func sampleMicLevel(_ meter: InputMeter) {
    if sampledMeter !== meter {
      sampledMeter = meter
      pendingPeak = -60
      meterSubscription = meter.$peakDBFS.sink { [weak self] level in
        guard let self, level.isFinite else { return }
        pendingPeak = max(pendingPeak, Double(level))
      }
    }
    let current = meter.isFresh() ? Double(meter.peakDBFS) : -60
    micMeter.show(macMicOn && meter.isFresh() ? max(pendingPeak, current) : -60)
    pendingPeak = -60
  }

  private func refreshSources() {
    CameraModel.shared.refreshDevices()
    microphones = AudioCapture.inputDevices().map { .init(id: $0.uid, name: $0.name) }
  }
  private func publishMacStatus() {
    guard pipe != nil else { return }
    let camera = CameraModel.shared
    let recorder = CameraRecorder.shared
    let session = AppStore.shared.session
    let activeMeter = relay.meter ?? (recorder.isCapturing ? recorder.inputMeter :
      (session.isActivelyRunning && session.settings.mode == "Voice" && !session.followsRemote ? session.meter : nil))
    updateSetupMeter(needed: iPadState?.cameraOnly == true && macMicOn && activeMeter == nil)
    let meter = activeMeter ?? (meterCapture != nil ? setupMeter : AppStore.shared.session.meter)
    sampleMicLevel(meter)
    let next = PadRemote.MacStatus(
      cameras: camera.devices.map { .init(id: $0.uid, name: $0.name) },
      selectedCamera: camera.selectedUID, cameraOn: isOn,
      microphones: microphones,
      selectedMicrophone: relay.session?.settings.audioDeviceUID ?? AppStore.shared.settings.audioDeviceUID,
      micOn: macMicOn, recording: recorder.isRecording ? .recording : .standby,
      displayName: macName, connectionKind: pipe?.name, framesSkipped: encoder.framesSkipped)
    if next != macStatus { macStatus = next }
    var update = next
    update.micLevelDB = micMeter.levelDB
    pipe?.send(CameraLink.Message.command(.macStatus(update)).encoded())
  }
  private func updateSetupMeter(needed: Bool) {
    let device = AudioCapture.resolvedInput(AppStore.shared.settings.audioDeviceUID)
    if !needed || meterCapture?.selectedDevice.uid != device?.uid {
      meterCapture?.stop()
      meterCapture = nil
      setupMeter.reset()
    }
    guard needed, meterCapture == nil, !CaptureAccess.isAgentOrTest, CaptureAccess.mayUse(.audio), let device,
      let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else { return }
    let capture = AudioCapture(device: device, outputFormat: format,
      channel: AudioChannel.load(device.uid, defaults: AppStore.preferences()))
    let delivery = AudioMeterDelivery { [weak self] in self?.setupMeter.show(channelPeaks: $0) }
    do {
      try capture.start(onBuffer: { _, _, _, peak, _ in
        delivery.receive(peaks: [peak], callback: ProcessInfo.processInfo.systemUptime)
      }, onStop: { [weak self, weak capture] _ in
        Task { @MainActor in
          if self?.meterCapture === capture { self?.meterCapture = nil }
        }
      })
      meterCapture = capture
    } catch { setupMeter.reset() }
  }

  private func receive(_ command: PadRemote.Command) {
    switch command {
    case .selectCamera(let id): selectCamera(id)
    case .cameraOn(let value):
      if !value || !isOn { cameraOwnedByIPad = value }
      receivingCameraRequest = true
      isOn = value
      receivingCameraRequest = false
      publishMacStatus()
    case .selectMicrophone(let id): selectMacMicrophone(id)
    case .micOn(let value):
      macMicOn = value
      value ? relay.resumeForMic() : relay.pauseForMic()
      publishMacStatus()
    default: break
    }
  }

  /// Sends the camera.
  @Published var isOn = false {
    didSet {
      if !receivingCameraRequest { cameraOwnedByIPad = false }
      if isOn != oldValue { isOn ? startCamera() : stopCamera() }
    }
  }
  /// Keeps the link open for the iPad Remote window and the CLI, camera or not.
  @Published var controlsIPad = false {
    didSet {
      guard controlsIPad != oldValue else { return }
      // Closing the Control iPad window ends the relay even if the camera keeps the link open.
      if !controlsIPad { relay.stop() }
      updateLink()
    }
  }
  /// What the iPad's presenter shows, while an iPad that reports it is connected.
  @Published private(set) var iPadState: PadRemote.State? {
    didSet {
      relay.iPadStateChanged(iPadState)
      if oldValue?.picturePriority != iPadState?.picturePriority, isOn, let pipe { attachCamera(pipe) }
    }
  }
  /// The Mac's microphone driving the iPad's reading, fed by every state the iPad sends.
  lazy var relay = PadVoiceRelay(link: self)
  private var relayActive = false
  /// What the menu shows under the toggles.
  @Published private(set) var status = "Off"
  /// Off by default: Wi-Fi requires the key shown on the iPad; USB-C uses the trusted cable.
  @Published var usesWiFi: Bool {
    didSet {
      defaults.set(usesWiFi, forKey: "sendCameraOverWiFi")
      if linkOn { usesWiFi ? startBrowsing() : stopBrowsing() }
    }
  }
  struct WiFiDevice: Identifiable, Equatable {
    let id: String
    let name: String
  }
  @Published private(set) var wifiDevices: [WiFiDevice] = []
  @Published var selectedWiFiID: String? {
    didSet {
      guard selectedWiFiID != oldValue else { return }
      generation += 1
      oldIPad = false
      if let old = pipe, old.name == "Wi-Fi" {
        old.send(CameraLink.Message.goodbye.encoded())
        old.close()
        lost(old)
      }
      updatePairingTarget()
      connectIfNeeded()
    }
  }
  private var unpairedDeviceID: String?
  @Published private(set) var unpairedDeviceName: String?
  @Published private(set) var pairingFailure: String?
  @Published private(set) var previewImage: CGImage?

  @Published private(set) var pairingOffer: PairingOffer?
  @Published private(set) var pairingRequestName: String?
  @Published private(set) var pairingRequestCode: String?
  private var pairingListener: NWListener?
  private var pairingRedemption = PairingRedemption()
  private var requestConnection: NWConnection?
  private var pairingMacID: UUID {
    if let value = defaults.string(forKey: "pairingMacID"), let id = UUID(uuidString: value) { return id }
    let id = UUID(); defaults.set(id.uuidString, forKey: "pairingMacID"); return id
  }

  func refreshPairingOffer() {
    pairingListener?.cancel()
    let offer = PairingOffer(macID: pairingMacID, name: Host.current().localizedName ?? "Mac", service: pairingMacID.uuidString)
    pairingOffer = offer
    guard (!CaptureAccess.isAgentOrTest || ProcessInfo.processInfo.environment["VP_IPAD_E2E"] == "1"),
      let listener = try? NWListener(using: CameraLinkSecurity.parameters(code: offer.secret)) else { return }
    listener.service = .init(name: offer.service, type: PairingExchange.macService)
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        guard let self else { connection.cancel(); return }
        connection.start(queue: .main); PairingExchange.expire(connection)
        defer { connection.cancel() }
        do {
          let request = try JSONDecoder().decode(PairingExchange.Request.self, from: await PairingExchange.receive(on: connection))
          guard let received = request.offer, let code = request.code, code.hasPrefix("QR:"), code.count == 75,
            UUID(uuidString: request.id) != nil, let current = self.pairingOffer else { throw PairingOffer.Failure.foreign }
          try self.pairingRedemption.redeem(received, expected: current)
          try await PairingExchange.send(JSONEncoder().encode(PairingExchange.Reply(id: offer.macID.uuidString, name: offer.name, code: "accepted")), on: connection)
          self.acceptedPairing(id: request.id, code: code)
          self.usesWiFi = true
          self.selectedWiFiID = request.id
          self.refreshPairingOffer()
        } catch { self.pairingFailure = "That code has expired or could not be verified. Choose New code and scan again." }
      }
    }
    listener.start(queue: .main)
    pairingListener = listener
  }

  func stopPairingOffer() {
    pairingListener?.cancel(); pairingListener = nil; pairingOffer = nil
    cancelPairingRequest()
  }

  func cancelPairingRequest() {
    requestConnection?.cancel(); requestConnection = nil; pairingRequestName = nil; pairingRequestCode = nil
  }

  func requestPairing(_ device: WiFiDevice) {
    cancelPairingRequest()
    selectedWiFiID = device.id
    usesWiFi = true
    let endpoint = NWEndpoint.service(name: device.id, type: PairingExchange.padService, domain: "local.", interface: nil)
    let connection = PairingExchange.connect(endpoint)
    requestConnection = connection; pairingRequestName = device.name; pairingFailure = nil
    Task {
      defer { if requestConnection === connection { cancelPairingRequest() } }
      do {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let request = PairingExchange.Request(id: pairingMacID.uuidString, name: Host.current().localizedName ?? "Mac", publicKeyCommitment: PairingExchange.commitment(key.publicKey.rawRepresentation))
        try await PairingExchange.send(JSONEncoder().encode(request), on: connection)
        let commitment = try await PairingExchange.receive(on: connection)
        guard commitment.count == 32 else { throw PairingOffer.Failure.foreign }
        try await PairingExchange.send(key.publicKey.rawRepresentation, on: connection)
        let publicKey = try await PairingExchange.receive(on: connection)
        guard PairingExchange.commitment(publicKey) == commitment, requestConnection === connection else { throw PairingOffer.Failure.foreign }
        let shared = try PairingExchange.key(key, peer: publicKey)
        pairingRequestCode = PairingExchange.confirmationCode(shared)
        let data = try await PairingExchange.receive(on: connection)
        guard requestConnection === connection else { return }
        let reply = try PairingExchange.open(data, key: shared)
        guard reply.id == device.id, reply.code.hasPrefix("QR:") else { throw PairingOffer.Failure.foreign }
        acceptedPairing(id: device.id, code: reply.code)
        selectedWiFiID = device.id
        connectIfNeeded()
      } catch { if requestConnection === connection { pairingFailure = "Could not connect. Check the iPad and try again, or type its key." } }
    }
  }

  func disconnect() {
    automaticallyLinks = false
    controlsIPad = false
    isOn = false
    linkOn = false
    stopLink()
  }

  func pair(key: String) {
    guard let id = unpairedDeviceID else { return }
    guard let code = CameraLinkSecurity.normalised(key) else {
      pairingFailure = "Enter the full pairing key shown on the iPad."
      return
    }
    codes[id] = code
    pairingFailure = nil
    selectedWiFiID = id
    connectIfNeeded()
  }

  /// The pairing code for each iPad the user has paired over Wi-Fi, by its install ID (legacy peers use their Bonjour name).
  private var refusedLegacyIDs: Set<String> = []
  private var codes: [String: String] {
    didSet { defaults.set(codes, forKey: "sendCameraPairingCodes") }
  }
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    usesWiFi = defaults.bool(forKey: "sendCameraOverWiFi")
    codes = defaults.dictionary(forKey: "sendCameraPairingCodes") as? [String: String] ?? [:]
    encoder.onPreview = { [weak self] image in
      Task { @MainActor in if self?.isOn == true { self?.previewImage = image } }
    }
  }

  private let output = AVCaptureVideoDataOutput()
  private let encoder = LinkEncoder()
  private var mux: USBMuxListener?
  private var browser: NWBrowser?
  private var wifiTargets: [NWEndpoint] = []
  private var usbDevices: [Int] = []
  /// The open connection; settable so tests can stand one in.
  var pipe: LinkPipe?
  private var connecting = false
  /// Bumped by every start and stop, so a connection begun under one run never attaches to the
  /// next or survives the switch being turned off.
  private var generation = 0
  private var retry: Task<Void, Never>?
  private var linkOn = false
  private var automaticallyLinks = false

  /// Discovery is independent of camera capture and the Remote window.
  func startDiscovering() {
    guard !CaptureAccess.isAgentOrTest else { return }
    automaticallyLinks = true
    updateLink()
  }
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

  /// While the voice relay runs, only a little video may queue, so its word messages are never far behind.
  func setRelayActive(_ active: Bool) {
    relayActive = active
    pipe?.videoLimit.store(active ? 256_000 : 3_000_000, ordering: .relaxed)
  }

  /// The iPad answered but is too old to be controlled.
  var iPadIsOld: Bool { oldIPad }

  /// Tests turn this off so that switching the remote on never looks for an iPad.
  var searchesForIPad = true

  private func updateLink() {
    let wanted = searchesForIPad && (automaticallyLinks || isOn || controlsIPad || calls > 0)
    guard wanted != linkOn else { return }
    linkOn = wanted
    wanted ? startLink() : stopLink()
  }

  /// Tests exercise the session with generated frames, never capture hardware.
  var capturesCamera = true
  private var cameraRetained = false

  private func startCamera() {
    if !capturesCamera {
      if let pipe { attachCamera(pipe) }
      updateLink()
      return
    }
    oldIPad = false
    let camera = CameraModel.shared
    camera.refresh()
    camera.start()
    guard let uid = camera.selectedUID else {
      status = "Choose a camera in the Second monitor window first"
      isOn = false
      return
    }
    let shared = SharedCameraSession.shared
    shared.select(uid)
    shared.retain()
    cameraRetained = true
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
    previewImage = nil
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
    guard cameraRetained else { updateLink(); return }
    cameraRetained = false
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
    browser.stateUpdateHandler = { [weak self, weak browser] state in
      guard case .failed = state else { return }
      Task { @MainActor in
        guard let self, self.browser === browser else { return }
        self.browser?.cancel()
        self.browser = nil
        try? await Task.sleep(for: .seconds(2))
        if self.linkOn && self.usesWiFi { self.startBrowsing() }
      }
    }
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
    wifiDevices = []
    unpairedDeviceID = nil
    unpairedDeviceName = nil
    pairingFailure = nil
    if pipe?.name == "Wi-Fi" { pipe?.close() }
  }

  private func stopLink() {
    generation += 1
    retry?.cancel()
    mux?.stop()
    mux = nil
    stopBrowsing()
    usbDevices = []
    pipe?.send(CameraLink.Message.goodbye.encoded())
    pipe?.close()
    pipe = nil
    if cameraOwnedByIPad { cameraOwnedByIPad = false; isOn = false }
    meterCapture?.stop()
    meterCapture = nil
    statusTimer = nil
    meterSubscription = nil
    sampledMeter = nil
    pendingPeak = -60
    micMeter.show(-60)
    macMicOn = true
    macStatus = PadRemote.MacStatus()
    iPadState = nil
    previewImage = nil
    status = "Off"
  }

  private func usbChanged(_ devices: [Int]) {
    // A plugged or swapped iPad may be an updated one.
    if devices != usbDevices { oldIPad = false }
    usbDevices = devices
    if !devices.isEmpty, let old = pipe, old.name == "Wi-Fi" { old.close(); lost(old) }
    connectIfNeeded()
  }

  /// Only paired iPads are sent to. A new one is paired once, with the code its Settings show.
  func wifiChanged(_ endpoints: [NWEndpoint]) {
    wifiTargets = endpoints
    let discovered = endpoints.compactMap(Self.serviceName).map {
      let peer = PadIdentity.peer(serviceName: $0)
      return WiFiDevice(id: peer.id, name: peer.name)
    }
    wifiDevices = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      .values.sorted { $0.id < $1.id }
    if let selectedWiFiID, !wifiDevices.contains(where: { $0.id == selectedWiFiID }) {
      self.selectedWiFiID = nil
    }
    updatePairingTarget()
    connectIfNeeded()
  }

  private func updatePairingTarget() {
    let device = wifiDevices.first {
      (selectedWiFiID == nil || $0.id == selectedWiFiID) && codes[$0.id] == nil
    }
    unpairedDeviceID = device?.id
    unpairedDeviceName = device?.name
  }

  func pairingCode(id: String, name: String) -> String? {
    codes[id] ?? (refusedLegacyIDs.contains(id) ? nil : (codes[name] ?? (id != name ? codes["iPad"] : nil)))
  }

  func acceptedPairing(id: String, code: String) {
    codes[id] = code
  }

  func refusedPairing(id: String, name: String) {
    codes[id] = nil
    // Do not retry an ambiguous legacy key on this device until the user pairs it.
    refusedLegacyIDs.insert(id)
    unpairedDeviceID = id
    unpairedDeviceName = name
    pairingFailure = "Pairing failed. Check the key on the iPad and try again."
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
          guard let serviceName = Self.serviceName(endpoint) else { continue }
          let peer = PadIdentity.peer(serviceName: serviceName)
          guard selectedWiFiID == nil || selectedWiFiID == peer.id else { continue }
          // A legacy key is only migrated after this specific device proves it owns that key.
          guard let code = pairingCode(id: peer.id, name: peer.name) else { continue }
          let result = await NetworkPipe.open(endpoint, code: code)
          guard run == generation, usesWiFi else {
            if case .opened(let stale) = result { stale.close() }
            break
          }
          switch result {
          case .opened(let pipe):
            acceptedPairing(id: peer.id, code: code)
            opened = pipe
          case .refused:
            // The iPad has a different code now: pair again next time it is seen.
            refusedPairing(id: peer.id, name: peer.name)
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

  func use(_ pipe: LinkPipe) {
    self.pipe = pipe
    unpairedDeviceName = nil
    pairingFailure = nil
    macName = Host.current().localizedName ?? "Mac"
    refreshSources()
    statusTicks = 0
    lastResponse = Date()
    macStatus = PadRemote.MacStatus()
    statusTimer = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if self.iPadState?.linkHeartbeat == true && Date().timeIntervalSince(self.lastResponse) > 8 {
            self.pipe?.close()
            if let pipe = self.pipe { self.lost(pipe) }
            return
          }
          self.statusTicks += 1
          if self.statusTicks % 15 == 0 { self.refreshSources() }
          self.publishMacStatus()
        }
      }
    if relayActive { pipe.videoLimit.store(256_000, ordering: .relaxed) }
    status = Self.connected(over: pipe.name, sending: isOn)
    pipe.onClose = { [weak self, weak pipe] in
      Task { @MainActor in if let pipe { self?.lost(pipe) } }
    }
    pipe.onMessage = { [weak self, weak pipe] message in
      if case .goodbye = message {
        Task { @MainActor in
          guard let self, let pipe, self.pipe === pipe else { return }
          pipe.close()
          self.lost(pipe)
        }
        return
      }
      if case .command(let command) = message {
        Task { @MainActor in
          if let self, let pipe, self.pipe === pipe { self.lastResponse = Date(); self.receive(command) }
        }
        return
      }
      guard case .state(var state) = message else { return }
      // Whatever the iPad says, the window's slider and the CLI get sane numbers.
      state.words = min(max(state.words, 0), 10_000_000)
      state.word = min(max(state.word, 0), state.words)
      Task { @MainActor in if let self, let pipe, self.pipe === pipe { self.lastResponse = Date(); self.iPadState = state } }
    }
    pipe.startReading()
    pipe.send(CameraLink.Message.hello(name: macName, version: CameraLink.protocolVersion).encoded())
    if isOn { attachCamera(pipe) }
    publishMacStatus()
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
    let priority = iPadState?.picturePriority ?? .realTime720p
    encoder.attach(pipe, bitRate: priority.bitRate(overUSB: pipe.name == "USB-C"), longSide: priority.longSide)
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
    if cameraOwnedByIPad { cameraOwnedByIPad = false; isOn = false }
    meterCapture?.stop()
    meterCapture = nil
    statusTimer = nil
    meterSubscription = nil
    sampledMeter = nil
    pendingPeak = -60
    micMeter.show(-60)
    macMicOn = true
    macStatus = PadRemote.MacStatus()
    iPadState = nil
    previewImage = nil
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
    CommandGroup(after: .windowList) {
      Button("Control iPad…") { openWindow(id: "ipad-remote") }
        .help("Choose the script on the iPad and control its reading")
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
    var longSide = 1920
    var generation = 0
  }
  private let target = Mutex(Target())
  private var session: VTCompressionSession?
  private var sessionSize: CMVideoDimensions?
  private var sessionGeneration = -1
  /// The parameter sets last sent, so they go again only when they change.
  private let lastSets = Mutex<[Data]>([])
  private var forceKeyFrame = false
  var onPreview: (@Sendable (CGImage) -> Void)?
  private lazy var previewContext = CIContext(options: [.cacheIntermediates: false])
  private var lastPreviewTime: CFTimeInterval = 0
  private let skipped = Atomic<Int>(0)
  var framesSkipped: Int { skipped.load(ordering: .relaxed) }
  /// Frames inside the encoder, not yet queued on the pipe. Counted with the pipe's waiting frames
  /// when deciding to admit a frame, so two frames cannot both pass while a write is stalled.
  private let encoding = Mutex(0)

  func attach(_ pipe: LinkPipe?, bitRate: Int = 10_000_000, longSide: Int = 1920) {
    skipped.store(0, ordering: .relaxed)
    target.withLock {
      $0.pipe = pipe
      $0.bitRate = bitRate
      $0.longSide = longSide
      $0.generation += 1
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    let (pipe, bitRate, longSide, generation) = target.withLock { ($0.pipe, $0.bitRate, $0.longSide, $0.generation) }
    guard let pipe, let image = sampleBuffer.imageBuffer else {
      if session != nil { tearDown() }
      return
    }
    // The cable or Wi-Fi is behind: skip this frame rather than queue it, and start the next
    // one clean so the iPad never shows a smeared picture. One frame may wait behind the one being
    // written, counting the one still being encoded; a second would only be older by the time it
    // went. Dropped before encoding, so no encoded reference frame is ever lost.
    if pipe.pendingBytes > pipe.videoLimit.load(ordering: .relaxed) || !admit(pipe) {
      skipped.add(1, ordering: .relaxed)
      forceKeyFrame = true
      return
    }
    let now = CACurrentMediaTime()
    if let onPreview, now - lastPreviewTime >= 0.5 {
      lastPreviewTime = now
      let source = CIImage(cvPixelBuffer: image)
      let scale = min(1, 320 / max(source.extent.width, source.extent.height))
      let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      if let thumbnail = previewContext.createCGImage(small, from: small.extent) { onPreview(thumbnail) }
    }
    let size = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(image)), height: Int32(CVPixelBufferGetHeight(image)))
    if session == nil || generation != sessionGeneration || sessionSize.map({ $0.width != size.width || $0.height != size.height }) == true {
      tearDown()
      makeSession(size: size, bitRate: bitRate, longSide: longSide)
      sessionGeneration = generation
    }
    guard let session else { skipped.add(1, ordering: .relaxed); release(); return }
    let options: CFDictionary? = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
    forceKeyFrame = false
    let status = VTCompressionSessionEncodeFrame(
      session, imageBuffer: image, presentationTimeStamp: sampleBuffer.presentationTimeStamp,
      duration: .invalid, frameProperties: options, infoFlagsOut: nil
    ) { [weak self] status, _, encoded in
      guard let self else { return }
      // Released after it is queued, so the frame is always counted in one place or the other.
      defer { self.release() }
      guard status == noErr, let encoded else { self.skipped.add(1, ordering: .relaxed); return }
      self.send(encoded, to: pipe)
    }
    // The handler never runs for a frame VideoToolbox refused.
    if status != noErr { skipped.add(1, ordering: .relaxed); release() }
  }

  /// Reserves the encoder slot unless a frame is already encoding or waiting to be written.
  private func admit(_ pipe: LinkPipe) -> Bool {
    encoding.withLock { count in
      guard count + pipe.videoFramesWaiting == 0 else { return false }
      count += 1
      return true
    }
  }

  private func release() { encoding.withLock { $0 -= 1 } }

  /// Frames reserved in the encoder, for tests.
  var framesEncoding: Int { encoding.withLock { $0 } }

  /// Returns once every frame given so far has come out of the encoder and onto the pipe.
  func drain() {
    captureQueue.sync { if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }
  }

  /// The output picture: the camera's own shape, no larger than `longSide` on its long side.
  static func encodedSize(_ size: CMVideoDimensions, longSide: Int = 1920) -> CMVideoDimensions {
    let long = max(size.width, size.height)
    guard Int(long) > longSide else { return size }
    let scale = Double(longSide) / Double(long)
    // H.264 wants even sizes.
    func even(_ value: Int32) -> Int32 { Int32((Double(value) * scale / 2).rounded()) * 2 }
    return CMVideoDimensions(width: even(size.width), height: even(size.height))
  }

  private func makeSession(size: CMVideoDimensions, bitRate: Int, longSide: Int) {
    let out = Self.encodedSize(size, longSide: longSide)
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
      // A key frame every half second, so a frame the link lost anyway recovers quickly; a frame
      // dropped here asks for one at once. The low-latency encoder honours the frame count, not the duration.
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 0.5,
      kVTCompressionPropertyKey_MaxKeyFrameInterval: 15,
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
  /// Written one message at a time from here, so a control message (anything but format or
  /// frame) can overtake the video still waiting, never the one already being written. At most
  /// one `.follow` and one latest Mac status wait at a time.
  private let backlog = Mutex((control: [(data: Data, key: UInt8)](), video: [Data](), writing: false))
  /// Queued bytes above which the encoder drops a frame. Lower while the voice relay runs, so its
  /// word messages are never far behind.
  let videoLimit = Atomic<Int>(3_000_000)
  private let closeHandler = Mutex<(@Sendable () -> Void)?>(nil)
  private let messageHandler = Mutex<(@Sendable (CameraLink.Message) -> Void)?>(nil)
  private let reader = Mutex(CameraLink.Reader())
  var pendingBytes: Int { pending.load(ordering: .relaxed) }
  /// Frames queued and not yet being written.
  var videoFramesWaiting: Int {
    backlog.withLock { $0.video.reduce(0) { $0 + ($1.count > 4 && $1[$1.startIndex + 4] == 3 ? 1 : 0) } }
  }
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
  /// Writes one message to the transport and calls `done` once it has gone (or failed).
  func write(_ data: Data, done: @escaping @Sendable () -> Void) { done() }
  func close() {}
  func startReading() {}

  final func send(_ data: Data) {
    queued(data.count)
    // Length, then the kind byte: format (2) and frame (3) are the picture, the rest is control.
    let kind = data.count > 4 ? data[data.startIndex + 4] : 0
    let key = kind == 5 ? Self.coalescingKey(data) : 0
    let replaced = backlog.withLock { backlog -> Int? in
      if kind == 2 || kind == 3 { backlog.video.append(data); return nil }
      // A word still waiting is out of date once a newer one arrives. The newer one goes to the
      // tail, so a pause or play sent between them is never overtaken by it.
      var dropped: Int?
      if key != 0, let index = backlog.control.firstIndex(where: { $0.key == key }) {
        dropped = backlog.control.remove(at: index).data.count
      }
      backlog.control.append((data, key))
      return dropped
    }
    if let replaced { sent(replaced) }
    pump()
  }

  private static func coalescingKey(_ message: Data) -> UInt8 {
    guard let command = try? JSONDecoder().decode(PadRemote.Command.self, from: message.dropFirst(5))
    else { return 0 }
    switch command {
    case .follow: return 1
    case .macStatus: return 2
    default: return 0
    }
  }

  private func pump() {
    let next = backlog.withLock { backlog -> Data? in
      guard !backlog.writing else { return nil }
      guard let data = backlog.control.isEmpty ? (backlog.video.isEmpty ? nil : backlog.video.removeFirst()) : backlog.control.removeFirst().data
      else { return nil }
      backlog.writing = true
      return data
    }
    guard let next else { return }
    write(next) { [self] in
      sent(next.count)
      backlog.withLock { $0.writing = false }
      pump()
    }
  }

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

  override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      defer { done() }
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
      case .waiting: pipe?.close()
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

  override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
    connection.send(content: data, completion: .contentProcessed { [weak self] error in
      if error != nil { self?.connection.cancel() }
      done()
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

  /// Bound only the usbmuxd handshake; the established stream waits normally for frames.
  static func handshakeTimeout(on fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
  }

  /// A socket tunnelled to `port` on the device, or nil when the device refuses (nothing is
  /// listening there) or usbmuxd is not reachable.
  static func connect(device: Int, port: UInt16) async -> Int32? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        guard let fd = openSocket() else { return continuation.resume(returning: nil) }
        handshakeTimeout(on: fd, seconds: 3)
        let message = request("Connect", ["DeviceID": device, "PortNumber": Int(port.bigEndian)])
        guard write(message, to: fd), let reply = read(from: fd), reply["Number"] as? Int == 0 else {
          Darwin.close(fd)
          return continuation.resume(returning: nil)
        }
        handshakeTimeout(on: fd, seconds: 0)
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
      while !socket.withLock({ $0.stopped }) {
        listen()
        onChange([])
        // usbmuxd can restart independently of the app. Never leave discovery latched off.
        for _ in 0..<20 {
          if socket.withLock({ $0.stopped }) { return }
          Thread.sleep(forTimeInterval: 0.1)
        }
      }
    }
  }

  private func listen() {
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

  func stop() {
    // Shutting the socket ends the read loop, and its thread closes it.
    socket.withLock { state in
      state.stopped = true
      if let fd = state.fd { Darwin.shutdown(fd, SHUT_RDWR) }
    }
  }
}
#endif
