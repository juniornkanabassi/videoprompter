import AppKit
import SwiftUI
import XCTest
@testable import JuniorPrompter

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

  func testCodeDoesNotInterpretMarkdownDelimiters() {
    let inline = FormattedMarkdownEditModel(markdown: "before `**text**` after")
    XCTAssertEqual(inline.rendered().string, "before **text** after")
    let block = FormattedMarkdownEditModel(markdown: "```\n**text**\n```")
    XCTAssertEqual(block.rendered().string, "**text**")
    XCTAssertEqual(block.replacing(NSRange(location: 2, length: 4), with: "plain")?.markdown,
      "```\n**plain**\n```")
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
}
