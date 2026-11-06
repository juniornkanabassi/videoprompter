import AppKit
import PrompterCore
import SwiftUI
import XCTest

@testable import VideoPrompter

/// The presenter bar keeps the camera picker and Framing guides reachable while the camera is on,
/// hidden while it is off, with grouped controls inside the presenter. Offscreen
/// fixture camera only: `startsCamera: false`, and no window is ordered in.
@MainActor final class PresenterBarTests: XCTestCase {
  override func setUp() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
  }
  private func elements(_ element: Any) -> [NSObject] {
    guard let object = element as? NSObject else { return [] }
    let selector = NSSelectorFromString("accessibilityChildren")
    let children = object.responds(to: selector)
      ? object.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
    return [object] + (children.isEmpty ? (object as? NSView)?.subviews ?? [] : children).flatMap(elements)
  }

  private func button(_ label: String, in host: NSView) throws -> NSObject {
    try XCTUnwrap(elements(host).first { object in
      let role = NSSelectorFromString("accessibilityRole")
      guard object.responds(to: role),
        let value = object.perform(role)?.takeUnretainedValue() as? String,
        ["AXButton", "AXMenuButton", "AXPopUpButton"].contains(value) else { return false }
      return ["accessibilityLabel", "accessibilityTitle"].contains { name in
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        let value = object.perform(selector)?.takeUnretainedValue()
        return (value as? String ?? (value as? NSAttributedString)?.string) == label
      }
    }, "The bar has no \(label) button. AX: \(elements(host).compactMap { self.label($0, "accessibilityLabel") ?? self.label($0, "accessibilityTitle") })")
  }

  private func frame(_ object: NSObject) throws -> NSRect {
    try XCTUnwrap(object.value(forKey: "accessibilityFrame") as? NSValue).rectValue
  }

  private func isEnabled(_ object: NSObject) throws -> Bool {
    // SwiftUI's virtual accessibility nodes implement this getter without adopting the protocol.
    let selector = NSSelectorFromString("isAccessibilityEnabled")
    guard object.responds(to: selector) else {
      XCTFail("Missing enabled getter on \(type(of: object))")
      throw NSError(domain: "PresenterBarTests", code: 1)
    }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
  }

  private func label(_ object: NSObject, _ name: String) -> String? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    let value = object.perform(selector)?.takeUnretainedValue()
    return value as? String ?? (value as? NSAttributedString)?.string
  }
  private func has(_ name: String, in host: NSView) -> Bool {
    elements(host).contains { label($0, "accessibilityLabel") == name || label($0, "accessibilityTitle") == name }
  }
  private func insideScrollView(_ node: NSObject) -> Bool {
    var current: NSObject? = node
    var seen = Set<ObjectIdentifier>()
    while let object = current, seen.insert(ObjectIdentifier(object)).inserted {
      if object is NSScrollView || label(object, "accessibilityRole") == "AXScrollArea" { return true }
      let getter = NSSelectorFromString("accessibilityParent")
      current = object.responds(to: getter) ? object.perform(getter)?.takeUnretainedValue() as? NSObject : nil
    }
    return false
  }

  func testTransportMatrixAtEveryZoomAndState() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("TransportMatrix")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Transport", markdown: String(repeating: "Read these words. ", count: 100))
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.recordingReadyOverride = true
    let recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    let host = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, monitor: ReferenceMonitor(), startsCamera: false, recorder: recorder))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    defer { store.session.pause(); window.contentView = nil; window.close() }
    func settle() async { for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for mode in PresenterDisplayMode.allCases {
        camera.displayMode = mode
        for state in ["idle", "reading", "recording"] {
          store.session.pause(); recorder.phase = state == "recording" ? .recording : .idle
          if state == "reading" { store.session.play() }
          await settle()
          let reading = mode != .videoOnly
          let action = mode == .prompterOnly ? "Show camera" : state == "recording" ? "Stop recording" : "Record"
          let recordButton = try button(action, in: host)
          XCTAssertTrue(try isEnabled(recordButton))
          let recordRect = try frame(recordButton)
          XCTAssertTrue(window.convertToScreen(host.bounds).contains(recordRect), "\(zoom) \(mode) \(state): \(action) \(recordRect)")
          XCTAssertFalse(insideScrollView(recordButton))
          if reading {
            let readButton = try button(state == "reading" ? "Pause" : "Start reading", in: host)
            XCTAssertEqual(try frame(readButton).midY, recordRect.midY, accuracy: 1)
            XCTAssertFalse(insideScrollView(readButton))
          } else { XCTAssertFalse(has("Start reading", in: host)); XCTAssertFalse(has("Pause", in: host)) }
          _ = try button("More presenter options", in: host)
          XCTAssertEqual(has("Text", in: host), reading, "Named tools stay on the reading surface")
          if zoom == 2 && state == "recording" {
            let bar = try XCTUnwrap(elements(host).first { label($0, "accessibilityIdentifier") == "presenter-control-bar" })
            XCTAssertLessThanOrEqual(try frame(bar).height, 280)
          }
        }
      }
    }
    recorder.phase = .idle; store.session.pause(); camera.displayMode = .prompterWithVideo
    store.settings.mode = "Manual"
    store.session.updateSettings(store.settings)
    store.session.play()
    camera.cleanView = true
    let position = store.session.tokenIndex
    await settle()
    _ = try button("Record", in: host); _ = try button("Exit clean view", in: host)
    XCTAssertFalse(has("Presenter script", in: host))
    XCTAssertTrue(store.session.isActivelyRunning, "Clean view must preserve reading")
    _ = try button("Pause", in: host)
    camera.cleanView = false; await settle()
    XCTAssertGreaterThanOrEqual(store.session.tokenIndex, position, "Reading continues through Clean view; it must not reset")
    XCTAssertTrue(store.session.isActivelyRunning)
    store.session.pause()
    recorder.phase = .waitingForFrames
    await settle()
    XCTAssertFalse(has("REC 00:00", in: host))
    _ = try button("Cancel preparation", in: host)
  }

  func testMoreControlsAndExposureStates() async throws {
    _ = NSApplication.shared
    let defaults = freshDefaults("MoreControls")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "More", markdown: "Read these words.")
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults); camera.displayMode = .prompterWithVideo
    camera.recordingReadyOverride = true
    let recorder = CameraRecorder(defaults: defaults); recorder.phase = .recording
    let host = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, monitor: ReferenceMonitor(), startsCamera: false, recorder: recorder))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 2400, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
    defer { window.contentView = nil; window.close() }
    func settle() async { for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }
    await settle()
    _ = try button("More presenter options", in: host)
    XCTAssertFalse(has("View", in: host))
    XCTAssertTrue(has("Text", in: host))
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(LibraryAX.bool(try button("Exposure settings", in: host), "accessibilityPerformPress"))
    await settle()
    let popover = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible && $0.contentView.map { !LibraryAX.named("Zebras", in: $0).isEmpty } == true })
    let content = try XCTUnwrap(popover.contentView)
    for (title, read) in [("Zebras", { camera.guides.zebras }), ("False colour", { camera.guides.falseColour })] {
      XCTAssertFalse(read())
      let toggle = try XCTUnwrap(LibraryAX.named(title, in: content).first { LibraryAX.value($0, "accessibilityRole") == "AXCheckBox" })
      _ = LibraryAX.bool(toggle, "accessibilityPerformPress")
      await settle()
      XCTAssertTrue(read(), "The real \(title) toggle changes the camera guides during a take")
    }
    XCTAssertTrue(LibraryAX.bool(try button("Exposure settings", in: host), "accessibilityPerformPress"))
    await settle()
    XCTAssertEqual(recorder.phase, .recording)
  }

  func testEverySettingsPageHasAnEnabledSetting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("RealSettings")))
    let host = NSHostingView(rootView: SettingsPage(store: store, tab: .general))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 1000), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
    defer { window.contentView = nil; window.close() }
    for tab in SettingsTab.allCases {
      host.rootView = SettingsPage(store: store, tab: tab)
      for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      let controls = elements(host).filter { node in
        ["AXCheckBox", "AXSlider", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXButton"].contains(label(node, "accessibilityRole") ?? "")
      }
      XCTAssertTrue(controls.contains { (try? isEnabled($0)) == true }, "\(tab) needs a real enabled setting")
    }
  }

  func testCompactWindowKeeps65PercentForReadingIncludingWarnings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("R8ReadingBudget")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Retake", markdown: String(repeating: "Read these words. ", count: 200))
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults); camera.displayMode = .prompterWithVideo
    camera.recordingReadyOverride = true
    let recorder = CameraRecorder(defaults: defaults)
    let draft = PresenterDraft(record: record)
    let host = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 720, height: 520), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
    defer { store.session.pause(); window.contentView = nil; window.close() }
    func settle() async { for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    var evidence: [[String: Any]] = []
    var baseSize = NSSize.zero
    for zoom in AppStore.uiZoomSteps {
      store.uiZoom = zoom
      for state in ["idle", "countdown", "reading", "waiting", "recording", "warning", "warning-both", "warning-and-notice"] {
        store.session.pause(); recorder.phase = .idle; recorder.savedTake = nil; recorder.droppedAudioBuffers = 0; draft.noticeMessage = nil
        if state == "countdown" { store.session.countdownTick = .seconds(60); store.session.startReading() }
        if state == "reading" { store.session.play(captureAudio: false) }
        if state == "waiting" { recorder.phase = .waitingForFrames }
        if state == "recording" { recorder.phase = .recording }
        if state.hasPrefix("warning") {
          recorder.savedTake = URL(fileURLWithPath: "/tmp/Opening take 03.mov")
          recorder.droppedFrames = 7
        }
        if state == "warning-both" { recorder.droppedAudioBuffers = 4 }
        if state == "warning-and-notice" { draft.noticeMessage = "This script changed outside Video Prompter. Review the new wording before recording another take." }
        await settle()
        let script = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first)
        let viewport = try XCTUnwrap(script.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(viewport.frame.height, 338, "\(zoom) \(state): script viewport \(viewport.frame)")
        let bar = try XCTUnwrap(elements(host).first { label($0, "accessibilityIdentifier") == "presenter-control-bar" })
        XCTAssertLessThanOrEqual(try frame(bar).height, 182, "\(zoom) \(state)")
        _ = try button("More presenter options", in: host)
        let start = try button(state == "countdown" ? "Cancel countdown" : state == "reading" ? "Pause" : "Start reading", in: host)
        let target = try frame(start)
        XCTAssertGreaterThanOrEqual(target.height, 24 * zoom - 1)
        if state == "idle" {
          if zoom == 1 { baseSize = target.size }
          XCTAssertEqual(target.width, baseSize.width * zoom, accuracy: 1)
          XCTAssertEqual(target.height, baseSize.height * zoom, accuracy: 1)
        }
        evidence.append(["zoom": zoom, "state": state, "controlWidth": target.width, "controlHeight": target.height,
                         "scriptHeight": viewport.frame.height, "windowHeight": 520, "readingFraction": viewport.frame.height / 520])
        if state == "idle" {
          XCTAssertFalse(has("Resolution pending camera", in: host))
        }
        if state.hasPrefix("warning") {
          let saved = try button("Saved with problems", in: host)
          XCTAssertTrue((label(saved, "accessibilityValue") ?? "").contains("Opening take 03.mov"))
          XCTAssertTrue(window.convertToScreen(host.bounds).contains(try frame(saved)))
          _ = try button("Show in Finder", in: host)
        }
        recorder.droppedFrames = 0
      }
      // A paused mid-script retake is one press and never changes recording state.
      store.session.seek(to: 10); recorder.phase = .recording
      await settle()
      if let reset = LibraryAX.named("Back to start", in: host).first {
        XCTAssertTrue(LibraryAX.bool(reset, "accessibilityPerformPress"))
      } else {
        _ = try button("More presenter options", in: host)
        store.session.restart() // The same action remains in More at widths that cannot fit it.
      }
      await settle()
      XCTAssertEqual(store.session.tokenIndex, 0)
      XCTAssertEqual(recorder.phase, .recording)
    }
    recorder.phase = .idle; camera.recordingReadyOverride = false
    await settle()
    XCTAssertFalse(try isEnabled(button("Record", in: host)))
    _ = try button("More presenter options", in: host)
    XCTAssertEqual(PresenterView.controlZoom(2), 2)
    if let path = ProcessInfo.processInfo.environment["VIDEOPROMPTER_LAYOUT_EVIDENCE"] {
      try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
  }

}
