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
    XCTAssertEqual(CameraGuides.SkinTone.fair.reference, .init(level: 65, range: 3))
    XCTAssertNil(CameraGuides.SkinTone.custom.reference)
    let store = CameraGuideStore(defaults: freshDefaults("AlphaExposurePerCamera"))
    store.set(guides, for: "one")
    XCTAssertEqual(store.guides(for: "one").skinReference, .init(level: 55, range: 3))
    XCTAssertEqual(store.guides(for: "two").skinReference, .init(level: 45, range: 2))
  }

  func testMigrationAndKeyMatchRenderer() throws {
    let old = try JSONDecoder().decode(CameraGuides.self, from: Data(#"{"zebraLevel":60,"zebraRange":3}"#.utf8))
    XCTAssertEqual(old.skinReference, .init(level: 60, range: 3))
    let limit = try JSONDecoder().decode(CameraGuides.self, from: Data(#"{"zebraLevel":95,"zebraRange":0}"#.utf8))
    XCTAssertEqual(limit.skinReference, .init(level: 45, range: 2))
    let settings = old.exposure
    XCTAssertEqual(settings.legendBands.map(\.label), ["Near black", "Very dark", "Mid grey", "My skin", "Near white", "Signal white"])
    let pink = try XCTUnwrap(settings.legendBands.first { $0.label == "My skin" })
    XCTAssertEqual(pink.range, "57 to 63")
    XCTAssertEqual(settings.colourTable[Int(CameraExposure.code(ire: 60))], pink.colour)
  }

}

extension AppearanceSnapshotTests {
  func testAlphaExposureSnapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let destination = URL(fileURLWithPath: output)
    var guides = CameraGuides.firstUse
    guides.falseColour = true
    try await snapshot(ExposureKey(guides: guides), name: "alpha-exposure-key", size: .init(width: 400, height: 650), scheme: .dark, destination: destination)
    try await snapshot(ExposureKey(guides: guides, compact: true), name: "alpha-exposure-chip", size: .init(width: 300, height: 100), scheme: .dark, destination: destination)
    try await snapshot(ZebraAdjustView(guides: .constant(guides)).padding(), name: "alpha-zebra-adjust", size: .init(width: 470, height: 600), scheme: .dark, destination: destination)
    try await snapshot(FalseColourAdjustView(guides: .constant(guides)).padding(), name: "alpha-false-colour-adjust", size: .init(width: 470, height: 650), scheme: .dark, destination: destination)
  }
}
