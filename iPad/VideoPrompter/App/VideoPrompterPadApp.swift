import PrompterCore
import SwiftUI

@main struct VideoPrompterPadApp: App {
  @StateObject private var store = PadStore()
  @AppStorage("padShowHome") private var showHome = HomeNavigation.initiallyShowsHome
  @AppStorage("padBackgroundTime") private var backgroundTime = 0.0
  @AppStorage("padBackgroundPresenter") private var backgroundPresenter = ""
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
        let expired = HomeNavigation.shouldShowHome(backgroundTime: backgroundTime, now: Date().timeIntervalSince1970)
        // An edit in progress is never closed under the reader; it is saved or cancelled by them.
        if expired, !store.editing, !(store.isPresenting && store.macOpenedPresenter) {
          if store.isPresenting { store.closePresenter() }
          showHome = true
        }
        store.folder.refresh()
        if backgroundTime > 0, !expired, !store.isPresenting { store.restoreBackgroundPresenter(backgroundPresenter) }
        backgroundTime = 0
        backgroundPresenter = ""
        store.folder.startWatching()
        store.camera.link.start()
      case .background:
        backgroundPresenter = store.presentingID?.uuidString ?? (store.cameraOnly ? "camera" : "")
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
  static let initiallyShowsHome = true
  static func shouldShowHome(backgroundTime: Double, now: Double) -> Bool {
    backgroundTime > 0 && now - backgroundTime >= 900
  }
}
