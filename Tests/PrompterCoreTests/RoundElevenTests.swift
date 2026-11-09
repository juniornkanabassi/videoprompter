import AVFoundation

import AppKit
import SwiftUI
import XCTest
import PrompterCore
@testable import VideoPrompter

@MainActor final class RoundElevenTests: XCTestCase {
  func testSoundNeedsMeasuredEvidenceAndResetReturnsToWaiting() {
    let meter = InputMeter()
    let now = ProcessInfo.processInfo.systemUptime
    XCTAssertEqual(RecordingHealth.measured(lastAudibleSampleAt: nil, clipping: false, now: now), .waiting)
    XCTAssertEqual(RecordingHealth.measured(lastAudibleSampleAt: nil, clipping: false, now: now + 4), .waiting)
    meter.show(channelPeaks: [0.2])
    XCTAssertEqual(RecordingHealth.measured(lastAudibleSampleAt: meter.lastAudibleSampleAt, clipping: false), .receiving)
    XCTAssertEqual(RecordingHealth.measured(lastAudibleSampleAt: now - 4, clipping: false, now: now), .silence)
    XCTAssertEqual(RecordingHealth.measured(lastAudibleSampleAt: now, clipping: true, now: now), .clipping)
    meter.reset()
    XCTAssertEqual(RecordingHealth.measured(lastAudibleSampleAt: meter.lastAudibleSampleAt, clipping: false), .waiting)
  }

  func testRecoveryCannotOverlapScriptAtAnySize() async throws {
    guard Features.recording else { throw XCTSkip("Recording is not available in this build") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("RoundEleven")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Recovery", markdown: String(repeating: "Read at your own pace. ", count: 100))
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    let recorder = CameraRecorder(defaults: defaults)
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
    defer { store.session.pause(); LibraryAX.close(window) }
    func frame(_ node: NSObject) throws -> NSRect {
      try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for access in [AVAuthorizationStatus.denied, .notDetermined, .authorized] {
        camera.authorization = access
        for position in [0, 90] {
          store.session.seek(to: position)
          for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
          XCTAssertEqual(host.bounds.width, 720, accuracy: 1)
          let recovery = try XCTUnwrap(LibraryAX.named("Recording status", in: host).first)
          XCTAssertTrue(LibraryAX.value(recovery, "accessibilityValue").contains("Camera unavailable"))
          let script = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first?.enclosingScrollView)
          let scriptFrame = script.convert(script.bounds, to: nil)
          XCTAssertFalse(window.convertToScreen(scriptFrame).intersects(try frame(recovery)), "Recovery must reserve space outside reading")
          let mode = try XCTUnwrap(LibraryAX.named("Reading status", in: host).first)
          XCTAssertGreaterThan(try frame(mode).height, 0)
          XCTAssertFalse(LibraryAX.named("Tools", in: host).isEmpty, "Guides are in More when the row cannot fit")
          XCTAssertTrue(LibraryAX.named("Saved video", in: host).isEmpty, "Missing picture shows recovery instead of output metadata")
          if position > 0 {
            for title in ["Start reading", "Record", "Tools"] {
              let control = try XCTUnwrap(LibraryAX.named(title, in: host).first)
              XCTAssertTrue(window.convertToScreen(host.bounds).contains(try frame(control)), "\(zoom): \(title)")
            }
            if let reset = LibraryAX.named("Back to start", in: host).first {
              XCTAssertTrue(LibraryAX.bool(reset, "accessibilityPerformPress"))
              XCTAssertEqual(store.session.tokenIndex, 0)
            }
          }
        }
      }
    }
  }
}
