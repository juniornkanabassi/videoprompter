import AVFoundation
import XCTest

@testable import JuniorPrompter
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

  func testMissingAudioInputPausesAndPreservesAnchor() {
    let session = SessionStore()
    session.present(record: record(), settings: PrompterSettings())
    let anchor = session.anchor
    session.play()

    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertEqual(session.anchorNotice, "Choose an audio input in the inspector")
    session.play(captureAudio: false)
    XCTAssertEqual(session.state, .running)
    XCTAssertNil(session.anchorNotice)
    session.pause()
  }

  func testTogglePausesAndResumesTimedSession() {
    let session = SessionStore()
    var settings = PrompterSettings()
    settings.mode = "Timed"
    session.present(record: record(), settings: settings)
    session.play()
    XCTAssertEqual(session.state, .running)
    session.toggle()
    XCTAssertEqual(session.state, .paused)
    session.toggle()
    XCTAssertEqual(session.state, .running)
  }

  func testSwitchingToTimedKeepsAnActiveSessionRunning() async {
    let session = SessionStore()
    session.present(record: record(), settings: PrompterSettings())
    session.play(captureAudio: false)
    var settings = PrompterSettings(); settings.mode = "Timed"; settings.speed = 600
    session.updateSettings(settings)
    XCTAssertEqual(session.state, .running)
    try? await Task.sleep(for: .milliseconds(500))
    XCTAssertGreaterThan(session.tokenIndex, 0)
    session.pause()
  }

  func testOldSettingsDecodeWithMixedLanguageDefault() throws {
    let value = try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"mode":"Voice","speed":120}"#.utf8))
    XCTAssertEqual(value.speechLanguage, "Mixed")
    XCTAssertEqual(value.soundThreshold, 0.055)
    XCTAssertTrue(value.allowsBackwardVoiceTracking)
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

  func testSoundModeUsesThresholdAndConfiguredSpeed() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Sound"; settings.speed = 600; settings.soundThreshold = 0.2
    session.present(record: record(), settings: settings)
    session.play(captureAudio: false)
    session.acceptSoundLevel(0.1, at: 1)
    XCTAssertEqual(session.tokenIndex, 0)
    session.acceptSoundLevel(0.3, at: 1)
    XCTAssertEqual(session.tokenIndex, 1)
    session.acceptSoundLevel(0.3, at: 1.05)
    XCTAssertEqual(session.tokenIndex, 1)
    session.acceptSoundLevel(0.3, at: 1.11)
    XCTAssertEqual(session.tokenIndex, 2)
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
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Timed"
    session.present(record: record(), settings: settings)
    let initialRevision = session.seekRevision
    session.seek(to: 1)
    XCTAssertEqual(session.seekRevision, initialRevision + 1)
    session.advanceOneToken()
    XCTAssertEqual(session.seekRevision, initialRevision + 1)
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
    var settings = PrompterSettings(); settings.mode = "Timed"
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
    var settings = PrompterSettings(); settings.mode = "Timed"
    session.present(record: record(), settings: settings)
    let anchor = session.anchor
    session.startMicrophoneTest(deviceUID: nil, gain: 1)
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertEqual(session.tokenIndex, 0)
    XCTAssertEqual(session.acceptedWords, 0)
    XCTAssertEqual(session.microphoneTestNotice, "Choose an available microphone to test.")
  }

  func testLiveSoundCapturePausesWhenSelectedDeviceDisappears() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["JUNIORPROMPTER_RUN_LIVE_MIC_DEVICE_LOSS"] == "1")
    try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                      "Live microphone regression requires existing audio permission.")
    let requestedUID = ProcessInfo.processInfo.environment["JUNIORPROMPTER_LIVE_MIC_DEVICE_UID"]
    guard let device = AudioCapture.inputDevices().first(where: { requestedUID == nil || $0.uid == requestedUID }) else {
      throw XCTSkip("Live microphone regression requires an available input device.")
    }

    let session = SessionStore()
    var settings = PrompterSettings()
    settings.mode = "Sound"
    settings.audioDeviceUID = device.uid
    settings.soundThreshold = 0
    settings.speed = 600
    session.present(record: record(), settings: settings)
    session.play()
    defer { session.pause() }

    let deadline = ContinuousClock.now + .seconds(5)
    while session.tokenIndex == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard session.tokenIndex > 0 else {
      XCTFail("Live capture did not deliver a buffer.")
      return
    }

    let anchor = try XCTUnwrap(session.anchor)
    session.microphoneDevicesDidChange([])
    let pauseDeadline = ContinuousClock.now + .seconds(2)
    while session.anchorNotice == nil && ContinuousClock.now < pauseDeadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertEqual(session.settings.audioDeviceUID, device.uid)
    XCTAssertEqual(session.anchorNotice, "The selected microphone was disconnected. Tracking paused.")
    let pausedIndex = session.tokenIndex
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(session.tokenIndex, pausedIndex)
  }
}
