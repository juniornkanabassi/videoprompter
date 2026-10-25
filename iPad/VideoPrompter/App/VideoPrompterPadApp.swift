import PrompterCore
import SwiftUI

@main struct VideoPrompterPadApp: App {
  @StateObject private var store = PadStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      LibraryScreen(folder: store.folder)
        .environmentObject(store)
        .fullScreenCover(isPresented: Binding(
          get: { store.presentingID != nil },
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
        .preferredColorScheme(.dark)
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        store.folder.refresh()
        store.folder.startWatching()
      case .background:
        store.folder.stopWatching()
        // iPadOS stops the microphone in the background; pausing keeps the place cleanly.
        if store.session.isActivelyRunning { store.session.pause() }
      default: break
      }
    }
  }
}
