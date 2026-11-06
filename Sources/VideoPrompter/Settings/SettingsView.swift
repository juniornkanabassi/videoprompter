import SwiftUI
import Speech
import AppKit
import CoreText

/// Only presenter appearance lives beside the script. App preferences have their own window.
struct InspectorView: View {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var store: AppStore
  @ObservedObject private var camera: CameraModel
  @State private var showsCameraSettings = false
  init(store: AppStore, camera: CameraModel = .shared) { self.store = store; self.camera = camera }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.xxl) {
      InspectorSection("Presenter") {
        VStack(alignment: .leading, spacing: Space.xs) {
          Text("What to show")
          InspectorChoice(title: "What to show", values: [.prompterOnly, .prompterWithVideo, .videoOnly],
            names: ["Script", "Script and camera", "Camera"], selection: $camera.displayMode)
        }.help("Show the script, the camera picture, or both")
        if camera.presentsWithVideo {
          Button("Camera Settings…") { showsCameraSettings = true }
            .buttonStyle(.link)
            .help("Choose the camera, its rotation and framing guides")
            .popover(isPresented: $showsCameraSettings, arrowEdge: .leading) {
              CameraSettingsPanel(model: camera, zoom: store.uiZoom).frame(width: 320).uiZoom(store.uiZoom)
            }
        }
      }
      InspectorSection("Text") {
        VStack(alignment: .leading, spacing: Space.xs) {
          Text("Font")
          InspectorChoice(title: "Font", values: AvailableFonts.presenter, names: AvailableFonts.presenter,
            selection: $store.settings.fontName)
        }.help("Choose the font used in the presenter")
        ValueSlider("Size", value: $store.settings.fontSize, in: AppStore.presenterFontSizes,
          readout: "\(Int(store.settings.fontSize)) pt").help("Make the presenter text easier to read")
        Toggle("Mirror for teleprompter glass", isOn: $store.settings.horizontalMirror)
          .accessibilityLabel("Mirror for teleprompter glass")
          .help("Flip text left to right for reflected glass")
      }
      InspectorSection("Layout") {
        ValueSlider("Text width", value: $store.settings.textWidth, in: PrompterSettings.textWidthRange, readout: "\(Int(store.settings.textWidth * 100))%")
          .help("Narrow or widen the centred script column")
        ValueSlider("Text visibility", value: $store.settings.textOpacity, in: 0.2...1, readout: "\(Int(store.settings.textOpacity * 100))%")
          .help("Make the script text more or less transparent")
        ValueSlider("Background darkness", value: backdropOpacity, in: PrompterSettings.backdropOpacityRange(withVideo: camera.presentsWithVideo), readout: "\(Int(backdropOpacity.wrappedValue * 100))%").help("Darken the backdrop; script and camera views keep separate values")
        ValueSlider("Reading guide position", value: $store.settings.guideFraction, in: 0.1...0.85, readout: "\(Int(store.settings.guideFraction * 100))%")
          .help("Move the line where your current words appear")
        ValueSlider("Reading guide visibility", value: $store.settings.guideOpacity, in: 0...1, readout: "\(Int(store.settings.guideOpacity * 100))%")
          .help("Fade the reading line; zero hides it")
      }
      InspectorSection("Typography") {
        VStack(alignment: .leading, spacing: Space.xs) {
          Text("Text weight")
          InspectorChoice(title: "Text weight", values: ["Regular", "Bold"], names: ["Regular", "Bold"], selection: $store.settings.fontWeight)
        }.help("Choose regular or bold presenter text")
        VStack(alignment: .leading, spacing: Space.xs) {
          Text("Alignment")
          InspectorChoice(title: "Alignment", values: ["Left", "Center", "Right"], names: ["Left", "Centre", "Right"], selection: $store.settings.alignment)
        }.help("Align the text within the script column")
        Slider(value: $store.settings.lineSpacing, in: 0...0.5) { Text("Line spacing") }.help("Adjust the space between lines")
        Slider(value: $store.settings.paragraphSpacing, in: 0...1) { Text("Paragraph spacing") }.help("Adjust the space between paragraphs")
        ColorPicker("Text colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.textColorHex) ?? .white) }, set: { store.settings.textColorHex = NSColor($0).hex }), supportsOpacity: false).help("Choose the script text colour")
        ColorPicker("Background colour", selection: Binding(get: { Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black) }, set: { store.settings.backgroundColorHex = NSColor($0).hex }), supportsOpacity: false)
          .help("Choose the background colour")
      }
      InspectorSection("Advanced") {
        DisclosureGroup("Mirroring and cues", isExpanded: Binding(get: { !store.simpleInterface }, set: { store.simpleInterface = !$0 })) {
          Toggle("Mirror text top to bottom", isOn: $store.settings.verticalMirror)
            .help("Flip text top to bottom for your teleprompter setup")
          Picker("Text rotation", selection: $store.settings.rotation) {
            Text("0°").tag(0); Text("180°").tag(180)
          }.help("Rotate the script by half a turn")
          Toggle("Show stage directions", isOn: $store.settings.showCues)
            .help("Show bracketed stage directions alongside spoken text")
          Toggle("Highlight active word", isOn: $store.settings.highlightActiveWord)
            .help("Mark the current word as the script follows you")
        }.accessibilityAction { store.simpleInterface.toggle() }
          .help("Show the presenter's mirroring, rotation and cue options")
      }
      }.padding(Space.lg)
    }
      .foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
      .scrollContentBackground(.hidden)
      .background(LibraryAppearance.color(.windowBackgroundColor, scheme: colorScheme))
      .environment(\.colorScheme, colorScheme).preferredColorScheme(colorScheme)
  }

  private var backdropOpacity: Binding<Double> {
    Binding(get: { store.settings.backdropOpacity(withVideo: camera.presentsWithVideo) },
      set: { store.settings.setBackdropOpacity($0, withVideo: camera.presentsWithVideo) })
  }
}

enum SettingsTab: String, CaseIterable {
  case general = "General", voice = "Voice", editor = "Editor", presets = "Presets"
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .voice: "mic"
    case .editor: "textformat"
    case .presets: "slider.horizontal.3"
    }
  }
}

struct AppSettingsView: View {
  @ObservedObject var store: AppStore
  @State private var selection: SettingsTab
  @SceneStorage("settingsTab") private var savedTab = SettingsTab.general.rawValue
  private let selectedTab: SettingsTab?
  init(store: AppStore, selectedTab: SettingsTab? = nil) {
    self.store = store
    self.selectedTab = selectedTab
    _selection = State(initialValue: selectedTab ?? .general)
  }
  static let width: CGFloat = 560
  private var height: CGFloat {
    switch selection {
    case .general: 300
    case .voice: 520
    case .editor: 240
    case .presets: min(600, 280 + CGFloat(store.presets.count) * 40)
    }
  }
  var body: some View {
    TabView(selection: $selection) {
      ForEach(SettingsTab.allCases, id: \.self) { tab in
        // Zoom inside the page, not the TabView: the window and its native tabs stay one size and
        // the Form scrolls in its fixed viewport, rather than the window doubling at 200%.
        SettingsPage(store: store, tab: tab).uiZoom(store.uiZoom)
          .tabItem { Label(tab.rawValue, systemImage: tab.symbol) }.tag(tab)
      }
    }.frame(width: Self.width, height: height)
      .onAppear { if selectedTab == nil { selection = SettingsTab(rawValue: savedTab) ?? .general } }
      .onChange(of: selection) { _, tab in savedTab = tab.rawValue }
  }
}

/// Also rendered directly by the headless snapshot check so every tab is covered.
struct SettingsPage: View {
  @ObservedObject var store: AppStore
  let tab: SettingsTab
  @Environment(\.undoManager) private var undoManager
  @State private var presetName = ""
  @State private var renamePreset: PrompterSettings?
  @State private var renameValue = ""

  var body: some View {
    // Voice owns its Form so its lifecycle hangs on the page, not on a lazily loaded section.
    if tab == .voice { VoiceSettingsPage(store: store) } else { form }
  }

  private var form: some View {
    Form {
      switch tab {
      case .general:
        Section {
          Picker("How it follows you", selection: $store.settings.mode) {
            Text("Voice").tag("Voice"); Text("Manual").tag("Manual")
          }.pickerStyle(.radioGroup).help("Follow spoken words or scroll at a steady speed")
          if store.settings.mode == "Manual" {
            ValueSlider("Speed", value: $store.settings.speed, in: 20...300,
              readout: "\(Int(store.settings.speed)) words per minute")
              .help("Set how fast Manual moves through your script")
          }
        } header: { Text("Following") } footer: {
          Text("Voice follows the words you say. Manual scrolls at a steady speed.")
        }
        Section("Windows") {
          Picker("Interface size", selection: $store.uiZoom) {
            ForEach(AppStore.uiZoomSteps, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
          }.help("Make the library, inspector and Settings controls larger or smaller")
          Toggle("Align presenter to screen edges", isOn: $store.settings.presenterSnappingEnabled)
            .help("Snap the presenter to screen edges or centre after dragging")
        }
      case .voice:
        EmptyView()
      case .editor:
        Section {
          Picker("Editor font", selection: $store.previewFontName) {
            ForEach(AvailableFonts.editor, id: \.self) { Text($0).tag($0) }
          }.help("Change the editor font; presenter text has its own settings")
          Stepper(value: $store.previewFontSize, in: AppStore.editorFontSizes, step: 1) {
            Text("Editor size  \(Int(store.previewFontSize)) pt").monospacedDigit()
          }.accessibilityLabel("Editor text size").help("Change text size while editing")
        } header: { Text("Editor text") } footer: { Text("Presenter text is set separately in the Presenter inspector.") }
      case .presets:
        Section("Save current presenter settings") {
          TextField("Preset name", text: $presetName, prompt: Text("For example, Studio"))
            .help("Give the current presenter settings a name")
          Button("Save Preset") { store.savePreset(named: presetName); presetName = "" }
            .help("Save the current presenter settings for reuse")
        }
        Section {
          if store.presets.isEmpty { Text("Saved presets appear here.").foregroundStyle(.secondary) }
          ForEach(store.presets) { preset in
            HStack {
              Button(preset.name) { store.applyPreset(preset) }.buttonStyle(.plain)
                .lineLimit(1).truncationMode(.tail).help("Apply \(preset.name)")
              Spacer()
              Button("Delete \(preset.name)", systemImage: "trash") { store.deletePreset(preset.id, undoManager: undoManager) }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("Remove this preset; choose Edit > Undo to restore it")
            }.contextMenu {
              Button("Rename…") { renamePreset = preset; renameValue = preset.name }
                .help("Change the name of these saved settings")
              Button("Duplicate") { store.duplicatePreset(preset.id) }.help("Make another copy of these saved settings")
              Button("Replace with Current Settings") { store.updatePreset(preset.id) }
                .help("Overwrite this preset with the settings in use")
              Button("Delete", role: .destructive) { store.deletePreset(preset.id, undoManager: undoManager) }
                .help("Remove this preset; choose Edit > Undo to restore it")
            }
          }
        } header: { Text("Saved settings") } footer: { Text("Applying a preset keeps your microphone and spoken language.") }
      }
    }.formStyle(.grouped)
      .alert("Rename Saved Settings", isPresented: Binding(get: { renamePreset != nil }, set: { if !$0 { renamePreset = nil } })) {
        TextField("Preset name", text: $renameValue).help("Enter a new name for these saved settings")
        Button("Save") { if let preset = renamePreset { store.renamePreset(preset.id, name: renameValue) }; renamePreset = nil }
        Button("Cancel", role: .cancel) { renamePreset = nil }
      }

  }
}

private struct VoiceSettingsPage: View {
  @ObservedObject var store: AppStore
  @State private var devices: [AudioInputDevice] = []
  @State private var deviceObserver: AudioInputDeviceObserver?
  @State private var supportedSpeechLocales: [Locale] = []
  @State private var gainDraft: Double?
  private var session: SessionStore { store.session }

  var body: some View {
    Form { sections }.formStyle(.grouped)
    .task { supportedSpeechLocales = await SpeechTranscriber.supportedLocales }
    .task(id: gainDraft) {
      guard gainDraft != nil, (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
      commitGain()
    }
    .onAppear {
      devices = AudioCapture.inputDevices()
      deviceObserver = AudioCapture.inputDeviceObserver {
        let available = AudioCapture.inputDevices()
        devices = available
        session.microphoneDevicesDidChange(available)
      }
    }
    .onDisappear { commitGain(); deviceObserver = nil; session.stopMicrophoneTest() }
  }

  @ViewBuilder private var sections: some View {
    Section {
      Picker("Microphone", selection: Binding(
        get: { store.settings.audioDeviceUID ?? "" },
        set: { session.stopMicrophoneTest(); store.settings.audioDeviceUID = $0.isEmpty ? nil : $0 })
      ) {
        Text("Choose a microphone").tag("")
        if let uid = store.settings.audioDeviceUID, !devices.contains(where: { $0.uid == uid }) {
          Text("Selected microphone unavailable").tag(uid)
        }
        ForEach(devices) { Text($0.name).tag($0.uid) }
      }.help("Choose the microphone that Voice listens to")
      MicrophoneTestRow(session: session, deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain)
      LabeledContent("Microphone volume") {
        Slider(value: Binding(get: { gainDraft ?? store.settings.inputGain },
          set: { gainDraft = $0; session.setMicrophoneTestGain($0) }), in: 0.25...4
        ) { editing in if !editing { commitGain() } }
          .accessibilityLabel("Microphone volume")
          .accessibilityValue(String(format: "%.2f times", gainDraft ?? store.settings.inputGain))
      }.help("Reduce the volume if the sound distorts")
      LabeledContent("Loudest sound") { LoudestSoundReadout(meter: session.meter) }
    } header: { Text("Microphone") } footer: { Text("Zero dBFS is the microphone's maximum level. Lower the volume if the sound distorts.") }
    Section("Recognition") {
      Picker("Spoken language", selection: $store.settings.speechLanguage) {
        Text("Mixed English & French").tag("Mixed")
        Text("Automatic (script language)").tag("Automatic")
        Text("English").tag("English"); Text("French").tag("French")
        ForEach(supportedSpeechLocales.filter { !["en-GB", "fr-FR"].contains($0.identifier) }, id: \.identifier) { locale in
          Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
        }
      }.help("Choose the language you will speak; Automatic uses the script language")
      Toggle("Follow me when I repeat earlier words", isOn: $store.settings.allowsBackwardVoiceTracking)
        .help("Allow the reading position to move back when you repeat a passage")
    }
  }
  private func commitGain() {
    guard let gain = gainDraft else { return }
    gainDraft = nil
    store.settings.inputGain = gain
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
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
        Spacer()
        Text(readout).font(.caption).monospacedDigit().foregroundStyle(.primary)
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
