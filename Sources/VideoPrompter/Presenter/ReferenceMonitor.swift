import AppKit
import SwiftUI

/// A passage of the script pinned over the full camera picture, so the presenter doubles as a
/// reference monitor: you check your framing while glancing at just the lines you are about to say.
@MainActor final class ReferenceMonitor: ObservableObject {
  static let shared = ReferenceMonitor()
  @Published private(set) var passage: String?
  /// What the presenter showed before the monitor took over, restored when it ends.
  private var previousMode: PresenterDisplayMode?

  var isActive: Bool { passage != nil }

  func begin(_ text: String, camera: CameraModel) {
    let cleaned = Self.clean(text)
    guard !cleaned.isEmpty else { return }
    if passage == nil { previousMode = camera.displayMode }
    passage = cleaned
    camera.displayMode = .videoOnly
  }

  /// Back to the script. A view the person picked themselves while monitoring is left alone.
  func end(camera: CameraModel) {
    guard passage != nil else { return }
    passage = nil
    if camera.displayMode == .videoOnly, let previousMode, previousMode != .videoOnly {
      camera.displayMode = previousMode
    } else if camera.displayMode == .videoOnly {
      camera.displayMode = .prompterWithVideo
    }
    previousMode = nil
  }

  /// Any other view chosen from the View menu ends the monitor without changing that choice.
  func displayModeDidChange(_ mode: PresenterDisplayMode) {
    guard passage != nil, mode != .videoOnly else { return }
    passage = nil
    previousMode = nil
  }

  /// Selected text from the library editor can carry Markdown markers; the monitor shows words only.
  nonisolated static func clean(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        var line = line.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") || line.hasPrefix(">") { line.removeFirst() }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { line.removeFirst(2) }
        return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
          .trimmingCharacters(in: .whitespaces)
      }
      .joined(separator: "\n")
      .replacingOccurrences(of: "\n\n\n", with: "\n\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The text selected in the focused script view, else anywhere in the presenter: the presenter
  /// is a non-activating panel, so its script often holds a selection without being first responder.
  static func focusedSelection() -> String? {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, let value = selection(in: text) { return value }
    guard let root = PresenterController.shared.panel?.contentView else { return nil }
    return textViews(in: root).lazy.compactMap(selection).first
  }
  private static func selection(in text: NSTextView) -> String? {
    let range = text.selectedRange()
    guard range.length > 0, NSMaxRange(range) <= (text.string as NSString).length else { return nil }
    return (text.string as NSString).substring(with: range)
  }
  private static func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
  }
}

/// The pinned passage, drawn across the bottom of the camera picture.
struct ReferenceMonitorCaption: View {
  let passage: String
  let fontName: String
  let end: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Reference monitor", systemImage: "video.badge.checkmark")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        Button("Back to script", systemImage: "text.alignleft", action: end)
          .keyboardShortcut(.cancelAction)
          .buttonStyle(.bordered)
          .help("Leave the reference monitor and return to the full script (Esc)")
      }
      // A long selection shrinks to fit rather than covering the picture it is there to check.
      Text(passage)
        .font(.custom(fontName, size: 22, relativeTo: .title3))
        .foregroundStyle(.white)
        .lineLimit(6).minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Monitored passage")
    }
    .padding(12)
    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    .padding(.horizontal, 16)
    .frame(maxWidth: 820)
  }
}
