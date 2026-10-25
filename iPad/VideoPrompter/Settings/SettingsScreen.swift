import PrompterCore
import SwiftUI
import UIKit

/// The Mac's presenter settings, laid out for touch. Changes apply to an open presenter at once.
struct SettingsScreen: View {
  @EnvironmentObject private var store: PadStore
  @Environment(\.dismiss) private var dismiss
  @State private var microphones: [AudioInputDevice] = []
  @State private var presetName = ""
  @State private var choosingFolder = false

  private static let fonts: [String] = {
    let preferred = ["Lexend Deca", "Lexend", "Helvetica Neue", "Avenir Next", "Georgia"]
    let others = UIFont.familyNames.sorted().filter { !preferred.contains($0) }
    return preferred.filter { UIFont.familyNames.contains($0) || $0.hasPrefix("Lexend") } + others
  }()

  var body: some View {
    Form {
      reading
      teleprompter
      text
      camera
      presets
      scriptsFolder
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { Button("Done") { dismiss() } }
    .onAppear { microphones = AudioCapture.inputDevices() }
    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { store.folder.choose(url) }
    }
  }

  private var reading: some View {
    Section {
      Picker("Follow", selection: $store.settings.mode) {
        Text("Voice").tag("Voice")
        Text("Manual").tag("Manual")
      }
      .pickerStyle(.segmented)
      if store.settings.mode == "Manual" {
        LabeledContent("Speed") {
          Slider(value: $store.settings.speed, in: 20...300, step: 5)
          Text("\(Int(store.settings.speed)) wpm").monospacedDigit().frame(width: 80, alignment: .trailing)
        }
      } else {
        Picker("Language", selection: $store.settings.speechLanguage) {
          Text("English and French").tag("Mixed")
          Text("English").tag("English")
          Text("French").tag("French")
          Text("Detect from script").tag("Automatic")
        }
        Picker("Microphone", selection: $store.settings.audioDeviceUID) {
          ForEach(microphones) { Text($0.name).tag(Optional($0.uid)) }
        }
        Toggle("Follow repeated earlier words", isOn: $store.settings.allowsBackwardVoiceTracking)
      }
    } header: {
      Text("Reading")
    } footer: {
      Text(store.settings.mode == "Voice"
        ? "Voice follows you with on-device speech recognition. The first use may download Apple's speech files."
        : "Manual scrolls at a steady speed. Up and down arrows change it while presenting.")
    }
  }

  private var teleprompter: some View {
    Section("Teleprompter") {
      Toggle("Mirror for teleprompter glass", isOn: $store.settings.horizontalMirror)
      Toggle("Flip text top to bottom", isOn: $store.settings.verticalMirror)
      LabeledContent("Reading line") {
        Slider(value: $store.settings.guideFraction, in: 0.15...0.85)
      }
      LabeledContent("Line marker") {
        Slider(value: $store.settings.guideOpacity, in: 0...1)
      }
    }
  }

  private var text: some View {
    Section("Text") {
      Picker("Font", selection: $store.settings.fontName) {
        ForEach(Self.fonts, id: \.self) { Text($0).font(.custom($0, size: 17)).tag($0) }
      }
      LabeledContent("Size") {
        Slider(value: $store.settings.fontSize, in: 18...120, step: 1)
        Text("\(Int(store.settings.fontSize)) pt").monospacedDigit().frame(width: 60, alignment: .trailing)
      }
      Picker("Weight", selection: $store.settings.fontWeight) {
        Text("Regular").tag("Regular")
        Text("Bold").tag("Bold")
      }
      ColorPicker("Text colour", selection: hexBinding(\.textColorHex), supportsOpacity: false)
      ColorPicker("Background", selection: hexBinding(\.backgroundColorHex), supportsOpacity: false)
      LabeledContent("Background opacity") {
        Slider(value: $store.settings.backgroundOpacity, in: 0...1)
      }
      LabeledContent("Line spacing") {
        Slider(value: $store.settings.lineSpacing, in: 0...0.8)
      }
      LabeledContent("Paragraph spacing") {
        Slider(value: $store.settings.paragraphSpacing, in: 0...1.2)
      }
      LabeledContent("Text width") {
        Slider(value: $store.settings.textWidth, in: PrompterSettings.textWidthRange)
      }
      Picker("Alignment", selection: $store.settings.alignment) {
        Text("Left").tag("Left")
        Text("Centre").tag("Center")
        Text("Right").tag("Right")
      }
      Toggle("Show cues such as [pause]", isOn: $store.settings.showCues)
      Toggle("Highlight the current word", isOn: $store.settings.highlightActiveWord)
    }
  }

  private var camera: some View {
    CameraSettings(camera: store.camera, dimming: $store.settings.videoDimming)
  }

  private var presets: some View {
    Section {
      ForEach(store.presets) { preset in
        Button(preset.name) { store.apply(preset) }
      }
      .onDelete { store.deletePresets(at: $0) }
      HStack {
        TextField("New preset name", text: $presetName)
        Button("Save Current Look") {
          store.savePreset(named: presetName)
          presetName = ""
        }
      }
    } header: {
      Text("Presets")
    } footer: {
      Text("Presets are shared with the Mac through the scripts folder. Applying one keeps this iPad's mirroring and microphone.")
    }
  }

  private var scriptsFolder: some View {
    Section {
      LabeledContent("Location", value: store.folder.isICloud ? "iCloud Drive › \(store.folder.rootURL.lastPathComponent)" : "On this iPad")
      Button("Choose Folder in iCloud Drive…") { choosingFolder = true }
      if store.folder.rootURL != ScriptFolder.localFolder {
        Button("Use Scripts on This iPad Only") { store.folder.useLocalFolder() }
      }
    } header: {
      Text("Scripts")
    } footer: {
      Text("Choose the Video Prompter folder in iCloud Drive to see the same scripts as your Mac. Edits on either side appear on the other within a few seconds of iCloud syncing.")
    }
  }

  private func hexBinding(_ path: WritableKeyPath<PrompterSettings, String>) -> Binding<Color> {
    Binding(
      get: { Color(uiColor: ScriptRenderer.colour(store.settings[keyPath: path])) },
      set: { store.settings[keyPath: path] = UIColor($0).hex })
  }
}

private struct CameraSettings: View {
  @ObservedObject var camera: PadCamera
  @Binding var dimming: Double
  var body: some View {
    Section {
      Toggle("Show camera behind the script", isOn: $camera.isOn)
      Picker("Camera", selection: $camera.selectedID) {
        ForEach(camera.devices) { device in
          Text(device.isExternal ? "\(device.name) (USB-C)" : device.name).tag(Optional(device.id))
        }
      }
      Toggle("Mirror camera", isOn: $camera.mirrored)
      LabeledContent("Darken picture") { Slider(value: $dimming, in: 0...0.9) }
      Toggle("Rule of thirds", isOn: $camera.guides.thirds)
      Toggle("Centre lines", isOn: $camera.guides.axes)
      Picker("Frame marker", selection: $camera.guides.marker) {
        Text("None").tag(CameraAspect?.none)
        ForEach(CameraAspect.presets) { Text($0.label).tag(Optional($0)) }
      }
      if camera.devices.first(where: { $0.id == camera.selectedID })?.isExternal == true {
        Picker("Rotation", selection: $camera.guides.rotation) {
          ForEach(CameraRotation.allCases) { Text("\($0.rawValue)°").tag($0) }
        }
      }
      if camera.isOn, let mode = camera.mode { LabeledContent("Picture", value: mode) }
      if let notice = camera.notice { Text(notice).foregroundStyle(.secondary) }
    } header: {
      Text("Camera")
    } footer: {
      Text("Under teleprompter glass the iPad's own cameras face away from you. Plug in the ATEM Mini's USB-C webcam output, a Sony camera set to USB Streaming, any UVC webcam or an HDMI to USB-C capture adapter to see the studio picture here.")
    }
  }
}

extension UIColor {
  /// "#RRGGBB", as the settings store colours.
  var hex: String {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
  }
}
