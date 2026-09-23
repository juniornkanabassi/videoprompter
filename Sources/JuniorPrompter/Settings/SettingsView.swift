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
  /// Input gain while it is being dragged; nil once it has been written to the settings.
  @State private var gainDraft: Double?
  @State private var renamePreset: PrompterSettings?
  @State private var renameValue = ""
  @State private var supportedSpeechLocales: [Locale] = []
  init(store: AppStore) { self.store = store; self.session = store.session }
  var body: some View {
    Form {
      Section("Mode") {
        // Segmented while the three labels fit, a menu when the pane is narrower.
        ViewThatFits(in: .horizontal) {
          modePicker.pickerStyle(.segmented)
          modePicker.pickerStyle(.menu)
        }
      }
      if camera.presentsWithVideo {
        Section("Video") {
          LabeledContent("Camera") { CameraPicker(model: camera) }
          Picker("Rotation", selection: camera.rotationChoice) {
            ForEach(CameraModel.rotationOptions, id: \.0) { Text($0.0).tag($0.1) }
          }
          Button("Guides") { showsGuideSettings.toggle() }
            .popover(isPresented: $showsGuideSettings, arrowEdge: .bottom) {
              CameraGuideSettings(model: camera).frame(width: 300).padding()
            }
          Toggle("Mirror camera", isOn: $camera.mirrored)
        }.task { camera.start() }
      }
      Section("Text") {
        Picker("Font", selection: $store.settings.fontName) {
          ForEach(AvailableFonts.presenter, id: \.self, content: Text.init)
        }
        ValueSlider("Text size", value: $store.settings.fontSize, in: AppStore.presenterFontSizes,
                    readout: "\(Int(store.settings.fontSize)) pt")
        Slider(value: $store.settings.textWidth, in: PrompterSettings.textWidthRange) { Text("Text width") }
        Slider(value: $store.settings.textOpacity, in: 0.2...1) { Text("Text opacity") }
        // One control, not a Prompter-only slider that did nothing over video beside a Video one.
        Slider(value: backdropOpacity, in: PrompterSettings.backdropOpacityRange(withVideo: camera.presentsWithVideo)) {
          Text("Background opacity")
        }.help("Kept separately for Prompter only and Prompter + video")
        Slider(value: $store.settings.guideFraction, in: 0.1...0.85) { Text("Guide position") }
        Slider(value: $store.settings.guideOpacity, in: 0...1) { Text("Guide opacity") }
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
          ColorPicker("Text colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.textColorHex) ?? .white) }, set: { store.settings.textColorHex = NSColor($0).hex }), supportsOpacity: false)
          ColorPicker("Background colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black) }, set: { store.settings.backgroundColorHex = NSColor($0).hex }), supportsOpacity: false)
        }
      }
      Section("Motion") {
        Picker("Tracking", selection: $store.settings.mode) {
          ForEach(["Voice", "Manual"], id: \.self, content: Text.init)
        }
        if store.settings.mode == "Manual" {
          ValueSlider("Speed", value: $store.settings.speed, in: 20...300,
                      readout: "\(Int(store.settings.speed)) wpm")
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
          // The menu sizes to its longest name; let it give way and show the choice as a tooltip.
          Picker("Input device", selection: Binding(
            get: { store.settings.audioDeviceUID ?? "" },
            set: { session.stopMicrophoneTest(); store.settings.audioDeviceUID = $0.isEmpty ? nil : $0 })
          ) {
            Text("Choose a microphone").tag("")
            if let uid = store.settings.audioDeviceUID, !devices.contains(where: { $0.uid == uid }) {
              Text("Selected microphone unavailable").tag(uid)
            }
            ForEach(devices) { device in Text(device.name).tag(device.uid) }
          }
          .frame(maxWidth: .infinity)
          .help(store.settings.audioDeviceUID.map { uid in
            devices.first { $0.uid == uid }?.name ?? "Selected microphone unavailable"
          } ?? "Choose a microphone")
          Button("Refresh microphones", systemImage: "arrow.clockwise") { devices = AudioCapture.inputDevices() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Refresh microphones")
        }
        // The capture hears each tick at once; the settings, and with them the whole inspector, the
        // presenter and the saved copy, only follow once the drag pauses. A fixed-size slider with
        // no readout, so nothing here changes the layout while it moves.
        LabeledContent("Input gain") {
          Slider(value: Binding(
            get: { gainDraft ?? store.settings.inputGain },
            set: { gainDraft = $0; session.setMicrophoneTestGain($0) }), in: 0.25...4
          ) { editing in if !editing { commitGain() } }
            .accessibilityValue(String(format: "%.2f times", gainDraft ?? store.settings.inputGain))
        }
        .task(id: gainDraft) {
          guard gainDraft != nil, (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
          commitGain()
        }
        HStack {
          Button(session.isTestingMicrophone ? "Stop test" : "Test microphone") {
            if session.isTestingMicrophone {
              session.stopMicrophoneTest()
            } else {
              session.startMicrophoneTest(deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain)
            }
          }
          .disabled(!session.isTestingMicrophone && store.settings.audioDeviceUID == nil)
          if session.isTestingMicrophone {
            Label("Testing. Speak normally.", systemImage: "mic.fill")
              .foregroundStyle(.secondary)
          }
        }
        InputLevelMeter(peakDBFS: session.audioPeakDBFS, isClipping: session.isClipping)
        // The clipping warning shares this row: a row of its own came and went with the signal and
        // shook everything below it during a test.
        LabeledContent("Peak level") {
          HStack {
            if session.isClipping {
              Label("Clipping", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.red).help("Clipping")
            }
            Text(session.audioPeakDBFS.isFinite ? String(format: "%.1f dBFS", session.audioPeakDBFS) : "−∞ dBFS")
              .monospacedDigit().lineLimit(1).fixedSize()
          }
        }
        Text("Green below −20 dBFS. Yellow from −20 to −9 dBFS. Red above −9 dBFS.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let notice = session.microphoneTestNotice {
          Label(notice, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.secondary)
        }
      }
      Section("Presets") {
        HStack {
          TextField("Preset name", text: $presetName)
          Button("Save") { store.savePreset(named: presetName); presetName = "" }
        }
        ForEach(store.presets) { preset in
          HStack {
            Button(preset.name) { store.applyPreset(preset) }.buttonStyle(.plain)
              .lineLimit(1).truncationMode(.tail)
              .help("Apply \(preset.name)")
            Spacer()
            Button("Delete \(preset.name)", systemImage: "trash") { store.deletePreset(preset.id) }
              .labelStyle(.iconOnly).buttonStyle(.plain)
              .help("Delete preset")
          }.contextMenu {
            Button("Rename") { renamePreset = preset; renameValue = preset.name }
            Button("Duplicate") { store.duplicatePreset(preset.id) }
            Button("Update from Current Settings") { store.updatePreset(preset.id) }
            Button("Delete", role: .destructive) { store.deletePreset(preset.id) }
          }
        }
      }
    }.formStyle(.grouped).task {
      supportedSpeechLocales = await SpeechTranscriber.supportedLocales
    }.onAppear {
      devices = AudioCapture.inputDevices()
      deviceObserver = AudioCapture.inputDeviceObserver {
        let available = AudioCapture.inputDevices()
        devices = available
        session.microphoneDevicesDidChange(available)
      }
    }.onDisappear {
      commitGain()
      deviceObserver = nil
      session.stopMicrophoneTest()
    }.alert("Tracking modes changed", isPresented: Binding(
      get: { store.modeMigrationNotice != nil }, set: { if !$0 { store.dismissModeMigrationNotice() } })
    ) {
      Button("OK") {}
    } message: {
      Text(store.modeMigrationNotice ?? "")
    }.alert("Rename Preset", isPresented: Binding(get: { renamePreset != nil }, set: { if !$0 { renamePreset = nil } })) {
      TextField("Preset name", text: $renameValue)
      Button("Save") { if let preset = renamePreset { store.renamePreset(preset.id, name: renameValue) }; renamePreset = nil }
      Button("Cancel", role: .cancel) { renamePreset = nil }
    }
  }

  private var modePicker: some View {
    Picker("Mode", selection: $camera.displayMode) {
      ForEach(PresenterDisplayMode.allCases) { Text($0.label).tag($0) }
    }.labelsHidden()
  }

  private func commitGain() {
    guard let gain = gainDraft else { return }
    gainDraft = nil
    store.settings.inputGain = gain
  }

  private var backdropOpacity: Binding<Double> {
    Binding(
      get: { store.settings.backdropOpacity(withVideo: camera.presentsWithVideo) },
      set: { store.settings.setBackdropOpacity($0, withVideo: camera.presentsWithVideo) })
  }
}

/// A slider with its value read out beside it, on one labelled row.
private struct ValueSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let readout: String
  init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, readout: String) {
    self.title = title; _value = value; self.range = range; self.readout = readout
  }
  var body: some View {
    LabeledContent(title) {
      HStack {
        Slider(value: $value, in: range) { Text(title) }.labelsHidden()
        Text(readout).monospacedDigit().foregroundStyle(.secondary)
      }
    }
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
    .accessibilityValue(peakDBFS.isFinite ? String(format: "%.1f dBFS", peakDBFS) : "silence")
    .accessibilityHint(isClipping ? "Input is clipping." : "Marks from minus 60 to 0 dBFS, with warning zones at minus 20 and minus 9.")
    // `ingest` ignores silence.
    .onChange(of: peakDBFS) { _, value in peakHold.ingest(value, at: ProcessInfo.processInfo.systemUptime) }
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
