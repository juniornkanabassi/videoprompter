import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Disposable state and transparent offscreen hosts only. No capture, playback or Finder actions.
@MainActor final class QAFindingsRound4Tests: XCTestCase {
  private func fixture() async throws -> (AppStore, UserDefaults) {
    let root = URL(fileURLWithPath: "/private/tmp/vp-qa4-test-\(UUID())")
    let defaults = freshDefaults("QAFindingsRound4")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    await store.waitForInitialLoad()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (store, defaults)
  }

  func testReopenedFramingSectionShowsPersistedCustomMarkerDimensions() async throws {
    let (_, defaults) = try await fixture()
    let camera = CameraModel(defaults: defaults)
    camera.selectedUID = "qa4-fixture-camera"
    camera.guides.marker = CameraAspect(width: 5, height: 4)
    // Switching away from Framing and back rebuilds CameraGuideSections, just like a relaunch.
    let reopened = CameraModel(defaults: defaults)
    XCTAssertEqual(reopened.guides.marker, CameraAspect(width: 5, height: 4))
    let (window, host) = await LibraryAX.host(CameraGuideSections(model: reopened))
    defer { LibraryAX.close(window) }
    let fields = LibraryAX.elements(host).filter { LibraryAX.value($0, "accessibilityRole") == "AXTextField" }
    XCTAssertEqual(fields.count, 2)
    for (index, expected) in ["5", "4"].enumerated() {
      let label = index == 0 ? "Width" : "Height"
      let field = try XCTUnwrap(fields.indices.contains(index) ? fields[index] : nil)
      let value = String(describing: field.value(forKey: "accessibilityValue") ?? "")
      XCTAssertEqual(value, expected, "The custom marker editor must show the saved \(label.lowercased()), not an unrelated default")
    }
  }

  func testFormatRecoveryDestinationExposesRecordingFormat() async throws {
    guard Features.recording else { throw XCTSkip("Recording is not available in this build") }
    let (store, _) = try await fixture()
    // Format recovery selects the Recording section inside Camera & Recording.
    XCTAssertEqual(CameraRecorder.recovery(for: CocoaError(.featureUnsupported)), .format)
    let (window, host) = await LibraryAX.host(PresenterSettingsPopover(store: store, initialTab: .camera, initialCameraSection: "Recording"))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named("Settings page", in: host).isEmpty, "Verify the recovery destination is actually mounted")
    XCTAssertFalse(LibraryAX.named("Recording format", in: host).isEmpty,
      "Change recording format must open the Recording section, not the unrelated Camera section")
  }
}
