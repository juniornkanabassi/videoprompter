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
          let recovery = try XCTUnwrap(LibraryAX.named("Camera unavailable", in: host).first)
          let script = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first?.enclosingScrollView)
          let scriptFrame = script.convert(script.bounds, to: nil)
          XCTAssertFalse(window.convertToScreen(scriptFrame).intersects(try frame(recovery)), "Recovery must reserve space outside reading")
          let mode = try XCTUnwrap(LibraryAX.named("Reading mode", in: host).first)
          XCTAssertGreaterThanOrEqual(try frame(mode).height, 24 * zoom)
          XCTAssertFalse(LibraryAX.named("Framing guides", in: host).isEmpty)
          XCTAssertFalse(LibraryAX.named("Saved video", in: host).isEmpty)
          if position > 0 {
            let reset = try XCTUnwrap(LibraryAX.named("Back to start", in: host).first, "zoom=\(zoom) index=\(store.session.tokenIndex) running=\(store.session.isActivelyRunning) labels=\(LibraryAX.elements(host).map { LibraryAX.value($0, "accessibilityLabel") })")
            for title in ["Start reading", "Back to start", "Record", "Camera", "Framing guides", "Exposure", "Microphone"] {
              let control = try XCTUnwrap(LibraryAX.named(title, in: host).first)
              XCTAssertTrue(window.convertToScreen(host.bounds).contains(try frame(control)), "\(zoom): \(title)")
            }
            XCTAssertTrue(LibraryAX.bool(reset, "accessibilityPerformPress"))
            XCTAssertEqual(store.session.tokenIndex, 0)
          }
        }
      }
    }
  }
}
