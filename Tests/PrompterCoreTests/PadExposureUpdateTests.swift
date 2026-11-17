import XCTest
@testable import PrompterCore
@testable import VideoPrompter

/// The Mac's exposure update, applied the way the iPad applies it (`PadStore` calls `applyExposure`).
final class PadExposureUpdateTests: XCTestCase {
  private func applied(_ update: PadRemote.Guides, to start: CameraGuides = .firstUse) -> CameraGuides {
    var guides = start
    guides.applyExposure(update)
    guides.sanitise()
    return guides
  }

  func testSkinToneSetsReferenceAndFaceBand() {
    let guides = applied(.init(skinTone: "Fair"))
    XCTAssertEqual(guides.skinTone, .fair)
    XCTAssertEqual(guides.skinReference, .init(level: 68, range: 3))
    // First-use guides watch the face reference, so the zebra band follows the tone.
    XCTAssertEqual(guides.zebraPurpose, .faceReference)
    XCTAssertEqual([guides.zebraLevel, guides.zebraRange], [68, 3])
  }

  func testCustomSkinLevelAndRangeAreClamped() {
    let guides = applied(.init(skinLevel: 400, skinRange: 0))
    XCTAssertEqual(guides.skinReference, .init(level: 100, range: 1))
    XCTAssertEqual(guides.skinTone, .custom)
  }

  func testUnknownNamesAreIgnoredAndOutOfRangeZebraNumbersClamp() {
    let start = CameraGuides.firstUse
    let unknown = applied(.init(zebraPurpose: "nonsense", skinTone: "Purple"), to: start)
    XCTAssertEqual(unknown, start)
    let guides = applied(.init(zebraLevel: 250, zebraRange: -3))
    XCTAssertEqual([guides.zebraLevel, guides.zebraRange], [100, 0])
    XCTAssertEqual(guides.zebraPurpose, .custom)
  }

  func testLimitAndBandKeepTheirOwnSavedLevels() {
    var guides = applied(.init(zebraPurpose: "brightAreas"))
    XCTAssertEqual([guides.zebraLevel, guides.zebraRange], [95, 0])
    guides = applied(.init(zebraLevel: 50, zebraRange: 4), to: guides)
    XCTAssertEqual([guides.zebraLevel, guides.zebraRange], [50, 4])
    XCTAssertEqual(guides.savedLimitLevel, 95)
    guides = applied(.init(zebraRange: 0), to: guides)
    XCTAssertEqual([guides.zebraLevel, guides.zebraRange], [95, 0])
    XCTAssertEqual([guides.savedRangeLevel, guides.savedRangeWidth], [50, 4])
  }

  func testGreyCardChecksStartLastAndEndFirst() {
    var guides = applied(.init(zebraPurpose: "brightAreas", greyCardCheck: true))
    XCTAssertTrue(guides.greyCardCheck)
    XCTAssertEqual([guides.zebraLevel, guides.zebraRange], [41, 2])
    // An update about something else leaves a running check alone.
    guides = applied(.init(thirds: true), to: guides)
    XCTAssertTrue(guides.greyCardCheck)
    // Ending it restores what was set before, then the update's own edits land on top.
    guides = applied(.init(zebraLevel: 80, zebraRange: 0, greyCardCheck: false), to: guides)
    XCTAssertFalse(guides.greyCardCheck)
    XCTAssertEqual([guides.zebraLevel, guides.zebraRange], [80, 0])
  }

  func testStateWithoutNewFieldsStillDecodes() throws {
    let guides = try JSONDecoder().decode(PadRemote.Guides.self, from: Data(#"{"zebras":true,"rotation":90}"#.utf8))
    XCTAssertNil(guides.zebraPurpose)
    XCTAssertNil(guides.greyCardCheck)
    XCTAssertEqual(guides, PadRemote.Guides(zebras: true, rotation: 90))
  }
}
