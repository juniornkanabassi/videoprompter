import AppKit
import PrompterCore
import SwiftUI
import XCTest

@testable import VideoPrompter

/// Editing a script in the presenter, driven the way a person edits: the real presenter editor in
/// an offscreen window, real text-view commands, then the Markdown file read back from disk.
/// Nothing is shown, the real clipboard is never touched, and the library is a throwaway folder.
@MainActor
final class ScriptEditingTests: XCTestCase {
  static let rich = "# Title\n\nOne sentence. Two **bold** words and [a link](https://example.com) end.\n\n- first item\n- second *item*\n\n1. one\n2. two\n\nLast line."

  private final class Counter { var unsupported = 0 }

  @MainActor private struct Rig {
    let store: AppStore
    let record: ScriptRecord
    let draft: PresenterDraft
    let window: NSWindow
    let host: NSHostingView<PresenterEditorView>
    let view: NSTextView
    let counter: Counter
    let file: URL?

    var visible: String { view.string }
    func select(_ text: String, occurrence: Int = 0) {
      var from = 0
      var range = NSRange(location: NSNotFound, length: 0)
      for _ in 0...occurrence {
        range = (view.string as NSString).range(of: text, range: NSRange(location: from, length: view.string.utf16.count - from))
        from = NSMaxRange(range)
      }
      precondition(range.location != NSNotFound, "\(text) is not on screen: \(view.string)")
      view.setSelectedRange(range)
    }
    func caret(after text: String) {
      let range = (view.string as NSString).range(of: text)
      precondition(range.location != NSNotFound, "\(text) is not on screen")
      view.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }
    func type(_ text: String) { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    func settle() async {
      for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(15)) }
    }
  }

  private func editableTextView(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView, text.isEditable { return text }
    for sub in view.subviews { if let found = editableTextView(in: sub) { return found } }
    return nil
  }

  /// A library with one script (optionally a linked file outside it), presented and opened for editing.
  private func makeRig(_ markdown: String = ScriptEditingTests.rich, linked: Bool = false, seekTo word: String? = nil) async throws -> Rig {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("editing-\(UUID().uuidString)")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults()))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    var record = try await store.library!.create(title: "Edit me", markdown: markdown)
    var file: URL?
    if linked {
      // The library refuses a link into its own folder, so the file lives beside it.
      let outside = FileManager.default.temporaryDirectory.appendingPathComponent("editing-outside-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
      file = outside.appendingPathComponent("edit-me.md")
      try Data(markdown.utf8).write(to: file!)
      _ = try await store.library!.link(record.id, to: file!)
      record = try await store.library!.read(record.id)
    }
    await store.reload()
    store.selectedID = record.id
    var settings = PrompterSettings()
    settings.mode = "Manual"
    store.session.present(record: try XCTUnwrap(store.selected), settings: settings)
    if let word, let index = store.session.document.spokenTokens.firstIndex(where: { $0.normalised == word }) {
      store.session.seek(to: index)
    }
    let draft = PresenterDraft(record: record)
    draft.begin(session: store.session)
    let counter = Counter()
    let host = NSHostingView(rootView: PresenterEditorView(
      session: store.session, draft: draft, settings: settings, sideInset: 42, onUnsupportedEdit: { counter.unsupported += 1 }))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 520), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.contentView = host
    addTeardownBlock { @MainActor in window.contentView = nil }
    var found: NSTextView?
    for _ in 0..<60 {
      host.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(20))
      found = editableTextView(in: host)
      if let found, window.firstResponder === found { break }
    }
    let view = try XCTUnwrap(found)
    return Rig(store: store, record: store.selected ?? record, draft: draft, window: window, host: host, view: view, counter: counter, file: file)
  }

  private func disk(_ rig: Rig) async throws -> String {
    let url = try await rig.store.library!.scriptURL(for: rig.record.id)
    return try String(contentsOf: rig.file ?? url, encoding: .utf8)
  }

  private func privateBoard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("VideoPrompterEditing.\(UUID().uuidString)"))
    addTeardownBlock { board.releaseGlobally() }
    board.clearContents()
    return board
  }

  private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
  }

  // MARK: Entering edit mode

  /// Root cause: focus and the caret were set one main-queue hop after SwiftUI made the view, when
  /// the view often had no window or no height yet. Entering edit mode now waits for the real view.
  func testEditModeTakesFocusAtOnceWithTheCaretAtTheReadingPosition() async throws {
    let markdown = (1...30).map { "Passage \($0) with several readable words." }.joined(separator: "\n\n")
    let rig = try await makeRig(markdown, seekTo: "20")
    XCTAssertTrue(rig.window.firstResponder === rig.view, "the editor is focused without a click")
    let visible = try XCTUnwrap(FormattedMarkdownEditModel(markdown: markdown)
      .visibleIndex(forSourceOffset: try XCTUnwrap(rig.store.session.activeToken).sourceRange.location))
    XCTAssertEqual(rig.view.selectedRange(), NSRange(location: visible, length: 0), "caret at the reading position")
    rig.type("X")
    XCTAssertTrue(rig.draft.markdown.contains("X20"), "typing lands where the reader was")
    XCTAssertEqual(rig.counter.unsupported, 0)
  }

  /// Root cause: after the Alpha redesign nothing called `begin`, so the only way to edit was the
  /// library. The controller now opens the same draft in place.
  func testControllerOpensTheDraftInPlaceAndTheEditorTakesFocus() async throws {
    _ = NSApplication.shared
    try XCTSkipIf(CameraModel.shared.presentsWithVideo, "video on would open a camera from a test")
    OffscreenPanels.install()
    defer { OffscreenPanels.uninstall() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("editing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults()))
    let record = try await store.library!.create(title: "Live", markdown: "Opening words here.\n\nSecond passage with the target word.")
    await store.reload()
    store.selectedID = record.id
    store.settings.mode = "Manual"
    let controller = PresenterController()
    controller.beginEditing()
    XCTAssertFalse(controller.isEditing, "nothing to edit before the presenter is open")
    controller.present(store: store)
    let target = try XCTUnwrap(store.session.document.spokenTokens.firstIndex { $0.normalised == "target" })
    store.session.seek(to: target)
    controller.beginEditing()
    XCTAssertTrue(controller.isEditing)
    XCTAssertFalse(store.session.isActivelyRunning, "reading pauses while editing")
    var editor: NSTextView?
    for _ in 0..<100 {
      try? await Task.sleep(for: .milliseconds(20))
      if let content = controller.panel?.contentView { editor = editableTextView(in: content) }
      if let editor, controller.panel?.firstResponder === editor { break }
    }
    let view = try XCTUnwrap(editor, "the editor appears in the presenter")
    XCTAssertTrue(controller.panel?.firstResponder === view)
    let draft = try XCTUnwrap(controller.draft)
    draft.markdown = "Opening words changed.\n\nSecond passage with the target word."
    await draft.confirm(store: store)
    XCTAssertFalse(controller.isEditing)
    XCTAssertEqual(store.session.activeToken?.normalised, "target")
    let saved = try await store.library!.read(record.id)
    XCTAssertEqual(saved.markdown, "Opening words changed.\n\nSecond passage with the target word.")
  }

  // MARK: Keyboard commands

  /// Root cause: Edit-menu commands never reached the editor while the app was inactive (OBS in
  /// front of the non-activating presenter), and the test process has no menu bar at all, so this
  /// also proves the editor answers them itself.
  func testKeyboardShortcutsReachTheFocusedEditorWithoutAMenu() async throws {
    let rig = try await makeRig()
    XCTAssertNil(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.item(withTitle: "Select All"), "no help from a menu")
    rig.view.setSelectedRange(NSRange(location: 0, length: 0))
    XCTAssertTrue(rig.window.performKeyEquivalent(with: key("a", .command, in: rig.window)))
    XCTAssertEqual(rig.view.selectedRange(), NSRange(location: 0, length: rig.view.string.utf16.count), "Cmd-A selects everything")
    rig.caret(after: "Title\n\n")
    rig.type("Hello ")
    rig.type("world ")
    XCTAssertTrue(rig.draft.markdown.hasPrefix("# Title\n\nHello world One"))
    XCTAssertTrue(rig.window.performKeyEquivalent(with: key("z", .command, in: rig.window)), "Cmd-Z")
    XCTAssertEqual(rig.draft.markdown, Self.rich, "undo takes the typing back out of the Markdown")
    XCTAssertTrue(rig.window.performKeyEquivalent(with: key("z", [.command, .shift], in: rig.window)), "Shift-Cmd-Z")
    XCTAssertTrue(rig.draft.markdown.hasPrefix("# Title\n\nHello world One"), "redo puts it back")
    // Command-Delete is Move to Trash in the library menu; in the editor it deletes to the line start.
    let before = rig.draft.markdown
    rig.caret(after: "Two bold")
    XCTAssertTrue(rig.window.performKeyEquivalent(with: key("\u{7F}", .command, in: rig.window)))
    XCTAssertLessThan(rig.draft.markdown.count, before.count, "text before the caret on its line is gone")
    XCTAssertTrue(rig.draft.markdown.contains(" words and [a link](https://example.com) end."), rig.draft.markdown)
    XCTAssertTrue(rig.store.scripts.contains { $0.id == rig.record.id }, "and the script was not moved to the Trash")
    rig.window.makeFirstResponder(nil)
    XCTAssertFalse(rig.window.performKeyEquivalent(with: key("a", .command, in: rig.window)), "an unfocused editor does not grab keys")
  }

  // MARK: Selecting, deleting, cutting, copying, pasting

  func testDoubleAndTripleClickSelectAWordAndAParagraph() async throws {
    let rig = try await makeRig()
    let range = (rig.view.string as NSString).range(of: "sentence")
    let manager = try XCTUnwrap(rig.view.layoutManager)
    manager.ensureLayout(for: try XCTUnwrap(rig.view.textContainer))
    let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: range.location + 2, length: 1), actualCharacterRange: nil)
    let rect = manager.boundingRect(forGlyphRange: glyphs, in: rig.view.textContainer!)
    let inView = NSPoint(x: rect.midX + rig.view.textContainerOrigin.x, y: rect.midY + rig.view.textContainerOrigin.y)
    let point = rig.view.convert(inView, to: nil)
    func click(_ count: Int) {
      let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
      // The mouse-up is queued first so the text view's own drag-tracking loop ends at once.
      NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: rig.window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 0)!, atStart: false)
      rig.view.mouseDown(with: down)
    }
    click(2)
    XCTAssertEqual((rig.view.string as NSString).substring(with: rig.view.selectedRange()).trimmingCharacters(in: .whitespaces), "sentence")
    click(3)
    let triple = (rig.view.string as NSString).substring(with: rig.view.selectedRange())
    XCTAssertTrue(triple.hasPrefix("One sentence. Two bold words and a link end."), "triple click takes the paragraph: \(triple)")
    rig.view.deleteBackward(nil)
    XCTAssertFalse(rig.draft.markdown.contains("One sentence"))
    XCTAssertTrue(rig.draft.markdown.contains("# Title"))
    XCTAssertEqual(rig.counter.unsupported, 0)
  }

  /// Root cause: only 32 percent of the ways to select text across formatting could be deleted:
  /// a heading, a whole bold word, a whole link or select-all were silently refused ("script
  /// edit not supported") and nothing happened. Deleting what is selected now always works.
  func testDeletingAnySelectionWorksAcrossHeadingsBoldLinksListsAndCallouts() async throws {
    let docs = [
      Self.rich,
      "Intro line.\n\n> [!note]\n> Body of the note.\n\n> [!tip] Titled\n> More body.\n\nAfter.",
      "Text\n\n```\nlet a = 1\n```\n\nEnd",
      "Intro\n\n> A plain quote\n> second line\n\nEnd",
    ]
    var tried = 0
    var refused: [String] = []
    for markdown in docs {
      let model = FormattedMarkdownEditModel(markdown: markdown)
      let text = model.rendered().string as NSString
      // Every start and every third end: all ranges would take half a minute.
      for start in 0..<text.length {
        for end in stride(from: start + 1, through: text.length, by: 3) {
          let range = NSRange(location: start, length: end - start)
          tried += 1
          guard let next = model.replacing(range, with: "") else { refused.append("\(range) in \(markdown.prefix(12))"); continue }
          // Accepted only if it removed exactly the selected text, never anything else.
          let expected = text.replacingCharacters(in: range, with: "")
          XCTAssertEqual(next.rendered().string, expected)
        }
      }
    }
    // Before: 68 percent of these were refused. What is left is a selection that stops inside a
    // callout's built-in title or a code fence, or begins inside a link and ends beyond it, where no
    // Markdown can keep the rest intact.
    XCTAssertLessThan(Double(refused.count) / Double(tried), 0.25, "refused \(refused.count) of \(tried): \(refused.prefix(8))")
    let rich = FormattedMarkdownEditModel(markdown: Self.rich)
    let all = NSRange(location: 0, length: rich.rendered().string.utf16.count)
    XCTAssertEqual(rich.replacing(all, with: "")?.markdown, "")
    XCTAssertEqual(rich.replacing(NSRange(location: 0, length: 5), with: "")?.markdown.hasPrefix("\n\nOne sentence."), true, "heading text")
    XCTAssertEqual(rich.replacing((rich.rendered().string as NSString).range(of: "a link"), with: "")?.markdown.contains("[]("), false, "no empty link left behind")
    XCTAssertEqual(rich.replacing((rich.rendered().string as NSString).range(of: "bold"), with: "")?.markdown.contains("**"), false, "no empty bold left behind")
    // Typing over a selection keeps the formatting around it.
    XCTAssertEqual(rich.replacing((rich.rendered().string as NSString).range(of: "bold"), with: "plain")?.markdown.contains("**plain**"), true)
  }

  func testSelectAllAndTypeOrDeleteInTheLiveEditor() async throws {
    let rig = try await makeRig()
    rig.view.selectAll(nil)
    rig.view.deleteBackward(nil)
    XCTAssertEqual(rig.draft.markdown, "")
    XCTAssertEqual(rig.view.string, "")
    rig.view.undoManager?.undo()
    XCTAssertEqual(rig.draft.markdown, Self.rich)
    XCTAssertEqual(rig.view.string, FormattedMarkdownEditModel(markdown: Self.rich).rendered().string)
    rig.view.selectAll(nil)
    rig.type("Brand new script.")
    XCTAssertEqual(rig.draft.markdown, "Brand new script.")
    XCTAssertEqual(rig.counter.unsupported, 0)
  }

  func testCopyPlainCutAndPlainPasteKeepMarkdownIntact() async throws {
    let rig = try await makeRig()
    // Copy is the words as plain text, not 44 pt white rich text that is invisible elsewhere.
    rig.select("Two bold words")
    XCTAssertEqual(rig.view.writablePasteboardTypes.map(\.rawValue), ["NSStringPboardType"])
    XCTAssertEqual(rig.view.readablePasteboardTypes.map(\.rawValue), ["NSStringPboardType"])
    let board = privateBoard()
    XCTAssertTrue(rig.view.writeSelection(to: board, types: rig.view.writablePasteboardTypes), "copy still works")
    XCTAssertEqual(board.string(forType: .string), "Two bold words")
    XCTAssertNil(board.data(forType: .rtf), "no rich text leaves the editor")
    // Cut is that copy plus the deletion, across the bold run.
    rig.view.delete(nil)
    XCTAssertEqual(rig.draft.markdown, Self.rich.replacingOccurrences(of: "Two **bold** words", with: ""))
    // Paste what was cut at the end: the words arrive plain, so the bold does not come back.
    rig.caret(after: "Last line.")
    XCTAssertTrue(rig.view.readSelection(from: board, type: .string))
    XCTAssertTrue(rig.draft.markdown.hasSuffix("Last line.Two bold words"))
    // Rich text on the board is ignored in favour of its plain words.
    let mixed = privateBoard()
    mixed.setString("plain words", forType: .string)
    mixed.setData(try NSAttributedString(string: "RICH words", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
      .data(from: NSRange(location: 0, length: 10), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
    rig.caret(after: "Title\n\n")
    XCTAssertTrue(rig.view.readSelection(from: mixed, type: .string))
    XCTAssertTrue(rig.draft.markdown.hasPrefix("# Title\n\nplain wordsOne sentence."), rig.draft.markdown)
    XCTAssertFalse(rig.draft.markdown.contains("RICH"))
    // Markdown typed or pasted as words stays words: it shows as typed and does not restyle the script.
    let literal = "**not bold** and # not a heading and [x](y)\n- not a list"
    rig.view.selectAll(nil)
    let pasted = privateBoard()
    pasted.setString(literal, forType: .string)
    XCTAssertTrue(rig.view.readSelection(from: pasted, type: .string))
    XCTAssertEqual(rig.view.string, literal, "the pasted words are exactly what shows")
    XCTAssertEqual(FormattedMarkdownEditModel(markdown: rig.draft.markdown).rendered().string, literal)
    XCTAssertEqual(rig.counter.unsupported, 0)
  }

  func testUndoAndRedoWalkBackAndForthThroughCutsReplacementsAndTyping() async throws {
    let rig = try await makeRig()
    rig.select("Two bold words")
    rig.view.delete(nil)                       // a cut across a bold run
    rig.select("Title")
    rig.type("Headline")                       // replacing heading text keeps the heading
    rig.select("a link")
    rig.view.deleteBackward(nil)               // the whole link goes, with its address
    rig.caret(after: "Last line.")
    rig.type(" More.")
    let final = rig.draft.markdown
    XCTAssertEqual(final, "# Headline\n\nOne sentence.  and  end.\n\n- first item\n- second *item*\n\n1. one\n2. two\n\nLast line. More.")
    var steps = 0
    while rig.view.undoManager?.canUndo == true, steps < 20 { rig.view.undoManager?.undo(); steps += 1 }
    XCTAssertEqual(rig.draft.markdown, Self.rich, "undo all the way back is the original, byte for byte")
    XCTAssertEqual(rig.view.string, FormattedMarkdownEditModel(markdown: Self.rich).rendered().string)
    while rig.view.undoManager?.canRedo == true { rig.view.undoManager?.redo() }
    XCTAssertEqual(rig.draft.markdown, final)
    XCTAssertEqual(rig.counter.unsupported, 0)
  }

  func testSavingWithoutChangesLeavesTheFileByteForByteAndEditorFitsTheViewport() async throws {
    let markdown = Self.rich + "\n"
    let rig = try await makeRig(markdown)
    XCTAssertFalse(rig.draft.hasEdits)
    await rig.draft.confirm(store: rig.store)
    let onDisk = try await disk(rig)
    XCTAssertEqual(onDisk, markdown, "headings, bold, links, lists and the final newline survive a round trip")
    // The caret and selection are readable on the presenter's dark page, whatever the Mac's appearance.
    XCTAssertEqual(rig.view.insertionPointColor.alphaComponent, 1)
    XCTAssertNotEqual(rig.view.insertionPointColor, .black)
    // The text fills the pane, so a click or drag below a short script is still in the text.
    let clip = try XCTUnwrap(rig.view.enclosingScrollView).contentView.bounds
    XCTAssertGreaterThanOrEqual(rig.view.frame.height, clip.height)
  }

  // MARK: Saving, cancelling, syncing

  func testSaveWritesTheMarkdownFileAndKeepsFormattingAroundTheEdit() async throws {
    let rig = try await makeRig()
    rig.select("sentence")
    rig.type("line")
    rig.select("second item")
    rig.type("final point")
    rig.caret(after: "Last line.")
    rig.type(" Thanks for watching.")
    await rig.draft.confirm(store: rig.store)
    XCTAssertNil(rig.draft.errorMessage)
    XCTAssertFalse(rig.draft.isEditing)
    // Headings, bold, the link and both lists are byte for byte as they were. "second item" was
    // typed over as a whole, so the italic that covered half of it goes with it.
    let expected = Self.rich
      .replacingOccurrences(of: "One sentence.", with: "One line.")
      .replacingOccurrences(of: "second *item*", with: "final point")
      .replacingOccurrences(of: "Last line.", with: "Last line. Thanks for watching.")
    let onDisk = try await disk(rig)
    XCTAssertEqual(onDisk, expected)
    XCTAssertEqual(rig.draft.markdown, expected)
    XCTAssertEqual(rig.counter.unsupported, 0)
  }

  func testPresenterEditShowsInTheLibraryAtOnceAndKeepsTheReadingAnchor() async throws {
    let rig = try await makeRig(seekTo: "bold")
    let anchor = try XCTUnwrap(rig.store.session.activeToken).normalised
    rig.select("Title")
    rig.type("Headline")
    rig.select("first item")
    rig.type("opening item")
    await rig.draft.confirm(store: rig.store)
    XCTAssertNil(rig.draft.errorMessage)
    let saved = try await rig.store.library!.read(rig.record.id)
    XCTAssertEqual(saved.markdown, rig.draft.markdown)
    XCTAssertEqual(rig.store.scripts.first { $0.id == rig.record.id }?.markdown, saved.markdown, "the library list has it at once")
    XCTAssertEqual(rig.store.selected?.markdown, saved.markdown, "and so does the library editor's script")
    XCTAssertEqual(FormattedMarkdownEditModel(markdown: saved.markdown).rendered().string.hasPrefix("Headline\n\nOne sentence."), true)
    XCTAssertEqual(rig.store.session.document.markdown, saved.markdown, "the presenter reads the new text")
    XCTAssertEqual(rig.store.session.activeToken?.normalised, anchor, "the reading anchor stayed on the same word")
    XCTAssertNil(rig.store.session.anchorNotice)
    let flushed = await rig.store.flushPendingSaves()
    XCTAssertTrue(flushed)
  }

  func testCancelRestoresTheScriptExactlyAndReopeningStartsFromTheFile() async throws {
    let rig = try await makeRig()
    rig.view.selectAll(nil)
    rig.type("Throw this away")
    XCTAssertTrue(rig.draft.hasEdits)
    rig.draft.requestCancel()
    XCTAssertTrue(rig.draft.closeRequested, "typed edits are confirmed before they are discarded")
    rig.draft.discardAndClose()
    XCTAssertFalse(rig.draft.isEditing)
    let onDisk = try await disk(rig)
    XCTAssertEqual(onDisk, Self.rich, "the file was never touched")
    XCTAssertEqual(rig.store.selected?.markdown, Self.rich)
    rig.draft.begin(session: rig.store.session)
    XCTAssertEqual(rig.draft.markdown, Self.rich)
    XCTAssertFalse(rig.draft.hasEdits)
  }

  /// Root cause: a file changed by Obsidian while the presenter edit was open could only be
  /// kept or lost (Save as Separate Script). Changes to different lines now merge into the draft.
  func testExternalChangeToAnotherLineMergesIntoTheOpenEditWithoutLosingTyping() async throws {
    let rig = try await makeRig(linked: true)
    let file = try XCTUnwrap(rig.file)
    rig.select("sentence")
    rig.type("line")
    let typed = rig.draft.markdown
    XCTAssertTrue(typed.contains("One line."))
    // Obsidian saves a change to the last line.
    let external = Self.rich.replacingOccurrences(of: "Last line.", with: "Last line, rewritten in Obsidian.")
    try Data(external.utf8).write(to: file, options: .atomic)
    await rig.store.refreshExternalChanges()
    for _ in 0..<20 where !rig.draft.markdown.contains("Obsidian") {
      try? await Task.sleep(for: .milliseconds(20))
      await rig.settle()
    }
    XCTAssertTrue(rig.draft.markdown.contains("One line."), "the typing is still there")
    XCTAssertTrue(rig.draft.markdown.contains("rewritten in Obsidian"), "the outside change joined it")
    XCTAssertTrue(rig.view.string.contains("One line.") && rig.view.string.contains("rewritten in Obsidian"), "and the editor shows both")
    XCTAssertNotNil(rig.draft.noticeMessage)
    XCTAssertFalse(rig.draft.hasExternalChange(in: rig.store), "so saving is not a conflict")
    await rig.draft.confirm(store: rig.store)
    XCTAssertNil(rig.draft.errorMessage)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), typed.replacingOccurrences(of: "Last line.", with: "Last line, rewritten in Obsidian."))
    await rig.store.refreshExternalChanges()
    XCTAssertNil(rig.store.errorMessage)
  }

  func testExternalChangeWithNoTypingJustUpdatesTheEditorAndASameLineConflictKeepsTheDraft() async throws {
    let rig = try await makeRig(linked: true)
    let file = try XCTUnwrap(rig.file)
    // Nothing typed yet: the editor follows the file.
    let first = Self.rich.replacingOccurrences(of: "Last line.", with: "Last line, first outside edit.")
    try Data(first.utf8).write(to: file, options: .atomic)
    await rig.store.refreshExternalChanges()
    for _ in 0..<20 where rig.draft.markdown != first { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(rig.draft.markdown, first)
    XCTAssertNil(rig.draft.noticeMessage, "no typing, nothing to merge")
    await rig.settle()
    XCTAssertTrue(rig.view.string.contains("first outside edit"))
    // Typing on the same line as an outside change cannot be merged: the draft is kept, and saving refuses.
    rig.select("outside edit")
    rig.type("inside edit")
    let mine = rig.draft.markdown
    let second = first.replacingOccurrences(of: "first outside edit", with: "second outside edit")
    try Data(second.utf8).write(to: file, options: .atomic)
    await rig.store.refreshExternalChanges()
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(rig.draft.markdown, mine, "typing is never replaced")
    XCTAssertTrue(rig.draft.hasExternalChange(in: rig.store))
    await rig.draft.confirm(store: rig.store)
    XCTAssertNotNil(rig.draft.errorMessage)
    XCTAssertTrue(rig.draft.isEditing, "the editor stays open with the draft")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), second, "the outside version is not overwritten")
  }

  func testLibraryEditorTypingWhileThePresenterEditIsOpenMergesToo() async throws {
    let rig = try await makeRig()
    rig.select("first item")
    rig.type("opening item")
    // Typed in the library editor at the same time, on a different line.
    rig.store.updateMarkdown(Self.rich.replacingOccurrences(of: "Last line.", with: "Last line (library)."), for: rig.record.id)
    for _ in 0..<20 where !rig.draft.markdown.contains("(library)") { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(rig.draft.markdown.contains("opening item") && rig.draft.markdown.contains("(library)"))
    await rig.draft.confirm(store: rig.store)
    XCTAssertNil(rig.draft.errorMessage)
    let flushed = await rig.store.flushPendingSaves()
    XCTAssertTrue(flushed)
    let onDisk = try await disk(rig)
    XCTAssertTrue(onDisk.contains("opening item") && onDisk.contains("(library)"), onDisk)
  }

  func testLineMergeKeepsBothSidesOrReportsAClash() {
    let base = "a\nb\nc\nd\ne"
    XCTAssertEqual(LineMerge.merge(base: base, mine: "a\nB\nc\nd\ne", theirs: "a\nb\nc\nd\nE"), "a\nB\nc\nd\nE")
    XCTAssertEqual(LineMerge.merge(base: base, mine: "a\nb\nc\nd\ne", theirs: "a\nb\nc\nnew\nd\ne"), "a\nb\nc\nnew\nd\ne", "untouched draft follows the file")
    XCTAssertEqual(LineMerge.merge(base: base, mine: "x\na\nb\nc\nd\ne", theirs: "a\nb\nc\nd\ne\ny"), "x\na\nb\nc\nd\ne\ny", "insertions at both ends")
    XCTAssertEqual(LineMerge.merge(base: base, mine: "a\nb\nc\nd", theirs: "a\nb\nc\nd\ne\nf"), nil, "a deleted line touching an added one")
    XCTAssertNil(LineMerge.merge(base: base, mine: "a\nB\nc\nd\ne", theirs: "a\nBB\nc\nd\ne"), "same line changed twice")
    XCTAssertEqual(LineMerge.merge(base: base, mine: "a\nB\nc\nd\ne", theirs: "a\nB\nc\nd\ne"), "a\nB\nc\nd\ne", "same change on both sides")
    XCTAssertEqual(LineMerge.merge(base: "x\n", mine: "x\nmine\n", theirs: "x\n"), "x\nmine\n")
    XCTAssertEqual(LineMerge.merge(base: "", mine: "typed", theirs: ""), "typed")
  }
}
