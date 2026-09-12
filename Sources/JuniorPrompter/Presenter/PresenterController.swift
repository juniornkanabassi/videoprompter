import AppKit
import PrompterCore
import SwiftUI

@MainActor final class PresenterController: NSObject, NSWindowDelegate {
  static let shared = PresenterController()
  private var panel: NSPanel?
  private var screenObserver: NSObjectProtocol?
  private weak var activeSession: SessionStore?
  private var draft: PresenterDraft?
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let draft, draft.isEditing else { activeSession?.pause(); return true }
    draft.requestClose()
    return false
  }
  func present(store: AppStore, on screen: NSScreen? = nil) {
    guard draft?.isEditing != true else {
      draft?.errorMessage = "Finish or cancel the open edit before presenting another script."
      panel?.makeKeyAndOrderFront(nil)
      return
    }
    guard let script = store.selected else { return }
    store.session.present(record: script, settings: store.settings)
    activeSession = store.session
    let draft = PresenterDraft(record: store.session.activeRecord ?? script)
    self.draft = draft
    let panel = self.panel ?? makePanel()
    panel.title = "JuniorPrompter · \(script.metadata.title)"
    panel.contentView = NSHostingView(rootView: PresenterView(store: store, session: store.session, draft: draft))
    self.panel = panel
    let targetScreen = screen ?? (CommandLine.arguments.contains("--agent-screen")
      ? (NSScreen.screens.first(where: { $0.localizedName == "Prompter XL" }) ?? NSScreen.screens.first(where: { $0.localizedName == "Agent Screen" }))
      : nil)
    if let targetScreen {
      let area = targetScreen.visibleFrame
      let size = NSSize(width: min(760, area.width), height: min(520, area.height))
      panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                            width: size.width, height: size.height), display: true)
    }
    recoverVisibleFrame(panel)
    if screen != nil || CommandLine.arguments.contains("--agent-screen") {
      panel.orderFrontRegardless()
      panel.makeKey()
    } else {
      panel.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
  func close() {
    guard let draft, draft.isEditing else { closeNow(); return }
    draft.requestClose()
  }
  func closeNow() { activeSession?.pause(); panel?.orderOut(nil) }
  private func makePanel() -> NSPanel {
    let value = NSPanel(
      contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false
    )
    value.delegate = self
    value.level = .floating
    value.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
    value.sharingType = CommandLine.arguments.contains("--capture-visible") ? .readOnly : .none
    value.hidesOnDeactivate = false
    value.isMovableByWindowBackground = true
    value.isReleasedWhenClosed = false
    value.isOpaque = false
    value.backgroundColor = .clear
    value.titleVisibility = .hidden
    value.titlebarAppearsTransparent = true
    value.minSize = NSSize(width: 360, height: 220)
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { if let panel = self?.panel { self?.recoverVisibleFrame(panel) } }
    }
    return value
  }
  private func recoverVisibleFrame(_ panel: NSPanel) {
    guard !Self.hasReachableTitleBar(panel.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame)),
      let target = NSScreen.main ?? NSScreen.screens.first
    else { return }
    var frame = panel.frame
    frame.size.width = min(frame.width, target.visibleFrame.width)
    frame.size.height = min(frame.height, target.visibleFrame.height)
    frame.origin = NSPoint(
      x: target.visibleFrame.midX - frame.width / 2, y: target.visibleFrame.midY - frame.height / 2)
    panel.setFrame(frame, display: true)
  }
  static func hasReachableTitleBar(_ frame: NSRect, visibleFrames: [NSRect]) -> Bool {
    let titleBar = NSRect(x: frame.minX, y: frame.maxY - 44, width: frame.width, height: 44)
    return visibleFrames.contains {
      let overlap = titleBar.intersection($0)
      return overlap.width >= 120 && overlap.height >= 24
    }
  }
}

@MainActor final class PresenterDraft: ObservableObject {
  private(set) var recordID: UUID
  private(set) var expectedFingerprint: String
  private(set) var expectedRevision: UInt64
  @Published var markdown: String
  @Published var isEditing = false
  @Published var isSaving = false
  @Published var closeRequested = false
  @Published var errorMessage: String?
  @Published var noticeMessage: String?

  init(record: ScriptRecord) {
    recordID = record.id
    expectedFingerprint = record.metadata.contentFingerprint
    expectedRevision = record.metadata.revision
    markdown = record.markdown
  }
  func begin(session: SessionStore) {
    guard let record = session.activeRecord else { return }
    recordID = record.id
    expectedFingerprint = record.metadata.contentFingerprint
    expectedRevision = record.metadata.revision
    markdown = record.markdown
    session.pause()
    isEditing = true
    errorMessage = nil
    noticeMessage = nil
  }
  func cancel() { isEditing = false; closeRequested = false; errorMessage = nil }
  func requestClose() {
    guard !isSaving else {
      errorMessage = "Wait for the save to finish before closing the presenter."
      return
    }
    closeRequested = true
  }
  func confirm(store: AppStore) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await store.savePresentedMarkdown(
        markdown, for: recordID, expectedFingerprint: expectedFingerprint,
        expectedRevision: expectedRevision)
      if let saved = store.scripts.first(where: { $0.id == recordID }) {
        expectedFingerprint = saved.metadata.contentFingerprint
        expectedRevision = saved.metadata.revision
      }
      isEditing = false
      closeRequested = false
      errorMessage = nil
    } catch {
      errorMessage = "The script changed or could not be saved. Your presenter draft is still open. \(error)"
    }
  }
  func saveAsCopy(store: AppStore) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await store.savePresentedDraftAsCopy(markdown, for: recordID)
      isEditing = false
      closeRequested = false
      errorMessage = nil
      noticeMessage = "Draft saved as a separate script. The presenter remains on the original script."
    } catch {
      errorMessage = "The draft could not be saved as a separate script. \(error)"
    }
  }
  func hasExternalChange(in store: AppStore) -> Bool {
    guard let metadata = store.scripts.first(where: { $0.id == recordID })?.metadata else { return true }
    return metadata.contentFingerprint != expectedFingerprint || metadata.revision != expectedRevision
  }
}

private struct PresenterView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var session: SessionStore
  @ObservedObject var draft: PresenterDraft
  @FocusState private var editorFocused: Bool
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .top) {
        Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black).opacity(store.settings.backgroundOpacity)
        ScriptTextView(
          document: session.document, tokenIndex: session.tokenIndex,
          lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
          isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
          guideFraction: store.settings.guideFraction, fontName: store.settings.fontName,
          fontSize: store.settings.fontSize, textOpacity: store.settings.textOpacity,
          fontWeight: store.settings.fontWeight, textColorHex: store.settings.textColorHex,
          lineSpacing: store.settings.lineSpacing, paragraphSpacing: store.settings.paragraphSpacing,
          horizontalMargin: store.settings.horizontalMargin, alignment: store.settings.alignment,
          showCues: store.settings.showCues, highlightActiveWord: store.settings.highlightActiveWord,
          onSeek: session.seek
        )
        .scaleEffect(
          x: store.settings.horizontalMirror ? -1 : 1, y: store.settings.verticalMirror ? -1 : 1
        ).rotationEffect(.degrees(Double(store.settings.rotation)))
        .allowsHitTesting(!draft.isEditing)
        .accessibilityHidden(draft.isEditing)
        Rectangle().fill(.cyan.opacity(0.82)).frame(height: 2).offset(
          y: max(54, geometry.size.height * store.settings.guideFraction)
        ).allowsHitTesting(false)
      }
    }.background(Color.clear).onChange(of: store.settings) { _, value in
      session.updateSettings(value)
    }
    .overlay(alignment: .top) {
      ZStack {
        Image(systemName: "line.3.horizontal")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        WindowDragHandle()
      }
      .frame(width: 72, height: 24)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(.top, 4)
      .accessibilityLabel("Drag presenter window")
      .accessibilityHint("Drag to move the presenter window")
      .allowsHitTesting(!draft.isEditing)
      .accessibilityHidden(draft.isEditing)
    }
    .overlay(alignment: .bottom) {
      HStack(spacing: 8) {
        Button(action: session.previousPassage) { Image(systemName: "backward.end.fill") }
          .accessibilityLabel("Previous passage")
        Button(action: session.toggle) {
          Image(systemName: session.isActivelyRunning ? "pause.fill" : "play.fill")
        }.buttonStyle(.borderedProminent).accessibilityLabel(session.isActivelyRunning ? "Pause" : "Play")
        Button(action: session.nextPassage) { Image(systemName: "forward.end.fill") }
          .accessibilityLabel("Next passage")
        Button(action: session.restart) { Image(systemName: "arrow.counterclockwise") }
          .accessibilityLabel("Restart")
        Button {
          if draft.isEditing { draft.cancel() } else { draft.begin(session: session) }
        } label: {
          Image(systemName: draft.isEditing ? "xmark" : "pencil")
        }.accessibilityLabel(draft.isEditing ? "Cancel script edit" : "Edit script")
        Button { PresenterController.shared.close() } label: { Image(systemName: "xmark") }
          .accessibilityLabel("Close presenter")
      }
      .buttonStyle(.bordered).padding(8)
      .background(.ultraThinMaterial, in: Capsule()).padding(10)
      .disabled(draft.isEditing)
      .accessibilityHidden(draft.isEditing)
    }
    .overlay {
      if draft.isEditing {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Edit script").font(.headline)
            Spacer()
            Text("Markdown").foregroundStyle(.secondary)
          }
          TextEditor(text: $draft.markdown)
            .font(sourceEditorFont)
            .frame(maxHeight: .infinity)
            .focused($editorFocused)
            .onAppear { DispatchQueue.main.async { editorFocused = true } }
          if draft.hasExternalChange(in: store) {
            Text("This script changed outside JuniorPrompter. Confirming will keep this draft and show a conflict instead of overwriting it.")
              .foregroundStyle(.orange)
          }
          if let error = draft.errorMessage {
            Text(error).foregroundStyle(.red)
            Button("Save as Separate Script") { Task { await draft.saveAsCopy(store: store) } }
              .disabled(draft.isSaving)
          }
          HStack {
            Button("Cancel") { draft.cancel() }
              .keyboardShortcut(.cancelAction).disabled(draft.isSaving)
            Spacer()
            Button("Confirm edit") { Task { await draft.confirm(store: store) } }
              .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
              .disabled(draft.isSaving)
          }
        }
        .padding(16).frame(maxWidth: 720, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
      }
    }
    .confirmationDialog("Discard this presenter draft?", isPresented: $draft.closeRequested) {
      Button("Discard Draft and Close", role: .destructive) {
        draft.cancel()
        PresenterController.shared.closeNow()
      }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("The draft has not been saved to the script library.")
    }
    .onChange(of: draft.isEditing) { _, isEditing in
      if isEditing { DispatchQueue.main.async { editorFocused = true } }
    }
    .overlay(alignment: .bottom) {
      if let notice = session.anchorNotice ?? draft.noticeMessage {
        Text(notice).font(.caption).padding(8).background(.regularMaterial, in: Capsule())
          .padding(.bottom, 58)
      }
    }
  }
  private var sourceEditorFont: Font {
    switch store.sourceFontName {
    case "Monospaced": return .system(size: store.sourceFontSize, design: .monospaced)
    case "System Serif": return .system(size: store.sourceFontSize, design: .serif)
    case "System": return .system(size: store.sourceFontSize)
    default: return .custom(store.sourceFontName, size: store.sourceFontSize)
    }
  }
}

private struct WindowDragHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ view: NSView, context: Context) {}
  private final class DragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  }
}

struct ScriptTextView: NSViewRepresentable {
  let document: PrompterDocument
  let tokenIndex: Int
  let lastConfirmedTokenIndex: Int?
  let isActivelyRunning: Bool
  let seekRevision: Int
  let guideFraction: Double
  let fontName: String
  let fontSize: Double
  let textOpacity: Double
  let fontWeight: String
  let textColorHex: String
  let lineSpacing: Double
  let paragraphSpacing: Double
  let horizontalMargin: Double
  let alignment: String
  let showCues: Bool
  let highlightActiveWord: Bool
  let onSeek: (Int) -> Void
  init(document: PrompterDocument, tokenIndex: Int, lastConfirmedTokenIndex: Int? = nil, isActivelyRunning: Bool = false, seekRevision: Int = 0, guideFraction: Double, fontName: String, fontSize: Double, textOpacity: Double, fontWeight: String = "Regular", textColorHex: String = "#FFFFFF", lineSpacing: Double = 0.16, paragraphSpacing: Double = 0.34, horizontalMargin: Double = 42, alignment: String = "Left", showCues: Bool = true, highlightActiveWord: Bool = false, onSeek: @escaping (Int) -> Void) {
    self.document = document; self.tokenIndex = tokenIndex; self.lastConfirmedTokenIndex = lastConfirmedTokenIndex; self.isActivelyRunning = isActivelyRunning; self.seekRevision = seekRevision; self.guideFraction = guideFraction; self.fontName = fontName; self.fontSize = fontSize; self.textOpacity = textOpacity; self.fontWeight = fontWeight; self.textColorHex = textColorHex; self.lineSpacing = lineSpacing; self.paragraphSpacing = paragraphSpacing; self.horizontalMargin = horizontalMargin; self.alignment = alignment; self.showCues = showCues; self.highlightActiveWord = highlightActiveWord; self.onSeek = onSeek
  }
  func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.stopObservingUserScrolls()
  }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.contentView.postsBoundsChangedNotifications = true
    let text = TrackingTextView()
    text.isEditable = false
    text.isSelectable = true
    text.drawsBackground = false
    text.textContainerInset = NSSize(width: horizontalMargin, height: 80)
    text.textContainer?.widthTracksTextView = true
    text.onCharacterClick = { context.coordinator.seek($0) }
        text.onLayout = { [weak scroll] in
          guard let scroll else { return }
          context.coordinator.invalidateAlignment()
          context.coordinator.align(
            scroll: scroll, tokenIndex: context.coordinator.tokenIndex,
            guideFraction: context.coordinator.guideFraction)
        }
    scroll.documentView = text
    context.coordinator.textView = text
    context.coordinator.observeUserScrolls(in: scroll)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    (scroll.documentView as? NSTextView)?.textContainerInset.width = horizontalMargin
    context.coordinator.onSeek = onSeek
    context.coordinator.tokenIndex = tokenIndex
    context.coordinator.lastConfirmedTokenIndex = lastConfirmedTokenIndex
    context.coordinator.guideFraction = guideFraction
    if context.coordinator.seekRevision != seekRevision {
      context.coordinator.seekRevision = seekRevision
      context.coordinator.invalidateAlignment()
      context.coordinator.snapNextAlignment = true
    }
    context.coordinator.isActivelyRunning = isActivelyRunning
    let signature = "\(document.hashValue)|\(fontName)|\(fontSize)|\(textOpacity)|\(fontWeight)|\(textColorHex)|\(lineSpacing)|\(paragraphSpacing)|\(horizontalMargin)|\(alignment)|\(showCues)|\(highlightActiveWord)"
    if context.coordinator.signature != signature {
      context.coordinator.signature = signature
      context.coordinator.render(
        document: document, fontName: fontName, fontSize: fontSize, textOpacity: textOpacity,
        fontWeight: fontWeight, textColorHex: textColorHex, lineSpacing: lineSpacing,
        paragraphSpacing: paragraphSpacing, horizontalMargin: horizontalMargin,
        alignment: alignment, showCues: showCues, highlightActiveWord: highlightActiveWord)
    }
    context.coordinator.updateGeneration &+= 1
    let generation = context.coordinator.updateGeneration
    DispatchQueue.main.async {
      guard context.coordinator.updateGeneration == generation else { return }
      context.coordinator.updateReadState()
      context.coordinator.align(
        scroll: scroll, tokenIndex: tokenIndex, guideFraction: guideFraction)
    }
  }
  @MainActor final class Coordinator {
    weak var textView: NSTextView?
    var onSeek: (Int) -> Void
    var mappings: [(NSRange, Int)] = []
    var signature = ""
    var tokenIndex = 0
    var lastConfirmedTokenIndex: Int?
    var guideFraction = 0.35
    private var textOpacity = 1.0
    private var highlightActiveWord = false
    private var textColour = NSColor.white
    private var lastAligned: Int?
    private var lastGuideFraction: Double?
    private var lastReadTokenIndex: Int?
    private var lastReadConfirmedTokenIndex: Int?
    var updateGeneration = 0
    var seekRevision = 0
    var isActivelyRunning = false
    var snapNextAlignment = false
    private var scrollObserver: NSObjectProtocol?
    private var isProgrammaticScroll = false
    init(onSeek: @escaping (Int) -> Void) { self.onSeek = onSeek }
    func stopObservingUserScrolls() {
      if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
      scrollObserver = nil
    }
    func observeUserScrolls(in scroll: NSScrollView) {
      stopObservingUserScrolls()
      scrollObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
      ) { [weak self, weak scroll] _ in
        guard let self, let scroll else { return }
        MainActor.assumeIsolated { self.userDidScroll(scroll) }
      }
    }
    func render(document: PrompterDocument, fontName: String, fontSize: Double, textOpacity: Double,
      fontWeight: String = "Regular", textColorHex: String = "#FFFFFF", lineSpacing: Double = 0.16,
      paragraphSpacing: Double = 0.34, horizontalMargin: Double = 42, alignment: String = "Left",
      showCues: Bool = true, highlightActiveWord: Bool = false)
    {
      guard let textView else { return }
      self.textOpacity = textOpacity
      self.highlightActiveWord = highlightActiveWord
      self.textColour = NSColor(hex: textColorHex) ?? .white
      let attributed = NSMutableAttributedString()
      let textColour = NSColor(hex: textColorHex) ?? .white
      var headingRanges: [NSRange] = []
      for (index, block) in document.blocks.enumerated() {
        let rendered: AttributedString
        if block.kind == .listItem {
          var lines = AttributedString()
          for (lineIndex, line) in block.rawMarkdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if lineIndex > 0 { lines.append(AttributedString("\n")) }
            lines.append((try? AttributedString(markdown: String(line), options: .init(interpretedSyntax: .full))) ?? AttributedString(String(line)))
          }
          rendered = lines
        } else {
          rendered = (try? AttributedString(
            markdown: block.rawMarkdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(block.rawMarkdown)
        }
        let part = NSMutableAttributedString(attributedString: NSAttributedString(rendered))
        part.addAttribute(.foregroundColor, value: textColour.withAlphaComponent(textOpacity), range: NSRange(location: 0, length: part.length))
        if block.kind == .heading {
          headingRanges.append(NSRange(location: attributed.length, length: part.length))
        }
        attributed.append(part)
        if index < document.blocks.count - 1 { attributed.append(NSAttributedString(string: "\n\n")) }
      }
      let full = NSRange(location: 0, length: attributed.length)
      // Presenter clicks seek within the script, including linked words.
      attributed.removeAttribute(.link, range: full)
      let base = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
      attributed.enumerateAttribute(.font, in: full) { value, range, _ in
        let existing = value as? NSFont
        let ratio = existing.map { max(0.8, min(1.6, $0.pointSize / 13)) } ?? 1
        let traits = existing.map { NSFontManager.shared.traits(of: $0) }
          ?? NSFontTraitMask()
        let family = existing.flatMap { $0.fontName.lowercased().contains("mono") ? $0.fontName : nil }
        let styledBase = family.flatMap { NSFont(name: $0, size: fontSize * ratio) } ?? base
        let requested = fontWeight == "Bold" ? traits.union(.boldFontMask) : traits
        let styled = NSFontManager.shared.convert(styledBase, toHaveTrait: requested)
        attributed.addAttribute(.font, value: styled, range: range)
      }
      for range in headingRanges {
        guard let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        else { continue }
        let heading = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        attributed.addAttribute(.font, value: NSFontManager.shared.convert(heading, toSize: fontSize * 1.35), range: range)
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = max(3, fontSize * lineSpacing)
      paragraph.paragraphSpacing = max(10, fontSize * paragraphSpacing)
      paragraph.alignment = alignment == "Right" ? .right : alignment == "Center" ? .center : .left
      attributed.addAttribute(.paragraphStyle, value: paragraph, range: full)
      mappings = []
      let plain = attributed.string as NSString
      let cueRanges = cueRanges(in: plain, document: document)
      for range in cueRanges {
        attributed.addAttribute(.foregroundColor, value: showCues ? textColour.withAlphaComponent(textOpacity * 0.42) : .clear, range: range)
      }
      textView.textStorage?.setAttributedString(attributed)
      lastReadTokenIndex = nil
      lastReadConfirmedTokenIndex = nil
      var cursor = 0
      for (index, token) in document.spokenTokens.enumerated() {
        var found = NSRange(location: NSNotFound, length: 0)
        while cursor < plain.length {
          let search = NSRange(location: cursor, length: plain.length - cursor)
          let candidate = plain.range(of: token.text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
          guard candidate.location != NSNotFound else { break }
          if cueRanges.contains(where: { NSIntersectionRange($0, candidate).length > 0 }) {
            cursor = candidate.location + candidate.length
          } else {
            found = candidate
            break
          }
        }
        if found.location != NSNotFound {
          let range = punctuationRange(after: found, in: plain)
          mappings.append((range, index))
          cursor = range.location + range.length
        }
      }
      textView.needsLayout = true
      lastAligned = nil
      lastGuideFraction = nil
    }
    func updateReadState() {
      guard let textView else { return }
      let values = [lastReadTokenIndex, tokenIndex, lastReadConfirmedTokenIndex, lastConfirmedTokenIndex]
        .compactMap { $0 }
      guard let first = values.min(), let last = values.max(),
        lastReadTokenIndex != tokenIndex || lastReadConfirmedTokenIndex != lastConfirmedTokenIndex
      else { return }
      for (range, index) in mappings where first...last ~= index {
        let confirmed = lastConfirmedTokenIndex.map { index <= $0 } ?? false
        let alpha = confirmed ? textOpacity * 0.38 : textOpacity
        let color: NSColor = index == tokenIndex && !confirmed && highlightActiveWord ? .systemYellow.withAlphaComponent(alpha) : textColour.withAlphaComponent(alpha)
        textView.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
      }
      lastReadTokenIndex = tokenIndex
      lastReadConfirmedTokenIndex = lastConfirmedTokenIndex
    }
    func seek(_ character: Int) {
      guard
        let nearest = mappings.min(by: { distance(character, $0.0) < distance(character, $1.0) })
      else { return }
      onSeek(nearest.1)
    }
    func userDidScroll(_ scroll: NSScrollView) {
      guard !isProgrammaticScroll, let textView,
        let manager = textView.layoutManager, let container = textView.textContainer
      else { return }
      manager.ensureLayout(for: container)
      let guide = scroll.contentView.bounds.origin.y
        + max(54, scroll.contentView.bounds.height * guideFraction) - textView.textContainerInset.height
      guard let nearest = mappings.min(by: { left, right in
        let leftGlyph = manager.glyphRange(forCharacterRange: left.0, actualCharacterRange: nil)
        let rightGlyph = manager.glyphRange(forCharacterRange: right.0, actualCharacterRange: nil)
        return abs(manager.boundingRect(forGlyphRange: leftGlyph, in: container).midY - guide)
          < abs(manager.boundingRect(forGlyphRange: rightGlyph, in: container).midY - guide)
      }) else { return }
      tokenIndex = nearest.1
      lastConfirmedTokenIndex = nil
      onSeek(nearest.1)
    }
    func invalidateAlignment() { lastAligned = nil; lastGuideFraction = nil }
    func align(scroll: NSScrollView, tokenIndex: Int, guideFraction: Double) {
      guard (lastAligned != tokenIndex || lastGuideFraction != guideFraction), let textView,
        let mapping = mappings.first(where: { $0.1 == tokenIndex }),
        let manager = textView.layoutManager, let container = textView.textContainer
      else { return }
      let height = scroll.contentView.bounds.height
      let guideY = max(54, height * guideFraction)
      let edgeInset = max(80, max(guideY, height - guideY))
      textView.textContainerInset = NSSize(width: textView.textContainerInset.width, height: edgeInset)
      manager.ensureLayout(for: container)
      let glyph = manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
      let target = max(
        0,
        rect.midY + textView.textContainerInset.height - guideY)
      let animate = lastAligned != nil && isActivelyRunning && !snapNextAlignment
        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      let destination = NSPoint(x: scroll.contentView.bounds.origin.x, y: target)
      isProgrammaticScroll = true
      if animate {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.16
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          scroll.contentView.animator().setBoundsOrigin(destination)
        } completionHandler: { [weak self] in
          Task { @MainActor in self?.isProgrammaticScroll = false }
        }
      } else {
        scroll.contentView.layer?.removeAllAnimations()
        scroll.contentView.setBoundsOrigin(destination)
        isProgrammaticScroll = false
      }
      scroll.reflectScrolledClipView(scroll.contentView)
      lastAligned = tokenIndex
      lastGuideFraction = guideFraction
      snapNextAlignment = false
    }
    private func cueRanges(in plain: NSString, document: PrompterDocument) -> [NSRange] {
      var result: [NSRange] = []
      var cursor = 0
      for cue in document.blocks.flatMap(\.stageDirections) {
        guard cursor <= plain.length else { break }
        let search = NSRange(location: cursor, length: plain.length - cursor)
        let bracketed = "[\(cue.text)]"
        let match = plain.range(of: bracketed, options: [.caseInsensitive, .diacriticInsensitive], range: search)
        let range = match.location == NSNotFound
          ? plain.range(of: cue.text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
          : match
        if range.location != NSNotFound { result.append(range); cursor = range.location + range.length }
      }
      return result
    }
    private func punctuationRange(after range: NSRange, in text: NSString) -> NSRange {
      var end = range.upperBound
      while end < text.length,
        let scalar = UnicodeScalar(text.character(at: end)),
        CharacterSet.punctuationCharacters.contains(scalar)
      { end += 1 }
      return NSRange(location: range.location, length: end - range.location)
    }
    private func distance(_ point: Int, _ range: NSRange) -> Int {
      point < range.location
        ? range.location - point
        : point > range.location + range.length ? point - (range.location + range.length) : 0
    }
  }
}
private final class TrackingTextView: NSTextView {
  var onCharacterClick: ((Int) -> Void)?
  var onLayout: (() -> Void)?
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let manager = layoutManager, let container = textContainer {
      let adjusted = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
      let glyph = manager.glyphIndex(for: adjusted, in: container)
      guard glyph < manager.numberOfGlyphs else { super.mouseDown(with: event); return }
      let character = manager.characterIndexForGlyph(at: glyph)
      if character != NSNotFound {
        setSelectedRange(NSRange(location: 0, length: 0))
        onCharacterClick?(character)
        return
      }
    }
    super.mouseDown(with: event)
  }
  override func setFrameSize(_ newSize: NSSize) {
    let sizeChanged = abs(newSize.width - frame.width) > 0.5 || abs(newSize.height - frame.height) > 0.5
    super.setFrameSize(newSize)
    if sizeChanged { onLayout?() }
  }
}

private extension NSColor {
  convenience init?(hex: String) {
    var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
    self.init(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
  }
}
