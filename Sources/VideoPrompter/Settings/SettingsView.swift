import SwiftUI
import Speech
import AppKit
import CoreText

struct InspectorView: View {
  @ObservedObject var store: AppStore
  /// Not observed: the session publishes on every word read, and observing it redrew this whole
  /// form (19 to 27 ms a word in a Manual trace) for a panel that shows no reading position. Only
  /// `MicrophoneTestRow` watches it.
  private let session: SessionStore
  @ObservedObject private var camera = CameraModel.shared
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
      Section { Text("Settings").font(.title2.weight(.semibold)) }
      Section("Follow") {
        Picker("How it follows you", selection: $store.settings.mode) {
          ForEach(["Voice", "Manual"], id: \.self, content: Text.init)
        }.pickerStyle(.segmented).help("Voice follows your spoken words; Manual scrolls at a steady speed")
        Text(store.settings.mode == "Voice" ? "Follows the words you say." : "Scrolls at a steady speed.")
          .font(.caption).foregroundStyle(.secondary)
        if store.settings.mode == "Voice" {
          VStack(alignment: .leading, spacing: 6) {
            Text("Microphone")
          Picker("Microphone", selection: Binding(
            get: { store.settings.audioDeviceUID ?? "" },
            set: { session.stopMicrophoneTest(); store.settings.audioDeviceUID = $0.isEmpty ? nil : $0 })
          ) {
            Text("Choose a microphone").tag("")
            if let uid = store.settings.audioDeviceUID, !devices.contains(where: { $0.uid == uid }) {
              Text("Selected microphone unavailable").tag(uid)
            }
            ForEach(devices) { device in Text(device.name).tag(device.uid) }
          }
          .labelsHidden().accessibilityLabel("Microphone")
          .frame(maxWidth: .infinity, alignment: .leading)
          .help("Choose the microphone that Voice should listen to. " + (store.settings.audioDeviceUID.map { uid in
            devices.first { $0.uid == uid }?.name ?? "Selected microphone unavailable"
          } ?? "Choose a microphone"))
          }
          MicrophoneTestRow(session: session, deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain)
        } else {
          ValueSlider("Speed", value: $store.settings.speed, in: 20...300,
            readout: "\(Int(store.settings.speed)) words per minute").help("Set how fast Manual moves through your script")
        }
      }
      Section("Show") {
        ViewThatFits(in: .horizontal) {
          modePicker.pickerStyle(.segmented)
          modePicker.pickerStyle(.menu)
        }
        if camera.presentsWithVideo {
          LabeledContent("Camera") { CameraPicker(model: camera, zoom: store.uiZoom) }.help("Choose the camera shown behind your script")
          Picker("Rotation", selection: camera.rotationChoice) {
            ForEach(CameraModel.rotationOptions, id: \.0) { Text($0.0).tag($0.1) }
          }.help("Rotate the camera picture, or choose Automatic")
          Toggle("Mirror camera", isOn: $camera.mirrored).help("Flip the camera picture left to right")
            .task { camera.start() }
        }
      }
      Section("Text") {
        Picker("Font", selection: $store.settings.fontName) {
          ForEach(AvailableFonts.presenter, id: \.self, content: Text.init)
        }.help("Choose the font used in the presenter")
        ValueSlider("Size", value: $store.settings.fontSize, in: AppStore.presenterFontSizes,
          readout: "\(Int(store.settings.fontSize)) pt").help("Make the presenter text easier to read")
        Toggle("Mirror for teleprompter glass", isOn: $store.settings.horizontalMirror)
          .accessibilityLabel("Mirror for teleprompter glass")
          .help("Flip text left to right so it reads correctly in reflected glass")
      }
      Section {
        DisclosureGroup("More", isExpanded: Binding(get: { !store.simpleInterface }, set: { store.simpleInterface = !$0 })) {
          Group {
            Text("Voice").font(.headline)
          Picker("Spoken language", selection: $store.settings.speechLanguage) {
            Text("Mixed English & French").tag("Mixed")
            Text("Automatic (script language)").tag("Automatic")
            Text("English").tag("English")
            Text("French").tag("French")
            ForEach(supportedSpeechLocales.filter { !["en-GB", "fr-FR"].contains($0.identifier) }, id: \.identifier) { locale in
              Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
            }
          }.help("Choose the language you will speak; Automatic uses the script language")
          Toggle("Follow me when I repeat earlier words", isOn: $store.settings.allowsBackwardVoiceTracking).help("Allow the reading position to move back when you repeat a passage")
        LabeledContent("Microphone volume") {
          Slider(value: Binding(
            get: { gainDraft ?? store.settings.inputGain },
            set: { gainDraft = $0; session.setMicrophoneTestGain($0) }), in: 0.25...4
          ) { editing in if !editing { commitGain() } }
            .accessibilityLabel("Microphone volume")
            .accessibilityValue(String(format: "%.2f times", gainDraft ?? store.settings.inputGain))
        }
        .help("Adjust microphone volume; reduce it if the sound distorts")
        .task(id: gainDraft) {
          guard gainDraft != nil, (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
          commitGain()
        }
        LabeledContent("Loudest sound") {
          LoudestSoundReadout(meter: session.meter)
        }
          .help("dBFS measures sound against the microphone’s maximum level. Zero is the limit. Lower Microphone volume if the sound distorts.")
            Text("Layout").font(.headline)
        Slider(value: $store.settings.textWidth, in: PrompterSettings.textWidthRange) { Text("Text width") }.help("Narrow or widen the centred script column")
        Slider(value: $store.settings.textOpacity, in: 0.2...1) { Text("Text visibility") }.help("Make the script text more or less transparent")
        // One control, not a Prompter-only slider that did nothing over video beside a Video one.
        Slider(value: backdropOpacity, in: PrompterSettings.backdropOpacityRange(withVideo: camera.presentsWithVideo)) {
          Text("Background darkness")
        }.help("Make the backdrop darker; script-only and camera views keep separate values")
        Slider(value: $store.settings.guideFraction, in: 0.1...0.85) { Text("Reading line position") }.help("Move the line where your current words appear")
        Slider(value: $store.settings.guideOpacity, in: 0...1) { Text("Reading line visibility") }.help("Fade the reading line; zero hides it")
            Text("Typography").font(.headline)
          Picker("Text weight", selection: $store.settings.fontWeight) {
            Text("Regular").tag("Regular"); Text("Bold").tag("Bold")
          }.help("Choose regular or bold presenter text")
          Picker("Alignment", selection: $store.settings.alignment) {
            Text("Left").tag("Left"); Text("Centre").tag("Center"); Text("Right").tag("Right")
          }.help("Align the text within the script column")
          Slider(value: $store.settings.lineSpacing, in: 0...0.5) { Text("Line spacing") }.help("Adjust the space between lines")
          Slider(value: $store.settings.paragraphSpacing, in: 0...1) { Text("Paragraph spacing") }.help("Adjust the space between paragraphs")
          ColorPicker("Text colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.textColorHex) ?? .white) }, set: { store.settings.textColorHex = NSColor($0).hex }), supportsOpacity: false).help("Choose the script text colour")
          ColorPicker("Background colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black) }, set: { store.settings.backgroundColorHex = NSColor($0).hex }), supportsOpacity: false).help("Choose the background colour")
            Text("Presenter").font(.headline)
          Toggle("Mirror text top to bottom", isOn: $store.settings.verticalMirror).help("Flip text top to bottom for your teleprompter setup")
          Picker("Text rotation", selection: $store.settings.rotation) {
            Text("0°").tag(0)
            Text("180°").tag(180)
          }.help("Rotate the script by half a turn")
          Toggle("Show stage directions", isOn: $store.settings.showCues).help("Show bracketed stage directions alongside spoken text")
          Toggle("Align window to screen edges", isOn: $store.settings.presenterSnappingEnabled).help("Snap the presenter to screen edges or centre after dragging")
          Toggle("Highlight active word", isOn: $store.settings.highlightActiveWord).help("Mark the current word as the script follows you")
            Text("Editor text").font(.headline)
            Picker("Editor font", selection: $store.previewFontName) {
              ForEach(AvailableFonts.editor, id: \.self) { Text($0).tag($0) }
            }.help("Change the editor font; presenter text has its own settings")
            Stepper(value: $store.previewFontSize, in: AppStore.editorFontSizes, step: 1) {
              Text("Editor size  \(Int(store.previewFontSize)) pt").monospacedDigit()
            }.accessibilityLabel("Editor text size").help("Change text size while editing")
            Text("Saved settings").font(.headline)
        HStack {
          TextField("Name these settings", text: $presetName).help("Give the current presenter settings a name")
          Button("Save") { store.savePreset(named: presetName); presetName = "" }.help("Save the current presenter settings for reuse")
        }
        ForEach(store.presets) { preset in
          HStack {
            Button(preset.name) { store.applyPreset(preset) }.buttonStyle(.plain)
              .lineLimit(1).truncationMode(.tail)
              .help("Apply \(preset.name)")
            Spacer()
            Button("Delete \(preset.name)", systemImage: "trash") { store.deletePreset(preset.id) }
              .labelStyle(.iconOnly).buttonStyle(.plain)
              .help("Remove these saved settings; your script stays in the library")
          }.contextMenu {
            Button("Rename") { renamePreset = preset; renameValue = preset.name }.help("Change the name of these saved settings")
            Button("Duplicate") { store.duplicatePreset(preset.id) }.help("Make another copy of these saved settings")
            Button("Replace with current settings") { store.updatePreset(preset.id) }.help("Overwrite this saved set with the settings in use")
            Button("Delete", role: .destructive) { store.deletePreset(preset.id) }.help("Remove these saved settings")
          }
        }
          }
        }.accessibilityAction { store.simpleInterface.toggle() }
          .help("Show extra voice, layout, typography and saved settings")
      }
    }.formStyle(.grouped).onChange(of: store.simpleInterface) { _, _ in commitGain() }.task {
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
    }.alert("Following options changed", isPresented: Binding(
      get: { store.modeMigrationNotice != nil }, set: { if !$0 { store.dismissModeMigrationNotice() } })
    ) {
      Button("OK") {}
    } message: {
      Text(store.modeMigrationNotice ?? "")
    }.alert("Rename saved settings", isPresented: Binding(get: { renamePreset != nil }, set: { if !$0 { renamePreset = nil } })) {
      TextField("Name these settings", text: $renameValue).help("Enter a new name for these saved settings")
      Button("Save") { if let preset = renamePreset { store.renamePreset(preset.id, name: renameValue) }; renamePreset = nil }.help("Save the new name")
      Button("Cancel", role: .cancel) { renamePreset = nil }
    }
  }

  private var modePicker: some View {
    Picker("What to show", selection: $camera.displayMode) {
      Text("Script").tag(PresenterDisplayMode.prompterOnly)
      Text("Script and camera").tag(PresenterDisplayMode.prompterWithVideo)
      Text("Camera").tag(PresenterDisplayMode.videoOnly)
    }.labelsHidden().accessibilityLabel("What to show").help("Show the script, the camera picture, or both in the presenter")
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
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
        Spacer()
        Text(readout).font(.caption).monospacedDigit().foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }
      Slider(value: $value, in: range) { Text(title) }.labelsHidden().accessibilityLabel(title)
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

/// The microphone test's button, meter and notice: the only part of the form that shows session state.
private struct MicrophoneTestRow: View {
  @ObservedObject var session: SessionStore
  let deviceUID: String?
  let gain: Double
  var body: some View {
    HStack(spacing: 12) {
      Button(session.isTestingMicrophone ? "Stop test" : "Test") {
        if session.isTestingMicrophone { session.stopMicrophoneTest() }
        else { session.startMicrophoneTest(deviceUID: deviceUID, gain: gain) }
      }.help("Check your microphone before presenting")
        .disabled(!session.isTestingMicrophone && deviceUID == nil)
      LiveInputLevelMeter(meter: session.meter)
    }
    if let notice = session.microphoneTestNotice {
      Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
    }
  }
}

/// The meter observes the level on its own, so only it redraws as the level moves, not the form.
private struct LiveInputLevelMeter: View {
  @ObservedObject var meter: InputMeter
  var body: some View {
    InputLevelMeter(peakDBFS: meter.peakDBFS, isClipping: meter.isClipping, showsScale: false)
  }
}

private struct LoudestSoundReadout: View {
  @ObservedObject var meter: InputMeter
  var body: some View {
    HStack {
      if meter.isClipping {
        Label("Sound distortion", systemImage: "exclamationmark.triangle.fill")
          .labelStyle(.iconOnly).foregroundStyle(.red).help("Lower Microphone volume if the input is distorted")
      }
      Text(meter.peakDBFS.isFinite ? String(format: "%.1f dBFS", meter.peakDBFS) : "−∞ dBFS")
        .monospacedDigit().lineLimit(1).fixedSize()
    }
  }
}

struct InputLevelMeter: View {
  let peakDBFS: Float
  let isClipping: Bool
  var showsScale = true
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
        if showsScale {
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
    }
    .frame(height: showsScale ? 30 : 12)
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
