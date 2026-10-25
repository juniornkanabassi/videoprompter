@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// A video device as the picker shows it. `uid` is `AVCaptureDevice.uniqueID`, which is what
/// gets remembered: names repeat across identical cameras, unique IDs do not.
struct CameraDevice: Identifiable, Hashable, Sendable {
  let uid: String
  let name: String
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
  @Published var selectedUID: String? {
    didSet {
      defaults.set(selectedUID, forKey: "cameraDeviceUID")
      guard selectedUID != oldValue else { return }
      loadingGuides = true
      guides = guideStore.guides(for: selectedUID)
      loadingGuides = false
    }
  }
  /// Rotation, framing guides and the frame marker, remembered for each camera in turn.
  @Published var guides = CameraGuides() {
    didSet { if !loadingGuides { guideStore.set(guides, for: selectedUID) } }
  }
  @Published var mirrored: Bool { didSet { defaults.set(mirrored, forKey: "cameraMirrored") } }
  @Published var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: "cameraAlwaysOnTop") } }
  /// Script only, script over the live picture, or the live picture alone. The presenter's own
  /// controls are unaffected. The old Bool key is still written, so an older build reads it too.
  @Published var displayMode: PresenterDisplayMode {
    didSet {
      defaults.set(displayMode.rawValue, forKey: "presenterDisplayMode")
      defaults.set(displayMode != .prompterOnly, forKey: "presenterWithVideo")
    }
  }
  /// Whether the picture is shown at all: the capsule button, the menu and the camera ask this.
  var presentsWithVideo: Bool {
    get { displayMode != .prompterOnly }
    set { if newValue != presentsWithVideo { displayMode = newValue ? .prompterWithVideo : .prompterOnly } }
  }
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
    selectedUID = uid
    guides = guideStore.guides(for: uid)
    mirrored = defaults.bool(forKey: "cameraMirrored")
    alwaysOnTop = defaults.bool(forKey: "cameraAlwaysOnTop")
    displayMode = defaults.string(forKey: "presenterDisplayMode").flatMap(PresenterDisplayMode.init)
      ?? (defaults.bool(forKey: "presenterWithVideo") ? .prompterWithVideo : .prompterOnly)
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  /// A rotation chosen by hand turns Auto back off; one Vision picked leaves it on.
  func setRotation(_ rotation: CameraRotation, automatic: Bool = false) {
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
    ).devices.map { CameraDevice(uid: $0.uniqueID, name: $0.localizedName) }
  }

  /// Keep the remembered camera when it is still plugged in, otherwise take whatever is.
  static func resolve(_ savedUID: String?, in devices: [CameraDevice]) -> CameraDevice? {
    devices.first { $0.uid == savedUID } ?? devices.first
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

  func refresh() {
    devices = Self.discovered()
    let resolved = Self.resolve(selectedUID, in: devices)?.uid
    if resolved != selectedUID { selectedUID = resolved }
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
    view.apply(uid: model.selectedUID, guides: model.guides, mirrored: model.mirrored)
  }
  static func dismantleNSView(_ view: CameraStageView, coordinator: ()) { view.stop() }
}

struct CameraView: View {
  @ObservedObject private var model = CameraModel.shared
  @State private var showsGuideSettings = false
  @ObservedObject private var recorder = CameraRecorder.shared
  var body: some View {
    Group {
      switch model.authorization {
      case .denied, .restricted:
        VStack(spacing: 12) {
          Text("Video Prompter does not have permission to use the camera.")
          Button("Open System Settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
          }
        }.padding()
      default:
        if model.devices.isEmpty {
          ContentUnavailableView("Connect a camera", systemImage: "video",
            description: Text("Connect a USB camera or enable iPhone Continuity Camera, then choose it above. Check camera access in System Settings → Privacy & Security → Camera."))
        } else {
          CameraPreview(model: model).background(.black)
        }
      }
    }
    .frame(minWidth: 320, minHeight: 200)
    .task { model.start() }
    .onDisappear { Task { await recorder.stop() } }
    .onChange(of: model.selectedUID) { _, _ in Task { await recorder.stop() } }
    .background(CameraWindowLevel(alwaysOnTop: model.alwaysOnTop))
    .toolbar {
      CameraChoiceItems(model: model, rotation: model.rotationChoice, recording: recorder.isRecording || recorder.isBusy)
      ToolbarItemGroup { RecordingControls(recorder: recorder, camera: model) }
      ToolbarItem {
        Menu {
          Toggle("Mirror Camera", isOn: $model.mirrored).help("Flip the camera picture left to right")
          Button("Framing Guides…") { showsGuideSettings = true }
            .help("Choose composition lines and an output frame marker")
          Toggle("Always on Top", isOn: $model.alwaysOnTop).help("Keep the Camera window above other windows")
        } label: { Label("Options", systemImage: "ellipsis.circle") }
          .accessibilityLabel("Options").help("Camera mirroring, framing guides and window position")
          .popover(isPresented: $showsGuideSettings, arrowEdge: .bottom) {
            CameraGuideSettings(model: model).frame(width: 300).padding()
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
      ToolbarPopUp(title: "Camera rotation", help: "Rotate the camera picture, or choose Automatic", options: CameraModel.rotationOptions, selection: $rotation)
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
    Form {
      Section("Camera") {
        LabeledContent("Camera") { CameraPicker(model: model, zoom: zoom) }
          .help("Choose the camera shown behind your script")
        Picker("Rotation", selection: model.rotationChoice) {
          ForEach(CameraModel.rotationOptions, id: \.0) { Text($0.0).tag($0.1) }
        }.help("Rotate the camera picture, or choose Automatic")
        Toggle("Mirror camera", isOn: $model.mirrored).help("Flip the camera picture left to right")
      }
      CameraGuideSections(model: model)
    }.formStyle(.grouped).task { model.start() }
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
        LabeledContent("Guide visibility") { Slider(value: $model.guides.opacity, in: 0...1).accessibilityLabel("Guide visibility") }.help("Fade the guides; zero hides them")
      }
      Section("Frame marker") {
        Picker("Frame shape", selection: $model.guides.marker) {
          Text("Off").tag(nil as CameraAspect?)
          ForEach(CameraAspect.presets) { Text($0.label).tag(Optional($0)) }
          Text("Custom").tag(Optional(custom))
        }.help("Mark the shape of your intended output without cropping the recording")
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
          LabeledContent("Shade outside") { Slider(value: $model.guides.shadeOpacity, in: 0...1).accessibilityLabel("Shade outside") }.help("Darken the area outside the frame marker")
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
  func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
  func updateNSView(_ view: NSView, context: Context) {
    view.window?.level = alwaysOnTop ? .floating : .normal
  }
}

struct RecordingControls: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  @State private var settings = false
  var body: some View {
    Group {
      Button {
        Task { if recorder.isRecording { await recorder.stop() } else { await recorder.start(camera: camera) } }
      } label: {
        Label(recorder.isRecording ? "Stop" : "Record", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
          .foregroundStyle(.red)
      }.disabled(recorder.isBusy).help(recorder.isRecording ? "Finish and save this camera recording" : "Record the selected camera and microphone")
      if let started = recorder.startedAt {
        TimelineView(.periodic(from: started, by: 1)) { context in
          let seconds = max(0, Int(context.date.timeIntervalSince(started)))
          Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
        }
      }
      Button("Recording settings", systemImage: "slider.horizontal.3") { settings.toggle() }.accessibilityLabel("Recording settings").help("Choose recording quality, microphone and audio format")
        .popover(isPresented: $settings) {
          Form {
            Picker("Recording quality", selection: $recorder.preset) {
              ForEach(RecordingPreset.allCases, id: \.self) { Text($0.label).tag($0) }
            }.disabled(recorder.isRecording || recorder.isBusy).help("Standard is widely compatible; High compresses more efficiently; Edit makes larger files for video editing")
            Text("Standard (H.264) works with most players and editors. High (HEVC) compresses video more efficiently but needs compatible software. Edit (ProRes 422) makes larger files designed for video editing.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Microphone", selection: Binding(get: { recorder.microphoneUID ?? "" }, set: { recorder.microphoneUID = $0.isEmpty ? nil : $0 })) {
              Text("Default microphone").tag("")
              ForEach(CameraRecorder.microphones(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
              if let uid = recorder.microphoneUID, !CameraRecorder.microphones().contains(where: { $0.uniqueID == uid }) { Text("Selected microphone unavailable").tag(uid) }
            }.disabled(recorder.isRecording || recorder.isBusy).help("Choose the microphone recorded with the camera")
            Toggle("32-bit float audio", isOn: $recorder.floatAudio).disabled(recorder.isRecording || recorder.isBusy).help("Save uncompressed sound for adjusting volume in an editor; audio takes more space")
            Text("Saves uncompressed sound for adjusting volume in an editor. Audio takes more space. Leave off for smaller files. This cannot repair sound distorted by the microphone.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let file = recorder.lastFile { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.help("Find your latest saved recording") }
            if let error = recorder.errorMessage { Text(error).foregroundStyle(.red) }
          }.padding().frame(width: 380)
        }
    }.alert("Recording", isPresented: Binding(get: { recorder.errorMessage != nil && !settings }, set: { if !$0 { recorder.errorMessage = nil } })) {
      Button("OK") { recorder.errorMessage = nil }
    } message: { Text(recorder.errorMessage ?? "") }
  }
}
