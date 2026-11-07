import AVFoundation
import Foundation
import PrompterCore

/// Only the installed app can behave as an interactive app. A signed build in a temporary
/// folder still has the real bundle ID, but must never show windows or ask for permission.
enum AgentMode {
  static let realBundleID = ControlProtocol.bundleID
  static let isOn = rule(arguments: CommandLine.arguments, bundleID: Bundle.main.bundleIdentifier,
    bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
    underTest: NSClassFromString("XCTestCase") != nil)
  static func rule(arguments: [String], bundleID: String?, bundlePath: String, underTest: Bool) -> Bool {
    let installed = bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    return !underTest && (arguments.contains("--agent-screen") || bundleID != realBundleID || !installed)
  }
}

enum CaptureAccess {
  static let isAgentOrTest = AgentMode.isOn || NSClassFromString("XCTestCase") != nil

  /// Opening a device can itself ask for permission, even without requestAccess.
  static func mayUse(_ media: AVMediaType) -> Bool {
    mayUse(status: AVCaptureDevice.authorizationStatus(for: media))
  }

  static func mayUse(status: AVAuthorizationStatus) -> Bool { status == .authorized }

  static func deviceInput(_ device: AVCaptureDevice, media: AVMediaType) throws -> AVCaptureDeviceInput {
    guard mayUse(media) else { throw CocoaError(.userCancelled) }
    return try AVCaptureDeviceInput(device: device)
  }

  /// A shared camera session can also contain the recording microphone. Check both before starting.
  static func start(_ session: AVCaptureSession) {
    let inputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
    guard !inputs.isEmpty, inputs.allSatisfy({ input in
      [AVMediaType.video, .audio].allSatisfy { !input.device.hasMediaType($0) || mayUse($0) }
    }) else { return }
    session.startRunning()
  }

  static func mayPrompt(isAgentOrTest: Bool, headless: Bool) -> Bool {
    !isAgentOrTest && !headless
  }

  /// CLI/MCP launches must not prompt either. A person can reveal the installed app first.
  @MainActor static func request(_ media: AVMediaType) async -> Bool {
    await request(status: AVCaptureDevice.authorizationStatus(for: media),
      mayPrompt: mayPrompt(isAgentOrTest: isAgentOrTest, headless: Headless.shared.active)) {
      await AVCaptureDevice.requestAccess(for: media)
    }
  }

  @MainActor static func request(status: AVAuthorizationStatus, mayPrompt: Bool,
    requester: () async -> Bool) async -> Bool {
    if status == .authorized { return true }
    guard status == .notDetermined, mayPrompt else { return false }
    return await requester()
  }
}
