import SwiftUI
import Speech
import AppKit
import CoreText

// Keep both entry points on the same reading configuration.
typealias InspectorView = ReadingInspectorView

enum SettingsTab: String, CaseIterable {
  case general = "General", reading = "Reading", voice = "Voice", editor = "Editor", presets = "Saved settings"
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .reading: "text.book.closed"
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
  static var requestedTab: SettingsTab?
  static func requestVoiceTab() { requestTab(.voice) }
  static func requestTab(_ tab: SettingsTab) {
    requestedTab = tab
    NotificationCenter.default.post(name: .init("VideoPrompter.voiceSettings"), object: nil)
  }
  static let width: CGFloat = 560
  private var height: CGFloat {
    switch selection {
    case .general: 300
    case .reading: 580
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
      .onAppear {
        selection = Self.requestedTab ?? selectedTab ?? SettingsTab(rawValue: savedTab) ?? .general
        Self.requestedTab = nil
      }
      .onReceive(NotificationCenter.default.publisher(for: .init("VideoPrompter.voiceSettings"))) { _ in selection = Self.requestedTab ?? .voice; Self.requestedTab = nil }
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
  @State private var replacingPreset: PrompterSettings?
  @State private var appliedPreset: PrompterSettings?

  var body: some View {
    // Voice owns its Form so its lifecycle hangs on the page, not on a lazily loaded section.
    if tab == .voice { VoiceSettingsPage(store: store) } else if tab == .reading { InspectorView(store: store) } else { form }
  }

  private var form: some View {
    Form {
      switch tab {
      case .general:
        Section("Reading") {
          Button("Open Reading settings…") { AppSettingsView.requestTab(.reading) }
          Text("Reading mode, text and layout have one home in Reading.").font(.callout)
        }
        Section("Windows") {
          Picker("Interface size", selection: $store.uiZoom) {
            ForEach(AppStore.uiZoomSteps, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
          }.help("Make the library, inspector and Settings controls larger or smaller")
          Toggle("Align presenter to screen edges", isOn: $store.settings.presenterSnappingEnabled)
            .help("Snap the presenter to screen edges or centre after dragging")
        }
      case .voice, .reading:
        EmptyView()
      case .editor:
        Section {
          VStack(alignment: .leading) {
            Text("Editor font")
            InspectorChoice(title: "Editor font", values: AvailableFonts.editor, names: AvailableFonts.editor, selection: $store.previewFontName)
          }.help("Change the editor font; presenter text has its own settings")
          Stepper(value: $store.previewFontSize, in: AppStore.editorFontSizes, step: 1) {
            Text("Editor size  \(Int(store.previewFontSize)) pt").monospacedDigit()
          }.accessibilityLabel("Editor text size").help("Change text size while editing")
        } header: { Text("Editor text") } footer: { Text("Change the presenter text in Reading settings. Editor text only affects writing here.") }
      case .presets:
        Section("Save current presenter settings") {
          TextField("Settings name", text: $presetName, prompt: Text("For example, Studio"))
            .help("Give the current presenter settings a name")
          Button("Save Settings") {
            if let existing = store.presets.first(where: { $0.name == presetName.trimmingCharacters(in: .whitespacesAndNewlines) }) { replacingPreset = existing }
            else { store.savePreset(named: presetName); presetName = "" }
          }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Save the current presenter settings for reuse")
        }
        Section {
          if store.presets.isEmpty { Text("Your saved settings appear here.").foregroundStyle(.secondary) }
          ForEach(store.presets) { preset in
            VStack(alignment: .leading, spacing: Space.sm) {
              HStack {
                Text(preset.name).font(.headline)
                Spacer()
                if store.matchesPreset(preset) { Label("In use", systemImage: "checkmark.circle") }
                Button("Apply") { store.applyPreset(preset); appliedPreset = preset }
                  .accessibilityLabel("Apply \(preset.name)")
                Menu {
                  Button("Rename…") { renamePreset = preset; renameValue = preset.name }
                  Button("Duplicate") { store.duplicatePreset(preset.id) }
                  Button("Replace with Current Settings…") { replacingPreset = preset }
                  Button("Delete", role: .destructive) { store.deletePreset(preset.id, undoManager: undoManager) }
                } label: { Label("Actions", systemImage: "ellipsis.circle") }
                .accessibilityLabel("Actions for \(preset.name)")
              }
              Text(preset.readingSummary).font(.callout).fixedSize(horizontal: false, vertical: true)
              if appliedPreset?.id == preset.id {
                Text(store.matchesPreset(preset) ? "Applied \(preset.name)" : "Modified since applying \(preset.name)").font(.callout)
              }
            }.contextMenu {
              Button("Rename…") { renamePreset = preset; renameValue = preset.name }
                .help("Change the name of these saved settings")
              Button("Duplicate") { store.duplicatePreset(preset.id) }.help("Make another copy of these saved settings")
              Button("Replace with Current Settings") { replacingPreset = preset }
                .help("Replace these saved settings with the settings in use")
              Button("Delete", role: .destructive) { store.deletePreset(preset.id, undoManager: undoManager) }
                .help("Remove these saved settings; choose Edit > Undo to restore it")
            }
          }
        } header: { Text("Saved settings") } footer: { Text("Applies reading mode, speed, text appearance and presenter layout. Keeps your microphone and spoken language.") }
      }
    }.formStyle(.grouped)
      .confirmationDialog("Replace \(replacingPreset?.name ?? "saved settings")?", isPresented: Binding(get: { replacingPreset != nil }, set: { if !$0 { replacingPreset = nil } })) {
        Button("Replace", role: .destructive) { if let preset = replacingPreset { store.updatePreset(preset.id) }; replacingPreset = nil; presetName = "" }
        Button("Cancel", role: .cancel) { replacingPreset = nil }
      } message: { Text("This replaces the saved reading mode, speed, appearance and layout with your current settings. Your microphone and spoken language stay unchanged when you apply them.") }
      .alert("Rename Saved Settings", isPresented: Binding(get: { renamePreset != nil }, set: { if !$0 { renamePreset = nil } })) {
        TextField("Settings name", text: $renameValue).help("Enter a new name for these saved settings")
        Button("Save") { if let preset = renamePreset { store.renamePreset(preset.id, name: renameValue) }; renamePreset = nil }
          .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
  @ObservedObject private var recorder = CameraRecorder.shared
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
      Picker("Voice-follow microphone", selection: Binding(
        get: { store.settings.audioDeviceUID ?? "" },
        set: { session.stopMicrophoneTest(); store.settings.audioDeviceUID = $0.isEmpty ? nil : $0 })
      ) {
        Text("Choose a microphone").tag("")
        if let uid = store.settings.audioDeviceUID, !devices.contains(where: { $0.uid == uid }) {
          Text("Selected microphone unavailable").tag(uid)
        }
        ForEach(devices) { Text($0.name).tag($0.uid) }
      }.help("Choose the microphone that Voice listens to")
      Text("Used for following your words, not automatically for the saved take.").font(.callout)
      Text("Recording mic: \(recorder.microphoneName)").fixedSize(horizontal: false, vertical: true)
      Button("Use this microphone for recording") { recorder.microphoneUID = store.settings.audioDeviceUID }
        .disabled(recorder.isRecording || recorder.isBusy || store.settings.audioDeviceUID == nil)
      RecordingSettingsLink(store: store)
      Text("Voice follow mic: \(devices.first(where: { $0.uid == store.settings.audioDeviceUID })?.name ?? "Choose a microphone")").fixedSize(horizontal: false, vertical: true)
      MicrophoneTestRow(session: session, deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain)
      VStack(alignment: .leading, spacing: Space.sm) {
        Text("Microphone volume")
        Slider(value: Binding(get: { gainDraft ?? store.settings.inputGain },
          set: { gainDraft = $0; session.setMicrophoneTestGain($0) }), in: 0.25...4
        ) { editing in if !editing { commitGain() } }
          .accessibilityLabel("Microphone volume")
          .accessibilityValue(String(format: "%.2f times", gainDraft ?? store.settings.inputGain))
      }.help("Reduce the volume if the sound distorts")
      LabeledContent("Loudest sound") { LoudestSoundReadout(meter: session.meter) }
    } header: { Text("Microphone") } footer: { Text("Press Test microphone and speak normally. If you see Sound too loud, lower Microphone volume. The dBFS number is a technical level; 0 is the maximum.") }
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
      Slider(value: $value, in: range) { Text(title) }.labelsHidden().accessibilityLabel(title).accessibilityValue(readout.replacingOccurrences(of: "%", with: " percent").replacingOccurrences(of: " pt", with: " points"))
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
    VStack(alignment: .leading, spacing: Space.sm) {
      Button(session.isTestingMicrophone ? "Stop test" : "Test microphone") {
        if session.isTestingMicrophone { session.stopMicrophoneTest() }
        else { session.startMicrophoneTest(deviceUID: deviceUID, gain: gain) }
      }.help("Check your microphone before presenting")
        .disabled(!session.isTestingMicrophone && deviceUID == nil)
      LiveInputLevelMeter(meter: session.meter)
    }
    if deviceUID == nil { Text("Choose a microphone above to test it.").font(.callout) }
    if let notice = session.microphoneTestNotice {
      Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.primary)
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
        Label("Sound too loud", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red).help("Lower Microphone volume if the input is distorted")
      }
      Text(meter.peakDBFS.isFinite ? "Sound detected · " + String(format: "%.1f dBFS", meter.peakDBFS) : "No sound yet")
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


private struct RecordingSettingsLink: View {
  @ObservedObject var store: AppStore
  @State private var showsSettings = false
  var body: some View {
    Button("Recording input…") { showsSettings = true }
      .accessibilityLabel("Recording microphone and input test")
      .popover(isPresented: $showsSettings) {
        RecordingSettingsPanel(recorder: .shared, camera: .shared, zoom: store.uiZoom).frame(width: 420, height: 560).uiZoom(store.uiZoom)
      }
  }
}
