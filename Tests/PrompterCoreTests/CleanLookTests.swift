import XCTest
import PrompterCore
@testable import VideoPrompter

final class CleanLookTests: XCTestCase {
  @MainActor func testCleanSelectionAndPreferences() {
    let defaults = freshDefaults("CleanSelection")
    let camera = CameraModel(defaults: defaults)
    camera.chooseCleanLook(.pictureOnly)
    camera.chooseCleanLook(.scriptOnly)
    XCTAssertTrue(camera.cleanView, "Switching looks must keep Clean open")
    camera.keepCleanMicMeter = false
    let restored = CameraModel(defaults: defaults)
    XCTAssertEqual(restored.cleanLook, .scriptOnly)
    XCTAssertFalse(restored.keepCleanMicMeter)
    camera.chooseCleanLook(.scriptOnly)
    XCTAssertFalse(camera.cleanView, "Only selecting the active look exits Clean")
  }

  func testCountdownStateIsBackwardCompatible() throws {
    let old = Data(#"{"scripts":[],"running":false,"mode":"Manual","speed":120,"word":0,"words":0}"#.utf8)
    var state = try JSONDecoder().decode(PadRemote.State.self, from: old)
    XCTAssertNil(state.countdownRemaining)
    state.countdownRemaining = 3
    XCTAssertEqual(try JSONDecoder().decode(PadRemote.State.self, from: JSONEncoder().encode(state)).countdownRemaining, 3)
  }

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
