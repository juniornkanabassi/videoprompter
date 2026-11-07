import AppKit
import AVFoundation
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class QAFindingsRound12Tests: XCTestCase {
  private func fixture() async throws -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa12-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("QA12")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    await store.waitForInitialLoad()
    return (store, CameraModel(defaults: defaults), CameraRecorder(defaults: defaults))
  }

  func testUndoShootSetupDeletionPreservesLaterSavedSetup() async throws {
    let (store, camera, recorder) = try await fixture()
    XCTAssertTrue(store.saveShootSetup(named: "Original", camera: camera, recorder: recorder))
    let original = try XCTUnwrap(store.shootSetups.first)
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    store.deleteShootSetup(original.id, undoManager: manager)
    manager.endUndoGrouping()
    XCTAssertTrue(store.saveShootSetup(named: "Later setup", camera: camera, recorder: recorder))
    let later = try XCTUnwrap(store.shootSetups.first)
    manager.undo()
    XCTAssertEqual(Set(store.shootSetups.map(\.id)), [original.id, later.id],
      "Undo Delete Shoot Setup must restore the deleted item without deleting a setup saved afterwards")
    _ = await store.flushPendingSaves()
    let persisted = try JSONDecoder().decode([ShootSetup].self, from: XCTUnwrap(store.defaults.data(forKey: "shootSetups")))
    XCTAssertTrue(persisted.contains { $0.id == later.id }, "The unrelated setup must survive on disk too")
  }

  func testClickerWorksWhenSelectableReadingTextHasFocus() throws {
    _ = NSApplication.shared
    let panel = PresenterPanel(captureVisible: false)
    defer { panel.close() }
    let reading = TrackingTextView(frame: .init(x: 0, y: 0, width: 600, height: 300))
    reading.isEditable = false; reading.isSelectable = true
    reading.string = "One two three. Four five six."
    panel.contentView = reading
    XCTAssertTrue(panel.makeFirstResponder(reading))
    var handled: [UInt16] = []
    panel.onPassageKey = { handled.append($0); return true }
    for code: UInt16 in [49, 115, 116, 121, 123, 124] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
      XCTAssertTrue(panel.handlePassageKey(event), "Reading surface must handle clicker key \(code) after text selection")
    }
    XCTAssertEqual(handled, [49, 115, 116, 121, 123, 124])
    let field = NSTextField(string: "Take label")
    panel.contentView = field
    XCTAssertTrue(panel.makeFirstResponder(field))
    let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
      characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    let calls = handled.count
    XCTAssertFalse(panel.handlePassageKey(space), "A take-label field must keep its Space key")
    XCTAssertEqual(handled.count, calls)
  }

  func testLastTakeRestoresItsActualDurationAfterRelaunch() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa12-movie-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = CameraRecorder.fileURL(in: folder, defaultLabel: "Duration test")
    let writer = try MovieWriter(url: file, width: 320, height: 240, transform: .identity,
      preset: .standard, audio: nil, floatAudio: false)
    for frame in [0, 30, 60] {
      XCTAssertTrue(try writer.append(video: sample(frame)))
      try await Task.sleep(for: .milliseconds(80))
    }
    _ = try await writer.finish()
    let duration = try await AVURLAsset(url: file).load(.duration).seconds
    XCTAssertGreaterThan(duration, 2)
    let defaults = freshDefaults("QA12LastTake")
    defaults.set(file.path, forKey: "lastRecording")
    let reopened = CameraRecorder(defaults: defaults)
    XCTAssertEqual(reopened.lastFile, file)
    // Allow an implementation to reload the movie duration asynchronously.
    for _ in 0..<100 where reopened.lastTakeDuration == 0 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(reopened.lastTakeDuration, duration, accuracy: 0.1,
      "Last take shows 0:00 after relaunch although the saved movie is over two seconds long")
  }

  func testLongGraphemeDragExportHasVisibleNonemptyFilename() async throws {
    let (store, _, _) = try await fixture()
    // A single extended grapheme longer than the filename budget is a legal script title.
    let title = "a" + String(repeating: "\u{0301}", count: 150)
    XCTAssertEqual(title.count, 1)
    let record = try await store.createScript(title: title, markdown: "Read these words.")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa12-export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try ScriptFile(script: record).export(in: folder)
    XCTAssertFalse(file.lastPathComponent.hasPrefix("."),
      "Truncating a long grapheme must fall back to a visible name, not export the hidden file .md")
    XCTAssertFalse(file.deletingPathExtension().lastPathComponent.isEmpty)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), record.markdown)
  }

  private func sample(_ frame: Int) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
    let image = try XCTUnwrap(pixel)
    CVPixelBufferLockBaseAddress(image, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(image) {
      memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), plane == 0 ? 80 : 128,
        CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample)
    return try XCTUnwrap(sample)
  }
}
