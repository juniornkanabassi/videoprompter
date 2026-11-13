import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testIPadReplicaMidRead() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("IPadReplica")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let link = IPadCameraSender(defaults: defaults)
    let id = UUID()
    let markdown = "# Match day\n\nThe opening passage sets the scene for everyone watching at home.\n\nThe midfield is finding space between the lines and moving the ball with confidence.\n\nWatch the runner on the far side as the next passage begins.\n\nThere is still time to change the game."
    let state = PadRemote.State(scripts: [.init(id: id, title: "Match day")], presenting: id, running: true,
      mode: "Manual", speed: 120, word: 20, words: PrompterDocument(markdown: markdown).spokenTokens.count,
      look: .init(horizontalMirror: true, verticalMirror: true, fontSize: 32, textWidth: 0.85),
      deviceName: "Studio iPad", appVersion: "Test", scriptPreview: "Match day", markdown: markdown)
    let imageURL = try XCTUnwrap(Bundle.module.url(forResource: "presenter-clean", withExtension: "png", subdirectory: "Fixtures"))
    let image = try XCTUnwrap(NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    for variant in ["connected-reading", "paused", "not-connected", "camera-only"] {
      var fixture = state
      if variant == "connected-reading" { fixture.mode = "Voice"; fixture.voiceSource = "Mac" }
      if variant == "paused" { fixture.running = false }
      if variant == "camera-only" { fixture.cameraOnly = true; fixture.presenting = nil }
      for zoom in [1.0, 1.5] {
      try await snapshot(IPadRemoteView(link: link, store: store, stateOverride: variant == "not-connected" ? nil : fixture, startsLink: false, previewOverride: variant == "camera-only" ? image : nil).uiZoom(zoom),
        name: "ipad-\(variant)-\(Int(zoom * 100))", size: .init(width: 960 * zoom, height: 720 * zoom),
        scheme: .dark, destination: URL(fileURLWithPath: output), settleDelay: .milliseconds(300), prepare: { host in
          guard variant == "connected-reading" || variant == "paused" else { return }
          func texts(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(texts)
          }
          let text = texts(host).first { $0.string.contains("The midfield") }
          XCTAssertNotNil(text)
          var highlights = 0
          text?.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text?.textStorage?.length ?? 0)) { value, _, _ in
            if let colour = (value as? NSColor)?.usingColorSpace(.deviceRGB), colour.redComponent > 0.8, colour.greenComponent > 0.5, colour.blueComponent < 0.4 { highlights += 1 }
          }
          XCTAssertEqual(highlights, 1, "Exactly the current word must be highlighted at \(zoom)")
        })
      }
    }
  }
}
