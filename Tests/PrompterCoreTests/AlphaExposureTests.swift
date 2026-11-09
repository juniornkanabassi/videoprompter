import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class AlphaExposureTests: XCTestCase {
  func testSkinAndModesAreIndependent() throws {
    var guides = CameraGuides.firstUse
    let pink = guides.exposure.skinCodes
    guides.zebraLevel = 60
    guides.zebraRange = 4
    XCTAssertEqual(guides.exposure.skinCodes, pink)
    guides.zebraRangeMode = false
    guides.zebraLevel = 88
    guides.zebraRangeMode = true
    XCTAssertEqual(guides.zebraLevel, 60)
    XCTAssertEqual(guides.zebraRange, 4)
    guides.zebraRangeMode = false
    XCTAssertEqual(guides.zebraLevel, 88)
    guides.useZebraPreset(.faceReference)
    guides.skinReference = .init(level: 55, range: 3)
    XCTAssertEqual(guides.zebraLevel, 55)
    XCTAssertEqual(guides.zebraRange, 3)
    XCTAssertEqual(guides.skinTone, .medium)
    XCTAssertEqual(CameraGuides.SkinTone.deep.reference, .init(level: 45, range: 2))
    XCTAssertEqual(CameraGuides.SkinTone.fair.reference, .init(level: 68, range: 3))
    XCTAssertNil(CameraGuides.SkinTone.custom.reference)
    let store = CameraGuideStore(defaults: freshDefaults("AlphaExposurePerCamera"))
    store.set(guides, for: "one")
    XCTAssertEqual(store.guides(for: "one").skinReference, .init(level: 55, range: 3))
    XCTAssertEqual(store.guides(for: "two").skinReference, .init(level: 45, range: 2))
  }

  func testCustomChoiceAndZebraStatusPersist() throws {
    var guides = CameraGuides.firstUse
    guides.selectedSkinTone = .custom
    guides.zebras = false
    let decoded = try JSONDecoder().decode(CameraGuides.self, from: JSONEncoder().encode(guides))
    XCTAssertEqual(decoded.skinTone, .custom)
    XCTAssertEqual(decoded.exposure.zebraReadout, "Zebras off · Target 43 to 47 IRE")
    guides.zebras = true
    XCTAssertEqual(guides.exposure.zebraReadout, "Stripes on 43 to 47 IRE")
  }

  func testGreyCardRestoresSettingsAfterPersistence() throws {
    var guides = CameraGuides.firstUse
    guides.useZebraPreset(.brightAreas)
    guides.zebras = false
    guides.skinReference = .init(level: 61, range: 4)
    guides.savedRangeLevel = 52; guides.savedRangeWidth = 5; guides.savedLimitLevel = 91
    let original = guides
    guides.greyCardCheck = true
    XCTAssertEqual(guides.zebraLevel, 41)
    XCTAssertEqual(guides.zebraRange, 2)
    XCTAssertTrue(guides.zebras && guides.falseColour)
    XCTAssertEqual(guides.exposure.colourTable[Int(CameraExposure.code(ire: 41))], 0xFF00_C800)
    XCTAssertFalse(guides.exposure.legendBands.contains { $0.label == "My skin" })
    guides = try JSONDecoder().decode(CameraGuides.self, from: JSONEncoder().encode(guides))
    guides.greyCardCheck = false
    XCTAssertEqual(guides, original)
  }

  func testMigrationAndKeyMatchRenderer() throws {
    let old = try JSONDecoder().decode(CameraGuides.self, from: Data(#"{"zebraLevel":60,"zebraRange":3}"#.utf8))
    XCTAssertEqual(old.skinReference, .init(level: 60, range: 3))
    let limit = try JSONDecoder().decode(CameraGuides.self, from: Data(#"{"zebraLevel":95,"zebraRange":0}"#.utf8))
    XCTAssertEqual(limit.skinReference, .init(level: 45, range: 2))
    let settings = old.exposure
    XCTAssertEqual(settings.legendBands.map(\.label), ["My skin", "Signal white", "Near white", "Mid grey", "Very dark", "Near black"])
    let pink = try XCTUnwrap(settings.legendBands.first { $0.label == "My skin" })
    XCTAssertEqual(pink.range, "57 to 63")
    XCTAssertEqual(settings.colourTable[Int(CameraExposure.code(ire: 60))], pink.colour)
  }

}

extension AppearanceSnapshotTests {
  func testAlphaExposureSnapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let destination = URL(fileURLWithPath: output)
    for zoom in [1.0, 2.0] {
      let scale = Int(zoom * 100)
      var guides = CameraGuides.firstUse
      guides.falseColour = true
      try await snapshot(ExposureKey(guides: guides, zoom: zoom), name: "f3-setup-key-\(scale)", size: .init(width: 400 * zoom, height: 650 * zoom), scheme: .dark, destination: destination)
      try await snapshot(ZebraAdjustView(guides: .constant(guides)).padding().uiZoom(zoom), name: "f3-zebra-\(scale)", size: .init(width: 500 * zoom, height: 850 * zoom), scheme: .dark, destination: destination)
      try await snapshot(FalseColourAdjustView(guides: .constant(guides)).padding().uiZoom(zoom), name: "f3-false-deep-\(scale)", size: .init(width: 500 * zoom, height: 1200 * zoom), scheme: .dark, destination: destination)
      guides.selectedSkinTone = .custom
      try await snapshot(FalseColourAdjustView(guides: .constant(guides)).padding().uiZoom(zoom), name: "f3-false-custom-\(scale)", size: .init(width: 500 * zoom, height: 1350 * zoom), scheme: .dark, destination: destination)
      guides.greyCardCheck = true
      try await snapshot(FalseColourAdjustView(guides: .constant(guides)).padding().uiZoom(zoom), name: "f3-false-grey-\(scale)", size: .init(width: 500 * zoom, height: 1450 * zoom), scheme: .dark, destination: destination)
    }
  }
}

@MainActor final class ExposureVisibilityG2Tests: XCTestCase {
  func testBypassedFalseColourCanBeEnabledAgain() {
    let model = CameraModel(defaults: freshDefaults("G2FalseColour"))
    model.guides.falseColour = true
    model.exposureBypassed = true
    model.cleanView = true
    XCTAssertFalse(model.effectiveFalseColour)
    model.exposureBinding(\.falseColour).wrappedValue = true
    XCTAssertTrue(model.effectiveFalseColour)
  }

  func testBypassedGreyCardFinishesWithOriginalAids() {
    for falseColour in [false, true] {
      let model = CameraModel(defaults: freshDefaults("G2GreyCard"))
      model.guides = .firstUse
      model.guides.falseColour = falseColour
      let original = model.guides
      model.exposureBypassed = true
      model.setGreyCardCheck(true)
      XCTAssertTrue(model.effectiveZebras)
      XCTAssertTrue(model.effectiveFalseColour)
      XCTAssertEqual(model.effectiveGuides.exposure.zebraReadout, "Stripes on 39 to 43 IRE")
      model.setGreyCardCheck(false)
      XCTAssertEqual(model.guides, original)
      XCTAssertEqual(model.effectiveFalseColour, falseColour)
      XCTAssertTrue(model.effectiveZebras)
    }
  }

  func testBypassPresetAndTargetRestoreZebras() {
    let model = CameraModel(defaults: freshDefaults("G2Presets"))
    for purpose in [CameraGuides.ZebraPurpose.faceReference, .brightAreas] {
      model.exposureBypassed = true
      model.chooseZebraPreset(purpose)
      XCTAssertTrue(model.effectiveZebras)
      XCTAssertEqual(model.guides.validatedZebraPurpose, purpose)
      XCTAssertTrue(model.effectiveGuides.exposure.zebraReadout.hasPrefix("Stripes on"))
    }
    model.exposureBypassed = true
    model.zebraBinding(\.zebraLevel).wrappedValue = 88
    XCTAssertTrue(model.effectiveZebras)
    XCTAssertEqual(model.effectiveGuides.zebraLevel, 88)
  }

  func testPresetEndsBypassedGreyCardWithoutEnablingFalseColour() {
    let model = CameraModel(defaults: freshDefaults("G2GreyCardPreset"))
    model.guides.falseColour = false
    model.setGreyCardCheck(true)
    model.exposureBypassed = true
    model.chooseZebraPreset(.brightAreas)
    XCTAssertFalse(model.guides.greyCardCheck)
    XCTAssertFalse(model.effectiveFalseColour)
    XCTAssertTrue(model.effectiveZebras)
  }

  func testAdvancedShapeAndSameCustomShapeRestoreGuides() {
    let model = CameraModel(defaults: freshDefaults("G2Guides"))
    for marker in [CameraAspect(width: 4, height: 5), CameraAspect(width: 2.39, height: 1)] {
      model.chooseFrameMarker(marker)
      model.framingGuidesBypassed = true
      model.cleanView = true
      XCTAssertNil(model.effectiveGuides.marker)
      model.chooseFrameMarker(marker)
      XCTAssertEqual(model.effectiveGuides.marker, marker)
      XCTAssertTrue(model.framingIsVisible)
    }
  }

  func testLegacySkinActionRestoresVisibilityFromCleanView() {
    let model = CameraModel(defaults: freshDefaults("G2LegacySkin"))
    model.cleanView = true
    model.exposureBypassed = true
    model.applySkinExposurePreset()
    XCTAssertTrue(model.effectiveZebras)
    XCTAssertFalse(model.effectiveFalseColour)
  }

  func testNumberRowsSpeakTheirOwnSubject() {
    let skin = ExposureNumberRow(title: "Level", subject: "skin reference level", value: .constant(45), limits: 0...100)
    let zebra = ExposureNumberRow(title: "Level", subject: "zebra level", value: .constant(95), limits: 0...100)
    XCTAssertEqual(skin.accessibilityLabel(increasing: true), "Increase skin reference level, currently 45 IRE")
    XCTAssertEqual(zebra.accessibilityLabel(increasing: false), "Decrease zebra level, currently 95 IRE")
  }
}
