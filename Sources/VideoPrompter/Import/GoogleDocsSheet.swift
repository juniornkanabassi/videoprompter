import SwiftUI

/// The privacy policy both apps link to, from Settings or the Help menu and from Google sign-in.
enum PrivacyPolicy {
  static let url = URL(string: "https://juniornkanabassi.com/privacy/video-prompter/")!
}

/// Import from Google Docs, on the Mac and the iPad. A pasted link always works for a document
/// shared with "Anyone with the link"; signing in with Google adds the account's own documents,
/// searchable, newest first. `importDocument` brings one in and returns why it failed, or nil.
struct GoogleDocsSheet: View {
  @ObservedObject var google: GoogleDocs
  let importDocument: (String) async -> String?
  @Environment(\.dismiss) private var dismiss
  @State private var link = ""
  @State private var search = ""
  @State private var docs: [GoogleDoc] = []
  @State private var loading = false
  @State private var importing: String?
  @State private var problem: String?

  var body: some View {
    Form {
      Section {
        TextField("https://docs.google.com/document/d/…", text: $link)
          .autocorrectionDisabled()
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
          #endif
          .onSubmit { importLink() }
        Button {
          importLink()
        } label: {
          if importing == GoogleDocs.documentID(from: link), importing != nil {
            ProgressView()
          } else {
            Text("Import")
          }
        }
        .disabled(GoogleDocs.documentID(from: link) == nil || importing != nil)
      } header: {
        Text("Paste a link")
      } footer: {
        Text(google.isSignedIn
          ? "Any document your Google account can open."
          : "Works for documents shared with “Anyone with the link”. For others, sign in below.")
      }

      if google.canSignIn {
        if google.isSignedIn {
          Section("Your Google Docs") {
            TextField("Search", text: $search)
              .onSubmit { Task { await load() } }
            if loading && docs.isEmpty { ProgressView() }
            ForEach(docs) { doc in
              Button {
                Task { await bringIn(doc.id) }
              } label: {
                HStack {
                  Label(doc.name, systemImage: "doc.richtext")
                  Spacer()
                  if importing == doc.id {
                    ProgressView()
                  } else if let modified = doc.modified {
                    Text(modified, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                  }
                }
              }
              .disabled(importing != nil)
            }
          }
          Section {
            Button("Sign Out of Google", role: .destructive) { google.signOut() }
          }
        } else {
          Section {
            Button {
              Task {
                do {
                  try await google.signIn()
                  await load()
                } catch { problem = error.localizedDescription }
              }
            } label: {
              Label("Sign in with Google", systemImage: "person.crop.circle")
            }
          } footer: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Video Prompter asks Google for read-only access to your Drive, to list your documents and copy the ones you choose into the app. It never changes your Drive, and nothing goes anywhere but this device. Signing out here also revokes the access at Google.")
              Link("Privacy Policy", destination: PrivacyPolicy.url)
            }
          }
        }
      }

      if let problem {
        Section { Text(problem).foregroundStyle(.red) }
      }
    }
    .navigationTitle("Import from Google Docs")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #else
    .formStyle(.grouped)
    .frame(minWidth: 480, minHeight: 420)
    #endif
    .toolbar { Button("Done") { dismiss() } }
    .task(id: google.isSignedIn) { if google.isSignedIn { await load() } }
    .onChange(of: search) {
      Task {
        try? await Task.sleep(for: .milliseconds(400))
        await load()
      }
    }
  }

  private func importLink() {
    guard let id = GoogleDocs.documentID(from: link) else {
      problem = GoogleDocsError.notALink.localizedDescription
      return
    }
    Task { await bringIn(id) }
  }

  private func bringIn(_ id: String) async {
    importing = id
    problem = nil
    // A failure is shown here rather than as an alert behind the sheet.
    problem = await importDocument(id)
    importing = nil
    if problem == nil { dismiss() }
  }

  private func load() async {
    let query = search
    loading = true
    defer { loading = false }
    do {
      let found = try await google.list(matching: query)
      if query == search { docs = found }
    } catch { problem = error.localizedDescription }
  }
}
