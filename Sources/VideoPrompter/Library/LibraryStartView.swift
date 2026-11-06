import SwiftUI

/// The first success is choosing a job, before configuring the tools for it.
struct LibraryStartView: View {
  @ObservedObject var store: AppStore
  @Binding var importing: Bool
  let practice: () -> Void
  let camera: () -> Void

  @ViewBuilder private var otherScriptActions: some View {
    Button("Import a File…") { importing = true }
    Button("Write a Script") { store.create() }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.xxl) {
        VStack(alignment: .leading, spacing: Space.sm) {
          Text("Ready when you are").font(store.uiZoom >= 1.5 ? UIType.title : .largeTitle.bold())
        }
        VStack(alignment: .leading, spacing: Space.md) {
          Button { store.importClipboard() } label: {
            Label("Paste Copied Text", systemImage: "doc.on.clipboard")
          }.buttonStyle(.borderedProminent)
          Text("Copy your script, then paste it here.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        Text("Then choose **Present**, then **Start reading**. Voice follow moves the text as you speak.")
          .font(.callout).fixedSize(horizontal: false, vertical: true)
          Button("Try the Practice Script", action: practice).buttonStyle(.link)
            .help("Open a short guided practice, then choose Start reading")
        }
        VStack(alignment: .leading, spacing: Space.md) {
          Button(action: camera) { Label("Camera Only", systemImage: "video") }
          Text("Check your framing or record without a script.")
            .fixedSize(horizontal: false, vertical: true)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Space.lg) { otherScriptActions }
          VStack(alignment: .leading, spacing: Space.sm) { otherScriptActions }
        }
      }.foregroundStyle(.primary).frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(Space.margin)
    }
  }
}
