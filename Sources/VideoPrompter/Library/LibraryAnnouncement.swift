#if os(macOS)
import AppKit

@MainActor enum LibraryAnnouncement {
  static func post(_ message: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }
}
#endif
