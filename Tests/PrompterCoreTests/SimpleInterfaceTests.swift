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

@MainActor private func pressDisclosure(_ label: String, in host: NSView) throws {
  let action = NSSelectorFromString("accessibilityPerformPress")
  let object = try XCTUnwrap(accessibilityObjects(host).first {
    labels($0).first?.contains(label) == true && $0.responds(to: action)
  }, "Missing disclosure: \(label)")
  _ = object.perform(action)
}

@MainActor final class SimpleInterfaceTests: XCTestCase {
  private func cleanUp(_ store: AppStore, suite: String, root: URL) {
    addTeardownBlock { @MainActor in
      await store.flushSettings()
      TestDefaults.remove(suite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  func testPresenterGroupsStayInsideWindowAt100And150AndReportEditing() async throws {
    _ = NSApplication.shared
    try XCTSkipIf(CameraModel.shared.presentsWithVideo, "video on would open a camera from a test")
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    OffscreenPanels.install()
    defer { OffscreenPanels.uninstall() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bar-centre-\(UUID())")
    let suite = "BarCentre.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    cleanUp(store, suite: suite, root: root)
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
      // Wide enough for the restored camera picker and Framing guides to share one row at 150%;
      // narrow-window wrapping is covered by UIZoomTests.
      panel.setContentSize(NSSize(width: 1100, height: 520))
      await settle()
      let start = try buttonFrame("Start reading")
      let close = try buttonFrame("Close presenter")
      let restart = try buttonFrame("Back to start")
      let edit = try buttonFrame("Edit script")
      let reading = try buttonFrame("Reading")
      let recording = try buttonFrame("Record camera")
      let screenBounds = panel.convertToScreen(content.bounds)
      for frame in [start, close, restart, edit, reading, recording] {
        XCTAssertTrue(screenBounds.contains(frame), "\(scale): grouped controls stay inside the presenter")
      }
      XCTAssertEqual(close.midY, edit.midY, accuracy: 2, "Editing and closing share the secondary row")
      XCTAssertGreaterThan(start.midY, close.midY, "Reading sits above secondary actions")
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
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    cleanUp(store, suite: suite, root: root)
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
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    cleanUp(store, suite: suite, root: root)
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

  func testPublicRenameRetainsLegacyIsolatedPreferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-suite-\(UUID())")
    let suite = "VidPrompt.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))"
    removeDefaultsAtTeardown(suite)
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    var settings = PrompterSettings()
    settings.fontSize = 61
    defaults.set(try JSONEncoder().encode(settings), forKey: "settings")
    defaults.set(false, forKey: "simpleInterface")
    defaults.set(1.5, forKey: "uiZoom")
    defaults.set("remembered-camera", forKey: "cameraDeviceUID")
    let arguments = ["test", "--data-directory", root.path]
    let store = AppStore(arguments: arguments)
    cleanUp(store, suite: suite, root: root)
    XCTAssertEqual(store.settings.fontSize, 61)
    XCTAssertEqual(store.uiZoom, 1.5)
    XCTAssertFalse(store.simpleInterface)
    XCTAssertEqual(CameraModel(defaults: AppStore.preferences(arguments: arguments)).selectedUID, "remembered-camera")
    store.previewFontSize = 27
    _ = await store.flushPendingSaves()
    let reopened = AppStore(arguments: arguments)
    XCTAssertEqual(reopened.previewFontSize, 27)
    await reopened.flushSettings()
    XCTAssertTrue(AppStore.preferences(arguments: ["test"]) === UserDefaults.standard)
  }

  func testScriptSwitchingInitialisesMountedEditorStateAndKeepsEditsIsolated() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-ui-\(UUID())")
    let suite = "VideoPrompter.Switch.\(UUID())"
    let defaults = TestDefaults.suite(named: suite)!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    cleanUp(store, suite: suite, root: root)
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
      try pressDisclosure("Script details", in: host)
      await settle()
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
    TestDefaults.record(suite)
    let store = AppStore(arguments: ["test", "--data-directory", root.path])
    cleanUp(store, suite: suite, root: root)
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
    for text in ["Ready when you are", "Paste a Script", "Import a File", "Write a Script", "Camera Only", "Try the Practice Script"] {
      XCTAssertTrue(rendered.contains(text), "Missing first-use guidance: \(text)")
    }
    }
    // Geometry, not just AX presence: the whole guide stays inside the 200% detail column.
    let guidance = try XCTUnwrap(accessibilityObjects(host).first {
      labels($0).first?.contains("Then choose Present") == true
    })
    XCTAssertTrue(guidance.responds(to: NSSelectorFromString("accessibilityFrame")))
    let frame = try XCTUnwrap(guidance.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    let guideFrame = window.convertFromScreen(frame)
    XCTAssertGreaterThanOrEqual(guideFrame.minX, 400, "guide stays to the right of the zoomed sidebar")
    XCTAssertLessThanOrEqual(guideFrame.maxX, window.contentView!.bounds.width, "start screen stays inside the detail column")
    XCTAssertGreaterThan(frame.height, 40, "the next step wraps into a readable column")
    store.create()
    for _ in 0..<20 where store.selected == nil { try? await Task.sleep(for: .milliseconds(30)) }
    XCTAssertNotNil(store.selected, "New Script creates and selects a script")
  }

  func testPreferencesUseSettingsPagesAndInspectorKeepsOnlyPresenterControls() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-ui-\(UUID())")
    let suite = "SettingsUI.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    cleanUp(store, suite: suite, root: root)
    let camera = CameraModel(defaults: defaults)
    let before = store.settings
    let host = NSHostingView(rootView: AnyView(InspectorView(store: store, camera: camera)))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 560, height: 1800), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    func rendered() async -> String {
      for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
      return labels(host).joined(separator: "|")
    }
    let inspector = await rendered()
    for label in ["Reading text size", "Spacing and alignment", "Mirror for teleprompter glass", "Rotation and stage directions"] {
      XCTAssertTrue(inspector.contains(label), label)
    }
    for label in ["Spoken language", "Voice-follow input level", "Saved settings", "How it follows you", "Editor font"] {
      XCTAssertFalse(inspector.contains(label), label)
    }
    store.simpleInterface = false
    _ = await store.flushPendingSaves()
    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertFalse(reopened.simpleInterface)
    await reopened.flushSettings()
    try pressDisclosure("Rotation and stage directions", in: host)
    try pressDisclosure("Reading guide", in: host)
    let advanced = await rendered()
    XCTAssertTrue(advanced.contains("Show stage directions"))
    XCTAssertTrue(advanced.contains("Highlight active word"))
    let expected: [(SettingsTab, [String])] = [
      (.general, ["How it follows you", "Interface size", "Align presenter to screen edges"]),
      (.voice, ["Voice-follow microphone", "Spoken language", "Voice-follow input level", "Loudest sound"]),
      (.editor, ["Editor font", "Editor size"]),
      (.presets, ["Settings name", "Save Settings", "Saved settings"])
    ]
    for (tab, pageLabels) in expected {
      host.rootView = AnyView(SettingsPage(store: store, tab: tab))
      let page = await rendered()
      for label in pageLabels { XCTAssertTrue(page.contains(label), "\(tab): \(label)") }
    }
    XCTAssertEqual(store.settings, before)
  }
}
