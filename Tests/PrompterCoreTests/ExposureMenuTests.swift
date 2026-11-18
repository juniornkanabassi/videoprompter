import XCTest
@testable import PrompterCore
@testable import VideoPrompter

/// The Zebras and False colour menus: choice to update, the Mac's own camera as a `PadRemote.Guides`
/// state, and the iPad Adjust panels' diffing binding. No view is built, so no window can appear.
@MainActor final class ExposureMenuTests: XCTestCase {
  private typealias Logic = ExposureMenuLogic

  private func model() -> CameraModel {
    let camera = CameraModel(defaults: freshDefaults("ExposureMenus"))
    camera.selectedUID = "fixture"
    camera.guides = .firstUse
    return camera
  }

  // MARK: Local adapter

  func testLocalStateMirrorsTheGuidesAndAppliedUpdatesRoundTrip() {
    let camera = model()
    var state = Logic.state(from: camera.guides)
    XCTAssertEqual([state.zebras, state.falseColour, state.greyCardCheck], [true, false, false])
    XCTAssertEqual([state.zebraLevel, state.zebraRange, state.skinLevel, state.skinRange], [45, 2, 45, 2])
    XCTAssertEqual(state.zebraPurpose, "faceReference")

    Logic.apply(Logic.skinToneUpdate(.fair), to: camera)
    state = Logic.state(from: camera.guides)
    XCTAssertEqual([state.skinTone, state.zebraPurpose], ["Fair", "faceReference"])
    XCTAssertEqual([state.skinLevel, state.skinRange, state.zebraLevel, state.zebraRange, state.falseColour == true ? 1 : 0], [68, 3, 68, 3, 1])

    Logic.apply(Logic.levelUpdate(60), to: camera)
    state = Logic.state(from: camera.guides)
    XCTAssertEqual([state.zebraLevel, state.zebraRange], [60, 3])
    XCTAssertEqual(state.zebraPurpose, "custom")
    XCTAssertEqual(state.skinLevel, 68, "Zebras move on their own; the skin reference stays")
  }

  func testGreyCardGoesThroughTheModelAndSurvivesOtherEdits() {
    let camera = model()
    camera.exposureBypassed = true
    Logic.apply(Logic.greyCardUpdate(true), to: camera)
    XCTAssertTrue(camera.guides.greyCardCheck)
    XCTAssertFalse(camera.exposureBypassed, "A new check shows the aids")
    XCTAssertEqual([camera.guides.zebraLevel, camera.guides.zebraRange], [41, 2])
    Logic.apply(Logic.greyCardUpdate(false), to: camera)
    XCTAssertFalse(camera.guides.greyCardCheck)
    XCTAssertEqual([camera.guides.zebraLevel, camera.guides.zebraRange], [45, 2])
  }

  func testSwitchingAnAidOffKeepsBypassAndCleanView() {
    let camera = model()
    camera.exposureBypassed = true; camera.cleanView = true
    Logic.apply(.init(zebras: false), to: camera)
    XCTAssertFalse(camera.guides.zebras)
    XCTAssertTrue(camera.exposureBypassed)
    XCTAssertTrue(camera.cleanView)
    Logic.apply(Logic.levelUpdate(80), to: camera)
    XCTAssertTrue(camera.guides.zebras)
    XCTAssertFalse(camera.exposureBypassed)
    XCTAssertFalse(camera.cleanView)
  }

  // MARK: Menu choice to update

  func testChoicesMapToUpdates() {
    XCTAssertEqual(Logic.levelUpdate(95), PadRemote.Guides(zebras: true, zebraLevel: 95))
    XCTAssertEqual(Logic.levelUpdate(101).zebraLevel, 100, "Up 1 at the top stays at 100")
    XCTAssertEqual(Logic.levelUpdate(-1).zebraLevel, 0)
    XCTAssertEqual(Logic.widthUpdate(5), PadRemote.Guides(zebras: true, zebraRange: 5))
    XCTAssertEqual(Logic.purposeUpdate(.faceReference), PadRemote.Guides(zebras: true, zebraPurpose: "faceReference"))
    XCTAssertEqual(Logic.skinToneUpdate(.brown), PadRemote.Guides(falseColour: true, skinTone: "Brown"))
    XCTAssertEqual(Logic.greyCardUpdate(true), PadRemote.Guides(greyCardCheck: true))
    let near = PadRemote.Guides(zebraRange: 2, skinRange: 3)
    XCTAssertEqual(Logic.modeUpdate(near: false, state: near), PadRemote.Guides(zebras: true, zebraRangeMode: false))
    XCTAssertEqual(Logic.modeUpdate(near: true, state: near), PadRemote.Guides(zebras: true, zebraRangeMode: true))
    XCTAssertEqual(Logic.customSkinUpdate(PadRemote.Guides(skinLevel: 45)), PadRemote.Guides(falseColour: true, skinLevel: 45))
  }

  func testLevelAndBrighterThenNearALevelOnTheMac() {
    let camera = model()
    Logic.apply(Logic.modeUpdate(near: false, state: Logic.state(from: camera.guides)), to: camera)
    XCTAssertEqual(camera.guides.zebraRange, 0)
    Logic.apply(Logic.modeUpdate(near: true, state: Logic.state(from: camera.guides)), to: camera)
    XCTAssertEqual(camera.guides.zebraRange, 2)
  }

  func testSwitchingModesKeepsACustomWidth() {
    let camera = model()
    Logic.apply(Logic.widthUpdate(5), to: camera)
    Logic.apply(Logic.levelUpdate(60), to: camera)
    Logic.apply(Logic.modeUpdate(near: false, state: Logic.state(from: camera.guides)), to: camera)
    Logic.apply(Logic.modeUpdate(near: true, state: Logic.state(from: camera.guides)), to: camera)
    XCTAssertEqual([camera.guides.zebraLevel, camera.guides.zebraRange], [60, 5])
    Logic.apply(Logic.modeUpdate(near: true, state: Logic.state(from: camera.guides)), to: camera)
    XCTAssertEqual([camera.guides.zebraLevel, camera.guides.zebraRange], [60, 5], "Choosing the ticked mode again changes nothing")
  }

  func testCustomSkinSelectsTheCustomToneKeepingItsNumbers() {
    let camera = model()
    Logic.apply(Logic.skinToneUpdate(.deep), to: camera)
    Logic.apply(Logic.customSkinUpdate(Logic.state(from: camera.guides)), to: camera)
    XCTAssertEqual(camera.guides.skinTone, .custom)
    XCTAssertEqual([camera.guides.skinReference.level, camera.guides.skinReference.range], [45, 2])
  }

  func testSummaries() {
    var guides = CameraGuides.firstUse
    XCTAssertEqual(Logic.zebraSummary(Logic.state(from: guides)), "My skin · 45 ±2")
    XCTAssertEqual(Logic.colourSummary(Logic.state(from: guides)), "off")
    guides.useZebraPreset(.brightAreas)
    XCTAssertEqual(Logic.zebraSummary(Logic.state(from: guides)), "Highlights · 95+")
    guides.falseColour = true
    guides.skinReference = CameraGuides.SkinTone.brown.reference!
    XCTAssertEqual(Logic.colourSummary(Logic.state(from: guides)), "Brown · 50 ±3")
    guides.skinReference.level = 52
    XCTAssertEqual(Logic.colourSummary(Logic.state(from: guides)), "Custom · 52 ±3")
    guides.greyCardCheck = true
    XCTAssertEqual(Logic.colourSummary(Logic.state(from: guides)), "Grey card · 41 ±2")
  }

  // MARK: Diffing binding for the iPad's Adjust panels

  private func remote(_ state: PadRemote.Guides, edit: (inout CameraGuides) -> Void) -> PadRemote.Guides {
    let old = Logic.guides(from: state)
    var new = old
    new.changeExposure(edit)
    return Logic.update(from: old, to: new)
  }

  private let base = PadRemote.Guides(zebras: true, falseColour: false, zebraPurpose: "faceReference", zebraLevel: 45, zebraRange: 2,
    skinTone: "Deep", skinLevel: 45, skinRange: 2, greyCardCheck: false)

  func testPanelStateRoundTripsThroughCameraGuides() {
    var state = base
    state.greyCardCheck = true
    state.zebraPurpose = "custom"; state.zebraLevel = 60; state.zebraRange = 0
    let guides = Logic.guides(from: state)
    XCTAssertEqual(Logic.state(from: guides), state)
    XCTAssertEqual(Logic.update(from: guides, to: guides), PadRemote.Guides())
  }

  func testDiffSendsOnlyChangedFields() {
    XCTAssertEqual(remote(base) { $0.zebras = false }, PadRemote.Guides(zebras: false))
    XCTAssertEqual(remote(base) { $0.falseColour = true }, PadRemote.Guides(falseColour: true))
    // A level change makes the purpose custom: both go, and nothing else.
    XCTAssertEqual(remote(base) { $0.zebraLevel = 50 }, PadRemote.Guides(zebraPurpose: "custom", zebraLevel: 50))
    XCTAssertEqual(remote(base) { $0.zebraRange = 4 }, PadRemote.Guides(zebraPurpose: "custom", zebraRange: 4))
  }

  func testPresetsAndSkinTonesSendOnlyTheirNames() {
    XCTAssertEqual(remote(base) { $0.useZebraPreset(.brightAreas) }, PadRemote.Guides(zebraPurpose: "brightAreas"))
    XCTAssertEqual(remote(base) {
      $0.skinReference = CameraGuides.SkinTone.fair.reference!; $0.selectedSkinTone = .fair
    }, PadRemote.Guides(skinTone: "Fair"), "The zebras that follow the skin tone are the receiver's to move")
    XCTAssertEqual(remote(base) { $0.selectedSkinTone = .custom }, PadRemote.Guides(skinTone: "Custom"))
  }

  func testCustomSkinStepperSendsTheChangedNumberOnly() {
    var state = base
    state.skinTone = "Custom"
    XCTAssertEqual(remote(state) { $0.skinReference.level = 52; $0.selectedSkinTone = .custom }, PadRemote.Guides(skinLevel: 52))
    XCTAssertEqual(remote(state) { $0.skinReference.range = 5; $0.selectedSkinTone = .custom }, PadRemote.Guides(skinRange: 5))
  }

  func testLimitAndRangeSwitchSendsOnlyTheMode() {
    var state = base
    state.zebraPurpose = "brightAreas"; state.zebraLevel = 95; state.zebraRange = 0
    XCTAssertEqual(remote(state) { $0.zebraRangeMode = true }, PadRemote.Guides(zebraPurpose: "custom", zebraRangeMode: true))
    XCTAssertEqual(remote(base) { $0.zebraRangeMode = false }, PadRemote.Guides(zebraPurpose: "custom", zebraRangeMode: false))
  }

  func testGreyCardStartsAndFinishesWithoutSideEffects() {
    XCTAssertEqual(remote(base) { $0.greyCardCheck = true }, PadRemote.Guides(greyCardCheck: true))
    var checking = base
    checking.zebraLevel = 41; checking.greyCardCheck = true
    let old = Logic.guides(from: checking)
    var finished = old
    finished.greyCardCheck = false
    XCTAssertEqual(Logic.update(from: old, to: finished), PadRemote.Guides(greyCardCheck: false))
  }

}
