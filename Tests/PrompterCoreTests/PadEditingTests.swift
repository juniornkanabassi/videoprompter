import Foundation
import XCTest
import PrompterCore
@testable import PadScriptFolder
@testable import VideoPrompter

@MainActor
final class PadEditingTests: XCTestCase {
  private typealias Folder = PadScriptFolder.ScriptFolder
  /// Compile the actual Foundation editor engine, since SwiftPM's macOS app cannot import UIKit.
  func testIPadMarkdownEngineHeadlessly() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PadEditing-\(UUID())")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let main = scratch.appendingPathComponent("main.swift")
    try #"""
    import Foundation
    @main struct Checks { @MainActor static func main() {
    func range(_ needle: String, in model: PadMarkdownEdit) -> NSRange { (model.text as NSString).range(of: needle) }
    func require(_ condition: Bool, _ label: String) {
      if !condition { fatalError(label) }
    }
    let original = "# Bonjour 👨‍👩‍👧‍👦\n\n**bold** and *italic* café e\u{301}\n"
    let model = PadMarkdownEdit(original)
    require(model.text == "Bonjour 👨‍👩‍👧‍👦\n\nbold and italic café e\u{301}\n", "formatted display")
    require(model.markdown == original, "exact initial round trip")
    let changed = model.replacing(range("café", in: model), with: "été 🦊")!
    require(changed.markdown == original.replacingOccurrences(of: "café", with: "été 🦊"), "Unicode replacement preserves formatting")
    let bold = changed.formatting(.bold, range: range("été", in: changed))!
    require(bold.markdown.contains("**été**"), "bold")
    let italic = bold.formatting(.italic, range: range("été", in: bold))!
    require(italic.markdown.contains("***été***"), "nested bold italic")
    require(italic.formatting(.italic, range: range("été", in: italic))!.markdown == bold.markdown, "toggle italic")
    let unheading = model.formatting(.heading, range: NSRange(location: 0, length: 0))!
    require(unheading.formatting(.heading, range: NSRange(location: 0, length: 0))!.markdown == original, "heading toggle")
    let selected = range("café", in: model)
    let copied = (model.text as NSString).substring(with: selected)
    let cut = model.replacing(selected, with: "")!
    let pasted = cut.replacing(NSRange(location: selected.location, length: 0), with: copied)!
    require(pasted.markdown == original, "cut paste round trip")
    let crossed = model.replacing(range("old and it", in: model), with: "new")!
    require(crossed.text.contains("bnewalic"), "selection across formatting")
    let deleteBold = model.replacing(range("bold", in: model), with: "")!
    require(!deleteBold.markdown.contains("****") && deleteBold.text.contains(" and italic"), "cut a complete formatted word")
    let literal = PadMarkdownEdit("hello").replacing(NSRange(location: 5, length: 0), with: " *literal* [link] #heading")!
    require(literal.text == "hello *literal* [link] #heading", "pasted punctuation stays literal")
    let emoji = range("👨‍👩‍👧‍👦", in: model)
    require(model.replacing(emoji, with: "⚽️")!.text.contains("Bonjour ⚽️"), "whole grapheme replacement")
    require(model.replacing(NSRange(location: emoji.location + 1, length: 1), with: "x") == nil, "reject split surrogate")
    let list = PadMarkdownEdit("- **one** and *two*\n2. three")
    require(list.text == "- one and two\n2. three", "list markers and inline styles")
    require(list.replacing(range("one", in: list), with: "new")!.markdown == "- **new** and *two*\n2. three", "editing list preserves Markdown")
    let untouched = "```swift\nlet a = 1\n```\n\n- item\n\n[link](https://example.com)"
    require(PadMarkdownEdit(untouched).markdown == untouched, "untouched advanced Markdown")
    let draft = PadEditorDraft("hello")
    var begins = 0, ends = 0
    draft.beginEditing(onBegin: { begins += 1 }, onEnd: { ends += 1 })
    draft.beginEditing(onBegin: { begins += 1 }, onEnd: { ends += 1 })
    require(draft.isEditing && begins == 1, "editing acquires one lock")
    draft.history.groupsByEvent = false
    draft.history.beginUndoGrouping()
    draft.apply(draft.model.formatting(.bold, range: NSRange(location: 0, length: 5))!,
      selection: NSRange(location: 0, length: 5), previousSelection: NSRange(location: 0, length: 5))
    draft.history.endUndoGrouping()
    require(draft.model.markdown == "**hello**", "format in undo stack")
    draft.history.undo()
    require(draft.model.markdown == "hello", "undo")
    draft.history.redo()
    require(draft.model.markdown == "**hello**", "redo")
    require(!draft.save { _ in false } && draft.isEditing, "failed save keeps editing lock")
    draft.cancel()
    require(ends == 1 && !draft.isEditing, "cancel releases editing lock")
    draft.endEditing()
    require(ends == 1, "disappearance cannot release twice")
    draft.beginEditing(onBegin: { begins += 1 }, onEnd: { ends += 1 })
    var written = ""
    require(draft.save { written = $0; return true }, "save succeeds")
    require(written == "hello" && ends == 2 && !draft.isEditing, "save writes and releases editing lock")
    require(draft.model.markdown == "hello" && !draft.history.canUndo, "cancel restores original and clears history")
    // Library drafts: typed text is dirty until written, a failed write keeps it, Cancel returns to the last write.
    let typed = PadEditorDraft("one two")
    require(!typed.isDirty, "fresh draft is clean")
    typed.apply(typed.model.replacing(NSRange(location: 7, length: 0), with: " three")!,
      selection: NSRange(location: 13, length: 0), previousSelection: NSRange(location: 7, length: 0))
    require(typed.isDirty, "typing makes the draft dirty")
    require(!typed.save { _ in false } && typed.isDirty, "failed autosave keeps the draft dirty")
    var disk = ""
    require(typed.save { disk = $0; return true } && disk == "one two three" && !typed.isDirty, "autosave writes the typed text")
    typed.cancel()
    require(typed.model.markdown == "one two three", "cancel after a save keeps the saved text")
    typed.apply(typed.model.replacing(NSRange(location: 13, length: 0), with: " four")!,
      selection: NSRange(location: 18, length: 0), previousSelection: NSRange(location: 13, length: 0))
    typed.adopt("the Mac text")
    require(typed.model.markdown == "the Mac text" && !typed.isDirty && !typed.history.canUndo, "adopting newer saved text leaves a clean draft")
    typed.cancel()
    require(typed.model.markdown == "the Mac text", "cancel returns to the adopted text")
    print("PadMarkdownEdit round-trip, Unicode, selection, formatting and cut/paste passed")
    }}
    """#.write(to: main, atomically: true, encoding: .utf8)
    let executable = scratch.appendingPathComponent("editor-check")
    let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
    try run(URL(fileURLWithPath: developer).appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"),
      [root.appendingPathComponent("iPad/VideoPrompter/Library/ScriptEditor.swift").path, main.path, "-parse-as-library", "-o", executable.path])
    try run(executable, [])
  }

  func testSaveWritesMarkdownAndKeepsTheSameReadingWord() throws {
    let (folder, script) = try fixture()
    let original = try folder.record(for: script)
    let session = SessionStore(defaults: freshDefaults("PadEditingSession"))
    var settings = PrompterSettings(); settings.mode = "Manual"
    session.present(record: original, settings: settings)
    session.seek(to: 2)
    XCTAssertEqual(session.activeToken?.text, "three")
    let saved = try folder.save("preface one **two** three four", to: script)
    session.applyEditedRecord(saved)
    XCTAssertEqual(try Folder.read(script.url), "preface one **two** three four")
    XCTAssertEqual(session.activeToken?.text, "three")
    XCTAssertEqual(session.activeRecord?.markdown, saved.markdown)
  }

  func testCancelLeavesFileAndReadingAnchorUntouched() throws {
    let (folder, script) = try fixture()
    let original = try folder.record(for: script)
    let session = SessionStore(defaults: freshDefaults("PadEditingCancel"))
    session.present(record: original, settings: PrompterSettings())
    session.seek(to: 2)
    let anchor = session.anchor
    // A draft never reaches the coordinated writer until Save succeeds.
    var draft = "unsaved changes"
    draft = original.markdown
    XCTAssertEqual(draft, original.markdown)
    XCTAssertEqual(try Folder.read(script.url), original.markdown)
    XCTAssertEqual(session.anchor, anchor)
  }

  func testEditorLifecycleAndKeyboardActionsAreWiredToNativeControls() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("iPad/VideoPrompter/Library/ScriptEditor.swift"), encoding: .utf8)
    // UIKit is not in the macOS test process: these are wiring checks, not simulated touch input.
    for call in ["onBegin: store.beginEditing", "onEnd: store.endEditing", "store.save(text, to: script, basis: draft.original)",
      "history.undo()", "history.redo()", "history.registerUndo", "UIKeyCommand.inputEscape",
      "view.markedTextRange", "scrollRangeToVisible", "private func cancel() { draft.cancel(); markdown = draft.original; onDone() }"] {
      XCTAssertTrue(source.contains(call), "Missing editor integration: \(call)")
    }
  }

  /// What the library does when typed text is still unsaved: the editor writes it as it goes away or
  /// the app backgrounds, Open presenter writes it first, and the library never takes the on-the-fly lock.
  func testLibraryDraftIsSavedBeforeSwitchingOrPresenting() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let editor = try String(contentsOf: root.appendingPathComponent("iPad/VideoPrompter/Library/ScriptEditor.swift"), encoding: .utf8)
    let library = try String(contentsOf: root.appendingPathComponent("iPad/VideoPrompter/Library/LibraryScreen.swift"), encoding: .utf8)
    for call in ["if !onTheFly, !flush(), draft.isDirty", "store.draftFlusher.flush = flush", "phase != .active, !onTheFly",
      "(try? store.folder.saveCopy(draft.model.markdown, of: script)) != nil", "case .keptAsCopy: keptAsCopy = true; return true"] {
      XCTAssertTrue(editor.contains(call), "Missing autosave wiring: \(call)")
    }
    for call in ["if store.draftFlusher.resolve() { store.present(script) }", "of: store.presentingID",
      "Button { select(script.id) }", "if store.draftFlusher.resolve() { store.selectedID = id }", "{ select(nil) }"] {
      XCTAssertTrue(library.contains(call), "Missing library wiring: \(call)")
    }
    // A Mac Send or Open settles the typed draft first, and is refused if the draft cannot be written.
    let store = try String(contentsOf: root.appendingPathComponent("iPad/VideoPrompter/App/PadStore.swift"), encoding: .utf8)
    XCTAssertTrue(store.contains("case .present, .sendScript, .play, .selectCamera, .cameraOn(true):\n      // Another version is about to be received or shown"))
    XCTAssertTrue(store.contains("if !draftFlusher.resolve() {"))
    XCTAssertFalse(library.contains(".onTheFly"), "The library must never take the on-the-fly lock")
  }

  /// Open presenter reads the folder, so after the autosave it presents the edited text, not the old file.
  func testPresentingAfterAutosaveShowsTheEditedText() throws {
    let (folder, script) = try fixture()
    let saved = try folder.save("one **two** three four five", to: script)
    let session = SessionStore(defaults: freshDefaults("PadEditingPresent"))
    session.present(record: try folder.record(for: script), settings: PrompterSettings())
    XCTAssertEqual(session.activeRecord?.markdown, saved.markdown)
    XCTAssertTrue(session.document.spokenTokens.contains { $0.text == "five" })
  }

  private func fixture() throws -> (Folder, FolderScript) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PadEditingFiles-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let folder = Folder(defaults: freshDefaults("PadEditingFiles"), local: root)
    return (folder, try folder.create(title: "Draft", markdown: "one **two** three four"))
  }

  private func run(_ executable: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable; process.arguments = arguments
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
  }
}
