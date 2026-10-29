import AppKit
import SwiftUI

/// A launch by `videoprompter` or the MCP server (`--headless`) runs as a background service: the control socket
/// answers, and there is no library window, no Dock tile and no update prompt. Visual commands still show what they
/// are for: `present` puts the presenter up without the library window. The app turns into the ordinary windowed app
/// when a command passes --show, on a reopen from the Dock, Spotlight or Finder, or when anything activates it (a
/// click on the presenter, say). A headless copy with nothing on screen that nobody has used for `idleLimit` quits.
@MainActor final class Headless {
  static let shared = Headless()
  /// `--headless` asks for it; `--show` (a test run that wants its window) wins.
  private(set) var active = CommandLine.arguments.contains("--headless") && !CommandLine.arguments.contains("--show")
  /// Ten minutes; `--idle-quit SECONDS` shortens it for checks.
  let idleLimit: TimeInterval = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--idle-quit"), arguments.indices.contains(index + 1),
      let seconds = TimeInterval(arguments[index + 1]), seconds > 0
    else { return 600 }
    return seconds
  }()
  /// The library window, kept transparent and off screen while headless so revealing it is instant.
  weak var mainWindow: NSWindow?
  /// Opens a library window; the app's commands set it, since a headless launch never makes one.
  var openLibrary: (@MainActor () -> Void)?
  /// Whether quitting now would interrupt nothing (no recording); the store answers it.
  var canQuit: @MainActor () -> Bool = { true }
  private var lastUse = Date()
  /// Commands still running; the copy never quits under one.
  private var inFlight = 0
  /// The main window is off screen because this class put it there, not because someone closed it; a reopen
  /// brings it back rather than letting SwiftUI open a second one.
  var windowHidden = false
  private var timer: Timer?
  private var activeObserver: Any?

  /// From the App's init, before any window exists.
  func start() {
    guard active, timer == nil else { return }
    NSApplication.shared.setActivationPolicy(.accessory)
    // `open -g` never activates the app, so activation means a person (or --show) wants it.
    activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { Headless.shared.promote() }
    }
    timer = Timer.scheduledTimer(withTimeInterval: min(30, idleLimit), repeats: true) { _ in MainActor.assumeIsolated { Headless.shared.quitIfIdle() } }
  }
  /// A control request started or finished: the idle clock starts again.
  func begin() { inFlight += 1; lastUse = Date() }
  func end() { inFlight -= 1; lastUse = Date() }
  /// Become the ordinary app: Dock tile, menu bar, update checks. The library window comes back too, unless another
  /// window (the presenter) is already on screen, so the app is never visible with nothing to show.
  func promote() {
    guard active else { return }
    active = false
    timer?.invalidate(); timer = nil
    if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    activeObserver = nil
    NSApp.setActivationPolicy(.regular)
    Updates.shared.resume()
    // The library's views read `active` for alerts kept back while headless; have them look again.
    AppStore.shared.objectWillChange.send()
    guard let window = mainWindow else { return }
    window.alphaValue = 1; window.ignoresMouseEvents = false
    if !NSApp.windows.contains(where: \.isVisible) { window.makeKeyAndOrderFront(nil); windowHidden = false }
  }
  /// Promote and bring the library window forward: --show, or a reopen from the Dock, Spotlight or Finder.
  func reveal() {
    promote()
    windowHidden = false
    // Even with the presenter on screen, --show means the library comes forward.
    if let window = mainWindow { window.makeKeyAndOrderFront(nil) } else if let openLibrary { openLibrary() } else { reopenSelf() }
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
  }
  /// The fallback when the commands have not handed over `openLibrary`: asking LaunchServices to reopen this running
  /// copy makes SwiftUI open a library window, as a Dock click would, as long as no other window is on screen.
  private func reopenSelf() {
    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
  }
  private func quitIfIdle() {
    // The hidden main window counts as nothing on screen, even if SwiftUI ordered it back in at alpha 0.
    let shown = NSApp.windows.contains { $0.isVisible && !($0 === mainWindow && windowHidden) }
    guard active, inFlight == 0, !shown, Date().timeIntervalSince(lastUse) >= idleLimit, canQuit() else { return }
    NSApp.terminate(nil)
  }
}

/// Placed behind the library window's content. It remembers the window for `Headless.reveal()`. A headless launch
/// makes no library window, but should one be made while still headless, this makes it transparent and click-through
/// and takes it off screen.
struct HeadlessWindowHider: NSViewRepresentable {
  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      MainActor.assumeIsolated {
        guard Headless.shared.mainWindow == nil else { return }
        Headless.shared.mainWindow = window
        guard Headless.shared.active else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        Headless.shared.windowHidden = true
        // SwiftUI orders the window front later in the same launch pass; take it away again after that.
        DispatchQueue.main.async { if Headless.shared.active { window.orderOut(nil) } }
      }
    }
  }
  func makeNSView(context: Context) -> NSView { Probe(frame: .zero) }
  func updateNSView(_ view: NSView, context: Context) {}
}
