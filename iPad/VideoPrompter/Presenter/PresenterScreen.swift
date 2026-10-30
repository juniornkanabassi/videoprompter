import PrompterCore
import SwiftUI
import UIKit

/// The full-screen presenter. The script fills the screen, mirrored for the glass when that is
/// on; the controls stay readable for whoever is holding the iPad and fade while it runs. A
/// Bluetooth keyboard, clicker or foot pedal drives it without touching the screen.
struct PresenterScreen: View {
  @EnvironmentObject private var store: PadStore
  @ObservedObject var session: SessionStore
  @ObservedObject var camera: PadCamera
  @State private var controlsVisible = true
  @State private var hideTask: Task<Void, Never>?
  @State private var showingSettings = false
  @State private var editing: FolderScript?
  @FocusState private var focused: Bool

  private var settings: PrompterSettings { store.settings }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        background
        ScriptCanvas(
          document: session.document, tokenIndex: session.tokenIndex,
          lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
          isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
          layoutGuideFraction: settings.verticalMirror ? 1 - settings.guideFraction : settings.guideFraction,
          style: ScriptStyle(settings), textWidth: settings.textWidth,
          manualPosition: session.isManual ? { [session] in session.manualPosition() }
            : UIAccessibility.isReduceMotionEnabled ? nil : { [session] in session.voicePosition() },
          onSeek: { session.seek(to: $0) },
          onUserScroll: { session.seekFromUserScroll(to: $0) })
        .scaleEffect(x: settings.horizontalMirror ? -1 : 1, y: settings.verticalMirror ? -1 : 1)
        .ignoresSafeArea()
        GuideLine(opacity: settings.guideOpacity)
          .position(x: geometry.size.width / 2, y: geometry.size.height * settings.guideFraction)
          .allowsHitTesting(false)
        if controlsVisible {
          controls.transition(.opacity)
        }
        status
      }
      .contentShape(Rectangle())
      .onTapGesture { reveal(toggle: true) }
    }
    .ignoresSafeArea()
    .statusBarHidden(!controlsVisible)
    .persistentSystemOverlays(.hidden)
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(phases: .down) { press in handle(press) }
    .onAppear {
      focused = true
      reveal()
    }
    .onChange(of: session.isActivelyRunning) { reveal() }
    .sheet(isPresented: $showingSettings, onDismiss: { focused = true }) {
      NavigationStack { SettingsScreen() }.environmentObject(store)
    }
    .sheet(item: $editing, onDismiss: { focused = true }) { script in
      ScriptEditor(script: script).environmentObject(store)
    }
  }

  @ViewBuilder private var background: some View {
    let colour = Color(uiColor: ScriptRenderer.colour(settings.backgroundColorHex))
    if camera.isOn {
      Group {
        if camera.isShowingMac {
          LinkPreview(camera: camera, link: camera.link)
        } else {
          CameraPreview(camera: camera)
        }
      }
      .ignoresSafeArea()
      colour.opacity(settings.videoDimming).ignoresSafeArea()
    } else {
      // Black underneath: a teleprompter's glass shows anything lighter as a grey haze.
      Color.black.ignoresSafeArea()
      colour.opacity(settings.backgroundOpacity).ignoresSafeArea()
    }
  }

  @ViewBuilder private var status: some View {
    let message: String? = {
      if let notice = session.anchorNotice { return notice }
      if case .uncertain(let text) = session.state { return text }
      return nil
    }()
    if let message {
      VStack {
        Spacer()
        Text(message)
          .font(.callout)
          .padding(.horizontal, 14).padding(.vertical, 8)
          .background(.ultraThinMaterial, in: Capsule())
          .padding(.bottom, controlsVisible ? 110 : 30)
      }
      .allowsHitTesting(false)
    }
  }

  private var controls: some View {
    VStack {
      HStack(spacing: 12) {
        PresenterButton("Close", systemImage: "xmark") { store.closePresenter() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Text(session.activeRecord?.metadata.title ?? "")
          .font(.headline).lineLimit(1)
          .padding(.horizontal, 14).padding(.vertical, 8)
          .background(.ultraThinMaterial, in: Capsule())
        Spacer()
        if let script = session.activeScriptID.flatMap(store.folder.script) {
          PresenterButton("Edit", systemImage: "pencil") {
            session.pause()
            editing = script
          }
        }
        PresenterButton("Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
      }
      Spacer()
      HStack(spacing: 12) {
        PresenterButton("Back to start", systemImage: "backward.end.fill") { session.restart() }
        PresenterButton("Previous passage", systemImage: "chevron.up") { session.previousPassage() }
        Button {
          session.toggle()
        } label: {
          Label(session.isActivelyRunning ? "Pause" : "Start",
                systemImage: session.isActivelyRunning ? "pause.fill" : "play.fill")
            .font(.title2.weight(.semibold))
            .frame(minWidth: 140, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        PresenterButton("Next passage", systemImage: "chevron.down") { session.nextPassage() }
        Picker("Follow", selection: Binding(get: { settings.mode }, set: { store.settings.mode = $0 })) {
          Text("Voice").tag("Voice")
          Text("Manual").tag("Manual")
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        if settings.mode == "Manual" {
          Stepper("\(Int(settings.speed)) wpm", value: Binding(
            get: { settings.speed }, set: { store.settings.speed = min(max($0, 20), 300) }), step: 10)
            .frame(width: 190)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        PresenterButton("Smaller text", systemImage: "textformat.size.smaller") { stepFont(-4) }
        PresenterButton("Larger text", systemImage: "textformat.size.larger") { stepFont(4) }
        PresenterButton(settings.horizontalMirror ? "Unmirror" : "Mirror", systemImage: "flip.horizontal") {
          store.settings.horizontalMirror.toggle()
        }
        PresenterButton(camera.isOn ? "Hide camera" : "Show camera", systemImage: camera.isOn ? "video.slash" : "video") {
          camera.isOn.toggle()
        }
      }
    }
    .padding(20)
    .foregroundStyle(.white)
    .tint(.accentColor)
  }

  private func stepFont(_ delta: Double) {
    store.settings.fontSize = min(max(store.settings.fontSize + delta, 18), 120)
  }

  /// Controls show on a tap or a pause and fade three seconds into reading.
  private func reveal(toggle: Bool = false) {
    hideTask?.cancel()
    withAnimation(.easeInOut(duration: 0.2)) {
      controlsVisible = toggle ? !controlsVisible : true
    }
    guard controlsVisible, session.isActivelyRunning else { return }
    hideTask = Task {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, session.isActivelyRunning else { return }
      withAnimation(.easeInOut(duration: 0.4)) { controlsVisible = false }
    }
  }

  /// Keyboards, presentation clickers and foot pedals. Most clickers send Page Up and Page Down
  /// or the arrow keys; pedals are usually set to Space or the arrows.
  private func handle(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .space, .return:
      session.toggle()
    case .pageDown, .rightArrow, .downArrow:
      if session.isManual, press.key == .downArrow { store.settings.speed = min(store.settings.speed + 10, 300) }
      else { session.nextPassage() }
    case .pageUp, .leftArrow, .upArrow:
      if session.isManual, press.key == .upArrow { store.settings.speed = max(store.settings.speed - 10, 20) }
      else { session.previousPassage() }
    case .home:
      session.restart()
    case .escape:
      store.closePresenter()
    default:
      switch press.characters {
      case "+", "=": stepFont(4)
      case "-": stepFont(-4)
      case "m": store.settings.horizontalMirror.toggle()
      case "v": store.settings.mode = settings.mode == "Voice" ? "Manual" : "Voice"
      default: return .ignored
      }
    }
    return .handled
  }
}

/// The reading line: a thin rule with a marker at each end, as on the Mac.
struct GuideLine: View {
  var opacity: Double
  var body: some View {
    HStack(spacing: 0) {
      Image(systemName: "arrowtriangle.right.fill").font(.system(size: 14))
      Rectangle().frame(height: 1).opacity(0.35)
      Image(systemName: "arrowtriangle.left.fill").font(.system(size: 14))
    }
    .foregroundStyle(Color.accentColor)
    .opacity(opacity)
    .padding(.horizontal, 6)
  }
}

private struct PresenterButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void
  init(_ title: String, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }
  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.title3)
        .frame(width: 48, height: 48)
        .background(.ultraThinMaterial, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .hoverEffect(.highlight)
  }
}
