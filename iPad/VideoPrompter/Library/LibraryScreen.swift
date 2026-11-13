import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

/// The Mac app's colours, shared by the library and Settings.
enum LibraryTheme {
  private static func rgb(_ value: UInt32) -> Color {
    Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
  }
  static let accent = rgb(0xF5CF4A)
  static let ink = rgb(0x1D1704)
  static let background = rgb(0x1E1E1F)
  static let card = rgb(0x262628)
  static let card2 = rgb(0x2F2F31)
  static let line = rgb(0x343437)
  static let text = rgb(0xECECEC)
  static let muted = rgb(0x9B9B9B)
  static let good = rgb(0x5FC28A)
  static let warn = rgb(0xE5A443)
  static let bad = rgb(0xE2685C)
}

/// The Mac that is sending, as far as the iPad knows it. `kind` ("USB-C" or "Wi-Fi") and the
/// Mac's display name come from the Mac's status message and may be missing, so every reader goes
/// through here: this is the one place to change if the link reports them differently.
struct MacConnection: Equatable {
  var name: String
  var kind: String?
}

extension PadStore {
  var macConnection: MacConnection? {
    guard let name = camera.link.macName else { return nil }
    return MacConnection(name: macStatus.displayName ?? name, kind: macStatus.connectionKind)
  }
}

/// Sidebar, script list and the chosen script, as in the Mac app.
struct LibraryScreen: View {
  @EnvironmentObject private var store: PadStore
  @ObservedObject var folder: ScriptFolder
  @State private var scope = LibraryScope.all
  @State private var search = ""
  @State private var importing = false
  @State private var choosingFolder = false
  @State private var showingSettings = false
  @State private var showingGoogle = false
  @State private var showingSidebar = false
  @State private var undo: DeletedScript?
  @AppStorage("askedForICloudFolder") private var askedForICloudFolder = false

  private var visible: [FolderScript] { folder.search(search, in: folder.scripts(in: scope)) }
  private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

  var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= 1000
      let narrow = geometry.size.width < 700
      let reading = narrow && store.selected != nil && scope != .recentlyDeleted
      ZStack(alignment: .leading) {
        HStack(spacing: 0) {
          if wide { sidebar.frame(width: 240) }
          if !reading {
            scriptList(showingMenu: !wide)
              .frame(width: narrow ? nil : 300)
              .frame(maxWidth: narrow ? .infinity : nil)
          }
          if !narrow || reading { detail(back: narrow) }
        }
        if !wide && showingSidebar {
          Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { showingSidebar = false }
          sidebar.frame(width: 280).transition(.move(edge: .leading))
        }
      }
      .animation(.snappy(duration: 0.2), value: showingSidebar)
    }
    .background(LibraryTheme.background.ignoresSafeArea())
    .foregroundStyle(LibraryTheme.text)
    .tint(LibraryTheme.accent)
    .overlay(alignment: .bottom) { undoBar }
    .onChange(of: store.macConnection, initial: true) { _, connection in
      if let connection { KnownMacs.note(name: connection.name, kind: connection.kind) }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
      guard case .success(let urls) = result else { return }
      Task { for url in urls { await store.importFile(url) } }
    }
    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
      askedForICloudFolder = true
      if case .success(let url) = result { folder.choose(url) }
    }
    .sheet(isPresented: $showingSettings) {
      NavigationStack { SettingsScreen() }.environmentObject(store)
    }
    .sheet(isPresented: $showingGoogle) {
      NavigationStack { GoogleDocsSheet(google: store.google, importDocument: store.importGoogleDoc) }.environmentObject(store)
    }
  }

  static let importTypes: [UTType] = [
    UTType(filenameExtension: "md") ?? .plainText, .plainText, .rtf, .pdf,
  ]

  // MARK: Sidebar

  private var sidebar: some View {
    VStack(spacing: 4) {
      HStack {
        Text("Scripts").font(.title.weight(.semibold))
        Spacer()
        Menu {
          Button("New Script", systemImage: "square.and.pencil") { store.newScript(); scope = .all; showingSidebar = false }
          Button("Import from Files…", systemImage: "square.and.arrow.down") { importing = true }
          Button("From Google Docs…", systemImage: "doc.richtext") { showingGoogle = true }
        } label: {
          Image(systemName: "plus").font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(LibraryTheme.card2, in: Circle())
        }
        .accessibilityLabel("Add script")
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 12)
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(LibraryTheme.muted)
        TextField("Search", text: $search)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.search)
        if searching {
          Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(LibraryTheme.muted) }
            .accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 44)
      .background(LibraryTheme.card2, in: RoundedRectangle(cornerRadius: 12))
      .padding(.bottom, 12)
      ScrollView {
        VStack(spacing: 4) {
          scopeRow(.all, "All Scripts")
          scopeRow(.sentFromMac, "Sent from Mac")
          if !folder.folderNames.isEmpty {
            Text("FOLDERS")
              .font(.footnote).tracking(0.5).foregroundStyle(LibraryTheme.muted)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
            ForEach(folder.folderNames, id: \.self) { scopeRow(.folder($0), $0) }
          }
        }
      }
      scopeRow(.recentlyDeleted, "Recently Deleted")
      Button { showingSettings = true; showingSidebar = false } label: {
        Text("Settings").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
      }
      .buttonStyle(.plain)
    }
    .font(.body)
    .padding(.horizontal, 16)
    .padding(.vertical, 28)
    .frame(maxHeight: .infinity)
    .background(LibraryTheme.card.ignoresSafeArea())
  }

  private func scopeRow(_ row: LibraryScope, _ title: String) -> some View {
    let selected = scope == row
    return Button { scope = row; showingSidebar = false } label: {
      HStack {
        Text(title).lineLimit(1)
        Spacer()
        Text("\(folder.count(in: row))").foregroundStyle(selected ? LibraryTheme.text : LibraryTheme.muted)
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .background(selected ? LibraryTheme.accent.opacity(0.18) : .clear)
      .overlay(alignment: .leading) {
        if selected { Rectangle().fill(LibraryTheme.accent).frame(width: 4) }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: Script list

  private func scriptList(showingMenu: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        if showingMenu {
          Button { showingSidebar = true } label: {
            Image(systemName: "sidebar.left").frame(width: 44, height: 44)
          }
          .accessibilityLabel("Show sidebar")
        }
        Text(listHeader).font(.subheadline).foregroundStyle(LibraryTheme.muted)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 12)
      if !folder.isICloud && !askedForICloudFolder && scope == .all {
        ICloudPrompt(choose: { choosingFolder = true }, dismiss: { askedForICloudFolder = true })
          .padding(.horizontal, 12).padding(.bottom, 12)
      }
      if scope == .recentlyDeleted { deletedList } else { liveList }
    }
    .padding(.top, 28)
    .overlay(alignment: .trailing) { LibraryTheme.line.frame(width: 1).ignoresSafeArea() }
  }

  private var listHeader: String {
    if scope == .recentlyDeleted {
      return folder.recentlyDeleted.count == 1 ? "1 deleted script" : "\(folder.recentlyDeleted.count) deleted scripts"
    }
    let count = visible.count
    if searching { return count == 1 ? "1 match" : "\(count) matches" }
    return (count == 1 ? "1 script" : "\(count) scripts") + " · newest first"
  }

  private var liveList: some View {
    List {
      ForEach(visible) { script in
        let selected = store.selectedID == script.id
        let label = folder.listLabel(for: script)
        Button { store.selectedID = script.id } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(label.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
            Text(folder.metaLine(for: script)).font(.subheadline).foregroundStyle(LibraryTheme.muted).multilineTextAlignment(.leading)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20).padding(.vertical, 16)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .listRowInsets(EdgeInsets())
        .listRowBackground(selected ? LibraryTheme.accent.opacity(0.16) : Color.clear)
        .listRowSeparatorTint(LibraryTheme.line)
        .contextMenu {
          Button("Present", systemImage: "play.fill") { store.present(script) }
          Button("Delete", systemImage: "trash", role: .destructive) { delete(script) }
        }
        .swipeActions {
          Button("Delete", systemImage: "trash", role: .destructive) { delete(script) }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .refreshable { folder.refresh() }
    .overlay {
      if folder.scripts.isEmpty {
        ContentUnavailableView(
          "No scripts yet", systemImage: "text.alignleft",
          description: Text(folder.isICloud
            ? "Scripts saved on your Mac appear here once iCloud delivers them."
            : "Create a script, import one, or choose your Video Prompter folder in iCloud Drive."))
      } else if visible.isEmpty {
        if searching {
          ContentUnavailableView.search(text: search)
        } else {
          ContentUnavailableView("Nothing here", systemImage: "tray", description: Text("No scripts in this list yet."))
        }
      }
    }
  }

  private var deletedList: some View {
    List {
      ForEach(folder.recentlyDeleted) { entry in
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.body.weight(.semibold))
            Text("Deleted \(ScriptFolder.dateLabel(entry.deletedAt).lowercased())").font(.subheadline).foregroundStyle(LibraryTheme.muted)
          }
          Spacer(minLength: 0)
          Button("Restore") { restore(entry) }
            .font(.body)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(LibraryTheme.card2, in: Capsule())
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(LibraryTheme.line)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .overlay {
      if folder.recentlyDeleted.isEmpty {
        ContentUnavailableView("Nothing deleted", systemImage: "trash", description: Text("Scripts you delete wait here for 30 days."))
      }
    }
  }

  // MARK: Detail

  @ViewBuilder private func detail(back: Bool) -> some View {
    Group {
      if scope == .recentlyDeleted {
        ContentUnavailableView("Recently Deleted", systemImage: "trash", description: Text("Restore a script to read or present it. Deleted scripts are kept for 30 days."))
      } else if let script = store.selected {
        // Fresh state per script, so a refresh still answering for one never asks about another.
        ScriptDetail(script: script, back: back ? { store.selectedID = nil } : nil, delete: delete).id(script.id)
      } else {
        ContentUnavailableView("Choose a script", systemImage: "doc.text", description: Text("Pick a script on the left, then press Open presenter."))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Delete and undo

  private func delete(_ script: FolderScript) {
    do {
      let entry = try folder.delete(script)
      store.forgetGoogleLink(script)
      if store.selectedID == script.id { store.selectedID = nil }
      undo = entry
    } catch { store.errorMessage = error.localizedDescription }
  }

  private func restore(_ entry: DeletedScript) {
    do {
      let script = try folder.restore(entry)
      if undo == entry {
        undo = nil
        store.selectedID = script.id
      }
    } catch { store.errorMessage = error.localizedDescription }
  }

  @ViewBuilder private var undoBar: some View {
    if let undo {
      HStack(spacing: 16) {
        Text("Deleted “\(undo.title)”").lineLimit(1)
        Button("Undo") { restore(undo) }
          .fontWeight(.semibold)
          .foregroundStyle(LibraryTheme.accent)
          .frame(minWidth: 44, minHeight: 44)
      }
      .padding(.horizontal, 20)
      .background(LibraryTheme.card2, in: Capsule())
      .overlay(Capsule().stroke(LibraryTheme.line))
      .padding(.bottom, 24)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .task(id: undo) {
        try? await Task.sleep(for: .seconds(6))
        if !Task.isCancelled { withAnimation { self.undo = nil } }
      }
    }
  }
}

/// Shown until the iCloud folder is chosen or the offer dismissed.
private struct ICloudPrompt: View {
  let choose: () -> Void
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Use the same scripts as your Mac", systemImage: "icloud").font(.headline)
      Text("On the Mac, turn on File › Keep Scripts in iCloud Drive for iPad. Then choose iCloud Drive › Video Prompter here.")
        .font(.subheadline).foregroundStyle(LibraryTheme.muted)
      HStack {
        Button("Choose Folder", action: choose).buttonStyle(.borderedProminent).foregroundStyle(LibraryTheme.ink)
        Button("Not Now", action: dismiss)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(LibraryTheme.card, in: RoundedRectangle(cornerRadius: 16))
  }
}

/// The chosen script: title, connection and the presenter button on top, the editor below, and a
/// footer that says how long it is and which copy this is.
private struct ScriptDetail: View {
  @EnvironmentObject private var store: PadStore
  let script: FolderScript
  let back: (() -> Void)?
  let delete: (FolderScript) -> Void
  @State private var renaming = false
  @State private var newTitle = ""
  @State private var updating = false
  @State private var confirmingOverwrite = false
  @State private var updateNote: String?
  @State private var explainingCopy = false
  @State private var flusher = PadDraftFlusher()

  var body: some View {
    VStack(spacing: 0) {
      header
      LibraryTheme.line.frame(height: 1)
      if script.isDownloaded {
        // The editing view, with its own formatting row, is the script editor's.
        ScriptEditor(script: script, flusher: flusher)
      } else {
        ProgressView("Downloading from iCloud…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      LibraryTheme.line.frame(height: 1)
      footer
    }
    // A presentation started elsewhere (the Mac) still shows what is on screen here.
    .onChange(of: store.presentingID) { _, id in if id != nil { _ = flusher.flush?() } }
    .confirmationDialog(
      "This script was edited since it came from Google Docs", isPresented: $confirmingOverwrite, titleVisibility: .visible
    ) {
      Button("Replace with the Google Doc", role: .destructive) { Task { await updateFromGoogle(overwrite: true) } }
      Button("Keep This Version", role: .cancel) {}
    } message: {
      Text("Updating replaces those edits with the document as it is in Google Docs now.")
    }
    .overlay(alignment: .top) {
      if let updateNote {
        Text(updateNote)
          .font(.callout)
          .padding(.horizontal, 16).padding(.vertical, 8)
          .background(LibraryTheme.card2, in: Capsule())
          .padding(.top, 8)
          .task {
            try? await Task.sleep(for: .seconds(2.5))
            self.updateNote = nil
          }
      }
    }
    .alert("Rename Script", isPresented: $renaming) {
      TextField("Title", text: $newTitle)
      Button("Rename") {
        do { try store.folder.rename(script, to: newTitle) } catch { store.errorMessage = error.localizedDescription }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      if let back {
        Button(action: back) { Image(systemName: "chevron.backward").frame(width: 44, height: 44) }
          .accessibilityLabel("Back to scripts")
      }
      Text(script.title).font(.title2.weight(.semibold)).lineLimit(1)
      Spacer(minLength: 12)
      if let connection = store.macConnection {
        HStack(spacing: 8) {
          Circle().fill(LibraryTheme.good).frame(width: 8, height: 8)
          Text(connection.kind.map { "Mac · \($0)" } ?? "Mac").font(.subheadline)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(LibraryTheme.card, in: Capsule())
        .overlay(Capsule().stroke(LibraryTheme.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connected to \(connection.name)")
      }
      Button {
        // Present what is on screen: an unsaved draft is written first, and a failed save stops here.
        if flusher.flush?() ?? true { store.present(script) }
      } label: {
        Label("Open presenter", systemImage: "play.fill")
          .font(.body.weight(.semibold))
          .foregroundStyle(LibraryTheme.ink)
          .padding(.horizontal, 24)
          .frame(height: 48)
          .background(LibraryTheme.accent, in: Capsule())
      }
      .buttonStyle(.plain)
      .disabled(!script.isDownloaded)
      .opacity(script.isDownloaded ? 1 : 0.4)
      .keyboardShortcut(.return, modifiers: .command)
      Menu {
        Button("Rename", systemImage: "character.cursor.ibeam") { newTitle = script.title; renaming = true }
        if store.isFromGoogle(script) {
          Button("Update from Google Docs", systemImage: "arrow.triangle.2.circlepath") {
            Task { await updateFromGoogle(overwrite: false) }
          }
          .disabled(updating)
        }
        Button("Delete", systemImage: "trash", role: .destructive) { delete(script) }
      } label: {
        Image(systemName: "ellipsis").frame(width: 44, height: 44).background(LibraryTheme.card2, in: Circle())
      }
      .accessibilityLabel("More")
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 24)
  }

  private var footer: some View {
    HStack(spacing: 16) {
      Text(store.folder.readingLine(for: script) ?? "")
      Spacer(minLength: 16)
      Button { explainingCopy = true } label: {
        HStack(spacing: 4) {
          Text(store.folder.copyLabel(for: script)).multilineTextAlignment(.trailing)
          Image(systemName: "info.circle")
        }
        .frame(minHeight: 44)
      }
      .buttonStyle(.plain)
      .popover(isPresented: $explainingCopy) {
        Text(copyExplanation)
          .font(.callout).padding(16).frame(width: 320, alignment: .leading)
          .presentationCompactAdaptation(.popover)
      }
    }
    .font(.subheadline)
    .foregroundStyle(LibraryTheme.muted)
    .padding(.horizontal, 40)
  }

  private var copyExplanation: String {
    switch store.folder.origin(of: script) {
    case .fromMac:
      "This is the copy the Mac sent. Edits you make here are saved on this iPad, and the Mac never writes over them."
    case .editedHere:
      "You edited this copy on the iPad. If the Mac sends the script again, its newer text is saved as a separate script beside this one, so nothing is lost."
    case .own:
      "This script lives in your scripts folder. Edits are saved as you finish them, and the Mac sees them within a few seconds."
    }
  }
}

extension ScriptDetail {
  fileprivate func updateFromGoogle(overwrite: Bool) async {
    updating = true
    defer { updating = false }
    switch await store.refreshFromGoogle(script, overwrite: overwrite) {
    case .hasLocalEdits: confirmingOverwrite = true
    case .updated: updateNote = "Updated from Google Docs"
    case .unchanged: updateNote = "Already up to date"
    case nil: break
    }
  }
}
