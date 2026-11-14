import XCTest
import PrompterCore
@testable import VideoPrompter

final class CleanLookTests: XCTestCase {
  func testLooksRoundTripAndOldPeersDecode() throws {
    for look in PadRemote.CleanLook.allCases {
      let value = PadRemote.Look(cleanLook: look, keepMicMeter: false)
      XCTAssertEqual(try JSONDecoder().decode(PadRemote.Look.self, from: JSONEncoder().encode(value)), value)
    }
    let old = try JSONDecoder().decode(PadRemote.Look.self, from: Data("{\"focusMode\":true}".utf8))
    XCTAssertNil(old.cleanLook)
    XCTAssertEqual(old.focusMode, true)
    XCTAssertTrue(PadRemote.CleanLook.pictureOnly.showsPicture)
    XCTAssertFalse(PadRemote.CleanLook.pictureOnly.showsScript)
    XCTAssertTrue(PadRemote.CleanLook.pictureAndScript.showsGuides)
    XCTAssertFalse(PadRemote.CleanLook.scriptOnly.showsPicture)
    XCTAssertTrue(PadRemote.CleanLook.scriptOnly.showsScript)
  }

  @MainActor func testExposureRemainsEnabledWhileReadingAndCleanRestoresIt() {
    let defaults = freshDefaults("CleanLooks")
    let camera = CameraModel(defaults: defaults)
    camera.guides.zebras = true
    camera.guides.falseColour = true
    camera.guides.thirds = true
    for look in PadRemote.CleanLook.allCases {
      camera.cleanLook = look
      camera.cleanView = true
      XCTAssertEqual(camera.previewGuides.zebras, look.showsGuides)
      XCTAssertEqual(camera.previewGuides.thirds, look.showsGuides)
    }
    camera.cleanView = false
    XCTAssertTrue(camera.previewGuides.zebras)
    XCTAssertTrue(camera.previewGuides.falseColour)
    let state = PadRemote.State(scripts: [], presenting: nil, running: true, mode: "Manual", speed: 120,
      word: 1, words: 10, look: .init(presenterSetup: false), guides: .init(zebras: true, falseColour: true))
    XCTAssertNil(state.activeCleanLook)
    var legacy = state
    legacy.look?.focusMode = true
    XCTAssertEqual(legacy.activeCleanLook, .scriptOnly)
    legacy.look?.cleanLook = .pictureAndScript
    legacy.cleanScreen = true
    XCTAssertEqual(legacy.activeCleanLook, .pictureAndScript)
    XCTAssertTrue(IPadRemoteView.replicaGuides(state).zebras)
    XCTAssertTrue(IPadRemoteView.replicaGuides(state).falseColour)
  }
}
