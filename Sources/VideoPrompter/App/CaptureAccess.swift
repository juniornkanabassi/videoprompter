import AVFoundation
import Foundation
import PrompterCore

/// Hidden agent copies (`--agent-screen`) and tests have their own app identity, so macOS would ask Junior
/// for camera and microphone access again for every copy. They never ask and never open a device unless
/// access was already granted; only the real app asks, once.
/// Anything other than Junior's real installed app (an agent's re-identified copy, a bare debug build) runs
/// as a hidden agent copy, even if someone forgets `--agent-screen`: invisible, never activating, silent.
enum AgentMode {
  static let realBundleID = ControlProtocol.bundleID
  static let isOn = rule(arguments: CommandLine.arguments, bundleID: Bundle.main.bundleIdentifier,
    underTest: NSClassFromString("XCTestCase") != nil)
  static func rule(arguments: [String], bundleID: String?, underTest: Bool) -> Bool {
    !underTest && (arguments.contains("--agent-screen") || bundleID != realBundleID)
  }
}

enum CaptureAccess {
  static let isAgentOrTest = AgentMode.isOn || NSClassFromString("XCTestCase") != nil

  /// Whether this process may open (or start a session on) a device of this kind right now.
  static func mayUse(_ media: AVMediaType) -> Bool {
    AVCaptureDevice.authorizationStatus(for: media) == .authorized || !isAgentOrTest
  }

  /// Asks only in the real app, and only when the answer is not known yet.
  static func request(_ media: AVMediaType) async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: media)
    if status == .authorized { return true }
    guard status == .notDetermined, !isAgentOrTest else { return false }
    return await AVCaptureDevice.requestAccess(for: media)
  }
}
