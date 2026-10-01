import AppKit
import Foundation
import PrompterCore
import XCTest
@testable import VidPrompt
@testable import PrompterCore

final class LinkedSecurityTests: XCTestCase {
  func testManagedWritesReplaceAtomicallyAndExternalWritesKeepIdentity() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/jps-\(UUID())")
    let external = root.deletingLastPathComponent().appendingPathComponent("external-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
    let library = try MarkdownLibrary(rootURL: root)
    let record = try await library.create(title: "Draft", markdown: "original")
    let index = root.appendingPathComponent("LibraryIndex.json")
    let originalInode = try FileManager.default.attributesOfItem(atPath: index.path)[.systemFileNumber] as? NSNumber
    _ = try await library.updateMetadata(record.id, title: "Renamed")
    XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.systemFileNumber] as? NSNumber, originalInode)
    try "original".write(to: external, atomically: true, encoding: .utf8)
    _ = try await library.link(record.id, to: external)
    let fileInode = try FileManager.default.attributesOfItem(atPath: external.path)[.systemFileNumber] as? NSNumber
    _ = try await library.save(record.id, markdown: "local", expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: external.path)[.systemFileNumber] as? NSNumber, fileInode)
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "local")
  }
  func testSaveBetweenReadAndDateSamplingIsNotMarkedAsSeen() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/jps-\(UUID())")
    let external = root.deletingLastPathComponent().appendingPathComponent("external-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
    let library = try MarkdownLibrary(rootURL: root)
    let record = try await library.create(title: "Race", markdown: "original")
    try "original".write(to: external, atomically: true, encoding: .utf8)
    _ = try await library.link(record.id, to: external)
    try "first save".write(to: external, atomically: true, encoding: .utf8)
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: external.path)
    // Save immediately after the read, before the old implementation sampled its date.
    await library.setLinkedReadHook {
      try! "later save".write(to: external, atomically: false, encoding: .utf8)
      try! FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(1)], ofItemAtPath: external.path)
    }
    let first = try await library.externalChange(for: record.id)
    XCTAssertEqual(first?.markdown, "first save")
    await library.setLinkedReadHook(nil)
    let second = try await library.externalChange(for: record.id)
    XCTAssertEqual(second?.markdown, "later save")
  }
  func testUnsafeLinksAreRefusedAndReplacementSymlinkCannotRedirectWrites() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/jps-\(UUID())")
    let external = root.deletingLastPathComponent().appendingPathComponent("external-\(UUID()).md")
    let victim = root.deletingLastPathComponent().appendingPathComponent("victim-\(UUID()).md")
    defer { for url in [root, external, victim] { try? FileManager.default.removeItem(at: url) } }
    let library = try MarkdownLibrary(rootURL: root)
    let record = try await library.create(title: "Protected", markdown: "original")
    let managed = try await library.scriptURL(for: record.id)
    do { _ = try await library.link(record.id, to: managed); XCTFail("Managed files cannot be linked originals") } catch {}
    try "original".write(to: external, atomically: true, encoding: .utf8)
    try "victim".write(to: victim, atomically: true, encoding: .utf8)
    _ = try await library.link(record.id, to: external)
    try FileManager.default.removeItem(at: external)
    try FileManager.default.createSymbolicLink(at: external, withDestinationURL: victim)
    let state = try await library.linkState(for: record.id)
    XCTAssertTrue(state.isBroken)
    _ = try await library.save(record.id, markdown: "local", expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "victim")
  }
}
@MainActor final class SettingsSecurityTests: XCTestCase {
  func testOversizedStoredSettingsClampBeforeIntegerReadouts() throws {
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: "/private/tmp/jps-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "SecuritySettings.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("{\"fontSize\":1e20,\"speed\":-1e20}".utf8), forKey: "settings")
    defaults.set(Data("{\"sourceFontName\":\"Lexend Deca\",\"previewFontName\":\"Lexend Deca\",\"sourceFontSize\":1e20,\"previewFontSize\":-1e20}".utf8), forKey: "editorTypography")
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(Int(store.settings.fontSize), 120); XCTAssertEqual(Int(store.settings.speed), 20)
    XCTAssertEqual(Int(store.sourceFontSize), 40); XCTAssertEqual(Int(store.previewFontSize), 12)
  }
}
