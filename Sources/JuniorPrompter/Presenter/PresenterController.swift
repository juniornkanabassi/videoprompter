import AppKit
import PrompterCore
import SwiftUI

@MainActor final class PresenterController: NSObject, NSWindowDelegate {
  static let shared = PresenterController()
  private var panel: NSPanel?
  private var screenObserver: NSObjectProtocol?
  private weak var activeSession: SessionStore?
  func windowWillClose(_ notification: Notification) { activeSession?.pause() }
  func present(store: AppStore) {
    guard let script = store.selected else { return }
    store.session.present(record: script, settings: store.settings)
    activeSession = store.session
    let panel = self.panel ?? makePanel()
    panel.title = "JuniorPrompter · \(script.metadata.title)"
    panel.contentView = NSHostingView(rootView: PresenterView(store: store, session: store.session))
    self.panel = panel
    if CommandLine.arguments.contains("--agent-screen"),
      let screen = NSScreen.screens.first(where: { $0.localizedName == "Agent Screen" })
    {
      let area = screen.visibleFrame
      let size = NSSize(width: min(760, area.width), height: min(520, area.height))
      panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                            width: size.width, height: size.height), display: true)
    }
    recoverVisibleFrame(panel)
    if CommandLine.arguments.contains("--agent-screen") {
      panel.orderFrontRegardless()
      panel.makeKey()
    } else {
      panel.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
  func close() {
    activeSession?.pause()
    panel?.orderOut(nil)
  }
  private func makePanel() -> NSPanel {
    let value = NSPanel(
      contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    value.delegate = self
    value.level = .floating
    value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    value.sharingType = CommandLine.arguments.contains("--capture-visible") ? .readOnly : .none
    value.hidesOnDeactivate = false
    value.isReleasedWhenClosed = false
    value.isOpaque = false
    value.backgroundColor = .clear
    value.minSize = NSSize(width: 360, height: 220)
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { if let panel = self?.panel { self?.recoverVisibleFrame(panel) } }
    }
    return value
  }
  private func recoverVisibleFrame(_ panel: NSPanel) {
    guard !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }),
      let target = NSScreen.main ?? NSScreen.screens.first
    else { return }
    var frame = panel.frame
    frame.size.width = min(frame.width, target.visibleFrame.width)
    frame.size.height = min(frame.height, target.visibleFrame.height)
    frame.origin = NSPoint(
      x: target.visibleFrame.midX - frame.width / 2, y: target.visibleFrame.midY - frame.height / 2)
    panel.setFrame(frame, display: true)
  }
}

private struct PresenterView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var session: SessionStore
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .top) {
        Color(nsColor: NSColor(hex: store.settings.backgroundColorHex) ?? .black).opacity(store.settings.backgroundOpacity)
        ScriptTextView(
          document: session.document, tokenIndex: session.tokenIndex,
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
        ).rotationEffect(.degrees(Double(store.settings.rotation))).padding(.top, 52)
        Rectangle().fill(.cyan.opacity(0.82)).frame(height: 2).offset(
          y: max(54, geometry.size.height * store.settings.guideFraction)
        ).allowsHitTesting(false)
        HStack(spacing: 10) {
          Button(action: session.previousPassage) { Image(systemName: "backward.end.fill") }
            .accessibilityLabel("Previous passage")
          Button(action: session.toggle) {
            Image(systemName: session.isActivelyRunning ? "pause.fill" : "play.fill")
          }.buttonStyle(.borderedProminent).accessibilityLabel(session.isActivelyRunning ? "Pause" : "Play")
          Button(action: session.nextPassage) { Image(systemName: "forward.end.fill") }
            .accessibilityLabel("Next passage")
          Button(action: session.restart) { Image(systemName: "arrow.counterclockwise") }
            .accessibilityLabel("Restart")
          Spacer()
          Text(statusText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          Button {
            PresenterController.shared.close()
          } label: {
            Image(systemName: "xmark")
          }.accessibilityLabel("Close presenter")
        }
        .buttonStyle(.bordered).padding(10).background(.ultraThinMaterial)
      }
    }.background(Color.clear).onChange(of: store.settings) { _, value in
      session.updateSettings(value)
    }
    .overlay(alignment: .bottom) {
      if let notice = session.anchorNotice {
        Text(notice).font(.caption).padding(8).background(.regularMaterial, in: Capsule()).padding()
      }
    }
  }
  private var statusText: String {
    switch session.state {
    case .running:
      return
        "\(store.settings.mode) · \(session.tokenIndex+1)/\(max(1,session.document.spokenTokens.count))"
    case .uncertain(let text): return text
    case .paused: return "Paused"
    case .stopped: return "Stopped"
    }
  }
}

struct ScriptTextView: NSViewRepresentable {
  let document: PrompterDocument
  let tokenIndex: Int
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
  init(document: PrompterDocument, tokenIndex: Int, guideFraction: Double, fontName: String, fontSize: Double, textOpacity: Double, fontWeight: String = "Regular", textColorHex: String = "#FFFFFF", lineSpacing: Double = 0.16, paragraphSpacing: Double = 0.34, horizontalMargin: Double = 42, alignment: String = "Left", showCues: Bool = true, highlightActiveWord: Bool = false, onSeek: @escaping (Int) -> Void) {
    self.document = document; self.tokenIndex = tokenIndex; self.guideFraction = guideFraction; self.fontName = fontName; self.fontSize = fontSize; self.textOpacity = textOpacity; self.fontWeight = fontWeight; self.textColorHex = textColorHex; self.lineSpacing = lineSpacing; self.paragraphSpacing = paragraphSpacing; self.horizontalMargin = horizontalMargin; self.alignment = alignment; self.showCues = showCues; self.highlightActiveWord = highlightActiveWord; self.onSeek = onSeek
  }
  func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
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
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    (scroll.documentView as? NSTextView)?.textContainerInset.width = horizontalMargin
    context.coordinator.onSeek = onSeek
    context.coordinator.tokenIndex = tokenIndex
    context.coordinator.guideFraction = guideFraction
    let signature = "\(document.hashValue)|\(fontName)|\(fontSize)|\(textOpacity)|\(fontWeight)|\(textColorHex)|\(lineSpacing)|\(paragraphSpacing)|\(horizontalMargin)|\(alignment)|\(showCues)|\(highlightActiveWord)"
    if context.coordinator.signature != signature {
      context.coordinator.signature = signature
      context.coordinator.render(
        document: document, fontName: fontName, fontSize: fontSize, textOpacity: textOpacity,
        fontWeight: fontWeight, textColorHex: textColorHex, lineSpacing: lineSpacing,
        paragraphSpacing: paragraphSpacing, horizontalMargin: horizontalMargin,
        alignment: alignment, showCues: showCues, highlightActiveWord: highlightActiveWord)
    }
    DispatchQueue.main.async {
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
    var guideFraction = 0.35
    private var textOpacity = 1.0
    private var highlightActiveWord = false
    private var textColour = NSColor.white
    private var lastAligned: Int?
    private var lastGuideFraction: Double?
    init(onSeek: @escaping (Int) -> Void) { self.onSeek = onSeek }
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
        let rendered =
          (try? AttributedString(
            markdown: block.rawMarkdown, options: .init(interpretedSyntax: .full)))
          ?? AttributedString(block.rawMarkdown)
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
          mappings.append((found, index))
          cursor = found.location + found.length
        }
      }
      textView.needsLayout = true
      lastAligned = nil
      lastGuideFraction = nil
    }
    func updateReadState() {
      guard let textView else { return }
      for (range, index) in mappings {
        let alpha = index < tokenIndex ? textOpacity * 0.38 : textOpacity
        let color: NSColor = index == tokenIndex && highlightActiveWord ? .systemYellow.withAlphaComponent(alpha) : textColour.withAlphaComponent(alpha)
        textView.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
      }
    }
    func seek(_ character: Int) {
      guard
        let nearest = mappings.min(by: { distance(character, $0.0) < distance(character, $1.0) })
      else { return }
      onSeek(nearest.1)
    }
    func invalidateAlignment() { lastAligned = nil; lastGuideFraction = nil }
    func align(scroll: NSScrollView, tokenIndex: Int, guideFraction: Double) {
      guard (lastAligned != tokenIndex || lastGuideFraction != guideFraction), let textView,
        let mapping = mappings.first(where: { $0.1 == tokenIndex }),
        let manager = textView.layoutManager, let container = textView.textContainer
      else { return }
      let height = scroll.contentView.bounds.height
      let guideY = max(54, (height + 52) * guideFraction) - 52
      let edgeInset = max(80, max(guideY, height - guideY))
      textView.textContainerInset = NSSize(width: textView.textContainerInset.width, height: edgeInset)
      manager.ensureLayout(for: container)
      let glyph = manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
      let target = max(
        0,
        rect.midY + textView.textContainerInset.height - guideY)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
      scroll.reflectScrolledClipView(scroll.contentView)
      lastAligned = tokenIndex
      lastGuideFraction = guideFraction
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
