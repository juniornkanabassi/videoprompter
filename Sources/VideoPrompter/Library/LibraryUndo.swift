import Foundation
import PrompterCore

/// Register immediately, then serialize disk work so a quick Undo cannot overtake its edit.
enum LibraryEdit {
  case rename(UUID, String)
  case move([(UUID, UUID?)])
  case link(UUID, ScriptMetadata?)
  case relink(ScriptRecord)
}

@MainActor private final class LibraryEditReceipt {
  var inverse: LibraryEdit?
}

extension AppStore {
  func performLibraryEdit(_ edit: LibraryEdit, name: String, undoManager: UndoManager?) {
    enqueueLibraryEdit(edit, name: name, undoManager: undoManager)
  }

  func registerLinkUndo(_ previous: ScriptRecord, manager: UndoManager?) {
    let receipt = LibraryEditReceipt()
    receipt.inverse = .relink(previous)
    registerLibraryUndo(receipt, name: "Link File", undoManager: manager)
  }

  private func registerLibraryUndo(_ receipt: LibraryEditReceipt, name: String, undoManager: UndoManager?) {
    undoManager?.registerUndo(withTarget: receipt) { [weak self, weak undoManager] _ in
      self?.enqueueLibraryEdit(nil, name: name, undoManager: undoManager, reversing: receipt)
    }
    undoManager?.setActionName(name)
  }

  private func enqueueLibraryEdit(_ edit: LibraryEdit?, name: String, undoManager: UndoManager?,
                                  reversing: LibraryEditReceipt? = nil) {
    let receipt = LibraryEditReceipt()
    registerLibraryUndo(receipt, name: name, undoManager: undoManager)
    libraryEditRevision += 1
    let previous = libraryEditTask
    libraryEditTask = Task { [self, weak undoManager] in
      await previous?.value
      guard let edit = reversing?.inverse ?? edit, let library else {
        undoManager?.removeAllActions(withTarget: receipt)
        return
      }
      do {
        switch edit {
        case let .rename(id, name):
          guard let folder = folders.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
          try await renameLibraryFolder(id, name: name)
          receipt.inverse = .rename(id, folder.name)
        case let .move(destinations):
          var restored: [(UUID, UUID?)] = []
          // Keep successful members reversible even when a later disk write fails.
          for (id, destination) in destinations {
            guard let script = scripts.first(where: { $0.id == id }) else { continue }
            try await moveScripts([id], to: destination)
            restored.append((id, script.metadata.folderID))
            receipt.inverse = .move(restored)
          }
        case let .relink(previous):
          // Capture the inverse only after earlier queued restores have finished.
          let current = try await library.read(previous.id)
          // Restore the library copy and link without writing either external file.
          _ = try await library.unlink(previous.id)
          let detached = try await library.read(previous.id)
          _ = try await library.save(previous.id, markdown: previous.markdown,
                                     expectedFingerprint: detached.metadata.contentFingerprint)
          _ = try await library.restoreLink(previous.id, from: previous.metadata)
          let restored = try await library.read(previous.id)
          if let index = scripts.firstIndex(where: { $0.id == previous.id }) {
            scripts[index] = restored
            session.applyEditedRecord(restored)
          }
          await refreshLinkStates()
          receipt.inverse = .relink(current)
        case let .link(id, metadata):
          guard let script = scripts.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
          let updated: ScriptMetadata
          if let metadata { updated = try await library.restoreLink(id, from: metadata) }
          else { updated = try await library.unlink(id) }
          if let index = scripts.firstIndex(where: { $0.id == id }) { scripts[index].metadata = updated }
          await refreshLinkStates()
          receipt.inverse = .link(id, script.metadata)
        }
      } catch {
        errorMessage = "The library change could not be saved. Check free space and access to the script folder, then try again. Details: \(error.localizedDescription)"
      }
      if receipt.inverse == nil { undoManager?.removeAllActions(withTarget: receipt) }
    }
  }
}
