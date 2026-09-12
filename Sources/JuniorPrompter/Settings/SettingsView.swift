import SwiftUI
import Speech
import AppKit
import CoreText

struct InspectorView: View {
  @ObservedObject var store: AppStore
  @ObservedObject private var session: SessionStore
  @State private var presetName = ""
  @State private var devices: [AudioInputDevice] = []
  @State private var deviceObserver: AudioInputDeviceObserver?
  @State private var renamePreset: PrompterSettings?
  @State private var renameValue = ""
  @State private var supportedSpeechLocales: [Locale] = []
  init(store: AppStore) { self.store = store; self.session = store.session }
  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Font", selection: $store.settings.fontName) {
          ForEach(AvailableFonts.presenter, id: \.self, content: Text.init)
        }
        Slider(value: $store.settings.fontSize, in: 18...120)
        LabeledContent("Text size", value: "\(Int(store.settings.fontSize)) pt")
        LabeledContent("Background opacity") {
          Slider(value: $store.settings.backgroundOpacity, in: 0...1)
        }
        LabeledContent("Text opacity") { Slider(value: $store.settings.textOpacity, in: 0.2...1) }
        LabeledContent("Guide position") {
          Slider(value: $store.settings.guideFraction, in: 0.1...0.85)
        }
        DisclosureGroup("Advanced appearance") {
          Picker("Weight", selection: $store.settings.fontWeight) {
            Text("Regular").tag("Regular"); Text("Bold").tag("Bold")
          }
          Picker("Alignment", selection: $store.settings.alignment) {
            Text("Left").tag("Left"); Text("Centre").tag("Center"); Text("Right").tag("Right")
          }
          Slider(value: $store.settings.lineSpacing, in: 0...0.5) { Text("Line spacing") }
          Slider(value: $store.settings.paragraphSpacing, in: 0...1) { Text("Paragraph spacing") }
          Slider(value: $store.settings.horizontalMargin, in: 0...120) { Text("Horizontal margin") }
          Toggle("Show stage directions", isOn: $store.settings.showCues)
          Toggle("Highlight active word", isOn: $store.settings.highlightActiveWord)
          ColorPicker("Text colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.textColorHex) ?? .white) }, set: { store.settings.textColorHex = $0.nsColor.hex }), supportsOpacity: false)
          ColorPicker("Background colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black) }, set: { store.settings.backgroundColorHex = $0.nsColor.hex }), supportsOpacity: false)
        }
      }
      Section("Mirror") {
        Toggle("Horizontal", isOn: $store.settings.horizontalMirror)
        Toggle("Vertical", isOn: $store.settings.verticalMirror)
        Picker("Rotation", selection: $store.settings.rotation) {
          Text("0°").tag(0)
          Text("180°").tag(180)
        }
      }
      Section("Tracking") {
        Picker("Mode", selection: $store.settings.mode) {
          ForEach(["Voice", "Timed", "Manual", "Sound"], id: \.self, content: Text.init)
        }
        if store.settings.mode == "Timed" || store.settings.mode == "Sound" {
          Slider(value: $store.settings.speed, in: 20...300)
          LabeledContent("Speed", value: "\(Int(store.settings.speed)) wpm")
        }
        if store.settings.mode == "Sound" {
          Slider(value: $store.settings.soundThreshold, in: 0...0.5)
          LabeledContent("Sound threshold", value: String(format: "%.3f", store.settings.soundThreshold))
          Text("Advances while sound is above threshold; does not match words.").font(.caption).foregroundStyle(.secondary)
        }
        if store.settings.mode == "Voice" {
          Toggle("Allow backward voice tracking", isOn: $store.settings.allowsBackwardVoiceTracking)
          Picker("Speech languages", selection: $store.settings.speechLanguage) {
            Text("Mixed English & French").tag("Mixed")
            Text("Automatic (script language)").tag("Automatic")
            Text("English").tag("English")
            Text("French").tag("French")
            ForEach(supportedSpeechLocales.filter { !["en-GB", "fr-FR"].contains($0.identifier) }, id: \.identifier) { locale in
              Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
            }
          }
        }
      }
      Section("Audio input") {
        HStack {
          Picker(
            "Microphone",
            selection: Binding(
              get: { store.settings.audioDeviceUID ?? "" },
              set: {
                session.stopMicrophoneTest()
                store.settings.audioDeviceUID = $0.isEmpty ? nil : $0
              })
          ) {
            Text("Choose a microphone").tag("")
            if let uid = store.settings.audioDeviceUID,
              !devices.contains(where: { $0.uid == uid })
            {
              Text("Selected microphone unavailable").tag(uid)
            }
            ForEach(devices) { device in Text(device.name).tag(device.uid) }
          }
          Button { devices = AudioCapture.inputDevices() } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Refresh microphones")
        }
        LabeledContent("Input gain") {
          Slider(
            value: Binding(
              get: { store.settings.inputGain },
              set: {
                store.settings.inputGain = $0
                session.setMicrophoneTestGain($0)
              }), in: 0.25...4)
        }
        HStack {
          Button(session.isTestingMicrophone ? "Stop test" : "Test microphone") {
            if session.isTestingMicrophone {
              session.stopMicrophoneTest()
            } else {
              session.startMicrophoneTest(
                deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain)
            }
          }
          .disabled(!session.isTestingMicrophone && store.settings.audioDeviceUID == nil)
          if session.isTestingMicrophone {
            Label("Testing. Speak normally.", systemImage: "mic.fill")
              .foregroundStyle(.secondary)
          }
        }
        InputLevelMeter(peakDBFS: session.audioPeakDBFS, isClipping: session.isClipping)
        LabeledContent("Peak level", value: Self.decibelText(session.audioPeakDBFS))
        Text("Green below −20 dBFS. Yellow from −20 to −9 dBFS. Red above −9 dBFS.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if session.isClipping {
          Label("Input is clipping", systemImage: "exclamationmark.triangle.fill").foregroundStyle(
            .red)
        }
        if let notice = session.microphoneTestNotice {
          Label(notice, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.secondary)
        }
      }
      Section("Presets") {
        HStack {
          TextField("Preset name", text: $presetName)
          Button("Save") {
            store.savePreset(named: presetName)
            presetName = ""
          }
        }
          ForEach(store.presets) { preset in
            HStack {
              Button(preset.name) { store.applyPreset(preset) }.buttonStyle(.plain)
            Spacer()
            Button {
              store.deletePreset(preset.id)
            } label: {
              Image(systemName: "trash")
            }.buttonStyle(.plain)
            }.contextMenu {
              Button("Rename") { renamePreset = preset; renameValue = preset.name }
              Button("Duplicate") { store.duplicatePreset(preset.id) }
              Button("Update from Current Settings") { store.updatePreset(preset.id) }
              Button("Delete", role: .destructive) { store.deletePreset(preset.id) }
            }
          }
      }
      Section("Session") {
        LabeledContent("Words accepted", value: "\(session.acceptedWords)")
        if store.settings.mode == "Voice" { LabeledContent("Estimated WPM", value: "\(session.estimatedWPM)") }
        LabeledContent("Session milestone", value: "Next \(session.sessionMilestone) words")
        LabeledContent("Scripts tracked") {
          VStack(alignment: .trailing, spacing: 2) {
            Text("\(store.scriptsTracked)")
            Text("Includes recently deleted")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        LabeledContent(
          "Active time",
          value: Duration.seconds(session.activeDuration).formatted(
            .time(pattern: .minuteSecond)))
      }
    }.formStyle(.grouped).padding(12).frame(minWidth: 255).task {
      supportedSpeechLocales = await SpeechTranscriber.supportedLocales
    }.onAppear {
      devices = AudioCapture.inputDevices()
      deviceObserver = AudioCapture.inputDeviceObserver {
        let available = AudioCapture.inputDevices()
        devices = available
        session.microphoneDevicesDidChange(available)
      }
    }.onDisappear {
      deviceObserver = nil
      session.stopMicrophoneTest()
    }.alert("Rename Preset", isPresented: Binding(get: { renamePreset != nil }, set: { if !$0 { renamePreset = nil } })) {
      TextField("Preset name", text: $renameValue)
      Button("Save") { if let preset = renamePreset { store.renamePreset(preset.id, name: renameValue) }; renamePreset = nil }
      Button("Cancel", role: .cancel) { renamePreset = nil }
    }
  }

  private static func decibelText(_ value: Float) -> String {
    value.isFinite ? String(format: "%.1f dBFS", value) : "−∞ dBFS"
  }
}

enum AvailableFonts {
  private static let supportedInstalled: [String] = {
    registerBundledFonts(missingFrom: Set(NSFontManager.shared.availableFontFamilies))
    return ["Poppins", "Lexend", "Lexend Deca"].filter { NSFont(name: $0, size: 14) != nil }
  }()

  static let presenter = ["SF Pro", "Helvetica Neue", "Georgia", "Avenir Next"] + supportedInstalled
  static let editor = ["System Serif", "System", "Georgia", "Avenir Next", "Helvetica Neue", "Monospaced"] + supportedInstalled

  private static func registerBundledFonts(missingFrom families: Set<String>) {
    for (file, family) in [("Lexend-Variable.ttf", "Lexend"), ("LexendDeca-Variable.ttf", "Lexend Deca")] where !families.contains(family) {
      guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Fonts") else { continue }
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }
}

private struct InputLevelMeter: View {
  let peakDBFS: Float
  let isClipping: Bool
  @State private var peakHold = PeakHold()
  private let ticks: [(Double, String)] = [(-60, "−60"), (-50, "−50"), (-40, "−40"), (-30, "−30"), (-20, "−20"), (-15, "−15"), (-12, "−12"), (-9, "−9"), (-6, "−6"), (-3, "−3"), (0, "0")]

  private var fill: CGFloat {
    guard peakDBFS.isFinite else { return 0 }
    return CGFloat(min(1, max(0, (peakDBFS + 60) / 60)))
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        ZStack(alignment: .leading) {
          Capsule().fill(.quaternary)
          LinearGradient(
            stops: [
              .init(color: .green, location: 0), .init(color: .green, location: 2.0 / 3.0),
              .init(color: .yellow, location: 2.0 / 3.0), .init(color: .yellow, location: 0.85),
              .init(color: .red, location: 0.85)
            ], startPoint: .leading, endPoint: .trailing
          ).mask(alignment: .leading) {
            Rectangle().frame(width: geometry.size.width * fill)
          }
          ForEach(ticks, id: \.0) { value, _ in
            let position = CGFloat((value + 60) / 60)
            Rectangle().fill(.primary.opacity(0.65)).frame(width: 1).offset(
              x: geometry.size.width * position - 1)
          }
          if peakHold.value(at: ProcessInfo.processInfo.systemUptime) != nil {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
              if let marker = peakHold.value(at: ProcessInfo.processInfo.systemUptime) {
                Rectangle().fill(.white).frame(width: 2).offset(x: geometry.size.width * markerPosition(marker) - 1)
              }
            }
          }
        }
        .frame(height: 12)
        ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
          let position = CGFloat((tick.0 + 60) / 60)
          Text(tick.1)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .position(x: min(geometry.size.width - 8, max(8, geometry.size.width * position)), y: index.isMultiple(of: 2) ? 21 : 31)
        }
      }
    }
    .frame(height: 40)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Microphone peak level")
    .accessibilityValue(
      peakDBFS.isFinite ? String(format: "%.1f dBFS", peakDBFS) : "silence")
    .accessibilityHint(isClipping ? "Input is clipping." : "Marks from minus 60 to 0 dBFS, with warning zones at minus 20 and minus 9.")
    .onChange(of: peakDBFS) { _, value in
      guard value.isFinite else { return }
      let uptime = ProcessInfo.processInfo.systemUptime
      peakHold.ingest(value, at: uptime)
    }
    .task(id: peakHold.generation) {
      guard peakHold.value(at: ProcessInfo.processInfo.systemUptime) != nil else { return }
      try? await Task.sleep(for: .seconds(6))
      if !Task.isCancelled { peakHold.expire() }
    }
  }

  private func markerPosition(_ value: Float) -> CGFloat {
    CGFloat(min(1, max(0, (value + 60) / 60)))
  }
}

struct PeakHold {
  private(set) var peak: Float?
  private(set) var at = 0.0
  private(set) var generation = 0
  mutating func ingest(_ value: Float, at now: TimeInterval) {
    guard value.isFinite, value >= (self.value(at: now) ?? -.infinity) else { return }
    peak = value; at = now; generation += 1
  }
  func value(at now: TimeInterval) -> Float? {
    guard let peak else { return nil }
    let result = peak - Float(max(0, now - at - 0.4) * 11.76)
    return result >= -60 ? result : nil
  }
  mutating func expire() { peak = nil; generation += 1 }
}

private extension Color {
  var nsColor: NSColor { NSColor(self) }
}
private extension NSColor {
  convenience init?(hex: String) { guard let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }; self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1) }
  var hex: String { let c = usingColorSpace(.deviceRGB) ?? self; return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)) }
}
