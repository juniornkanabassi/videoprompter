import Foundation

/// A guided try opens the presenter, but never starts the microphone or a recording.
@MainActor enum PracticeReading {
  static let title = "Practice reading"
  static func markdown(voiceFollow: Bool) -> String {
    """
    # Practice reading

    Press Start reading, then say these words aloud.

    \(voiceFollow ? "The text follows my voice. I can pause here, take a breath, and carry on when I am ready." : "The text scrolls at a steady speed. I can change to Voice follow in Settings > Reading if I want it to follow my voice.")

    I am looking towards the camera and reading at my own pace.

    Now press Pause. Use Back to start to try again.

    This practice does not record a video. When I am ready to record, I press Record and Start reading separately.
    """
  }

  @discardableResult static func prepare(store: AppStore) async throws -> UUID {
    let text = markdown(voiceFollow: store.settings.mode == "Voice")
    let record = if let existing = store.scripts.first(where: { $0.metadata.title == title && $0.markdown == text }) {
      existing
    } else {
      try await store.createScript(title: title, markdown: text)
    }
    store.selectFolder(nil)
    store.search = ""
    store.selectedID = record.id
    return record.id
  }

  static func present(store: AppStore, camera: CameraModel = .shared, show: (AppStore) -> Void = { PresenterController.shared.presentFromLibrary(store: $0) }) async {
    do {
      try await prepare(store: store)
      camera.cleanView = false
      camera.showTemporarily(.prompterOnly)
      show(store)
    } catch {
      store.errorMessage = "The practice script could not be saved. Check free space and try again. \(error.localizedDescription)"
    }
  }
}
