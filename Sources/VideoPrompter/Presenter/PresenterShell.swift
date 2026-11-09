import SwiftUI

/// Reading stays selected while paused; Clean preserves the exact reading anchor.
@MainActor final class PresenterShell: ObservableObject {
  @Published var reading: Bool
  @Published var adjustTab: AdjustTab?

  init(reading: Bool = false, adjustTab: AdjustTab? = nil) {
    self.reading = reading
    self.adjustTab = adjustTab
  }

  func cleanEntered(session: SessionStore) {
    session.pause()
    adjustTab = nil
  }

  @discardableResult func escape(camera: CameraModel, session: SessionStore) -> Bool {
    if camera.cleanView { camera.cleanView = false }
    else if adjustTab != nil { adjustTab = nil }
    else if reading { session.pause(); reading = false }
    else { return false }
    return true
  }
}
