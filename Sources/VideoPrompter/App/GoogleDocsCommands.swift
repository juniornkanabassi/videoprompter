import AppKit
import PrompterCore
import SwiftUI

/// The Mac's Google Docs import: File › Import from Google Docs… opens the same sheet the iPad
/// uses, in a window of its own, and File › Update from Google Docs fetches the selected script's
/// document again. Imported scripts are ordinary library scripts; the link to their document is
/// remembered beside them in the preferences.
@MainActor enum MacGoogleDocs {
  static let docs = GoogleDocs()
  static var links: GoogleDocLinks { GoogleDocLinks(defaults: AppStore.preferences()) }
}

extension AppStore {
  /// Imports a Google Doc as a new script in the selected folder. Returns why it failed, or nil.
  func importGoogleDoc(_ document: String) async -> String? {
    do {
      let (title, markdown) = try await MacGoogleDocs.docs.export(document)
      let record = try await createScript(title: title, markdown: markdown)
      MacGoogleDocs.links[record.id] = .init(document: document, fingerprint: MarkdownLibrary.fingerprint(markdown))
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func isFromGoogle(_ id: UUID) -> Bool { MacGoogleDocs.links[id] != nil }

  /// Fetches the selected script's document again and puts it in as an edit, so it is saved,
  /// undone and shown in an open presenter like any other. Asks first if the script was edited
  /// since it last came from Google.
  func updateSelectedFromGoogle() {
    guard let script = selected, let link = MacGoogleDocs.links[script.id] else { return }
    if MarkdownLibrary.fingerprint(script.markdown) != link.fingerprint {
      let alert = NSAlert()
      alert.messageText = "This script was edited since it came from Google Docs"
      alert.informativeText = "Updating replaces those edits with the document as it is in Google Docs now."
      alert.addButton(withTitle: "Replace with the Google Doc")
      alert.addButton(withTitle: "Keep This Version")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    let id = script.id
    Task {
      do {
        let (_, markdown) = try await MacGoogleDocs.docs.export(link.document)
        MacGoogleDocs.links[id] = .init(document: link.document, fingerprint: MarkdownLibrary.fingerprint(markdown))
        updateMarkdown(markdown, for: id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

/// The import window's content.
struct GoogleDocsWindow: View {
  @ObservedObject var store: AppStore
  var body: some View {
    NavigationStack {
      GoogleDocsSheet(google: MacGoogleDocs.docs, importDocument: store.importGoogleDoc)
    }
  }
}
