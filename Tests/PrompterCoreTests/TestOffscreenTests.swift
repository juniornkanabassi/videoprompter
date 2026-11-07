import AVFoundation
import AppKit
import TestOffscreen
import XCTest
@testable import VideoPrompter

/// Tests never show anything on Junior's screens or take focus.
@MainActor final class TestOffscreenTests: XCTestCase {
  func testEveryWindowATestShowsStaysInvisibleAndClickThrough() {
    TestOffscreenInstalled()
    XCTAssertEqual(TestOffscreenCaptureGuardsInstalled(), 1)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    for show in [{ window.makeKeyAndOrderFront(nil) }, { window.orderFrontRegardless() }, { window.orderFront(nil) }] {
      window.alphaValue = 1
      show()
      XCTAssertTrue(window.isVisible)
      XCTAssertEqual(window.alphaValue, 0)
      XCTAssertTrue(window.ignoresMouseEvents)
      window.orderOut(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    XCTAssertFalse(NSApp.isActive, "a test must never bring the test process forward")
  }
}

/// Tests never trigger macOS camera or microphone prompts: each test binary is a new app identity to macOS.
@MainActor final class CaptureAccessTests: XCTestCase {
  func testTestsNeverAskForCameraOrMicrophone() async throws {
    XCTAssertTrue(CaptureAccess.isAgentOrTest)
    let undecided = [AVMediaType.video, .audio].filter { AVCaptureDevice.authorizationStatus(for: $0) != .authorized }
    try XCTSkipIf(undecided.isEmpty, "this Mac already granted both, so there is no prompt to prove absent")
    for media in [AVMediaType.video, .audio] where AVCaptureDevice.authorizationStatus(for: media) != .authorized {
      XCTAssertFalse(CaptureAccess.mayUse(media))
      let granted = await CaptureAccess.request(media)
      XCTAssertFalse(granted)
    }
  }
}

final class AgentModeTests: XCTestCase {
  func testOnlyTheRealBundleRunsVisibleOutsideTests() {
    XCTAssertEqual(AgentMode.realBundleID, "com.juniornkanabassi.VidPrompt")
    // The real app stays visible wherever it is opened from (DMG, Downloads, App Translocation).
    XCTAssertFalse(AgentMode.rule(arguments: ["app"], bundleID: AgentMode.realBundleID, underTest: false))
    XCTAssertFalse(AgentMode.isOn, "tests keep their own window and focus guards")
    let real = AgentMode.realBundleID
    XCTAssertFalse(AgentMode.rule(arguments: ["app"], bundleID: real, underTest: false), "the installed app runs normally")
    XCTAssertTrue(AgentMode.rule(arguments: ["app", "--agent-screen"], bundleID: real, underTest: false))
    XCTAssertTrue(AgentMode.rule(arguments: ["app"], bundleID: "com.example.vp-check-1", underTest: false), "a re-identified copy is hidden")
    XCTAssertTrue(AgentMode.rule(arguments: ["app"], bundleID: nil, underTest: false), "a bare debug build is hidden")
    XCTAssertFalse(AgentMode.rule(arguments: ["app", "--agent-screen"], bundleID: nil, underTest: true))
  }
}

extension CaptureAccessTests {
  func testEveryAuthorizationStateWithoutTouchingHardware() async {
    for status in [AVAuthorizationStatus.notDetermined, .restricted, .denied, .authorized] {
      XCTAssertEqual(CaptureAccess.mayUse(status: status), status == .authorized)
      for mayPrompt in [false, true] {
        var calls = 0
        let granted = await CaptureAccess.request(status: status, mayPrompt: mayPrompt) {
          calls += 1
          return true
        }
        let shouldAsk = status == .notDetermined && mayPrompt
        XCTAssertEqual(calls, shouldAsk ? 1 : 0)
        XCTAssertEqual(granted, status == .authorized || shouldAsk)
      }
    }
  }
}

extension CaptureAccessTests {
  func testHeadlessAndAgentProcessesNeverPromptEvenWithRealBundleID() {
    for agent in [false, true] {
      for headless in [false, true] {
        XCTAssertEqual(CaptureAccess.mayPrompt(isAgentOrTest: agent, headless: headless), !agent && !headless)
      }
    }
  }

  func testUnusedAndUnavailableAudioCaptureDoesNotOpenInput() throws {
    let capture = AudioCapture(device: AudioInputDevice(id: 0, uid: "missing-test-device", name: "Missing"),
      outputFormat: try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)))
    capture.stop()
    XCTAssertThrowsError(try capture.start(onBuffer: { _, _, _, _, _ in XCTFail("No input should run") }, onStop: { _ in })) { error in
      XCTAssertTrue(error as? AudioCaptureError == .permissionDenied || error as? AudioCaptureError == .deviceUnavailable)
    }
    capture.stop()
  }
}
