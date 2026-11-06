import Combine
import Foundation

/// One ordered save queue for the editor's title, tags and body feedback.
@MainActor final class LibraryEditorSave: ObservableObject {
  @Published private(set) var message = "Changes save automatically"
  @Published private(set) var isSaving = false
  @Published private(set) var failed = false
  private var task: Task<Void, Never>?
  private var generation = 0

  @discardableResult
  func schedule(store: AppStore, id: UUID, title: String, tags: [String], delay: Duration = .milliseconds(450)) -> Task<Void, Never> {
    let previous = task
    previous?.cancel()
    generation += 1
    let current = generation
    isSaving = true
    failed = false
    message = "Saving…"
    task = Task { @MainActor in
      await previous?.value
      do {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        if let record = store.scripts.first(where: { $0.id == id }),
          record.metadata.title != title || record.metadata.tags != tags {
          try await store.updateScriptMetadata(id, title: title, tags: tags)
        }
        let saved = await store.flushPendingSaves()
        try Task.checkCancellation()
        guard current == generation else { return }
        isSaving = false
        failed = !saved
        message = saved ? "Saved" : "Not saved. Try saving again."
        LibraryAnnouncement.post(message)
      } catch is CancellationError {} catch {
        guard current == generation else { return }
        isSaving = false
        failed = true
        message = "Could not save changes. \(error.localizedDescription)"
        LibraryAnnouncement.post(message)
      }
    }
    return task!
  }
}
