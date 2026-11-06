import SwiftUI

/// The first success is choosing a job, before configuring the tools for it.
struct LibraryStartView: View {
  @ObservedObject var store: AppStore
  @Binding var importing: Bool
  let practice: () -> Void
  let camera: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.xxl) {
        VStack(alignment: .leading, spacing: Space.sm) {
          Text("Ready when you are").font(.largeTitle.bold())
          Text("Read your words. Keep your eyes on the camera.")
            .font(.title3).fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: Space.md) {
          Button { store.importClipboard() } label: {
            Label("Paste a Script", systemImage: "doc.on.clipboard")
          }.buttonStyle(.borderedProminent)
          HStack(spacing: Space.lg) {
            Button("Import a File…") { importing = true }
            Button("Write a Script") { store.create() }
          }
          Text("Then choose Present to open your script, and Start reading when you are ready.")
            .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        VStack(alignment: .leading, spacing: Space.md) {
          Button(action: camera) { Label("Camera Only", systemImage: "video") }
          Text("Check your framing or record without a script.")
            .fixedSize(horizontal: false, vertical: true)
        }
        Button("Try the Practice Script") {
          store.showWelcomeScript()
          practice()
        }.buttonStyle(.link)
      }.foregroundStyle(.primary).frame(maxWidth: 480, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: 460).padding(Space.section)
    }
  }
}
