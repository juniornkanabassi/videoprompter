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
      Group {
        macControl
        reading
        teleprompter
        text
        camera
        presets
        scriptsFolder
        Section("About") {
          LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
          Link("Privacy Policy", destination: PrivacyPolicy.url)
        }
      }
      .listRowBackground(LibraryTheme.card)
    }
    .scrollContentBackground(.hidden)
    .background(LibraryTheme.background.ignoresSafeArea())
    .tint(LibraryTheme.accent)
    .modifier(PairingPresentation(link: store.camera.link))
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { Button("Done") { dismiss() } }
    .onAppear { microphones = AudioCapture.inputDevices() }
    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { store.folder.choose(url) }
    }
  }

  /// The way into the Mac connection page, with where the connection stands.
  private var macControl: some View {
    Section {
      NavigationLink {
        MacControlScreen(link: store.camera.link, failure: store.camera.link.pairingFailure)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Connect to a Mac")
          Text(store.macConnection.map { "\($0.name)" + ($0.kind.map { " · \($0)" } ?? "") } ?? "Not connected")
            .font(.subheadline)
            .foregroundStyle(store.macConnection == nil ? LibraryTheme.muted : LibraryTheme.good)
        }
      }
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
          Text(device.isMac ? "\(device.name) (Mac link)" : device.isExternal ? "\(device.name) (USB-C)" : device.name)
            .tag(Optional(device.id))
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

// MARK: - Connect to a Mac

/// A Mac this iPad has been connected to, remembered by name so Settings can list it.
struct KnownMac: Codable, Identifiable, Equatable {
  var name: String
  var kind: String?
  var lastSeen: Date
  var id: String { name }
}

enum KnownMacs {
  private static let key = "macLinkKnownMacs"

  static func load() -> [KnownMac] {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([KnownMac].self, from: $0) } ?? []
  }

  static func note(name: String, kind: String?, at date: Date = Date()) {
    var macs = load().filter { $0.name != name }
    macs.append(KnownMac(name: name, kind: kind, lastSeen: date))
    save(macs)
  }

  static func remove(_ name: String) { save(load().filter { $0.name != name }) }
  /// A new key unpairs every Mac that came over Wi-Fi.
  static func removeWiFi() { save(load().filter { $0.kind != "Wi-Fi" }) }

  private static func save(_ macs: [KnownMac]) {
    UserDefaults.standard.set(try? JSONEncoder().encode(macs), forKey: key)
  }
}

/// The page Settings opens for connecting a Mac: the three ways to connect, the Macs known,
/// and the Wi-Fi pairing key, hidden until asked for.
struct MacControlScreen: View {
  @EnvironmentObject private var store: PadStore
  @ObservedObject var link: MacLink
  /// An optional preview override; live failures come from the observed link.
  var failure: String?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var reveal = KeyReveal()
  @State private var confirming = false
  @State private var captured = MacControlScreen.screenIsCaptured
  @State private var known = KnownMacs.load()
  @State private var scanning = false
  @State private var showingKey = false

  init(link: MacLink, failure: String? = nil) {
    self.link = link
    self.failure = failure
  }

  private var connection: MacConnection? { store.macConnection }
  private var usingUSB: Bool { connection?.kind == "USB-C" }

  static var screenIsCaptured: Bool {
    UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.screen.isCaptured == true }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        HStack {
          Text("Connect to a Mac").font(.largeTitle.weight(.semibold))
          Spacer()
          Button("Done") { dismiss() }
            .font(.body)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(LibraryTheme.card2, in: Capsule())
            .buttonStyle(.plain)
        }
        notice(connection.map { "Connected to \($0.name)" + ($0.kind.map { " · \($0)" } ?? "") } ?? "Not connected", colour: connection == nil ? LibraryTheme.muted : LibraryTheme.good)
        ways
        if let failure = failure ?? link.pairingFailure { notice(failure, colour: LibraryTheme.bad) }
        if connection == nil {
          notice("Plug in a USB-C cable, or scan the code in the Mac’s iPad Remote window.", colour: LibraryTheme.warn)
        }
        if !macs.isEmpty { pairedMacs }
        if showingKey { keyCard } else { Button("Show key to type instead") { showingKey = true } }
        Text("No Apple ID or iCloud is needed. Scripts the Mac sends are saved on this iPad in Sent from Mac.")
          .font(.subheadline).foregroundStyle(LibraryTheme.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: 720)
      .padding(.horizontal, 24)
      .padding(.vertical, 40)
      .frame(maxWidth: .infinity)
    }
    .background(Color.black.ignoresSafeArea())
    .foregroundStyle(LibraryTheme.text)
    .tint(LibraryTheme.accent)
    .toolbar(.hidden, for: .navigationBar)
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
      captured = Self.screenIsCaptured
      if captured { reveal.hide() }
    }
    .onChange(of: scenePhase) { _, phase in if phase != .active { reveal.hide() } }
    .onChange(of: connection) { _, _ in known = KnownMacs.load() }
    .fullScreenCover(isPresented: $scanning) { PairingScanner(link: link) }
    .onDisappear { reveal.hide() }
    .confirmationDialog("Generate a new key?", isPresented: $confirming, titleVisibility: .visible) {
      Button("Generate new key", role: .destructive) {
        link.newPairingCode()
        KnownMacs.removeWiFi()
        known = KnownMacs.load()
        reveal.show(at: Date(), captured: captured)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every Mac paired over Wi-Fi is unpaired and must type the new key. USB-C keeps working.")
    }
  }

  // MARK: Ways to connect

  private var ways: some View {
    VStack(spacing: 0) {
      TextField("iPad name", text: $link.deviceName)
        .onSubmit { link.deviceName = PadIdentity.cleanName(link.deviceName) }
        .accessibilityLabel("iPad name")
        .padding(.vertical, 12)
      divider
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("USB-C cable")
          Text("Always on. Works with no network. Tap Trust on this iPad the first time.")
            .font(.subheadline).foregroundStyle(LibraryTheme.muted)
        }
        Spacer(minLength: 12)
        Text(usbStatus).font(.subheadline).foregroundStyle(usingUSB ? LibraryTheme.good : LibraryTheme.muted)
      }
      .padding(.vertical, 12)
      divider
      Toggle(isOn: $link.allowsWiFi) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Same Wi-Fi")
          Text("Scan the code in the Mac’s iPad Remote window. Known Macs reconnect automatically.")
            .font(.subheadline).foregroundStyle(LibraryTheme.muted)
        }
      }
      .padding(.vertical, 12)
      divider
      Button("Scan the code") { scanning = true }
        .buttonStyle(.borderedProminent).foregroundStyle(.black).padding(.vertical, 12)
    }
    .padding(.horizontal, 20)
    .background(LibraryTheme.card, in: RoundedRectangle(cornerRadius: 16))
  }

  private var usbStatus: String {
    if usingUSB { return "In use" }
    return "Automatic"
  }

  private var divider: some View { LibraryTheme.line.frame(height: 1) }

  private func notice(_ text: String, colour: Color) -> some View {
    Text(text)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(LibraryTheme.card, in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(colour))
  }

  // MARK: Paired Macs

  /// The connected Mac first, then the others, most recently seen first.
  private var macs: [KnownMac] {
    var list = known
    if let connection, !list.contains(where: { $0.name == connection.name }) {
      list.append(KnownMac(name: connection.name, kind: connection.kind, lastSeen: Date()))
    }
    return list.sorted {
      ($0.name == connection?.name ? 1 : 0, $0.lastSeen) > ($1.name == connection?.name ? 1 : 0, $1.lastSeen)
    }
  }

  private var pairedMacs: some View {
    VStack(spacing: 0) {
      ForEach(Array(macs.enumerated()), id: \.element.id) { index, mac in
        if index > 0 { divider }
        macRow(mac).padding(.vertical, 8)
      }
    }
    .padding(.horizontal, 20)
    .background(LibraryTheme.card, in: RoundedRectangle(cornerRadius: 16))
  }

  private func macRow(_ mac: KnownMac) -> some View {
    let now = mac.name == connection?.name
    return HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(mac.name)
        Text(now ? "Connected now" + ((connection?.kind).map { " by \($0)" } ?? "")
          : "Last seen " + mac.lastSeen.formatted(.relative(presentation: .named)))
          .font(.subheadline).foregroundStyle(now ? LibraryTheme.good : LibraryTheme.muted)
      }
      Spacer(minLength: 12)
      if now {
        pill("Disconnect", colour: LibraryTheme.text) { link.disconnect() }
      }
      pill("Forget", colour: LibraryTheme.bad) {
          link.forgetMac(named: mac.name)
          known = KnownMacs.load()
        }
    }
  }

  private func pill(_ title: String, colour: Color, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .foregroundStyle(colour)
      .padding(.horizontal, 16)
      .frame(minHeight: 44)
      .background(LibraryTheme.card2, in: Capsule())
      .buttonStyle(.plain)
  }

  // MARK: Pairing key

  private var keyCard: some View {
    // The clock only drives a redraw each second; what is shown follows `reveal`.
    TimelineView(.periodic(from: Date(), by: 1)) { _ in
      let now = Date()
      let shown = reveal.isVisible(at: now, captured: captured)
      VStack(spacing: 12) {
        Text("Pairing key for Wi-Fi").font(.subheadline).foregroundStyle(LibraryTheme.muted)
        Text(shown ? link.pairingCode : Self.masked(link.pairingCode))
          .font(.system(.largeTitle, design: .monospaced))
          .tracking(2)
          .lineLimit(1).minimumScaleFactor(0.5)
          .foregroundStyle(shown ? LibraryTheme.text : LibraryTheme.muted)
          .textSelection(.disabled)
          .accessibilityLabel(shown ? "Pairing key \(link.pairingCode)" : "Pairing key hidden")
        pill(shown ? "Hide key · \(reveal.secondsLeft(at: now)) s" : "Show key for 30 s", colour: LibraryTheme.text) {
          if shown { reveal.hide() } else { reveal.show(at: Date(), captured: captured) }
        }
        .disabled(captured)
        Text("Hidden while the screen is recorded or shared").font(.footnote).foregroundStyle(LibraryTheme.muted)
        Button("Generate new key…") { confirming = true }
          .foregroundStyle(LibraryTheme.bad)
          .padding(.horizontal, 20)
          .frame(minHeight: 44)
          .overlay(Capsule().stroke(LibraryTheme.bad))
          .buttonStyle(.plain)
        Text("Every Mac will need the new key").font(.footnote).foregroundStyle(LibraryTheme.muted)
      }
      .padding(20)
      .frame(maxWidth: .infinity)
      .background(LibraryTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
  }

  /// "K7QF-2MZX-P9RT-W3HD" as "••••-••••-••••-••••".
  static func masked(_ code: String) -> String { String(code.map { $0 == "-" ? "-" : "•" }) }
}
