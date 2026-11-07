import AppKit
import PrompterCore
import SwiftUI

struct ScriptTextView: View {
  typealias Context = ScriptTextCanvas.Context
  let document: PrompterDocument
  let tokenIndex: Int
  var lastConfirmedTokenIndex: Int?
  var isActivelyRunning = false
  var seekRevision = 0
  let guideFraction: Double
  var verticalMirror = false
  let fontName: String
  let fontSize: Double
  let textOpacity: Double
  var fontWeight = "Regular"
  var textColorHex = "#FFFFFF"
  var lineSpacing = 0.16
  var paragraphSpacing = 0.34
  var horizontalMargin = 42.0
  var alignment = "Left"
  var overVideo = false
  var showCues = true
  var highlightActiveWord = false
  /// The session's fractional token position, painted on a display link while running: Manual's
  /// timeline, or Voice's glide after the recogniser. Nil keeps the eased, word-at-a-time alignment.
  var manualPosition: (() -> Double)?
  let onSeek: (Int) -> Void
  /// A scroll the reader made by hand; falls back to `onSeek`.
  var onUserScroll: ((Int) -> Void)?
  /// The column is `textWidth` of the presenter's width, centred, and never nearer an edge
  /// than the old fixed 42 pt margin. Only the text uses it; the camera stays full size.
  static func sideInset(width: CGFloat, textWidth: Double) -> CGFloat {
    max(42, width * (1 - CGFloat(textWidth)) / 2)
  }
  static func visualGuideY(height: CGFloat, fraction: Double) -> CGFloat {
    min(height, max(54, height * fraction))
  }
  var body: some View {
    ScriptTextCanvas(configuration: self)
      .mask { ReadingViewportMask(flipped: verticalMirror) }
  }
  func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.stopObservingUserScrolls()
    coordinator.stopManualScrolling()
  }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let text = TrackingTextView()
    text.setAccessibilityLabel("Presenter script")
    text.setAccessibilityHelp("Select a word with the keyboard, then press Option-Command-Return to read from it.")
    text.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Read from Selection", target: text, selector: #selector(TrackingTextView.accessibilityReadFromSelection))])
    text.isEditable = false
    text.isSelectable = true
    text.drawsBackground = false
    text.textContainerInset = NSSize(width: horizontalMargin, height: 80)
    text.textContainer?.widthTracksTextView = true
    text.onCharacterClick = { context.coordinator.seek($0) }
    text.onLayout = { [weak scroll] in
      guard let scroll else { return }
      context.coordinator.dropScrollGeometry()
      // During a full layout the caller aligns once it returns; see `layOutScript`.
      guard !context.coordinator.isLayingOutScript else { return }
      context.coordinator.invalidateAlignment()
      context.coordinator.alignToCurrent(in: scroll)
    }
    scroll.documentView = text
    context.coordinator.textView = text
    context.coordinator.verticalMirror = verticalMirror
    context.coordinator.observeUserScrolls(in: scroll)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.setSideInset(horizontalMargin)
    coordinator.onSeek = onSeek
    coordinator.onUserScroll = onUserScroll
    coordinator.setManualSource(manualPosition)
    coordinator.tokenIndex = tokenIndex
    coordinator.lastConfirmedTokenIndex = lastConfirmedTokenIndex
    coordinator.guideFraction = guideFraction
    let seeked = coordinator.noteSeekRevision(seekRevision)
    if coordinator.verticalMirror != verticalMirror || seeked {
      coordinator.verticalMirror = verticalMirror
      coordinator.snapToGuide()
    }
    coordinator.isActivelyRunning = isActivelyRunning
    coordinator.releaseHandScroll()
    coordinator.updateDisplayLink(for: scroll)
    let style = "\(fontName)|\(fontSize)|\(textOpacity)|\(fontWeight)|\(textColorHex)|\(lineSpacing)|\(paragraphSpacing)|\(alignment)|\(showCues)|\(highlightActiveWord)|\(overVideo)"
    if coordinator.needsRender(document: document, style: style) {
      coordinator.render(
        document: document, fontName: fontName, fontSize: fontSize, textOpacity: textOpacity,
        fontWeight: fontWeight, textColorHex: textColorHex, lineSpacing: lineSpacing,
        paragraphSpacing: paragraphSpacing,
        alignment: alignment, showCues: showCues, highlightActiveWord: highlightActiveWord, overVideo: overVideo)
    }
    coordinator.updateGeneration &+= 1
    let generation = coordinator.updateGeneration
    DispatchQueue.main.async {
      guard coordinator.updateGeneration == generation else { return }
      coordinator.updateReadState()
      if coordinator.manualPosition != nil {
        coordinator.alignManual(in: scroll)
      } else {
        coordinator.align(scroll: scroll, tokenIndex: tokenIndex, guideFraction: guideFraction)
      }
    }
  }
  @MainActor final class Coordinator: NSObject {
    weak var textView: NSTextView?
    var onSeek: (Int) -> Void
    var mappings: [(NSRange, Int)] = []
    /// The system's Reduce Motion; tests that only check where the text lands set it to skip the easing.
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// How long an eased move takes. Ease-out, so the line starts moving at full speed the moment
    /// the reader reaches it, and a new target picks up from wherever the last move had got to:
    /// the 0.60 s ease-in-out this replaced started every line from rest and put the line on the
    /// guide over a second after the reader got there at a fast pace.
    static let easedMoveSeconds = 0.20
    /// Moves the script: eased, or at once, which also stops an easing in flight. Tests swap it to
    /// see what was asked for, since an eased scroll does not advance while the screen is locked.
    static var moveClip: (NSClipView, NSPoint, _ eased: Bool) -> Void = { clip, destination, eased in
      if eased {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = easedMoveSeconds
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          clip.animator().setBoundsOrigin(destination)
        }
      } else {
        // A zero-length animator move is what replaces an animator move in flight; the layer's
        // own animations go too, and the plain assignment leaves the origin exact.
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0
          clip.animator().setBoundsOrigin(destination)
        }
        clip.layer?.removeAllAnimations()
        clip.setBoundsOrigin(destination)
      }
    }
    private var renderedDocument: PrompterDocument?
    private var renderedStyle = ""
    var tokenIndex = 0
    var lastConfirmedTokenIndex: Int?
    var guideFraction = 0.35
    var verticalMirror = false
    private var textOpacity = 1.0
    private var highlightActiveWord = false
    private var textColour = NSColor.white
    private var lastAligned: Int?
    private var lastGuideFraction: Double?
    private var lastAlignmentDestination: NSPoint?
    private var lastReadTokenIndex: Int?
    private var lastReadConfirmedTokenIndex: Int?
    var updateGeneration = 0
    private(set) var seekRevision = 0
    var isActivelyRunning = false {
      // Play resumes Manual alignment after a hand scroll.
      didSet { if isActivelyRunning, !oldValue { isHandScrolled = false; pendingUserSeeks = 0 } }
    }
    /// Set by the first live-scroll event and held until the gesture's seek arrives (Voice) or Play
    /// (Manual), so `updateNSView`, `onLayout` and the display link cannot pull the reader's scroll
    /// back to the timeline.
    private(set) var isHandScrolled = false
    /// Voice let go of: the next paints ease from where the hand left the text instead of jumping.
    private var settle: (from: CGFloat, start: CFTimeInterval)?
    static let settleSeconds = 0.2
    /// Seek revisions the hand scroll itself caused, which must not lift the suppression.
    private var pendingUserSeeks = 0
    var snapNextAlignment = false
    private var scrollObservers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    /// Every mapping's rendered midY, measured on the gesture's first scroll event. Only geometry
    /// clears it (a new gesture, a render, a resize): each hand-scroll seek re-aligns, and clearing
    /// it there too would measure the whole script again on every event.
    private(set) var liveScrollMidYs: [CGFloat]?
    var onUserScroll: ((Int) -> Void)?
    /// Manual's timeline or Voice's glide. The display link paints it while `isActivelyRunning`.
    private(set) var manualPosition: (() -> Double)?
    private var displayLink: CADisplayLink?
    private weak var manualScroll: NSScrollView?
    var isDisplayLinkActive: Bool { displayLink != nil }
    init(onSeek: @escaping (Int) -> Void) {
      self.onSeek = onSeek
      super.init()
    }
    func setManualSource(_ source: (() -> Double)?) {
      // Crossing between Manual and Voice hands the scroll position over: re-align from scratch.
      if (source == nil) != (manualPosition == nil) {
        isHandScrolled = false
        invalidateAlignment()
        endsVoiceAnimation = source != nil
      }
      manualPosition = source
    }
    private var endsVoiceAnimation = false
    /// The display link exists only while Manual is running and this view is alive: paused, stopped,
    /// completed and dismantled all remove it, so an idle presenter does no per-frame work.
    func updateDisplayLink(for scroll: NSScrollView) {
      guard isActivelyRunning, manualPosition != nil else { return stopManualScrolling() }
      guard displayLink == nil else { return }
      let link = scroll.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
      link.add(to: .main, forMode: .common)
      displayLink = link
      manualScroll = scroll
    }
    func stopManualScrolling() {
      displayLink?.invalidate()
      displayLink = nil
    }
    @objc private func displayLinkFired(_ link: CADisplayLink) {
      guard isActivelyRunning, manualPosition != nil, let scroll = manualScroll else {
        return stopManualScrolling()
      }
      // A hand on the scroll wheel wins; its first event pauses the session and this link with it.
      guard !isLiveScrolling else { return }
      alignManual(in: scroll)
    }
    func stopObservingUserScrolls() {
      scrollObservers.forEach(NotificationCenter.default.removeObserver)
      scrollObservers.removeAll()
    }
    func observeUserScrolls(in scroll: NSScrollView) {
      stopObservingUserScrolls()
      let center = NotificationCenter.default
      scroll.contentView.postsFrameChangedNotifications = true
      scrollObservers = [
        center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
          MainActor.assumeIsolated {
            guard let self, let scroll else { return }
            self.dropScrollGeometry()
            self.snapToGuide()
            self.alignToCurrent(in: scroll)
          }
        },
        center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.isLiveScrolling = true
            self?.dropScrollGeometry()
            if self?.manualPosition != nil { self?.isHandScrolled = true }
          }
        },
        center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
          guard let self, let scroll else { return }
          MainActor.assumeIsolated { self.userDidScroll(scroll) }
        },
        center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.isLiveScrolling = false
            self.releaseHandScroll()
            // The hand let go (momentum included): glide the word it chose onto the guide, once.
            if self.manualPosition == nil, let scroll {
              self.invalidateAlignment()
              self.align(scroll: scroll, tokenIndex: self.tokenIndex, guideFraction: self.guideFraction,
                         eases: !Self.reducesMotion())
            }
          }
        },
      ]
    }
    /// Voice keeps running through a hand scroll, so no Play comes to lift the hold once the gesture
    /// and the seeks it caused are done (Manual is paused by then, and stays held).
    func releaseHandScroll() {
      guard isHandScrolled, isActivelyRunning, !isLiveScrolling, pendingUserSeeks == 0 else { return }
      isHandScrolled = false
      if let y = textView?.enclosingScrollView?.contentView.bounds.origin.y { settle = (y, CACurrentMediaTime()) }
    }
    /// Takes the session's seek revision and returns whether it changed. A seek the hand scroll
    /// caused keeps Manual suppressed; any other (a click, Next passage, Restart) is explicit, so
    /// alignment follows it again.
    func noteSeekRevision(_ revision: Int) -> Bool {
      let bumps = revision &- seekRevision
      guard bumps != 0 else { return false }
      seekRevision = revision
      let fromHand = min(max(bumps, 0), pendingUserSeeks)
      pendingUserSeeks -= fromHand
      // An explicit seek (a click, Next passage, Restart) lands at once, not eased from a hand.
      if bumps > fromHand { isHandScrolled = false; settle = nil }
      return true
    }
    /// Whether this document or style differs from what is drawn. It runs on every SwiftUI update,
    /// i.e. every word, so it compares instead of hashing the script: an unchanged document shares
    /// its storage with the drawn one, and that comparison returns at once.
    func needsRender(document: PrompterDocument, style: String) -> Bool {
      guard renderedDocument != document || renderedStyle != style else { return false }
      renderedDocument = document
      renderedStyle = style
      return true
    }
    func render(document: PrompterDocument, fontName: String, fontSize: Double, textOpacity: Double,
      fontWeight: String = "Regular", textColorHex: String = "#FFFFFF", lineSpacing: Double = 0.16,
      paragraphSpacing: Double = 0.34, alignment: String = "Left",
      showCues: Bool = true, highlightActiveWord: Bool = false, overVideo: Bool = false)
    {
      guard let textView else { return }
      self.textOpacity = textOpacity
      self.highlightActiveWord = highlightActiveWord
      textColour = NSColor(hex: textColorHex) ?? .white
      // The editor's own layout, so the same Markdown has the same characters, paragraph styles and
      // height in both. Only presenter state (weight, cues, read colours) is applied after it.
      // Callouts are production notes, so the presenter leaves them out; offsets still map to the file.
      let model = FormattedMarkdownEditModel(markdown: document.markdown, omittingCallouts: true)
      let attributed = NSMutableAttributedString(attributedString: model.rendered(
        fontName: fontName, fontSize: fontSize,
        typography: EditorTypography(
          textColor: textColour.withAlphaComponent(textOpacity),
          lineSpacing: max(3, fontSize * lineSpacing), paragraphSpacing: max(10, fontSize * paragraphSpacing),
          alignment: NSTextAlignment(setting: alignment))))
      let full = NSRange(location: 0, length: attributed.length)
      if overVideo {
        let halo = NSShadow()
        halo.shadowColor = NSColor.black.withAlphaComponent(0.6)
        halo.shadowBlurRadius = 6
        halo.shadowOffset = .zero
        attributed.addAttribute(.shadow, value: halo, range: full)
      }
      // Presenter clicks seek within the script, including linked words.
      attributed.removeAttribute(.link, range: full)
      if fontWeight == "Bold" {
        attributed.enumerateAttribute(.font, in: full) { value, range, _ in
          guard let font = value as? NSFont else { return }
          attributed.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
        }
      }
      var visible = model.visibleIndices()
      var blockRanges: [UUID: NSRange] = [:]
      for block in document.blocks {
        let source = block.sourceRange
        let indices = (source.location..<(source.location + source.length)).compactMap { visible[$0] }
        if let low = indices.min(), let high = indices.max() {
          blockRanges[block.id] = NSRange(location: low, length: high - low + 1)
        }
      }
      mappings = []
      dropScrollGeometry()
      var plain = attributed.string as NSString
      var cueRanges = cueRanges(in: plain, document: document, blocks: blockRanges, visible: visible)
      for range in cueRanges {
        attributed.addAttribute(.foregroundColor, value: showCues ? textColour.withAlphaComponent(textOpacity * 0.42) : .clear, range: range)
      }
      if !showCues {
        // Remove hidden cues from the actual selectable/accessible string, then remap source
        // offsets. Transparent glyphs still leak stage directions to assistive technology.
        let removed = cueRanges.map { range -> NSRange in
          var range = range
          if NSMaxRange(range) < plain.length,
            let scalar = UnicodeScalar(plain.character(at: NSMaxRange(range))),
            CharacterSet.whitespaces.contains(scalar) { range.length += 1 }
          return range
        }
        visible = visible.compactMapValues { offset in
          if removed.contains(where: { NSLocationInRange(offset, $0) }) { return nil }
          return offset - removed.filter { NSMaxRange($0) <= offset }.reduce(0) { $0 + $1.length }
        }
        for range in removed.sorted(by: { $0.location > $1.location }) { attributed.deleteCharacters(in: range) }
        plain = attributed.string as NSString
        blockRanges.removeAll()
        for block in document.blocks {
          let indices = (block.sourceRange.location..<(block.sourceRange.location + block.sourceRange.length)).compactMap { visible[$0] }
          if let low = indices.min(), let high = indices.max() {
            blockRanges[block.id] = NSRange(location: low, length: high - low + 1)
          }
        }
        cueRanges = []
      }
      var cursor = 0
      for (index, token) in document.spokenTokens.enumerated() {
        // A word maps straight from its source offset. Failing that it is looked for only inside its
        // own passage: a spoken word the rendering does not show (a code fence's language tag)
        // otherwise matched the same text paragraphs later, and every word after it mapped there
        // or nowhere: the presenter jumped ahead.
        guard let block = blockRanges[token.blockID] else { continue }
        var found = Self.visibleRange(token.sourceRange, in: visible, matching: token.text, in: plain)
          ?? NSRange(location: NSNotFound, length: 0)
        cursor = max(cursor, block.location)
        while found.location == NSNotFound, cursor < NSMaxRange(block) {
          let search = NSRange(location: cursor, length: NSMaxRange(block) - cursor)
          let candidate = plain.range(of: token.text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
          guard candidate.location != NSNotFound else { break }
          if cueRanges.contains(where: { NSIntersectionRange($0, candidate).length > 0 }) {
            cursor = candidate.location + candidate.length
          } else {
            found = candidate
          }
        }
        if found.location != NSNotFound {
          let range = punctuationRange(after: found, in: plain)
          mappings.append((range, index))
          cursor = range.location + range.length
        }
      }
      // Words already read stay dimmed through a re-render (a style change, an edit, a reopened
      // presenter or the end of an in-place edit): their colour goes in before the text is shown.
      let progress = max(tokenIndex, lastConfirmedTokenIndex ?? 0)
      for (range, index) in mappings where index <= progress {
        attributed.addAttribute(.foregroundColor, value: readColour(index), range: range)
      }
      textView.textStorage?.setAttributedString(attributed)
      lastReadTokenIndex = tokenIndex
      lastReadConfirmedTokenIndex = lastConfirmedTokenIndex
      textView.needsLayout = true
      invalidateAlignment()
    }
    func updateReadState() {
      guard let textView else { return }
      let values = [lastReadTokenIndex, tokenIndex, lastReadConfirmedTokenIndex, lastConfirmedTokenIndex]
        .compactMap { $0 }
      guard let lower = values.min(), let last = values.max(),
        lastReadTokenIndex != tokenIndex || lastReadConfirmedTokenIndex != lastConfirmedTokenIndex
      else { return }
      // Adding or clearing confirmation changes every preceding word's colour. Ordinary
      // unconfirmed progress still needs only the span between the old and new active words.
      let first = (lastReadConfirmedTokenIndex == nil) != (lastConfirmedTokenIndex == nil)
        ? min(0, lower) : lower
      // One edit transaction, so the text storage invalidates and redraws the changed span once
      // instead of once per word; a progress event can cover a dozen words.
      textView.textStorage?.beginEditing()
      var slot = mappingLowerBound(first)
      while slot < mappings.count, mappings[slot].1 <= last {
        let (range, index) = mappings[slot]
        textView.textStorage?.addAttribute(.foregroundColor, value: readColour(index), range: range)
        slot += 1
      }
      textView.textStorage?.endEditing()
      lastReadTokenIndex = tokenIndex
      lastReadConfirmedTokenIndex = lastConfirmedTokenIndex
    }
    /// Read words dim; the current word is highlighted when that is on.
    private func readColour(_ index: Int) -> NSColor {
      let confirmed = lastConfirmedTokenIndex.map { index <= $0 } ?? false
      let alpha = confirmed ? textOpacity * 0.5 : textOpacity
      return index == tokenIndex && !confirmed && highlightActiveWord
        ? .systemYellow.withAlphaComponent(alpha) : textColour.withAlphaComponent(alpha)
    }
    func seek(_ character: Int) {
      guard let nearest = mappings.min(by: { distance(character, $0.0) < distance(character, $1.0) }) else { return }
      onSeek(nearest.1)
    }
    func userDidScroll(_ scroll: NSScrollView) {
      guard isLiveScrolling, let textView,
        let manager = textView.layoutManager, let container = textView.textContainer
      else { return }
      layOutScript(manager, container)
      let guide = scroll.contentView.bounds.origin.y
        + layoutGuideY(height: scroll.contentView.bounds.height, fraction: guideFraction) - textView.textContainerInset.height
      // Each word is measured once per gesture, not twice per trackpad event (60 to 120 a second,
      // and a long script lagged behind the fingers). Layout holds still while the hand scrolls;
      // a render, resize or reflow drops these.
      let midYs = liveScrollMidYs ?? mappings.map { range in
        let glyph = manager.glyphRange(forCharacterRange: range.0, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyph, in: container).midY
      }
      liveScrollMidYs = midYs
      guard let slot = Self.nearestSlot(midYs, to: guide) else { return }
      let nearest = mappings[slot]
      tokenIndex = nearest.1
      lastConfirmedTokenIndex = nil
      if manualPosition != nil { pendingUserSeeks += 1 }
      (onUserScroll ?? onSeek)(nearest.1)
    }
    /// The first slot nearest `guide`. A scan, not a search: mappings are in token order, which is
    /// not always page order (a code fence's language tag can map to a later line of its body).
    static func nearestSlot(_ midYs: [CGFloat], to guide: CGFloat) -> Int? {
      midYs.indices.min { abs(midYs[$0] - guide) < abs(midYs[$1] - guide) }
    }
    private func layoutGuideY(height: CGFloat, fraction: Double) -> CGFloat {
      let visual = ScriptTextView.visualGuideY(height: height, fraction: fraction)
      return verticalMirror ? height - visual : visual
    }
    /// Assigning textContainerInset dirties the layout of the whole script, so only when the
    /// width really moved; the reflowed anchor then snaps back onto the guide line.
    func setSideInset(_ inset: CGFloat) {
      guard let textView, abs(textView.textContainerInset.width - inset) > 0.5 else { return }
      textView.textContainerInset.width = inset
      dropScrollGeometry()
      snapToGuide()
    }
    func invalidateAlignment() {
      lastPaint = nil
      lastAligned = nil
      lastGuideFraction = nil
      lastAlignmentDestination = nil
    }
    func dropScrollGeometry() { liveScrollMidYs = nil; lastPaint = nil }
    /// The last Manual or Voice paint. The same position, guide and height with the scroll still
    /// where it was put needs no layout or measuring: Voice paints every frame, silence included.
    private var lastPaint: (position: Double, guide: Double, height: CGFloat, y: CGFloat)?
    /// Re-align on the next update without easing.
    func snapToGuide() {
      invalidateAlignment()
      snapNextAlignment = true
    }
    /// The layout ready to measure, with the top and bottom inset that let any word reach the guide.
    private func prepareGuide(_ scroll: NSScrollView, fraction: Double)
      -> (manager: NSLayoutManager, container: NSTextContainer, guideY: CGFloat)?
    {
      guard let textView, let manager = textView.layoutManager, let container = textView.textContainer
      else { return nil }
      let height = scroll.contentView.bounds.height
      let guideY = layoutGuideY(height: height, fraction: fraction)
      let edgeInset = max(80, max(guideY, height - guideY))
      // Same reason: re-laying the whole script out on every advance is the presenter's most
      // expensive recurring work, and the edge inset only changes when the window resizes.
      if abs(textView.textContainerInset.height - edgeInset) > 0.5 {
        textView.textContainerInset = NSSize(width: textView.textContainerInset.width, height: edgeInset)
      }
      layOutScript(manager, container)
      return (manager, container, guideY)
    }
    /// True while `layOutScript` runs. Each paragraph laid out grows the text view, and its
    /// `onLayout` used to align (and so lay out again) inside this very call: one open of a
    /// 4,800-word script ran 134 nested align passes, nested up to 15 deep, about 400 ms.
    private(set) var isLayingOutScript = false
    /// The whole script laid out, with the size changes it causes left to the caller, which
    /// measures and aligns once afterwards.
    private func layOutScript(_ manager: NSLayoutManager, _ container: NSTextContainer) {
      guard !isLayingOutScript else { return }
      isLayingOutScript = true
      defer { isLayingOutScript = false }
      manager.ensureLayout(for: container)
    }
    /// Where the scroll must sit to put this rendered range on the guide.
    private func scrollY(
      of range: NSRange, manager: NSLayoutManager, container: NSTextContainer, guideY: CGFloat
    ) -> CGFloat {
      let glyph = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
      return max(0, rect.midY + (textView?.textContainerInset.height ?? 0) - guideY)
    }
    /// The scroll for a fractional token position, interpolated between the token mappings so motion
    /// is continuous. Words on one line share a scroll position, so interpolating only between
    /// neighbouring words would hold still for a line and then jump one line in one word's time:
    /// instead the scroll runs from a line's first word to the next line's first word across the
    /// words in between. Each line's first word lands exactly on the guide; words with no rendered
    /// range are skipped.
    func manualScrollY(at position: Double, in scroll: NSScrollView) -> CGFloat? {
      guard !mappings.isEmpty, let (manager, container, guideY) = prepareGuide(scroll, fraction: guideFraction),
        let inset = textView?.textContainerInset.height
      else { return nil }
      // Unclamped, so the lines above the first scrollable one still count as different lines.
      func y(_ index: Int) -> CGFloat {
        let glyph = manager.glyphRange(forCharacterRange: mappings[index].0, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyph, in: container).midY + inset - guideY
      }
      let current = mappingIndex(at: position)
      let here = y(current)
      var first = current
      while first > 0, abs(y(first - 1) - here) < 2 { first -= 1 }
      var next = current + 1
      while next < mappings.count, abs(y(next) - here) < 2 { next += 1 }
      guard next < mappings.count else { return max(0, here) }
      let from = Double(mappings[first].1), to = Double(mappings[next].1)
      let fraction = min(max((position - from) / (to - from), 0), 1)
      return max(0, here + (y(next) - here) * CGFloat(fraction))
    }
    /// Mappings are appended in token order, with gaps for words the rendering omits.
    /// Return count when no token reaches the target, including an empty document.
    private func mappingLowerBound(_ tokenIndex: Int) -> Int {
      var low = 0
      var high = mappings.count
      while low < high {
        let middle = low + (high - low) / 2
        if mappings[middle].1 < tokenIndex { low = middle + 1 } else { high = middle }
      }
      return low
    }
    func mappingIndex(at position: Double) -> Int {
      var low = 0
      var high = mappings.count
      while low < high {
        let middle = low + (high - low) / 2
        if Double(mappings[middle].1) <= position {
          low = middle + 1
        } else {
          high = middle
        }
      }
      return max(0, low - 1)
    }
    /// Puts the session's Manual position on the guide. Used for every Manual alignment, running or
    /// not, so a pause holds the exact fraction; no easing, so Reduce Motion has nothing to remove.
    func alignManual(in scroll: NSScrollView) {
      guard !isHandScrolled, let position = manualPosition?() else { return }
      applyManualPosition(position, in: scroll)
    }
    func applyManualPosition(_ position: Double, in scroll: NSScrollView) {
      let height = scroll.contentView.bounds.height
      if settle == nil, let last = lastPaint, last.position == position, last.guide == guideFraction, last.height == height,
        abs(scroll.contentView.bounds.origin.y - last.y) <= 0.01 { return }
      guard var target = manualScrollY(at: position, in: scroll) else { return }
      if let settle {
        let t = (CACurrentMediaTime() - settle.start) / Self.settleSeconds
        if t >= 1 || Self.reducesMotion() { self.settle = nil } else {
          target = settle.from + (target - settle.from) * CGFloat(1 - (1 - t) * (1 - t))
        }
      }
      lastPaint = (position, guideFraction, height, target)
      if endsVoiceAnimation {
        // Voice's easing may still be in flight from before the mode changed.
        scroll.contentView.layer?.removeAllAnimations()
        endsVoiceAnimation = false
      }
      let origin = scroll.contentView.bounds.origin
      guard abs(origin.y - target) > 0.01 else { return }
      scroll.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: target))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    /// The layout changed under the current word: Voice re-aligns on it, Manual on its position.
    func alignToCurrent(in scroll: NSScrollView) {
      if manualPosition != nil { alignManual(in: scroll) } else { align(scroll: scroll, tokenIndex: tokenIndex, guideFraction: guideFraction) }
    }
    /// Never while a hand is scrolling: a trackpad sends a continuous gesture, and snapping the
    /// nearest word onto the guide at each step fought the fingers and juddered (a mouse wheel's
    /// discrete clicks start no live scroll, so it never showed there). The end of the gesture
    /// settles it once.
    func align(scroll: NSScrollView, tokenIndex: Int, guideFraction: Double, eases: Bool? = nil) {
      guard !isLiveScrolling, (lastAligned != tokenIndex || lastGuideFraction != guideFraction) else { return }
      let slot = mappingLowerBound(tokenIndex)
      guard slot < mappings.count, mappings[slot].1 == tokenIndex,
        let (manager, container, guideY) = prepareGuide(scroll, fraction: guideFraction)
      else { return }
      let target = scrollY(of: mappings[slot].0, manager: manager, container: container, guideY: guideY)
      let animate = eases ?? (lastAligned != nil && isActivelyRunning && !snapNextAlignment && !Self.reducesMotion())
      let destination = NSPoint(x: scroll.contentView.bounds.origin.x, y: target)
      let isSameDestination = lastAlignmentDestination.map {
        abs($0.x - destination.x) <= 0.5 && abs($0.y - destination.y) <= 0.5
      } ?? false
      if !animate || !isSameDestination { Self.moveClip(scroll.contentView, destination, animate) }
      if !animate || !isSameDestination { scroll.reflectScrolledClipView(scroll.contentView) }
      lastAligned = tokenIndex
      lastGuideFraction = guideFraction
      lastAlignmentDestination = destination
      snapNextAlignment = false
    }
    /// The rendered range of a source range that maps character for character to `text`, else nil.
    private static func visibleRange(
      _ source: UTF16SourceRange, in visible: [Int: Int], matching text: String, in plain: NSString
    ) -> NSRange? {
      guard source.length > 0, let start = visible[source.location],
        let end = visible[source.location + source.length - 1], end - start == source.length - 1
      else { return nil }
      let range = NSRange(location: start, length: source.length)
      return plain.substring(with: range).compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        ? range : nil
    }
    private func cueRanges(
      in plain: NSString, document: PrompterDocument, blocks: [UUID: NSRange], visible: [Int: Int]
    ) -> [NSRange] {
      var result: [NSRange] = []
      for block in document.blocks {
        guard let bounds = blocks[block.id] else { continue }
        var cursor = bounds.location
        for cue in block.stageDirections {
          let bracketed = "[\(cue.text)]"
          if let range = Self.visibleRange(cue.sourceRange, in: visible, matching: bracketed, in: plain) {
            result.append(range)
            cursor = max(cursor, NSMaxRange(range))
            continue
          }
          guard cursor < NSMaxRange(bounds) else { continue }
          let search = NSRange(location: cursor, length: NSMaxRange(bounds) - cursor)
          let match = plain.range(of: bracketed, options: [.caseInsensitive, .diacriticInsensitive], range: search)
          let range = match.location == NSNotFound
            ? plain.range(of: cue.text, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            : match
          if range.location != NSNotFound { result.append(range); cursor = NSMaxRange(range) }
        }
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
      max(0, range.location - point, point - NSMaxRange(range))
    }
  }
}
final class TrackingTextView: NSTextView {
  var onCharacterClick: ((Int) -> Void)?
  var onLayout: (() -> Void)?
  @objc func accessibilityReadFromSelection() -> Bool {
    guard selectedRange().location < (string as NSString).length else { return false }
    readFromSelection(nil)
    return true
  }
  @objc func readFromSelection(_ sender: Any?) {
    guard selectedRange().location < (string as NSString).length else { return }
    onCharacterClick?(selectedRange().location)
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option] {
      readFromSelection(nil)
    } else { super.keyDown(with: event) }
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    let item = NSMenuItem(title: "Read from Selection", action: #selector(readFromSelection(_:)), keyEquivalent: "\r")
    item.keyEquivalentModifierMask = [.command, .option]
    item.target = self
    menu.insertItem(item, at: 0)
    return menu
  }
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let manager = layoutManager, let container = textContainer {
      let adjusted = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
      let glyph = manager.glyphIndex(for: adjusted, in: container)
      guard glyph < manager.numberOfGlyphs else { super.mouseDown(with: event); return }
      let character = manager.characterIndexForGlyph(at: glyph)
      if character != NSNotFound {
        // Control-click is the context menu and shift-click extends a selection: neither seeks.
        guard event.modifierFlags.isDisjoint(with: [.control, .shift]) else { super.mouseDown(with: event); return }
        setSelectedRange(NSRange(location: 0, length: 0))
        // AppKit's own tracking runs until the button comes up: a drag leaves a selection for
        // the reference monitor, and a plain click still moves the reading position. A click
        // that wobbles over one character is still a click.
        super.mouseDown(with: event)
        if selectedRange().length <= 1 {
          setSelectedRange(NSRange(location: selectedRange().location, length: 0))
          onCharacterClick?(character)
        }
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

/// Keep the AppKit adapter separate so SwiftUI composites the fade in offscreen renders too.
struct ScriptTextCanvas: NSViewRepresentable {
  let configuration: ScriptTextView
  func makeCoordinator() -> ScriptTextView.Coordinator { configuration.makeCoordinator() }
  func makeNSView(context: Context) -> NSScrollView { configuration.makeNSView(context: context) }
  func updateNSView(_ view: NSScrollView, context: Context) { configuration.updateNSView(view, context: context) }
  static func dismantleNSView(_ view: NSScrollView, coordinator: ScriptTextView.Coordinator) {
    ScriptTextView.dismantleNSView(view, coordinator: coordinator)
  }
}

/// Match the outer mirror/rotation so the fade stays at the visible bottom of the reading area.
struct ReadingViewportMask: View {
  static let fadeHeight: CGFloat = 48
  let flipped: Bool
  var body: some View {
    VStack(spacing: 0) {
      if flipped { fade }
      Color.black
      if !flipped { fade }
    }
  }
  private var fade: some View {
    LinearGradient(colors: flipped ? [.clear, .black] : [.black, .clear], startPoint: .top, endPoint: .bottom)
      .frame(height: Self.fadeHeight)
  }
}
