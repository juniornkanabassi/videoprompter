import PrompterCore
import SwiftUI

/// A plain Markdown editor for last-minute fixes. Saving writes the file in place, so the Mac
/// sees the change within seconds, and an open presenter keeps its place.
struct ScriptEditor: View {
  @EnvironmentObject private var store: PadStore
  @Environment(\.dismiss) private var dismiss
  let script: FolderScript
  @State private var text = ""
  @State private var original = ""
  @State private var loaded = false

  var body: some View {
    NavigationStack {
      TextEditor(text: $text)
        .font(.custom("Lexend Deca", size: 18, relativeTo: .body))
        .lineSpacing(5)
        .padding(.horizontal, 12)
        .scrollContentBackground(.hidden)
        .navigationTitle(script.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              if text == original || store.save(text, to: script) { dismiss() }
            }
            .keyboardShortcut("s", modifiers: .command)
          }
        }
    }
    .interactiveDismissDisabled(text != original)
    .onAppear {
      guard !loaded, let record = store.record(for: script) else { return }
      text = record.markdown
      original = record.markdown
      loaded = true
    }
  }
}
