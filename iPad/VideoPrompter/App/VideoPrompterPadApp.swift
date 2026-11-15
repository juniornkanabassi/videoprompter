import PrompterCore
import SwiftUI

@main struct VideoPrompterPadApp: App {
  @StateObject private var store = PadStore()
  @AppStorage("padShowHome") private var showHome = true
  @AppStorage("padBackgroundTime") private var backgroundTime = 0.0
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      Group {
        if showHome { HomeScreen(showHome: $showHome) }
        else { LibraryScreen(folder: store.folder, showHome: $showHome) }
      }
        .environmentObject(store)
        .fullScreenCover(isPresented: Binding(
          get: { store.isPresenting },
          set: { if !$0 { store.closePresenter() } })
        ) {
          PresenterScreen(session: store.session, camera: store.camera).environmentObject(store)

        }
        .alert("Video Prompter", isPresented: Binding(
          get: { store.errorMessage != nil || store.folder.errorMessage != nil },
          set: { if !$0 { store.errorMessage = nil; store.folder.errorMessage = nil } })
        ) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(store.errorMessage ?? store.folder.errorMessage ?? "")
        }
        .onChange(of: store.isPresenting) { _, value in
          store.camera.link.setPresenting(value)
        }
        .onChange(of: store.presentingID) { _, id in
          if id != nil { showHome = false }
        }
        .preferredColorScheme(.dark)
        .tint(AlphaStyle.accent)
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        if HomeNavigation.shouldShowHome(backgroundTime: backgroundTime, now: Date().timeIntervalSince1970), !store.session.followsRemote {
          if store.isPresenting { store.closePresenter() }
          showHome = true
        }
        backgroundTime = 0
        store.folder.refresh()
        store.folder.startWatching()
        store.camera.link.start()
      case .background:
        backgroundTime = Date().timeIntervalSince1970
        store.folder.stopWatching()
        // iPadOS stops the microphone in the background; pausing keeps the place cleanly.
        if store.session.isActivelyRunning { store.session.pause() }
      default: break
      }
    }
  }
}

// A missing timestamp is the first open, or a foreground transition without a background.
enum HomeNavigation {
  static func shouldShowHome(backgroundTime: Double, now: Double) -> Bool {
    backgroundTime > 0 && now - backgroundTime >= 900
  }
}
