import AppKit
import Foundation
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class InputValidationTests: XCTestCase {
  private func fixture() -> (AppStore, UserDefaults, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("validation-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("InputValidation")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), defaults, root)
  }

  func testEveryReadingNumberUsesTheSameRulesAtDecodeAndMutation() throws {
    let fields: [(String, WritableKeyPath<PrompterSettings, Double>, InputValidation.NumberRule)] = [
      ("fontSize", \.fontSize, InputValidation.fontSize), ("speed", \.speed, InputValidation.speed),
      ("textOpacity", \.textOpacity, InputValidation.textOpacity),
      ("backgroundOpacity", \.backgroundOpacity, InputValidation.backgroundOpacity),
      ("videoDimming", \.videoDimming, InputValidation.videoDimming),
      ("guideFraction", \.guideFraction, InputValidation.guideFraction),
      ("guideOpacity", \.guideOpacity, InputValidation.guideOpacity),
      ("lineSpacing", \.lineSpacing, InputValidation.lineSpacing),
      ("paragraphSpacing", \.paragraphSpacing, InputValidation.paragraphSpacing),
      ("inputGain", \.inputGain, InputValidation.inputGain), ("textWidth", \.textWidth, InputValidation.textWidth)
    ]
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    for (name, path, rule) in fields {
      for value in [-1e100, 1e100, .infinity, -.infinity, .nan, rule.range.lowerBound, rule.range.upperBound] {
        var typed = PrompterSettings(); typed[keyPath: path] = value
        XCTAssertEqual(typed[keyPath: path], rule.repair(value), name)
        let encodedValue: Any = value.isFinite ? value : value.isNaN ? "NaN" : value > 0 ? "Infinity" : "-Infinity"
        let decoded = try decoder.decode(PrompterSettings.self, from: JSONSerialization.data(withJSONObject: [name: encodedValue]))
        XCTAssertEqual(decoded[keyPath: path], rule.repair(value), name)
      }
      let wrongType = try decoder.decode(PrompterSettings.self, from: JSONSerialization.data(withJSONObject: [name: ["broken": true], "name": "Keep this preset"]))
      XCTAssertTrue(rule.accepts(wrongType[keyPath: path]))
      XCTAssertEqual(wrongType.name, "Keep this preset")
    }
  }

  func testCorruptPreferencesFileOpensSafeSettingsAndPresenter() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-preferences-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("CorruptPreferencesFile")
    let reading = Data(#"{"fontSize":"wrong type","textOpacity":1e100,"speed":-1e100,"rotation":9223372036854775807,"alignment":"invalid","fontWeight":"invalid","textColorHex":"ＦＦＦＦＦＦ","mode":"Manual","name":"Keep me"}"#.utf8)
    let file = root.appendingPathComponent("corrupt-preferences.plist")
    let plist: [String: Any] = ["settings": reading, "presets": Data("[\(String(decoding: reading, as: UTF8.self))]".utf8),
      "editorTypography": Data(#"{"sourceFontSize":1e100,"previewFontSize":"broken"}"#.utf8),
      "uiZoom": Double.infinity, "cameraGuides": ["test-camera": Data(#"{"thirds":true,"opacity":1e100,"zebraLevel":9223372036854775807,"marker":{"width":0,"height":9}}"#.utf8)]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
    let loaded = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
    for (key, value) in loaded { defaults.set(value, forKey: key) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    await store.waitForInitialLoad()
    XCTAssertTrue(store.libraryAvailable)
    XCTAssertEqual(store.settings.fontSize, 44)
    XCTAssertEqual(store.settings.textOpacity, 1)
    XCTAssertEqual(store.settings.speed, 20)
    XCTAssertEqual(store.settings.rotation, 0)
    XCTAssertEqual(store.settings.textColorHex, "#FFFFFF")
    XCTAssertEqual(store.settings.fontWeight, "Regular")
    XCTAssertEqual(store.settings.alignment, "Left")
    XCTAssertEqual(store.presets.first?.name, "Keep me")
    XCTAssertEqual(store.sourceFontSize, 40)
    XCTAssertEqual(store.previewFontSize, 18)
    XCTAssertEqual(store.uiZoom, 1)
    let guides = CameraGuideStore(defaults: defaults).guides(for: "test-camera")
    XCTAssertTrue(guides.thirds)
    XCTAssertNil(guides.marker)
    XCTAssertEqual(guides.opacity, 1)
    XCTAssertEqual(guides.zebraLevel, 100)
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    let actions = ControlActions(store: store, camera: camera, recorder: recorder)
    let reply = await actions.handle("settings_get", [:])
    XCTAssertEqual(reply.body["ok"] as? Bool, true)
    let record = try await store.createScript(title: "Safe startup", markdown: "One two three")
    store.session.present(record: record, settings: store.settings)
    let (window, _) = await LibraryAX.host(PresenterView(store: store, session: store.session,
      draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
    LibraryAX.close(window)
    _ = await store.flushPendingSaves()
    let reopened = try JSONDecoder().decode(PrompterSettings.self, from: XCTUnwrap(defaults.data(forKey: "settings")))
    XCTAssertEqual(reopened, store.settings)
  }

  func testCLIRangesShareReadingRulesAndRejectNonFiniteInput() throws {
    let command = try XCTUnwrap(ControlProtocol.commands.first { $0.action == "settings_set" })
    let mapping: [(String, InputValidation.NumberRule, Bool)] = [
      ("speed", InputValidation.speed, false), ("textSize", InputValidation.fontSize, false),
      ("textVisibility", InputValidation.textOpacity, true), ("textWidth", InputValidation.textWidth, true),
      ("backgroundDarkness", InputValidation.backgroundOpacity, true), ("readingLine", InputValidation.guideFraction, true),
      ("readingLineVisibility", InputValidation.guideOpacity, true), ("lineSpacing", InputValidation.lineSpacing, true),
      ("paragraphSpacing", InputValidation.paragraphSpacing, true), ("microphoneVolume", InputValidation.inputGain, true)
    ]
    for (name, rule, percent) in mapping {
      let param = try XCTUnwrap(command.params.first { $0.name == name })
      XCTAssertEqual(param.range, percent ? rule.percentRange : rule.range)
      for invalid in ["nan", "inf", "1e100", "-1e100", "", "１２３"] { XCTAssertFalse(param.accepts(invalid), name) }
      XCTAssertTrue(param.accepts(String(Int(try XCTUnwrap(param.range).lowerBound))), name)
      XCTAssertTrue(param.accepts(String(Int(try XCTUnwrap(param.range).upperBound))), name)
    }
  }

  func testTypedEditorAndGuideValuesAreRepairedBeforeUse() {
    let (store, defaults, _) = fixture()
    store.sourceFontSize = .nan; store.previewFontSize = .infinity; store.uiZoom = .nan
    XCTAssertEqual(store.sourceFontSize, 18); XCTAssertEqual(store.previewFontSize, 18); XCTAssertEqual(store.uiZoom, 1)
    let camera = CameraModel(defaults: defaults)
    camera.guides.opacity = .nan; camera.guides.shadeOpacity = .infinity
    camera.guides.zebraLevel = Int.max; camera.guides.zebraRange = Int.min
    XCTAssertEqual(camera.guides.opacity, 0.85); XCTAssertEqual(camera.guides.shadeOpacity, 0.5)
    XCTAssertEqual(camera.guides.zebraLevel, 100); XCTAssertEqual(camera.guides.zebraRange, 0)
    XCTAssertNotNil(camera.guides.zebraWarning)
  }

  func testBothExposureToolsClearBypassThroughModelAndCLI() async {
    let (store, defaults, _) = fixture()
    let camera = CameraModel(defaults: defaults)
    for key in [\CameraGuides.zebras, \CameraGuides.falseColour] {
      camera.guides[keyPath: key] = false
      camera.exposureBypassed = true
      camera.guides[keyPath: key] = true
      XCTAssertFalse(camera.exposureBypassed)
      XCTAssertTrue(camera.previewGuides[keyPath: key])
    }
    let actions = ControlActions(store: store, camera: camera, recorder: CameraRecorder(defaults: defaults))
    camera.guides.falseColour = false; camera.exposureBypassed = true
    let reply = await actions.handle("camera_guides", ["falseColour": "on"])
    XCTAssertEqual(reply.body["ok"] as? Bool, true)
    XCTAssertTrue(camera.previewGuides.falseColour)
  }

  func testUnicodeFilenamesAreWritableUniqueAndPreserveOriginals() async throws {
    let (_, _, root) = fixture()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let family = "👨‍👩‍👧‍👦"
    XCTAssertTrue(InputValidation.filename(String(repeating: family, count: 100), fallback: "Take", suffix: ".mov").hasPrefix(family))
    let names = [String(repeating: "👍🏿", count: 100), String(repeating: "👨‍👩‍👧‍👦", count: 100),
      String(repeating: "e\u{301}", count: 200), "..", " /:\\\u{0}\n ", "é" + String(repeating: "\u{301}", count: 300)]
    for name in names {
      let first = CameraRecorder.fileURL(in: root, label: name)
      try Data("original".utf8).write(to: first)
      let next = CameraRecorder.fileURL(in: root, label: name)
      XCTAssertNotEqual(first, next)
      try Data().write(to: next)
      XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original")
      for url in [first, next, ICloudScripts.freeURL(for: name, in: root)] {
        XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 240)
        XCTAssertLessThanOrEqual(url.lastPathComponent.utf16.count, 240)
        XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
        try Data().write(to: url)
      }
    }
    let library = try MarkdownLibrary(rootURL: root.appendingPathComponent("library"))
    _ = try await library.create(title: String(repeating: "漢", count: 100), markdown: "Safe script")
  }

  func testSavedLanguageAndDiscreteChoicesAreValidated() throws {
    for value in ["", "not a language", "en--GB", "😃", "en\u{0}GB"] {
      let data = try JSONSerialization.data(withJSONObject: ["speechLanguage": value, "rotation": 90, "fontWeight": "Invalid", "alignment": "Invalid"])
      let decoded = try JSONDecoder().decode(PrompterSettings.self, from: data)
      XCTAssertEqual(decoded.speechLanguage, "Automatic")
      XCTAssertEqual(decoded.rotation, 0)
      XCTAssertEqual(decoded.fontWeight, "Regular")
      XCTAssertEqual(decoded.alignment, "Left")
    }
    for value in ["en-GB", "de-DE", "zh-Hans-HK", "en_US", "French", "Mixed"] {
      XCTAssertEqual(InputValidation.language(value), value)
    }
  }

  func testCorruptWindowGeometryIsIgnored() {
    let (_, defaults, _) = fixture()
    let screen = PresenterFrameMemory.Screen(id: 1, name: "Test", frame: .init(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: .init(x: 0, y: 0, width: 1920, height: 1080))
    for rect in ["{{nan, 0}, {800, 600}}", "{{0, inf}, {800, 600}}", "{{0, 0}, {inf, 600}}"] {
      defaults.set(["offset": rect, "display": 1, "name": "Test"], forKey: PresenterFrameMemory.key)
      XCTAssertNil(PresenterFrameMemory.restored(from: defaults, screens: [screen]))
    }
  }
}
