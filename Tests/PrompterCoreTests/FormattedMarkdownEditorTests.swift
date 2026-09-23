import AppKit
import SwiftUI
import XCTest
@testable import JuniorPrompter
import PrompterCore

final class FormattedMarkdownEditorTests: XCTestCase {
  func testRenderKeepsFormattingAndExactBlankLines() {
    let model = FormattedMarkdownEditModel(markdown: "\n# Heading\n\n\n**bold** and *italic*\n")
    XCTAssertEqual(model.rendered().string, "\nHeading\n\n\nbold and italic\n")
    let range = NSRange(model.rendered().string.range(of: "bold")!, in: model.rendered().string)
    XCTAssertTrue((model.rendered().attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?
      .fontDescriptor.symbolicTraits.contains(.bold) == true)
  }

  func testCrossFormatSelectionPreservesDelimitersAndUntouchedMarkdown() {
    let model = FormattedMarkdownEditModel(markdown: "before **bold** and *italic* after")
    let range = NSRange(model.rendered().string.range(of: "old and it")!, in: model.rendered().string)
    XCTAssertEqual(model.replacing(range, with: "REPLACEMENT")?.markdown,
      "before **bREPLACEMENT***alic* after")
    XCTAssertEqual(model.replacing(range, with: "REPLACEMENT")?.rendered().string,
      "before bREPLACEMENTalic after")
  }

  func testParagraphJoinAndLiteralInput() {
    let model = FormattedMarkdownEditModel(markdown: "one\n\ntwo")
    XCTAssertEqual(model.replacing(NSRange(location: 3, length: 2), with: " ")?.markdown, "one two")
    XCTAssertEqual(model.replacing(NSRange(location: 0, length: 0), with: "*literal*")?.markdown,
      "\\*literal\\*one\n\ntwo")
  }

  func testLiteralEntitiesHtmlAndListMarkersStayVisible() {
    XCTAssertEqual(FormattedMarkdownEditModel(markdown: "start\\&copy; \\<tag>").rendered().string, "start&copy; <tag>")
    let source = FormattedMarkdownEditModel(markdown: "start")
    let atEnd = NSRange(location: source.rendered().length, length: 0)
    let entity = try! XCTUnwrap(source.replacing(atEnd, with: "&copy; <tag>"))
    XCTAssertEqual(entity.markdown, "start\\&copy; \\<tag>")
    XCTAssertEqual(entity.rendered().string, "start&copy; <tag>")
    let list = try! XCTUnwrap(FormattedMarkdownEditModel(markdown: "").replacing(NSRange(location: 0, length: 0), with: "1. item"))
    XCTAssertEqual(list.rendered().string, "1. item")
  }

  func testMarkdownListMarkersStayVisibleWhileItemTextRemainsEditable() {
    let model = FormattedMarkdownEditModel(markdown: "- First point\n2. Deuxième point")
    XCTAssertEqual(model.rendered().string, "- First point\n2. Deuxième point")
    let changedMarker = try! XCTUnwrap(model.replacing(NSRange(location: 0, length: 1), with: "+"))
    XCTAssertEqual(changedMarker.markdown, "+ First point\n2. Deuxième point")
    XCTAssertEqual(changedMarker.rendered().string, "+ First point\n2. Deuxième point")
    let all = NSRange(location: 0, length: model.rendered().length)
    let replacement = try! XCTUnwrap(model.replacing(all, with: "Replacement"))
    XCTAssertEqual(replacement.markdown, "Replacement")
    XCTAssertEqual(replacement.rendered().string, "Replacement")

    let first = NSRange(model.rendered().string.range(of: "First")!, in: model.rendered().string)
    let afterFirst = try! XCTUnwrap(model.replacing(first, with: "Updated"))
    XCTAssertEqual(afterFirst.markdown, "- Updated point\n2. Deuxième point")
    XCTAssertEqual(afterFirst.rendered().string, "- Updated point\n2. Deuxième point")

    let second = NSRange(afterFirst.rendered().string.range(of: "Deuxième")!, in: afterFirst.rendered().string)
    let afterSecond = try! XCTUnwrap(afterFirst.replacing(second, with: "French"))
    XCTAssertEqual(afterSecond.markdown, "- Updated point\n2. French point")
    XCTAssertEqual(afterSecond.rendered().string, "- Updated point\n2. French point")
  }

  func testASecondNumberAfterAListMarkerStaysTextAndInlineFormattingSurvives() {
    let model = FormattedMarkdownEditModel(markdown: "3. 2020. A year\n- **bold** and *italic* and `code`")
    let rendered = model.rendered()
    XCTAssertEqual(rendered.string, "3. 2020. A year\n- bold and italic and code")
    let bold = NSRange(rendered.string.range(of: "bold")!, in: rendered.string)
    XCTAssertTrue((rendered.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)?
      .fontDescriptor.symbolicTraits.contains(.bold) == true)
    let year = NSRange(rendered.string.range(of: "2020")!, in: rendered.string)
    XCTAssertEqual(model.replacing(year, with: "2021")?.markdown, "3. 2021. A year\n- **bold** and *italic* and `code`")
  }

  func testCodeDoesNotInterpretMarkdownDelimiters() {
    let inline = FormattedMarkdownEditModel(markdown: "before `**text**` after")
    XCTAssertEqual(inline.rendered().string, "before **text** after")
    let block = FormattedMarkdownEditModel(markdown: "```\n**text**\n```")
    XCTAssertEqual(block.rendered().string, "**text**")
    XCTAssertEqual(block.replacing(NSRange(location: 2, length: 4), with: "plain")?.markdown,
      "```\n**plain**\n```")
  }

  func testIncrementalTypingAtFormattedRunBoundariesKeepsMarkdownValid() {
    func type(_ text: String, into model: FormattedMarkdownEditModel, at location: inout Int) -> FormattedMarkdownEditModel {
      var result = model
      for character in text {
        result = try! XCTUnwrap(result.replacing(NSRange(location: location, length: 0), with: String(character)))
        location += String(character).utf16.count
      }
      return result
    }

    var bold = FormattedMarkdownEditModel(markdown: "**Junior** test")
    var location = 6
    bold = type(" Junior", into: bold, at: &location)
    XCTAssertEqual(bold.markdown, "**Junior** Junior test")
    XCTAssertEqual(bold.rendered().string, "Junior Junior test")

    var italic = FormattedMarkdownEditModel(markdown: "*bonjour* monde")
    location = 7
    italic = type(" français", into: italic, at: &location)
    XCTAssertEqual(italic.markdown, "*bonjour* français monde")
    XCTAssertEqual(italic.rendered().string, "bonjour français monde")
  }

  func testFormattingActionsPreserveVisibleTextAndUpdateCanonicalMarkdown() {
    let plain = FormattedMarkdownEditModel(markdown: "Say hello")
    let hello = NSRange(location: 4, length: 5)
    let bold = try! XCTUnwrap(plain.applyingStyle("**", to: hello))
    XCTAssertEqual(bold.markdown, "Say **hello**")
    XCTAssertEqual(bold.rendered().string, plain.rendered().string)
    XCTAssertTrue((bold.rendered().attribute(.font, at: hello.location, effectiveRange: nil) as? NSFont)?
      .fontDescriptor.symbolicTraits.contains(.bold) == true)
    XCTAssertEqual(bold.applyingStyle("**", to: hello)?.markdown, plain.markdown)
    let italic = try! XCTUnwrap(plain.applyingStyle("*", to: hello))
    XCTAssertEqual(italic.markdown, "Say *hello*")
    XCTAssertEqual(italic.applyingStyle("*", to: hello)?.markdown, plain.markdown)
    let boldItalic = try! XCTUnwrap(bold.applyingStyle("*", to: hello))
    XCTAssertEqual(boldItalic.markdown, "Say ***hello***")
    XCTAssertEqual(boldItalic.applyingStyle("*", to: hello)?.markdown, bold.markdown)
    let paragraph = FormattedMarkdownEditModel(markdown: "hello\n")
    let allParagraph = NSRange(location: 0, length: paragraph.rendered().length)
    XCTAssertEqual(paragraph.applyingStyle("**", to: allParagraph)?.markdown, "**hello**\n")

    let heading = try! XCTUnwrap(plain.applyingHeading(to: hello))
    XCTAssertEqual(heading.markdown, "# Say hello")
    XCTAssertEqual(heading.rendered().string, plain.rendered().string)
    XCTAssertEqual(heading.applyingHeading(to: hello)?.markdown, plain.markdown)

    let linked = try! XCTUnwrap(plain.applyingLink(to: hello, destination: "https://example.com"))
    XCTAssertEqual(linked.markdown, "Say [hello](https://example.com)")
    XCTAssertEqual(linked.rendered().string, plain.rendered().string)

    let existing = FormattedMarkdownEditModel(markdown: "Read [this page](https://old.example)")
    let label = NSRange(location: 5, length: 9)
    XCTAssertEqual(existing.linkDestination(for: label), "https://old.example")
    let updated = try! XCTUnwrap(existing.applyingLink(to: label, destination: "https://new.example"))
    XCTAssertEqual(updated.markdown, "Read [this page](https://new.example)")
    XCTAssertEqual(updated.rendered().string, existing.rendered().string)
    XCTAssertEqual(updated.removingLink(to: label)?.markdown, "Read this page")
    let titled = FormattedMarkdownEditModel(markdown: "Read [this page](https://old.example \"Old\")")
    XCTAssertNil(titled.linkDestination(for: label))
    XCTAssertNil(titled.applyingLink(to: label, destination: "https://new.example"))
    XCTAssertEqual(titled.removingLink(to: label)?.markdown, "Read this page")
  }

  func testRenderedTextUsesSemanticForegroundColour() {
    let rendered = FormattedMarkdownEditModel(markdown: "# Heading\n\n**bold**").rendered()
    XCTAssertEqual(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .labelColor)
    XCTAssertEqual(rendered.attribute(.foregroundColor, at: rendered.length - 1, effectiveRange: nil) as? NSColor, .labelColor)
  }

  @MainActor func testNativeIncrementalTypingAfterFormattedRuns() {
    var value = "**Junior** test"
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)

    view.setSelectedRange(NSRange(location: 6, length: 0))
    for character in " Junior" {
      view.insertText(String(character), replacementRange: view.selectedRange())
    }
    XCTAssertEqual(value, "**Junior** Junior test")
    XCTAssertEqual(view.string, "Junior Junior test")

    value = "*bonjour* monde"
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)
    view.setSelectedRange(NSRange(location: 7, length: 0))
    for character in " français" {
      view.insertText(String(character), replacementRange: view.selectedRange())
    }
    XCTAssertEqual(value, "*bonjour* français monde")
    XCTAssertEqual(view.string, "bonjour français monde")
  }

  @MainActor func testProgrammaticFormattingUndoThenNativeTypingUndoRedo() {
    var value = "hello"
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.allowsUndo = true
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)

    view.setSelectedRange(NSRange(location: 0, length: 5))
    coordinator.apply(.bold, in: view)
    XCTAssertEqual(value, "**hello**")
    view.undoManager?.undo()
    XCTAssertEqual(value, "hello")
    XCTAssertEqual(view.string, "hello")

    view.setSelectedRange(NSRange(location: 5, length: 0))
    view.insertText("!", replacementRange: view.selectedRange())
    XCTAssertEqual(value, "hello!")
    view.undoManager?.undo()
    XCTAssertEqual(value, "hello")
    view.undoManager?.redo()
    XCTAssertEqual(value, "hello!")
  }

  @MainActor func testNativeBoundaryFallbackReconcilesFormattingThroughUndoRedo() {
    let original = "**Junior**"
    let edited = "**Junior** test"
    var value = original
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.allowsUndo = true
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [], backing: .buffered, defer: true)
    window.contentView = view
    window.makeFirstResponder(view)
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)

    view.undoManager?.groupsByEvent = false
    view.undoManager?.beginUndoGrouping()
    view.setSelectedRange(NSRange(location: 0, length: 6))
    view.insertText("Junior", replacementRange: view.selectedRange())
    view.setSelectedRange(NSRange(location: 6, length: 0))
    view.insertText(" test", replacementRange: view.selectedRange())
    view.undoManager?.endUndoGrouping()
    XCTAssertEqual(value, edited)
    XCTAssertEqual(view.string, "Junior test")
    XCTAssertTrue((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?
      .fontDescriptor.symbolicTraits.contains(.bold) == true)
    XCTAssertFalse((view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?
      .fontDescriptor.symbolicTraits.contains(.bold) == true)

    view.undoManager?.undo()
    XCTAssertEqual(value, original)
    view.undoManager?.redo()
    XCTAssertEqual(value, edited)
    XCTAssertFalse((view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?
      .fontDescriptor.symbolicTraits.contains(.bold) == true)
  }

  @MainActor func testNativeEditUndoRedoUpdateBinding() {
    var value = "# Heading"
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.allowsUndo = true
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [], backing: .buffered, defer: true)
    window.contentView = view
    window.makeFirstResponder(view)
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)
    let heading = NSRange(view.string.range(of: "Heading")!, in: view.string)
    view.setSelectedRange(heading)
    view.insertText("Title", replacementRange: heading)
    XCTAssertEqual(value, "# Title")
    XCTAssertTrue(view.undoManager?.canUndo == true)
    view.undoManager?.undo()
    XCTAssertEqual(value, "# Heading")
    XCTAssertTrue(view.undoManager?.canRedo == true)
    view.undoManager?.redo()
    XCTAssertEqual(value, "# Title")
    XCTAssertTrue(view.undoManager?.canUndo == true)
  }

  @MainActor func testFontChangeKeepsSourceAndNativeSelection() {
    var value = "# Heading"
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)
    let selection = NSRange(view.string.range(of: "Heading")!, in: view.string)
    view.setSelectedRange(selection)
    coordinator.configure(view, markdown: value, fontName: "Georgia", fontSize: 24)
    XCTAssertEqual(value, "# Heading")
    XCTAssertEqual(view.string, "Heading")
    XCTAssertEqual(view.selectedRange(), selection)
    XCTAssertGreaterThan((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 24)
  }

  @MainActor func testMarkedTextDefersSourceUntilCompositionEnds() {
    var value = "# Heading"
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)
    let heading = NSRange(view.string.range(of: "Heading")!, in: view.string)
    view.setMarkedText("Title", selectedRange: NSRange(location: 5, length: 0), replacementRange: heading)
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
    XCTAssertEqual(value, "# Heading")
    view.unmarkText()
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
    XCTAssertEqual(value, "# Title")
  }

  @MainActor func testNativeUndoRestoresExactCrossFormatSource() {
    let original = "**bold** and *italic* 😀 français"
    let edited = "**bREPL***alic* 😀 français"
    var value = original
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.allowsUndo = true
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [], backing: .buffered, defer: true)
    window.contentView = view
    window.makeFirstResponder(view)
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)
    let selection = NSRange(view.string.range(of: "old and it")!, in: view.string)
    view.insertText("REPL", replacementRange: selection)
    XCTAssertEqual(value, edited)
    view.undoManager?.undo()
    XCTAssertEqual(value, original)
    view.undoManager?.redo()
    XCTAssertEqual(value, edited)
  }

  @MainActor func testNativeIncrementalTypingInEmptyParagraphPreservesSpaces() {
    var value = ""
    var unsupportedEdits = 0
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "Lexend Deca", fontSize: 18, onUnsupportedEdit: { unsupportedEdits += 1 })
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "Lexend Deca", fontSize: 18)

    var expected = ""
    for character in "Native editing test." {
      expected.append(character)
      view.insertText(String(character), replacementRange: view.selectedRange())
      XCTAssertEqual(view.string, expected)
      XCTAssertEqual(value, expected)
    }
    XCTAssertEqual(unsupportedEdits, 0)
  }

  @MainActor func testEmptyDocumentUsesSelectedTypingFont() {
    var value = ""
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "Georgia", fontSize: 24)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "Georgia", fontSize: 24)
    view.insertText("Text", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(value, "Text")
    let font = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    XCTAssertEqual(font?.pointSize, 24)
    XCTAssertTrue(font?.familyName?.contains("Georgia") == true)
  }

  @MainActor func testNativeMultipleEditsUndoRedoWithUnicode() {
    var value = "café 😀 bonjour"
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.allowsUndo = true
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [], backing: .buffered, defer: true)
    window.contentView = view
    window.makeFirstResponder(view)
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)
    view.undoManager?.groupsByEvent = false
    view.undoManager?.beginUndoGrouping()
    var range = NSRange(view.string.range(of: "café")!, in: view.string)
    view.insertText("salut", replacementRange: range)
    view.undoManager?.endUndoGrouping()
    view.undoManager?.beginUndoGrouping()
    range = NSRange(view.string.range(of: "😀")!, in: view.string)
    view.insertText("😁", replacementRange: range)
    view.undoManager?.endUndoGrouping()
    XCTAssertEqual(value, "salut 😁 bonjour")
    view.undoManager?.undo()
    XCTAssertEqual(value, "salut 😀 bonjour")
    view.undoManager?.undo()
    XCTAssertEqual(value, "café 😀 bonjour")
    view.undoManager?.redo()
    view.undoManager?.redo()
    XCTAssertEqual(value, "salut 😁 bonjour")
  }

  /// Obsidian saves the linked file while the editor is scrolled down: text inserted or deleted
  /// before the visible passage must not move it, and nothing changes at the very top.
  @MainActor func testExternalUpdateKeepsTheVisiblePassageWhereItIs() throws {
    let original = (1...40).map { "Passage \($0) with several readable words." }.joined(separator: "\n\n")
    var value = original
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "Helvetica", fontSize: 24)
    let coordinator = editor.makeCoordinator()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 4_000))
    view.isVerticallyResizable = true
    view.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    scroll.documentView = view
    coordinator.configure(view, markdown: value, fontName: "Helvetica", fontSize: 24)
    let manager = try XCTUnwrap(view.layoutManager)
    let container = try XCTUnwrap(view.textContainer)
    func lineTop(_ word: String) -> CGFloat {
      manager.ensureLayout(for: container)
      let range = (view.string as NSString).range(of: word)
      return manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: range.location), effectiveRange: nil).minY
    }
    func shown(_ word: String) -> CGFloat { lineTop(word) - scroll.contentView.bounds.minY }
    scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: lineTop("Passage 25 ") - 120))
    scroll.reflectScrolledClipView(scroll.contentView)
    let before = shown("Passage 25 ")

    value = "Inserted one.\n\nInserted two.\n\nInserted three.\n\n" + original
    coordinator.configure(view, markdown: value, fontName: "Helvetica", fontSize: 24)
    XCTAssertEqual(shown("Passage 25 "), before, accuracy: 1, "an insertion before it")

    value = original.replacingOccurrences(of: "Passage 1 with several readable words.\n\n", with: "")
    coordinator.configure(view, markdown: value, fontName: "Helvetica", fontSize: 24)
    XCTAssertEqual(shown("Passage 25 "), before, accuracy: 1, "a deletion before it")

    XCTAssertEqual(FormattedMarkdownEditor.Coordinator.mappedOffset(50, from: "abc", to: "abc"), 50)
    XCTAssertEqual(FormattedMarkdownEditor.Coordinator.mappedOffset(9, from: "abc def ghi", to: "abc XY def ghi"), 12)
    XCTAssertEqual(FormattedMarkdownEditor.Coordinator.mappedOffset(9, from: "abc def ghi", to: "abc ghi"), 5)
  }

  @MainActor func testExternalSourceReplacementClearsEditorUndoHistory() {
    var value = "one"
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System Serif", fontSize: 17)
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: .zero)
    view.allowsUndo = true
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)
    view.insertText("two", replacementRange: NSRange(location: 0, length: 3))
    XCTAssertEqual(value, "two")
    XCTAssertTrue(view.undoManager?.canUndo == true)
    value = "external **source**"
    coordinator.configure(view, markdown: value, fontName: "System Serif", fontSize: 17)
    XCTAssertEqual(view.string, "external source")
    XCTAssertFalse(view.undoManager?.canUndo == true)
    view.undoManager?.undo()
    XCTAssertEqual(value, "external **source**")
  }

  private let callout = "Before.\n\n> [!info] Graphic — the **quote**\n> On screen, *his* words.\n> Source: Opta.\n\nAfter."

  func testCalloutRendersTitleAndBodyInABoxWithoutMarkers() throws {
    let model = FormattedMarkdownEditModel(markdown: callout)
    let rendered = model.rendered(fontSize: 20)
    XCTAssertEqual(rendered.string, "Before.\n\nGraphic — the quote\nOn screen, his words.\nSource: Opta.\n\nAfter.")
    let text = rendered.string as NSString
    let title = text.range(of: "Graphic")
    XCTAssertEqual(rendered.attribute(.foregroundColor, at: title.location, effectiveRange: nil) as? NSColor, .systemBlue)
    XCTAssertTrue((rendered.attribute(.font, at: title.location, effectiveRange: nil) as? NSFont)?
      .fontDescriptor.symbolicTraits.contains(.bold) == true)
    let his = text.range(of: "his")
    XCTAssertTrue((rendered.attribute(.font, at: his.location, effectiveRange: nil) as? NSFont)?
      .fontDescriptor.symbolicTraits.contains(.italic) == true)
    func blocks(at index: Int) -> [NSTextBlock] {
      (rendered.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []
    }
    let box = try XCTUnwrap(blocks(at: title.location).first)
    XCTAssertTrue(blocks(at: text.range(of: "Source").location).first === box, "one box for the whole callout")
    XCTAssertEqual(box.borderColor(for: .minX), .systemBlue)
    XCTAssertGreaterThan(box.width(for: .border, edge: .minX), 0)
    XCTAssertTrue(blocks(at: text.range(of: "Before").location).isEmpty)
    XCTAssertTrue(blocks(at: text.range(of: "After").location).isEmpty)
    // Title-less callouts show their type; other types take their colour family.
    let bare = FormattedMarkdownEditModel(markdown: "> [!warning]\n> Careful").rendered()
    XCTAssertEqual(bare.string, "Warning\nCareful")
    XCTAssertEqual(bare.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemOrange)
    // A plain quote keeps its current rendering.
    XCTAssertEqual(FormattedMarkdownEditModel(markdown: "> just a quote").rendered().string, "just a quote")
  }

  func testEditsInsideACalloutRoundTripToMarkdown() throws {
    let model = FormattedMarkdownEditModel(markdown: callout)
    let text = model.rendered().string as NSString
    let words = try XCTUnwrap(model.replacing(text.range(of: "words"), with: "claims"))
    XCTAssertEqual(words.markdown, callout.replacingOccurrences(of: "words.", with: "claims."))
    let titled = try XCTUnwrap(model.replacing(text.range(of: "Graphic"), with: "Chart"))
    XCTAssertEqual(titled.markdown, callout.replacingOccurrences(of: "Graphic", with: "Chart"))
    let bold = try XCTUnwrap(model.applyingStyle("**", to: text.range(of: "Source")))
    XCTAssertEqual(bold.markdown, callout.replacingOccurrences(of: "> Source", with: "> **Source**"))
    // Joining two callout lines takes the hidden "> " with the line break.
    let join = try XCTUnwrap(model.replacing(NSRange(location: text.range(of: "Source").location - 1, length: 1), with: " "))
    XCTAssertEqual(join.markdown, callout.replacingOccurrences(of: "words.\n> Source", with: "words. Source"))
    let start = text.range(of: "words").location
    let spanned = try XCTUnwrap(model.replacing(NSRange(location: start, length: text.range(of: "Opta").location - start), with: ""))
    XCTAssertEqual(spanned.markdown, callout.replacingOccurrences(of: "words.\n> Source: ", with: ""))
    XCTAssertEqual(spanned.rendered().string, "Before.\n\nGraphic — the quote\nOn screen, his Opta.\n\nAfter.")
  }

  func testReturnInsideACalloutKeepsTheLineInItAndReturnOnAnEmptyLastLineLeavesIt() throws {
    let model = FormattedMarkdownEditModel(markdown: callout)
    let text = model.rendered().string as NSString
    let afterWords = NSMaxRange(text.range(of: "words."))
    let split = try XCTUnwrap(model.replacing(NSRange(location: afterWords, length: 0), with: "\n"))
    XCTAssertEqual(split.markdown, callout.replacingOccurrences(of: "words.\n", with: "words.\n> \n"))
    let typed = try XCTUnwrap(split.replacing(NSRange(location: afterWords + 1, length: 0), with: "New"))
    XCTAssertEqual(typed.markdown, callout.replacingOccurrences(of: "words.\n", with: "words.\n> New\n"))
    XCTAssertEqual(PrompterDocument(markdown: typed.markdown).blocks.map(\.kind), [.paragraph, .callout, .paragraph])
    // Return at the end of the title and at the end of the last line.
    let afterTitle = try XCTUnwrap(model.replacing(NSRange(location: NSMaxRange(text.range(of: "quote")), length: 0), with: "\n"))
    XCTAssertTrue(afterTitle.markdown.contains("**quote**\n> \n> On screen"))
    let lastEnd = NSMaxRange(text.range(of: "Opta."))
    let extended = try XCTUnwrap(model.replacing(NSRange(location: lastEnd, length: 0), with: "\n"))
    XCTAssertTrue(extended.markdown.contains("> Source: Opta.\n> \n\nAfter."))
    // A second Return on that empty last line leaves the callout, as in Obsidian.
    let left = try XCTUnwrap(extended.replacing(NSRange(location: lastEnd + 1, length: 0), with: "\n"))
    XCTAssertTrue(left.markdown.contains("> Source: Opta.\n\n\n\nAfter."))
    let paragraph = try XCTUnwrap(left.replacing(NSRange(location: lastEnd + 2, length: 0), with: "Out"))
    XCTAssertEqual(PrompterDocument(markdown: paragraph.markdown).blocks.map(\.kind), [.paragraph, .callout, .paragraph, .paragraph])
    // At the very end of a file too.
    let tail = FormattedMarkdownEditModel(markdown: "> [!tip] Note\n> body")
    let tailExtended = try XCTUnwrap(tail.replacing(NSRange(location: tail.rendered().length, length: 0), with: "\n"))
    XCTAssertEqual(tailExtended.markdown, "> [!tip] Note\n> body\n> ")
    let tailLeft = try XCTUnwrap(tailExtended.replacing(NSRange(location: tailExtended.rendered().length, length: 0), with: "\n"))
    XCTAssertEqual(tailLeft.markdown, "> [!tip] Note\n> body\n\n")
    let tailTyped = try XCTUnwrap(tailLeft.replacing(NSRange(location: tailLeft.rendered().length, length: 0), with: "Said"))
    XCTAssertEqual(tailTyped.markdown, "> [!tip] Note\n> body\n\nSaid")
  }

  func testPresenterModelOmitsCalloutsAndTheirBlankLines() {
    let markdown = "> [!info] First\n> x\n\nOne.\n\n> [!info] A\n> a\n\n> [!tip] B\n> b\n\nTwo.\n\n> [!info] Last\n> z\n"
    let model = FormattedMarkdownEditModel(markdown: markdown, omittingCallouts: true)
    XCTAssertEqual(model.rendered().string, "One.\n\nTwo.\n")
    let source = markdown as NSString
    let visible = model.visibleIndices()
    XCTAssertEqual(visible[source.range(of: "Two").location], 6)
    XCTAssertEqual(visible[source.range(of: "One").location], 0)
  }

  @MainActor func testNativeTypingAndReturnInsideACallout() {
    var value = "> [!info] Graphic\n> body"
    var unsupportedEdits = 0
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }),
      fontName: "System", fontSize: 18, onUnsupportedEdit: { unsupportedEdits += 1 })
    let coordinator = FormattedMarkdownEditor.Coordinator(editor)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.delegate = coordinator
    coordinator.configure(view, markdown: value, fontName: "System", fontSize: 18)
    XCTAssertEqual(view.string, "Graphic\nbody")
    view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
    view.insertNewline(nil)
    view.insertText("more", replacementRange: view.selectedRange())
    XCTAssertEqual(value, "> [!info] Graphic\n> body\n> more")
    view.insertNewline(nil)
    view.insertNewline(nil)
    view.insertText("Spoken", replacementRange: view.selectedRange())
    XCTAssertEqual(value, "> [!info] Graphic\n> body\n> more\n\nSpoken")
    XCTAssertEqual(view.string, "Graphic\nbody\nmore\n\nSpoken")
    XCTAssertEqual(unsupportedEdits, 0)
  }

  func testEditsBesideACalloutNeverSilenceScriptAndDeletingACalloutRemovesItsHeader() throws {
    let model = FormattedMarkdownEditModel(markdown: callout)
    let text = model.rendered().string as NSString
    // Backspace at the start of the paragraph after the callout.
    let joined = try XCTUnwrap(model.replacing(NSRange(location: text.range(of: "After").location - 1, length: 1), with: ""))
    XCTAssertEqual(joined.markdown, callout.replacingOccurrences(of: "Opta.\n\nAfter", with: "Opta.\nAfter"))
    XCTAssertEqual(PrompterDocument(markdown: joined.markdown).spokenTokens.last?.text, "After")
    // Typing on the blank line above the callout.
    let above = try XCTUnwrap(model.replacing(NSRange(location: text.range(of: "Graphic").location - 1, length: 0), with: "Said"))
    XCTAssertEqual(above.markdown, callout.replacingOccurrences(of: "Before.\n\n", with: "Before.\nSaid\n"))
    XCTAssertEqual(PrompterDocument(markdown: above.markdown).blocks.map(\.kind), [.paragraph, .callout, .paragraph])
    // Deleting the whole callout's visible text, alone or with the passage before it.
    let start = text.range(of: "Graphic").location
    let whole = NSRange(location: start, length: NSMaxRange(text.range(of: "Opta.")) - start)
    XCTAssertEqual(try XCTUnwrap(model.replacing(whole, with: "")).markdown, "Before.\n\n\n\nAfter.")
    let withBefore = NSRange(location: 0, length: NSMaxRange(whole))
    XCTAssertEqual(try XCTUnwrap(model.replacing(withBefore, with: "")).markdown, "\n\nAfter.")
    XCTAssertEqual(try XCTUnwrap(model.replacing(NSRange(location: 0, length: text.length), with: "")).markdown, "")
    // The box is the same object across renders, so re-rendering does not restyle it.
    func box(_ rendered: NSAttributedString) -> NSTextBlock? {
      (rendered.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
    }
    XCTAssertTrue(box(model.rendered()) === box(FormattedMarkdownEditModel(markdown: callout).rendered()))
    let touching = FormattedMarkdownEditModel(markdown: "> [!info] A\n> a\n> [!info] B\n> b").rendered()
    func block(at index: Int) -> NSTextBlock? {
      (touching.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
    }
    XCTAssertEqual(touching.string, "A\na\nB\nb")
    XCTAssertFalse(block(at: 0) === block(at: 4), "touching callouts draw as two boxes")
  }
}
