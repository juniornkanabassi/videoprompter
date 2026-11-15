import SwiftUI

struct HomeScreen: View {
  @EnvironmentObject private var store: PadStore
  @Binding var showHome: Bool
  var snapshotMac: HomeMacState? = nil
  @AppStorage("padLastOpenedScript") private var lastID = ""
  @State private var settings = false
  @State private var mac = false

  private var lastScript: FolderScript? {
    guard let id = UUID(uuidString: lastID), let script = store.folder.script(id), script.isDownloaded else { return nil }
    return script
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          Text("What do you want to do?").font(.largeTitle.bold())
          let columns = geometry.size.width >= 850 ? 3 : 1
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), alignment: .leading, spacing: 16) {
            card(icon: "doc.text", title: "Read a script", description: "Your scripts, scrolling as you speak.") {
              Text("\(store.folder.count(in: .all)) scripts · \(store.folder.count(in: .sentFromMac)) sent from Mac")
                .foregroundStyle(LibraryTheme.muted)
              if let script = lastScript {
                Button { store.selectedID = script.id; showHome = false } label: {
                  HStack { Text("Continue “\(script.title)”").lineLimit(2).multilineTextAlignment(.leading); Spacer(); Image(systemName: "chevron.right") }
                    .frame(minHeight: 44)
                }.foregroundStyle(LibraryTheme.accent).accessibilityHint("Opens this script in the library")
              }
              action("Open scripts", icon: "doc.on.doc", primary: true) { showHome = false }
            }
            card(icon: "video", title: "Camera only", description: "See yourself and check framing, focus and exposure. No script needed.") {
              action("Open camera", icon: "video") { if store.draftFlusher.resolve() { store.presentCamera() } }
            }
            MacHomeCard(snapshot: snapshotMac, open: { mac = true })
          }
          Spacer(minLength: 0)
          Button { settings = true } label: { Label("Settings", systemImage: "gearshape").frame(minHeight: 44) }
            .buttonStyle(.plain)
        }.padding(32).frame(maxWidth: 1200, minHeight: geometry.size.height, alignment: .topLeading).frame(maxWidth: .infinity)
      }
    }
    .background(LibraryTheme.background.ignoresSafeArea()).foregroundStyle(LibraryTheme.text)
    .sheet(isPresented: $settings) { NavigationStack { SettingsScreen() }.environmentObject(store) }
    .sheet(isPresented: $mac) { NavigationStack { MacControlScreen(link: store.camera.link, failure: store.camera.link.pairingFailure) }.environmentObject(store) }
  }
}

private func card<Content: View>(icon: String, title: String, description: String, @ViewBuilder content: () -> Content) -> some View {
  VStack(alignment: .leading, spacing: 14) {
    Image(systemName: icon).font(.title2).foregroundStyle(LibraryTheme.accent)
      .frame(width: 50, height: 50).background(LibraryTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
    Text(description).foregroundStyle(LibraryTheme.muted).fixedSize(horizontal: false, vertical: true)
    Spacer(minLength: 12)
    content()
  }.padding(22).frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
    .background(LibraryTheme.card, in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(LibraryTheme.line))
}

private func action(_ title: String, icon: String, primary: Bool = false, perform: @escaping () -> Void) -> some View {
  Button(action: perform) { Label(title, systemImage: icon).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48) }
    .buttonStyle(.plain).foregroundStyle(primary ? LibraryTheme.ink : LibraryTheme.text)
    .background(primary ? LibraryTheme.accent : LibraryTheme.card2, in: RoundedRectangle(cornerRadius: 12))
}

enum HomeMacState {
  case off, looking(String), connected(String, String?)
}

private struct MacHomeCard: View {
  @EnvironmentObject private var store: PadStore
  let snapshot: HomeMacState?
  let open: () -> Void
  var body: some View {
    let state: HomeMacState = snapshot ?? store.macConnection.map { .connected($0.name, $0.kind) } ?? (store.camera.link.allowsWiFi ? store.camera.link.pairedMacs.first.map { .looking($0.name) } : nil) ?? .off
    let connection: MacConnection? = { if case let .connected(name, kind) = state { return MacConnection(name: name, kind: kind) }; return nil }()
    let looking: String? = { if case let .looking(name) = state { return name }; return nil }()
    card(icon: "laptopcomputer", title: connection.map { "Connected to \($0.name)" } ?? (looking == nil ? "Connect to Mac" : "Looking for your Mac"), description: "Control this iPad's script and camera from your Mac.") {
      Text(connection.map { "Connected" + ($0.kind.map { " · \($0)" } ?? "") } ?? (looking == nil ? "Not connected" : "Searching…"))
        .font(.subheadline.weight(.semibold)).padding(8)
        .background((connection != nil ? LibraryTheme.good : looking != nil ? LibraryTheme.warn : LibraryTheme.muted).opacity(0.2), in: Capsule())
      if let looking { Text(looking).foregroundStyle(LibraryTheme.muted) }
      action(connection != nil ? "Manage" : looking != nil ? "Troubleshoot" : "Set up", icon: "laptopcomputer", perform: open)
    }
  }
}

struct MacTile: View {
  @EnvironmentObject private var store: PadStore
  @State private var open = false
  var body: some View {
    let connection = store.macConnection
    Button { open = true } label: {
      VStack(spacing: 3) {
        Label("Mac", systemImage: "laptopcomputer")
        HStack(spacing: 4) { Circle().fill(connection == nil ? LibraryTheme.muted : LibraryTheme.good).frame(width: 7, height: 7); Text(connection == nil ? "Off" : "Connected").font(.caption) }
      }.frame(maxWidth: .infinity, minHeight: 54)
    }.buttonStyle(.plain).background(LibraryTheme.card2, in: RoundedRectangle(cornerRadius: 12))
      .accessibilityLabel("Mac").accessibilityValue(connection.map { "Connected to \($0.name)" } ?? "Off")
      .sheet(isPresented: $open) { NavigationStack { MacControlScreen(link: store.camera.link, failure: store.camera.link.pairingFailure) }.environmentObject(store) }
  }
}
