@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import os

extension CameraDevice {
  /// What the button and the list show: a device with an empty name still reads as something.
  var displayName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unnamed camera" : name
  }
}

/// The camera control for the Camera window's toolbar and the inspector's Video section: a button
/// naming the camera that opens the list, and the list previews whichever camera the pointer or
/// the arrow keys are on, so nobody has to pick blind between several devices.
struct CameraPicker: View {
  @ObservedObject var model: CameraModel
  @ObservedObject var recorder: CameraRecorder = .shared
  /// The library's UI zoom. A popover is its own hosting view, so the parent's zoom never reaches it.
  var zoom = 1.0
  var darkSurface = false
  @Environment(\.colorScheme) private var colorScheme
  @State private var isOpen = false

  /// Never blank. A remembered camera that is gone reads as the one `refresh` will fall back to.
  static func label(for uid: String?, in devices: [CameraDevice]) -> String {
    CameraModel.resolve(uid, in: devices)?.displayName ?? "Choose camera"
  }

  var body: some View {
    let label = Self.label(for: model.selectedUID, in: model.devices)
    Button { isOpen.toggle() } label: {
      HStack(spacing: Space.xs) {
        Text(label).fixedSize(horizontal: false, vertical: true)
          .foregroundColor(darkSurface ? .white : LibraryAppearance.color(.labelColor, scheme: colorScheme))
        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
          .foregroundColor(darkSurface ? .white : LibraryAppearance.color(.labelColor, scheme: colorScheme))
      }
    }
    .disabled(recorder.isRecording || recorder.isBusy)
    .help(recorder.isRecording || recorder.isBusy ? "Stop recording to change camera" : label)
    .onChange(of: recorder.phase) { _, _ in
      if recorder.isRecording || recorder.isBusy { isOpen = false }
    }
    .accessibilityLabel("Camera")
    .accessibilityValue(label)
    .accessibilityHint(recorder.isRecording || recorder.isBusy ? "Stop recording to change camera" : "Lists cameras, with previews when camera access is allowed")
    .restoringPopoverFocus(isPresented: $isOpen, identifier: "camera-picker")
    .popover(isPresented: $isOpen, arrowEdge: .bottom) {
      CameraPickerList(model: model, zoom: zoom) { isOpen = false }.uiZoom(zoom)
    }
  }
}

struct CameraPickerList: View {
  @ObservedObject var model: CameraModel
  var zoom = 1.0
  var startsPreview = true
  /// Hosts with their own recovery card suppress the duplicate explanation and action.
  var showsRecovery = true
  var devicesOverride: [CameraDevice]? = nil
  private var devices: [CameraDevice] { devicesOverride ?? model.devices }
  let close: () -> Void
  @StateObject private var preview = CameraPickerPreview()
  /// The row under the pointer or the keyboard, which is the camera previewed.
  @State private var highlighted: String?
  @State private var navigated = false
  @FocusState private var emptyFocused: Bool
  @FocusState private var keyboardCameraUID: String?
  @AccessibilityFocusState private var focusedCameraUID: String?

  private var selected: String? { CameraModel.resolve(model.selectedUID, in: devices)?.uid }

  var body: some View {
    Group {
      if zoom >= 1.5 {
        VStack(alignment: .leading, spacing: Space.md) {
          pane
          ScrollViewReader { proxy in
            ScrollView { choiceRows }
              .onChange(of: highlighted) { _, uid in
                if let uid, navigated || model.authorization == .authorized { proxy.scrollTo(uid) }
              }
              .onAppear { if let selected { proxy.scrollTo(selected) } }
          }
        }.frame(width: 240, height: 300)
      } else {
        HStack(alignment: .top, spacing: Space.md) { choices; pane }
      }
    }
    .padding(Space.md)
    .focusable(devices.isEmpty)
    .focused($emptyFocused)
    .onKeyPress(.downArrow) { move(1) }
    .onKeyPress(.upArrow) { move(-1) }
    .onKeyPress(.return) { if let highlighted { choose(highlighted) }; return .handled }
    .onKeyPress(.escape) { close(); return .handled }
    .onAppear {
      highlighted = selected ?? devices.first?.uid
      DispatchQueue.main.async {
        emptyFocused = devices.isEmpty
        keyboardCameraUID = highlighted
        focusedCameraUID = highlighted
      }
    }
    .onChange(of: highlighted) { _, uid in if startsPreview { preview.show(uid, mirrored: model.mirrored) } }
    .onChange(of: model.authorization) { _, _ in
      if startsPreview { preview.show(highlighted, mirrored: model.mirrored) }
    }
    .onDisappear { preview.stop() }
  }

  private var choices: some View {
    ScrollViewReader { proxy in
      ScrollView {
        choiceRows
      }
      .onChange(of: highlighted) { _, uid in
        if let uid, navigated || model.authorization == .authorized { proxy.scrollTo(uid) }
      }
      .onAppear { if let selected { proxy.scrollTo(selected) } }
    }.frame(width: 240, height: devices.isEmpty || model.authorization != .authorized ? 260 : min(240, max(44, CGFloat(devices.count) * 52)))
  }

  private var choiceRows: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      if showsRecovery && (devices.isEmpty || model.authorization != .authorized) { emptyState }
      ForEach(devices, id: \.uid) { device in row(device).id(device.uid) }
    }
  }

  private var emptyState: some View {
    let recovery = Self.recovery(for: model.authorization)
    return VStack(alignment: .leading, spacing: Space.sm) {
      Text(recovery.title).font(.headline)
      Text(recovery.message).font(.callout).fixedSize(horizontal: false, vertical: true)
      if model.authorization == .notDetermined {
        Button("Allow Camera Access") { model.start() }
      } else {
      Button("Open Camera Privacy Settings") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
          NSWorkspace.shared.open(url)
        }
      }
      }
      if model.authorization == .authorized {
        Button("Refresh Cameras") { model.refresh() }
      }
    }.font(.callout).foregroundStyle(.primary).padding(Space.sm)
  }

  static func recovery(for authorization: AVAuthorizationStatus) -> (title: String, message: String) {
    switch authorization {
    case .denied, .restricted:
      return ("Camera access is off", "Allow Video Prompter in System Settings, then refresh cameras.")
    case .notDetermined:
      return ("Camera access needed", "Choose Allow Camera Access to see and select your cameras here.")
    default:
      return ("No camera connected", "Connect or switch on your camera, then refresh. Check Camera Privacy Settings if it still does not appear.")
    }
  }

  private func row(_ device: CameraDevice) -> some View {
    let isSelected = device.uid == selected
    let isHighlighted = device.uid == highlighted
    return Button { choose(device.uid) } label: {
      HStack(spacing: Space.sm) {
        Image(systemName: "checkmark").fontWeight(.semibold).opacity(isSelected ? 1 : 0)
        Text(device.displayName).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Space.sm)
      .padding(.vertical, Space.xs)
      .foregroundStyle(isHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
      .background(
        isHighlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: .rect(cornerRadius: Space.xs))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .focusable()
    .focused($keyboardCameraUID, equals: device.uid)
    .onHover { inside in
      if inside {
        navigated = true
        highlighted = device.uid
      } else if highlighted == device.uid {
        highlighted = nil
      }
    }
    .accessibilityLabel(device.displayName)
    .accessibilityFocused($focusedCameraUID, equals: device.uid)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityValue(Self.rowStatus(selected: isSelected, highlighted: isHighlighted, authorization: model.authorization))
  }

  /// Navigation is not evidence that the camera has delivered a picture.
  static func rowStatus(selected: Bool, highlighted: Bool, authorization: AVAuthorizationStatus) -> String {
    var parts = [String]()
    if selected { parts.append("Selected") }
    if highlighted { parts.append("Highlighted") }
    if authorization != .authorized { parts.append(recovery(for: authorization).title) }
    return parts.joined(separator: ". ")
  }

  private var pane: some View {
    VStack(spacing: Space.sm) {
      ZStack {
        Rectangle().fill(.black)
        if let layer = preview.layer {
          PreviewLayerView(layer: layer, rotation: preview.rotation, aspect: preview.aspect)
        }
        if let note {
          Text(note).font(UIType.secondary).foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center).padding(Space.md)
        }
      }
      .frame(width: 240, height: 135)
      .clipShape(.rect(cornerRadius: Space.md))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(note ?? "Camera preview: \(caption)")
      Text(caption).font(UIType.secondary).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true).frame(width: 240)
        .accessibilityHidden(true)
    }
  }

  private var caption: String {
    devices.first { $0.uid == highlighted }?.displayName ?? " "
  }

  /// Read live, never requested: the picker must not raise the permission prompt by itself.
  private var note: String? {
    switch model.authorization {
    case .authorized: break
    case .denied, .restricted: return "Camera access is off. Allow it in System Settings to see previews."
    default: return "Previews appear once camera access is allowed."
    }
    if highlighted == nil { return "Point to a camera or use the arrow keys to preview it" }
    return preview.noSignal ? "No signal" : nil
  }

  private func move(_ step: Int) -> KeyPress.Result {
    navigated = true
    highlighted = Self.nextHighlight(highlighted, selected: selected, devices: devices, step: step)
    keyboardCameraUID = highlighted
    focusedCameraUID = highlighted
    if let device = devices.first(where: { $0.uid == highlighted }) {
      LibraryAnnouncement.post(device.displayName + ". " + Self.rowStatus(selected: device.uid == selected, highlighted: true, authorization: model.authorization))
    }
    return .handled
  }

  static func nextHighlight(_ current: String?, selected: String?, devices: [CameraDevice], step: Int) -> String? {
    let uids = devices.map(\.uid)
    guard !uids.isEmpty else { return nil }
    guard let current, let index = uids.firstIndex(of: current) else { return selected ?? uids.first }
    return uids[min(max(index + step, 0), uids.count - 1)]
  }

  /// The camera is handed to the shared session only once its preview session has let go of it:
  /// a DeckLink input cannot be open in two sessions at once.
  private func choose(_ uid: String) {
    if let device = devices.first(where: { $0.uid == uid }) { LibraryAnnouncement.post("Camera selected: " + device.displayName) }
    guard !CameraRecorder.shared.isRecording && !CameraRecorder.shared.isBusy else { return }
    if uid != model.selectedUID {
      preview.stop { [model] in
        guard !CameraRecorder.shared.isRecording && !CameraRecorder.shared.isBusy else { return }
        model.selectedUID = uid
      }
    }
    close()
  }
}

/// The popover's preview: one camera at a time, for the row under the pointer or the keyboard.
@MainActor final class CameraPickerPreview: ObservableObject {
  enum Source: Equatable {
    case none
    /// The camera `SharedCameraSession` already has attached: a second session could not open it.
    case shared(String)
    /// Any other camera, on a light session of its own.
    case dedicated(String)
  }
  typealias Factory = @MainActor (
    _ uid: String, _ layer: AVCaptureVideoPreviewLayer, _ mirrored: Bool,
    _ firstFrame: @escaping @Sendable () -> Void
  ) -> CameraPreviewFeed

  nonisolated static func source(for uid: String?, sharedUID: String?, authorized: Bool) -> Source {
    guard authorized, let uid else { return .none }
    return uid == sharedUID ? .shared(uid) : .dedicated(uid)
  }

  @Published private(set) var source = Source.none
  /// A fresh layer for each camera shown, so one camera's last picture never sits under the next
  /// camera's name.
  @Published private(set) var layer: AVCaptureVideoPreviewLayer?
  @Published private(set) var noSignal = false
  /// The shown camera's own saved rotation, so a camera mounted on its side previews upright.
  @Published private(set) var rotation = CameraRotation.none
  /// The picture's size before rotation. The shared session knows it; a camera opened here is
  /// taken as 16:9 until proven otherwise, and the layer's aspect-fit keeps any other shape whole.
  @Published private(set) var aspect = CGSize(width: 16, height: 9)
  /// The one dedicated session, if any.
  private(set) var feed: CameraPreviewFeed?
  private let timeout: Duration
  private let sharedUID: @MainActor () -> String?
  private let authorized: @MainActor () -> Bool
  private let makeFeed: Factory
  private let guides: CameraGuideStore
  private var watchdog: Task<Void, Never>?
  /// Bumped on every stop, so a late first frame from a camera already left behind is ignored.
  private var generation = 0

  init(
    timeout: Duration = .seconds(1.5),
    sharedUID: @escaping @MainActor () -> String? = { SharedCameraSession.shared.attachedUID },
    authorized: @escaping @MainActor () -> Bool = {
      AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    },
    guides: CameraGuideStore = CameraGuideStore(),
    makeFeed: @escaping Factory = { CameraPreviewSession(uid: $0, layer: $1, mirrored: $2, firstFrame: $3) }
  ) {
    self.timeout = timeout
    self.sharedUID = sharedUID
    self.authorized = authorized
    self.makeFeed = makeFeed
    self.guides = guides
  }

  /// `mirrored` is the Camera window's Mirror, which applies to whichever camera is shown.
  func show(_ uid: String?, mirrored: Bool = false) {
    let next = Self.source(for: uid, sharedUID: sharedUID(), authorized: authorized())
    guard next != source else { return }
    stop()
    source = next
    guard next != .none else { return }
    // Handed to the session's queue, which only joins it to the session and lets it go.
    nonisolated(unsafe) let layer = AVCaptureVideoPreviewLayer()
    layer.videoGravity = .resizeAspect
    rotation = guides.guides(for: uid).rotation
    aspect = CGSize(width: 16, height: 9)
    self.layer = layer
    switch next {
    case .none:
      return
    case .shared:
      // Held while it is previewed: the selected camera may not be showing anywhere yet.
      let shared = SharedCameraSession.shared
      shared.retain()
      aspect = shared.pictureSize ?? aspect
      layer.setSessionWithNoConnection(shared.session)
      shared.reconfigure { CameraPreviewConnection.connect(layer, to: $0, mirrored: mirrored) }
    case .dedicated(let uid):
      let current = generation
      feed = makeFeed(uid, layer, mirrored) { [weak self] in
        Task { @MainActor in self?.frameArrived(current) }
      }
      watchdog = Task { [weak self, timeout] in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        self?.noFrame(current)
      }
    }
  }

  /// Stops the preview at once. `done` runs once the dedicated session has really closed its
  /// camera, so that camera can be handed to the shared session straight after.
  func stop(then done: (@MainActor @Sendable () -> Void)? = nil) {
    watchdog?.cancel()
    watchdog = nil
    generation += 1
    noSignal = false
    let old = (source, layer)
    source = .none
    layer = nil
    switch old {
    case (.shared, let old?):
      nonisolated(unsafe) let layer = old
      let shared = SharedCameraSession.shared
      shared.reconfigure { CameraPreviewConnection.disconnect(layer, from: $0) }
      shared.release()
      done?()
    case (.dedicated, _):
      feed?.stop { if let done { Task { @MainActor in done() } } }
      feed = nil
    default:
      done?()
    }
  }

  private func frameArrived(_ from: Int) {
    guard from == generation else { return }
    watchdog?.cancel()
    noSignal = false
  }

  /// Nothing in time: say so, and try the heavier preset, which a DeckLink may need.
  private func noFrame(_ from: Int) {
    guard from == generation else { return }
    noSignal = true
    feed?.fallBack()
  }
}

/// A preview session the picker opened. A protocol only so the tests can count sessions without
/// a camera.
@MainActor protocol CameraPreviewFeed: AnyObject {
  /// No frame arrived in time: move to the heavier preset.
  func fallBack()
  /// Stop and close the camera, then call `done` from the session's queue.
  func stop(then done: @escaping @Sendable () -> Void)
}

/// A preview layer joined to its session by hand, on the session's own queue, rather than
/// wherever the layer's `session` property happens to be set. Mirroring belongs to the
/// connection, as in `CameraStageView`; the rotation is the layer's own transform.
enum CameraPreviewConnection {
  static func connect(_ layer: AVCaptureVideoPreviewLayer, to session: AVCaptureSession, mirrored: Bool) {
    let port = session.inputs.lazy.flatMap(\.ports).first { $0.mediaType == .video }
    guard let port else { return }
    let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = mirrored
    }
    session.beginConfiguration()
    if session.canAddConnection(connection) { session.addConnection(connection) }
    session.commitConfiguration()
  }

  static func disconnect(_ layer: AVCaptureVideoPreviewLayer, from session: AVCaptureSession) {
    session.beginConfiguration()
    session.connections.filter { $0.videoPreviewLayer === layer }.forEach(session.removeConnection)
    session.commitConfiguration()
  }
}

/// A light session of its own for a camera the shared session does not have. Every session of
/// this kind is configured, started and stopped on one serial queue, so the camera left behind
/// is closed before the next one opens, and a camera only passed over is never opened at all.
///
/// Preview layer only. A data output watches for the first frame, for "No signal", and is
/// removed as soon as that frame arrives.
///
/// `nonisolated` on purpose: the feed protocol is main-actor, and inferring that isolation here
/// would put `open` on the main actor while it runs on the queue, which is what crashed 0.7.1.
nonisolated final class CameraPreviewSession: NSObject, CameraPreviewFeed,
  AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
  private static let queue = DispatchQueue(label: "VideoPrompter.camera.picker")
  private static let frames = DispatchQueue(label: "VideoPrompter.camera.picker.frames")
  /// Touched on `queue` only, apart from handing it to the layer.
  private let session = AVCaptureSession()
  private let stopped = OSAllocatedUnfairLock(initialState: false)
  private let firstFrame: @Sendable () -> Void
  /// The format the device had before a preset changed it. Touched on `queue` only.
  private var original: (device: AVCaptureDevice, format: AVCaptureDevice.Format)?
  /// The format the device was using once this preview's preset took effect. Queue only.
  private var applied: AVCaptureDevice.Format?
  /// Touched on `frames` only.
  private var sawFrame = false
  private var isStopped: Bool { stopped.withLock { $0 } }

  init(
    uid: String, layer: AVCaptureVideoPreviewLayer, mirrored: Bool = false,
    firstFrame: @escaping @Sendable () -> Void
  ) {
    self.firstFrame = firstFrame
    super.init()
    layer.setSessionWithNoConnection(session)
    nonisolated(unsafe) let layer = layer
    Self.queue.async { self.open(uid, layer, mirrored) }
  }

  /// `.medium` first, the lightest preset worth trying: a 4K v210 feed is heavy for a thumbnail.
  /// `fallBack` moves to `.high`, which runs Cam B at 1920x1080.
  private func open(_ uid: String, _ layer: AVCaptureVideoPreviewLayer, _ mirrored: Bool) {
    guard !isStopped, let device = AVCaptureDevice(uniqueID: uid),
      let input = try? AVCaptureDeviceInput(device: device)
    else { return }
    original = (device, device.activeFormat)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: Self.frames)
    session.beginConfiguration()
    if session.canAddInput(input) { session.addInput(input) }
    if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
    if session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
    CameraPreviewConnection.connect(layer, to: session, mirrored: mirrored)
    if CaptureAccess.mayUse(.video) { session.startRunning() }
    applied = device.activeFormat
  }

  /// The format to give back on stop: the original, but only while the device is still on the exact
  /// one this preview applied. Anything else was chosen later by `SharedCameraSession` or the
  /// probe, and is not this preview's to undo.
  static func formatToRestore<Format: Equatable>(original: Format, applied: Format?, current: Format) -> Format? {
    applied == current && current != original ? original : nil
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard !sawFrame else { return }
    sawFrame = true
    firstFrame()
    let session = self.session
    Self.queue.async {
      guard session.outputs.contains(output) else { return }
      session.beginConfiguration()
      session.removeOutput(output)
      session.commitConfiguration()
    }
  }

  func fallBack() {
    Self.queue.async { [self] in
      guard !isStopped, session.sessionPreset != .high, session.canSetSessionPreset(.high) else { return }
      session.beginConfiguration()
      session.sessionPreset = .high
      session.commitConfiguration()
      applied = original?.device.activeFormat
    }
  }

  /// Leaves the session empty as well as stopped, so whichever thread lets go of it last has
  /// nothing left to tear down, and gives the device back the format it came with: the preset
  /// replaced it, and `SharedCameraSession` pins whatever format a DeckLink has when it opens it.
  func stop(then done: @escaping @Sendable () -> Void) {
    stopped.withLock { $0 = true }
    Self.queue.async { [self] in
      session.stopRunning()
      session.beginConfiguration()
      session.connections.filter { $0.videoPreviewLayer != nil }.forEach(session.removeConnection)
      session.outputs.forEach(session.removeOutput)
      session.inputs.forEach(session.removeInput)
      session.commitConfiguration()
      if let (device, format) = original,
        let restore = Self.formatToRestore(original: format, applied: applied, current: device.activeFormat),
        (try? device.lockForConfiguration()) != nil
      {
        device.activeFormat = restore
        device.unlockForConfiguration()
      }
      original = nil
      applied = nil
      done()
    }
  }
}

/// Hosts the preview layer, turned and aspect-fitted the way `CameraStageView` does it.
private struct PreviewLayerView: NSViewRepresentable {
  let layer: AVCaptureVideoPreviewLayer
  let rotation: CameraRotation
  let aspect: CGSize
  func makeNSView(context: Context) -> CameraThumbnailView { CameraThumbnailView() }
  func updateNSView(_ view: CameraThumbnailView, context: Context) {
    view.preview = layer
    view.rotation = rotation
    view.aspect = aspect
  }
}

/// Internal for the geometry test.
final class CameraThumbnailView: NSView {
  var preview: AVCaptureVideoPreviewLayer? {
    didSet {
      guard preview !== oldValue else { return }
      oldValue?.removeFromSuperlayer()
      if let preview { layer?.addSublayer(preview) }
      needsLayout = true
    }
  }
  var rotation = CameraRotation.none { didSet { if rotation != oldValue { needsLayout = true } } }
  var aspect = CGSize(width: 16, height: 9) { didSet { if aspect != oldValue { needsLayout = true } } }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
  }
  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    guard let preview else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CameraStageView.place(preview, on: rotation.fittedRect(aspect: aspect, in: bounds), turnedBy: rotation)
    CATransaction.commit()
  }
}
