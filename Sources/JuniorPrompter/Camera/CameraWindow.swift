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

@MainActor final class CameraModel: ObservableObject {
  /// One model for the Camera window, the Camera menu and the presenter's video background:
  /// they show the same camera with the same rotation and the same guides.
  static let shared = CameraModel()
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
  /// Whether the presenter shows the script over the live picture rather than over its own
  /// background. The presenter's own controls are unaffected either way.
  @Published var presentsWithVideo: Bool {
    didSet { defaults.set(presentsWithVideo, forKey: "presenterWithVideo") }
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
    presentsWithVideo = defaults.bool(forKey: "presenterWithVideo")
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  /// A rotation chosen by hand turns Auto back off; one Vision picked leaves it on.
  func setRotation(_ rotation: CameraRotation, automatic: Bool = false) {
    guard guides.rotation != rotation || guides.automaticRotation == automatic else { return }
    if automatic {
      guard guides.automaticRotation else { return }
      guides.rotation = rotation
    } else {
      guides.rotation = rotation
      guides.automaticRotation = false
    }
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
    [("Auto", nil)] + CameraRotation.allCases.map { ($0.label, Optional($0)) }

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
  /// The presenter keeps the camera's own composition guides off unless they are asked for.
  var showsGuides = true
  func makeNSView(context: Context) -> CameraStageView { CameraStageView(frame: .zero) }
  func updateNSView(_ view: CameraStageView, context: Context) {
    var guides = model.guides
    if !showsGuides {
      guides.thirds = false
      guides.axes = false
      guides.bullseye = false
      guides.marker = nil
    }
    view.apply(uid: model.selectedUID, guides: guides, mirrored: model.mirrored)
  }
  static func dismantleNSView(_ view: CameraStageView, coordinator: ()) { view.stop() }
}

struct CameraView: View {
  @ObservedObject private var model = CameraModel.shared
  @State private var showsGuideSettings = false
  var body: some View {
    Group {
      switch model.authorization {
      case .denied, .restricted:
        VStack(spacing: 12) {
          Text("JuniorPrompter does not have permission to use the camera.")
          Button("Open System Settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
          }
        }.padding()
      default:
        if model.devices.isEmpty {
          Text("No camera found.").foregroundStyle(.secondary)
        } else {
          CameraPreview(model: model).background(.black)
        }
      }
    }
    .frame(minWidth: 320, minHeight: 200)
    .task { model.start() }
    .background(CameraWindowLevel(alwaysOnTop: model.alwaysOnTop))
    .toolbar {
      CameraChoiceItems(model: model, rotation: model.rotationChoice)
      ToolbarItem {
        Toggle("Mirror Camera", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: $model.mirrored)
          .help("Mirror camera")
      }
      ToolbarItem {
        Button("Guides", systemImage: "grid") { showsGuideSettings.toggle() }
          .help("Guides and frame marker")
          .popover(isPresented: $showsGuideSettings, arrowEdge: .bottom) {
            CameraGuideSettings(model: model).frame(width: 300).padding()
          }
      }
      ToolbarItem {
        Toggle("Always on Top", systemImage: "pin", isOn: $model.alwaysOnTop)
          .help("Keep the Camera window above other windows")
      }
    }
  }
}

/// The Camera window's camera and rotation pop-ups.
struct CameraChoiceItems: ToolbarContent {
  @ObservedObject var model: CameraModel
  @Binding var rotation: CameraRotation?
  var body: some ToolbarContent {
    // The picker previews each camera on hover, so choosing one is never blind.
    ToolbarItem { CameraPicker(model: model) }
    ToolbarItem {
      ToolbarPopUp(title: "Rotation", options: CameraModel.rotationOptions, selection: $rotation)
    }
  }
}

/// A toolbar pop-up that always shows its selection. SwiftUI's `Picker` drew blank in this
/// toolbar; AppKit's pop-up is re-synced on every update, so a camera list that arrives after the
/// window opens still shows the chosen name.
struct ToolbarPopUp<Value: Hashable>: NSViewRepresentable {
  let title: String
  let options: [(String, Value)]
  @Binding var selection: Value
  var placeholder = "None"

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSPopUpButton {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.setAccessibilityLabel(title)
    popup.toolTip = title
    return popup
  }
  func updateNSView(_ popup: NSPopUpButton, context: Context) {
    let values = options.map(\.1)
    let selection = $selection
    context.coordinator.onChoose = { index in
      if values.indices.contains(index) { selection.wrappedValue = values[index] }
    }
    Self.sync(popup, titles: options.map(\.0), selected: values.firstIndex(of: self.selection),
              placeholder: placeholder, target: context.coordinator)
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
  @State private var customWidth = 2.39
  @State private var customHeight = 1.0
  var body: some View {
    Form {
      Section("Guides") {
        Toggle("Rule of thirds", isOn: $model.guides.thirds)
        Toggle("Centre axes", isOn: $model.guides.axes)
        Toggle("Centre bullseye", isOn: $model.guides.bullseye)
        ColorPicker("Colour", selection: guideColor, supportsOpacity: false)
        LabeledContent("Opacity") { Slider(value: $model.guides.opacity, in: 0...1) }
      }
      Section("Frame marker") {
        Picker("Aspect ratio", selection: marker) {
          Text("Off").tag(nil as CameraAspect?)
          ForEach(CameraAspect.presets) { Text($0.label).tag(Optional($0)) }
          Text("Custom").tag(Optional(custom))
        }
        if let value = model.guides.marker, !CameraAspect.presets.contains(value) {
          HStack {
            TextField("Width", value: $customWidth, format: .number).frame(width: 64)
            Text(":")
            TextField("Height", value: $customHeight, format: .number).frame(width: 64)
          }
          .onChange(of: customWidth) { _, _ in model.guides.marker = custom }
          .onChange(of: customHeight) { _, _ in model.guides.marker = custom }
        }
        if model.guides.marker != nil {
          LabeledContent("Shade outside") { Slider(value: $model.guides.shadeOpacity, in: 0...1) }
        }
      }
    }.formStyle(.grouped)
  }
  private var custom: CameraAspect { CameraAspect(width: customWidth, height: customHeight) }
  private var marker: Binding<CameraAspect?> {
    Binding(get: { model.guides.marker }, set: { model.guides.marker = $0 })
  }
  private var guideColor: Binding<Color> {
    Binding(get: guideColorValue, set: setGuideColor)
  }
  private func guideColorValue() -> Color {
    guard let cgColor = CameraGuides.color(model.guides.colorHex, alpha: 1) else { return .blue }
    return Color(nsColor: NSColor(cgColor: cgColor) ?? .systemBlue)
  }
  private func setGuideColor(_ color: Color) {
    let rgb: NSColor = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
    let red = Int((rgb.redComponent * 255).rounded())
    let green = Int((rgb.greenComponent * 255).rounded())
    let blue = Int((rgb.blueComponent * 255).rounded())
    model.guides.colorHex = String(format: "#%02X%02X%02X", red, green, blue)
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
