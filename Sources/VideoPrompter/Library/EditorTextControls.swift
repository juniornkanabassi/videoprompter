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
      ReadingSlider(value: $store.previewFontSize, range: AppStore.editorFontSizes,
        title: "Editor text size", spokenValue: "\(Int(store.previewFontSize)) points")
    }
    if showsReadingLink {
        Button {
          AppSettingsView.requestTab(.reading)
          openSettings()
        } label: {
          Text("Reading text size…").underline().foregroundStyle(.primary)
            .frame(minHeight: 24).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .help("Open Reading text size in Settings > Reading")
    }
  }
}

struct EditorTextPopover: View {
  @ObservedObject var store: AppStore
  var body: some View {
    Form {
      Section { EditorTextControls(store: store, showsReadingLink: true) }
      header: { Text("Writing") }
      footer: { Text("Changes only the writing surface.").font(.callout).foregroundStyle(.primary) }
    }
      .formStyle(.grouped).uiZoom(store.uiZoom)
      .frame(width: min(560, 320 * store.uiZoom), height: min(540, 280 * store.uiZoom))
  }
}
