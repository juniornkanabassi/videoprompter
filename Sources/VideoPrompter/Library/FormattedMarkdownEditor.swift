import AppKit
import SwiftUI
import PrompterCore

enum EditorFormatAction {
  case bold, italic, heading, link
}

/// Type and layout an editing surface borrows from wherever it is shown, so the
/// presenter can edit in place without the text moving or changing appearance.
struct EditorTypography {
  var textColor: NSColor = .labelColor
  var lineSpacing: Double = 0
  var paragraphSpacing: Double = 0
  var horizontalInset: Double = 0
  var alignment: NSTextAlignment = .left
}

private final class FormattingTextView: NSTextView {
  var onFormat: ((EditorFormatAction) -> Void)?

  /// Width autoresizing adds the clip view's change, which drifts once a zoomed pane rescales
  /// the scroll view: zoomed out, the text wrapped short of the pane and its right strip took
  /// no clicks. The text is always exactly as wide as what shows it.
  override func setFrameSize(_ newSize: NSSize) {
    var size = newSize
    if !isHorizontallyResizable, let clip = superview as? NSClipView { size.width = clip.bounds.width }
    super.setFrameSize(size)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    menu.addItem(.separator())
    for item in formatMenu().items { menu.addItem(item.copy() as! NSMenuItem) }
    return menu
  }

  private func formatMenu() -> NSMenu {
    let menu = NSMenu(title: "Format")
    for (title, action) in [
      ("Bold", EditorFormatAction.bold),
      ("Italic", EditorFormatAction.italic),
      ("Heading", EditorFormatAction.heading),
      ("Add or Edit Link…", EditorFormatAction.link)
    ] {
      let item = NSMenuItem(title: title, action: #selector(applyFormat(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = action
      menu.addItem(item)
    }
    return menu
  }

  @objc private func applyFormat(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? EditorFormatAction else { return }
    onFormat?(action)
  }
}

/// A formatted editor which changes only the visible source characters the user selected.
struct FormattedMarkdownEditor: NSViewRepresentable {
  @Binding var markdown: String
  var fontName: String
  var fontSize: Double
  var onUnsupportedEdit: (() -> Void)? = nil
  var focusesOnAppear = false
  var typography = EditorTypography()
  /// Markdown offset to place on the guide when the editor appears, so an in-place
  /// presenter edit starts where the reader was.
  var anchorSourceOffset: Int? = nil
  var guideFraction = 0.35
  /// The reading view flips the guide for a vertically mirrored presenter; editing in place
  /// must flip it the same way or the anchored passage jumps when the pencil is pressed.
  var verticalMirror = false
  /// Markdown offset the reader has read up to: the text before it is greyed as the presenter greys
  /// it, so editing in place still shows where the reading got to.
  var readThroughSourceOffset: Int? = nil

  /// Menu actions follow the first responder, so both editing surfaces use the same formatter.
  @discardableResult static func formatFocused(_ action: EditorFormatAction, in window: NSWindow? = NSApp.keyWindow) -> Bool {
    guard canFormat(in: window), let editor = window?.firstResponder as? FormattingTextView else { return false }
    editor.onFormat?(action)
    return true
  }

  static func canFormat(in window: NSWindow? = NSApp.keyWindow) -> Bool {
    guard let editor = window?.firstResponder as? FormattingTextView else { return false }
    return editor.isEditable && editor.onFormat != nil
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSView {
    let root = NSView()
    let scroll = NSScrollView()
    root.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    let layout = NSLayoutManager()
    let storage = NSTextStorage()
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    let view = FormattingTextView(frame: NSRect.zero, textContainer: container)
    view.setAccessibilityLabel("Script editor")
    view.minSize = NSSize.zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = NSView.AutoresizingMask.width
    view.isRichText = true
    view.allowsUndo = true
    view.drawsBackground = false
    view.delegate = context.coordinator
    view.onFormat = { [weak coordinator = context.coordinator, weak view] action in
      guard let coordinator, let view else { return }
      coordinator.apply(action, in: view)
    }
    scroll.documentView = view
    view.textContainerInset = NSSize(width: typography.horizontalInset, height: 8)
    context.coordinator.configure(view, markdown: markdown, fontName: fontName, fontSize: fontSize, typography: typography,
      readThrough: readThroughSourceOffset)
    if focusesOnAppear {
      DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
    if let anchorSourceOffset {
      DispatchQueue.main.async { [guideFraction, verticalMirror] in
        context.coordinator.scrollToAnchor(
          view, sourceOffset: anchorSourceOffset, guideFraction: guideFraction,
          verticalMirror: verticalMirror)
      }
    }
    return root
  }

  func updateNSView(_ root: NSView, context: Context) {
    guard let scroll = root.subviews.compactMap({ $0 as? NSScrollView }).first,
      let view = scroll.documentView as? NSTextView
    else { return }
    context.coordinator.parent = self
    view.textContainerInset.width = typography.horizontalInset
    context.coordinator.configure(view, markdown: markdown, fontName: fontName, fontSize: fontSize, typography: typography,
      readThrough: readThroughSourceOffset)
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: FormattedMarkdownEditor
    private var model = FormattedMarkdownEditModel(markdown: "")
    private var updating = false
    private var fontName = ""
    private var fontSize = 0.0
    private var typography = EditorTypography()
    private weak var textView: NSTextView?
    private let editorUndoManager = UndoManager()

    init(_ parent: FormattedMarkdownEditor) { self.parent = parent }

    func configure(_ view: NSTextView, markdown: String, fontName: String, fontSize: Double,
      typography: EditorTypography = EditorTypography(), readThrough: Int? = nil)
    {
      textView = view
      // Keep links legible on the actual editor surface, including the dark presenter.
      view.linkTextAttributes = [.foregroundColor: typography.textColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue]
      let changedReading = self.readThrough?.offset != readThrough
      // Kept with the text it was measured in, so edits before it move the grey edge with them.
      if changedReading { self.readThrough = readThrough.map { ($0, markdown) } }
      let changedFont = changedReading || self.fontName != fontName || self.fontSize != fontSize
        || self.typography.textColor != typography.textColor
        || self.typography.lineSpacing != typography.lineSpacing
        || self.typography.paragraphSpacing != typography.paragraphSpacing
        || self.typography.alignment != typography.alignment
      self.fontName = fontName
      self.fontSize = fontSize
      self.typography = typography
      // A binding echo after a native edit has the same source model. Re-rendering it
      // would reset AppKit's selection and undo grouping.
      guard model.markdown != markdown || changedFont else { return }
      // A different source that did not come from typing here (Obsidian saved the linked file),
      // or a new text size (Zoom In): what is on screen stays where it is.
      let old = model
      let top = viewportTop(of: view, in: old)
      if old.markdown != markdown {
        editorUndoManager.removeAllActions()
        model = FormattedMarkdownEditModel.cached(markdown: markdown)
      }
      render(view, keeping: view.selectedRange())
      applyEmptyTypingAttributes(to: view)
      if let top { restoreViewport(view, top, from: old.markdown) }
    }

    /// The source offset of the first line showing, and how far below the top edge that line sits.
    /// Nil at the very top, where there is nothing to keep.
    private func viewportTop(of view: NSTextView, in model: FormattedMarkdownEditModel) -> (offset: Int, inset: CGFloat)? {
      guard let scroll = view.enclosingScrollView, let manager = view.layoutManager,
        let container = view.textContainer, view.string.utf16.count > 0
      else { return nil }
      let clip = scroll.contentView.bounds
      guard clip.minY > 0 else { return nil }
      let glyph = manager.glyphIndex(
        for: NSPoint(x: view.textContainerInset.width, y: clip.minY - view.textContainerInset.height), in: container)
      guard let offset = model.sourceOffset(forVisibleIndex: manager.characterIndexForGlyph(at: glyph)) else { return nil }
      let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      return (offset, line.minY + view.textContainerInset.height - clip.minY)
    }

    private func restoreViewport(_ view: NSTextView, _ top: (offset: Int, inset: CGFloat), from old: String) {
      guard let scroll = view.enclosingScrollView, let manager = view.layoutManager,
        let container = view.textContainer,
        let index = model.visibleIndex(forSourceOffset: Self.mappedOffset(top.offset, from: old, to: model.markdown)),
        index < view.string.utf16.count
      else { return }
      manager.ensureLayout(for: container)
      let line = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil)
      let clip = scroll.contentView
      clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x,
        y: max(0, line.minY + view.textContainerInset.height - top.inset)))
      scroll.reflectScrolledClipView(clip)
    }

    /// Where a source offset of `old` lands in `new`: unchanged before the edit, shifted by the
    /// change in length after it, and at the start of the replaced span inside it.
    static func mappedOffset(_ offset: Int, from old: String, to new: String) -> Int {
      let a = Array(old.utf16), b = Array(new.utf16)
      var prefix = 0
      while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
      var suffix = 0
      while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
      if offset <= prefix { return offset }
      if offset >= a.count - suffix { return offset + b.count - a.count }
      return prefix
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
      replacementString text: String?) -> Bool
    {
      if textView.hasMarkedText() { return true }
      if textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true { return true }
      guard !updating, let text, let next = model.replacing(range, with: text) else {
        if !updating { parent.onUnsupportedEdit?() }
        return false
      }
      // Keep this internal model ahead of the native mutation so a sequence of undo,
      // redo or marked-text replacements is mapped against the current visible text.
      // The SwiftUI binding is deliberately updated in textDidChange.
      let previous = model
      model = next
      textView.undoManager?.registerUndo(withTarget: self) { target in target.restore(previous) }
      return true
    }

    func textDidChange(_ notification: Notification) {
      guard !updating, let view = notification.object as? NSTextView else { return }
      commit(view)
    }

    private func commit(_ view: NSTextView) {
      guard !updating, !view.hasMarkedText() else { return }
      if view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true { return }
      // This is only a recovery path for an AppKit mutation that did not take the
      // delegate route. Normal undo/redo restores its exact registered source snapshot.
      var rendered = styled()
      if view.string != rendered.string {
        guard let edit = Self.visibleEdit(from: rendered.string,
          to: view.string), let next = model.replacing(edit.range, with: edit.replacement)
        else {
          render(view, keeping: view.selectedRange())
          parent.onUnsupportedEdit?()
          return
        }
        model = next
        rendered = styled()
      }
      reconcileAttributes(in: view, rendered: rendered)
      parent.markdown = model.markdown
    }

    func apply(_ action: EditorFormatAction, in view: NSTextView) {
      switch action {
      case .bold: apply(model.applyingStyle("**", to: view.selectedRange()), in: view)
      case .italic: apply(model.applyingStyle("*", to: view.selectedRange()), in: view)
      case .heading: apply(model.applyingHeading(to: view.selectedRange()), in: view)
      case .link: applyLink(in: view)
      }
    }

    private func applyLink(in view: NSTextView) {
      let selection = view.selectedRange()
      let original = model.markdown
      let existing = model.isExistingLink(for: selection)
      let existingDestination = model.linkDestination(for: selection)
      guard existing || selection.length > 0 else {
        parent.onUnsupportedEdit?()
        return
      }
      let editable = !existing || existingDestination != nil
      let alert = NSAlert()
      alert.messageText = "Link destination"
      alert.informativeText = editable
        ? "Enter the web address for the selected text."
        : "This link has a title and cannot be edited here. You can remove it safely."
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
      field.stringValue = existingDestination ?? ""
      field.placeholderString = "https://example.com"
      field.isEditable = editable
      field.setAccessibilityLabel("Link destination")
      alert.accessoryView = field
      let applyButton = alert.addButton(withTitle: "Apply Link")
      applyButton.isEnabled = editable
      if existing { alert.addButton(withTitle: "Remove Link") }
      alert.addButton(withTitle: "Cancel")
      let complete: (NSApplication.ModalResponse) -> Void = { [weak self, weak view] response in
        guard let self, let view else { return }
        guard self.model.markdown == original else {
          self.parent.onUnsupportedEdit?()
          return
        }
        if response == .alertFirstButtonReturn {
          self.apply(self.model.applyingLink(to: selection, destination: field.stringValue), in: view)
        } else if existing, response == .alertSecondButtonReturn {
          self.apply(self.model.removingLink(to: selection), in: view)
        }
      }
      if let window = view.window {
        alert.beginSheetModal(for: window, completionHandler: complete)
      } else {
        complete(alert.runModal())
      }
    }

    private func apply(_ next: FormattedMarkdownEditModel?, in view: NSTextView) {
      guard let next else {
        parent.onUnsupportedEdit?()
        return
      }
      let previous = model
      model = next
      view.undoManager?.registerUndo(withTarget: self) { target in target.restore(previous, rendering: true) }
      render(view, keeping: view.selectedRange())
      parent.markdown = next.markdown
    }

    /// Undo and redo. A native edit's snapshot needs no render: AppKit restores the text itself.
    private func restore(_ snapshot: FormattedMarkdownEditModel, rendering: Bool = false) {
      let current = model
      model = snapshot
      textView?.undoManager?.registerUndo(withTarget: self) { target in target.restore(current, rendering: rendering) }
      if rendering, let textView { render(textView, keeping: textView.selectedRange()) }
      parent.markdown = snapshot.markdown
    }

    private var readThrough: (offset: Int, markdown: String)?

    /// The model's rendering, with the text already read greyed as the presenter greys it
    /// (0.38 of the text's opacity), on every render and after every edit alike.
    private func styled() -> NSAttributedString {
      let rendered = model.rendered(fontName: fontName, fontSize: fontSize, typography: typography)
      guard let readThrough,
        let end = model.visibleIndex(forSourceOffset: Self.mappedOffset(readThrough.offset, from: readThrough.markdown, to: model.markdown)),
        end > 0
      else { return rendered }
      let greyed = NSMutableAttributedString(attributedString: rendered)
      let range = NSRange(location: 0, length: min(end, greyed.length))
      greyed.enumerateAttribute(.foregroundColor, in: range) { value, part, _ in
        let colour = (value as? NSColor) ?? typography.textColor
        greyed.addAttribute(.foregroundColor, value: colour.withAlphaComponent(colour.alphaComponent * 0.5), range: part)
      }
      return greyed
    }

    private func render(_ view: NSTextView, keeping selection: NSRange) {
      updating = true
      view.textStorage?.setAttributedString(styled())
      let location = min(selection.location, view.string.utf16.count)
      view.setSelectedRange(NSRange(location: location, length: min(selection.length, view.string.utf16.count - location)))
      updating = false
    }

    /// Same guide arithmetic as the presenter's own text view, so the passage the
    /// reader was on does not move when editing starts.
    func scrollToAnchor(
      _ view: NSTextView, sourceOffset: Int, guideFraction: Double, verticalMirror: Bool = false
    ) {
      guard let index = model.visibleIndex(forSourceOffset: sourceOffset),
        let manager = view.layoutManager, let container = view.textContainer,
        let scroll = view.enclosingScrollView
      else { return }
      manager.ensureLayout(for: container)
      let glyph = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
      let clip = scroll.contentView
      let visual = ScriptTextView.visualGuideY(height: clip.bounds.height, fraction: guideFraction)
      let guideY = verticalMirror ? clip.bounds.height - visual : visual
      clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x,
        y: max(0, rect.midY + view.textContainerInset.height - guideY)))
      scroll.reflectScrolledClipView(clip)
      view.setSelectedRange(NSRange(location: index, length: 0))
    }

    private func applyEmptyTypingAttributes(to view: NSTextView) {
      guard view.string.isEmpty else { return }
      view.typingAttributes = [.font: FormattedMarkdownEditModel.font(name: fontName, size: fontSize), .foregroundColor: typography.textColor]
    }

    private func reconcileAttributes(in view: NSTextView, rendered: NSAttributedString) {
      guard let storage = view.textStorage, storage.length > 0 else { return }
      guard storage.string == rendered.string, !storage.isEqual(to: rendered) else { return }
      updating = true
      storage.beginEditing()
      rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, range, _ in
        guard !storage.attributedSubstring(from: range).isEqual(to: rendered.attributedSubstring(from: range)) else { return }
        storage.setAttributes(attributes, range: range)
      }
      storage.endEditing()
      updating = false
    }

    private static func visibleEdit(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
      let before = Array(old)
      let after = Array(new)
      guard before != after else { return nil }
      var prefix = 0
      while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
      var oldEnd = before.count
      var newEnd = after.count
      while oldEnd > prefix, newEnd > prefix,
        before[oldEnd - 1] == after[newEnd - 1]
      { oldEnd -= 1; newEnd -= 1 }
      let location = String(before[..<prefix]).utf16.count
      let oldLength = String(before[prefix..<oldEnd]).utf16.count
      return (NSRange(location: location, length: oldLength), String(after[prefix..<newEnd]))
    }
  }
}
