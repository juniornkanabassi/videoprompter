import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Disposable models and transparent hosts only. Never capture camera/audio or activate the app.
@MainActor final class QAFindingsRound5Tests: XCTestCase {
  private func camera(_ defaults: UserDefaults? = nil) -> CameraModel {
    let model = CameraModel(defaults: defaults ?? freshDefaults("QA5Framing"))
    model.selectedUID = "qa5-no-hardware"
    model.guides.marker = CameraAspect(width: 2.39, height: 1)
    return model
  }

  private func fields(_ host: NSView) -> [NSTextField] {
    LibraryAX.elements(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
  }

  private func enter(_ text: String, in field: NSTextField) async throws {
    field.stringValue = text
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    field.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    try await Task.sleep(for: .milliseconds(120))
  }

  func testCustomRatioCanBeCompletedWhenFirstDimensionMatchesAPreset() async throws {
    let model = camera()
    let (window, host) = await LibraryAX.host(CameraGuideSettings(model: model))
    defer { LibraryAX.close(window) }
    XCTAssertEqual(fields(host).count, 2)
    try await enter("1", in: XCTUnwrap(fields(host).first))
    XCTAssertEqual(model.guides.marker, CameraAspect(width: 1, height: 1))
    XCTAssertEqual(fields(host).count, 2,
      "Editing Custom from 2.39:1 to 1:2 must keep Height reachable after Width becomes 1; an intermediate preset is not a request to leave Custom.")
    guard fields(host).count == 2 else { return }
    try await enter("2", in: fields(host)[1])
    XCTAssertEqual(model.guides.marker, CameraAspect(width: 1, height: 2))
  }

  func testCustomRatioRejectsZeroAndNegativeDimensions() async throws {
    for input in ["0", "-1"] {
      let defaults = freshDefaults("QA5InvalidFraming")
      let model = camera(defaults)
      let before = model.guides.marker
      let (window, host) = await LibraryAX.host(CameraGuideSettings(model: model))
      defer { LibraryAX.close(window) }
      try await enter(input, in: XCTUnwrap(fields(host).first))
      XCTAssertEqual(model.guides.marker, before, "Invalid width \(input) must not replace the usable frame marker")
      let reopened = CameraModel(defaults: defaults)
      XCTAssertTrue(reopened.guides.marker?.isValid == true, "Invalid width must not survive reopening the settings")
    }
  }

  func testOversizedCustomRatioDoesNotCrashTheSettingsProcess() async throws {
    let probeKey = "VIDEOPROMPTER_QA5_RATIO_CRASH_PROBE"
    if ProcessInfo.processInfo.environment[probeKey] == "1" {
      let model = camera()
      let (window, host) = await LibraryAX.host(CameraGuideSettings(model: model))
      defer { LibraryAX.close(window) }
      try await enter("100000000000000000000", in: XCTUnwrap(fields(host).first))
      return
    }
    // A separate offscreen XCTest process contains the trap, so other regression tests still run.
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("vp-qa5-crash-\(UUID()).log")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: output) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
    process.arguments = ["-XCTest", "PrompterCoreTests.QAFindingsRound5Tests/testOversizedCustomRatioDoesNotCrashTheSettingsProcess", Bundle(for: Self.self).bundlePath]
    var environment = ProcessInfo.processInfo.environment
    environment[probeKey] = "1"
    process.environment = environment
    process.standardOutput = handle; process.standardError = handle
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let deadline = ContinuousClock.now + .seconds(20)
    while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(process.isRunning, "Custom width editing must not hang")
    if process.isRunning { return }
    let log = try String(contentsOf: output, encoding: .utf8)
    XCTAssertEqual(process.terminationReason, .exit, "Typing a numeric width must not terminate the app. \(log.suffix(2500))")
    XCTAssertEqual(process.terminationStatus, 0, "Oversized input must be rejected without a crash")
  }

}
