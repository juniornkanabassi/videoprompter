import SwiftUI
import Speech
import AppKit
import CoreText

struct InspectorView: View {
  @ObservedObject var store: AppStore
  @ObservedObject private var session: SessionStore
  @ObservedObject private var camera = CameraModel.shared
  @State private var showsGuideSettings = false
  @State private var presetName = ""
  @State private var devices: [AudioInputDevice] = []
  @State private var deviceObserver: AudioInputDeviceObserver?
  @State private var renamePreset: PrompterSettings?
  @State private var renameValue = ""
  @State private var supportedSpeechLocales: [Locale] = []
  init(store: AppStore) { self.store = store; self.session = store.session }
  var body: some View {
    Form {
      Section("Mode") {
        Picker("Mode", selection: $camera.presentsWithVideo) {
          Text("Prompter only").tag(false)
          Text("Prompter + video").tag(true)
        }.pickerStyle(.segmented).labelsHidden()
      }
      if camera.presentsWithVideo {
        Section("Video") {
          Picker("Camera", selection: $camera.selectedUID) {
            if camera.devices.isEmpty { Text("No camera found").tag(camera.selectedUID) }
            ForEach(camera.devices) { Text($0.name).tag(Optional($0.uid)) }
          }
          HStack {
            Picker("Rotation", selection: camera.rotationChoice) {
              Text("Auto").tag(nil as CameraRotation?)
              ForEach(CameraRotation.allCases) { Text($0.label).tag(Optional($0)) }
            }
            Button("Guides") { showsGuideSettings.toggle() }
              .popover(isPresented: $showsGuideSettings, arrowEdge: .bottom) {
                CameraGuideSettings(model: camera).frame(width: 300).padding()
              }
          }
          Toggle("Mirror camera", isOn: $camera.mirrored)
        }.task { camera.start() }
      }
      Section("Text") {
        Picker("Font", selection: $store.settings.fontName) {
          ForEach(AvailableFonts.presenter, id: \.self, content: Text.init)
        }
        Slider(value: $store.settings.fontSize, in: 18...120)
        LabeledContent("Text size", value: "\(Int(store.settings.fontSize)) pt")
        LabeledContent("Text width") {
          Slider(value: $store.settings.textWidth, in: 0.3...1)
        }
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
          Toggle("Mirror text horizontally", isOn: $store.settings.horizontalMirror)
          Toggle("Mirror text vertically", isOn: $store.settings.verticalMirror)
          Picker("Text rotation", selection: $store.settings.rotation) {
            Text("0°").tag(0)
            Text("180°").tag(180)
          }
          Toggle("Show stage directions", isOn: $store.settings.showCues)
          Toggle("Snap presenter window", isOn: $store.settings.presenterSnappingEnabled)
          Toggle("Highlight active word", isOn: $store.settings.highlightActiveWord)
          ColorPicker("Text colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.textColorHex) ?? .white) }, set: { store.settings.textColorHex = $0.nsColor.hex }), supportsOpacity: false)
          ColorPicker("Background colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black) }, set: { store.settings.backgroundColorHex = $0.nsColor.hex }), supportsOpacity: false)
        }
      }
      Section("Motion") {
        Picker("Tracking", selection: $store.settings.mode) {
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
      Section("Microphone") {
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
    registerBundledFonts()
    return ["Poppins", "Lexend", "Lexend Deca"].filter { NSFont(name: $0, size: 14) != nil }
  }()

  static let presenter = ["SF Pro", "Helvetica Neue", "Georgia", "Avenir Next"] + supportedInstalled
  static let editor = ["System Serif", "System", "Georgia", "Avenir Next", "Helvetica Neue", "Monospaced"] + supportedInstalled

  private static func registerBundledFonts() {
    for (file, family) in [("Lexend-Variable.ttf", "Lexend"), ("LexendDeca-Variable.ttf", "Lexend Deca")]
    where needsBundledFont(members: NSFontManager.shared.availableMembers(ofFontFamily: family)) {
      guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Fonts") else { continue }
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }

  /// A present family name is not enough: this Mac has Lexend installed as
  /// ExtraBold alone, so asking for "Lexend" returned a heavy face. Register the
  /// bundled variable font whenever the family has no upright regular member.
  static func needsBundledFont(members: [[Any]]?) -> Bool {
    guard let members, !members.isEmpty else { return true }
    return !members.contains { member in
      guard member.count >= 4, (member[2] as? Int) == 5, let traits = member[3] as? UInt
      else { return false }
      return traits & UInt(NSFontTraitMask.italicFontMask.rawValue) == 0
    }
  }
}

struct InputLevelMeter: View {
  let peakDBFS: Float
  let isClipping: Bool
  @State private var peakHold = PeakHold()
  static let ticks: [(Float, String)] = [(-60, "−60"), (-50, "−50"), (-40, "−40"), (-30, "−30"), (-20, "−20"), (-15, "−15"), (-12, "−12"), (-9, "−9"), (-6, "−6"), (-3, "−3"), (0, "0")]
  private static let labelFont = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
  static let labelWidths = ticks.map { ($0.1 as NSString).size(withAttributes: [.font: labelFont]).width }

  /// OBS's mapping: linear in dB from −60 to 0.
  static func position(_ dBFS: Float) -> CGFloat {
    dBFS.isFinite ? CGFloat(min(1, max(0, (dBFS + 60) / 60))) : 0
  }

  /// One row of labels that never collide: both ends always, then from 0 leftwards each label
  /// that clears every label already placed by `gap`. Positions are fractions of the width.
  static func visibleLabels(positions: [CGFloat], widths: [CGFloat], availableWidth: CGFloat, gap: CGFloat = 6) -> [Int] {
    guard let last = positions.indices.last else { return [] }
    var placed = [last, 0]
    for index in positions.indices.reversed() where index != last && index != 0 {
      let span = labelSpan(position: positions[index], width: widths[index], availableWidth: availableWidth)
      let clears = placed.allSatisfy { other in
        let placedSpan = labelSpan(position: positions[other], width: widths[other], availableWidth: availableWidth)
        return span.upperBound + gap <= placedSpan.lowerBound || placedSpan.upperBound + gap <= span.lowerBound
      }
      if clears { placed.append(index) }
    }
    return Set(placed).sorted()
  }

  /// A label centred on its tick, kept inside the meter.
  static func labelSpan(position: CGFloat, width: CGFloat, availableWidth: CGFloat) -> ClosedRange<CGFloat> {
    let start = min(max(0, position * availableWidth - width / 2), max(0, availableWidth - width))
    return start...(start + width)
  }

  var body: some View {
    GeometryReader { geometry in
      let positions = Self.ticks.map { Self.position($0.0) }
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
            Rectangle().frame(width: geometry.size.width * Self.position(peakDBFS))
          }
          ForEach(positions, id: \.self) { position in
            Rectangle().fill(.primary.opacity(0.65)).frame(width: 1).offset(
              x: geometry.size.width * position - 1)
          }
          if peakHold.value(at: ProcessInfo.processInfo.systemUptime) != nil {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
              if let marker = peakHold.value(at: ProcessInfo.processInfo.systemUptime) {
                Rectangle().fill(.white).frame(width: 2).offset(x: geometry.size.width * Self.position(marker) - 1)
              }
            }
          }
        }
        .frame(height: 12)
        ForEach(Self.visibleLabels(positions: positions, widths: Self.labelWidths, availableWidth: geometry.size.width), id: \.self) { index in
          let span = Self.labelSpan(position: positions[index], width: Self.labelWidths[index], availableWidth: geometry.size.width)
          Text(Self.ticks[index].1)
            .font(Font(Self.labelFont as CTFont))
            .foregroundStyle(.secondary)
            .fixedSize()
            .position(x: (span.lowerBound + span.upperBound) / 2, y: 22)
        }
      }
    }
    .frame(height: 30)
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
