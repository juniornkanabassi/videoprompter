import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class DesignSpecTests: XCTestCase {
  func testNewDefaultsPreserveDecodedValues() throws {
    XCTAssertEqual(PrompterSettings().videoDimming, 0.5)
    XCTAssertEqual(PrompterSettings().textWidth, 0.75)
    let saved = try JSONDecoder().decode(PrompterSettings.self, from: Data("{\"videoDimming\":0.25,\"textWidth\":1}".utf8))
    XCTAssertEqual(saved.videoDimming, 0.25)
    XCTAssertEqual(saved.textWidth, 1)
  }

  func testMicrophoneMigrationAndSharedInput() throws {
    for (following, recording, separate) in [(nil, nil, false), ("one", "one", false), ("one", "two", true)] as [(String?, String?, Bool)] {
      let defaults = freshDefaults("MicrophoneMigration")
      var settings = PrompterSettings(); settings.audioDeviceUID = following
      defaults.set(try JSONEncoder().encode(settings), forKey: "settings")
      defaults.set(recording, forKey: "recordingMicrophoneUID")
      let recorder = CameraRecorder(defaults: defaults)
      XCTAssertEqual(recorder.usesSeparateMicrophone, separate)
      XCTAssertEqual(recorder.resolvedMicrophoneUID, separate ? recording : following)
      recorder.usesSeparateMicrophone = false
      settings.audioDeviceUID = "changed"
      recorder.useSettings(settings)
      XCTAssertEqual(recorder.resolvedMicrophoneUID, "changed")
    }
  }

  func testAllRecordingSettingsAndCameraSelectionAreLockedAtModel() {
    let defaults = freshDefaults("RecordingLock")
    let recorder = CameraRecorder(defaults: defaults)
    let camera = CameraModel(defaults: defaults)
    camera.recorder = recorder
    camera.selectedUID = "one"
    recorder.microphoneUID = "one"
    let guides = camera.guides
    for phase in [CameraRecorder.Phase.preparing, .waitingForFrames, .recording, .saving] {
      recorder.phase = phase
      camera.selectedUID = "two"
      camera.guides.rotation = .quarter
      camera.guides.automaticRotation = true
      recorder.preset = .edit
      recorder.mirrorSavedVideo = true
      recorder.microphoneUID = "two"
      recorder.floatAudio = true
      recorder.takeLabel = "changed"
      recorder.usesSeparateMicrophone = true
      XCTAssertEqual(camera.selectedUID, "one")
      XCTAssertEqual(camera.guides.rotation, guides.rotation)
      XCTAssertEqual(camera.guides.automaticRotation, guides.automaticRotation)
      XCTAssertEqual(recorder.preset, .standard)
      XCTAssertFalse(recorder.mirrorSavedVideo)
      XCTAssertEqual(recorder.microphoneUID, "one")
      XCTAssertFalse(recorder.floatAudio)
      XCTAssertEqual(recorder.takeLabel, "")
      XCTAssertFalse(recorder.usesSeparateMicrophone)
      camera.guides.zebras = true
      XCTAssertTrue(camera.guides.zebras, "Monitor overlays remain usable during a take")
    }
  }

  func testCleanViewKeepsConfigurationButClearsEveryOverlay() {
    let camera = CameraModel(defaults: freshDefaults("CleanView"))
    camera.guides.thirds = true; camera.guides.axes = true; camera.guides.bullseye = true
    camera.guides.marker = CameraAspect(width: 9, height: 16)
    camera.guides.zebras = true; camera.guides.falseColour = true
    let before = camera.guides
    camera.cleanView = true
    let preview = camera.previewGuides
    XCTAssertFalse(preview.thirds); XCTAssertFalse(preview.axes); XCTAssertFalse(preview.bullseye)
    XCTAssertNil(preview.marker); XCTAssertFalse(preview.zebras); XCTAssertFalse(preview.falseColour)
    camera.cleanView = false
    XCTAssertEqual(camera.previewGuides, before)
  }

  func testUnreadyAudioIsCountedAndReported() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = try MovieWriter(url: dir.appendingPathComponent("audio.mov"), width: 16, height: 16,
      transform: .identity, preset: .standard, audio: .init(sampleRate: 48000, channels: 1), floatAudio: false)
    writer.audioReadyOverride = false
    var sample: CMSampleBuffer?
    CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
      makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
      sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    try writer.append(audio: XCTUnwrap(sample))
    XCTAssertEqual(writer.droppedAudioBuffers, 1)
    XCTAssertTrue(RecordingAudioHealth.message(drops: writer.droppedAudioBuffers, clipping: false, fresh: true).contains("Sound dropped"))
  }

  func testBatchTrashUndoRestoresBothScripts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("TrashUndo")))
    let a = try await store.createScript(title: "One", markdown: "One")
    let b = try await store.createScript(title: "Two", markdown: "Two")
    let manager = UndoManager()
    store.delete([a.id, b.id], undoManager: manager)
    XCTAssertTrue(manager.canUndo, "Undo is registered in action order, before the disk work")
    for _ in 0..<100 where !store.scripts.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(store.scripts.isEmpty)
    manager.undo()
    for _ in 0..<100 where store.scripts.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(Set(store.scripts.map(\.id)), [a.id, b.id])
    XCTAssertTrue(store.trash.isEmpty)
    XCTAssertTrue(manager.canRedo)
    manager.redo()
    for _ in 0..<100 where !store.scripts.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(store.scripts.isEmpty)
    XCTAssertTrue(manager.canUndo)
  }

  func testPresetApplyCanBeUndoneAndKeepsMicrophone() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("PresetUndo")))
    let manager = UndoManager()
    store.settings.audioDeviceUID = "original"
    let before = store.settings
    var preset = before; preset.fontSize = 80; preset.audioDeviceUID = "other"
    store.applyPreset(preset, undoManager: manager)
    XCTAssertEqual(store.settings.fontSize, 80)
    XCTAssertEqual(store.settings.audioDeviceUID, "original")
    manager.undo()
    XCTAssertEqual(store.settings.fontSize, before.fontSize)
  }

  func testPastedTitlesAndVocabulary() throws {
    XCTAssertEqual(AppStore.pastedTitle("# A heading\nBody"), "A heading")
    XCTAssertEqual(AppStore.pastedTitle("One two three four five six seven\nBody"), "One two three four five six")
    XCTAssertEqual(AppStore.pastedTitle("   "), "Pasted Script")
    XCTAssertEqual(AppStore.pastedTitle("\n\nA useful title"), "A useful title")
    XCTAssertEqual(SettingsTab.allCases.map(\.rawValue), ["General", "Reading", "Reading presets", "Microphone", "Camera & Recording"])
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    let banned = ["Set up this take", "following microphone", "Clean picture", "Dismiss receipt", "Paste as New Script", "Record camera", "Skin exposure check", "Separate Camera Monitor"]
    for case let file as URL in FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      for word in banned { XCTAssertFalse(text.contains(word), "\(file.lastPathComponent): \(word)") }
    }
  }

  func testExposureShortcutsHaveNoAppOrEnabledSystemClashes() throws {
    // Apple's default system list contains none of these. User remappings are also checked below.
    let shortcuts = [KeyboardShortcut("k", modifiers: [.command, .option]), KeyboardShortcut("z", modifiers: [.command, .option]), KeyboardShortcut("x", modifiers: [.command, .option])]
    for shortcut in shortcuts {
      for existing in [ScriptShortcuts.importFile, ScriptShortcuts.italic, ScriptShortcuts.newScript, ScriptShortcuts.library, ScriptShortcuts.camera, ScriptShortcuts.biggerText, ScriptShortcuts.smallerText] {
        XCTAssertFalse(shortcut.key == existing.key && shortcut.modifiers == existing.modifiers)
      }
    }
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.symbolichotkeys.plist")
    guard let data = try? Data(contentsOf: path), let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let keys = plist["AppleSymbolicHotKeys"] as? [String: [String: Any]] else { return }
    for key in keys.values where key["enabled"] as? Bool == true {
      if let parameters = (key["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 {
        XCTAssertFalse([40, 6, 7].contains(parameters[1]) && parameters[2] == 1572864, "Enabled global shortcut clashes")
      }
    }
  }
}
