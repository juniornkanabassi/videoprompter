import AVFoundation
import Foundation

/// Hidden agent copies (`--agent-screen`) and tests have their own app identity, so macOS would ask Junior
/// for camera and microphone access again for every copy. They never ask and never open a device unless
/// access was already granted; only the real app asks, once.
enum CaptureAccess {
  static let isAgentOrTest = CommandLine.arguments.contains("--agent-screen") || NSClassFromString("XCTestCase") != nil

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
