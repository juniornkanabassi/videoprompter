import AVFoundation
import Combine
import XCTest

@testable import VideoPrompter
import PrompterCore

@MainActor
final class SessionStoreTests: XCTestCase {
  private func record() -> ScriptRecord {
    ScriptRecord(
      metadata: ScriptMetadata(title: "Test", fileName: "test.md"), markdown: "One two three")
  }

  func testMeterPublishesAtMostTwentyTimesASecondAndKeepsTheLoudestPeak() {
    let session = SessionStore()
    // Buffers arrive at about 47 Hz; each publish re-renders every view observing the session.
    session.publishMeter(peak: 0.5, clipping: false)
    let first = session.audioPeakDBFS
    session.publishMeter(peak: 0.9, clipping: false)
    XCTAssertEqual(session.audioPeakDBFS, first, "A second buffer within 50 ms must not publish.")
    Thread.sleep(forTimeInterval: 0.06)
    session.publishMeter(peak: 0.1, clipping: false)
    XCTAssertEqual(
      session.audioPeakDBFS, AudioCapture.decibels(fullScalePeak: 0.9), accuracy: 0.001,
      "The loudest buffer since the last publish must survive the throttle.")
  }

  func testMeterChangesDoNotRepublishTheSession() {
    // The presenter observes the session; the level moving must wake only the meters.
    let session = SessionStore()
    var sessionChanges = 0
    var meterChanges = 0
    let sessionWatch = session.objectWillChange.sink { sessionChanges += 1 }
    let meterWatch = session.meter.objectWillChange.sink { meterChanges += 1 }
    session.publishMeter(peak: 0.5, clipping: false)
    XCTAssertEqual(sessionChanges, 0)
    XCTAssertGreaterThan(meterChanges, 0)
    XCTAssertEqual(session.audioPeakDBFS, AudioCapture.decibels(fullScalePeak: 0.5), accuracy: 0.001)
    meterChanges = 0
    session.meter.reset()
    session.meter.reset()
    XCTAssertEqual(meterChanges, 1, "A reset of a silent meter must not publish again.")
    withExtendedLifetime((sessionWatch, meterWatch)) {}
  }

  func testReadingPositionsSurviveRelaunchAndRemapEditsPerScript() {
    let suite = "VideoPrompterPositionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let now = 10.0
    let first = record()
    var second = record()
    second.metadata.id = UUID()
    second.markdown = "Alpha beta gamma delta"
    let manual = PrompterSettings()
    let session = SessionStore(defaults: defaults)
    session.clock = { now }
    session.present(record: first, settings: manual)
    session.seek(to: 1)
    session.pause()
    session.present(record: second, settings: manual)
    session.seek(to: 2)
    session.pause()

    let relaunched = SessionStore(defaults: defaults)
    relaunched.present(record: first, settings: manual)
    XCTAssertEqual(relaunched.tokenIndex, 1)
    XCTAssertEqual(relaunched.lastConfirmedTokenIndex, 0)
    relaunched.present(record: second, settings: manual)
    XCTAssertEqual(relaunched.tokenIndex, 2)

    var edited = first
    edited.metadata.revision += 1
    edited.markdown = "New words.\n\nOne two three"
    let editedSession = SessionStore(defaults: defaults)
    editedSession.present(record: edited, settings: manual)
    XCTAssertEqual(editedSession.document.spokenTokens[editedSession.tokenIndex].text, "two")

    editedSession.restart()
    let afterRestart = SessionStore(defaults: defaults)
    afterRestart.present(record: edited, settings: manual)
    XCTAssertEqual(afterRestart.tokenIndex, 0)
    afterRestart.seek(to: 2)
    afterRestart.pause()
    afterRestart.forgetPosition(for: edited.id)
    let afterDelete = SessionStore(defaults: defaults)
    afterDelete.present(record: edited, settings: manual)
    XCTAssertEqual(afterDelete.tokenIndex, 0)
  }

  func testMissingAudioInputPausesAndPreservesAnchor() {
    let session = SessionStore()
    session.present(record: record(), settings: PrompterSettings())
    let anchor = session.anchor
    session.play()

    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertEqual(session.anchorNotice, "Choose a microphone in Presenter settings")
    session.play(captureAudio: false)
    XCTAssertEqual(session.state, .running)
    XCTAssertNil(session.anchorNotice)
    session.pause()
  }

  func testRelevantSettingsClearMissingMicrophoneNoticeWithoutMovingAnchor() {
    for change in ["mode", "microphone", "language"] {
      let session = SessionStore()
      var settings = PrompterSettings()
      session.present(record: record(), settings: settings)
      session.seek(to: 1)
      session.play()
      let anchor = session.anchor
      XCTAssertNotNil(session.anchorNotice)
      settings.fontSize += 1
      session.updateSettings(settings)
      XCTAssertNotNil(session.anchorNotice, "appearance changes keep useful guidance")
      if change == "mode" { settings.mode = "Manual" }
      if change == "microphone" { settings.audioDeviceUID = "disposable-not-opened" }
      if change == "language" { settings.speechLanguage = "French" }
      session.updateSettings(settings)
      XCTAssertNil(session.anchorNotice, change)
      XCTAssertEqual(session.anchor, anchor)
      XCTAssertEqual(session.state, .paused)
    }
  }

  func testLeavingVoiceOrChangingDeviceCancelsPendingMicrophoneTest() throws {
    let devices = AudioCapture.inputDevices()
    try XCTSkipIf(devices.isEmpty, "a connected device is required to exercise the pending test")
    let device = try XCTUnwrap(devices.first)
    for change in ["mode", "microphone"] {
      let session = SessionStore()
      var settings = PrompterSettings()
      settings.audioDeviceUID = device.uid
      session.present(record: record(), settings: settings)
      let anchor = session.anchor
      // No suspension: the permission/capture task cannot run before updateSettings cancels it.
      session.startMicrophoneTest(deviceUID: device.uid, gain: 1)
      XCTAssertTrue(session.isTestingMicrophone)
      if change == "mode" { settings.mode = "Manual" }
      else { settings.audioDeviceUID = nil }
      session.updateSettings(settings)
      XCTAssertFalse(session.isTestingMicrophone, change)
      XCTAssertEqual(session.anchor, anchor)
      XCTAssertEqual(session.state, .paused)
    }
  }

  func testTogglePausesAndResumesManualSession() {
    let session = SessionStore()
    var settings = PrompterSettings()
    settings.mode = "Manual"
    session.present(record: record(), settings: settings)
    session.play()
    XCTAssertEqual(session.state, .running)
    session.toggle()
    XCTAssertEqual(session.state, .paused)
    session.toggle()
    XCTAssertEqual(session.state, .running)
    session.pause()
  }

  func testSwitchingToManualKeepsAnActiveSessionRunningFromTheCurrentWord() {
    var now = 100.0
    let session = manualSession(speed: 60, at: { now })
    var voice = PrompterSettings(); voice.mode = "Voice"
    session.updateSettings(voice)
    session.play(captureAudio: false)
    session.seek(to: 3)
    var manual = voice; manual.mode = "Manual"; manual.speed = 60
    session.updateSettings(manual)
    XCTAssertEqual(session.state, .running)
    XCTAssertEqual(session.manualPosition(), 3, accuracy: 1e-9)
    now += 2
    XCTAssertEqual(session.manualPosition(), 5, accuracy: 1e-9)
    session.pause()
  }

  func testOldSettingsDecodeWithMixedLanguageDefault() throws {
    let value = try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"mode":"Voice","speed":120}"#.utf8))
    XCTAssertEqual(value.speechLanguage, "Mixed")
    XCTAssertTrue(value.allowsBackwardVoiceTracking)
  }

  // MARK: Mode migration

  private func decodedMode(_ raw: String) throws -> String {
    try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"mode":"\#(raw)","soundThreshold":0.3}"#.utf8)).mode
  }

  func testSavedModesMigrateToVoiceAndManualAndIgnoreTheOldThreshold() throws {
    XCTAssertEqual(try decodedMode("Voice"), "Voice")
    XCTAssertEqual(try decodedMode("Timed"), "Manual")
    XCTAssertEqual(try decodedMode("Manual"), "Manual")
    XCTAssertEqual(try decodedMode("Sound"), "Voice")
    XCTAssertEqual(try decodedMode("Telepathy"), "Voice", "an unknown mode falls back to Voice")
    let encoded = try String(decoding: JSONEncoder().encode(PrompterSettings()), as: UTF8.self)
    XCTAssertFalse(encoded.contains("soundThreshold"))
  }

  private func migrationStore(_ defaults: UserDefaults, root: URL) -> AppStore {
    AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
  }
  private func freshDefaults() -> UserDefaults {
    let name = "VideoPrompterTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }

  func testLegacySettingsAndPresetsMigrateAndApplyingAnOldPresetUsesTheNewMode() {
    let defaults = freshDefaults()
    defaults.set(Data(#"{"mode":"Timed","speed":90}"#.utf8), forKey: "settings")
    defaults.set(Data(#"[{"name":"Old sound","mode":"Sound"},{"name":"Old manual","mode":"Manual"}]"#.utf8), forKey: "presets")
    let store = migrationStore(defaults, root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    XCTAssertEqual(store.settings.mode, "Manual")
    XCTAssertEqual(store.settings.speed, 90)
    XCTAssertEqual(store.presets.map(\.mode), ["Voice", "Manual"])
    var stale = store.presets[0]
    stale.mode = "Timed"
    store.applyPreset(stale)
    XCTAssertEqual(store.settings.mode, "Manual", "an old preset applies with the normalised mode")
    stale.mode = "Sound"
    store.applyPreset(stale)
    XCTAssertEqual(store.settings.mode, "Voice")
  }

  func testMigrationNoticeShowsOnceAndOnlyForALegacyMode() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // Nothing saved, or only Voice: no notice.
    let clean = freshDefaults()
    XCTAssertNil(migrationStore(clean, root: root).modeMigrationNotice)
    clean.set(Data(#"{"mode":"Voice"}"#.utf8), forKey: "settings")
    XCTAssertNil(migrationStore(clean, root: root).modeMigrationNotice)

    for legacy in ["Timed", "Sound", "Manual"] {
      let defaults = freshDefaults()
      defaults.set(Data(#"{"mode":"\#(legacy)"}"#.utf8), forKey: "settings")
      let store = migrationStore(defaults, root: root)
      XCTAssertNotNil(store.modeMigrationNotice, "\(legacy) was saved by an older build")
      XCTAssertEqual(defaults.integer(forKey: "modeMigrationNoticeVersion"), 0, "not remembered until dismissed")
      XCTAssertNotNil(migrationStore(defaults, root: root).modeMigrationNotice, "a relaunch keeps it until dismissed")
      store.dismissModeMigrationNotice()
      XCTAssertNil(store.modeMigrationNotice)
      XCTAssertEqual(defaults.integer(forKey: "modeMigrationNoticeVersion"), 1)
      XCTAssertNil(migrationStore(defaults, root: root).modeMigrationNotice, "shown once")
    }
    // A legacy mode only in a preset counts too.
    let preset = freshDefaults()
    preset.set(Data(#"[{"mode":"Sound"}]"#.utf8), forKey: "presets")
    XCTAssertNotNil(migrationStore(preset, root: root).modeMigrationNotice)
  }

  // MARK: Manual timeline

  /// Ten words at 60 wpm: one token a second, so the position reads as elapsed seconds.
  private func manualSession(speed: Double = 60, at clock: @escaping () -> TimeInterval)
    -> SessionStore
  {
    let session = SessionStore()
    session.clock = clock
    var settings = PrompterSettings(); settings.mode = "Manual"; settings.speed = speed
    session.present(
      record: ScriptRecord(
        metadata: ScriptMetadata(title: "Ten", fileName: "ten.md"),
        markdown: "one two three four five six seven eight nine ten"),
      settings: settings)
    return session
  }

  func testManualAdvancesFractionallyOnTheMonotonicClockAndPublishesWholeTokens() {
    var now = 100.0
    let session = manualSession { now }
    XCTAssertEqual(session.manualPosition(), 0)
    session.play()
    XCTAssertEqual(session.state, .running)
    now = 100.5
    XCTAssertEqual(session.manualPosition(), 0.5, accuracy: 1e-9)
    XCTAssertEqual(session.tokenIndex, 0, "the published frontier moves a token at a time")
    now = 102.5
    XCTAssertEqual(session.manualPosition(), 2.5, accuracy: 1e-9)
    session.syncManualFrontier()
    XCTAssertEqual(session.tokenIndex, 2)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 1)
    XCTAssertEqual(session.manualPosition(), 2.5, accuracy: 1e-9, "syncing does not move the fraction")
    session.pause()
  }

  func testManualSpeedChangeContinuesFromTheCurrentFractionWithoutAJump() {
    var now = 100.0
    let session = manualSession { now }
    session.play()
    now = 102.5
    var faster = session.settings; faster.speed = 120
    session.updateSettings(faster)
    XCTAssertEqual(session.manualPosition(), 2.5, accuracy: 1e-9)
    now = 103
    XCTAssertEqual(session.manualPosition(), 3.5, accuracy: 1e-9, "two tokens a second from 2.5")
    var slower = faster; slower.speed = 30
    session.updateSettings(slower)
    now = 105
    XCTAssertEqual(session.manualPosition(), 4.5, accuracy: 1e-9)
    // Unrelated settings changes do not rebase.
    var french = slower; french.speechLanguage = "French"
    session.updateSettings(french)
    now = 107
    XCTAssertEqual(session.manualPosition(), 5.5, accuracy: 1e-9)
    session.pause()
  }

  func testManualPauseFreezesTheExactFractionAndResumeContinuesThere() {
    var now = 100.0
    let session = manualSession { now }
    session.play()
    now = 103.25
    session.pause()
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.manualPosition(), 3.25, accuracy: 1e-9)
    XCTAssertEqual(session.tokenIndex, 3)
    now = 500
    XCTAssertEqual(session.manualPosition(), 3.25, accuracy: 1e-9, "paused time does not count")
    session.play()
    XCTAssertEqual(session.manualPosition(), 3.25, accuracy: 1e-9)
    now = 501
    XCTAssertEqual(session.manualPosition(), 4.25, accuracy: 1e-9)
    session.play()
    XCTAssertEqual(session.manualPosition(), 4.25, accuracy: 1e-9, "a second Play does not restart the clock")
    session.pause()
  }

  func testManualSeekPassageAndRestartRebaseAndAPausedSeekStaysPaused() {
    var now = 100.0
    let session = manualSession { now }
    session.play()
    now = 101.7
    let revision = session.seekRevision
    session.seek(to: 6)
    XCTAssertEqual(session.seekRevision, revision + 1)
    XCTAssertEqual(session.manualPosition(), 6, accuracy: 1e-9)
    XCTAssertEqual(session.state, .running)
    now = 102
    XCTAssertEqual(session.manualPosition(), 6.3, accuracy: 1e-9)
    session.pause()
    session.seek(to: 2)
    XCTAssertEqual(session.state, .paused, "a paused seek stays paused")
    now = 200
    XCTAssertEqual(session.manualPosition(), 2, accuracy: 1e-9)
    session.play()
    session.nextPassage()
    XCTAssertEqual(session.manualPosition(), 9, accuracy: 1e-9, "one passage: next goes to the last word")
    session.previousPassage()
    XCTAssertEqual(session.manualPosition(), 0, accuracy: 1e-9)
    now = 203
    session.restart()
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.manualPosition(), 0, accuracy: 1e-9)
    XCTAssertEqual(session.tokenIndex, 0)
  }

  func testManualReachingTheEndConfirmsTheLastWordAndStopsThenPlayRestarts() {
    var now = 100.0
    let session = manualSession { now }
    session.play()
    now = 109.5
    session.syncManualFrontier()
    XCTAssertEqual(session.tokenIndex, 9)
    XCTAssertTrue(session.isActivelyRunning, "the last word is still being read")
    XCTAssertEqual(session.manualPosition(), 9, accuracy: 1e-9, "the position stops on the last word")
    now = 110
    session.syncManualFrontier()
    XCTAssertEqual(session.state, .paused)
    XCTAssertFalse(session.isActivelyRunning)
    XCTAssertTrue(session.manualCompleted)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 9)
    XCTAssertEqual(session.tokenIndex, 9)
    now = 300
    session.syncManualFrontier()
    XCTAssertEqual(session.manualPosition(), 9, accuracy: 1e-9)
    // Play after completion starts from the beginning.
    session.play()
    XCTAssertFalse(session.manualCompleted)
    XCTAssertEqual(session.state, .running)
    XCTAssertEqual(session.tokenIndex, 0)
    XCTAssertNil(session.lastConfirmedTokenIndex)
    XCTAssertEqual(session.manualPosition(), 0, accuracy: 1e-9)
    now = 301
    XCTAssertEqual(session.manualPosition(), 1, accuracy: 1e-9)
    // Completing again, a seek comes before Play: it starts from the seek.
    now = 320
    session.syncManualFrontier()
    XCTAssertTrue(session.manualCompleted)
    session.seek(to: 4)
    XCTAssertFalse(session.manualCompleted)
    session.play()
    XCTAssertEqual(session.manualPosition(), 4, accuracy: 1e-9)
    session.pause()
  }

  func testManualProgressesWithNoPresenterThroughItsOwnTimer() async throws {
    var now = 100.0
    let session = manualSession(speed: 300) { now }
    session.play()
    now = 101
    for _ in 0..<40 where session.tokenIndex < 5 { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(session.tokenIndex, 5, "five tokens a second, published by the session with no view")
    XCTAssertEqual(session.lastConfirmedTokenIndex, 4)
    now = 110
    for _ in 0..<40 where session.isActivelyRunning { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertFalse(session.isActivelyRunning, "the timer finishes the script")
    XCTAssertTrue(session.manualCompleted)
  }

  func testFinishingAnEditRebasesManualAtTheRemappedWord() throws {
    var now = 100.0
    let session = manualSession { now }
    session.play()
    now = 102.5
    var edited = try XCTUnwrap(session.activeRecord)
    edited.markdown += " eleven"
    edited.metadata.revision += 1
    session.applyEditedRecord(edited)
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.tokenIndex, 2)
    XCTAssertEqual(session.manualPosition(), 2, accuracy: 1e-9)
    session.play()
    now = 103.5
    XCTAssertEqual(session.manualPosition(), 3, accuracy: 1e-9)
    session.pause()
  }

  func testUserScrollPausesManualAndSeeksButVoiceKeepsRunning() {
    var now = 100.0
    let session = manualSession { now }
    session.play()
    now = 101.5
    session.seekFromUserScroll(to: 7)
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.tokenIndex, 7)
    XCTAssertEqual(session.manualPosition(), 7, accuracy: 1e-9)
    now = 150
    XCTAssertEqual(session.manualPosition(), 7, accuracy: 1e-9, "resumes only when Play is pressed")
    session.play()
    now = 151
    XCTAssertEqual(session.manualPosition(), 8, accuracy: 1e-9)
    session.pause()

    var voice = PrompterSettings(); voice.mode = "Voice"
    session.updateSettings(voice)
    session.play(captureAudio: false)
    session.seekFromUserScroll(to: 2)
    XCTAssertTrue(session.isActivelyRunning)
    XCTAssertEqual(session.tokenIndex, 2)
    session.pause()
  }

  func testVoiceAdvancesOnlyFromSpeechNotFromTheClock() {
    var now = 100.0
    let session = manualSession { now }
    var voice = PrompterSettings(); voice.mode = "Voice"; voice.speed = 300
    session.updateSettings(voice)
    session.play(captureAudio: false)
    now = 1_000
    session.syncManualFrontier()
    XCTAssertEqual(session.tokenIndex, 0)
    XCTAssertTrue(session.isActivelyRunning)
    XCTAssertFalse(session.manualCompleted)
    session.acceptSpeechCandidate(SpeechCandidate(
      replacementID: "a", generation: 1, locale: Locale(identifier: "en-GB"), text: "one two three",
      range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1)), isFinal: false))
    XCTAssertEqual(session.lastConfirmedTokenIndex, 2)
    XCTAssertEqual(session.tokenIndex, 3)
    session.pause()
  }

  func testVoiceTrackingCanRejectBackwardMatchesWithoutPoisoningForwardTracking() async {
    let session = SessionStore()
    var settings = PrompterSettings()
    settings.mode = "Voice"
    settings.allowsBackwardVoiceTracking = false
    let script = ScriptRecord(
      metadata: ScriptMetadata(title: "Test", fileName: "test.md"),
      markdown: "one two three four five six seven eight nine ten")
    session.present(record: script, settings: settings)
    session.seek(to: 7)
    session.play(captureAudio: false)
    func candidate(_ id: String, _ text: String) -> SpeechCandidate {
      SpeechCandidate(replacementID: id, generation: 1, locale: Locale(identifier: "en-GB"), text: text,
        range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1)), isFinal: true)
    }
    session.acceptSpeechCandidate(candidate("backward", "one two three four"))
    try? await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(session.tokenIndex, 7)
    session.acceptSpeechCandidate(candidate("forward", "eight nine ten"))
    try? await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(session.tokenIndex, 9)
  }

  func testOverlappingEnglishAndFrenchFinalsChooseTheStrongerCandidate() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    let script = ScriptRecord(
      metadata: ScriptMetadata(title: "Test", fileName: "test.md"),
      markdown: "the quick brown fox jumps over the lazy dog")
    session.present(record: script, settings: settings)
    session.play(captureAudio: false)
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1))
    session.acceptSpeechCandidate(SpeechCandidate(
      replacementID: "en", generation: 1, locale: Locale(identifier: "en-GB"),
      text: "the quick", range: range, isFinal: true))
    session.acceptSpeechCandidate(SpeechCandidate(
      replacementID: "fr", generation: 1, locale: Locale(identifier: "fr-FR"),
      text: "the quick brown fox", range: range, isFinal: true))
    XCTAssertEqual(session.lastConfirmedTokenIndex, 3)
    XCTAssertEqual(session.tokenIndex, 4)
  }

  /// A weaker overlapping sibling that would replay behind the accepted frontier must neither move
  /// the reader back nor leave the tracker or state poisoned, with backward tracking on or off.
  private func assertWeakerSiblingKeepsAcceptedFrontier(allowsBackward: Bool) {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    settings.allowsBackwardVoiceTracking = allowsBackward
    let script = ScriptRecord(
      metadata: ScriptMetadata(title: "Test", fileName: "test.md"),
      markdown: "one two three four five six seven eight nine ten")
    session.present(record: script, settings: settings)
    session.seek(to: 7)
    session.play(captureAudio: false)
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1))
    session.acceptSpeechCandidate(SpeechCandidate(
      replacementID: "en", generation: 1, locale: Locale(identifier: "en-GB"),
      text: "eight nine", range: range, isFinal: true))
    XCTAssertEqual(session.lastConfirmedTokenIndex, 8)
    session.acceptSpeechCandidate(SpeechCandidate(
      replacementID: "fr", generation: 1, locale: Locale(identifier: "fr-FR"),
      text: "one two three four", range: range, isFinal: true))
    XCTAssertEqual(session.lastConfirmedTokenIndex, 8)
    XCTAssertEqual(session.tokenIndex, 9)
    XCTAssertEqual(session.state, .running)
    // The tracker still sits at the accepted frontier, so the next words continue from it.
    session.acceptSpeechCandidate(SpeechCandidate(
      replacementID: "next", generation: 1, locale: Locale(identifier: "en-GB"),
      text: "ten", range: CMTimeRange(
        start: CMTime(seconds: 2, preferredTimescale: 1), duration: CMTime(seconds: 1, preferredTimescale: 1)),
      isFinal: true))
    XCTAssertEqual(session.lastConfirmedTokenIndex, 9)
    session.pause()
  }

  func testWeakerOverlappingSiblingCannotRegressAcceptedFrontier() {
    assertWeakerSiblingKeepsAcceptedFrontier(allowsBackward: true)
  }

  func testBackwardDisabledOverlappingSiblingRestoresTracker() {
    assertWeakerSiblingKeepsAcceptedFrontier(allowsBackward: false)
  }

  func testContinuousInterimCandidatesFlushBeforeStreamStops() async {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: record(), settings: settings)
    session.play(captureAudio: false)
    let initialRevision = session.seekRevision
    for index in 0..<5 {
      session.acceptSpeechCandidate(
        SpeechCandidate(
          replacementID: "revision-\(index)", generation: 1, locale: Locale(identifier: "en-GB"),
          text: "One two three", range: CMTimeRange(
            start: CMTime(seconds: Double(index), preferredTimescale: 1000),
            duration: CMTime(seconds: 1, preferredTimescale: 1000)), isFinal: false))
      try? await Task.sleep(for: .milliseconds(10))
      if index == 3 { XCTAssertGreaterThan(session.tokenIndex, 0) }
    }
    XCTAssertGreaterThan(session.tokenIndex, 0)
    XCTAssertEqual(session.seekRevision, initialRevision)
    session.pause()
  }

  func testExplicitSeekIncrementsRevisionButAutomaticAdvanceDoesNot() {
    var now = 100.0
    let session = manualSession { now }
    let initialRevision = session.seekRevision
    session.seek(to: 1)
    XCTAssertEqual(session.seekRevision, initialRevision + 1)
    session.play()
    now = 103
    session.syncManualFrontier()
    XCTAssertEqual(session.tokenIndex, 4)
    XCTAssertEqual(session.seekRevision, initialRevision + 1)
    session.pause()
  }

  func testSpeechArrivingAfterPauseIsIgnored() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: record(), settings: settings)
    session.play(captureAudio: false)
    session.pause()
    session.acceptSpeechCandidate(
      SpeechCandidate(
        replacementID: "late", generation: 1, locale: Locale(identifier: "en-GB"),
        text: "One two three", range: CMTimeRange(
          start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1000)), isFinal: false))
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.tokenIndex, 0)
  }

  /// Speech is credited the moment it arrives, so there is no queue for a seek to drop. What a seek
  /// must still guarantee: the reader's move wins, a revision from before it cannot move him again,
  /// and fresh speech continues from where he moved to.
  func testSeekOverridesEarlierSpeechAndKeepsVoiceSessionRunning() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    let script = ScriptRecord(
      metadata: ScriptMetadata(title: "Test", fileName: "test.md"),
      markdown: "one two three four five")
    session.present(record: script, settings: settings)
    session.play(captureAudio: false)
    func candidate(_ id: String, _ text: String) -> SpeechCandidate {
      SpeechCandidate(replacementID: id, generation: 1, locale: Locale(identifier: "en-GB"), text: text,
        range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1)), isFinal: false)
    }
    session.acceptSpeechCandidate(candidate("before", "one two three"))
    XCTAssertEqual(session.lastConfirmedTokenIndex, 2, "Credited on arrival, with no coalescing wait.")
    session.seek(to: 1)
    XCTAssertEqual(session.tokenIndex, 1)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 0)
    XCTAssertEqual(session.state, .running)
    session.acceptSpeechCandidate(candidate("before", "one two three"))
    XCTAssertEqual(session.tokenIndex, 1)
    session.acceptSpeechCandidate(candidate("after", "two three four"))
    XCTAssertEqual(session.lastConfirmedTokenIndex, 3)
    XCTAssertEqual(session.tokenIndex, 4)
  }

  func testLanguageChangePreservesReadingAnchor() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Manual"
    session.present(record: record(), settings: settings)
    session.seek(to: 1)
    let before = session.anchor
    var changed = settings; changed.speechLanguage = "French"
    session.updateSettings(changed)
    XCTAssertEqual(session.anchor, before)
    XCTAssertEqual(session.tokenIndex, 1)
  }

  func testPeakDecibelsUseFullScale() {
    XCTAssertEqual(AudioCapture.decibels(fullScalePeak: 1), 0, accuracy: 0.001)
    XCTAssertEqual(AudioCapture.decibels(fullScalePeak: 0.5), -6.0206, accuracy: 0.001)
    XCTAssertEqual(AudioCapture.decibels(fullScalePeak: 0), -.infinity)
  }

  func testMeterMeasurementHandlesInterleavedStereo() throws {
    let format = try XCTUnwrap(AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
    buffer.frameLength = 2
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    samples[0] = 0.5; samples[1] = -0.25; samples[2] = 0.25; samples[3] = -0.5
    let levels = AudioCapture.applyGainAndMeasure(buffer, gain: 1)
    XCTAssertEqual(levels.peak, 0.5, accuracy: 0.001)
    XCTAssertEqual(levels.rms, 0.3953, accuracy: 0.001)
  }

  func testMicrophoneTestWithoutDeviceDoesNotChangeSession() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: record(), settings: settings)
    let anchor = session.anchor
    session.startMicrophoneTest(deviceUID: nil, gain: 1)
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertEqual(session.tokenIndex, 0)
    XCTAssertEqual(session.acceptedWords, 0)
    XCTAssertEqual(session.microphoneTestNotice, "Choose an available microphone to test.")
  }
}
