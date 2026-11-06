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
      camera.displayMode = .videoOnly
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, hasScript: false, camera: camera, monitor: monitor, startsCamera: false, recorder: recorder), name: "camera-only-200-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      camera.displayMode = .prompterWithVideo
      recorder.phase = .recording
      recorder.inputMeter.show(channelPeaks: [0.1, 0.5])
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false, recorder: recorder), name: "presenter-recording-200-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      try await snapshot(RecordingInputLevel(meter: recorder.inputMeter).padding().uiZoom(2), name: "recording-meter-200-\(mode)", size: .init(width: 700, height: 320), scheme: scheme, destination: destination)
      for zoom in [1.0, 1.5, 2.0] {
        for phase in [CameraRecorder.Phase.preparing, .recording, .saving, .idle] {
          recorder.phase = phase
          recorder.savedTake = phase == .idle ? URL(fileURLWithPath: "/tmp/Studio take 2026-11-06.mov") : nil
          try await snapshot(RecordingStatusPanel(recorder: recorder, camera: camera, zoom: zoom, dismiss: {}), name: "recording-status-\(phase.rawValue)-\(Int(zoom * 100))-\(mode)", size: .init(width: 700, height: 440), scheme: scheme, destination: destination)
        }
      }
      let failedRecorder = CameraRecorder(defaults: defaults)
      let disconnectedCamera = CameraModel(defaults: defaults)
      disconnectedCamera.selectedUID = nil
      await failedRecorder.start(camera: disconnectedCamera)
      failedRecorder.errorMessage = nil
      for zoom in [1.0, 1.5, 2.0] {
        try await snapshot(RecordingStatusPanel(recorder: failedRecorder, camera: disconnectedCamera, zoom: zoom, dismiss: {}), name: "recording-status-failed-\(Int(zoom * 100))-\(mode)", size: .init(width: 700, height: 440), scheme: scheme, destination: destination)
      }
      recorder.savedTake = URL(fileURLWithPath: "/tmp/Studio take 2026-11-06.mov")
      store.settings.mode = "Manual"
      store.session.updateSettings(store.settings)
      store.session.play()
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false, recorder: recorder), name: "presenter-saved-reading-200-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      store.session.pause()
      recorder.savedTake = nil
      recorder.phase = .idle
      store.uiZoom = 1
      try await snapshot(PresenterSettingsPopover(store: store), name: "take-setup-\(mode)", size: .init(width: 540, height: 600), scheme: scheme, destination: destination)
      try await snapshot(PresenterReferenceCue(passage: String(repeating: "A short reference to check the composition. ", count: 20), fontName: "Helvetica Neue", readingSize: 48, zoom: 2, end: {}), name: "reference-cue-200-\(mode)", size: .init(width: 1000, height: 220), scheme: scheme, destination: destination)

      try await snapshot(SettingsPage(store: store, tab: .microphone).uiZoom(2), name: "settings-Voice-200-\(mode)", size: .init(width: 560, height: 700), scheme: scheme, destination: destination)
      camera.guides.zebras = true; camera.guides.falseColour = true
      try await snapshot(CameraExposureSettings(model: camera), name: "exposure-active-\(mode)", size: .init(width: 480, height: 900), scheme: scheme, destination: destination)
      camera.guides.zebras = false; camera.guides.falseColour = false
      try await snapshot(RecordingSettingsPanel(recorder: recorder, camera: camera), name: "recording-settings-\(mode)", size: .init(width: 500, height: 850), scheme: scheme, destination: destination)
      try await snapshot(CameraExposureSettings(model: camera), name: "exposure-tools-\(mode)", size: .init(width: 480, height: 640), scheme: scheme, destination: destination)
      store.settings.mode = "Manual"
      store.session.updateSettings(store.settings)
      store.session.play()
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false, recorder: recorder), name: "presenter-reading-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      store.session.pause()
      camera.displayMode = .prompterOnly
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
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        try await snapshot(ReadingSettingsSheet(store: store, camera: camera), name: "reading-settings-wide-\(Int(zoom * 100))-\(mode)", size: .init(width: min(880, 440 * zoom), height: 720), scheme: scheme, destination: destination)
        let devices = (1...12).map { CameraDevice(uid: "fixture-\($0)", name: "Camera \($0) with a long descriptive studio name") }
        camera.selectedUID = "fixture-10"
        camera.authorization = .authorized
        try await snapshot(CameraPickerList(model: camera, zoom: zoom, startsPreview: false, devicesOverride: devices, close: {}).uiZoom(zoom), name: "camera-picker-many-\(Int(zoom * 100))-\(mode)", size: .init(width: 600, height: 880), scheme: scheme, destination: destination)
      }
      camera.selectedUID = nil
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

  func testDesignSpecFixtures() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let destination = URL(fileURLWithPath: output)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = freshDefaults("DesignSpecSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["snapshot", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "A clear opening", markdown: "# A clear opening\n\nRead these opening words at your own pace.\n\nA second paragraph keeps the reading line easy to follow.")
    store.session.present(record: record, settings: store.settings)
    let draft = PresenterDraft(record: record)
    let camera = CameraModel(defaults: defaults); camera.recordingReadyOverride = true
    let recorder = CameraRecorder(defaults: defaults)
    let monitor = ReferenceMonitor()
    for (mode, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != mode { continue }
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom; camera.displayMode = .prompterWithVideo; recorder.phase = .idle
        try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false, recorder: recorder), name: "presenter-idle-camera-\(Int(zoom * 100))-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
        if zoom != 1.5 {
          recorder.phase = .recording; recorder.inputMeter.show(channelPeaks: [0.2, 0.4])
          try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false, recorder: recorder), name: "presenter-taking-\(Int(zoom * 100))-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
          recorder.phase = .idle
          for tab in SettingsTab.allCases {
            try await snapshot(SettingsPage(store: store, tab: tab).uiZoom(zoom), name: "settings-\(tab.rawValue)-\(Int(zoom * 100))-\(mode)", size: .init(width: 560, height: 640), scheme: scheme, destination: destination)
          }
        }
      }
      store.uiZoom = 1; camera.cleanView = true
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, monitor: monitor, startsCamera: false, recorder: recorder), name: "presenter-clean-view-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      camera.cleanView = false; camera.displayMode = .videoOnly; store.uiZoom = 2
      try await snapshot(PresenterView(store: store, session: store.session, draft: draft, hasScript: false, camera: camera, monitor: monitor, startsCamera: false, recorder: recorder), name: "presenter-camera-only-200-\(mode)", size: .init(width: 1000, height: 700), scheme: scheme, destination: destination)
      store.uiZoom = 1; recorder.usesSeparateMicrophone = true
      try await snapshot(MicrophonePage(store: store, recorder: recorder), name: "microphone-separate-\(mode)", size: .init(width: 560, height: 750), scheme: scheme, destination: destination)
      try await snapshot(CameraExposureSettings(model: camera), name: "exposure-panel-\(mode)", size: .init(width: 560, height: 600), scheme: scheme, destination: destination)
    }
  }

  func snapshot<V: View>(_ content: V, name: String, size: NSSize, scheme: ColorScheme, destination: URL) async throws {
    let host = NSHostingView(rootView: content.environment(\.offscreenRendering, true).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme).preferredColorScheme(scheme))
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
    if name.hasPrefix("library-100-scripts-200-") {
      func outlines(_ view: NSView) -> [NSOutlineView] {
        (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines)
      }
      let list = try XCTUnwrap(outlines(host).first)
      XCTAssertGreaterThanOrEqual(list.rows(in: list.visibleRect).length, 7,
        "At 200%, document navigation retains a useful viewport")
    }
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    let corner = bitmap.colorAt(x: 0, y: 0)
    let hasRenderedContent = stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 64)).contains { y in
      stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 64)).contains { x in
        bitmap.colorAt(x: x, y: y) != corner
      }
    }
    XCTAssertTrue(hasRenderedContent, "The snapshot must not be a blank compositor surface: \(name)")
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: destination.appendingPathComponent(name + ".png"))
    XCTAssertGreaterThan(data.count, 2_000, "A page must contain rendered content")
    let metadata: [String: Any] = ["page": name, "width": size.width, "height": size.height, "visible": window.isVisible, "renderer": "NSHostingView.cacheDisplay", "presenterAppearance": "Solid Reduce Transparency fallback", "limit": "Offscreen content only; native window glass and active toolbar require live review"]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent(name + "-snapshot.json"))
    print("SNAPSHOT \(destination.appendingPathComponent(name + ".png").path)")
  }
}
