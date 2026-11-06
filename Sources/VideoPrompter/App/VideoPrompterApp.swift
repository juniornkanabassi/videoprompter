import AppKit
@preconcurrency import AVFoundation
import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
  static let videoPrompterImport = Notification.Name("VideoPrompter.import")
}

/// Shared by the Add and File menus, so Import cannot steal the editor’s Italic shortcut.
enum ScriptShortcuts {
  static let importFile = KeyboardShortcut("i", modifiers: [.command, .shift])
  static let italic = KeyboardShortcut("i", modifiers: .command)
  static let newScript = KeyboardShortcut("n", modifiers: .command)
  static let library = KeyboardShortcut("l", modifiers: [.command, .shift])
  static let camera = KeyboardShortcut("c", modifiers: [.command, .shift])
  static let biggerText = KeyboardShortcut(">", modifiers: .command)
  static let smallerText = KeyboardShortcut("<", modifiers: .command)
}


@main struct VideoPrompterApp: App {
  @StateObject private var store = AppStore.shared
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  init() {
    // A launch by the command line or MCP (--headless) is a background service with no library window or Dock tile.
    // Restored windows (the Camera window, extra library windows) would bypass the hidden-window path.
    if Headless.shared.active { UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true]) }
    // The bundle starts as an agent (LSUIElement), so a headless launch never shows a Dock tile, not even for the
    // moment before this init runs. Every other launch becomes the ordinary app here, before it finishes launching.
    if !Headless.shared.active { NSApplication.shared.setActivationPolicy(.regular) }
    Headless.shared.start()
    if CommandLine.arguments.contains("--agent-screen") { NSWindow.keepEveryWindowInvisible() }
    Headless.shared.canQuit = { !CameraRecorder.shared.isRecording && !CameraRecorder.shared.isBusy }
    Updates.shared.start()
  }
  var body: some Scene {
    WindowGroup("Video Prompter", id: "library") {
      LibraryView(store: store)
        .background(MainWindowConfigurator())
        .background(HeadlessWindowHider())
        .onAppear { appDelegate.store = store }
    }
      .defaultSize(width: 1100, height: 750)
      .windowResizability(.contentMinSize)
      // Headless, the library window is never made, so it cannot appear even for a frame; a reveal opens it.
      .defaultLaunchBehavior(Headless.shared.active ? .suppressed : .automatic)
      .commands {
        CommandGroup(after: .textEditing) {
          Button("Find…") {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            let responder = NSApp.keyWindow?.firstResponder
            if let textView = responder as? NSTextView { textView.usesFindBar = true }
            NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: responder, from: item)
          }.keyboardShortcut("f", modifiers: .command)
        }
        // Grouped to stay within the commands builder's ten items.
        Group {
          SidebarCommands()
          InspectorCommands()
          PrivacyCommands()
          CommandGroup(after: .help) { Button("Getting Started Guide") { store.showWelcomeScript() } }
        }
        Group {
          ICloudCommands(store: store)
          IPadCameraCommands(sender: .shared)
        }
        CommandGroup(replacing: .newItem) { FileItems(store: store) }
        CommandGroup(before: .toolbar) {
          Button("Zoom In") { store.stepUIZoom(in: true) }.keyboardShortcut("+", modifiers: .command)
            .disabled(store.uiZoom >= AppStore.uiZoomSteps.last!)
          Button("Zoom Out") { store.stepUIZoom(in: false) }.keyboardShortcut("-", modifiers: .command)
            .disabled(store.uiZoom <= AppStore.uiZoomSteps.first!)
          Button("Actual Size") { store.uiZoom = 1 }.keyboardShortcut("0", modifiers: .command)
            .disabled(store.uiZoom == 1)
          Divider()
          Button("Make Text Bigger") { store.zoomFocusedText(in: true) }.keyboardShortcut(ScriptShortcuts.biggerText)
          Button("Make Text Smaller") { store.zoomFocusedText(in: false) }.keyboardShortcut(ScriptShortcuts.smallerText)
          Divider()
          PresenterVideoItems()
          ExposureMenuItems()
          Button("Presenter Full Screen") { PresenterController.shared.toggleFullScreen() }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandMenu("Format") {
          Button("Bold") { FormattedMarkdownEditor.formatFocused(.bold) }.keyboardShortcut("b")
          Button("Italic") { FormattedMarkdownEditor.formatFocused(.italic) }.keyboardShortcut(ScriptShortcuts.italic)
          Button("Heading") { FormattedMarkdownEditor.formatFocused(.heading) }
          Button("Add or Edit Link…") { FormattedMarkdownEditor.formatFocused(.link) }.keyboardShortcut("k")
        }
        CommandMenu("Prompter") {
          Button("Present") { PresenterController.shared.present(store: store) }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .help(store.selected == nil ? "Select a script to present" : "Present the selected script")
            .disabled(store.selected == nil)
          Button("Camera Only") { PresenterController.shared.presentCamera(store: store) }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .help("Choose a camera, check framing or record. Camera Monitor is an optional second view.")
          // Option-Command-Space is macOS's own Show Finder Search Window (and Shift-Command-Space
          // asks Siri), so the app never received it. Option-Command-S is VoicePrompter's.
          Button("Start or Pause") { PresenterController.shared.toggleReading(store: store) }
            .keyboardShortcut("s", modifiers: [.command, .option])
          Button("Back to Start") { PresenterController.shared.moveReading { $0.restart() } }
            .keyboardShortcut("r", modifiers: [.command, .option])
          Button("Previous Passage") { PresenterController.shared.moveReading { $0.previousPassage() } }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
          Button("Next Passage") { PresenterController.shared.moveReading { $0.nextPassage() } }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
          RecordingMenuItems()
          Divider()
          Button("Pin Selected Text over Camera") { PresenterController.shared.monitorSelection(store: store) }
            // Not Option-Command-M: that is Window > Minimise All.
            .keyboardShortcut("l", modifiers: [.command, .option])
            .help("Pin the selected passage over the camera picture, as a reference monitor")
          Button("Match Camera Size") { PresenterController.shared.matchCameraSize() }
        }
        CameraCommands()
        UpdateCommands()
      }
    Settings { AppSettingsView(store: store) }
    Window("Import from Google Docs", id: "google-docs") { GoogleDocsWindow(store: store) }
      .defaultSize(width: 520, height: 560)
    Window("iPad Remote", id: "ipad-remote") { IPadRemoteView(link: .shared).uiZoom(store.uiZoom) }
      .defaultSize(width: 420, height: 380)
      .defaultLaunchBehavior(.suppressed)
    Window("Camera Monitor", id: "camera") {
      CameraView(zoom: store.uiZoom)
        .background(MainWindowConfigurator(size: NSSize(width: 760, height: 480)))
        .onAppear { PresenterController.shared.observeInterfaceSettings(store) }
    }
      .defaultSize(width: 760, height: 480)
      .defaultLaunchBehavior(Headless.shared.active ? .suppressed : .automatic)
  }
}

/// The video background's two menu items. A view of its own so the toggle follows
/// `CameraModel.shared` without the whole app scene observing it.
struct PresenterVideoItems: View {
  @ObservedObject private var camera: CameraModel
  init(camera: CameraModel = .shared) { _camera = ObservedObject(wrappedValue: camera) }
  /// Prompter > Prompter Only / Present with Video / Video Only. Internal so the test flips the
  /// menu's own switches. Ticking the chosen one again goes back to Prompter only.
  func choice(_ mode: PresenterDisplayMode) -> Binding<Bool> {
    Binding(
      get: { camera.displayMode == mode },
      set: { camera.displayMode = $0 ? mode : .prompterOnly })
  }
  var body: some View {
    Toggle("Script Only", isOn: choice(.prompterOnly))
    Toggle("Script and Camera", isOn: choice(.prompterWithVideo))
      .keyboardShortcut("v", modifiers: [.command, .shift])
    Toggle("Camera Only", isOn: choice(.videoOnly))
  }
}

struct ExposureMenuItems: View {
  @ObservedObject private var camera = CameraModel.shared
  var body: some View {
    Toggle("Clean View", isOn: $camera.cleanView).keyboardShortcut("k", modifiers: [.option, .command])
    Toggle("Zebras", isOn: $camera.guides.zebras).keyboardShortcut("z", modifiers: [.option, .command])
    Toggle("False Colour", isOn: $camera.guides.falseColour).keyboardShortcut("x", modifiers: [.option, .command])
  }
}

/// File menu: the library's script and folder actions. Each item is disabled when nothing applies.
private struct FileItems: View {
  @ObservedObject var store: AppStore
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    let script = store.selected
    let link = script.flatMap { store.linkStates[$0.id] }
    Button("New Script") {
      if let window = Headless.shared.mainWindow { window.makeKeyAndOrderFront(nil) }
      else { openWindow(id: "library") }
      store.create()
    }
      .keyboardShortcut(ScriptShortcuts.newScript)
      .disabled(!store.libraryAvailable)
    Button("New Library Window") { openWindow(id: "library") }
      .keyboardShortcut(ScriptShortcuts.library)
    Button("New Folder…") { store.namingNewFolder = true }
      .disabled(!store.libraryAvailable)
    Button("Duplicate") { store.duplicate() }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(script == nil)
    Divider()
    // Keep the native Italic shortcut available in both script editors.
    Button("Import File…") { NotificationCenter.default.post(name: .videoPrompterImport, object: nil) }
      .keyboardShortcut(ScriptShortcuts.importFile)
      .disabled(!store.libraryAvailable)
    Button("Paste Copied Text") { store.importClipboard() }
      .disabled(!store.libraryAvailable)
    Button("Import from Google Docs…") { openWindow(id: "google-docs") }
      .disabled(!store.libraryAvailable)
    Button("Update from Google Docs") { store.updateSelectedFromGoogle() }
      .disabled(script.map { !store.isFromGoogle($0.id) } ?? true)
    Button("Export Markdown…") { script.map(store.exportMarkdown) }
      .disabled(script == nil)
    Button("Show in Finder") { script.map { store.revealInFinder($0.id) } }
      .disabled(script == nil || link?.isBroken == true)
    Divider()
    Button(link?.isBroken == true ? "Find Linked File…" : "Link File…") { store.relinkingID = script?.id }
      .disabled(script == nil || (script?.metadata.linkedPath != nil && link?.isBroken != true))
    Button("Unlink") { script.map { store.unlink($0.id) } }
      .disabled(script?.metadata.linkedPath == nil)
    Divider()
    Button("Move to Trash") { store.trashSelectionFromMenu() }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(store.selectedIDs.isEmpty)
  }
}

/// Commands are built even without a window, so headless reveal can open the library group.
private struct CameraCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    let _ = (Headless.shared.openLibrary = { [openWindow] in openWindow(id: "library") })
    CommandGroup(after: .windowList) {
      Button("Open Camera Monitor") { openWindow(id: "camera") }.keyboardShortcut(ScriptShortcuts.camera)
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controlServer: ControlServer?
  weak var store: AppStore? {
    didSet {
      guard controlServer == nil, let store else { return }
      let actions = ControlActions(store: store)
      let root = ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments)
      let server = ControlServer(socketURL: ControlProtocol.socketURL(dataRoot: root)) { action, params in await actions.handle(action, params) }
      controlServer = server
      do { try server.start() } catch { NSLog("Control server unavailable: %@", error.localizedDescription) }
    }
  }
  func applicationWillTerminate(_ notification: Notification) { controlServer?.stop() }
  /// A Dock click, Spotlight or Finder launch while a headless copy runs: show the library instead of nothing.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard Headless.shared.active || Headless.shared.windowHidden else { return true }
    // A headless launch makes no library window; open one here rather than leave it to SwiftUI's reopen handling,
    // which runs before the scene stops being suppressed.
    guard Headless.shared.mainWindow != nil else {
      Headless.shared.promote()
      guard let openLibrary = Headless.shared.openLibrary else { return true }
      openLibrary()
      return false
    }
    Headless.shared.reveal()
    return false
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Starts the control server even when no library window opens (a headless launch never shows one).
    if store == nil { store = AppStore.shared }
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if Self.deletesLineWhileTyping(event, in: NSApp.keyWindow) { return nil }
      if let presenter = NSApp.keyWindow as? PresenterPanel, presenter.handlePassageKey(event) { return nil }
      // Zoom In's "+" only matches with Shift held; take the unshifted Command-= too, as Safari does.
      guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers == "=", let store = self?.store
      else { return event }
      store.stepUIZoom(in: true)
      return nil
    }
  }
  /// Command-Delete is File > Move to Trash, but in a text field or editor it keeps its text meaning,
  /// delete to the start of the line, so typing can never bin a script. Runs before the menu sees it.
  static func deletesLineWhileTyping(_ event: NSEvent, in window: NSWindow?) -> Bool {
    guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers == "\u{7F}",
      let text = window?.firstResponder as? NSTextView, text.isEditable
    else { return false }
    text.deleteToBeginningOfLine(nil)
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store else { return .terminateNow }
    store.session.pause()
    Task {
      await CameraRecorder.shared.stop()
      let saved = await store.flushPendingSaves()
      if !saved && store.errorMessage == nil { store.errorMessage = "A script edit could not be saved. Retry the save before quitting." }
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
}

/// Zoom for a whole pane: lays the content out in 1/scale of the space it is given and draws it
/// scaled back up, so every label, control and text view grows together. SwiftUI's own scale keeps
/// clicks on target, AppKit views inside included; an NSHostingView inside a bounds-scaled NSView
/// draws the same but stops hit-testing its AppKit subviews.
struct UIZoom: Layout {
  var scale: Double
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let size = subviews.first?.sizeThatFits(ProposedViewSize(
      width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })) ?? .zero
    guard scale != 1 else { return size }
    // Zoomed, a pane takes the space it is offered: passing its content's minimum on, doubled at
    // 200%, asked the split view for more than the window had and AppKit looped on constraints.
    return CGSize(width: proposal.width ?? size.width * scale, height: proposal.height ?? size.height * scale)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale))
  }
}
extension View {
  func uiZoom(_ scale: Double) -> some View { UIZoom(scale: scale) { scaleEffect(scale, anchor: .topLeading) } }
}

extension NSApplication {
  /// Hidden agent copies (`--agent-screen`) must never come to the front and take focus from Junior.
  func activateUnlessAgentScreen() {
    guard !CommandLine.arguments.contains("--agent-screen") else { return }
    activate(ignoringOtherApps: true)
  }
}

extension NSWindow {
  /// `--agent-screen` (the packaged checks) runs the real app with nothing visible on any of Junior's displays:
  /// windows stay ordered in, so Accessibility still reads them, but are transparent and let clicks through.
  static func keepEveryWindowInvisible() {
    NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
      guard let window = note.object as? NSWindow, window.alphaValue != 0 || !window.ignoresMouseEvents else { return }
      MainActor.assumeIsolated { window.alphaValue = 0; window.ignoresMouseEvents = true }
    }
  }
}

extension NSScreen {
  /// Where `--agent-screen` puts windows: the Prompter XL, else the Agent Screen.
  static var agentScreen: NSScreen? {
    screens.first { $0.localizedName == "Prompter XL" } ?? screens.first { $0.localizedName == "Agent Screen" }
  }
}

struct MainWindowConfigurator: NSViewRepresentable {
  var size = NSSize(width: 1100, height: 750)
  final class Coordinator {
    var placed = false
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
  func updateNSView(_ view: NSView, context: Context) {
    guard CommandLine.arguments.contains("--agent-screen"), !context.coordinator.placed else { return }
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      context.coordinator.placed = true
      guard let area = NSScreen.agentScreen?.visibleFrame else { window.orderOut(nil); return }
      window.setFrame(area.centred(size).intersection(area), display: true)
      window.orderFrontRegardless()
    }
  }
}

struct RecordingMenuItems: View {
  @ObservedObject private var recorder = CameraRecorder.shared
  @ObservedObject private var camera = CameraModel.shared
  var body: some View {
    Button(recorder.isRecording ? "Stop Recording" : "Record") {
      Task { if recorder.isRecording { await recorder.stop() } else { await recorder.start(camera: camera) } }
    }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(recorder.isBusy || (!recorder.isRecording && !camera.isReadyToRecord))
      .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.didStartRunningNotification)) { _ in camera.objectWillChange.send() }
      .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.didStopRunningNotification)) { _ in camera.objectWillChange.send() }
    Button("Show Recordings Folder") { recorder.openRecordingsFolder() }
  }
}
