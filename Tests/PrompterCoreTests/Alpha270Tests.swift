import AVFoundation
import AppKit
import SwiftUI
import PrompterCore
import XCTest
@testable import VideoPrompter

final class Alpha270Tests: XCTestCase {
  func testChannelsOnBothFloatLayouts() throws {
    for interleaved in [true, false] {
      let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved))
      let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
      input.frameLength = 3
      let data = try XCTUnwrap(input.floatChannelData)
      for i in 0..<3 {
        if interleaved { data[0][i * 2] = Float(i + 1); data[0][i * 2 + 1] = -Float(i + 1) }
        else { data[0][i] = Float(i + 1); data[1][i] = -Float(i + 1) }
      }
      XCTAssertTrue(AudioChannel.both.extract(input) === input)
      for channel in [AudioChannel.left, .right] {
        let output = try XCTUnwrap(channel.extract(input))
        XCTAssertEqual(output.format.channelCount, 1)
        XCTAssertEqual(output.frameLength, 3)
        for i in 0..<3 { XCTAssertEqual(output.floatChannelData![0][i], Float(i + 1) * (channel == .left ? 1 : -1)) }
      }
    }
  }
  func testChannelPreferencesArePerDevice() {
    let defaults = freshDefaults("Alpha270Channels")
    XCTAssertEqual(AudioChannel.load("atem", defaults: defaults), .both)
    AudioChannel.left.save("atem", defaults: defaults)
    AudioChannel.right.save("usb", defaults: defaults)
    XCTAssertEqual(AudioChannel.load("atem", defaults: defaults), .left)
    XCTAssertEqual(AudioChannel.load("usb", defaults: defaults), .right)
    AudioChannel.both.save("atem", defaults: defaults)
    XCTAssertEqual(AudioChannel.load("atem", defaults: defaults), .both)
  }
  func testWelcomeLanguagesAndNewDefaults() {
    XCTAssertEqual(ScriptLanguage.detect(WelcomeScript.monitorMarkdown), .english)
    XCTAssertEqual(PrompterSettings().mode, "Voice")
    XCTAssertEqual(PrompterSettings().speechLanguage, "Automatic")
  }
}

extension AppearanceSnapshotTests {
  func testAlpha270Snapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let destination = URL(fileURLWithPath: output)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Alpha270Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults, offersWelcomeScript: true))
    await store.waitForWelcomeScript()
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    store.settings.audioDeviceUID = "atem"
    var atem = AudioInputDevice(id: 1, uid: "atem", name: "ATEM Mini Extreme ISO G2")
    atem.channels = 2; atem.connection = "Thunderbolt"
    var virtual = AudioInputDevice(id: 2, uid: "loopback", name: "Loopback Audio")
    virtual.channels = 2; virtual.connection = "Virtual"
    try await snapshot(AdjustPanel(selection: .constant(.mic), showsMic: .constant(true), camera: camera, store: store, startsMeter: false, microphonesOverride: [atem, virtual], recorder: recorder), name: "alpha-270-adjust-mic", size: .init(width: 540, height: 1100), scheme: .dark, destination: destination)
    camera.displayMode = .videoOnly
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for width in [900.0, 1600.0] {
        let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: store.selected!), camera: camera, startsCamera: false, recorder: recorder).defaultAppStorage(defaults)
        try await snapshot(view, name: "alpha-270-bar-\(Int(width))-\(Int(zoom * 100))", size: .init(width: width, height: 1200), scheme: .dark, destination: destination)
      }
    }
    store.uiZoom = 1
    try await snapshot(LibraryView(store: store, camera: camera), name: "alpha-270-welcome-library", size: .init(width: 1440, height: 900), scheme: .dark, destination: destination)
  }
}

extension Alpha270Tests {
  func testRecordingExtractionPreservesTimeAndUsesChosenChannel() throws {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
    let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
    input.frameLength = 2
    [Float(0.2), 0.8, 0.4, 0.6].enumerated().forEach { input.floatChannelData![0][$0.offset] = $0.element }
    var sample: CMSampleBuffer?
    let time = CMTime(value: 123, timescale: 100)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: 2, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
    let buffer = try XCTUnwrap(sample)
    XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: input.audioBufferList), noErr)
    CMSampleBufferSetDataReady(buffer)
    for (channel, peak) in [(AudioChannel.left, Float(0.4)), (.right, 0.8)] {
      let selected = try XCTUnwrap(channel.extract(buffer))
      XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(selected), time)
      XCTAssertEqual(CMSampleBufferGetNumSamples(selected), 2)
      XCTAssertEqual(RecordingAudioTest.channelPeaks(in: selected), [peak])
    }
  }

  @MainActor func testFooterControlsDoNotOverlapAtAllScales() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Alpha270Footer")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Test", markdown: "Read this test script.")
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .videoOnly
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for width in [900.0, 1600.0] {
        let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: CameraRecorder(defaults: defaults)).defaultAppStorage(defaults)
        let (window, host) = await LibraryAX.host(view, size: .init(width: width, height: 1200))
        defer { LibraryAX.close(window) }
        let frames = try ["Start reading", "Back to start", "Open script"].map { label -> NSRect in
          let button = try XCTUnwrap(LibraryAX.named(label, in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" }, label)
          let frame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
          XCTAssertGreaterThanOrEqual(frame.height, 44)
          return frame
        }
        for i in 0..<frames.count { for j in (i + 1)..<frames.count {
          XCTAssertFalse(frames[i].intersects(frames[j]), "Overlap at \(width), \(zoom): \(frames)")
        } }
      }
    }
  }
}
