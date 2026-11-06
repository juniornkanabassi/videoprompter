import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Opt-in, offscreen snapshots. No window is ordered, camera requested or account connected.
@MainActor final class AppearanceSnapshotTests: XCTestCase {
  func testEveryPageInLightAndDark() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let output = environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in image check: run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoPrompter-snapshot-fixture-\(UUID())", isDirectory: true)
    let previousCloud = ICloudScripts.cloudDocsOverride
    ICloudScripts.cloudDocsOverride = root.appendingPathComponent("UnavailableCloud")
    let suite = "VideoPrompter.Appearance.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["snapshot", "--data-directory", root.path], defaults: defaults)
    addTeardownBlock { @MainActor in
      _ = await store.flushPendingSaves()
      TestDefaults.remove(suite)
      ICloudScripts.cloudDocsOverride = previousCloud
      try? FileManager.default.removeItem(at: root)
    }
    let record = try await store.createScript(title: "A clear opening", markdown: "# A clear opening\n\nRead these opening words at your own pace.\n\nA second paragraph keeps the reading line easy to follow.\n\n**Important words** stay clear, with a [reference](https://example.com).")
    _ = try await store.createScript(title: "A longer title for the next recording", markdown: "A second saved script.")
    store.selectedID = record.id
    _ = try await store.createLibraryFolder(named: "Recordings")
    store.savePreset(named: "Studio")
    let camera = CameraModel(defaults: defaults)
    camera.authorization = .authorized
    let recorder = CameraRecorder(defaults: defaults)
    let link = IPadCameraSender(defaults: defaults)
    let monitor = ReferenceMonitor()
    store.settings.fontName = "Helvetica Neue"
    store.previewFontName = "Helvetica Neue"
    store.session.present(record: record, settings: store.settings)
    let draft = PresenterDraft(record: record)
    let previousAppearance = NSApp.appearance
    defer { NSApp.appearance = previousAppearance }
    for (mode, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
      if let requested = environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != mode { continue }
      NSApp.appearance = NSAppearance(named: appearance)
      store.inspector = false
      try await snapshot(LibraryView(store: store, camera: camera), name: "library-\(mode)", size: .init(width: 1200, height: 800), scheme: scheme, destination: destination)
      store.inspector = true
      try await snapshot(LibraryView(store: store, camera: camera), name: "library-inspector-\(mode)", size: .init(width: 1440, height: 900), scheme: scheme, destination: destination)
      try await snapshot(InspectorView(store: store, camera: camera), name: "presenter-inspector-\(mode)", size: .init(width: 360, height: 900), scheme: scheme, destination: destination)
      try await snapshot(ReferenceMonitorCaption(passage: String(repeating: "Welcome back. Bonjour à toutes et à tous. ", count: 30), fontName: "Helvetica Neue", readingSize: 48, end: {}), name: "reference-monitor-\(mode)", size: .init(width: 1000, height: 400), scheme: scheme, destination: destination)
      for tab in SettingsTab.allCases {
        try await snapshot(AppSettingsView(store: store, selectedTab: tab), name: "settings-\(tab.rawValue)-\(mode)", size: .init(width: 560, height: 640), scheme: scheme, destination: destination)
      }
      try await snapshot(CameraView(model: camera, recorder: recorder, startsCamera: false), name: "camera-\(mode)", size: .init(width: 960, height: 640), scheme: scheme, destination: destination)
      try await snapshot(GoogleDocsSheet(google: GoogleDocs(), importDocument: { _ in nil }), name: "google-docs-\(mode)", size: .init(width: 640, height: 560), scheme: scheme, destination: destination)
      try await snapshot(RelinkSheet(store: store, script: record), name: "relink-\(mode)", size: .init(width: 640, height: 320), scheme: scheme, destination: destination)
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false), name: "presenter-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      draft.begin(session: store.session)
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false), name: "presenter-editor-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      draft.cancel(resuming: false)
      camera.displayMode = .prompterWithVideo
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false), name: "presenter-camera-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      camera.displayMode = .prompterOnly
      // The bar at 200%, with the camera off (picker and guides dimmed) and on.
      store.uiZoom = 2
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false), name: "presenter-200-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      camera.displayMode = .prompterWithVideo
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false), name: "presenter-camera-200-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      try await snapshot(LibraryView(store: store, camera: camera), name: "library-200-\(mode)", size: .init(width: 1440, height: 900), scheme: scheme, destination: destination)
      try await snapshot(GoogleDocsSheet(google: GoogleDocs(), importDocument: { _ in nil }, zoom: 2), name: "google-docs-200-\(mode)", size: .init(width: 640, height: 560), scheme: scheme, destination: destination)
      camera.displayMode = .prompterOnly
      store.uiZoom = 1
      try await snapshot(IPadRemoteView(link: link, startsLink: false), name: "ipad-remote-\(mode)", size: .init(width: 480, height: 420), scheme: scheme, destination: destination)
    }
    XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "Snapshots must never order windows")
  }

  func testFirstLaunchRecoveryAndGrowingLibrary() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRoundTwo-\(UUID())")
    let previousCloud = ICloudScripts.cloudDocsOverride
    ICloudScripts.cloudDocsOverride = root.appendingPathComponent("UnavailableCloud")
    let suite = "LibraryRoundTwo.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["snapshot", "--data-directory", root.path], defaults: defaults, offersWelcomeScript: true)
    await store.waitForWelcomeScript()
    let camera = CameraModel(defaults: defaults)
    let destination = URL(fileURLWithPath: output)
    let previous = NSApp.appearance
    defer { NSApp.appearance = previous }
    addTeardownBlock { @MainActor in
      _ = await store.flushPendingSaves()
      TestDefaults.remove(suite)
      ICloudScripts.cloudDocsOverride = previousCloud
      try? FileManager.default.removeItem(at: root)
    }
    let comparison = RelinkComparison(libraryText: "# Opening\n\nBonjour à tous. Here is the saved draft.\n\nThe second paragraph contains the original ending.",
      fileText: "# Opening\n\nBonjour à tous. Here is the revised draft.\n\nA different ending for today's recording.",
      libraryDate: Date(timeIntervalSince1970: 1793966400), fileDate: Date(timeIntervalSince1970: 1793970000), fingerprint: "fixture")
    for (mode, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != mode { continue }
      NSApp.appearance = NSAppearance(named: appearance)
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        try await snapshot(LibraryView(store: store, camera: camera), name: "first-launch-\(Int(zoom * 100))-\(mode)", size: .init(width: 1132, height: 800), scheme: scheme, destination: destination)
        try await snapshot(CameraPickerList(model: camera, zoom: zoom, startsPreview: false, close: {}).uiZoom(zoom), name: "camera-picker-\(Int(zoom * 100))-\(mode)", size: .init(width: 600, height: 700), scheme: scheme, destination: destination)
        try await snapshot(RelinkComparisonView(comparison: comparison).padding(24).uiZoom(zoom), name: "relink-comparison-\(Int(zoom * 100))-\(mode)", size: .init(width: 700, height: 800), scheme: scheme, destination: destination)
      }
      store.uiZoom = 1
      var markdown = WelcomeScript.markdown
      try await snapshot(FormattedMarkdownEditor(markdown: Binding(get: { markdown }, set: { markdown = $0 }), fontName: "Helvetica Neue", fontSize: 18).padding(24), name: "welcome-callout-\(mode)", size: .init(width: 650, height: 850), scheme: scheme, destination: destination)
    }
    for index in 1...100 {
      _ = try await store.createScript(title: "Episode \(index): A longer title about football and recording", markdown: "Script \(index)")
    }
    for index in 1...12 { _ = try await store.createLibraryFolder(named: "Series \(index)") }
    store.selectedID = store.scripts.first?.id
    store.inspector = false
    for (mode, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != mode { continue }
      NSApp.appearance = NSAppearance(named: appearance)
      for zoom in [1.0, 2.0] {
        store.uiZoom = zoom
        try await snapshot(LibraryView(store: store, camera: camera), name: "library-100-scripts-\(Int(zoom * 100))-\(mode)", size: .init(width: 1132, height: 800), scheme: scheme, destination: destination)
      }
    }
    XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
  }

  private func snapshot<V: View>(_ content: V, name: String, size: NSSize, scheme: ColorScheme, destination: URL) async throws {
    let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme).preferredColorScheme(scheme))
    let window = NSWindow(contentRect: NSRect(origin: .init(x: -20000, y: -20000), size: size), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    defer { window.contentView = nil; window.close() }
    for _ in 0..<4 {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: destination.appendingPathComponent(name + ".png"))
    XCTAssertGreaterThan(data.count, 2_000, "A page must contain rendered content")
    let metadata: [String: Any] = ["page": name, "width": size.width, "height": size.height, "visible": window.isVisible, "renderer": "NSHostingView.cacheDisplay", "limit": "Offscreen content only; native window glass and active toolbar require live review"]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent(name + "-snapshot.json"))
    print("SNAPSHOT \(destination.appendingPathComponent(name + ".png").path)")
  }
}
