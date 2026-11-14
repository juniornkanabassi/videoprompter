import AppKit
import CoreText
import SwiftUI
import PrompterCore
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testPadHUDMacReferences() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
    for file in ["LexendDeca-Variable.ttf", "Lexend-Variable.ttf"] {
      CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(file) as CFURL, .process, nil)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("PadHUDReference")
    let store = flushedAtTeardown(AppStore(arguments: ["snapshot", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Matchday preview", markdown: """
      # Matchday preview

      Good evening, and welcome to the show. Tonight we look at how the title race has turned on a single weekend, and why the team in second place may be the happier one.

      First, the champions. They won again, but it was not pretty, and the manager knew it. Three shots on target all night, one of them a penalty.

      Second, the chasing pack. A late winner in the north, a comeback in the capital, and a goalkeeper who will want to forget his Saturday.

      Finally, the one result nobody saw coming. We will take it apart, minute by minute, and ask what it means for the run in.
      """)
    store.settings.fontSize = 48
    store.settings.textWidth = 0.75
    store.settings.highlightActiveWord = true
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    store.session.seek(to: 24)
    for size in [CGSize(width: 1180, height: 820), CGSize(width: 1366, height: 1024)] {
      let view = ZStack(alignment: .top) {
        Color.black
        PresenterReadingLine(settings: store.settings)
          .frame(width: size.width - 2 * ScriptTextView.sideInset(width: size.width, textWidth: store.settings.textWidth) + 2 * Space.xxl)
          .offset(y: size.height * 0.35 - PresenterReadingLine.bandHeight(fontSize: 48))
        ScriptTextView(document: store.session.document, tokenIndex: 24, lastConfirmedTokenIndex: 23,
          guideFraction: 0.35, fontName: store.settings.fontName, fontSize: 48, textOpacity: 1,
          horizontalMargin: ScriptTextView.sideInset(width: size.width, textWidth: store.settings.textWidth),
          highlightActiveWord: true, onSeek: { _ in })
      }
      try await snapshot(view, name: "mac-text-\(Int(size.width))x\(Int(size.height))", size: size,
        scheme: .dark, destination: URL(fileURLWithPath: output))
    }
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    let picture = NSImage(size: NSSize(width: 960, height: 540), flipped: false) { bounds in
      NSColor(white: 0.18, alpha: 1).setFill(); bounds.fill(); return true
    }
    for state in ["setup", "camera-only", "reading-camera", "mirrored-flipped"] {
      camera.displayMode = state == "camera-only" ? .videoOnly : .prompterWithVideo
      store.settings.horizontalMirror = state == "mirrored-flipped"
      store.settings.verticalMirror = state == "mirrored-flipped"
      let shell = PresenterShell(reading: state == "reading-camera" || state == "mirrored-flipped", scriptPreview: state != "camera-only")
      for size in [CGSize(width: 1180, height: 820), CGSize(width: 1366, height: 1024), CGSize(width: 834, height: 1194)] {
        recorder.inputMeter.show(peakDBFS: -9, isClipping: false)
        let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record),
          camera: camera, startsCamera: false, recorder: recorder, shell: shell, referencePicture: picture,
          sourceInfoOverride: CameraSourceInfo(displayName: "Camera", connection: .hdmiCapture, width: 1920, height: 1080, nominalFrameRate: 25))
        try await snapshot(view, name: "mac-\(state)-\(Int(size.width))x\(Int(size.height))", size: size, scheme: .dark, destination: URL(fileURLWithPath: output))
      }
    }
  }
}
