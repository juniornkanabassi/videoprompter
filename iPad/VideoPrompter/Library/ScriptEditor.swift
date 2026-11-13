import Foundation

/// Source-mapped editing: untouched Markdown stays byte-for-byte intact. All offsets are UTF-16.
struct PadMarkdownEdit {
  let markdown: String
  private(set) var text = ""
  private(set) var styles: [(range: NSRange, bold: Bool, italic: Bool, heading: Bool)] = []
  private var offsets: [Int] = []
  private var boundaries: Set<Int> = [0]

  init(_ markdown: String) {
    self.markdown = markdown
    let source = markdown as NSString
    var base = 0
    var fenced = false
    for line in markdown.components(separatedBy: "\n") {
      let raw = line as NSString
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
      // Code and unfamiliar block syntax stay literal rather than being rewritten.
      let literal = fenced || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix(">")
      let marker = literal ? nil : line.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression)
      let listMarker = literal ? nil : line.range(of: #"^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+"#, options: .regularExpression)
      let listPrefix = listMarker.map { String(line[$0]) } ?? ""
      let skip = marker.map { NSRange($0, in: line).length } ?? listPrefix.utf16.count
      let body = raw.substring(from: skip)
      let rich = literal ? AttributedString(body) :
        ((try? AttributedString(markdown: body, options: .init(
          interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true))) ?? AttributedString(body))
      var rendered = String(rich.characters)
      // The parser strips edge whitespace; the editor must not.
      let leading = body.prefix { $0 == " " || $0 == "\t" }
      let trailing = body.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
      let prefix = rendered.hasPrefix(String(leading)) ? "" : String(leading)
      let suffix = rendered.hasSuffix(String(trailing)) ? "" : String(trailing)
      rendered = listPrefix + prefix + rendered + suffix
      let start = (text as NSString).length
      var mapped = Array(repeating: -1, count: (rendered as NSString).length)
      for run in rich.runs {
        let range = NSRange(run.range, in: rich)
        let shifted = NSRange(location: range.location + prefix.utf16.count + listPrefix.utf16.count, length: range.length)
        let intent = run.inlinePresentationIntent ?? []
        styles.append((NSRange(location: start + shifted.location, length: shifted.length),
          intent.contains(.stronglyEmphasized), intent.contains(.emphasized), marker != nil))
        if let position = run.markdownSourcePosition, let sourceRange = NSRange(position, in: body) {
          let value = String(rich[run.range].characters)
          let found = (body as NSString).range(of: value, options: [], range: sourceRange)
          if found.location != NSNotFound, found.length == shifted.length {
            for i in 0..<found.length { mapped[shifted.location + i] = base + skip + found.location + i }
          }
        }
      }
      var cursor = 0
      let visible = rendered as NSString
      for i in mapped.indices {
        if mapped[i] >= 0 { cursor = mapped[i] - base + 1; continue }
        while cursor < raw.length, raw.character(at: cursor) != visible.character(at: i) { cursor += 1 }
        if cursor < raw.length { mapped[i] = base + cursor; cursor += 1 }
      }
      text += rendered
      offsets += mapped
      base += raw.length
      if base < source.length { text += "\n"; offsets.append(base); base += 1 }
    }
    var offset = 0
    for character in text { offset += String(character).utf16.count; boundaries.insert(offset) }
  }

  func visibleIndex(sourceOffset: Int) -> Int {
    offsets.firstIndex { $0 >= sourceOffset } ?? offsets.count
  }

  func replacing(_ range: NSRange, with replacement: String) -> PadMarkdownEdit? {
    guard valid(range) else { return nil }
    let expected = (text as NSString).replacingCharacters(in: range, with: replacement)
    if range.length == 0 {
      let candidates = range.location == offsets.count ? [markdown.utf16.count] :
        (range.location > 0 ? [offsets[range.location - 1] + 1, offsets[range.location]] : [offsets[range.location]])
      for offset in candidates where offset >= 0 {
        let next = PadMarkdownEdit((markdown as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: Self.literal(replacement)))
        if next.text == expected { return next }
      }
      return nil
    }
    let selected = Array(offsets[range.location..<NSMaxRange(range)])
    guard selected.allSatisfy({ $0 >= 0 }) else { return nil }
    var runs: [NSRange] = []
    for offset in selected {
      if let last = runs.last, NSMaxRange(last) == offset { runs[runs.count - 1].length += 1 }
      else { runs.append(NSRange(location: offset, length: 1)) }
    }
    let source = NSMutableString(string: markdown)
    for run in runs.dropFirst().reversed() { source.replaceCharacters(in: run, with: "") }
    source.replaceCharacters(in: runs[0], with: Self.literal(replacement))
    let next = PadMarkdownEdit(source as String)
    if next.text == expected { return next }
    if replacement.isEmpty {
      let cleaned = NSMutableString(string: markdown)
      var nextStart = cleaned.length
      for run in runs.reversed() {
        var removal = run
        for delimiter in ["***", "**", "*", "__", "_", "`"] {
          let count = delimiter.utf16.count
          if run.location >= count, NSMaxRange(run) + count <= (markdown as NSString).length,
            (markdown as NSString).substring(with: NSRange(location: run.location - count, length: count)) == delimiter,
            (markdown as NSString).substring(with: NSRange(location: NSMaxRange(run), length: count)) == delimiter {
            removal = NSRange(location: run.location - count, length: run.length + 2 * count)
            break
          }
        }
        if NSMaxRange(removal) > nextStart { removal = run }
        cleaned.replaceCharacters(in: removal, with: "")
        nextStart = removal.location
      }
      let candidate = PadMarkdownEdit(cleaned as String)
      if candidate.text == expected { return candidate }
    }
    // Replacing the complete visible document also removes now-empty formatting markers.
    if range.location == 0, range.length == offsets.count { return PadMarkdownEdit(Self.literal(replacement)) }
    return nil
  }

  enum Format { case bold, italic, heading }
  func formatting(_ format: Format, range: NSRange) -> PadMarkdownEdit? {
    guard valid(range) else { return nil }
    let source = markdown as NSString
    let start = range.location < offsets.count ? offsets[range.location] : source.length
    guard start >= 0 else { return nil }
    var result: String
    if format == .heading {
      let line = source.lineRange(for: NSRange(location: start, length: 0))
      let raw = source.substring(with: line)
      if let marker = raw.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression) {
        result = source.replacingCharacters(in: NSRange(location: line.location, length: NSRange(marker, in: raw).length), with: "")
      } else { result = source.replacingCharacters(in: NSRange(location: line.location, length: 0), with: "# ") }
    } else {
      guard range.length > 0, let last = offsets[range.location..<NSMaxRange(range)].last,
        last - start + 1 == range.length else { return nil }
      let delimiter = format == .bold ? "**" : "*"
      let count = delimiter.utf16.count
      let end = start + range.length
      let styled = styles.filter { NSIntersectionRange($0.range, range).length > 0 }
        .allSatisfy { format == .bold ? $0.bold : $0.italic }
      if styled, start >= count, end + count <= source.length,
        source.substring(with: NSRange(location: start - count, length: count)) == delimiter,
        source.substring(with: NSRange(location: end, length: count)) == delimiter {
        result = source.replacingCharacters(in: NSRange(location: start - count, length: range.length + 2 * count), with: source.substring(with: NSRange(location: start, length: range.length)))
      } else {
        result = source.replacingCharacters(in: NSRange(location: start, length: range.length), with: delimiter + source.substring(with: NSRange(location: start, length: range.length)) + delimiter)
      }
    }
    let next = PadMarkdownEdit(result)
    return next.text == text ? next : nil
  }

  private func valid(_ range: NSRange) -> Bool {
    range.location >= 0 && range.length >= 0 && range.location <= offsets.count
      && range.length <= offsets.count - range.location
      && boundaries.contains(range.location) && boundaries.contains(NSMaxRange(range))
  }
  private static func literal(_ text: String) -> String {
    var result = text
    for character in ["\\", "*", "_", "`", "[", "]", "&", "<", "#", ">"] {
      result = result.replacingOccurrences(of: character, with: "\\" + character)
    }
    return result
  }
}

/// One independent undo stack per editor, shared by typing and toolbar commands.
@MainActor
final class PadEditorDraft {
  let original: String
  private(set) var model: PadMarkdownEdit
  let history = UndoManager()
  var onChange: ((PadMarkdownEdit, NSRange) -> Void)?
  private var editingEnded: (() -> Void)?
  var isEditing: Bool { editingEnded != nil }
  func beginEditing(onBegin: () -> Void, onEnd: @escaping () -> Void) {
    guard editingEnded == nil else { return }
    editingEnded = onEnd; onBegin()
  }
  func endEditing() { let end = editingEnded; editingEnded = nil; end?() }
  @discardableResult func save(_ write: (String) -> Bool) -> Bool {
    guard write(model.markdown) else { return false }
    endEditing(); return true
  }
  init(_ markdown: String) { original = markdown; model = PadMarkdownEdit(markdown) }
  func reset(_ markdown: String) { model = PadMarkdownEdit(markdown); history.removeAllActions() }
  func apply(_ next: PadMarkdownEdit, selection: NSRange, previousSelection: NSRange) {
    let previous = model
    history.registerUndo(withTarget: self) { target in
      target.apply(previous, selection: previousSelection, previousSelection: selection)
    }
    model = next
    onChange?(next, selection)
  }
  func cancel() { reset(original); onChange?(model, NSRange(location: 0, length: 0)); endEditing() }
}

#if canImport(UIKit)
import PrompterCore
import SwiftUI
import UIKit

/// Compatibility for existing sheet callers. New inline hosts use ScriptEditorView directly.
struct ScriptEditor: View {
  @EnvironmentObject private var store: PadStore
  @Environment(\.dismiss) private var dismiss
  let script: FolderScript
  @State private var record: ScriptRecord?
  var body: some View {
    NavigationStack {
      if let record {
        ScriptEditorView(record: record, mode: store.presentingID == script.id ? .onTheFly : .library) { dismiss() }
          .navigationTitle(script.title).navigationBarTitleDisplayMode(.inline)
      } else { ProgressView().onAppear { record = store.record(for: script) } }
    }
  }
}

enum ScriptEditorMode { case library, onTheFly }

/// Hosts supply PadStore as an environment object and give a new record its own view identity.
struct ScriptEditorView: View {
  @EnvironmentObject private var store: PadStore
  let record: ScriptRecord
  let mode: ScriptEditorMode
  var onDone: () -> Void
  @State private var markdown: String
  @State private var command: PadEditorCommand?
  @State private var error: String?
  @State private var draft: PadEditorDraft

  init(record: ScriptRecord, mode: ScriptEditorMode, onDone: @escaping () -> Void) {
    self.record = record; self.mode = mode; self.onDone = onDone
    _markdown = State(initialValue: record.markdown)
    _draft = State(initialValue: PadEditorDraft(record.markdown))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        if mode == .onTheFly { Text("Editing").font(.headline) }
        Button { command = PadEditorCommand(action: .undo) } label: {
          Image(systemName: "arrow.uturn.backward").frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel("Undo")
        Button { command = PadEditorCommand(action: .redo) } label: {
          Image(systemName: "arrow.uturn.forward").frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel("Redo")
        ForEach(Array([("Bold", "bold"), ("Italic", "italic"), ("Heading", "textformat.size")].enumerated()), id: \.offset) { index, item in
          Button { command = PadEditorCommand(action: [.bold, .italic, .heading][index]) } label: {
            Image(systemName: item.1).frame(minWidth: 44, minHeight: 44)
          }.accessibilityLabel(item.0)
        }
        Spacer()
        Text((mode == .onTheFly ? "Reading paused · " : "") + (markdown == record.markdown ? "Saved" : "Not saved yet"))
          .font(.footnote).foregroundStyle(LibraryTheme.muted).lineLimit(1)
        Button("Cancel", action: cancel).frame(minHeight: 44)
        Button("Save", action: save).buttonStyle(.borderedProminent).foregroundStyle(LibraryTheme.ink).frame(minHeight: 44)
          .keyboardShortcut("s", modifiers: .command)
      }.padding(.horizontal, 12).background(LibraryTheme.card)
      if let error { Text(error).font(.callout).foregroundStyle(LibraryTheme.warn).padding(8).accessibilityAddTraits(.updatesFrequently) }
      FormattedScriptTextView(markdown: $markdown, draft: draft, command: command,
        sourceOffset: mode == .onTheFly ? readingOffset : nil,
        fontName: store.settings.fontName, fontSize: mode == .onTheFly ? store.settings.fontSize : 20,
        onSave: save, onCancel: cancel,
        onError: { error = $0 })
    }
    .background(mode == .onTheFly ? Color.black : LibraryTheme.background).tint(LibraryTheme.accent)
    .preferredColorScheme(.dark)
    .interactiveDismissDisabled(markdown != record.markdown)
    .onAppear {
      if mode == .onTheFly { draft.beginEditing(onBegin: store.beginEditing, onEnd: store.endEditing) }
    }
    .onDisappear { draft.endEditing() }
  }

  private var readingOffset: Int? {
    let tokens = store.session.document.spokenTokens
    let index = store.session.tokenIndex
    return tokens.indices.contains(index) ? tokens[index].sourceRange.location : nil
  }
  private func cancel() { draft.cancel(); markdown = record.markdown; onDone() }
  private func save() {
    // Commit any in-progress keyboard composition before reading the draft.
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    guard let script = store.folder.script(record.metadata.id) else { error = "This script is no longer in the folder."; return }
    guard draft.save({ $0 == record.markdown || store.save($0, to: script) }) else { error = store.errorMessage; return }
    onDone()
  }
}

struct PadEditorCommand: Equatable {
  enum Action { case bold, italic, heading, undo, redo }
  let id = UUID()
  let action: Action
}

private final class PadEditorTextView: UITextView {
  var format: ((PadMarkdownEdit.Format) -> Void)?
  var save: (() -> Void)?
  var cancel: (() -> Void)?
  var history = UndoManager()
  override var undoManager: UndoManager? { history }
  override var keyCommands: [UIKeyCommand]? {
    let commands = [UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(bold)),
     UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italic)),
     UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoEdit)),
     UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoEdit)),
     UIKeyCommand(input: "s", modifierFlags: .command, action: #selector(saveEdit)),
     UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelEdit))]
    for command in commands { command.wantsPriorityOverSystemBehavior = true }
    return commands + (super.keyCommands ?? [])
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let overlap = max(0, bounds.maxY - keyboardLayoutGuide.layoutFrame.minY)
    if abs(contentInset.bottom - overlap) > 1 {
      contentInset.bottom = overlap
      verticalScrollIndicatorInsets.bottom = overlap
      scrollRangeToVisible(selectedRange)
    }
  }
  @objc private func bold() { format?(.bold) }
  @objc private func italic() { format?(.italic) }
  @objc private func undoEdit() { history.undo() }
  @objc private func redoEdit() { history.redo() }
  @objc private func saveEdit() { unmarkText(); delegate?.textViewDidChange?(self); save?() }
  @objc private func cancelEdit() { cancel?() }
}

struct FormattedScriptTextView: UIViewRepresentable {
  @Binding var markdown: String
  let draft: PadEditorDraft
  var command: PadEditorCommand?
  var sourceOffset: Int?
  var fontName = "Lexend Deca"
  var fontSize = 20.0
  var onSave: () -> Void
  var onCancel: () -> Void
  var onError: (String?) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = PadEditorTextView()
    view.backgroundColor = .clear
    view.tintColor = UIColor(red: 245/255, green: 207/255, blue: 74/255, alpha: 1)
    view.accessibilityLabel = "Script editor"
    view.adjustsFontForContentSizeCategory = true
    view.keyboardDismissMode = .interactive
    view.keyboardLayoutGuide.followsUndockedKeyboard = true
    view.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 32, right: 20)
    view.delegate = context.coordinator
    view.history = context.coordinator.draft.history
    view.format = { [weak coordinator = context.coordinator, weak view] action in
      guard let view else { return }; coordinator?.format(action, view: view)
    }
    view.save = onSave; view.cancel = onCancel
    context.coordinator.render(view)
    if let sourceOffset { view.selectedRange = NSRange(location: context.coordinator.model.visibleIndex(sourceOffset: sourceOffset), length: 0) }
    DispatchQueue.main.async { view.becomeFirstResponder(); view.scrollRangeToVisible(view.selectedRange) }
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    (view as? PadEditorTextView)?.save = onSave
    (view as? PadEditorTextView)?.cancel = onCancel
    if markdown != coordinator.model.markdown, view.markedTextRange == nil {
      coordinator.model = PadMarkdownEdit(markdown); coordinator.render(view)
    }
    if let command, coordinator.lastCommand != command.id {
      coordinator.lastCommand = command.id
      // Toolbar commands update bindings after SwiftUI has finished this view update.
      DispatchQueue.main.async { [weak coordinator, weak view] in
        guard let coordinator, let view else { return }
        switch command.action {
        case .undo: coordinator.draft.history.undo()
        case .redo: coordinator.draft.history.redo()
        case .bold: coordinator.format(.bold, view: view)
        case .italic: coordinator.format(.italic, view: view)
        case .heading: coordinator.format(.heading, view: view)
        }
      }
    }
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: FormattedScriptTextView
    let draft: PadEditorDraft
    var model: PadMarkdownEdit {
      get { draft.model }
      set { draft.reset(newValue.markdown) }
    }
    var lastCommand: UUID?
    private var rendering = false
    init(_ parent: FormattedScriptTextView) { self.parent = parent; draft = parent.draft }

    func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      if view.markedTextRange != nil { return true }
      guard let next = model.replacing(range, with: text) else {
        parent.onError("This formatting cannot be edited here. The original Markdown has been kept.")
        return false
      }
      apply(next, selection: NSRange(location: range.location + text.utf16.count, length: 0), view: view)
      return false
    }
    func textViewDidChange(_ view: UITextView) {
      guard !rendering, view.markedTextRange == nil, view.text != model.text else { return }
      let old = Array(model.text), new = Array(view.text ?? "")
      var prefix = 0, suffix = 0
      while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
      while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
      let range = NSRange(location: String(old.prefix(prefix)).utf16.count,
        length: String(old[prefix..<(old.count - suffix)]).utf16.count)
      let replacement = String(new[prefix..<(new.count - suffix)])
      if let next = model.replacing(range, with: replacement) { apply(next, selection: view.selectedRange, view: view) }
      else { render(view); parent.onError("This edit could not preserve the Markdown. Your original text has been kept.") }
    }
    func textViewDidEndEditing(_ view: UITextView) { textViewDidChange(view) }
    func textViewDidChangeSelection(_ view: UITextView) {
      if !rendering {
        if view.markedTextRange == nil, view.text != model.text { textViewDidChange(view) }
        view.scrollRangeToVisible(view.selectedRange)
      }
    }
    func format(_ format: PadMarkdownEdit.Format, view: UITextView) {
      guard view.markedTextRange == nil, let next = model.formatting(format, range: view.selectedRange) else {
        parent.onError("Select text to format. Complex Markdown is kept unchanged."); return
      }
      apply(next, selection: view.selectedRange, view: view)
    }
    private func apply(_ next: PadMarkdownEdit, selection: NSRange, view: UITextView) {
      draft.onChange = { [weak self, weak view] next, selection in
        guard let self, let view else { return }
        self.parent.markdown = next.markdown; self.parent.onError(nil)
        self.render(view); view.selectedRange = selection; view.scrollRangeToVisible(selection)
      }
      draft.apply(next, selection: selection, previousSelection: view.selectedRange)
    }
    func render(_ view: UITextView) {
      rendering = true
      defer { rendering = false }
      let selection = view.selectedRange
      let offset = view.contentOffset
      let base = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: parent.fontName, size: parent.fontSize) ?? .systemFont(ofSize: parent.fontSize))
      let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
      let rich = NSMutableAttributedString(string: model.text, attributes: [.font: base, .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
      for style in model.styles {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.bold || style.heading { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
          ?? UIFont.systemFont(ofSize: base.pointSize).fontDescriptor.withSymbolicTraits(traits)
          ?? base.fontDescriptor
        let font = UIFont(descriptor: descriptor, size: base.pointSize * (style.heading ? 1.25 : 1))
        rich.addAttribute(.font, value: font, range: style.range)
      }
      view.attributedText = rich
      view.typingAttributes = [.font: base, .foregroundColor: UIColor.label]
      view.selectedRange = NSRange(location: min(selection.location, rich.length), length: min(selection.length, max(0, rich.length - selection.location)))
      view.setContentOffset(offset, animated: false)
    }
  }
}
#endif
