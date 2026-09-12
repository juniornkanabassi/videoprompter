import AppKit
import SwiftUI
import PrompterCore

/// A formatted editor which changes only the visible source characters the user selected.
struct FormattedMarkdownEditor: NSViewRepresentable {
  @Binding var markdown: String
  var fontName: String
  var fontSize: Double
  var onUnsupportedEdit: (() -> Void)? = nil

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    let layout = NSLayoutManager()
    let storage = NSTextStorage()
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    let view = NSTextView(frame: NSRect.zero, textContainer: container)
    view.minSize = NSSize.zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = NSView.AutoresizingMask.width
    view.isRichText = true
    view.allowsUndo = true
    view.drawsBackground = false
    view.textContainerInset = NSSize(width: 0, height: 8)
    view.delegate = context.coordinator
    scroll.documentView = view
    context.coordinator.configure(view, markdown: markdown, fontName: fontName, fontSize: fontSize)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView else { return }
    context.coordinator.parent = self
    context.coordinator.configure(view, markdown: markdown, fontName: fontName, fontSize: fontSize)
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: FormattedMarkdownEditor
    private var model = FormattedMarkdownEditModel(markdown: "")
    private var updating = false
    private var fontName = ""
    private var fontSize = 0.0
    private weak var textView: NSTextView?
    private let editorUndoManager = UndoManager()

    init(_ parent: FormattedMarkdownEditor) { self.parent = parent }

    func configure(_ view: NSTextView, markdown: String, fontName: String, fontSize: Double) {
      textView = view
      let changedFont = self.fontName != fontName || self.fontSize != fontSize
      self.fontName = fontName
      self.fontSize = fontSize
      guard model.markdown != markdown || changedFont else { return }
      // A binding echo after a native edit has the same source model. Re-rendering it
      // would reset AppKit's selection and undo grouping.
      if model.markdown == markdown {
        if changedFont {
          render(view, keeping: view.selectedRange())
          applyEmptyTypingAttributes(to: view)
        }
        return
      }
      editorUndoManager.removeAllActions()
      model = FormattedMarkdownEditModel(markdown: markdown)
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
      let rendered = model.rendered(fontName: fontName, fontSize: fontSize)
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

    private func restore(_ snapshot: FormattedMarkdownEditModel) {
      let current = model
      model = snapshot
      textView?.undoManager?.registerUndo(withTarget: self) { target in target.restore(current) }
      parent.markdown = snapshot.markdown
    }

    private func render(_ view: NSTextView, keeping selection: NSRange) {
      updating = true
      view.textStorage?.setAttributedString(model.rendered(fontName: fontName, fontSize: fontSize))
      let location = min(selection.location, view.string.utf16.count)
      view.setSelectedRange(NSRange(location: location, length: min(selection.length, view.string.utf16.count - location)))
      updating = false
    }

    private func applyEmptyTypingAttributes(to view: NSTextView) {
      guard view.string.isEmpty else { return }
      view.typingAttributes = [.font: FormattedMarkdownEditModel.font(name: fontName, size: fontSize), .foregroundColor: NSColor.labelColor]
    }

    private func reconcileAttributes(in view: NSTextView) {
      guard let storage = view.textStorage, storage.length > 0 else { return }
      let rendered = model.rendered(fontName: fontName, fontSize: fontSize)
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

  init(markdown: String) {
    self.markdown = markdown
    let document = PrompterDocument(markdown: markdown)
    let output = NSMutableAttributedString()
    var offsets: [Int?] = []
    var headings: [NSRange] = []
    let source = markdown as NSString
    var cursor = 0

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
          let fence = raw.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            || raw.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
          if !fence {
            let part = NSMutableAttributedString(string: raw)
            part.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: NSRange(location: 0, length: part.length))
            output.append(part)
            offsets += (0..<(raw as NSString).length).map { Optional(lineOffset + $0) }
          }
          lineOffset += (raw as NSString).length
          if index < lines.count - 1 {
            let nextIsFence = lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("```")
              || lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
            if !fence && !nextIsFence { output.append(NSAttributedString(string: "\n")); offsets.append(lineOffset) }
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
          output.append(NSAttributedString(string: marker))
          offsets += Array(repeating: nil, count: (marker as NSString).length)
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

  func rendered(fontName: String = "System Serif", fontSize: Double = 14) -> NSAttributedString {
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
    output.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
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
    guard let literal = Self.literalMarkdown(replacement, inCode: inCode) else { return nil }
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

  private static func listMarker(in line: String) -> String? {
    guard let range = line.range(of: #"^\s*(?:[-+*]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
    return String(line[range])
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
