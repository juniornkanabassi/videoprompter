import PrompterCore
import SwiftUI

@main struct VideoPrompterPadApp: App {
  @StateObject private var store = PadStore()
  @AppStorage("hasSuggestedMacConnection") private var suggested = false
  @State private var suggestConnection = false
  @State private var scan = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      LibraryScreen(folder: store.folder)
        .environmentObject(store)
        .fullScreenCover(isPresented: Binding(
          get: { store.isPresenting },
          set: { if !$0 { store.closePresenter() } })
        ) {
          PresenterScreen(session: store.session, camera: store.camera).environmentObject(store)
            .modifier(PairingPresentation(link: store.camera.link))
        }
        .alert("Video Prompter", isPresented: Binding(
          get: { store.errorMessage != nil || store.folder.errorMessage != nil },
          set: { if !$0 { store.errorMessage = nil; store.folder.errorMessage = nil } })
        ) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(store.errorMessage ?? store.folder.errorMessage ?? "")
        }
        .modifier(PairingPresentation(link: store.camera.link))
        .sheet(isPresented: $suggestConnection) {
          VStack(spacing: 24) {
            Text("Connect to a Mac").font(.largeTitle.bold())
            Text("Use a USB-C cable for an automatic connection, or scan the code in the Mac’s iPad Remote window.")
            Button("Scan the code") { suggestConnection = false; scan = true }
            Button("Not now") { suggestConnection = false }
          }.padding(40).presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $scan) { PairingScanner(link: store.camera.link) }
        .task {
          #if !targetEnvironment(simulator)
          if !suggested { suggested = true; suggestConnection = true }
          #endif
        }
        .preferredColorScheme(.dark)
        .tint(AlphaStyle.accent)
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        store.folder.refresh()
        store.folder.startWatching()
        store.camera.link.start()
      case .background:
        store.folder.stopWatching()
        // iPadOS stops the microphone in the background; pausing keeps the place cleanly.
        if store.session.isActivelyRunning { store.session.pause() }
      default: break
      }
    }
  }
}
