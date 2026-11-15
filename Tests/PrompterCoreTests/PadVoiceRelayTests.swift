@preconcurrency import AVFoundation
import Synchronization
import XCTest

@testable import PrompterCore
@testable import VideoPrompter

/// The Mac voice relay, driven by recorded-style candidates (never the microphone) and a fake link
/// that keeps what it is asked to send.
@MainActor
final class PadVoiceRelayTests: XCTestCase {
  private final class FakeLink: PadRelayLink {
    var sent: [PadRemote.Command] = []
    var active: [Bool] = []
    var onSend: ((PadRemote.Command) -> Void)?
    func send(_ command: PadRemote.Command) { sent.append(command); onSend?(command) }
    func setRelayActive(_ value: Bool) { active.append(value) }
    var follows: [PadRemote.Follow] { sent.compactMap { if case .follow(let follow) = $0 { follow } else { nil } } }
  }

  private let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
    "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"]
  private var markdown: String { words.joined(separator: " ") }
  private let macID = UUID()
  private let padID = UUID()
  private var record: ScriptRecord { record(markdown) }
  private func record(_ text: String) -> ScriptRecord {
    ScriptRecord(metadata: ScriptMetadata(id: macID, title: "Relay", fileName: "relay.md"), markdown: text)
  }
  private var fingerprint: String { MarkdownLibrary.fingerprint(markdown) }

  /// What the iPad reports. `text` is what its copy of the script says; `open` is whether it is presenting it.
  private func state(
    scripts: Bool = true, running: Bool = false, word: Int = 1, revision: Int = 4, voice: String = "Mac",
    text: String? = nil, open: Bool = true
  ) -> PadRemote.State {
    let fingerprint = MarkdownLibrary.fingerprint(text ?? markdown)
    return PadRemote.State(
      scripts: scripts ? [PadRemote.Script(id: padID, title: "Relay", macID: macID, fingerprint: fingerprint)] : [],
      presenting: scripts && open ? padID : nil, running: running, mode: "Voice", speed: 3, word: word, words: words.count,
      version: 3, voiceSource: voice, seekRevision: scripts && open ? revision : nil,
      fingerprint: scripts && open ? fingerprint : nil)
  }

  private func makeRelay(_ link: FakeLink, initial: PadRemote.State?, defaults: UserDefaults? = nil) -> PadVoiceRelay {
    let suite = "VideoPrompterTests.padRelay.\(UUID().uuidString)"
    removeDefaultsAtTeardown(suite)
    let relay = PadVoiceRelay(link: link, suiteName: suite, defaults: defaults ?? freshDefaults())
    relay.captureAudio = false
    relay.presenterIsCapturing = { false }
    relay.confirmationTimeout = .seconds(2)
    relay.iPadStateChanged(initial)
    return relay
  }

  private func until(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), what)
  }

  private var generation: UInt64 = 0
  private func hear(_ relay: PadVoiceRelay, _ text: String) {
    generation += 1
    relay.session?.acceptSpeechCandidate(SpeechCandidate(
      replacementID: "r\(generation)", generation: generation, locale: Locale(identifier: "en-GB"), text: text,
      range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1)), isFinal: false))
  }

  private func started(running: Bool = true, word: Int = 1) async throws -> (PadVoiceRelay, FakeLink) {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(running: running, word: word))
    relay.start(script: record, settings: PrompterSettings())
    try await until("live") { relay.session != nil && relay.status != "Getting the script onto the iPad…" }
    return (relay, link)
  }

  func testIPadInitiatedRelayUsesPresentedTextAndStopsOnLocalMic() async throws {
    let link = FakeLink()
    var current = state(running: false)
    current.markdown = markdown
    current.scripts = [.init(id: padID, title: "Made on iPad")]
    let relay = makeRelay(link, initial: current)
    relay.startFromIPad(settings: PrompterSettings())
    try await until("iPad initiated relay") { relay.session != nil }
    XCTAssertEqual(relay.session?.activeRecord?.markdown, markdown)
    XCTAssertFalse(link.sent.contains { if case .sendScript = $0 { return true }; return false })
    current.voiceSource = "iPad"
    relay.iPadStateChanged(current)
    XCTAssertFalse(relay.isRelaying)
    XCTAssertNil(relay.session)
  }

  func testRelayParsesTheScriptInTheIPadsLanguageAndFollowsAChange() async throws {
    let text = "uno 35 dos tres cuatro"
    let spanish = PrompterDocument(markdown: text, language: .spanish).spokenTokens.count
    let english = PrompterDocument(markdown: text, language: .english).spokenTokens.count
    XCTAssertNotEqual(spanish, english, "numbers expand differently, so word numbers differ")
    var current = state(text: text)
    current.markdown = text
    current.scripts = [.init(id: padID, title: "Hecho en iPad")]
    current.language = "Spanish"
    let relay = makeRelay(FakeLink(), initial: current)
    var mac = PrompterSettings()
    mac.speechLanguage = "English"
    relay.startFromIPad(settings: mac)
    try await until("relay session") { relay.session != nil }
    XCTAssertEqual(relay.session?.document.spokenTokens.count, spanish, "the iPad's language wins over the Mac's")
    current.language = "English"
    current.seekRevision = 5
    relay.iPadStateChanged(current)
    XCTAssertEqual(relay.session?.document.spokenTokens.count, english)
    XCTAssertTrue(relay.isRelaying)
    relay.stop()
    XCTAssertEqual(IPadReplicaView.document(text, language: "Spanish").spokenTokens.count, spanish, "the replica counts words as the iPad does")
    XCTAssertEqual(IPadReplicaView.document(text, language: nil).spokenTokens.count, english, "an older iPad keeps today's parse")
  }

  func testIPadInitiatedRelayRejectsMismatchedText() {
    var current = state()
    current.markdown = "different text"
    let relay = makeRelay(FakeLink(), initial: current)
    relay.startFromIPad(settings: PrompterSettings())
    XCTAssertFalse(relay.isRelaying)
  }

  func testPickerProtocolCompatibility() throws {
    let source = try JSONDecoder().decode(PadRemote.Source.self, from: Data(#"{"id":"old","name":"Old camera"}"#.utf8))
    XCTAssertNil(source.connection)
    let status = try JSONDecoder().decode(PadRemote.MacStatus.self, from: Data(#"{"cameraOn":true}"#.utf8))
    XCTAssertNil(status.supportsMicSelection)
    for command in [PadRemote.Command.macMicrophone(""), .macMicrophone(nil), .microphoneChannel("Left")] {
      XCTAssertEqual(try JSONDecoder().decode(PadRemote.Command.self, from: JSONEncoder().encode(command)), command)
    }
  }

  func testMissingScriptIsSentFirstThenTheRelaySeeksToTheIPadsWord() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(scripts: false))
    let ready = state(running: true, word: 5)
    link.onSend = { [weak relay] command in
      if case .sendScript = command { Task { @MainActor in relay?.iPadStateChanged(ready) } }
    }
    relay.start(script: record, settings: PrompterSettings())
    XCTAssertTrue(relay.isRelaying)
    try await until("session") { relay.session != nil }
    guard case .sendScript(let transfer) = link.sent.first else { return XCTFail("the script goes first: \(link.sent)") }
    XCTAssertEqual(transfer.macID, macID)
    XCTAssertEqual(transfer.markdown, markdown)
    XCTAssertTrue(transfer.present)
    XCTAssertEqual(link.sent.dropFirst().first, .voiceSource("Mac"))
    XCTAssertEqual(relay.session?.tokenIndex, 4, "the iPad's word 5 is token 4")
    XCTAssertEqual(link.active, [true])
    XCTAssertNotNil(relay.meter)
    XCTAssertTrue(relay.session?.isActivelyRunning == true)
  }

  func testAnIPadThatAlreadyHasTheScriptIsNotSentIt() async throws {
    let (relay, link) = try await started()
    XCTAssertFalse(link.sent.contains { if case .sendScript = $0 { true } else { false } })
    XCTAssertEqual(link.sent, [.voiceSource("Mac")])
    relay.stop()
  }

  func testFollowsAreSentInsideTheRecognitionTurn() async throws {
    let (relay, link) = try await started()
    defer { relay.stop() }
    let start = ProcessInfo.processInfo.systemUptime
    hear(relay, "alpha bravo")
    XCTAssertEqual(link.follows.count, 1, "A free transport receives the word synchronously")
    hear(relay, "charlie delta echo")
    XCTAssertEqual(link.follows.count, 2)
    let confirmed = try XCTUnwrap(relay.session?.lastConfirmedTokenIndex)
    XCTAssertGreaterThanOrEqual(confirmed, 4)
    XCTAssertEqual(link.follows.last, PadRemote.Follow(confirmed: confirmed, fingerprint: fingerprint, seekRevision: 4))
    print("RELAY two recognition calls to transport: \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms")
    hear(relay, "foxtrot")
    XCTAssertEqual(link.follows.count, 3)
    XCTAssertEqual(link.follows.last?.confirmed, relay.session?.lastConfirmedTokenIndex)
  }

  func testAnIPadSeekMovesTheRelayOnceAndWordChangesAloneDoNot() async throws {
    let (relay, link) = try await started()
    let session = try XCTUnwrap(relay.session)
    let before = session.seekRevision
    // The iPad's word moving as it follows us is not a seek.
    for word in [2, 3, 4] { relay.iPadStateChanged(state(running: true, word: word)) }
    XCTAssertEqual(session.seekRevision, before)
    // The pre-seek word is already sent with the old revision; the iPad rejects it if it arrives late.
    hear(relay, "alpha bravo")
    relay.iPadStateChanged(state(running: true, word: 15, revision: 5))
    XCTAssertEqual(session.seekRevision, before + 1)
    XCTAssertEqual(session.tokenIndex, 14)
    relay.iPadStateChanged(state(running: true, word: 16, revision: 5))
    relay.iPadStateChanged(state(running: true, word: 17, revision: 5))
    XCTAssertEqual(session.seekRevision, before + 1, "exactly one re-seek")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(link.follows.map(\.seekRevision), [4], "A pre-seek follow must retain its old revision")
    // The next word goes out with the new revision, and the relay's own seek was not echoed.
    hear(relay, "papa quebec")
    try await until("follow") { !link.follows.isEmpty }
    XCTAssertEqual(link.follows.map(\.seekRevision), [4, 5])
    XCTAssertEqual(session.seekRevision, before + 1, "and still only the one seek")
    relay.stop()
  }

  func testTheIPadsRunningAndPausedAreMirrored() async throws {
    let (relay, link) = try await started(running: false)
    let session = try XCTUnwrap(relay.session)
    XCTAssertFalse(session.isActivelyRunning, "waits for the iPad to play")
    relay.iPadStateChanged(state(running: true))
    XCTAssertTrue(session.isActivelyRunning)
    relay.iPadStateChanged(state(running: false))
    XCTAssertFalse(session.isActivelyRunning)
    XCTAssertTrue(relay.isRelaying)
    XCTAssertFalse(link.sent.contains(.pause), "mirroring a pause does not send one back")
    relay.stop()
  }

  func testMicOffPausesWithoutEndingAndMicOnResumesTheSameSession() async throws {
    let (relay, link) = try await started()
    defer { relay.stop() }
    let session = try XCTUnwrap(relay.session)
    relay.pauseForMic()
    relay.pauseForMic() // Repeated off commands must keep the original resume intent.
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(relay.isRelaying)
    XCTAssertTrue(relay.session === session)
    XCTAssertFalse(session.isActivelyRunning)
    XCTAssertFalse(link.sent.contains(.pause), "a deliberate mic pause is not a failed relay")
    relay.resumeForMic()
    XCTAssertTrue(session.isActivelyRunning)
    XCTAssertEqual(link.sent.last, .play)
    relay.resumeForMic()
    XCTAssertEqual(link.sent.filter { $0 == .play }.count, 1)
  }

  func testMicTogglePreservesAnAlreadyPausedRelay() async throws {
    let (relay, link) = try await started(running: false)
    defer { relay.stop() }
    relay.pauseForMic()
    await Task.yield()
    relay.resumeForMic()
    XCTAssertTrue(relay.isRelaying)
    XCTAssertEqual(relay.session?.isActivelyRunning, false)
    XCTAssertFalse(link.sent.contains(.play))
  }

  func testIPadMicStatePausesAndResumesWithoutDiscardingRelay() async throws {
    let (relay, link) = try await started()
    defer { relay.stop() }
    var off = state(running: false)
    off.micOn = false
    relay.iPadStateChanged(off)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(relay.isRelaying)
    XCTAssertEqual(relay.session?.isActivelyRunning, false)
    off.micOn = true
    relay.iPadStateChanged(off)
    XCTAssertEqual(relay.session?.isActivelyRunning, true)
    XCTAssertEqual(link.sent.last, .play)
    relay.iPadStateChanged(state(running: true))
    XCTAssertEqual(relay.session?.isActivelyRunning, true)
  }

  func testEditingDuringMicPauseDoesNotResumeReading() async throws {
    let (relay, link) = try await started()
    defer { relay.stop() }
    relay.pauseForMic()
    var editing = state(running: false)
    editing.editing = true
    relay.iPadStateChanged(editing)
    relay.resumeForMic()
    XCTAssertEqual(relay.session?.isActivelyRunning, false)
    XCTAssertFalse(link.sent.contains(.play))
  }

  func testAMicrophoneFailurePausesTheIPadAndSaysWhy() async throws {
    let (relay, link) = try await started(running: false)
    // The recogniser has no microphone: the session pauses itself with a notice, as a real failure does.
    relay.session?.resolveAudioInput = { _ in nil }
    relay.captureAudio = true
    relay.iPadStateChanged(state(running: true))
    try await until("ended") { !relay.isRelaying }
    XCTAssertEqual(link.sent.last, .pause)
    XCTAssertTrue(relay.status.contains("microphone"), relay.status)
    XCTAssertEqual(link.active, [true, false])
    XCTAssertNil(relay.meter)
  }

  func testStopBeforeVoiceAcknowledgementReturnsTheQueuedSwitchToIPad() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(voice: "iPad"))
    relay.start(script: record, settings: PrompterSettings())
    try await until("requested Mac voice") { link.sent.contains(.voiceSource("Mac")) }
    relay.stop()
    XCTAssertEqual(link.sent.suffix(2), [.voiceSource("Mac"), .voiceSource("iPad")])
    XCTAssertFalse(relay.isRelaying)
  }

  func testIdleStopAndRefusedStartReturnAnUnservedMacVoiceToIPad() {
    for refuse in [false, true] {
      let link = FakeLink()
      let relay = makeRelay(link, initial: state(open: false))
      if refuse { relay.startFromIPad(settings: PrompterSettings()) }
      else { relay.stop() }
      XCTAssertEqual(link.sent, [.voiceSource("iPad")])
      XCTAssertFalse(relay.isRelaying)
    }
  }

  func testAStopPausesTheIPadAndRestoresItsMicrophone() async throws {
    let (relay, link) = try await started()
    relay.stop()
    XCTAssertEqual(link.sent.last, .pause)
    XCTAssertTrue(link.sent.contains(.voiceSource("iPad")))
    XCTAssertFalse(relay.isRelaying)
    XCTAssertNil(relay.session)
    XCTAssertEqual(link.active, [true, false])
  }

  func testALinkDropEndsTheRelayWithoutWritingToADeadLink() async throws {
    let (relay, link) = try await started()
    let sentBefore = link.sent.count
    relay.iPadStateChanged(nil)
    XCTAssertFalse(relay.isRelaying)
    XCTAssertEqual(link.sent.count, sentBefore)
    XCTAssertTrue(relay.status.contains("dropped"), relay.status)
    XCTAssertNil(relay.session)
    XCTAssertNil(relay.meter)
    XCTAssertEqual(link.active, [true, false])
  }

  func testAnotherScriptOnTheIPadEndsTheRelay() async throws {
    let (relay, link) = try await started()
    var other = state(running: true)
    other.fingerprint = "0000000000000000"
    relay.iPadStateChanged(other)
    XCTAssertFalse(relay.isRelaying)
    XCTAssertEqual(link.sent.last, .pause)
  }

  func testAnEditSavedOnTheIPadHandsTheVoiceBackInsteadOfWaitingForWords() async throws {
    let (relay, link) = try await started(running: true)
    var editing = state(running: false)
    editing.editing = true
    relay.iPadStateChanged(editing)
    XCTAssertTrue(relay.isRelaying, "an edit in progress only pauses the relay")
    // Saved: the iPad's text, and so its fingerprint, is no longer the one the relay follows.
    var saved = state(running: false, text: markdown + " uniform")
    saved.editing = true
    relay.iPadStateChanged(saved)
    XCTAssertFalse(relay.isRelaying)
    XCTAssertTrue(relay.status.contains("edited on the iPad"), relay.status)
    XCTAssertEqual(link.sent.suffix(2), [.voiceSource("iPad"), .pause], "the iPad listens for itself, not for the Mac")
    // Resume after the save: the relay is gone, so nothing is waiting on or sending words.
    let sentBefore = link.sent.count
    relay.iPadStateChanged(state(running: true, voice: "iPad", text: markdown + " uniform"))
    XCTAssertEqual(link.sent.count, sentBefore)
    XCTAssertNil(relay.session)
    XCTAssertEqual(link.active, [true, false])
  }

  func testRefusesWhileTheMacsOwnPresenterListens() {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state())
    relay.presenterIsCapturing = { true }
    relay.start(script: record, settings: PrompterSettings())
    XCTAssertFalse(relay.isRelaying)
    XCTAssertTrue(relay.status.contains("presenter"), relay.status)
    XCTAssertEqual(link.sent, [.voiceSource("iPad")])
  }

  func testNoIPadMeansNoRelay() {
    let link = FakeLink()
    let relay = makeRelay(link, initial: nil)
    relay.start(script: record, settings: PrompterSettings())
    XCTAssertFalse(relay.isRelaying)
    XCTAssertEqual(relay.status, "No iPad is connected")
  }

  func testTheRelayCopiesRecognitionSettingsAndNeverTouchesTheMacsSavedPositions() async throws {
    let before = UserDefaults.standard.data(forKey: "readingPositions")
    var mac = PrompterSettings()
    mac.speechLanguage = "French"
    mac.allowsBackwardVoiceTracking = !mac.allowsBackwardVoiceTracking
    mac.audioDeviceUID = "some-microphone"
    mac.inputGain = 1.5
    mac.mode = "Manual"
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(running: true))
    relay.start(script: record, settings: mac)
    try await until("live") { relay.session != nil }
    let settings = try XCTUnwrap(relay.session?.settings)
    XCTAssertEqual(settings.mode, "Voice")
    XCTAssertEqual(settings.speechLanguage, mac.speechLanguage)
    XCTAssertEqual(settings.allowsBackwardVoiceTracking, mac.allowsBackwardVoiceTracking)
    XCTAssertEqual(settings.audioDeviceUID, mac.audioDeviceUID)
    XCTAssertEqual(settings.inputGain, mac.inputGain)
    hear(relay, "alpha bravo charlie")
    relay.stop()
    XCTAssertEqual(UserDefaults.standard.data(forKey: "readingPositions"), before)
  }

  // MARK: - Starting and stopping

  func testAStopBeforeTheStartRunsSendsNothing() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(voice: "iPad"))
    relay.start(script: record, settings: PrompterSettings())
    relay.stop()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(link.sent.isEmpty, "\(link.sent)")
    XCTAssertNil(relay.session)
    XCTAssertFalse(relay.isRelaying)
    XCTAssertFalse(link.active.contains(true))
    // And a new start afterwards works: the old run cannot leak into it.
    relay.iPadStateChanged(state(voice: "Mac"))
    relay.start(script: record, settings: PrompterSettings())
    try await until("live") { relay.session != nil }
    XCTAssertEqual(link.sent, [.voiceSource("Mac")])
    relay.stop()
  }

  func testAnIPadThatNeverOpensTheScriptEndsTheStartWithoutPausingIt() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(scripts: false))
    relay.confirmationTimeout = .milliseconds(150)
    relay.start(script: record, settings: PrompterSettings())
    try await until("gave up") { !relay.isRelaying }
    XCTAssertTrue(relay.status.contains("did not open"), relay.status)
    XCTAssertFalse(link.sent.contains(.pause), "it was never moving")
    XCTAssertNil(relay.session)
  }

  func testALinkDropWhileStartingEndsTheStart() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(scripts: false))
    relay.start(script: record, settings: PrompterSettings())
    relay.iPadStateChanged(nil)
    XCTAssertFalse(relay.isRelaying, "not left waiting")
    XCTAssertTrue(relay.status.contains("dropped"), relay.status)
    XCTAssertFalse(link.sent.contains(.pause))
  }

  func testAScriptClosedDuringTheVoiceSwitchIsNotRelayed() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(voice: "iPad"))
    // The iPad switches to the Mac's voice but has closed the script meanwhile.
    link.onSend = { [self, weak relay] command in
      if command == .voiceSource("Mac") { Task { @MainActor in relay?.iPadStateChanged(state(voice: "Mac", open: false)) } }
    }
    relay.start(script: record, settings: PrompterSettings())
    try await until("ended") { !relay.isRelaying }
    XCTAssertNil(relay.session)
    XCTAssertFalse(link.active.contains(true))
    XCTAssertTrue(relay.status.contains("closed or changed"), relay.status)
    XCTAssertFalse(link.sent.contains(.pause))
  }

  func testASeekAfterTheScriptsEndRestartsTheRelayOnARunningIPad() async throws {
    let (relay, _) = try await started(running: true)
    let session = try XCTUnwrap(relay.session)
    session.voiceEndGrace = .milliseconds(20)
    hear(relay, markdown)
    try await until("self-paused at the end") { !session.isActivelyRunning && relay.status == "Reached the end of the script" }
    XCTAssertTrue(relay.isRelaying)
    XCTAssertEqual(relay.status, "Reached the end of the script")
    relay.iPadStateChanged(state(running: true, word: 3, revision: 5))
    XCTAssertTrue(session.isActivelyRunning, "the iPad is still running and has gone back to word 3")
    XCTAssertEqual(session.tokenIndex, 2)
    relay.stop()
  }

  func testAWindowClosedStopsTheRelayAndPausesTheIPad() async throws {
    let link = FakeLink()
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    let relay = makeRelay(link, initial: state(running: true))
    sender.relay = relay
    relay.start(script: record, settings: PrompterSettings())
    try await until("live") { relay.session != nil }
    sender.controlsIPad = true
    XCTAssertTrue(relay.isRelaying, "opening the window does not stop it")
    sender.controlsIPad = false
    XCTAssertFalse(relay.isRelaying)
    XCTAssertEqual(link.sent.last, .pause)
  }

  func testTheTextLastSentIsTheBasisOfTheNextSend() async throws {
    let macDefaults = freshDefaults()
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(scripts: false), defaults: macDefaults)
    let ready = state(running: true)
    link.onSend = { [weak relay] command in
      if case .sendScript = command { Task { @MainActor in relay?.iPadStateChanged(ready) } }
    }
    relay.start(script: record, settings: PrompterSettings())
    try await until("live") { relay.session != nil }
    guard case .sendScript(let first) = link.sent.first else { return XCTFail("\(link.sent)") }
    XCTAssertNil(first.basis, "nothing was sent before")
    relay.stop()
    // The Mac edits the script; the iPad still has what was sent.
    let edited = markdown + " uniform"
    link.sent = []
    let editedReady = state(running: true, text: edited)
    link.onSend = { [weak relay] command in
      if case .sendScript = command { Task { @MainActor in relay?.iPadStateChanged(editedReady) } }
    }
    relay.iPadStateChanged(state(running: false))
    relay.start(script: record(edited), settings: PrompterSettings())
    try await until("live again") { relay.session != nil }
    guard case .sendScript(let second) = link.sent.first else { return XCTFail("\(link.sent)") }
    XCTAssertEqual(second.basis, fingerprint, "so the iPad updates its copy instead of keeping a duplicate")
    XCTAssertEqual(second.markdown, edited)
    XCTAssertNil(UserDefaults.standard.dictionary(forKey: "padRelaySentFingerprints")?[macID.uuidString], "kept in the injected defaults only")
    XCTAssertNil(macDefaults.data(forKey: "readingPositions"))
    relay.stop()
  }

  // MARK: - Revisions, restarts and the video limit

  func testAnyChangedRevisionIsASeekEvenWhenItGoesDown() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(running: true, revision: 5))
    relay.start(script: record, settings: PrompterSettings())
    try await until("live") { relay.session != nil }
    let session = try XCTUnwrap(relay.session)
    let before = session.seekRevision
    relay.iPadStateChanged(state(running: true, word: 8, revision: 2))
    XCTAssertEqual(session.seekRevision, before + 1)
    XCTAssertEqual(session.tokenIndex, 7)
    hear(relay, "hotel india")
    try await until("follow") { !link.follows.isEmpty }
    XCTAssertEqual(link.follows.map(\.seekRevision), [2], "stamped with the iPad's current revision, which went down")
    relay.stop()
  }

  func testAStopAndStartDuringTheReadinessWaitLeavesTheOldRunInert() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(scripts: false))
    relay.start(script: record, settings: PrompterSettings())
    try await Task.sleep(for: .milliseconds(60))
    relay.stop()
    relay.start(script: record, settings: PrompterSettings())
    try await Task.sleep(for: .milliseconds(60))
    relay.iPadStateChanged(state(voice: "iPad"))
    link.onSend = { [self, weak relay] command in
      if command == .voiceSource("Mac") { Task { @MainActor in relay?.iPadStateChanged(state(voice: "Mac")) } }
    }
    try await until("live") { relay.session != nil }
    try await Task.sleep(for: .milliseconds(100))
    let sends = link.sent.filter { if case .sendScript = $0 { true } else { false } }
    XCTAssertEqual(sends.count, 2, "one per start")
    XCTAssertEqual(link.sent.filter { $0 == .voiceSource("Mac") }.count, 1, "only the new run switched the voice")
    XCTAssertEqual(link.active.filter { $0 }.count, 1)
    XCTAssertFalse(link.sent.contains(.pause))
    relay.stop()
  }

  func testAStopAndStartDuringTheVoiceConfirmationLeavesTheOldRunInert() async throws {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state(voice: "iPad"))
    relay.start(script: record, settings: PrompterSettings())
    try await until("first run waits for the voice") { link.sent == [.voiceSource("Mac")] }
    relay.stop()
    relay.start(script: record, settings: PrompterSettings())
    try await until("second run asks too") { link.sent.filter { $0 == .voiceSource("Mac") }.count == 2 }
    // The iPad confirms once; the old run's wait must not complete a second session.
    relay.iPadStateChanged(state(voice: "Mac"))
    try await until("live") { relay.session != nil }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(link.sent.filter { $0 == .voiceSource("Mac") }.count, 2, "one request per run")
    XCTAssertEqual(link.active.filter { $0 }.count, 1, "one activation")
    XCTAssertTrue(relay.isRelaying)
    XCTAssertFalse(link.sent.contains(.pause))
    relay.stop()
    XCTAssertEqual(link.sent.last, .pause)
    XCTAssertFalse(relay.isRelaying)
  }

  func testTheSenderSetsAndRestoresTheVideoLimitOnItsPipe() {
    let sender = IPadCameraSender(defaults: freshDefaults())
    let pipe = StalledPipe(name: "limit")
    sender.pipe = pipe
    XCTAssertEqual(pipe.videoLimit.load(ordering: .relaxed), 3_000_000)
    sender.setRelayActive(true)
    XCTAssertEqual(pipe.videoLimit.load(ordering: .relaxed), 256_000)
    sender.setRelayActive(false)
    XCTAssertEqual(pipe.videoLimit.load(ordering: .relaxed), 3_000_000)
    sender.pipe = nil
  }

  func testConsoleRotatesMacCameraWithoutIPadAcknowledgement() {
    let camera = CameraModel.shared
    let original = camera.guides
    defer { camera.guides = original }
    let sender = IPadCameraSender(defaults: freshDefaults())
    for rotation in CameraRotation.allCases {
      sender.setCameraRotation(rotation.rawValue)
      XCTAssertEqual(camera.guides.rotation, rotation)
    }
    sender.setCameraRotation(45)
    XCTAssertEqual(camera.guides.rotation, CameraRotation.allCases.last)
  }

  func testTheEncoderDropsAFrameOnlyAboveTheLimit() throws {
    func queuedBytesAfterAFrame(limit: Int) throws -> Int {
      let pipe = StalledPipe(name: "encoder")
      pipe.videoLimit.store(limit, ordering: .relaxed)
      // A message the stalled transport never finishes: 300 KB queued.
      pipe.send(CameraLink.Message.frame(time: 0, keyFrame: true, data: Data(count: 300_000)).encoded())
      let before = pipe.pendingBytes
      let encoder = LinkEncoder()
      encoder.attach(pipe)
      encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try CameraLinkPipelineTests.frame(1280, 720, 1), from: CameraLinkPipelineTests.connection)
      encoder.captureQueue.sync {}
      let deadline = Date().addingTimeInterval(2)
      while pipe.pendingBytes == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
      return pipe.pendingBytes - before
    }
    XCTAssertGreaterThan(try queuedBytesAfterAFrame(limit: 3_000_000), 0, "admitted under the normal limit")
    XCTAssertEqual(try queuedBytesAfterAFrame(limit: 256_000), 0, "dropped over the relay's limit")
  }

  // MARK: - The transport

  private final class StalledPipe: LinkPipe, @unchecked Sendable {
    let written = Mutex<[Data]>([])
    let waiting = Mutex<[@Sendable () -> Void]>([])
    /// Writes numbered here fail: they are never written and the transport still finishes them.
    let failing = Mutex(Set<Int>())
    private let attempts = Mutex(0)
    override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
      waiting.withLock { $0.append(done) }
      let attempt = attempts.withLock { count in defer { count += 1 }; return count }
      if !failing.withLock({ $0.contains(attempt) }) { written.withLock { $0.append(data) } }
    }
    /// The transport finishes the write it was on.
    func finishOne() { waiting.withLock { $0.isEmpty ? nil : $0.removeFirst() }?() }
    var messages: [CameraLink.Message] {
      var reader = CameraLink.Reader()
      return written.withLock { $0 }.flatMap { (try? reader.append($0)) ?? [] }
    }
  }

  private static func numbered(_ index: Int) -> Data {
    CameraLink.Message.frame(time: UInt64(index), keyFrame: false, data: Data(repeating: UInt8(index % 250), count: 1_000)).encoded()
  }
  private static func number(_ message: CameraLink.Message) -> Int? {
    if case .frame(let time, _, _) = message { return Int(time) }
    return nil
  }
  private static func follow(_ index: Int) -> Data {
    CameraLink.Message.command(.follow(.init(confirmed: index, fingerprint: "f", seekRevision: 1))).encoded()
  }

  func testControlMessagesAreWrittenBeforeQueuedVideoInExactOrder() throws {
    let pipe = StalledPipe(name: "stalled")
    for index in 0..<40 { pipe.send(Self.numbered(index)) }
    XCTAssertEqual(pipe.pendingBytes, 40 * Self.numbered(0).count)
    pipe.send(CameraLink.Message.command(.pause).encoded())
    pipe.send(CameraLink.Message.command(.play).encoded())
    for _ in 0..<42 { pipe.finishOne() }
    let messages = pipe.messages
    XCTAssertEqual(messages.count, 42)
    // Frame 0 was already on the wire; the commands follow in order, then frames 1...39 in order.
    XCTAssertEqual(Self.number(messages[0]), 0)
    XCTAssertEqual(messages[1], .command(.pause))
    XCTAssertEqual(messages[2], .command(.play))
    XCTAssertEqual(messages.dropFirst(3).compactMap(Self.number), Array(1..<40))
    XCTAssertEqual(pipe.pendingBytes, 0)
  }

  func testOnlyTheNewestWaitingFollowIsWritten() {
    let pipe = StalledPipe(name: "follows")
    pipe.send(Self.numbered(0))
    for index in 0..<20 { pipe.send(Self.follow(index)) }
    let queuedBytes = pipe.pendingBytes
    XCTAssertEqual(queuedBytes, Self.numbered(0).count + Self.follow(19).count, "replaced ones no longer count as queued")
    pipe.send(CameraLink.Message.command(.pause).encoded())
    for _ in 0..<3 { pipe.finishOne() }
    let messages = pipe.messages
    XCTAssertEqual(messages.count, 3)
    XCTAssertEqual(messages[1], .command(.follow(.init(confirmed: 19, fingerprint: "f", seekRevision: 1))))
    XCTAssertEqual(messages[2], .command(.pause))
    XCTAssertEqual(pipe.pendingBytes, 0)
  }

  func testAReplacedFollowGoesAfterTheCommandsSentBetweenThem() {
    let pipe = StalledPipe(name: "order")
    pipe.send(Self.numbered(0))
    pipe.send(CameraLink.Message.command(.play).encoded())
    pipe.send(Self.follow(1))
    pipe.send(CameraLink.Message.command(.pause).encoded())
    pipe.send(Self.follow(2))
    for _ in 0..<4 { pipe.finishOne() }
    // A paused iPad ignores a follow, so the newer one must not jump ahead of the pause.
    XCTAssertEqual(pipe.messages.dropFirst(), [
      .command(.play), .command(.pause), .command(.follow(.init(confirmed: 2, fingerprint: "f", seekRevision: 1))),
    ])
    XCTAssertEqual(pipe.pendingBytes, 0)
  }

  func testAFailedWriteDoesNotStallTheQueue() {
    let pipe = StalledPipe(name: "failing")
    pipe.failing.withLock { $0 = [1] }
    for index in 0..<5 { pipe.send(Self.numbered(index)) }
    for _ in 0..<5 { pipe.finishOne() }
    XCTAssertEqual(pipe.messages.compactMap(Self.number), [0, 2, 3, 4], "the failed one is gone, the rest follow")
    XCTAssertEqual(pipe.pendingBytes, 0)
  }

  /// The real socket pipe, blocked in a write to a peer that never reads, is closed: the rest of
  /// the backlog drains without being written and nothing stays counted as queued.
  func testClosingDuringAnOutstandingWriteDrainsTheBacklog() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    var on: Int32 = 1
    setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    defer { Darwin.close(fds[1]) }
    let pipe = SocketPipe(socket: fds[0], name: "USB-C")
    let big = CameraLink.Message.frame(time: 0, keyFrame: false, data: Data(repeating: 7, count: 2_000_000)).encoded()
    for _ in 0..<6 { pipe.send(big) }
    pipe.send(CameraLink.Message.command(.pause).encoded())
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertGreaterThan(pipe.pendingBytes, 5 * big.count, "stuck in the first write")
    pipe.close()
    let deadline = Date().addingTimeInterval(3)
    while pipe.pendingBytes > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    XCTAssertEqual(pipe.pendingBytes, 0)
  }

  func testSendersOnTwoThreadsLoseNothingAndKeepEachOnesOrder() {
    final class Immediate: LinkPipe, @unchecked Sendable {
      let written = Mutex<[Data]>([])
      override func write(_ data: Data, done: @escaping @Sendable () -> Void) { written.withLock { $0.append(data) }; done() }
    }
    let pipe = Immediate(name: "threads")
    let group = DispatchGroup()
    for thread in 0..<2 {
      DispatchQueue.global().async(group: group) {
        for index in 0..<300 { pipe.send(Self.numbered(thread * 1000 + index)) }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    var reader = CameraLink.Reader()
    let numbers = pipe.written.withLock { $0 }.flatMap { (try? reader.append($0)) ?? [] }.compactMap(Self.number)
    XCTAssertEqual(numbers.count, 600)
    XCTAssertEqual(numbers.filter { $0 < 1000 }, Array(0..<300))
    XCTAssertEqual(numbers.filter { $0 >= 1000 }, Array(1000..<1300))
    XCTAssertEqual(pipe.pendingBytes, 0)
  }
}
