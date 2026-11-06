import CoreFoundation
import Foundation
import PrompterCore
import Synchronization
import XCTest

@testable import VideoPrompter

/// Test-only preferences cleanup. `removePersistentDomain` empties a suite, but cfprefsd still
/// leaves its plist behind, so this also flushes the domain and deletes exactly that one file.
/// Call it only after every writer for the suite has stopped or been flushed.
enum TestDefaults {
  private static let removedSuites = Mutex<Set<String>>([])
  static var folder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
  }

  static func plist(for suite: String) -> URL { folder.appendingPathComponent(suite + ".plist") }

  /// Only names a test made: never a path, a global or Apple domain, or the app's own domain.
  static func isRemovable(_ suite: String) -> Bool {
    !suite.isEmpty && !suite.hasPrefix(".") && !suite.contains("/") && !suite.hasPrefix("com.apple.")
      && suite != "com.juniornkanabassi.VidPrompt" && suite != Bundle.main.bundleIdentifier
  }

  /// The suite `AppStore.preferences(arguments:)` opens for a `--data-directory` launch.
  static func derivedSuite(arguments: [String]) -> String {
    let root = ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: arguments)
    return "VidPrompt.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))"
  }

  static func derivedSuite(dataDirectory root: URL) -> String {
    derivedSuite(arguments: ["test", "--data-directory", root.path])
  }

  private static let recordedSuites = Mutex<Set<String>>([])

  /// Every test suite comes from here, so the runner (checks/run-xctest.sh) can remove exactly
  /// these domains once the test process has exited and cfprefsd has stopped writing for it.
  static func suite(named suite: String) -> UserDefaults? {
    record(suite)
    return UserDefaults(suiteName: suite)
  }

  /// Appends `suite` to the file named by VIDEOPROMPTER_TEST_DEFAULTS_MANIFEST, once per process.
  /// Recorded before the suite is opened, so a crash after the first write still leaves its name.
  static func record(_ suite: String) {
    guard let path = ProcessInfo.processInfo.environment["VIDEOPROMPTER_TEST_DEFAULTS_MANIFEST"],
      !path.isEmpty, recordedSuites.withLock({ $0.insert(suite).inserted })
    else { return }
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard descriptor >= 0 else { return XCTFail("Cannot record test defaults suite in \(path)") }
    defer { close(descriptor) }
    let line = Array((suite + "\n").utf8)
    if write(descriptor, line, line.count) != line.count { XCTFail("Cannot record test defaults suite \(suite)") }
  }

  static func remove(_ suite: String) {
    guard isRemovable(suite) else {
      XCTFail("Refusing to remove preferences domain \(suite)")
      return
    }
    record(suite)
    removedSuites.withLock { _ = $0.insert(suite) }
    let defaults = UserDefaults(suiteName: suite)
    defaults?.removePersistentDomain(forName: suite)
    defaults?.synchronize()
    CFPreferencesSynchronize(suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    // The exact file only, once cfprefsd has written it: never a pattern or the whole folder.
    try? FileManager.default.removeItem(at: plist(for: suite))
    StandardDomainCleanup.registerOnce()
  }

  static func removeFlushedFiles() {
    let suites = removedSuites.withLock { Array($0) }
    // A later defaults flush can recreate an earlier suite's empty plist. Flush all before
    // deleting any, once the bundle has finished and all per-test writers have stopped.
    for suite in suites {
      CFPreferencesSynchronize(suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    for suite in suites { try? FileManager.default.removeItem(at: plist(for: suite)) }
  }
}

extension XCTestCase {
  /// Removes `suite` and its plist when the test ends, pass or fail. Register it before any
  /// writer's own flush (XCTest runs teardown blocks last in, first out).
  func removeDefaultsAtTeardown(_ suite: String) {
    TestDefaults.record(suite)
    StandardDomainCleanup.registerOnce()
    addTeardownBlock { TestDefaults.remove(suite) }
  }

  /// The derived suite of an `AppStore` made without injected defaults.
  func removeDerivedDefaultsAtTeardown(dataDirectory root: URL) {
    removeDefaultsAtTeardown(TestDefaults.derivedSuite(dataDirectory: root))
  }
}

/// Objects built with their default `.standard` defaults (SessionStore, CameraModel.shared,
/// CameraGuideStore, ICloudScripts) write the test runner's own domain. At the end of the bundle
/// this removes the keys the run added there, and the plist too if the run created it.
final class StandardDomainCleanup: NSObject, XCTestObservation {
  nonisolated(unsafe) private static var observer: StandardDomainCleanup?
  private let domain: String
  private let keysBefore: Set<String>
  private let fileExisted: Bool

  /// The app's own keys never belong to the runner's domain, even if written before registration.
  static let appKeys: Set<String> = [
    "readingPositions", "cameraGuides", "cameraDeviceUID", "cameraMirrored", "cameraAlwaysOnTop",
    "presenterDisplayMode", "presenterWithVideo", "recordingPreset", "recordingFloatAudio",
    "recordingMicrophoneUID", "sendCameraOverWiFi", "sendCameraPairingCodes",
    // ICloudScripts' keys, spelled out because that type is main-actor isolated.
    "keepScriptsInICloud", "unlinkICloudScriptsPending", "iCloudScriptMirrors",
    "iCloudScriptMirrorsDeclined", "iCloudPresetsFingerprint",
  ]

  private init(domain: String) {
    self.domain = domain
    keysBefore = Set(UserDefaults.standard.persistentDomain(forName: domain).map { Array($0.keys) } ?? [])
      .subtracting(Self.appKeys)
    fileExisted = FileManager.default.fileExists(atPath: TestDefaults.plist(for: domain).path)
  }

  static func registerOnce() {
    guard observer == nil else { return }
    let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    let cleanup = StandardDomainCleanup(domain: domain)
    observer = cleanup
    XCTestObservationCenter.shared.addTestObserver(cleanup)
  }

  func testBundleDidFinish(_ testBundle: Bundle) {
    let standard = UserDefaults.standard
    let current = standard.persistentDomain(forName: domain) ?? [:]
    for key in current.keys where !keysBefore.contains(key) { standard.removeObject(forKey: key) }
    standard.synchronize()
    CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    // Only a file this run created, and only once nothing is left in it.
    if !fileExisted, (standard.persistentDomain(forName: domain) ?? [:]).isEmpty {
      try? FileManager.default.removeItem(at: TestDefaults.plist(for: domain))
    }
    TestDefaults.removeFlushedFiles()
  }
}

/// Regression checks for the cleanup itself.
final class TestDefaultsTests: XCTestCase {
  func testRemoveDeletesTheSuitesPlistFileAndNothingElse() throws {
    let suite = "VideoPrompterTests.cleanup.\(UUID().uuidString)"
    let neighbour = "VideoPrompterTests.cleanup.\(UUID().uuidString)"
    removeDefaultsAtTeardown(neighbour)
    for name in [suite, neighbour] {
      let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
      defaults.set("value", forKey: "key")
      defaults.synchronize()
      CFPreferencesSynchronize(name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: TestDefaults.plist(for: suite).path), "the write reached disk")
    TestDefaults.remove(suite)
    XCTAssertFalse(FileManager.default.fileExists(atPath: TestDefaults.plist(for: suite).path), "plist removed")
    XCTAssertNil(TestDefaults.suite(named: suite)?.object(forKey: "key"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: TestDefaults.plist(for: neighbour).path), "another suite is untouched")
    XCTAssertEqual(TestDefaults.suite(named: neighbour)?.string(forKey: "key"), "value")
  }

  func testRefusesDomainsATestDidNotMake() {
    for name in ["", ".GlobalPreferences", "com.apple.finder", "com.juniornkanabassi.VidPrompt", "../x", "a/b"] {
      XCTAssertFalse(TestDefaults.isRemovable(name), name)
    }
    XCTAssertTrue(TestDefaults.isRemovable("VideoPrompterTests.\(UUID())"))
    XCTAssertTrue(TestDefaults.isRemovable(TestDefaults.derivedSuite(dataDirectory: URL(fileURLWithPath: "/tmp/x"))))
  }

  /// The name the helper derives is the suite AppStore really writes.
  @MainActor func testDerivedSuiteMatchesAppStorePreferences() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("derived-\(UUID())")
    let arguments = ["test", "--data-directory", root.path]
    let suite = TestDefaults.derivedSuite(arguments: arguments)
    removeDefaultsAtTeardown(suite)
    AppStore.preferences(arguments: arguments).set(42, forKey: "derivedProbe")
    XCTAssertEqual(TestDefaults.suite(named: suite)?.integer(forKey: "derivedProbe"), 42)
    TestDefaults.remove(suite)
    XCTAssertFalse(FileManager.default.fileExists(atPath: TestDefaults.plist(for: suite).path))
  }

  /// A failing test still removes its suite: the cleanup is a teardown block, not trailing code.
  func testCleanupStillRunsWhenTheTestFails() throws {
    let probe = FailingProbe(selector: #selector(FailingProbe.probeFailsAfterWriting))
    probe.run()
    let suite = try XCTUnwrap(probe.suite)
    XCTAssertFalse(probe.issues.isEmpty, "the probe really failed")
    XCTAssertTrue(probe.wroteFile, "the probe's suite reached disk before failing")
    XCTAssertFalse(FileManager.default.fileExists(atPath: TestDefaults.plist(for: suite).path), "teardown removed the plist")
    XCTAssertNil(TestDefaults.suite(named: suite)?.object(forKey: "key"))
  }
}

/// Run only by `testCleanupStillRunsWhenTheTestFails`: its method is not named `test…`, and its
/// deliberate failure is captured here instead of being reported.
final class FailingProbe: XCTestCase {
  var suite: String?
  var wroteFile = false
  var issues: [XCTIssue] = []

  @objc func probeFailsAfterWriting() throws {
    let name = "VideoPrompterTests.failing.\(UUID().uuidString)"
    suite = name
    removeDefaultsAtTeardown(name)
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defaults.set("value", forKey: "key")
    defaults.synchronize()
    CFPreferencesSynchronize(name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    wroteFile = FileManager.default.fileExists(atPath: TestDefaults.plist(for: name).path)
    XCTFail("deliberate failure before cleanup")
  }

  override func record(_ issue: XCTIssue) { issues.append(issue) }
}
