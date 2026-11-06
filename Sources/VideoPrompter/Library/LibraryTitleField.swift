import AppKit
import SwiftUI

/// A native editable title with a measured wrapped height, including before it takes focus.
struct LibraryTitleField: NSViewRepresentable {
  @Binding var title: String

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: title)
    field.isEditable = true
    field.isSelectable = true
    field.maximumNumberOfLines = 3
    field.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .regular)
    field.delegate = context.coordinator
    field.setAccessibilityLabel("Script title")
    field.toolTip = "Title, tags and script text save automatically"
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != title { field.stringValue = title }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
    let width = max(1, proposal.width ?? 400)
    let font = nsView.font!
    let line = ceil(font.ascender - font.descender + font.leading)
    let bounds = NSAttributedString(string: title.isEmpty ? "Title" : title, attributes: [.font: font])
      .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return CGSize(width: width, height: min(line * 3, max(line, ceil(bounds.height))) + 4)
  }
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: LibraryTitleField
    init(_ parent: LibraryTitleField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.title = field.stringValue
      field.invalidateIntrinsicContentSize()
    }
  }
}
