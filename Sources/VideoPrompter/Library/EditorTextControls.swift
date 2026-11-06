import SwiftUI

/// Settings > General and the library popover share the same writing preferences.
struct EditorTextControls: View {
  @ObservedObject var store: AppStore
  var showsReadingLink = false
  @Environment(\.openSettings) private var openSettings
  var body: some View {
    ReadingChoice(title: "Editor font", values: AvailableFonts.editor, names: AvailableFonts.editor,
      selection: $store.previewFontName, zoom: store.uiZoom)
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("Editor text size")
      Text("\(Int(store.previewFontSize)) pt").font(UIType.secondary).monospacedDigit()
      Slider(value: $store.previewFontSize, in: AppStore.editorFontSizes)
        .accessibilityLabel("Editor text size").accessibilityValue("\(Int(store.previewFontSize)) points")
    }
    VStack(alignment: .leading, spacing: Space.sm) {
      Text("Changes only the writing surface.").font(UIType.secondary)
        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
      if showsReadingLink {
        Button("Reading text size…") {
          AppSettingsView.requestTab(.reading)
          openSettings()
        }.buttonStyle(.link)
          .help("Open Reading text size in Settings > Reading")
      }
    }
  }
}

struct EditorTextPopover: View {
  @ObservedObject var store: AppStore
  var body: some View {
    Form { Section("Writing") { EditorTextControls(store: store, showsReadingLink: true) } }
      .formStyle(.grouped).uiZoom(store.uiZoom)
      .frame(width: min(560, 320 * store.uiZoom), height: min(540, 280 * store.uiZoom))
  }
}
