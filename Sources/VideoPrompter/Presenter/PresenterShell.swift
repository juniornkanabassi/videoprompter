import SwiftUI

/// Reading stays selected while paused; Clean preserves the exact reading anchor.
@MainActor final class PresenterShell: ObservableObject {
  @Published var reading: Bool
  @Published var adjustTab: AdjustTab?
  /// The script shown over the picture while setting up, before reading starts. Turning the camera
  /// off switches it on, so the presenter then sees just the script.
  @Published var scriptPreview: Bool

  init(reading: Bool = false, adjustTab: AdjustTab? = nil, scriptPreview: Bool = true) {
    self.reading = reading
    self.adjustTab = adjustTab
    self.scriptPreview = scriptPreview
  }

  func cleanEntered(session: SessionStore) {
    adjustTab = nil
  }

  @discardableResult func escape(camera: CameraModel, session: SessionStore) -> Bool {
    if camera.cleanView { camera.cleanView = false }
    else if adjustTab != nil { adjustTab = nil }
    else { return false }
    return true
  }
}
