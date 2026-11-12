import AVFoundation
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
  private var record: ScriptRecord {
    ScriptRecord(metadata: ScriptMetadata(id: macID, title: "Relay", fileName: "relay.md"), markdown: markdown)
  }
  private var fingerprint: String { MarkdownLibrary.fingerprint(markdown) }

  private func state(
    scripts: Bool = true, running: Bool = false, word: Int = 1, revision: Int = 4, voice: String = "Mac"
  ) -> PadRemote.State {
    PadRemote.State(
      scripts: scripts ? [PadRemote.Script(id: padID, title: "Relay", macID: macID, fingerprint: fingerprint)] : [],
      presenting: scripts ? padID : nil, running: running, mode: "Voice", speed: 3, word: word, words: words.count,
      version: 3, voiceSource: voice, seekRevision: scripts ? revision : nil, fingerprint: scripts ? fingerprint : nil)
  }

  private func makeRelay(_ link: FakeLink, initial: PadRemote.State?) -> PadVoiceRelay {
    let suite = "VideoPrompterTests.padRelay.\(UUID().uuidString)"
    removeDefaultsAtTeardown(suite)
    let relay = PadVoiceRelay(link: link, suiteName: suite)
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

  func testFollowsAreSentAndCoalescedToTheNewestWord() async throws {
    let (relay, link) = try await started()
    hear(relay, "alpha bravo")
    hear(relay, "charlie delta echo")
    XCTAssertTrue(link.follows.isEmpty, "nothing is written inside the turn that heard the words")
    try await until("follow") { !link.follows.isEmpty }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(link.follows.count, 1, "two words in one turn make one message")
    let confirmed = try XCTUnwrap(relay.session?.lastConfirmedTokenIndex)
    XCTAssertGreaterThanOrEqual(confirmed, 4)
    XCTAssertEqual(link.follows.first, PadRemote.Follow(confirmed: confirmed, fingerprint: fingerprint, seekRevision: 4))
    hear(relay, "foxtrot")
    try await until("second follow") { link.follows.count == 2 }
    XCTAssertEqual(link.follows.last?.confirmed, relay.session?.lastConfirmedTokenIndex)
    relay.stop()
  }

  func testAnIPadSeekMovesTheRelayOnceAndWordChangesAloneDoNot() async throws {
    let (relay, link) = try await started()
    let session = try XCTUnwrap(relay.session)
    let before = session.seekRevision
    // The iPad's word moving as it follows us is not a seek.
    for word in [2, 3, 4] { relay.iPadStateChanged(state(running: true, word: word)) }
    XCTAssertEqual(session.seekRevision, before)
    // A word heard but not yet sent is stale once the iPad has seeked elsewhere.
    hear(relay, "alpha bravo")
    relay.iPadStateChanged(state(running: true, word: 15, revision: 5))
    XCTAssertEqual(session.seekRevision, before + 1)
    XCTAssertEqual(session.tokenIndex, 14)
    relay.iPadStateChanged(state(running: true, word: 16, revision: 5))
    relay.iPadStateChanged(state(running: true, word: 17, revision: 5))
    XCTAssertEqual(session.seekRevision, before + 1, "exactly one re-seek")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(link.follows.isEmpty, "the follow made before the seek is dropped, not sent with the new revision")
    // The next word goes out with the new revision, and the relay's own seek was not echoed.
    hear(relay, "papa quebec")
    try await until("follow") { !link.follows.isEmpty }
    XCTAssertEqual(link.follows.map(\.seekRevision), [5])
    // An older revision (a late state) neither seeks nor changes the stamp.
    relay.iPadStateChanged(state(running: true, word: 3, revision: 4))
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

  func testAStopPausesTheIPadAndLeavesTheVoiceSource() async throws {
    let (relay, link) = try await started()
    relay.stop()
    XCTAssertEqual(link.sent.last, .pause)
    XCTAssertFalse(link.sent.contains(.voiceSource("iPad")))
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
  }

  func testAnotherScriptOnTheIPadEndsTheRelay() async throws {
    let (relay, link) = try await started()
    var other = state(running: true)
    other.fingerprint = "0000000000000000"
    relay.iPadStateChanged(other)
    XCTAssertFalse(relay.isRelaying)
    XCTAssertEqual(link.sent.last, .pause)
  }

  func testRefusesWhileTheMacsOwnPresenterListens() {
    let link = FakeLink()
    let relay = makeRelay(link, initial: state())
    relay.presenterIsCapturing = { true }
    relay.start(script: record, settings: PrompterSettings())
    XCTAssertFalse(relay.isRelaying)
    XCTAssertTrue(relay.status.contains("presenter"), relay.status)
    XCTAssertTrue(link.sent.isEmpty)
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

  // MARK: - Control messages beat video

  private final class StalledPipe: LinkPipe, @unchecked Sendable {
    let written = Mutex<[Data]>([])
    let waiting = Mutex<[@Sendable () -> Void]>([])
    override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
      written.withLock { $0.append(data) }
      waiting.withLock { $0.append(done) }
    }
    /// The transport finishes the write it was on.
    func finishOne() { waiting.withLock { $0.isEmpty ? nil : $0.removeFirst() }?() }
  }

  func testAControlMessageSentAfterManyFramesIsWrittenBeforeThem() throws {
    let pipe = StalledPipe(name: "stalled")
    let frame = CameraLink.Message.frame(time: 0, keyFrame: false, data: Data(repeating: 1, count: 10_000)).encoded()
    for _ in 0..<40 { pipe.send(frame) }
    XCTAssertEqual(pipe.pendingBytes, 40 * frame.count)
    pipe.send(CameraLink.Message.command(.pause).encoded())
    pipe.send(CameraLink.Message.command(.play).encoded())
    for _ in 0..<42 { pipe.finishOne() }
    let written = pipe.written.withLock { $0 }
    XCTAssertEqual(written.count, 42)
    var reader = CameraLink.Reader()
    let messages = try written.flatMap { try reader.append($0) }
    // The first frame was already on the wire; the commands go next, in order, ahead of the other 39.
    XCTAssertEqual(messages[1], .command(.pause))
    XCTAssertEqual(messages[2], .command(.play))
    XCTAssertEqual(messages.filter { if case .frame = $0 { true } else { false } }.count, 40, "no frame is lost")
    XCTAssertEqual(pipe.pendingBytes, 0)
  }
}
