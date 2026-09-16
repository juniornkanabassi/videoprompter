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

  @objc func showFormatMenu(_ sender: NSButton) {
    formatMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
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

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSView {
    let root = NSView()
    let header = NSView()
    let scroll = NSScrollView()
    root.addSubview(header)
    root.addSubview(scroll)
    header.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: root.topAnchor),
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: 32),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
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
    let formatButton = NSButton(title: "Format", target: view, action: #selector(FormattingTextView.showFormatMenu(_:)))
    formatButton.bezelStyle = .rounded
    formatButton.setAccessibilityLabel("Format selected text")
    formatButton.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(formatButton)
    NSLayoutConstraint.activate([
      formatButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      formatButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8)
    ])
    view.textContainerInset = NSSize(width: typography.horizontalInset, height: 8)
    context.coordinator.configure(view, markdown: markdown, fontName: fontName, fontSize: fontSize, typography: typography)
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
    context.coordinator.configure(view, markdown: markdown, fontName: fontName, fontSize: fontSize, typography: typography)
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
      typography: EditorTypography = EditorTypography())
    {
      textView = view
      let changedFont = self.fontName != fontName || self.fontSize != fontSize
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
      if model.markdown != markdown {
        editorUndoManager.removeAllActions()
        model = FormattedMarkdownEditModel(markdown: markdown)
      }
      render(view, keeping: view.selectedRange())
      applyEmptyTypingAttributes(to: view)
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
      let rendered = model.rendered(fontName: fontName, fontSize: fontSize, typography: typography)
      if view.string != rendered.string {
        guard let edit = Self.visibleEdit(from: rendered.string,
          to: view.string), let next = model.replacing(edit.range, with: edit.replacement)
        else {
          render(view, keeping: view.selectedRange())
          parent.onUnsupportedEdit?()
          return
        }
        model = next
      }
      reconcileAttributes(in: view)
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

    private func render(_ view: NSTextView, keeping selection: NSRange) {
      updating = true
      view.textStorage?.setAttributedString(model.rendered(fontName: fontName, fontSize: fontSize, typography: typography))
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

    private func reconcileAttributes(in view: NSTextView) {
      guard let storage = view.textStorage, storage.length > 0 else { return }
      let rendered = model.rendered(fontName: fontName, fontSize: fontSize, typography: typography)
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

/// Kept internal-but-testable: rendering and source patching have no SwiftUI dependency.
struct FormattedMarkdownEditModel {
  let markdown: String
  private let renderedSource: NSAttributedString
  private let sourceOffsets: [Int?]
  private let headingRanges: [NSRange]
  private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(([^)\n]*)\)"#)

  init(markdown: String) {
    self.markdown = markdown
    let document = PrompterDocument(markdown: markdown)
    let output = NSMutableAttributedString()
    var offsets: [Int?] = []
    var headings: [NSRange] = []
    let source = markdown as NSString
    var cursor = 0

    func isFence(_ line: some StringProtocol) -> Bool {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }
    func appendLiteral(_ range: NSRange) {
      guard range.length > 0 else { return }
      output.append(NSAttributedString(string: source.substring(with: range)))
      offsets += (range.location..<(range.location + range.length)).map(Optional.some)
    }

    for block in document.blocks {
      appendLiteral(NSRange(location: cursor, length: block.sourceRange.location - cursor))
      var lineOffset = block.sourceRange.location
      let lines = block.rawMarkdown.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() {
        let raw = String(line)
        if block.kind == .code {
          let fence = isFence(raw)
          if !fence {
            let part = NSMutableAttributedString(string: raw)
            part.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: NSRange(location: 0, length: part.length))
            output.append(part)
            offsets += (0..<(raw as NSString).length).map { Optional(lineOffset + $0) }
          }
          lineOffset += (raw as NSString).length
          if index < lines.count - 1 {
            if !fence && !isFence(lines[index + 1]) { output.append(NSAttributedString(string: "\n")); offsets.append(lineOffset) }
            lineOffset += 1
          }
          continue
        }
        let rich = (try? AttributedString(markdown: raw,
          options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true)))
          ?? AttributedString(raw)
        let part = NSMutableAttributedString(attributedString: NSAttributedString(rich))
        // Foundation Markdown omits trailing spaces from a paragraph's rendered text.
        // Keep any omitted literal spaces visible and source-mapped while the user is typing.
        let rawTrailingSpaces = raw.reversed().prefix { $0 == " " || $0 == "\t" }.count
        let renderedTrailingSpaces = part.string.reversed().prefix { $0 == " " || $0 == "\t" }.count
        if rawTrailingSpaces > renderedTrailingSpaces {
          part.append(NSAttributedString(string: String(raw.suffix(rawTrailingSpaces - renderedTrailingSpaces))))
        }
        if block.kind == .listItem, let marker = Self.listMarker(in: raw) {
          output.append(NSAttributedString(string: marker.text))
          offsets += (marker.sourceRange.location..<NSMaxRange(marker.sourceRange)).map { lineOffset + $0 }
        }
        for run in rich.runs {
          let intent = run.inlinePresentationIntent ?? []
          var traits: NSFontTraitMask = []
          if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
          if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
          guard !traits.isEmpty || intent.contains(.code) else { continue }
          let base = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : NSFont.systemFont(ofSize: 14)
          let font = NSFontManager.shared.convert(base, toHaveTrait: traits)
          part.addAttribute(.font, value: font, range: NSRange(run.range, in: rich))
        }
        if rich.runs.contains(where: { run in
          run.presentationIntent?.components.contains(where: { if case .header = $0.kind { return true }; return false }) == true
        }) {
          headings.append(NSRange(location: output.length, length: part.length))
        }
        output.append(part)
        offsets += Self.sourceOffsets(for: part, source: raw, base: lineOffset)
        lineOffset += (raw as NSString).length
        if index < lines.count - 1 {
          output.append(NSAttributedString(string: "\n"))
          offsets.append(lineOffset)
          lineOffset += 1
        }
      }
      cursor = block.sourceRange.location + block.sourceRange.length
    }
    appendLiteral(NSRange(location: cursor, length: source.length - cursor))
    renderedSource = output
    sourceOffsets = offsets
    headingRanges = headings
  }

  func applyingStyle(_ delimiter: String, to visibleRange: NSRange) -> FormattedMarkdownEditModel? {
    guard let visibleRange = trimmedStyleRange(visibleRange), let range = sourceRange(for: visibleRange) else { return nil }
    let source = markdown as NSString
    let delimiterLength = (delimiter as NSString).length
    if hasStyle(delimiter, in: visibleRange),
      range.location >= delimiterLength,
      source.substring(with: NSRange(location: range.location - delimiterLength, length: delimiterLength)) == delimiter,
      NSMaxRange(range) + delimiterLength <= source.length,
      source.substring(with: NSRange(location: NSMaxRange(range), length: delimiterLength)) == delimiter
    {
      return replacingSource(
        NSRange(location: range.location - delimiterLength, length: range.length + delimiterLength * 2),
        with: source.substring(with: range))
    }
    return replacingSource(range, with: delimiter + source.substring(with: range) + delimiter)
  }

  private func trimmedStyleRange(_ range: NSRange) -> NSRange? {
    let text = renderedSource.string as NSString
    guard range.location >= 0, range.length >= 0, range.location <= text.length,
      range.length <= text.length - range.location else { return nil }
    var start = range.location
    var end = NSMaxRange(range)
    while start < end, let scalar = UnicodeScalar(text.character(at: start)),
      CharacterSet.whitespacesAndNewlines.contains(scalar)
    { start += 1 }
    while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)),
      CharacterSet.whitespacesAndNewlines.contains(scalar)
    { end -= 1 }
    return start < end ? NSRange(location: start, length: end - start) : nil
  }

  private func hasStyle(_ delimiter: String, in visibleRange: NSRange) -> Bool {
    let trait: NSFontTraitMask = delimiter == "**" ? .boldFontMask : .italicFontMask
    var hasStyle = true
    renderedSource.enumerateAttribute(.font, in: visibleRange) { value, _, _ in
      hasStyle = hasStyle && ((value as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(trait) } ?? false)
    }
    return hasStyle
  }

  func applyingHeading(to visibleRange: NSRange) -> FormattedMarkdownEditModel? {
    guard let range = sourceRange(for: visibleRange) else { return nil }
    let source = markdown as NSString
    let line = source.lineRange(for: range)
    let raw = source.substring(with: line)
    if let marker = raw.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
      return replacingSource(NSRange(location: line.location + NSRange(marker, in: raw).location, length: NSRange(marker, in: raw).length), with: "")
    }
    return replacingSource(NSRange(location: line.location, length: 0), with: "# ")
  }

  func isExistingLink(for visibleRange: NSRange) -> Bool {
    guard let range = sourceRange(for: visibleRange) else { return false }
    return linkMatch(containing: range) != nil
  }

  func linkDestination(for visibleRange: NSRange) -> String? {
    guard let range = sourceRange(for: visibleRange), let match = linkMatch(containing: range) else { return nil }
    let destination = (markdown as NSString).substring(with: match.range(at: 2))
    return Self.isSimpleDestination(destination) ? destination : nil
  }

  func applyingLink(to visibleRange: NSRange, destination: String) -> FormattedMarkdownEditModel? {
    let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isSimpleDestination(destination), let selected = sourceRange(for: visibleRange) else { return nil }
    let source = markdown as NSString
    if let match = linkMatch(containing: selected) {
      guard Self.isSimpleDestination(source.substring(with: match.range(at: 2))) else { return nil }
      let label = source.substring(with: match.range(at: 1))
      return replacingSource(match.range, with: "[\(label)](\(destination))")
    }
    return replacingSource(selected, with: "[\(source.substring(with: selected))](\(destination))")
  }

  func removingLink(to visibleRange: NSRange) -> FormattedMarkdownEditModel? {
    guard let selected = sourceRange(for: visibleRange), let match = linkMatch(containing: selected) else { return nil }
    return replacingSource(match.range, with: (markdown as NSString).substring(with: match.range(at: 1)))
  }

  private static func isSimpleDestination(_ value: String) -> Bool {
    !value.contains(where: { $0.isWhitespace || $0.isNewline })
      && URL(string: value)?.scheme != nil
  }

  private func sourceRange(for visibleRange: NSRange) -> NSRange? {
    guard visibleRange.location >= 0, NSMaxRange(visibleRange) <= sourceOffsets.count else { return nil }
    if visibleRange.length == 0 {
      guard let offset = insertionOffsets(at: visibleRange.location).first else { return nil }
      return NSRange(location: offset, length: 0)
    }
    let selected = sourceOffsets[visibleRange.location..<NSMaxRange(visibleRange)]
    guard let first = selected.first ?? nil, selected.allSatisfy({ $0 != nil }),
      let last = selected.last ?? nil, last - first + 1 == selected.count
    else { return nil }
    return NSRange(location: first, length: selected.count)
  }

  private func replacingSource(_ range: NSRange, with replacement: String) -> FormattedMarkdownEditModel? {
    let source = NSMutableString(string: markdown)
    source.replaceCharacters(in: range, with: replacement)
    let next = FormattedMarkdownEditModel(markdown: source as String)
    return next.renderedSource.string == renderedSource.string ? next : nil
  }

  private func linkMatch(containing selection: NSRange) -> NSTextCheckingResult? {
    let source = markdown as NSString
    let full = NSRange(location: 0, length: source.length)
    return Self.linkRegex.matches(in: markdown, range: full).first { match in
      let label = match.range(at: 1)
      return selection.location >= label.location && NSMaxRange(selection) <= NSMaxRange(label)
    }
  }

  /// First visible character at or after a markdown offset, for placing a guide.
  func visibleIndex(forSourceOffset offset: Int) -> Int? {
    sourceOffsets.firstIndex { $0.map { $0 >= offset } ?? false }
  }

  func rendered(fontName: String = "System Serif", fontSize: Double = 14,
    typography: EditorTypography = EditorTypography()) -> NSAttributedString
  {
    let output = NSMutableAttributedString(attributedString: renderedSource)
    let full = NSRange(location: 0, length: output.length)
    guard full.length > 0 else { return output }
    let base = Self.font(name: fontName, size: fontSize)
    output.enumerateAttribute(.font, in: full) { existing, range, _ in
      let prior = existing as? NSFont
      let traits = prior.map { NSFontManager.shared.traits(of: $0) } ?? []
      let family = prior?.fontName.lowercased().contains("mono") == true
        ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : base
      let styled = NSFontManager.shared.convert(family, toHaveTrait: traits)
      output.addAttribute(.font, value: styled, range: range)
    }
    // PresentationIntent is read as a typed Foundation Markdown attribute above.
    // Heading runs have no fixed font size in Foundation, so apply this view's scale here.
    for range in headingRanges where range.length > 0 {
      let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
      output.addAttribute(.font, value: NSFontManager.shared.convert(bold, toSize: fontSize * 1.35), range: range)
    }
    output.addAttribute(.foregroundColor, value: typography.textColor, range: full)
    if typography.lineSpacing > 0 || typography.paragraphSpacing > 0 || typography.alignment != .left {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = typography.lineSpacing
      paragraph.paragraphSpacing = typography.paragraphSpacing
      paragraph.alignment = typography.alignment
      output.addAttribute(.paragraphStyle, value: paragraph, range: full)
    }
    return output
  }

  func replacing(_ range: NSRange, with replacement: String) -> FormattedMarkdownEditModel? {
    guard range.location >= 0, NSMaxRange(range) <= sourceOffsets.count else { return nil }
    if range.length == 0 {
      return insertionOffsets(at: range.location).lazy.compactMap {
        replacing([NSRange(location: $0, length: 0)], visibleRange: range, with: replacement)
      }.first
    }
    let selected = sourceOffsets[range.location..<NSMaxRange(range)]
    guard selected.allSatisfy({ $0 != nil }) else { return nil }
    var runs: [NSRange] = []
    for offset in selected.compactMap({ $0 }) {
      if let last = runs.last, offset == NSMaxRange(last) {
        runs[runs.count - 1].length += 1
      } else if runs.last?.location != offset {
        runs.append(NSRange(location: offset, length: 1))
      }
    }
    guard !runs.isEmpty else { return nil }
    return replacing(runs, visibleRange: range, with: replacement)
  }

  private func replacing(_ runs: [NSRange], visibleRange: NSRange, with replacement: String) -> FormattedMarkdownEditModel? {
    let inCode = visibleRange.location < renderedSource.length
      && ((renderedSource.attribute(.font, at: visibleRange.location, effectiveRange: nil) as? NSFont)?.fontName.lowercased().contains("mono") == true)
    let literal: String
    if isListMarkerEdit(runs, replacement: replacement) {
      literal = replacement
    } else if let escaped = Self.literalMarkdown(replacement, inCode: inCode) {
      literal = escaped
    } else {
      return nil
    }
    let source = NSMutableString(string: markdown)
    for run in runs.dropFirst().reversed() { source.replaceCharacters(in: run, with: "") }
    source.replaceCharacters(in: runs[0], with: literal)
    let next = FormattedMarkdownEditModel(markdown: source as String)
    let expected = NSMutableString(string: renderedSource.string)
    expected.replaceCharacters(in: visibleRange, with: replacement)
    // Source positions may be absent from literal runs. Accept a fallback alignment
    // only when re-rendering proves it changed exactly the requested visible text.
    return next.renderedSource.string == expected as String ? next : nil
  }

  private func isListMarkerEdit(_ runs: [NSRange], replacement: String) -> Bool {
    guard runs.count == 1 else { return false }
    let source = markdown as NSString
    let lineRange = source.lineRange(for: runs[0])
    let line = source.substring(with: lineRange)
    guard let marker = Self.listMarker(in: line) else { return false }
    let local = NSRange(location: runs[0].location - lineRange.location, length: runs[0].length)
    guard local.location >= marker.sourceRange.location, NSMaxRange(local) <= NSMaxRange(marker.sourceRange) else {
      return false
    }
    let amended = NSMutableString(string: line)
    amended.replaceCharacters(in: local, with: replacement)
    return Self.listMarker(in: amended as String) != nil
  }

  private func insertionOffsets(at index: Int) -> [Int] {
    if index == sourceOffsets.count { return [(markdown as NSString).length] }
    guard let next = sourceOffsets[index] else { return [] }
    if index > 0, let previous = sourceOffsets[index - 1], previous + 1 <= next {
      return previous + 1 == next ? [next] : [previous + 1, next]
    }
    return [next]
  }

  private static func sourceOffsets(for rendered: NSAttributedString, source: String, base: Int) -> [Int?] {
    var result = Array<Int?>(repeating: nil, count: rendered.length)
    rendered.enumerateAttribute(.markdownSourcePosition, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
      guard let position = value as? AttributedString.MarkdownSourcePosition,
        let positionRange = NSRange(position, in: source)
      else { return }
      let visible = rendered.attributedSubstring(from: range).string as NSString
      let raw = source as NSString
      let found = raw.range(of: visible as String, options: [], range: positionRange)
      guard found.location != NSNotFound, found.length == range.length else { return }
      for index in 0..<range.length { result[range.location + index] = base + found.location + index }
    }
    // Foundation does not attach positions to every literal run. Align those runs
    // monotonically with their raw UTF-16 source, while source-position anchors keep
    // formatted content on the correct side of hidden delimiters.
    let visible = rendered.string as NSString
    let raw = source as NSString
    var cursor = 0
    for index in result.indices {
      if let offset = result[index] {
        cursor = max(cursor, offset - base + 1)
        continue
      }
      let unit = visible.character(at: index)
      while cursor < raw.length, raw.character(at: cursor) != unit { cursor += 1 }
      guard cursor < raw.length else { continue }
      result[index] = base + cursor
      cursor += 1
    }
    return result
  }

  private static func listMarker(in line: String) -> (text: String, sourceRange: NSRange)? {
    guard let range = line.range(of: #"^\s*(?:[-+*]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
    return (String(line[range]), NSRange(range, in: line))
  }

  private static func literalMarkdown(_ text: String, inCode: Bool) -> String? {
    if inCode { return text.contains("`") ? nil : text }
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "*", with: "\\*")
      .replacingOccurrences(of: "_", with: "\\_")
      .replacingOccurrences(of: "`", with: "\\`")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
      .replacingOccurrences(of: "&", with: "\\&")
      .replacingOccurrences(of: "<", with: "\\<")
    return escaped.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      guard let first = line.first else { return String(line) }
      if line.range(of: "^\\d+[.)]\\s", options: .regularExpression) != nil {
        var value = String(line)
        if let marker = value.firstIndex(where: { $0 == "." || $0 == ")" }) { value.insert("\\", at: marker) }
        return value
      }
      guard "#>+-".contains(first) else { return String(line) }
      return "\\" + line
    }.joined(separator: "\n")
  }

  static func font(name: String, size: Double) -> NSFont {
    switch name {
    case "System Serif":
      let descriptor = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body).withDesign(.serif)
      return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
    case "Monospaced": return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    case "System": return NSFont.systemFont(ofSize: size)
    default: return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }
  }
}
