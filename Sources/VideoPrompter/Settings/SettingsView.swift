import PrompterCore
import SwiftUI
import Combine
import Speech
import AppKit
import CoreText
@preconcurrency import AVFoundation


enum SettingsTab: String, CaseIterable {
  case general = "General", reading = "Reading", presets = "Reading presets", shootSetups = "Shoot setups", microphone = "Microphone", camera = "Camera & Recording"
  static var allCases: [SettingsTab] { [.reading, .camera, .microphone, .general] }
  var label: String { self == .camera ? "Camera and monitor" : self == .general ? "App" : rawValue }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .reading: "text.book.closed"
    case .microphone: "mic"
    case .camera: "video"
    case .presets: "slider.horizontal.3"
    case .shootSetups: "camera.badge.ellipsis"
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
  static func requestVoiceTab() { requestTab(.microphone) }
  static func requestTab(_ tab: SettingsTab) {
    requestedTab = tab
    NotificationCenter.default.post(name: .init("VideoPrompter.microphoneSettings"), object: nil)
  }
  private var availableSize: CGSize {
    let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
    return CGSize(width: min(880 * store.uiZoom, screen.width - 80), height: min(600 * store.uiZoom, screen.height - 80))
  }
  private func navigationLabel(_ tab: SettingsTab, width: CGFloat) -> some View {
    HStack(spacing: Space.sm) {
      Image(systemName: tab.symbol).frame(width: 20)
      Text(tab.label).lineLimit(nil).frame(width: max(60, width - 64), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
  var body: some View {
    GeometryReader { geometry in
      let sidebarWidth = min(250 * store.uiZoom, geometry.size.width * 0.34)
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: Space.xs) {
          ForEach(SettingsTab.allCases, id: \.self) { tab in
            Button { selection = tab } label: {
              navigationLabel(tab, width: sidebarWidth / store.uiZoom)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .background(selection == tab ? AlphaStyle.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel(tab.label).accessibilityAddTraits(selection == tab ? .isSelected : [])
          }
          Spacer()
        }.padding(Space.sm).uiZoom(store.uiZoom)
          .frame(width: sidebarWidth).frame(maxHeight: .infinity)
          .accessibilityElement(children: .contain).accessibilityLabel("Settings page")
        SettingsPage(store: store, tab: selection).uiZoom(store.uiZoom)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }.frame(minWidth: 720, idealWidth: availableSize.width, minHeight: 480, idealHeight: availableSize.height).background(CalmInitialFocus())
      .onAppear {
        selection = Self.requestedTab ?? selectedTab ?? SettingsTab(rawValue: savedTab) ?? .general
        Self.requestedTab = nil
      }
      .onReceive(NotificationCenter.default.publisher(for: .init("VideoPrompter.microphoneSettings"))) { _ in selection = Self.requestedTab ?? .microphone; Self.requestedTab = nil }
      .onChange(of: selection) { _, tab in savedTab = tab.rawValue }
  }
}

/// Also rendered directly by the headless snapshot check so every tab is covered.
struct SettingsPage: View {
  @Environment(\.colorScheme) private var scheme
  @ObservedObject var store: AppStore
  let tab: SettingsTab
  var cameraSection = "Camera"
  @Environment(\.undoManager) private var undoManager
  @State private var presetName = ""
  @State private var renamePreset: PrompterSettings?
  @State private var renameValue = ""
  @State private var appliedPreset: PrompterSettings?
  @State private var replacedPreset: PrompterSettings?
  @State private var replacementUndoID: UUID?
  /// An exact existing name means the button replaces that preset, and must say so.
  static func presetToReplace(_ name: String, in presets: [PrompterSettings]) -> PrompterSettings? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : presets.first { $0.name == trimmed }
  }

  var body: some View {
    // Voice owns its Form so its lifecycle hangs on the page, not on a lazily loaded section.
    Group {
      if tab == .microphone { MicrophonePage(store: store) } else if tab == .reading { readingPage } else if tab == .camera { CameraRecordingPage(store: store, section: cameraSection) } else if tab == .general { titledPage("App") { form } } else { form }
    }.foregroundStyle(LibraryAppearance.color(.labelColor, scheme: scheme))
  }

  private func titledPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(.system(size: 28, weight: .bold)).padding(.horizontal, AlphaStyle.panelInset).padding(.top, AlphaStyle.panelInset).padding(.bottom, Space.xxl)
      content().font(.system(size: 15)).controlSize(.large).buttonStyle(SettingsFormButtonStyle())
    }
  }

  private var readingPage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text("Reading").font(.system(size: 28, weight: .bold)).padding(.bottom, Space.xxl)
        ReadingSettingsPage(store: store).font(.system(size: 15)).controlSize(.large).buttonStyle(SettingsFormButtonStyle()).frame(minHeight: 700)
        SettingsPage(store: store, tab: .presets).frame(minHeight: 500)
      }.padding(AlphaStyle.panelInset)
    }
  }

  private var form: some View {
    Form {
      switch tab {
      case .general:
        Section {
          Picker("Interface size", selection: $store.uiZoom) {
            ForEach(AppStore.uiZoomSteps, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
          }
        }
        Section { EditorTextControls(store: store) }
        header: { Text("Writing") }
        footer: { Text("Changes only the writing surface.").font(.callout).foregroundStyle(.primary) }
        IPadSettingsSection(store: store)
        Section("Windows") {
          Toggle("Align presenter to screen edges", isOn: $store.settings.presenterSnappingEnabled)
        }
      case .microphone, .reading, .camera:
        EmptyView()
      case .shootSetups:
        ShootSetupSection(store: store, camera: .shared, recorder: .shared)
      case .presets:
        let existing = Self.presetToReplace(presetName, in: store.presets)
        Section("Save current reading settings") {
          TextField("Preset name", text: $presetName, prompt: Text("For example, Studio"))
            .help("Give the current presenter settings a name")
          Button(existing.map { "Replace “\($0.name)”" } ?? "Save reading preset") {
            if let existing { replacementUndoID = store.updatePreset(existing.id, undoManager: undoManager) } else { store.savePreset(named: presetName) }
            replacedPreset = existing; presetName = ""
          }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(existing == nil ? "Save the current presenter settings for reuse" : "Change this saved look to the current settings")
          if let existing { Text("“\(existing.name)” already exists. Its saved look will change to the current settings.").font(.callout) }
          if let replacedPreset {
            PresetReplacementReceipt(store: store, preset: replacedPreset, operationID: replacementUndoID,
              manager: undoManager) { self.replacedPreset = nil }
          }
        }
        Section {
          if store.presets.isEmpty { Text("Your reading presets appear here.").font(.callout).foregroundStyle(.primary) }
          ForEach(store.presets) { preset in
            VStack(alignment: .leading, spacing: Space.sm) {
              HStack {
                Text(preset.name).font(.headline)
                Spacer()
                if store.matchesPreset(preset) { Label("In use", systemImage: "checkmark.circle") }
                Button("Apply") { store.applyPreset(preset, undoManager: undoManager); appliedPreset = preset }
                  .accessibilityLabel("Apply \(preset.name)")
                Menu {
                  Button("Rename…") { renamePreset = preset; renameValue = preset.name }
                  Button("Duplicate") { store.duplicatePreset(preset.id) }
                  Button("Replace with current settings") { store.updatePreset(preset.id, undoManager: undoManager) }
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
                .help("Change the name of this reading preset")
              Button("Duplicate") { store.duplicatePreset(preset.id) }.help("Make another copy of this reading preset")
              Button("Replace with current settings") { store.updatePreset(preset.id, undoManager: undoManager) }
                .help("Replace this reading preset with the settings in use")
              Button("Delete", role: .destructive) { store.deletePreset(preset.id, undoManager: undoManager) }
                .help("Remove this reading preset; choose Edit > Undo to restore it")
            }
          }
        } header: { Text("Reading presets").foregroundStyle(.primary) } footer: { Text("Applies reading mode, speed, text appearance and presenter layout. Keeps your microphone and spoken language.").foregroundStyle(.primary) }
      }
    }.formStyle(.grouped).font(.system(size: 15)).controlSize(.large)
      .alert("Rename reading preset", isPresented: Binding(get: { renamePreset != nil }, set: { if !$0 { renamePreset = nil } })) {
        TextField("Preset name", text: $renameValue).help("Enter a new name for this reading preset")
        Button("Save") { if let preset = renamePreset { store.renamePreset(preset.id, name: renameValue) }; renamePreset = nil }
          .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel", role: .cancel) { renamePreset = nil }
      }

  }
}

/// The receipt must never undo an unrelated action that has since reached the top of the stack.
struct PresetReplacementReceipt: View {
  @ObservedObject var store: AppStore
  let preset: PrompterSettings
  let operationID: UUID?
  let manager: UndoManager?
  var onUndo: () -> Void = {}
  @State private var canUndo = false

  var body: some View {
    HStack(spacing: Space.sm) {
      Text("Replaced “\(preset.name)”")
      if canUndo {
        Button("Undo") {
          if store.undoPresetReplacement(operationID, manager: manager) { onUndo() }
          refresh()
        }
      }
    }.font(.callout)
      .onAppear { refresh() }
      .onChange(of: store.presets) { refresh() }
      .onReceive(Publishers.MergeMany([
        Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange
      ].map { NotificationCenter.default.publisher(for: $0, object: manager) })) { _ in refresh() }
  }

  private func refresh() { canUndo = store.canUndoPresetReplacement(operationID, manager: manager) }
}

typealias VoiceSettingsPage = MicrophonePage

struct MicrophonePage: View {
  @ObservedObject var store: AppStore
  var compact = false
  var startsMeter = true
  @State private var devices: [AudioInputDevice] = []
  @State private var deviceObserver: AudioInputDeviceObserver?
  @State private var supportedSpeechLocales: [Locale] = []
  @State private var gainDraft: Double?
  @State private var advanced = false
  @ObservedObject var recorder = CameraRecorder.shared
  private var session: SessionStore { store.session }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !compact { Text("Microphone").font(.system(size: 28, weight: .bold)).padding(.horizontal, AlphaStyle.panelInset).padding(.top, AlphaStyle.panelInset).padding(.bottom, Space.xxl) }
      Form { sections }.formStyle(.grouped).font(.system(size: 15)).controlSize(.large).buttonStyle(SettingsFormButtonStyle())
    }
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
    .onChange(of: store.settings.audioDeviceUID) { _, _ in
      recorder.useSettings(store.settings)
      advanced = recorder.usesSeparateMicrophone
      if compact && startsMeter && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { session.startMicrophoneTest(deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain) }
    }
    .onAppear {
      recorder.useSettings(store.settings)
      advanced = recorder.usesSeparateMicrophone
      if compact && startsMeter && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { session.startMicrophoneTest(deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain) }
    }
    .onDisappear { commitGain(); deviceObserver = nil; session.stopMicrophoneTest(); recorder.stopInputTest() }
  }

  @ViewBuilder private var sections: some View {
    Section("Microphone") {
      if !compact { Text(Features.recording ? "Video Prompter listens to this microphone to follow your words, and records it with your video." : "Video Prompter listens to this microphone to follow your words.").font(.callout) }
      LabeledContent("Microphone") {
      Menu {
        Picker("Microphone", selection: Binding(
          get: { store.settings.audioDeviceUID ?? "" },
          set: { session.stopMicrophoneTest(); store.settings.audioDeviceUID = $0.isEmpty ? nil : $0 })
        ) {
          Text("System default").tag("")
          if let uid = store.settings.audioDeviceUID, !devices.contains(where: { $0.uid == uid }) { Text("Selected microphone unavailable").tag(uid) }
          ForEach(devices) { Text($0.name).tag($0.uid) }
        }.pickerStyle(.inline)
      } label: { Text(microphoneName).fixedSize(horizontal: false, vertical: true) }
        .accessibilityLabel("Microphone").accessibilityValue(microphoneName).help(microphoneName)
        .disabled(recorder.settingsLocked && !recorder.usesSeparateMicrophone)
        .initialPopoverFocus(when: !recorder.settingsLocked || recorder.usesSeparateMicrophone)
      }
      if compact { LiveInputLevelMeter(meter: session.meter) }
      else { MicrophoneTestRow(session: session, deviceUID: store.settings.audioDeviceUID, gain: store.settings.inputGain, micName: microphoneName) }
      LabeledContent("Loudest sound") { LoudestSoundReadout(meter: session.meter) }
      MicrophoneVolumeControl(value: Binding(get: { gainDraft ?? store.settings.inputGain }, set: {
        gainDraft = $0; session.setMicrophoneTestGain($0)
      })).initialPopoverFocus(when: recorder.settingsLocked && !recorder.usesSeparateMicrophone)
    }
    if !compact {
    Section("Listening") {
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
    PermissionSection()
    if Features.recording {
    Section {
      DisclosureGroup("Advanced", isExpanded: $advanced) {
        Toggle("Record from a different microphone", isOn: $recorder.usesSeparateMicrophone)
          .disabled(recorder.settingsLocked).help("Stop recording to change this")
        if recorder.usesSeparateMicrophone { RecordingMicrophoneSection(recorder: recorder) }
      }
    }
    }
  }
  }
  private var microphoneName: String {
    devices.first(where: { $0.uid == store.settings.audioDeviceUID })?.name ?? (store.settings.audioDeviceUID == nil ? "System default" : "Selected microphone unavailable")
  }
  private func commitGain() {
    guard let gain = gainDraft else { return }
    gainDraft = nil
    store.settings.inputGain = gain
  }
}

/// Gain affects speech following and its test meter, never the saved recording or speakers.
struct MicrophoneVolumeControl: View {
  @Binding var value: Double
  static func stepped(_ value: Double, by step: Int) -> Double {
    min(4, max(0.25, (value * 100).rounded() / 100 + Double(step) / 100))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack {
        Text("Microphone volume")
        Spacer()
        Text("\(Int((value * 100).rounded()))%")
          .monospacedDigit().accessibilityLabel("Microphone volume value")
      }
      ReadingSlider(value: $value, range: 0.25...4, title: "Microphone volume",
        spokenValue: "\(Int((value * 100).rounded())) percent")
      HStack {
        Button("−1%") { value = Self.stepped(value, by: -1) }
          .accessibilityLabel("Decrease microphone volume by 1 percent").disabled(value <= 0.25)
        Button("+1%") { value = Self.stepped(value, by: 1) }
          .accessibilityLabel("Increase microphone volume by 1 percent").disabled(value >= 4)
        Spacer()
        Button("Reset to 100%") { value = 1 }
          .accessibilityLabel("Reset microphone volume to 100 percent").disabled(value == 1)
      }
      Text(Features.recording ? "Changes voice following and its test level only. Saved audio and speaker volume stay unchanged." : "Changes voice following and its test level only. Speaker volume stays unchanged.")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
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
  let micName: String
  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Button(session.isTestingMicrophone ? "Stop test" : "Test microphone") {
        if session.isTestingMicrophone { session.stopMicrophoneTest() }
        else { session.startMicrophoneTest(deviceUID: deviceUID, gain: gain) }
      }.help("Check your microphone before presenting")

      MicMeterView(meter: session.meter, micName: micName, showsHeading: false)
        .frame(height: 180).background(Color.black, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
    }
    if deviceUID == nil { Text("System default: \(AudioCapture.resolvedInput(nil)?.name ?? "No microphone available")").font(.callout) }
    if let notice = session.microphoneTestNotice {
      Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.primary)
    }
  }
}

/// The meter observes the level on its own, so only it redraws as the level moves, not the form.
private struct LiveInputLevelMeter: View {
  @ObservedObject var meter: InputMeter
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      InputLevelMeter(peakDBFS: meter.peakDBFS, isClipping: meter.isClipping, showsScale: true, zoneScale: true)
      Text(meter.peakDBFS.isFinite ? String(format: "%.0f dBFS", meter.peakDBFS) : "No signal").monospacedDigit()
    }
  }
}

private struct LoudestSoundReadout: View {
  @ObservedObject var meter: InputMeter
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      if meter.isClipping {
        Label("Too loud. Lower microphone volume.", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.primary).help("Lower microphone volume if the input is distorted")
      }
      Text(meter.peakDBFS.isFinite ? "Sound detected · " + String(format: "%.1f dBFS", meter.peakDBFS) : "No sound yet")
        .monospacedDigit().fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct InputLevelMeter: View {
  @Environment(\.colorScheme) private var scheme
  static func scaleColour(_ scheme: ColorScheme) -> Color { Color(white: scheme == .light ? 0.35 : 0.6) }
  let peakDBFS: Float
  let isClipping: Bool
  var showsScale = true
  var zoneScale = false
  @State private var peakHold = PeakHold()
  static let ticks: [(Float, String)] = [(-60, "−60"), (-50, "−50"), (-40, "−40"), (-30, "−30"), (-18, "−18"), (-15, "−15"), (-12, "−12"), (-9, "−9"), (-6, "−6"), (-3, "−3"), (0, "0")]
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

  static func zoneTrack(vertical: Bool = false) -> some View {
    LinearGradient(stops: [
      .init(color: .green, location: 0), .init(color: .green, location: position(-18)),
      .init(color: .yellow, location: position(-18)), .init(color: .yellow, location: position(-6)),
      .init(color: .red, location: position(-6)), .init(color: .red, location: 1)
    ], startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing)
  }

  var body: some View {
    GeometryReader { geometry in
      let ticks = zoneScale ? Self.ticks.filter { $0.0 == -18 || $0.0 == -6 } : Self.ticks
      let widths = ticks.map { ($0.1 as NSString).size(withAttributes: [.font: Self.labelFont]).width }
      let positions = ticks.map { Self.position($0.0) }
      ZStack(alignment: .topLeading) {
        ZStack(alignment: .leading) {
          Self.zoneTrack().opacity(0.2)
          Self.zoneTrack().mask(alignment: .leading) {
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
        ForEach(Self.visibleLabels(positions: positions, widths: widths, availableWidth: geometry.size.width), id: \.self) { index in
          let span = Self.labelSpan(position: positions[index], width: widths[index], availableWidth: geometry.size.width)
          Text(ticks[index].1)
            .font(Font(Self.labelFont as CTFont))
            .foregroundStyle(Self.scaleColour(scheme))
            .fixedSize()
            .position(x: (span.lowerBound + span.upperBound) / 2, y: 22)
        }
        }
      }
    }
    .frame(height: showsScale ? 32 : 12)
    .accessibilityHidden(true)
    .overlay { AccessibleInputLevel(peakDBFS: peakDBFS, isClipping: isClipping).allowsHitTesting(false) }
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


/// Presenter and native Settings share the same pages and bindings.
struct PresenterSettingsPopover: View {
  @ObservedObject var store: AppStore
  var initialTab: SettingsTab = .reading
  var initialCameraSection = "Camera"
  @State private var tab: SettingsTab = .reading
  var body: some View {
    VStack(spacing: Space.sm) {
      Picker("Settings page", selection: $tab) {
        ForEach(SettingsTab.allCases, id: \.self) { Text($0.label).tag($0) }
      }.pickerStyle(.menu).fixedSize().padding(Space.sm).initialPopoverFocus()
      SettingsPage(store: store, tab: tab, cameraSection: initialCameraSection)
    }.uiZoom(store.uiZoom).frame(width: 560, height: 600).popoverEntryFocus()
      .onAppear { tab = initialTab }
  }
}

struct CameraRecordingPage: View {
  @ObservedObject var store: AppStore
  @ObservedObject var camera = CameraModel.shared
  @ObservedObject var recorder = CameraRecorder.shared
  var startsCamera = true
  @State var section = "Camera"
  @AppStorage("presenterExposureKey") private var exposureKey = true
  @State private var detail: CameraSettingsDetail?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text("Camera and monitor").font(.system(size: 28, weight: .bold)).padding(.bottom, Space.xxl)
        row("Camera", "Used for the monitor picture", camera.sourceInfo?.displayName ?? "No camera chosen", .camera)
        row("Shot", "Landscape, vertical turned left or vertical turned right", camera.shotSummary, .shot)
        row("My skin reference", "Pink in false colour and the My skin zebra preset", "\(camera.guides.skinReference.level) ±\(camera.guides.skinReference.range) IRE", .skin)
        row("Zebras", "Range or Limit, with your presets", !camera.effectiveZebras ? "Off" : camera.guides.zebraRangeMode ? "On · Range \(camera.guides.zebraLevel) ±\(camera.guides.zebraRange)" : "On · Limit \(camera.guides.zebraLevel)", .zebras)
        row("False colour", "Brightness bands, with your skin in pink", camera.effectiveFalseColour ? "On" : "Off", .falseColour)
        row("Guides", "Vertical 9:16, Thirds, Centre mark", guideSummary, .guides)
        row("Exposure key", "Shown while setting up", exposureKey ? "On" : "Off", .key)
        row("Advanced", "Other camera and guide choices", "", .advanced)
      }.padding(AlphaStyle.panelInset).frame(maxWidth: .infinity, alignment: .leading)
    }
    .tint(AlphaStyle.accent)
    .sheet(item: $detail) { item in
      CameraSettingsDetailSheet(item: item, store: store, camera: camera, recorder: recorder,
        startsCamera: startsCamera, exposureKey: $exposureKey) { detail = nil }

    }
  }
  private var guideSummary: String {
    guard camera.framingIsVisible else { return "Off" }
    var names: [String] = []
    if camera.guides.marker == CameraAspect(width: 9, height: 16) { names.append("Vertical 9:16") }
    else if let marker = camera.guides.marker { names.append(marker.label) }
    if camera.guides.thirds { names.append("Thirds") }
    if camera.guides.axes || camera.guides.bullseye { names.append("Centre mark") }
    return names.joined(separator: ", ")
  }
  private func row(_ title: String, _ subtitle: String, _ value: String, _ destination: CameraSettingsDetail) -> some View {
    Button { detail = destination } label: {
      HStack(spacing: Space.md) {
        VStack(alignment: .leading, spacing: Space.xs) {
          Text(title).font(.system(size: 17, weight: .semibold))
          Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Text(value).font(.system(size: 15)).foregroundStyle(.secondary)
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
      }.padding(.vertical, Space.sm).frame(minHeight: 56).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(value)
      .overlay(alignment: .bottom) { Divider() }
  }
}
enum CameraSettingsDetail: String, CaseIterable, Identifiable {
  case camera = "Camera", shot = "Shot", skin = "My skin reference", zebras = "Zebras", falseColour = "False colour", guides = "Guides", key = "Exposure key", advanced = "Advanced"
  var id: String { rawValue }
}


struct CameraSettingsDetailSheet: View {
  let item: CameraSettingsDetail
  @ObservedObject var store: AppStore
  @ObservedObject var camera: CameraModel
  @ObservedObject var recorder: CameraRecorder
  let startsCamera: Bool
  @Binding var exposureKey: Bool
  var done: () -> Void
  var containerSize: CGSize? = nil
  private var availableSize: CGSize {
    let size = containerSize ?? NSApp.keyWindow?.contentView?.bounds.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
    return CGSize(width: max(1, min(700 * store.uiZoom, size.width)), height: max(1, min(700 * store.uiZoom, size.height)))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Space.lg) {
      HStack {
        if ![CameraSettingsDetail.camera, .zebras, .falseColour, .guides].contains(item) {
          Text(item.rawValue).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button(action: done) { Text("Done").padding(.horizontal, Space.md).frame(minHeight: AlphaStyle.minTarget) }
          .buttonStyle(.plain).foregroundStyle(AlphaStyle.onAccent)
          .background(AlphaStyle.accent, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      }
      ScrollView {
        VStack(alignment: .leading, spacing: Space.md) {
          switch item {
          case .camera, .shot: CameraAdjustView(model: camera, devicesOverride: startsCamera ? nil : [], showsShotHeading: item != .shot, shotOnly: item == .shot)
          case .skin: SkinTonePicker(model: camera)
          case .zebras: ZebraAdjustView(model: camera)
          case .falseColour: FalseColourAdjustView(model: camera)
          case .guides: AlphaGuideSections(model: camera)
          case .key:
            HStack {
              Text("Show exposure key"); Spacer()
              Toggle("Show exposure key", isOn: $exposureKey).labelsHidden().toggleStyle(.switch)
            }.frame(minHeight: AlphaStyle.minTarget)
          case .advanced:
            HStack {
              Text("Mirror camera preview"); Spacer()
              Toggle("Mirror camera preview", isOn: $camera.mirrored).labelsHidden().toggleStyle(.switch)
            }.frame(minHeight: AlphaStyle.minTarget)
            CameraAdjustView(model: camera, devicesOverride: [], advancedOnly: true)
            Text("Guide look").font(.system(size: 17, weight: .semibold))
            CameraGuideSections(model: camera, alphaStyle: true)
            Form { ShootSetupSection(store: store, camera: camera, recorder: recorder) }
              .formStyle(.grouped).scrollDisabled(true).contentMargins(.horizontal, 0, for: .scrollContent).frame(minHeight: 260)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }.padding(AlphaStyle.panelInset)
      .buttonStyle(SettingsFormButtonStyle())
      .uiZoom(store.uiZoom)
      .frame(width: availableSize.width, height: availableSize.height)
      .tint(AlphaStyle.accent)
  }
}

private struct SettingsFormButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.padding(.horizontal, Space.sm).frame(minWidth: AlphaStyle.minTarget, minHeight: AlphaStyle.minTarget)
      .contentShape(Rectangle())
      .background(.primary.opacity(configuration.isPressed ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
  }
}

struct ReadingAppearancePreview: View {
  let settings: PrompterSettings
  let overVideo: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("Reading preview · scaled sample").font(.callout).fixedSize(horizontal: false, vertical: true)
      Text("Read.")
        .font(.custom(settings.fontName, size: settings.fontSize * 0.65))
        .fontWeight(settings.fontWeight == "Bold" ? .bold : .regular)
        .foregroundStyle(Color(nsColor: NSColor(hex: settings.textColorHex) ?? .white).opacity(settings.textOpacity))
        .multilineTextAlignment(settings.alignment == "Left" ? .leading : settings.alignment == "Right" ? .trailing : .center)
        .fixedSize()
        .rotationEffect(.degrees(Double(settings.rotation)))
        .padding(Space.md)
        .frame(maxWidth: .infinity, minHeight: max(140, settings.fontSize * 3)) // grid: ok Minimum preview height scales with the chosen reading text size.
        .background(Color(nsColor: NSColor(hex: settings.backgroundColorHex) ?? .black)
          .opacity(settings.backdropOpacity(withVideo: overVideo)), in: Rectangle())
        .background(.gray)
        .scaleEffect(x: settings.horizontalMirror ? -1 : 1, y: settings.verticalMirror ? -1 : 1)
        .accessibilityLabel("Sample of current reading appearance")
    }
  }
}

struct AutomaticScrollDelay: View {
  @ObservedObject var session: SessionStore
  var body: some View {
    Picker("Start delay", selection: $session.startDelay) {
      Text("Off").tag(0)
      Text("3 seconds").tag(3)
      Text("5 seconds").tag(5)
    }
    Text("Gives you time to settle before the text moves. Cancel countdown stops it.").font(.callout)
  }
}

/// Opening settings reports permissions; it never requests one.
struct PermissionSection: View {
  @State private var permissionRevision = 0
  var body: some View {
    let _ = permissionRevision
    Section("Permissions") {
      PermissionRow(name: "Camera", status: AVCaptureDevice.authorizationStatus(for: .video), pane: "Camera")
      PermissionRow(name: "Microphone", status: AVCaptureDevice.authorizationStatus(for: .audio), pane: "Microphone")
      PermissionRow(name: "Speech recognition", status: speechStatus, pane: "SpeechRecognition")
    }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissionRevision += 1 }
  }
  private var speechStatus: AVAuthorizationStatus {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: .authorized
    case .notDetermined: .notDetermined
    case .denied: .denied
    case .restricted: .restricted
    @unknown default: .denied
    }
  }
}
struct PermissionRow: View {
  let name: String
  let status: AVAuthorizationStatus
  let pane: String
  static func statusText(_ status: AVAuthorizationStatus) -> String {
    status == .authorized ? "Allowed" : status == .notDetermined ? "Not asked yet" : "Not allowed"
  }
  static func settingsURL(_ pane: String) -> URL {
    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane)!
  }
  var body: some View {
    LabeledContent(name) {
      Text(Self.statusText(status))
      Button("System settings…") { NSWorkspace.shared.open(Self.settingsURL(pane)) }
        .accessibilityLabel("Open \(name) in System Settings").help("Change \(name) permission in System Settings")
    }.accessibilityElement(children: .contain).accessibilityLabel(name).accessibilityValue(Self.statusText(status))
  }
}
struct IPadSettingsSection: View {
  @ObservedObject var store: AppStore
  @ObservedObject var sender = IPadCameraSender.shared
  var body: some View {
    Section("iPad") {
      Toggle("Keep scripts in iCloud Drive for iPad", isOn: $store.keepsScriptsInICloud)
        .disabled(!ICloudScripts.isAvailable)
        .help("Copies every script to iCloud Drive › Video Prompter and keeps it in step with Video Prompter on iPad")
      Toggle("Send camera to iPad", isOn: $sender.isOn)
        .help("Shows this Mac's camera behind the script in Video Prompter on an iPad connected by USB-C")
      Toggle("Also connect over Wi-Fi", isOn: $sender.usesWiFi)
        .help("Also looks for your iPad on the same Wi-Fi, paired with the key its Settings show. The link is encrypted with that key.")
      if sender.isOn { Text(sender.status).font(.callout) }
    }
  }
}
/// Clear only automatic entry focus, once per new window. Popovers keep their explicit focus route.
struct CalmInitialFocus: NSViewRepresentable {
  final class Coordinator { weak var window: NSWindow? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async {
      guard let window = view.window, context.coordinator.window !== window else { return }
      context.coordinator.window = window
      window.makeFirstResponder(nil)
    }
  }
}
