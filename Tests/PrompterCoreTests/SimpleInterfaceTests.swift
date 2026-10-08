import AppKit
import SwiftUI
import PrompterCore
import XCTest
@testable import VideoPrompter


@MainActor
private func labels(_ element: Any) -> [String] {
  guard let object = element as? NSObject else { return [] }
  func attribute(_ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
  }
  let own = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { attribute($0).map { String(describing: $0) } }.joined(separator: " ")
  let children = attribute("accessibilityChildren") as? [Any] ?? (object.accessibilityAttributeValue(.children) as? [Any] ?? [])
  let viewChildren = (object as? NSView)?.subviews ?? []
  return [own] + (children.isEmpty ? viewChildren.flatMap(labels) : children.flatMap(labels))
}

@MainActor
private func accessibilityObjects(_ element: Any) -> [NSObject] {
  guard let object = element as? NSObject else { return [] }
  let selector = NSSelectorFromString("accessibilityChildren")
  let children = object.responds(to: selector)
    ? object.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
  let fallback = object.accessibilityAttributeValue(.children) as? [Any] ?? (object as? NSView)?.subviews ?? []
  return [object] + (children.isEmpty ? fallback : children).flatMap(accessibilityObjects)
}

@MainActor final class SimpleInterfaceTests: XCTestCase {
  func testPresenterSingleRowIsCentredAt100And150AndReportsEditing() async throws {
    _ = NSApplication.shared
    try XCTSkipIf(CameraModel.shared.presentsWithVideo, "video on would open a camera from a test")
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    OffscreenPanels.install()
    defer { OffscreenPanels.uninstall() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bar-centre-\(UUID())")
    let suite = "BarCentre.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Centred", markdown: "Opening words.\n\nAnother passage.")
    await store.reload()
    store.selectedID = record.id
    let controller = PresenterController()
    controller.present(store: store)
    defer { controller.closeNow() }
    let panel = try XCTUnwrap(controller.panel)
    let content = try XCTUnwrap(panel.contentView)
    func settle() async { for _ in 0..<8 { content.layoutSubtreeIfNeeded(); panel.display(); try? await Task.sleep(for: .milliseconds(30)) } }
    func buttonFrame(_ label: String) throws -> NSRect {
      let object = try XCTUnwrap(accessibilityObjects(content).first { object in
        let selector = NSSelectorFromString("accessibilityRole")
        guard object.responds(to: selector), object.perform(selector)?.takeUnretainedValue() as? String == "AXButton" else { return false }
        return labels(object).first?.contains(label) == true
      }, "Missing \(label)")
      return try XCTUnwrap(object.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    }
    for scale in [1.0, 1.5] {
      store.uiZoom = scale
      panel.setContentSize(NSSize(width: 760, height: 520))
      await settle()
      let start = try buttonFrame("Start")
      let close = try buttonFrame("Close presenter")
      let restart = try buttonFrame("Back to start")
      let edit = try buttonFrame("Edit script")
      // The fixed-width status pill plus the existing row spacing precedes Start.
      let left = start.minX - (88 + 16 + 8) * scale
      XCTAssertEqual((left + close.maxX) / 2, panel.frame.midX, accuracy: 2, "\(scale): the row is centred")
      for frame in [close, restart, edit] {
        XCTAssertEqual(frame.midY, start.midY, accuracy: 2, "\(scale): all controls stay in one row")
      }
    }
    let draft = try XCTUnwrap(Mirror(reflecting: controller).descendant("draft") as? PresenterDraft)
    draft.begin(session: store.session)
    await settle()
    let rendered = labels(content).joined(separator: "|")
    XCTAssertTrue(rendered.contains("Editing"))
    XCTAssertFalse(rendered.contains("Paused"))
    draft.cancel(resuming: false)
  }

  func testMenuTrashYieldsToScriptAndNativeTitleAndTagsFieldEditors() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-trash-\(UUID())")
    let suite = "MenuTrash.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let library = try XCTUnwrap(store.library)
    let record = try await library.create(title: "Keep", markdown: "Keep these words")
    await store.reload()
    store.selectedIDs = [record.id]
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    defer { window.contentView = nil }
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    editor.isEditable = true
    window.contentView = editor
    XCTAssertTrue(window.makeFirstResponder(editor))
    XCTAssertFalse(AppStore.canTrashSelection(in: window))
    store.trashSelectionFromMenu(in: window)
    for name in ["Title", "Add tags"] {
      let field = NSTextField(string: name)
      field.isEditable = true
      window.makeFirstResponder(nil)
      let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
      window.contentView = container
      container.addSubview(field)
      let fieldEditor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
      fieldEditor.frame = NSRect(x: 0, y: 50, width: 400, height: 100)
      container.addSubview(fieldEditor)
      fieldEditor.isEditable = true
      XCTAssertTrue(fieldEditor.isFieldEditor)
      XCTAssertTrue(window.makeFirstResponder(fieldEditor))
      XCTAssertTrue(window.firstResponder === fieldEditor)
      XCTAssertFalse(AppStore.canTrashSelection(in: window), "\(name) keeps its native field editor")
      store.trashSelectionFromMenu(in: window)
    }
    let untouched = await library.listTrash()
    XCTAssertTrue(untouched.isEmpty)
    XCTAssertEqual(store.scripts.map(\.id), [record.id])
    window.makeFirstResponder(nil)
    XCTAssertTrue(AppStore.canTrashSelection(in: window))
    store.trashSelectionFromMenu(in: window)
    for _ in 0..<50 where !store.scripts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(store.scripts.isEmpty)
    let deleted = await library.listTrash()
    XCTAssertEqual(deleted.map(\.id), [record.id])
  }

  func testImportMenusShareAShortcutDistinctFromNativeItalic() {
    XCTAssertEqual(ScriptShortcuts.importFile.key, KeyEquivalent("i"))
    XCTAssertEqual(ScriptShortcuts.importFile.modifiers, [.command, .shift])
    XCTAssertEqual(ScriptShortcuts.italic.key, KeyEquivalent("i"))
    XCTAssertEqual(ScriptShortcuts.italic.modifiers, .command)
    XCTAssertNotEqual(ScriptShortcuts.importFile.modifiers, ScriptShortcuts.italic.modifiers)
  }

  func testContextMoveAndTrashKeepBulkSelectionOnlyForASelectedTarget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-scope-\(UUID())")
    let suite = "ContextScope.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let library = try XCTUnwrap(store.library)
    let folder = try await library.createFolder(name: "Moved")
    let first = try await library.create(title: "First", markdown: "First words")
    let second = try await library.create(title: "Second", markdown: "Second words")
    let outside = try await library.create(title: "Outside", markdown: "Outside words")
    await store.reload()
    store.selectedIDs = [first.id, second.id]
    XCTAssertEqual(store.contextSelection(for: first.id), [first.id, second.id])
    XCTAssertEqual(store.contextSelection(for: outside.id), [outside.id])
    store.moveSelectedScripts(store.contextSelection(for: first.id), to: folder.id)
    for _ in 0..<50 where store.scripts.first(where: { $0.id == second.id })?.metadata.folderID != folder.id {
      try await Task.sleep(for: .milliseconds(10))
    }
    let movedFirst = try await library.read(first.id)
    let movedSecond = try await library.read(second.id)
    let unmovedOutside = try await library.read(outside.id)
    XCTAssertEqual(movedFirst.metadata.folderID, folder.id)
    XCTAssertEqual(movedSecond.metadata.folderID, folder.id)
    XCTAssertNil(unmovedOutside.metadata.folderID)
    store.moveSelectedScripts(store.contextSelection(for: outside.id), to: folder.id)
    for _ in 0..<50 where store.scripts.first(where: { $0.id == outside.id })?.metadata.folderID != folder.id {
      try await Task.sleep(for: .milliseconds(10))
    }
    let movedOutside = try await library.read(outside.id)
    XCTAssertEqual(movedOutside.metadata.folderID, folder.id)
    store.delete(store.contextSelection(for: outside.id))
    for _ in 0..<50 where store.scripts.contains(where: { $0.id == outside.id }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(Set(store.scripts.map(\.id)), [first.id, second.id])
    let singletonTrash = await library.listTrash()
    XCTAssertEqual(Set(singletonTrash.map(\.id)), [outside.id])
    store.delete(store.contextSelection(for: first.id))
    for _ in 0..<50 where !store.scripts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(store.scripts.isEmpty)
    let bulkTrash = await library.listTrash()
    XCTAssertEqual(Set(bulkTrash.map(\.id)), [first.id, second.id, outside.id])
  }

  func testPublicRenameRetainsLegacyIsolatedPreferences() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-suite-\(UUID())")
    let suite = "VidPrompt.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var settings = PrompterSettings()
    settings.fontSize = 61
    defaults.set(try JSONEncoder().encode(settings), forKey: "settings")
    defaults.set(false, forKey: "simpleInterface")
    defaults.set(1.5, forKey: "uiZoom")
    defaults.set("remembered-camera", forKey: "cameraDeviceUID")
    let arguments = ["test", "--data-directory", root.path]
    let store = AppStore(arguments: arguments)
    XCTAssertEqual(store.settings.fontSize, 61)
    XCTAssertEqual(store.uiZoom, 1.5)
    XCTAssertFalse(store.simpleInterface)
    XCTAssertEqual(CameraModel(defaults: AppStore.preferences(arguments: arguments)).selectedUID, "remembered-camera")
    store.previewFontSize = 27
    XCTAssertEqual(AppStore(arguments: arguments).previewFontSize, 27)
    XCTAssertTrue(AppStore.preferences(arguments: ["test"]) === UserDefaults.standard)
  }

  func testScriptSwitchingInitialisesMountedEditorStateAndKeepsEditsIsolated() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-ui-\(UUID())")
    let suite = "VideoPrompter.Switch.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let alpha = try await store.library!.create(title: "Alpha title", markdown: "**Alpha** body", tags: ["alpha-tag"])
    let beta = try await store.library!.create(title: "Beta title", markdown: "**Beta** body", tags: ["beta-tag"])
    await store.reload()
    store.selectedID = alpha.id
    let host = NSHostingView(rootView: LibraryView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1132, height: 750), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = host
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async {
      for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
    }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    for record in [alpha, beta, alpha] {
      store.selectedID = record.id
      await settle()
      let editor = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first)
      XCTAssertEqual(editor.string, record.id == alpha.id ? "Alpha body" : "Beta body")
      let fields = views(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
      XCTAssertTrue(fields.contains { $0.stringValue == record.metadata.title }, "selected title")
      XCTAssertTrue(fields.contains { $0.stringValue == record.metadata.tags.joined(separator: ", ") }, "selected tags")
      XCTAssertFalse(editor.undoManager?.canUndo ?? false, "switching resets native undo")
      if record.id == beta.id {
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("!", replacementRange: editor.selectedRange())
        await settle()
        let flushed = await store.flushPendingSaves()
        XCTAssertTrue(flushed)
      }
    }
    let savedAlpha = try await store.library!.read(alpha.id)
    let savedBeta = try await store.library!.read(beta.id)
    XCTAssertEqual(savedAlpha.markdown, alpha.markdown)
    XCTAssertEqual(savedBeta.markdown, "**Beta** body!")
  }

  func testEmptyLibraryExplainsTheStepsAndOffersBothCreationActions() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("empty-ui-\(UUID())")
    let suite = "VidPrompt.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))"
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    let store = AppStore(arguments: ["test", "--data-directory", root.path])
    let host = NSHostingView(rootView: LibraryView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1132, height: 750), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
    for zoom in [1.0, 1.5, 2.0] {
    store.uiZoom = zoom
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
    let rendered = labels(host).joined(separator: "|")
    for text in ["Your script, ready to read", "Add a script", "Choose Voice or Manual in Settings", "Press Present", "Import Script", "New Script"] {
      XCTAssertTrue(rendered.contains(text), "Missing first-use guidance: \(text)")
    }
    }
    // Geometry, not just AX presence: the whole guide stays inside the 200% detail column.
    let guidance = try XCTUnwrap(accessibilityObjects(host).first {
      labels($0).first?.contains("Add a script.") == true
    })
    XCTAssertTrue(guidance.responds(to: NSSelectorFromString("accessibilityFrame")))
    let frame = try XCTUnwrap(guidance.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    let guideFrame = window.convertFromScreen(frame)
    XCTAssertGreaterThanOrEqual(guideFrame.minX, 400, "guide stays to the right of the zoomed sidebar")
    XCTAssertLessThanOrEqual(guideFrame.maxX, 813, "guide stays to the left of the inspector")
    XCTAssertGreaterThan(frame.height, 100, "all steps wrap into a readable column")
    store.create()
    for _ in 0..<20 where store.selected == nil { try? await Task.sleep(for: .milliseconds(30)) }
    XCTAssertNotNil(store.selected, "New Script creates and selects a script")
  }

  func testPreferencePersistsPerDataDirectoryAndInspectorHidesOnlyAdvancedSections() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simple-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let arguments = ["test", "--data-directory", root.path]
    let otherRoot = root.appendingPathComponent("another")
    let otherArguments = ["test", "--data-directory", otherRoot.path]
    defer {
      for directory in [root, otherRoot] {
        let suite = "VidPrompt.\(MarkdownLibrary.fingerprint(directory.standardizedFileURL.path))"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      }
    }
    let store = AppStore(arguments: arguments)
    XCTAssertTrue(store.simpleInterface, "a new data root starts with the simple interface")
    let before = store.settings
    let reopened = AppStore(arguments: arguments)
    XCTAssertTrue(reopened.simpleInterface)
    XCTAssertTrue(reopened.simpleInterface)
    let other = AppStore(arguments: otherArguments)
    XCTAssertTrue(other.simpleInterface)
    XCTAssertTrue(other.simpleInterface)
    let host = NSHostingView(rootView: InspectorView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 1800), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }
    await settle()
    let simple = labels(host).joined(separator: "|")
    XCTAssertTrue(simple.contains("Size")); XCTAssertTrue(simple.contains("How it follows you"))
    XCTAssertFalse(simple.contains("Typography")); XCTAssertFalse(simple.contains("Saved settings"))
    XCTAssertFalse(simple.contains("Microphone volume"))
    XCTAssertFalse(simple.contains("Loudest sound"))
    XCTAssertFalse(simple.contains("Spoken language"))
    XCTAssertTrue(simple.contains("Test"))
    XCTAssertTrue(simple.contains("Microphone peak level"))
    XCTAssertTrue(simple.contains("Mirror for teleprompter glass"))
    store.simpleInterface = false
    XCTAssertTrue(AppStore(arguments: otherArguments).simpleInterface, "the other data directory keeps its own preference")
    XCTAssertFalse(AppStore(arguments: arguments).simpleInterface, "an explicit advanced preference survives reopening")
    await settle()
    let full = labels(host).joined(separator: "|")
    XCTAssertTrue(full.contains("Typography")); XCTAssertTrue(full.contains("Saved settings"))
    XCTAssertTrue(full.contains("Size")); XCTAssertTrue(full.contains("How it follows you"))
    XCTAssertTrue(full.contains("Microphone volume"))
    XCTAssertTrue(full.contains("Loudest sound"))
    XCTAssertTrue(full.contains("Spoken language"))
    store.simpleInterface = true
    XCTAssertTrue(AppStore(arguments: arguments).simpleInterface, "an explicit simple preference survives reopening")
    XCTAssertEqual(store.settings, before)
  }
}
