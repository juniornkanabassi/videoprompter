@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// A video device as the picker shows it. `uid` is `AVCaptureDevice.uniqueID`, which is what
/// gets remembered: names repeat across identical cameras, unique IDs do not.
struct CameraDevice: Identifiable, Hashable, Sendable {
  let uid: String
  let name: String
  var isPhysical = true
  var id: String { uid }
}

/// What the presenter shows. Older versions stored only whether video was on, as a Bool.
enum PresenterDisplayMode: String, CaseIterable, Identifiable {
  case prompterOnly, prompterWithVideo, videoOnly
  var id: String { rawValue }
  var label: String {
    switch self {
    case .prompterOnly: "Script only"
    case .prompterWithVideo: "Script and camera"
    case .videoOnly: "Camera only"
    }
  }
  var systemImage: String {
    switch self {
    case .prompterOnly: "text.alignleft"
    case .prompterWithVideo: "video.fill"
    case .videoOnly: "camera.fill"
    }
  }
}

@MainActor final class CameraModel: ObservableObject {
  /// One model for the Camera window, the Camera menu and the presenter's video background:
  /// they show the same camera with the same rotation and the same guides.
  static let shared = CameraModel(defaults: AppStore.preferences())
  @Published private(set) var devices: [CameraDevice] = []
  @Published private var storedSelectedUID: String?
  var selectedUID: String? {
    get { storedSelectedUID }
    set {
      guard !recordingLocked, newValue != storedSelectedUID else { return }
      storedSelectedUID = newValue
      defaults.set(newValue, forKey: "cameraDeviceUID")
      loadingGuides = true
      guides = guideStore.guides(for: newValue)
      loadingGuides = false
    }
  }
  @Published private var storedGuides = CameraGuides()
  var guides: CameraGuides {
    get { storedGuides }
    set {
      var value = newValue
      if recordingLocked {
        value.rotation = storedGuides.rotation
        value.automaticRotation = storedGuides.automaticRotation
      }
      let old = storedGuides
      guard value != old else { return }
      storedGuides = value
      if !loadingGuides {
        guideStore.set(value, for: selectedUID)
        if value.zebras != old.zebras { announceExposure("Zebras", on: value.zebras) }
        if value.falseColour != old.falseColour { announceExposure("False colour", on: value.falseColour) }
      }
    }
  }
  @Published var mirrored: Bool { didSet {
    defaults.set(mirrored, forKey: "cameraMirrored")
  } }
  var recorder: CameraRecorder = .shared
  var recordingLocked: Bool { recorder.isRecording || recorder.isBusy }
  @Published var cleanView = false
  @Published var exposureBypassed = false
  var exposureIsConfigured: Bool { guides.zebras || guides.falseColour }
  var previewGuides: CameraGuides {
    var value = guides
    if exposureBypassed || cleanView { value.zebras = false; value.falseColour = false }
    if cleanView { value.thirds = false; value.axes = false; value.bullseye = false; value.marker = nil }
    return value
  }
  private func announceExposure(_ name: String, on: Bool) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: name + (on ? " on" : " off"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }
  func applySkinExposurePreset() {
    guides.zebras = true; guides.useZebraPreset(.faceReference)
    guides.falseColour = false; exposureBypassed = false
  }
  @Published var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: "cameraAlwaysOnTop") } }
  /// Script only, script over the live picture, or the live picture alone. The presenter's own
  /// controls are unaffected. The old Bool key is still written, so an older build reads it too.
  @Published var displayMode: PresenterDisplayMode {
    didSet {
      guard !showingTemporarily else { return }
      defaults.set(displayMode.rawValue, forKey: "presenterDisplayMode")
      defaults.set(displayMode != .prompterOnly, forKey: "presenterWithVideo")
    }
  }
  private var showingTemporarily = false
  /// True while `showTemporarily` assigns, which is when `$displayMode` subscribers hear of it.
  var isShowingTemporarily: Bool { showingTemporarily }
  /// Camera only forced by the reference monitor or a presenter with no script. It is not saved,
  /// so a quit or a close leaves the person's own choice for next time.
  func showTemporarily(_ mode: PresenterDisplayMode) {
    showingTemporarily = true
    displayMode = mode
    showingTemporarily = false
  }
  /// The last view the person chose, as saved.
  var savedDisplayMode: PresenterDisplayMode {
    defaults.string(forKey: "presenterDisplayMode").flatMap(PresenterDisplayMode.init)
      ?? (defaults.bool(forKey: "presenterWithVideo") ? .prompterWithVideo : .prompterOnly)
  }
  func restoreSavedDisplayMode() {
    let saved = savedDisplayMode
    if displayMode != saved { displayMode = saved }
  }
  /// Whether the picture is shown at all: the capsule button, the menu and the camera ask this.
  var presentsWithVideo: Bool {
    get { displayMode != .prompterOnly }
    set { if newValue != presentsWithVideo { displayMode = newValue ? .prompterWithVideo : .prompterOnly } }
  }
  var recordingReadyOverride: Bool?
  @Published var authorization = AVCaptureDevice.authorizationStatus(for: .video)
  private let defaults: UserDefaults
  private let guideStore: CameraGuideStore
  private var loadingGuides = false
  // nonisolated so `deinit` can take the observers back out again.
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    guideStore = CameraGuideStore(defaults: defaults)
    let uid = defaults.string(forKey: "cameraDeviceUID")
    storedSelectedUID = uid
    storedGuides = guideStore.guides(for: uid)
    mirrored = defaults.bool(forKey: "cameraMirrored")
    alwaysOnTop = defaults.bool(forKey: "cameraAlwaysOnTop")
    displayMode = defaults.string(forKey: "presenterDisplayMode").flatMap(PresenterDisplayMode.init)
      ?? (defaults.bool(forKey: "presenterWithVideo") ? .prompterWithVideo : .prompterOnly)
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  /// A rotation chosen by hand turns Auto back off; one Vision picked leaves it on.
  func setRotation(_ rotation: CameraRotation, automatic: Bool = false) {
    guard !recordingLocked else { return }
    guard guides.rotation != rotation || guides.automaticRotation == automatic,
      !automatic || guides.automaticRotation else { return }
    guides.rotation = rotation
    if !automatic { guides.automaticRotation = false }
  }

  /// Built-in, USB/Thunderbolt UVC, Continuity Camera and every virtual camera (OBS, Elgato,
  /// Blackmagic) that registers itself as an AVFoundation device — those arrive as `.external`.
  static func discovered() -> [CameraDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
      mediaType: .video, position: .unspecified
    ).devices.map {
      CameraDevice(uid: $0.uniqueID, name: $0.localizedName,
        isPhysical: $0.deviceType == .builtInWideAngleCamera || $0.deviceType == .continuityCamera
          // Only recognised physical transports may be chosen without the user's input.
          || ($0.deviceType == .external && [0x626c746e, 0x70636920, 0x75736220, 0x31333934, 0x7468756e].contains($0.transportType))) // bltn, pci, usb, 1394, thun
    }
  }

  /// Preserve saved choices. A new setup must never silently choose a virtual camera.
  static func resolve(_ savedUID: String?, in devices: [CameraDevice]) -> CameraDevice? {
    if let savedUID { return devices.first { $0.uid == savedUID } }
    return devices.first { $0.isPhysical && !$0.name.localizedCaseInsensitiveContains("virtual") }
  }

  func start() {
    guard observers.isEmpty else { refresh(); return }
    for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      })
    }
    Task {
      if authorization == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
      }
      refresh()
    }
  }

  var unavailableMessage: String? {
    if authorization == .denied || authorization == .restricted {
      return "Allow camera access in System Settings > Privacy & Security > Camera."
    }
    if Self.resolve(selectedUID, in: devices) == nil {
      return selectedUID == nil ? (devices.isEmpty ? "Connect a camera, then choose it in the camera menu." : "Choose a camera to show its picture. Virtual cameras are never selected automatically.") : "The chosen camera is unavailable. Reconnect it or choose another camera."
    }
    return nil
  }

  func refresh() {
    let previousMessage = unavailableMessage
    devices = Self.discovered()
    let resolved = Self.resolve(selectedUID, in: devices)?.uid
    if selectedUID == nil, let resolved {
      selectedUID = resolved
      if let name = devices.first(where: { $0.uid == resolved })?.name {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
          userInfo: [.announcement: "Camera chosen: \(name)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
      }
    }
    if let message = unavailableMessage, message != previousMessage {
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
  }

  /// The rotation control's choices, in the Camera window's toolbar and the inspector alike.
  static let rotationOptions: [(String, CameraRotation?)] =
    [("Automatic", nil)] + CameraRotation.allCases.map { ($0.label, Optional($0)) }

  /// One control for the four angles and Auto: nothing chooses an angle *and* leaves Auto on.
  /// On the model, because the Camera window's toolbar and the inspector both show it.
  var rotationChoice: Binding<CameraRotation?> {
    Binding(
      get: { [weak self] in
        guard let self, !guides.automaticRotation else { return nil }
        return guides.rotation
      },
      set: { [weak self] value in
        guard let self else { return }
        if let value { setRotation(value) } else { guides.automaticRotation = true }
      })
  }
}

/// The camera picture in a window or behind the script. Both hand the same model to the same
/// `CameraStageView`, so the session is opened once and the guides cannot drift apart.
struct CameraPreview: NSViewRepresentable {
  @ObservedObject var model: CameraModel
  func makeNSView(context: Context) -> CameraStageView { CameraStageView(frame: .zero) }
  func updateNSView(_ view: CameraStageView, context: Context) {
    view.apply(uid: model.selectedUID, guides: model.previewGuides, mirrored: model.mirrored)
  }
  static func dismantleNSView(_ view: CameraStageView, coordinator: ()) { view.stop() }
}

struct CameraView: View {
  @ObservedObject private var model: CameraModel
  @State private var showsGuideSettings = false
  @State private var showsExposureSettings = false
  @Environment(\.openSettings) private var openSettings
  var zoom = 1.0
  @ObservedObject private var recorder: CameraRecorder
  private let startsCamera: Bool

  init(model: CameraModel = .shared, recorder: CameraRecorder = .shared, startsCamera: Bool = true, zoom: Double = 1) {
    self.model = model
    self.recorder = recorder
    self.zoom = zoom
    self.startsCamera = startsCamera
  }
  var body: some View {
    Group {
      switch model.authorization {
      case .denied, .restricted:
        ContentUnavailableView {
          Label("No camera access", systemImage: "video.slash")
        } description: {
          Text("Allow Video Prompter in System Settings → Privacy & Security → Camera.").font(.callout).foregroundStyle(.primary)
        } actions: {
          Button("Open System Settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
          }
        }
        .uiZoom(zoom)
      default:
        if let message = model.unavailableMessage {
          ContentUnavailableView("Connect a camera", systemImage: "video",
            description: Text(message).font(.callout).foregroundStyle(.primary))
            .uiZoom(zoom)
        } else {
          CameraPreview(model: model).background(.black)
        }
      }
    }
    .overlay(alignment: .topTrailing) { ExposureLegend(model: model).padding(Space.sm).uiZoom(zoom) }
    .popover(isPresented: $showsExposureSettings) { CameraExposureSettings(model: model).frame(width: 360, height: 500).uiZoom(zoom) }
    .frame(minWidth: 320, minHeight: 200)
    .task { if startsCamera { model.start() } }

    .background(CameraWindowLevel(alwaysOnTop: model.alwaysOnTop))
    .toolbar {
      CameraChoiceItems(model: model, rotation: model.rotationChoice, recording: recorder.isRecording || recorder.isBusy)
      ToolbarItemGroup { ExposureToggle(model: model, kind: .zebras); ExposureToggle(model: model, kind: .falseColour) }
      ToolbarItem {
        Button("Exposure…", systemImage: "sun.max") { showsExposureSettings = true }
      }
      ToolbarItemGroup { RecordingControls(recorder: recorder, camera: model, zoom: zoom) }
      ToolbarItem {
        Menu {
          Text("Second-display camera view. Shares camera and recording setup with the presenter.")
          Toggle("Mirror Camera Preview", isOn: $model.mirrored).help("Flip only the monitor picture. Saved video has its own mirroring setting.")
          Button("Framing Guides…") { showsGuideSettings = true }
            .help("Choose framing guides and a frame marker")
          Button("Camera & Recording Settings…") { AppSettingsView.requestTab(.camera); openSettings() }
          Toggle("Always on Top", isOn: $model.alwaysOnTop).help("Keep the Camera window above other windows")
        } label: { Label("Options", systemImage: "ellipsis.circle") }
          .accessibilityLabel("Options").help("Camera mirroring, framing guides and window position")
          .popover(isPresented: $showsGuideSettings, arrowEdge: .bottom) {
            CameraGuideSettings(model: model).frame(width: 340, height: 480).uiZoom(zoom)
          }
      }
    }
  }
}

/// The Camera window's camera and rotation pop-ups.
struct CameraChoiceItems: ToolbarContent {
  @ObservedObject var model: CameraModel
  @Binding var rotation: CameraRotation?
  var recording = false
  var body: some ToolbarContent {
    // The picker previews each camera on hover, so choosing one is never blind.
    ToolbarItem { CameraPicker(model: model).disabled(recording) }
    ToolbarItem {
      ToolbarPopUp(title: "Rotation", help: "Rotate the preview and saved video, or choose Automatic", options: CameraModel.rotationOptions, selection: $rotation).disabled(recording)
    }
  }
}

/// A toolbar pop-up that always shows its selection. SwiftUI's `Picker` drew blank in this
/// toolbar; AppKit's pop-up is re-synced on every update, so a camera list that arrives after the
/// window opens still shows the chosen name.
struct ToolbarPopUp<Value: Hashable>: NSViewRepresentable {
  let title: String
  var help: String? = nil
  let options: [(String, Value)]
  @Binding var selection: Value

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSPopUpButton {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.setAccessibilityLabel(title)
    popup.toolTip = help ?? title
    return popup
  }
  func updateNSView(_ popup: NSPopUpButton, context: Context) {
    let values = options.map(\.1)
    let selection = $selection
    context.coordinator.onChoose = { index in
      if values.indices.contains(index) { selection.wrappedValue = values[index] }
    }
    Self.sync(popup, titles: options.map(\.0), selected: values.firstIndex(of: self.selection),
              placeholder: "None", target: context.coordinator)
  }
  /// Items go in through the menu: `addItems(withTitles:)` drops a second camera of the same name.
  static func sync(_ popup: NSPopUpButton, titles: [String], selected: Int?, placeholder: String,
                   target: Coordinator) {
    let shown = titles.isEmpty ? [placeholder] : titles
    if popup.itemArray.map(\.title) != shown {
      popup.removeAllItems()
      for (index, title) in shown.enumerated() {
        let item = NSMenuItem(title: title, action: titles.isEmpty ? nil : #selector(Coordinator.choose(_:)), keyEquivalent: "")
        item.target = target
        item.tag = index
        popup.menu?.addItem(item)
      }
    }
    popup.isEnabled = !titles.isEmpty
    popup.selectItem(at: titles.isEmpty ? 0 : selected ?? -1)
  }
  @MainActor final class Coordinator: NSObject {
    var onChoose: (Int) -> Void = { _ in }
    @objc func choose(_ sender: NSMenuItem) { onChoose(sender.tag) }
  }
}

/// The composition guides and the frame marker, in one popover rather than a row of toolbar
/// toggles: there are too many of them now to sit in the toolbar.
struct CameraGuideSettings: View {
  @ObservedObject var model: CameraModel
  var body: some View {
    Form { CameraGuideSections(model: model) }.formStyle(.grouped)
  }
}

/// Every camera choice in one place: the presenter's View menu and the Settings panel both open
/// this, so the camera, its turn, mirroring and the guides are never split across three screens.
struct CameraSettingsPanel: View {
  @ObservedObject var model: CameraModel
  var zoom = 1.0
  var body: some View {
    Form { CameraSettingsSections(model: model, zoom: zoom); CameraGuideSections(model: model); CameraExposureSections(model: model) }.formStyle(.grouped)
  }
}

struct CameraSettingsSections: View {
  @ObservedObject var model: CameraModel
  var zoom = 1.0
  var body: some View {
    Section("Camera") {
      LabeledContent("Camera") { CameraPicker(model: model, zoom: zoom) }
        .disabled(model.recordingLocked).help("Stop recording to change this")
      Picker("Camera and saved-video rotation", selection: model.rotationChoice) {
        ForEach(CameraModel.rotationOptions, id: \.0) { Text($0.0).tag($0.1) }
      }.disabled(model.recordingLocked).help("Stop recording to change this")
      Text("Rotation changes both the camera preview and the saved take.").font(.callout)
      if model.guides.automaticRotation { Text("Detected angle: \(model.guides.rotation.label)").font(.callout) }
      Toggle("Mirror camera preview", isOn: $model.mirrored)
    }
  }
}

/// The guide and frame marker sections, shared by both panels above.
struct CameraGuideSections: View {
  @ObservedObject var model: CameraModel
  @State private var customWidth = 2.39
  @State private var customHeight = 1.0
  var body: some View {
    Group {
      Section("Framing guides") {
        Toggle("Rule of thirds", isOn: $model.guides.thirds).help("Divide the picture into thirds to help compose your shot")
        Toggle("Centre cross", isOn: $model.guides.axes).help("Mark the horizontal and vertical centre of the picture")
        Toggle("Centre target", isOn: $model.guides.bullseye).help("Mark the centre with a target")
        ColorPicker("Colour", selection: guideColor, supportsOpacity: false).help("Choose the colour of framing guides")
        LabeledContent("Guide visibility") { Slider(value: $model.guides.opacity, in: 0...1).accessibilityLabel("Guide visibility").accessibilityValue("\(Int(model.guides.opacity * 100)) percent") }.help("Fade the guides; zero hides them")
      }
      Section("Frame marker") {
        Picker("Frame shape", selection: $model.guides.marker) {
          Text("Off").tag(nil as CameraAspect?)
          ForEach(CameraAspect.presets) { Text($0.label).tag(Optional($0)) }
          Text("Custom").tag(Optional(custom))
        }.help("Mark the shape of your intended output without cropping the recording")
        if let marker = model.guides.marker { Text("\(marker.label) guide only. The full frame is recorded.").font(.callout) }
        if let value = model.guides.marker, !CameraAspect.presets.contains(value) {
          HStack {
            TextField("Width", value: $customWidth, format: .number).help("Set the width part of the custom frame ratio").frame(width: 64)
            Text(":")
            TextField("Height", value: $customHeight, format: .number).help("Set the height part of the custom frame ratio").frame(width: 64)
          }
          .onChange(of: customWidth) { model.guides.marker = custom }
          .onChange(of: customHeight) { model.guides.marker = custom }
        }
        if model.guides.marker != nil {
          LabeledContent("Shade outside") { Slider(value: $model.guides.shadeOpacity, in: 0...1).accessibilityLabel("Shade outside").accessibilityValue("\(Int(model.guides.shadeOpacity * 100)) percent") }.help("Darken the area outside the frame marker")
        }
      }
    }
  }
  private var custom: CameraAspect { CameraAspect(width: customWidth, height: customHeight) }
  private var guideColor: Binding<Color> {
    Binding(
      get: {
        guard let cgColor = CameraGuides.color(model.guides.colorHex, alpha: 1) else { return .blue }
        return Color(nsColor: NSColor(cgColor: cgColor) ?? .systemBlue)
      },
      set: {
        let rgb = NSColor($0).usingColorSpace(.sRGB) ?? .systemBlue
        func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        model.guides.colorHex = String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
      })
  }
}

/// Always-on-top belongs to the window, not to the preview inside it.
private struct CameraWindowLevel: NSViewRepresentable {
  let alwaysOnTop: Bool
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = WindowAttachmentView(frame: .zero)
    view.onAttach = { [weak coordinator = context.coordinator] window in coordinator?.observe(window) }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.alwaysOnTop = alwaysOnTop
    context.coordinator.observe(view.window)
  }
  @MainActor final class Coordinator {
    var alwaysOnTop = false
    private weak var window: NSWindow?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    func observe(_ window: NSWindow?) {
      guard let window else { return }
      window.level = alwaysOnTop ? .floating : .normal
      guard self.window !== window else { return }
      self.window = window
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification].map { name in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
          MainActor.assumeIsolated { PresenterController.shared.preserveRecordingStatus() }
        }
      }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
  }
  private final class WindowAttachmentView: NSView {
    var onAttach: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onAttach?(window)
    }
  }
}

struct PresenterRecordButton: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  var compact = false
  var body: some View {
    Group {
      if recorder.phase == .preparing || recorder.phase == .waitingForFrames {
        Button { Task { await recorder.stop() } } label: {
          Text(compact ? "Cancel" : "Cancel preparation")
        }.accessibilityLabel("Cancel preparation")
        Text(recorder.phase == .waitingForFrames ? "Waiting for camera" : "Preparing…")
          .font(.callout).fixedSize(horizontal: false, vertical: true)
      } else if recorder.isRecording {
        Button { Task { await recorder.stop() } } label: {
          if compact { VStack(spacing: 0) { Text("Stop"); Text("recording") }.fixedSize() }
          else { Label("Stop recording", systemImage: "stop.circle.fill") }
        }.accessibilityLabel("Stop recording")
          .buttonStyle(PresenterButtonStyle(prominent: true)).tint(.red)
        let seconds = Int(recorder.recordedDuration)
        HStack(spacing: Space.xs) {
          Circle().fill(.red).frame(width: 8, height: 8)
          Text(String(format: "REC %02d:%02d", seconds / 60, seconds % 60)).monospacedDigit().font(.callout)
        }.accessibilityElement(children: .combine).layoutPriority(2)
      } else if recorder.phase == .saving {
        Text("Saving…").font(.callout)
      } else {
        Button { Task { await recorder.start(camera: camera) } } label: {
          Label { Text("Record").fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "record.circle").foregroundStyle(.red) }
        }.accessibilityLabel("Record")
          .buttonStyle(PresenterButtonStyle()).disabled(!camera.isReadyToRecord)
      }
    }
  }
}

struct RecordingControls: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  var compact = false
  var showsSetup = true
  var showsHealth = true
  var zoom = 1.0
  var body: some View {
    PresenterRecordButton(recorder: recorder, camera: camera)
    if showsHealth && (recorder.isRecording || recorder.isBusy) { RecordingAudioHealth(recorder: recorder) }
    if recorder.phase == .idle { RecordingReceipt(recorder: recorder, camera: camera, zoom: zoom).uiZoom(zoom) }
  }
}

/// Also shown in the persistent result, because an alert can close when recording stops.
struct RecordingRecoveryActions: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  var configure: () -> Void
  var body: some View {
      switch recorder.recovery {
      case .cameraPrivacy:
        Button("Allow camera access") { openPrivacy("Camera") }
      case .microphonePrivacy:
        Button("Allow microphone access") { openPrivacy("Microphone") }
      case .camera, .microphone:
        Button("Choose \(recorder.recovery == .camera ? "camera" : "microphone")") { configure() }
      case .format:
        Button("Change recording format") { configure() }
      case .storage:
        Button("Open recordings folder") { recorder.openRecordingsFolder() }
      case .retry:
        Button("Try recording again") { Task { await recorder.start(camera: camera) } }
      }
  }
  private func openPrivacy(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane)!)
  }
}

struct RecordingMicrophoneSection: View {
  @ObservedObject var recorder: CameraRecorder
  var body: some View {
      Section("Recording microphone") {

        Menu {
        Picker("Recording microphone", selection: Binding(get: { recorder.microphoneUID ?? "" }, set: { recorder.stopInputTest(); recorder.microphoneUID = $0.isEmpty ? nil : $0 })) {
          Text("System default (\(AVCaptureDevice.default(for: .audio)?.localizedName ?? "unavailable"))").tag("")
          ForEach(CameraRecorder.microphones(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
          if let uid = recorder.microphoneUID, !CameraRecorder.microphones().contains(where: { $0.uniqueID == uid }) { Text("Selected microphone unavailable").tag(uid) }
        }.pickerStyle(.inline)
        } label: {
          Text(recorder.microphoneName).fixedSize(horizontal: false, vertical: true)
        }.accessibilityLabel("Recording microphone").accessibilityValue(recorder.microphoneName).help(recorder.microphoneName).disabled(recorder.isRecording || recorder.isBusy)

        Button(recorder.isTestingInput ? "Stop test" : "Test recording microphone") {
          if recorder.isTestingInput { recorder.stopInputTest() } else { Task { await recorder.startInputTest() } }
        }.disabled(recorder.isRecording || recorder.isBusy)
        if recorder.isTestingInput || recorder.isRecording { RecordingInputLevel(meter: recorder.inputMeter) }
        Toggle("32-bit float audio", isOn: $recorder.floatAudio).disabled(recorder.isRecording || recorder.isBusy)
        Text("Uncompressed sound gives more room for volume changes in an editor. It cannot repair distortion at the microphone.").font(.callout)
      }
  }
}

struct RecordingSettingsPanel: View {
  var includesMicrophone = true
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  var zoom = 1.0
  var body: some View {
    Form {
      CameraSettingsSections(model: camera, zoom: zoom)
      RecordingSettingsSections(recorder: recorder, camera: camera, zoom: zoom)
      RecordingFolderSection(recorder: recorder)
    }.formStyle(.grouped)
  }
}

struct RecordingSettingsSections: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  var zoom = 1.0
  var body: some View {
    Section("Recording setup") {
      Text(recorder.outputSummary(camera: camera)).font(.callout)
      if zoom >= 1.5 {
        VStack(alignment: .leading, spacing: Space.xs) {
          Text("Recording format")
          Menu {
            Picker("Recording format", selection: $recorder.preset) {
              ForEach(RecordingPreset.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.inline)
          } label: { Text(recorder.preset.label).fixedSize(horizontal: false, vertical: true) }
            .accessibilityLabel("Recording format").accessibilityValue(recorder.preset.label)
        }
      } else {
        Picker("Recording format", selection: $recorder.preset) {
          ForEach(RecordingPreset.allCases, id: \.self) { Text($0.label).tag($0) }
        }
      }
      Toggle("Mirror saved video", isOn: $recorder.mirrorSavedVideo)
      TextField("Take name", text: $recorder.takeLabel)
    }.disabled(recorder.settingsLocked).help("Stop recording to change this")
  }
}
struct RecordingFolderSection: View {
  @ObservedObject var recorder: CameraRecorder
  var body: some View {
    Section("Recordings") {
      Button("Show Recordings Folder") { recorder.openRecordingsFolder() }
      if let file = recorder.lastFile { Button("Show Last Take in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
    }
  }
}

struct RecordingInputLevel: View {
  @ObservedObject var meter: InputMeter
  var compact = false
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(compact
          ? (!meter.isFresh() ? "No recent audio. Check microphone." : meter.isClipping ? "Too loud. Lower microphone level." : meter.peakDBFS < -60 ? "Quiet or silent. Check microphone." : "Receiving recording audio")
          : (!meter.isFresh() ? "Waiting for audio samples. Check the microphone connection." : meter.isClipping ? "Sound too loud. Lower the microphone level." : meter.peakDBFS < -60 ? "Very quiet or silent. Speak to check the level." : "Receiving recording audio"))
        if !compact, let at = meter.lastSampleAt {
          Text(String(format: "Last sample %.1f seconds ago", max(0, ProcessInfo.processInfo.systemUptime - at))).monospacedDigit()
        }
        ForEach(Array(meter.channelPeaks.enumerated()), id: \.offset) { index, peak in
          HStack {
            Text("Ch \(index + 1)")
            Text(peak > 0 && meter.isFresh() ? String(format: "%.1f dBFS", AudioCapture.decibels(fullScalePeak: peak)) : "Silent").monospacedDigit()
            if compact {
              let fraction = meter.isFresh() ? max(0, min(1, (Double(AudioCapture.decibels(fullScalePeak: peak)) + 60) / 60)) : 0
              ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.2))
                Capsule().fill(peak >= 0.99 ? Color.red : Color.green).frame(width: 120 * fraction)
              }.frame(width: 120, height: 8)
                .accessibilityLabel("Recording channel \(index + 1) level")
                .accessibilityValue(meter.isFresh() ? "\(Int(fraction * 100)) percent" : "No recent audio")
            } else {
              InputLevelMeter(peakDBFS: meter.isFresh() ? AudioCapture.decibels(fullScalePeak: peak) : -.infinity, isClipping: peak >= 0.99)
            }
          }
        }
      }.font(.callout)
    }
  }
}

struct CameraExposureSettings: View {
  @ObservedObject var model: CameraModel
  var body: some View { Form { CameraExposureSections(model: model) }.formStyle(.grouped) }
}

struct ExposureToggle: View {
  enum Kind { case zebras, falseColour }
  @ObservedObject var model: CameraModel
  let kind: Kind
  var compact = false
  private var on: Bool { kind == .zebras ? model.guides.zebras : model.guides.falseColour }
  private var title: String { kind == .zebras ? "Zebras" : "False colour" }
  var body: some View {
    Button {
      if kind == .zebras { model.guides.zebras.toggle() } else { model.guides.falseColour.toggle() }
    } label: {
      if compact {
        if kind == .falseColour { VStack(spacing: 0) { Text("False"); Text("colour") }.fixedSize() }
        else { Text(title).fixedSize() }
      } else { Label(title, systemImage: kind == .zebras ? "circle.lefthalf.striped.horizontal" : on ? "paintpalette.fill" : "paintpalette") }
    }.tint(on ? Color.accentColor : nil).accessibilityLabel(title).accessibilityValue(on ? "On" : "Off")
  }
}

struct CameraExposureSections: View {
  @ObservedObject var model: CameraModel
  var body: some View {
    Section("Exposure") {
      Text("Adjust brightness on your camera. Use Zebras to check bright areas, or False colour to see brightness colours.").font(.callout)
      Toggle("Zebras", isOn: $model.guides.zebras)
      Toggle("False colour", isOn: $model.guides.falseColour)
      Picker("Zebras show", selection: Binding(get: { model.guides.validatedZebraPurpose }, set: { model.guides.useZebraPreset($0) })) {
        ForEach(CameraGuides.ZebraPurpose.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      ExposureGuidance(zebras: true, guides: model.guides, falseColour: true)
      Text("Exposure aids only change this preview. Adjust exposure on your camera.").font(.callout).foregroundStyle(.primary)
      DisclosureGroup("Custom levels") {
        Stepper("Level: \(model.guides.zebraLevel) IRE", value: $model.guides.zebraLevel, in: 0...100)
        Stepper("Range: ±\(model.guides.zebraRange) IRE", value: $model.guides.zebraRange, in: 0...10)
      }
      DisclosureGroup("How exposure aids work") {
        Text("For a standard video feed, a lit face usually sits between about 40 IRE for deeper skin and 65 IRE for lighter skin. Face reference starts at 45 ± 5; adjust it to your skin. Camera profiles vary, so use it as a reference.")
        Text("Bright-area zebras warn where detail may wash out. False colour compares the brightness of different areas.")
        Text("These colours and zebras measure the brightness of the feed received by your Mac. They do not change the saved video. The right levels depend on your camera and picture profile.")
      }.font(.callout)
    }
  }
}

extension CameraModel {
  var isReadyToRecord: Bool {
    if let recordingReadyOverride { return recordingReadyOverride }
    return authorization == .authorized && selectedUID != nil && unavailableMessage == nil
      && SharedCameraSession.shared.attachedUID == selectedUID && SharedCameraSession.shared.session.isRunning
  }
}

extension CameraRecorder {
  func outputSummary(camera: CameraModel) -> String {
    let codec = preset == .standard ? "H.264" : preset == .high ? "HEVC" : "ProRes 422"
    var parts: [String] = []
    if let uid = camera.selectedUID, let device = AVCaptureDevice(uniqueID: uid) {
      let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
      let rotated = camera.guides.rotation.swapsAxes
      parts.append("\(rotated ? size.height : size.width) × \(rotated ? size.width : size.height)")
      let duration = device.activeVideoMinFrameDuration.seconds
      if duration.isFinite && duration > 0 { parts.append(String(format: "%.2f fps", 1 / duration)) }
    }
    parts.append("\(camera.guides.rotation.label) saved rotation")
    parts.append(codec)
    parts.append(mirrorSavedVideo ? "mirrored output" : "unmirrored output")
    parts.append(camera.guides.marker.map { "\($0.label) guide only; full frame saved" } ?? "full frame")
    if let free = try? Self.recordingsFolder().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
      parts.append(String(format: "%.1f GB free", Double(free) / 1_000_000_000))
    }
    return parts.joined(separator: " · ")
  }
}

enum RecordingHealth: Equatable {
  case receiving, silence, clipping
  static func state(clipping: Bool, fresh: Bool) -> Self { clipping ? .clipping : fresh ? .receiving : .silence }
  var message: String {
    switch self {
    case .receiving: "Receiving sound"
    case .silence: "No sound for 3 seconds. Check the microphone."
    case .clipping: "Too loud. Lower the microphone level."
    }
  }
}

struct RecordingAudioHealth: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject private var meter: InputMeter
  @State private var beganAt = ProcessInfo.processInfo.systemUptime
  @State private var previousHealth = RecordingHealth.receiving
  @State private var lastWarningAt = -Double.infinity
  init(recorder: CameraRecorder) { self.recorder = recorder; meter = recorder.inputMeter }
  nonisolated static func message(drops: Int, clipping: Bool, fresh: Bool) -> String {
    if drops > 0 { return "Sound dropped from the file (\(drops) times)" }
    return RecordingHealth.state(clipping: clipping, fresh: fresh).message
  }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      let fresh = ProcessInfo.processInfo.systemUptime - (meter.lastAudibleSampleAt ?? beganAt) < 3
      let health = RecordingHealth.state(clipping: meter.isClipping && meter.isFresh(), fresh: fresh)
      VStack(alignment: .leading, spacing: Space.xs) {
        HStack(spacing: Space.sm) {
          Text("Mic: \(recorder.microphoneName)").lineLimit(2).help(recorder.microphoneName)
            .fixedSize(horizontal: false, vertical: true)
          InputLevelMeter(peakDBFS: meter.isFresh() ? meter.peakDBFS : -.infinity, isClipping: meter.isClipping, showsScale: false)
            .frame(minWidth: 40, maxWidth: 100)
        }
        if recorder.droppedAudioBuffers > 0 || health != .receiving {
          Label(Self.message(drops: recorder.droppedAudioBuffers, clipping: health == .clipping, fresh: fresh), systemImage: "exclamationmark.triangle.fill").fontWeight(.semibold)
            .fixedSize(horizontal: false, vertical: true)
        }
        if recorder.droppedFrames > 0 {
          Label("Video frames dropped (\(recorder.droppedFrames)). The picture may stutter.", systemImage: "exclamationmark.triangle.fill")
            .fixedSize(horizontal: false, vertical: true)
        }
      }.font(.callout)
        .onChange(of: health) { _, value in
          guard recorder.isRecording, value != previousHealth else { return }
          previousHealth = value
          let now = ProcessInfo.processInfo.systemUptime
          if value != .receiving {
            guard now - lastWarningAt >= 5 else { return }
            lastWarningAt = now
          }
          NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: value.message, .priority: (value == .receiving ? NSAccessibilityPriorityLevel.medium : .high).rawValue])
        }
    }
  }
}

struct RecordingReceipt: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel = .shared
  var configure: (() -> Void)? = nil
  var zoom = 1.0
  @State private var recoverySettings = false
  var body: some View {
    if recorder.savedTake != nil || recorder.takeFailure != nil {
      VStack(alignment: .leading, spacing: Space.sm) {
        if let file = recorder.savedTake {
          Label(recorder.qualityWarning == nil ? (zoom >= 1.5 ? "Saved" : "Saved \(file.lastPathComponent)") : (zoom >= 1.5 ? "Saved with problems" : "Saved with problems: \(file.lastPathComponent)"),
            systemImage: recorder.qualityWarning == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true).help(file.path)
          if let warning = recorder.qualityWarning { Text(warning).font(.callout).fixedSize(horizontal: false, vertical: true) }
          if zoom >= 1.5 {
            DisclosureGroup("Take details") { Text(file.lastPathComponent).font(.callout).textSelection(.enabled) }
          }
          WrapLayout(spacing: Space.sm) {
            Button("Play") { NSWorkspace.shared.open(file) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            if recorder.qualityWarning != nil { Button("Try recording again") { Task { await recorder.start(camera: camera) } } }
            Button("Hide") { recorder.savedTake = nil }
          }
        } else if let failure = recorder.takeFailure {
          Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).fixedSize(horizontal: false, vertical: true)
          if let file = recorder.incompleteTake {
            Button("Show incomplete take in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
          }
          RecordingRecoveryActions(recorder: recorder, camera: camera) {
            if let configure { configure() } else { recoverySettings = true }
          }.popover(isPresented: $recoverySettings) {
            PresenterSettingsPopover(store: AppStore.shared, initialTab: recorder.recovery == .microphone ? .microphone : .camera)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md).modifier(PresenterGlass(radius: 12)).environment(\.colorScheme, .dark)
    }
  }
}

struct RecordingStatusPanel: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  var zoom = 1.0
  var dismiss: () -> Void
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.sm) {
        if recorder.phase != .idle {
          WrapLayout(spacing: Space.sm) {
            PresenterRecordButton(recorder: recorder, camera: camera, compact: zoom >= 1.5)
          }
          RecordingAudioHealth(recorder: recorder)
        } else {
          RecordingReceipt(recorder: recorder, camera: camera, zoom: zoom)
          if recorder.savedTake == nil && recorder.takeFailure == nil { Text("No completed take was saved.") }
          Button("Close", action: dismiss)
        }
      }.padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
    }.uiZoom(zoom)
  }
}
