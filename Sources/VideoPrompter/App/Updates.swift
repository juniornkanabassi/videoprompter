import AppKit
import Combine
import Sparkle
import SwiftUI

/// Self-updating with Sparkle 2, as in Talk & Read. Sparkle's standard updater and user driver do the work: they
/// check the appcast once a day (Info.plist), show the release notes and install only after the user agrees. Each
/// update is a zip whose EdDSA signature must match SUPublicEDKey, and release.sh writes the appcast.
@MainActor final class Updates {
  static let shared = Updates()
  static let productionID = "com.juniornkanabassi.VidPrompt"
  /// Kept alive for the life of the app; nil when updates are off.
  private var controller: SPUStandardUpdaterController?
  var updater: SPUUpdater? { controller?.updater }

  /// From the App's init, so the menu sees the updater. Updates stay off (no updater, no menu item) unless this is
  /// the production bundle with a feed and a real public key: build.sh strips both from local builds, and the
  /// built-app check runs a copy under its own bundle id that must never check or install anything.
  func start() {
    let info = Bundle.main.infoDictionary ?? [:]
    guard controller == nil, Bundle.main.bundleIdentifier == Self.productionID, info["SUFeedURL"] is String,
      let key = info["SUPublicEDKey"] as? String, !key.isEmpty, !key.hasPrefix("REPLACE_WITH_")
    else { return }
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }
}

/// Video Prompter > Check for Updates…, enabled while Sparkle can start a check (Sparkle's SwiftUI pattern).
struct UpdateCommands: Commands {
  var body: some Commands {
    CommandGroup(after: .appInfo) {
      if let updater = Updates.shared.updater { CheckForUpdatesButton(updater: updater) }
    }
  }
}

private struct CheckForUpdatesButton: View {
  @StateObject private var state: UpdateCheckState
  private let updater: SPUUpdater
  init(updater: SPUUpdater) {
    self.updater = updater
    _state = StateObject(wrappedValue: UpdateCheckState(updater: updater))
  }
  var body: some View {
    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!state.canCheck)
  }
}

@MainActor private final class UpdateCheckState: ObservableObject {
  @Published var canCheck = false
  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
  }
}
