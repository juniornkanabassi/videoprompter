@preconcurrency import AVFoundation
import CoreMedia

import AppKit
import SwiftUI
import XCTest
import PrompterCore
@testable import VideoPrompter

private struct LiveVoiceText: View {
  @ObservedObject var session: SessionStore
  var body: some View {
    ScriptTextView(document: session.document, tokenIndex: session.tokenIndex,
      lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
      isActivelyRunning: session.isActivelyRunning, guideFraction: 0.35,
      fontName: "Helvetica", fontSize: 64, textOpacity: 1,
      highlightActiveWord: true, manualPosition: { session.voicePosition() }, onSeek: { _ in })
  }
}

@MainActor
final class VoiceRenderLatencyTests: XCTestCase {
  func testHighlightChangesInTheLayoutPassBeforeScrollCatchesUp() async throws {
    let session = SessionStore(defaults: freshDefaults("HighlightLatency"))
    var now = 0.0
    session.clock = { now }
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: .init(metadata: .init(title: "Highlight", fileName: "highlight.md"),
      markdown: "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november"), settings: settings)
    let host = NSHostingView(rootView: LiveVoiceText(session: session))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { session.pause(); window.contentView = nil; window.close() }
    XCTAssertEqual(window.alphaValue, 0)
    session.play(captureAudio: false)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    _ = session.voicePosition()
    now = 4
    _ = session.voicePosition()
    session.acceptSpeechCandidate(.init(replacementID: "partial", generation: 1,
      locale: .init(identifier: "en-GB"), text: "alpha bravo charlie delta echo foxtrot",
      range: .init(start: .zero, duration: .init(seconds: 2, preferredTimescale: 48000)), isFinal: false))
    XCTAssertEqual(session.tokenIndex, 6, "The partial must publish without a final or another word")
    XCTAssertLessThan(session.voicePosition(), 1, "Highlight must not wait for the scroll")
    // Force the representable's layout, without yielding to its deferred scroll block.
    host.rootView = LiveVoiceText(session: session)
    host.layoutSubtreeIfNeeded()
    func text(in view: NSView) -> NSTextView? {
      if let value = view as? NSTextView { return value }
      return view.subviews.lazy.compactMap { text(in: $0) }.first
    }
    let view = try XCTUnwrap(text(in: host))
    var highlighted = ""
    view.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
      if let colour = value as? NSColor, colour == NSColor.systemYellow.withAlphaComponent(1) {
        highlighted += (view.string as NSString).substring(with: range)
      }
    }
    XCTAssertEqual(highlighted.trimmingCharacters(in: .whitespacesAndNewlines), "golf")
  }

  func testPartialResultThroughHostedProductionText() async throws {
    try await replay(withExposure: false)
  }

  func testPartialResultWhileExposureAndMeterAreBusy() async throws {
    try await replay(withExposure: true)
  }

  private func replay(withExposure: Bool) async throws {
    let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let script = try String(contentsOf: root.appendingPathComponent("short-173-script.md"), encoding: .utf8)
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: .init(metadata: .init(title: "Replay", fileName: "replay.md"),
      markdown: Array(repeating: script, count: 4).joined(separator: "\n\n")), settings: settings)
    let host = NSHostingView(rootView: LiveVoiceText(session: session))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { session.pause(); window.contentView = nil; window.close() }
    XCTAssertEqual(window.alphaValue, 0)
    session.play(captureAudio: false)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    func text(in view: NSView) -> NSTextView? {
      if let value = view as? NSTextView { return value }
      return view.subviews.lazy.compactMap { text(in: $0) }.first
    }
    let view = try XCTUnwrap(text(in: host))
    var load: Task<Int, Never>?
    if withExposure {
      var pixels: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pixels), kCVReturnSuccess)
      let frame = try XCTUnwrap(pixels)
      CVPixelBufferLockBaseAddress(frame, [])
      memset(CVPixelBufferGetBaseAddressOfPlane(frame, 0), 128,
        CVPixelBufferGetBytesPerRowOfPlane(frame, 0) * CVPixelBufferGetHeightOfPlane(frame, 0))
      CVPixelBufferUnlockBaseAddress(frame, [])
      let meter = AudioMeterDelivery { peaks in session.publishMeter(peak: peaks[0], clipping: false) }
      load = Task.detached {
        let processor = CameraExposure(settings: .init()) { _ in }
        var frames = 0
        while !Task.isCancelled {
          autoreleasepool {
            _ = processor.process(frame, settings: .init(zebras: true, falseColour: true, skinLevel: 55, skinRange: 3))
          }
          meter.receive(peaks: [0.5], callback: ProcessInfo.processInfo.systemUptime)
          await MainActor.run { NotificationCenter.default.post(name: .cameraExposureDidChange, object: nil) }
          frames += 1
          try? await Task.sleep(for: .milliseconds(66))
        }
        return frames
      }
    }
    defer { load?.cancel() }
    var match: [Double] = [], update: [Double] = [], draw: [Double] = []
    for count in stride(from: 10, through: 60, by: 2) {
      let start = ProcessInfo.processInfo.systemUptime
      session.acceptSpeechCandidate(.init(replacementID: "replay", generation: 1, locale: .init(identifier: "en-GB"),
        text: session.document.spokenTokens.prefix(count).map(\.text).joined(separator: " "),
        range: CMTimeRange(start: .zero, duration: CMTime(seconds: Double(count) / 3, preferredTimescale: 48000)), isFinal: false))
      let matched = ProcessInfo.processInfo.systemUptime
      match.append(matched - start)
      let expected = session.document.spokenTokens[count].normalised
      var highlighted = ""
      repeat {
        try await Task.sleep(for: .milliseconds(5))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        view.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
          if let colour = value as? NSColor, colour == NSColor.systemYellow.withAlphaComponent(1) {
            highlighted = PrompterDocument(markdown: (view.string as NSString).substring(with: range)).spokenTokens.first?.normalised ?? ""
          }
        }
      } while highlighted != expected && ProcessInfo.processInfo.systemUptime - matched < 2
      update.append(ProcessInfo.processInfo.systemUptime - matched)
      XCTAssertEqual(highlighted, expected)
      let beforeDraw = ProcessInfo.processInfo.systemUptime
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      draw.append(ProcessInfo.processInfo.systemUptime - beforeDraw)
      XCTAssertEqual(session.tokenIndex, count)
      XCTAssertFalse(view.string.isEmpty)
    }
    if let load {
      load.cancel()
      let frames = await load.value
      XCTAssertGreaterThan(frames, 0)
      print("EXPOSURE frames processed alongside voice: \(frames)")
    }
    XCTAssertLessThan(try XCTUnwrap(update.max()), 0.5, "Partial highlights must not queue behind rendering")
    for (name, values) in [("match", match), ("update", update), ("offscreen draw", draw)] {
      let sorted = values.sorted()
      print("PRODUCTION TEXT exposure=\(withExposure) \(name) median=\(sorted[sorted.count / 2] * 1000) ms max=\(sorted.last! * 1000) ms")
    }
  }
}
