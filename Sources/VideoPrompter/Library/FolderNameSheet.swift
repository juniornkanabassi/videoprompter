import SwiftUI

/// Alert text fields lose their native accessible name; a labelled sheet preserves it.
struct FolderNameSheet: View {
  let title: String
  @Binding var name: String
  let action: String
  let zoom: Double
  let cancel: () -> Void
  let save: () -> Void
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Space.lg) {
      Text(title).font(.headline).accessibilityAddTraits(.isHeader)
      VStack(alignment: .leading, spacing: Space.sm) {
        Text("Folder name").font(.callout)
        TextField("Folder name", text: $name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Folder name")
          .help("Enter a name for this folder")
          .focused($nameFocused)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button(action, action: save).keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(Space.xxl).uiZoom(zoom)
      .frame(width: min(360 * zoom, 640))
      .onAppear { nameFocused = true }
  }
}
