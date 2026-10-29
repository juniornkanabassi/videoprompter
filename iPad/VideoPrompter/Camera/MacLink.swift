@preconcurrency import AVFoundation
import Network
import PrompterCore
import SwiftUI
import UIKit

/// Receives the camera a Mac sends with File › Send Camera to iPad. Over USB-C the Mac reaches
/// the iPad through usbmuxd, the same channel Xcode and Finder use, so no network or pairing is
/// needed; the iPad only listens on its own loopback port. On Wi-Fi it advertises itself with
/// Bonjour, but only when Settings allows it, since that asks for local network access.
///
/// One Mac at a time: a new connection replaces the old one.
@MainActor final class MacLink: ObservableObject {
  /// The sending Mac's name while one is connected.
  @Published private(set) var macName: String?
  /// The picture's size as the Mac encodes it.
  @Published private(set) var pictureSize: CGSize?
  @Published var allowsWiFi = UserDefaults.standard.bool(forKey: "macLinkWiFi") {
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
    if let code = UserDefaults.standard.string(forKey: "macLinkKey") { return code }
    let code = CameraLinkSecurity.newCode()
    UserDefaults.standard.set(code, forKey: "macLinkKey")
    return code
  }()

  func newPairingCode() {
    pairingCode = CameraLinkSecurity.newCode()
    UserDefaults.standard.set(pairingCode, forKey: "macLinkKey")
    if allowsWiFi {
      wifi?.cancel()
      wifi = nil
      receiver.dropWiFi()
      restartWiFi()
    }
  }

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
  func start() {
    if usb == nil || usb?.state == .cancelled { usb = makeUSBListener() }
    restartWiFi()
  }

  private func makeUSBListener() -> NWListener? {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true
    guard let port = NWEndpoint.Port(rawValue: CameraLink.usbPort),
      let listener = try? NWListener(using: parameters, on: port)
    else { return nil }
    configure(listener)
    return listener
  }

  private func restartWiFi() {
    if !allowsWiFi {
      wifi?.cancel()
      wifi = nil
      // Turning Wi-Fi off also ends a Mac already sending over it; USB-C carries on.
      receiver.dropWiFi()
    } else if wifi == nil || wifi?.state == .cancelled {
      let parameters = CameraLinkSecurity.parameters(code: pairingCode)
      parameters.includePeerToPeer = false
      guard let listener = try? NWListener(using: parameters) else { return }
      listener.service = NWListener.Service(name: UIDevice.current.name, type: CameraLink.bonjourType)
      configure(listener, wifi: true)
      wifi = listener
    }
  }

  private func configure(_ listener: NWListener, wifi: Bool = false) {
    let receiver = self.receiver
    listener.newConnectionHandler = { connection in receiver.accept(connection, overWiFi: wifi) }
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

  private func handle(_ event: LinkReceiver.Event) {
    switch event {
    case .connected(let name):
      macName = name
      onChange?()
    case .format(let size):
      pictureSize = size
      onChange?()
    case .disconnected:
      guard macName != nil else { return }
      macName = nil
      pictureSize = nil
      onChange?()
    }
  }
}

/// The network side: reads messages and turns frames into sample buffers for the renderer, all on
/// one serial queue. `@unchecked Sendable` because every stored property is touched on `queue`
/// only, except `onEvent`, which is set once before the first connection.
final class LinkReceiver: @unchecked Sendable {
  enum Event: Sendable {
    case connected(String)
    case format(CGSize)
    case disconnected
  }

  let queue = DispatchQueue(label: "VideoPrompter.maclink", qos: .userInteractive)
  var onEvent: (@Sendable (Event) -> Void)?
  private let renderer: AVSampleBufferVideoRenderer
  private var connection: NWConnection?
  private var connectionIsWiFi = false
  private var reader = CameraLink.Reader()
  private var format: CMVideoFormatDescription?
  /// After a connection or a decoder failure, frames wait for the next key frame.
  private var needsKeyFrame = true

  init(renderer: AVSampleBufferVideoRenderer) {
    self.renderer = renderer
  }

  /// Connections still in their handshake, and whether each came over Wi-Fi.
  private var pending: [(connection: NWConnection, wifi: Bool)] = []

  /// Called on `queue`, where the listeners run.
  func accept(_ new: NWConnection, overWiFi: Bool) {
    // The current Mac stays until the newcomer is ready, so a peer that fails the pairing
    // handshake cannot knock it off.
    pending.append((new, overWiFi))
    new.stateUpdateHandler = { [weak self, weak new] state in
      guard let self, let new else { return }
      switch state {
      case .ready: self.promote(new, overWiFi: overWiFi)
      case .failed, .cancelled:
        self.pending.removeAll { $0.connection === new }
        self.closed(new)
      default: break
      }
    }
    new.start(queue: queue)
    // A handshake that never finishes must not linger.
    queue.asyncAfter(deadline: .now() + 10) { [weak self, weak new] in
      guard let self, let new, self.pending.contains(where: { $0.connection === new }) else { return }
      new.cancel()
    }
  }

  private func promote(_ new: NWConnection, overWiFi: Bool) {
    // Dropped while it shook hands: Wi-Fi was turned off or the pairing code changed.
    guard pending.contains(where: { $0.connection === new }) else { return }
    pending.removeAll { $0.connection === new }
    connection?.cancel()
    connection = new
    connectionIsWiFi = overWiFi
    reader = CameraLink.Reader()
    format = nil
    needsKeyFrame = true
    renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    receive(on: new)
  }

  func dropWiFi() {
    queue.async { [self] in
      if connectionIsWiFi { connection?.cancel() }
      for waiting in pending where waiting.wifi { waiting.connection.cancel() }
      pending.removeAll { $0.wifi }
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
    case .hello(let name, _):
      onEvent?(.connected(name))
    case .format(let width, let height, let sets):
      format = Self.formatDescription(sets)
      needsKeyFrame = true
      onEvent?(.format(CGSize(width: width, height: height)))
    case .frame(_, let keyFrame, let data):
      enqueue(data, keyFrame: keyFrame)
    case .goodbye:
      connection?.cancel()
    }
  }

  private func enqueue(_ data: Data, keyFrame: Bool) {
    guard let format else { return }
    if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
      renderer.flush()
      needsKeyFrame = true
    }
    if needsKeyFrame {
      guard keyFrame else { return }
      needsKeyFrame = false
    }
    // A slow decoder must not build a queue: the picture is for framing, and a late frame is
    // worse than a dropped one.
    // A dropped frame breaks the ones that refer to it, so wait for the next key frame.
    guard renderer.isReadyForMoreMediaData || keyFrame, let sample = Self.sampleBuffer(data, format: format) else {
      needsKeyFrame = true
      return
    }
    renderer.enqueue(sample)
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
