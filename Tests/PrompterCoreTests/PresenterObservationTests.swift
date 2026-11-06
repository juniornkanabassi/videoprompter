import AppKit
import SwiftUI
import AVFoundation
import Combine
import Foundation
import PrompterCore
import XCTest
@testable import VideoPrompter

@MainActor
final class PresenterObservationTests: XCTestCase {
  func testInPlaceEditorUpdatesReadThroughAfterSeekWithoutInvalidatingShell() async throws {
    _ = NSApplication.shared
    let suite = "PresenterEditorObservation.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    defer { TestDefaults.remove(suite) }
    let session = SessionStore(defaults: defaults)
    var now = 100.0
    session.clock = { now }
    var settings = PrompterSettings()
    settings.mode = "Manual"
    settings.speed = 60
    settings.fontName = "Helvetica Neue"
    let record = ScriptRecord(metadata: ScriptMetadata(title: "Editing", fileName: "editing.md"),
      markdown: "one two three four five six")
    session.present(record: record, settings: settings)
    session.play(captureAudio: false)
    now = 103
    session.syncManualFrontier(at: now)
    session.pause()
    let draft = PresenterDraft(record: record)
    draft.begin(session: session)
    let shell = PresenterSessionState(session: session)
    var shellChanges = 0
    let watch = shell.objectWillChange.sink { shellChanges += 1 }
    let host = NSHostingView(rootView: PresenterEditorView(session: session, draft: draft,
      settings: settings, sideInset: 20, onUnsupportedEdit: {}))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    func editor(in view: NSView) -> NSTextView? {
      if let text = view as? NSTextView { return text }
      for child in view.subviews { if let text = editor(in: child) { return text } }
      return nil
    }
    let text = try XCTUnwrap(editor(in: host))
    func alpha() -> CGFloat {
      (text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 0
    }
    XCTAssertEqual(alpha(), 0.5, accuracy: 0.01)
    session.seek(to: 0)
    for _ in 0..<30 where alpha() < 0.99 {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(alpha(), 1, accuracy: 0.01, "Seeking back must remove stale read-through shading in the mounted editor")
    XCTAssertEqual(shellChanges, 0, "Position changes belong to the editor, not the presenter shell")
    XCTAssertFalse(window.isVisible)
    withExtendedLifetime(watch) {}
  }

  func testManualWordInvalidationBenchmark() {
    let suite = "PresenterObservationTests.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(named: suite)!
    defer { TestDefaults.remove(suite) }
    let session = SessionStore(defaults: defaults)
    var now = 100.0
    session.clock = { now }
    var settings = PrompterSettings()
    settings.mode = "Manual"
    settings.speed = 60
    session.present(record: ScriptRecord(
      metadata: ScriptMetadata(title: "Benchmark", fileName: "benchmark.md"),
      markdown: Array(repeating: "word", count: 1002).joined(separator: " ")), settings: settings)
    session.play(captureAudio: false)
    let presentation = PresenterSessionState(session: session)
    var changes = 0
    var shellChanges = 0
    let watch = session.objectWillChange.sink { changes += 1 }
    let shellWatch = presentation.objectWillChange.sink { shellChanges += 1 }
    let start = ContinuousClock.now
    for index in 1...1000 {
      now = 100 + Double(index)
      session.syncManualFrontier(at: now)
    }
    let elapsed = start.duration(to: .now)
    print("PRESENTER_BENCHMARK words=1000 original_outer_invalidations=\(changes) narrowed_outer_invalidations=\(shellChanges) elapsed=\(elapsed)")
    XCTAssertEqual(session.tokenIndex, 1000)
    XCTAssertGreaterThanOrEqual(changes, 2000)
    XCTAssertEqual(shellChanges, 0)
    withExtendedLifetime((watch, shellWatch)) {}
    session.pause()
  }

  func testSpeechWordsOnlyInvalidateTheTextAndLifecycleChangesStillReachTheShell() {
    let suite = "PresenterObservationSpeechTests.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(named: suite)!
    defer { TestDefaults.remove(suite) }
    let session = SessionStore(defaults: defaults)
    var settings = PrompterSettings()
    settings.mode = "Voice"
    let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    session.present(record: ScriptRecord(
      metadata: ScriptMetadata(title: "Speech", fileName: "speech.md"),
      markdown: words.joined(separator: " ")), settings: settings)
    session.play(captureAudio: false)
    let presentation = PresenterSessionState(session: session)
    var wordChanges = 0
    var shellChanges = 0
    let wordWatch = session.$tokenIndex.dropFirst().sink { _ in wordChanges += 1 }
    let shellWatch = presentation.objectWillChange.sink { shellChanges += 1 }
    for count in 2...9 {
      session.acceptSpeechCandidate(SpeechCandidate(
        replacementID: "speech", generation: 1, locale: Locale(identifier: "en-GB"),
        text: words.prefix(count).joined(separator: " "),
        range: CMTimeRange(start: .zero, duration: CMTime(seconds: Double(count), preferredTimescale: 1000)),
        isFinal: false))
    }
    XCTAssertEqual(session.tokenIndex, 9)
    XCTAssertGreaterThan(wordChanges, 0)
    XCTAssertEqual(shellChanges, 0, "Recognised words must not invalidate camera or controls.")
    session.pause()
    XCTAssertEqual(shellChanges, 1, "The controls must still show Paused immediately.")
    settings.fontSize += 4
    session.updateSettings(settings)
    XCTAssertEqual(shellChanges, 2, "Typography still reaches the whole presenter.")
    session.updateSettings(settings)
    XCTAssertEqual(shellChanges, 2, "Repeated equivalent state must not wake the shell.")
    var replacement = session.activeRecord!
    replacement.markdown += " eleven"
    replacement.metadata.revision += 1
    session.applyEditedRecord(replacement)
    XCTAssertGreaterThan(shellChanges, 2, "Editing must rebuild the document.")
    withExtendedLifetime((wordWatch, shellWatch)) {}
  }
}
