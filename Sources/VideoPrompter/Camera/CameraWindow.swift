@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct CameraPreview: NSViewRepresentable {
  @ObservedObject var model: CameraModel
  var presenter = false
  func makeNSView(context: Context) -> CameraStageView { CameraStageView(frame: .zero) }
  func updateNSView(_ view: CameraStageView, context: Context) {
    view.apply(uid: model.selectedUID, guides: presenter ? model.previewGuides : model.monitorGuides, mirrored: model.mirrored)
  }
  static func dismantleNSView(_ view: CameraStageView, coordinator: ()) { view.stop() }
}

struct CameraView: View {
  @State private var showsCameraPicker = false
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
    CameraPreview(model: model).background(.black)
    .overlay {
      if model.needsRecovery {
        CameraRecoveryView(model: model) { showsCameraPicker = true }.uiZoom(zoom)
          .popover(isPresented: $showsCameraPicker) {
            CameraPickerList(model: model, zoom: zoom) { showsCameraPicker = false }.uiZoom(zoom)
          }
      }
    }
    .overlay(alignment: .topTrailing) { ExposureLegend(model: model, respectsPresenterCleanView: false).padding(Space.sm).uiZoom(zoom) }
    .popover(isPresented: $showsExposureSettings) { CameraExposureSettings(model: model, presenter: false).frame(width: 360, height: 500).uiZoom(zoom) }
    .frame(minWidth: 320, minHeight: 200)
    .task { if startsCamera { model.start() } }

    .background(CameraWindowLevel(alwaysOnTop: model.alwaysOnTop))
    .toolbar {
      CameraChoiceItems(model: model, rotation: model.rotationChoice, recording: recorder.isRecording || recorder.isBusy)
      ToolbarItemGroup { ExposureToggle(model: model, kind: .zebras, presenter: false); ExposureToggle(model: model, kind: .falseColour, presenter: false) }
      ToolbarItem {
        Button("Framing Guides", systemImage: "grid") { showsGuideSettings = true }
          .help("Choose which framing lines to show")
          .restoringPopoverFocus(isPresented: $showsGuideSettings, identifier: "monitor-guides")
          .popover(isPresented: $showsGuideSettings) {
            CameraGuideSettings(model: model).frame(width: 340, height: 480).uiZoom(zoom).popoverEntryFocus()
          }
      }
      ToolbarItem {
        Button("Exposure Settings", systemImage: "sun.max") { showsExposureSettings = true }.help("Choose zebras, false colour and their levels")
      }
      ToolbarItemGroup { RecordingControls(recorder: recorder, camera: model, zoom: zoom) }
      ToolbarItem {
        Menu {
          Toggle("Mirror Camera Preview", isOn: $model.mirrored).help("Flip only the monitor picture. Saved video has its own mirroring setting.")
          Button("Camera & Recording Settings…") { AppSettingsView.requestTab(.camera); openSettings() }
          Toggle("Always on Top", isOn: $model.alwaysOnTop).help("Keep the Second monitor window above other windows")
        } label: { Label("Options", systemImage: "ellipsis.circle") }
          .accessibilityLabel("Options").help("Mirror the preview, open camera settings or keep the window on top")

      }
    }
  }
}

/// The Second monitor window's camera and rotation pop-ups.
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
struct CameraSettingsSections: View {
  @ObservedObject var model: CameraModel
  var zoom = 1.0
  var body: some View {
    Section {
      LabeledContent("Camera") { CameraPicker(model: model, zoom: zoom) }
        .disabled(model.recordingLocked).help("Stop recording to change this")
      Picker("Camera and saved-video rotation", selection: model.rotationChoice) {
        ForEach(CameraModel.rotationOptions, id: \.0) { Text($0.0).tag($0.1) }
      }.disabled(model.recordingLocked).help("Stop recording to change this")
      if model.guides.automaticRotation { Text("Detected angle: \(model.guides.rotation.label)").font(.callout) }
      Toggle("Mirror camera preview", isOn: $model.mirrored)
    } header: { Text("Device") } footer: { Text("Rotation changes both the camera preview and the saved take.").font(.callout) }
  }
}

/// The guide and frame marker sections, shared by both panels above.
struct CameraGuideSections: View {
  @ObservedObject var model: CameraModel
  @State private var editingCustom = false
  @State private var invalidDimension = false
  private var shape: Binding<String> {
    Binding(get: {
      guard let marker = model.guides.marker else { return "Off" }
      return editingCustom || !CameraAspect.presets.contains(marker) ? "Custom" : marker.label
    }, set: { choice in
      editingCustom = choice == "Custom"
      invalidDimension = false
      if choice == "Off" { model.guides.marker = nil }
      else if choice == "Custom" { model.guides.marker = model.guides.marker ?? CameraAspect(width: 2.39, height: 1) }
      else { model.guides.marker = CameraAspect.presets.first { $0.label == choice } }
    })
  }
  private func updateMarker(width: Double, height: Double) {
    editingCustom = true
    let marker = CameraAspect(width: width, height: height)
    invalidDimension = !marker.isValid
    if marker.isValid { model.guides.marker = marker }
  }
  private var customWidth: Binding<Double> {
    Binding(get: { model.guides.marker?.width ?? 2.39 },
      set: { updateMarker(width: $0, height: model.guides.marker?.height ?? 1) })
  }
  private var customHeight: Binding<Double> {
    Binding(get: { model.guides.marker?.height ?? 1 },
      set: { updateMarker(width: model.guides.marker?.width ?? 2.39, height: $0) })
  }
  var body: some View {
    Group {
      Section("Framing guides") {
        Toggle("Rule of thirds", isOn: $model.guides.thirds).initialPopoverFocus().help("Divide the picture into thirds to help compose your shot")
        Toggle("Centre cross", isOn: $model.guides.axes).help("Mark the horizontal and vertical centre of the picture")
        Toggle("Centre target", isOn: $model.guides.bullseye).help("Mark the centre with a target")
        ColorPicker("Colour", selection: guideColor, supportsOpacity: false).help("Choose the colour of framing guides")
        LabeledContent("Guide visibility") { ReadingSlider(value: $model.guides.opacity, range: 0...1, title: "Guide visibility", spokenValue: "\(Int(model.guides.opacity * 100)) percent") }.help("Fade the guides; zero hides them")
      }
      Section("Frame marker") {
        Picker("Frame shape", selection: shape) {
          Text("Off").tag("Off")
          ForEach(CameraAspect.presets) { Text($0.label).tag($0.label) }
          Text("Custom").tag("Custom")
        }.help("Mark the shape of your intended output without cropping the recording")
        if let marker = model.guides.marker { Text("\(marker.label) guide only. The full frame is recorded.").font(.callout) }
        if shape.wrappedValue == "Custom" {
          HStack {
            VStack(alignment: .leading) {
              Text("Width").fixedSize()
              TextField("Width", value: customWidth, format: .number).labelsHidden()
                .help("Set the width part of the custom frame ratio")
            }.frame(minWidth: 80)
            Text(":")
            VStack(alignment: .leading) {
              Text("Height").fixedSize()
              TextField("Height", value: customHeight, format: .number).labelsHidden()
                .help("Set the height part of the custom frame ratio")
            }.frame(minWidth: 80)
          }
        }
        if invalidDimension {
          Text("Enter a width and height greater than 0 and no more than 100.").font(.callout)
        }
        if model.guides.marker != nil {
          LabeledContent("Shade outside") { ReadingSlider(value: $model.guides.shadeOpacity, range: 0...1, title: "Shade outside", spokenValue: "\(Int(model.guides.shadeOpacity * 100)) percent") }.help("Darken the area outside the frame marker")
        }
      }
    }
  }
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
  var showsStatus = true
  var defaultLabel = ""
  var secondary = false
  var body: some View {
    Group {
      if recorder.phase == .preparing || recorder.phase == .waitingForFrames {
        Button { Task { await recorder.stop() } } label: {
          Text(compact ? "Cancel" : "Cancel preparation")
        }.accessibilityLabel("Cancel preparation")
        if showsStatus { Text(recorder.phase == .waitingForFrames ? "Waiting for camera" : "Preparing…")
          .font(.callout).fixedSize(horizontal: false, vertical: true) }
      } else if recorder.isRecording {
        Button { Task { await recorder.stop() } } label: {
          if compact { Text("Stop recording").fixedSize(horizontal: false, vertical: true) }
          else { Label("Stop recording", systemImage: "stop.circle.fill") }
        }.accessibilityLabel("Stop recording")
          .buttonStyle(PresenterButtonStyle(prominent: true)).tint(.red)
        if showsStatus {
        let seconds = Int(recorder.recordedDuration)
        HStack(spacing: Space.xs) {
          Circle().fill(.red).frame(width: 8, height: 8)
          Text(String(format: "REC %02d:%02d", seconds / 60, seconds % 60)).monospacedDigit().font(.callout)
        }.accessibilityElement(children: .combine).layoutPriority(2)
        }
      } else if recorder.phase == .saving {
        Text("Saving…").font(.callout)
      } else {
        Button { Task { await recorder.start(camera: camera, defaultLabel: defaultLabel) } } label: {
          Label { Text("Record").fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "record.circle").foregroundStyle(.red) }
        }.accessibilityLabel("Record")
          .buttonStyle(PresenterButtonStyle()).disabled(!camera.isReadyToRecord)
          .help(camera.isReadyToRecord ? "Record a take. Reading starts separately." : camera.recordingBlockReason)
          .accessibilityHint(camera.isReadyToRecord ? "Reading starts separately" : camera.recordingBlockReason)
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
    if showsHealth && (recorder.isCapturing || recorder.phase == .saving) { RecordingAudioHealth(recorder: recorder) }
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
        Button("Allow Camera Access") { openPrivacy("Camera") }
      case .microphonePrivacy:
        Button("Allow Microphone Access") { openPrivacy("Microphone") }
      case .camera, .microphone:
        Button("Choose \(recorder.recovery == .camera ? "camera" : "microphone")") { configure() }
      case .format:
        Button("Change Recording Format") { configure() }
      case .storage:
        Button("Show Recordings Folder") { recorder.openRecordingsFolder() }
      case .retry:
        Button("Try Recording Again") { Task { await recorder.start(camera: camera, defaultLabel: recorder.takeDefaultLabel) } }
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

        Button(recorder.isTestingInput ? "Stop Test" : "Test Recording Microphone") {
          if recorder.isTestingInput { recorder.stopInputTest() } else { Task { await recorder.startInputTest() } }
        }.disabled(recorder.isRecording || recorder.isBusy)
        if recorder.isTestingInput || recorder.isRecording { RecordingInputLevel(meter: recorder.inputMeter) }
        Toggle("32-bit float audio", isOn: $recorder.floatAudio).disabled(recorder.isRecording || recorder.isBusy)
        Text("Uncompressed sound gives more room for volume changes in an editor. It cannot repair distortion at the microphone.").font(.callout)
      }
  }
}

struct RecordingSettingsSections: View {
  var defaultLabel = ""
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject var camera: CameraModel
  var zoom = 1.0
  var body: some View {
    Section {
      LabeledContent("Picture", value: recorder.compactOutputConfirmation(camera: camera))
      LabeledContent("Rotation", value: camera.guides.rotation.label)
      LabeledContent("Format", value: recorder.recordingFormatName)
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
      TextField("Take name", text: $recorder.takeLabel, prompt: Text("Take"))

    } header: { Text("Recording setup") } footer: {
      Text("Leave empty to use the script title. Next file: " + CameraRecorder.fileURL(in: CameraRecorder.recordingsFolder(), label: recorder.takeLabel, defaultLabel: defaultLabel).lastPathComponent).font(.callout)
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

/// The camera's next step belongs on its picture, in both camera surfaces.
struct CameraRecoveryView: View {
  @ObservedObject var model: CameraModel
  var chooseCamera: () -> Void
  var body: some View {
    VStack(spacing: Space.sm) {
      Label(title, systemImage: "video.slash").font(.headline)
      Text(message).font(.callout).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if model.authorization == .denied || model.authorization == .restricted {
        Button("Allow Camera in System Settings") {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
        }.initialPopoverFocus()
      } else if model.authorization == .notDetermined {
        Button("Allow Camera Access") { model.start() }.initialPopoverFocus()
      } else { Button("Choose Camera", action: chooseCamera).initialPopoverFocus() }
    }.foregroundStyle(.white).padding(Space.md)
      .background(Surfaces.scrim, in: RoundedRectangle(cornerRadius: 12))
      .frame(maxWidth: 420).accessibilityIdentifier("camera-recovery")
  }
  private var title: String {
    if model.authorization == .denied || model.authorization == .restricted { return "Camera access is off" }
    if model.authorization == .notDetermined { return "Allow your camera" }
    return model.selectedUID == nil ? "Connect a camera" : "Camera picture unavailable"
  }
  private var message: String {
    if model.authorization == .denied || model.authorization == .restricted {
      return "Allow Video Prompter in System Settings > Privacy & Security > Camera."
    }
    if model.authorization == .notDetermined { return "Allow camera access to see your picture. Reading does not record a video." }
    let name = model.devices.first { $0.uid == model.selectedUID }?.displayName
    return name.map { "Check \($0) is connected and switched on, then choose your camera." }
      ?? "Connect and switch on your camera, then choose it here."
  }
}

/// A bounded, named notice keeps the next action readable even at 200%.
struct RecordingHealthNotice: View {
  @ObservedObject var recorder: CameraRecorder
  var zoom = 1.0
  var compact = false
  @State private var showsDetails = false
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      let health = RecordingHealth.measured(lastAudibleSampleAt: recorder.inputMeter.lastAudibleSampleAt,
        clipping: recorder.inputMeter.isClipping && recorder.inputMeter.isFresh())
      let warning = recorder.droppedAudioBuffers > 0 || recorder.droppedFrames > 0 || health == .clipping || health == .silence
      Button { showsDetails = true } label: {
        Text(recorder.droppedFrames > 0 ? "Check recording" : warning ? "Check microphone" : health == .waiting ? "Waiting for sound" : "Receiving sound")
          .font(.callout).fixedSize().frame(minHeight: 24)
      }.buttonStyle(.plain)
        .accessibilityValue(recorder.droppedAudioBuffers > 0 ? "Sound dropped from the file (\(recorder.droppedAudioBuffers) times)" : health.message)
        .restoringPopoverFocus(isPresented: $showsDetails, identifier: "recording-health")
        .popover(isPresented: $showsDetails) {
          VStack(alignment: .leading, spacing: Space.md) {
            RecordingAudioHealth(recorder: recorder)
            Text("Check the microphone connection and input level. Stop recording before changing the recording microphone.")
              .initialPopoverFocus().font(.callout).fixedSize(horizontal: false, vertical: true)
          }.padding(Space.md).frame(width: 320).uiZoom(zoom).popoverEntryFocus()
        }
    }
  }
}

struct CameraExposureSettings: View {
  @ObservedObject var model: CameraModel
  var presenter = true
  var body: some View { Form { CameraExposureSections(model: model, presenter: presenter) }.formStyle(.grouped) }
}

struct ExposureToggle: View {
  enum Kind { case zebras, falseColour }
  @ObservedObject var model: CameraModel
  let kind: Kind
  var presenter = true
  private var binding: Binding<Bool> { model.exposureBinding(kind == .zebras ? \.zebras : \.falseColour, presenter: presenter) }
  private var on: Bool { binding.wrappedValue }
  private var title: String {
    let title = kind == .zebras ? ExposureLegend.zebraTitle(for: model.guides.validatedZebraPurpose) : "Check brightness · False colour"
    return presenter ? title : title.capitalized
  }
  var body: some View {
    Button { binding.wrappedValue.toggle() } label: {
      Label(title, systemImage: kind == .zebras ? "circle.lefthalf.striped.horizontal" : (on ? "paintpalette.fill" : "paintpalette")).fixedSize(horizontal: false, vertical: true)
    }.help(kind == .zebras ? ExposureGuidance.zebraLookFor(model.guides) : ExposureGuidance.colourPurpose)
      .tint(on ? Color.accentColor : nil).accessibilityLabel(title).accessibilityValue(on ? "On" : "Off")
  }
}

struct CameraExposureSections: View {
  @ObservedObject var model: CameraModel
  var presenter = true
  var body: some View { ExposureSettingsContent(model: model, presenter: presenter) }
}

extension CameraModel {
  var needsRecovery: Bool {
    recordingReadyOverride != true && (authorization != .authorized || unavailableMessage != nil)
  }
  var recordingBlockReason: String {
    if authorization == .denied || authorization == .restricted { return "Allow camera in System Settings" }
    if authorization == .notDetermined { return "Allow camera access to record" }
    if selectedUID == nil { return "Connect and choose a camera to record" }
    return "Camera picture unavailable. Check the camera connection."
  }
  var recordingRecoveryAction: String {
    if authorization == .denied || authorization == .restricted { return "Allow camera in System Settings" }
    if authorization == .notDetermined { return "Allow camera access" }
    return selectedUID == nil ? "Connect and choose camera…" : "Check camera…"
  }
  var isReadyToRecord: Bool {
    if let recordingReadyOverride { return recordingReadyOverride }
    return authorization == .authorized && selectedUID != nil && unavailableMessage == nil
      && SharedCameraSession.shared.attachedUID == selectedUID && SharedCameraSession.shared.session.isRunning
  }
}

extension CameraRecorder {
  func frameRateConfirmation(camera: CameraModel) -> String {
    guard camera.pictureSize != nil, let uid = camera.selectedUID, let device = AVCaptureDevice(uniqueID: uid) else { return "Frame rate unknown" }
    let seconds = device.activeVideoMinFrameDuration.seconds
    guard seconds.isFinite, seconds > 0 else { return "Frame rate unknown" }
    return String(format: "%.2f fps", 1 / seconds)
  }
  func preRecordConfirmation(camera: CameraModel) -> String {
    [compactOutputConfirmation(camera: camera), frameRateConfirmation(camera: camera),
      inputAndFormatConfirmation, mirrorSavedVideo ? "Mirrored saved video" : "Unmirrored saved video",
      "Saves to " + Self.recordingsFolder().path].joined(separator: " · ")
  }
  var recordingFormatName: String { preset == .standard ? "H.264" : preset == .high ? "HEVC" : "ProRes 422" }
  var inputAndFormatConfirmation: String {
    "Mic: \(microphoneName) · \(recordingFormatName)"
  }
  func compactOutputConfirmation(camera: CameraModel) -> String {
    guard let size = camera.pictureSize else { return "Orientation unknown · resolution unknown" }
    let rotated = camera.guides.rotation.swapsAxes ? CGSize(width: size.height, height: size.width) : size
    let orientation = rotated.width < rotated.height ? "Portrait" : rotated.width > rotated.height ? "Landscape" : "Square"
    return "\(orientation) · \(Int(rotated.width)) × \(Int(rotated.height))" + (camera.guides.marker == nil ? "" : " · guide only")
  }
  func outputConfirmation(camera: CameraModel) -> String {
    var dimensions = "Resolution unknown"
    var orientation = "Orientation unknown"
    if let uid = camera.selectedUID, let device = AVCaptureDevice(uniqueID: uid) {
      let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
      let width = camera.guides.rotation.swapsAxes ? size.height : size.width
      let height = camera.guides.rotation.swapsAxes ? size.width : size.height
      dimensions = "\(width) × \(height)"
      orientation = height > width ? "Portrait" : width > height ? "Landscape" : "Square"
    }
    return "\(dimensions) · \(orientation) · Folder: \(Self.recordingsFolder().deletingLastPathComponent().lastPathComponent) › \(Self.recordingsFolder().lastPathComponent)"
  }
  func outputSummary(camera: CameraModel) -> String {
    let codec = preset == .standard ? "H.264" : preset == .high ? "HEVC" : "ProRes 422"
    var parts: [String] = []
    parts.append(compactOutputConfirmation(camera: camera))
    parts.append(frameRateConfirmation(camera: camera))
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
  case waiting, receiving, silence, clipping
  static func measured(lastAudibleSampleAt: TimeInterval?, clipping: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Self {
    guard let lastAudibleSampleAt else { return clipping ? .clipping : .waiting }
    return state(clipping: clipping, fresh: now - lastAudibleSampleAt < 3)
  }
  static func state(clipping: Bool, fresh: Bool) -> Self { clipping ? .clipping : fresh ? .receiving : .silence }
  var message: String {
    switch self {
    case .waiting: "Waiting for sound"
    case .receiving: "Receiving sound"
    case .silence: "No sound for 3 seconds. Check the microphone."
    case .clipping: "Too loud. Lower the microphone level."
    }
  }
}

struct RecordingAudioHealth: View {
  @ObservedObject var recorder: CameraRecorder
  @ObservedObject private var meter: InputMeter
  var compact = false
  @State private var previousHealth = RecordingHealth.waiting
  @State private var lastWarningAt = -Double.infinity
  init(recorder: CameraRecorder, compact: Bool = false) { self.recorder = recorder; self.compact = compact; meter = recorder.inputMeter }
  nonisolated static func message(drops: Int, clipping: Bool, fresh: Bool) -> String {
    if drops > 0 { return "Sound dropped from the file (\(drops) times)" }
    return RecordingHealth.state(clipping: clipping, fresh: fresh).message
  }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      let health = RecordingHealth.measured(lastAudibleSampleAt: meter.lastAudibleSampleAt,
        clipping: meter.isClipping && meter.isFresh())
      let layout = compact ? AnyLayout(HStackLayout(spacing: Space.sm)) : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
      layout {
        if recorder.isCapturing {
        HStack(spacing: Space.sm) {
          Text("Mic: \(recorder.microphoneName)").lineLimit(2).help(recorder.microphoneName)
            .fixedSize(horizontal: false, vertical: true)
          InputLevelMeter(peakDBFS: meter.isFresh() ? meter.peakDBFS : -.infinity, isClipping: meter.isClipping, showsScale: false)
            .frame(minWidth: 40, maxWidth: 100)
        }
        }
        if recorder.droppedAudioBuffers > 0 || (recorder.isCapturing && health != .receiving) {
          Label(recorder.droppedAudioBuffers > 0 ? "Sound dropped from the file (\(recorder.droppedAudioBuffers) times)" : health.message, systemImage: "exclamationmark.triangle.fill").fontWeight(.semibold)
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
  var compact = false
  @State private var recoverySettings = false
  @State private var showsDetails = false
  static func problemSummary(frames: Int, audio: Int, failure: String?) -> String {
    if let failure { return failure }
    if frames > 0 && audio > 0 { return "Picture and sound dropped. Review take." }
    if audio > 0 { return "Sound dropped. Review take." }
    return "Picture dropped. Review take."
  }
  static func shortCause(_ message: String) -> String {
    // Preserve the diagnosis; detailed recovery stays in the receipt.
    let detail = message.replacingOccurrences(of: "No completed take was saved. ", with: "")
      .replacingOccurrences(of: "No take was saved. ", with: "")
    return detail.components(separatedBy: ". ").first ?? detail
  }
  var body: some View {
    if compact, recorder.savedTake != nil || recorder.takeFailure != nil {
      let file = recorder.savedTake
      let title = file.map { "Saved " + $0.lastPathComponent } ?? "Take not saved"
      HStack(spacing: Space.sm) {
        HStack(spacing: Space.xs) {
          Text(file == nil ? "Take not saved" : recorder.qualityWarning == nil ? "Saved" : "Saved with problems")
            .fixedSize()
          if let file {
            Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Text("· " + CameraRecorder.durationText(recorder.lastTakeDuration)).fixedSize()
          }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(recorder.qualityWarning == nil ? Color.primary : Color.orange)
        .help([file?.path, recorder.qualityWarning].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + (file == nil ? "" : " · " + CameraRecorder.durationText(recorder.lastTakeDuration)))
        .accessibilityValue([file?.path, recorder.qualityWarning].compactMap { $0 }.joined(separator: " · "))
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: Space.sm) {
          if let file {
            Button(recorder.qualityWarning == nil ? "Play" : "Review") {
              if recorder.qualityWarning == nil { NSWorkspace.shared.open(file) } else { showsDetails = true }
            }.help("Play or review the saved take").accessibilityValue(file.lastPathComponent)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.help(file.path)
          } else {
            Button("Review") { showsDetails = true }.help("Review why the take was not saved")
          }
          Button("Hide", systemImage: "xmark") { recorder.receiptHidden = true }
            .labelStyle(.iconOnly).accessibilityLabel("Hide receipt").help("Hide receipt and show picture controls")
        }.font(.callout).fixedSize().buttonStyle(.plain).frame(minHeight: 24)
      }
      .restoringPopoverFocus(isPresented: $showsDetails, identifier: "recording-receipt")
      .popover(isPresented: $showsDetails) {
        RecordingReceipt(recorder: recorder, camera: camera, configure: configure, zoom: zoom)
          .frame(width: 440).padding(Space.sm).uiZoom(zoom).popoverEntryFocus()
      }
    } else if recorder.savedTake != nil || recorder.takeFailure != nil {
      VStack(alignment: .leading, spacing: Space.sm) {
        if let file = recorder.savedTake {
          Label(recorder.qualityWarning == nil ? "Saved \(file.lastPathComponent)" : "Saved with problems: \(file.lastPathComponent)",
            systemImage: recorder.qualityWarning == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold)).lineLimit(compact ? 1 : nil).truncationMode(.middle).help(file.path)
            .accessibilityValue(file.lastPathComponent)
          if let warning = recorder.qualityWarning { Text(warning).font(.callout).fixedSize(horizontal: false, vertical: true) }
          WrapLayout(spacing: Space.sm) {
            Button("Play") { NSWorkspace.shared.open(file) }.initialPopoverFocus()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            if recorder.qualityWarning != nil { Button("Try Recording Again") { Task { await recorder.start(camera: camera, defaultLabel: recorder.takeDefaultLabel) } } }
            Button("Hide") { recorder.receiptHidden = true }
          }
        } else if let failure = recorder.takeFailure {
          Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isStaticText).initialPopoverFocus()
          if let file = recorder.incompleteTake {
            Button("Show Incomplete Take in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
          }
          RecordingRecoveryActions(recorder: recorder, camera: camera) {
            if let configure { configure() } else { recoverySettings = true }
          }.popover(isPresented: $recoverySettings) {
            PresenterSettingsPopover(store: AppStore.shared, initialTab: recorder.recovery == .microphone ? .microphone : .camera, initialCameraSection: recorder.recovery == .format ? "Recording" : "Camera")
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? Space.xs : Space.md).background(Surfaces.presenterPanel, in: RoundedRectangle(cornerRadius: 12)).environment(\.colorScheme, .dark)
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
