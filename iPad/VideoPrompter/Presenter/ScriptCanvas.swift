import PrompterCore
import SwiftUI
import UIKit

/// The scrolling script. It keeps the current word on the reading line: Manual and Voice both
/// follow the session's fractional position on every display refresh (Manual's timeline, Voice's
/// glide after the recogniser), the same rules as the Mac presenter. A drag moves the reading position to the word left on the line.
/// Tells the coordinator whenever UIKit has really resized it: SwiftUI can update the representable
/// before the new bounds arrive, and the reading rule must be re-measured against the final size.
final class CanvasTextView: UITextView {
  var onLayout: (() -> Void)?
  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

struct ScriptCanvas: UIViewRepresentable {
  let document: PrompterDocument
  let tokenIndex: Int
  var lastConfirmedTokenIndex: Int?
  var isActivelyRunning = false
  var seekRevision = 0
  /// Where the reading line sits in the canvas's own (unmirrored) layout, from the top.
  let layoutGuideFraction: Double
  let style: ScriptStyle
  let textWidth: Double
  /// The session's fractional token position, read on every frame while running. Nil eases to each word.
  var manualPosition: (() -> Double)?
  let onSeek: (Int) -> Void
  var onUserScroll: ((Int) -> Void)?
  /// A single tap, told apart from the double tap that jumps to a word. Clean screen uses it to bring the controls back.
  var onSingleTap: (() -> Void)?

  static func sideInset(width: CGFloat, textWidth: Double) -> CGFloat {
    max(32, width * (1 - CGFloat(textWidth)) / 2)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UITextView {
    let view = CanvasTextView(usingTextLayoutManager: false)
    view.onLayout = { [weak c = context.coordinator] in c?.relayout() }
    view.isEditable = false
    view.isSelectable = false
    view.backgroundColor = .clear
    view.showsVerticalScrollIndicator = false
    view.showsHorizontalScrollIndicator = false
    view.alwaysBounceVertical = true
    view.contentInsetAdjustmentBehavior = .never
    view.textContainer.lineFragmentPadding = 0
    view.accessibilityLabel = "Presenter script"
    view.delegate = context.coordinator
    let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    view.addGestureRecognizer(doubleTap)
    let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped))
    singleTap.require(toFail: doubleTap)
    view.addGestureRecognizer(singleTap)
    context.coordinator.textView = view
    return view
  }

  static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
    coordinator.stopDisplayLink()
  }

  func updateUIView(_ view: UITextView, context: Context) {
    let c = context.coordinator
    c.parent = self
    let inset = Self.sideInset(width: view.bounds.width, textWidth: textWidth)
    if abs(view.textContainerInset.left - inset) > 0.5 {
      view.textContainerInset.left = inset
      view.textContainerInset.right = inset
      c.snapNext = true
    }
    if c.renderedDocument != document || c.renderedStyle != style {
      c.render(document: document, style: style)
    } else {
      c.updateReadColours()
    }
    if c.lastSeekRevision != seekRevision {
      c.lastSeekRevision = seekRevision
      c.snapNext = true
      // Only the drag's own seek eases; a click, Next passage or Restart lands at once, also
      // when it arrives in the same update as the drag's.
      if seekRevision != c.dragSeekRevision { c.settle = nil }
      c.dragSeekRevision = nil
    }
    c.updateDisplayLink()
    if manualPosition == nil { c.alignVoice() } else { c.alignManual() }
  }

  @MainActor final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ScriptCanvas?
    weak var textView: UITextView?
    var renderedDocument: PrompterDocument?
    var renderedStyle: ScriptStyle?
    var lastSeekRevision = -1
    var snapNext = true
    private var mappings: [(range: NSRange, token: Int)] = []
    private var colouredThrough: (token: Int, confirmed: Int?) = (-1, nil)
    private var lastAligned: (token: Int, guide: Double, height: CGFloat)?
    /// The last Manual or Voice paint. The same position, guide and height with the scroll still
    /// where it was put needs no layout or measuring: Voice paints every frame, silence included.
    private var lastPaint: (position: Double, guide: Double, size: CGSize, y: CGFloat)?
    /// A drag let go of: the next paints ease from where the finger left the text instead of jumping.
    var settle: (from: CGFloat, start: CFTimeInterval)?
    var dragSeekRevision: Int?
    private var displayLink: CADisplayLink?
    private var isDragging = false
    /// The Mac's yellow, #f5cf4a.
    private static let currentWord = UIColor(red: 0.961, green: 0.812, blue: 0.290, alpha: 1)
    private var baseColour = UIColor.white
    private var textOpacity = 1.0

    func render(document: PrompterDocument, style: ScriptStyle) {
      guard let textView, let parent else { return }
      let output = ScriptRenderer.render(document, style: style)
      mappings = output.mappings
      baseColour = ScriptRenderer.colour(style.textColorHex)
      textOpacity = style.textOpacity
      let text = NSMutableAttributedString(attributedString: output.text)
      let progress = max(parent.tokenIndex, parent.lastConfirmedTokenIndex ?? 0)
      for (range, index) in mappings where index <= progress {
        text.addAttribute(.foregroundColor, value: readColour(index), range: range)
      }
      textView.attributedText = text
      renderedDocument = document
      renderedStyle = style
      colouredThrough = (parent.tokenIndex, parent.lastConfirmedTokenIndex)
      lastAligned = nil
      snapNext = true
    }

    /// Read words dim; the current word turns yellow when that is on.
    private func readColour(_ index: Int) -> UIColor {
      guard let parent else { return baseColour }
      let confirmed = parent.lastConfirmedTokenIndex.map { index <= $0 } ?? false
      let alpha = confirmed ? textOpacity * 0.38 : textOpacity
      return index == parent.tokenIndex && !confirmed && (renderedStyle?.highlightActiveWord ?? false)
        ? Self.currentWord.withAlphaComponent(alpha) : baseColour.withAlphaComponent(alpha)
    }

    /// Only the words between the old and new positions change colour.
    func updateReadColours() {
      guard let textView, let parent else { return }
      let now = (token: parent.tokenIndex, confirmed: parent.lastConfirmedTokenIndex)
      guard now.token != colouredThrough.token || now.confirmed != colouredThrough.confirmed else { return }
      let values = [colouredThrough.token, now.token, colouredThrough.confirmed ?? -1, now.confirmed ?? -1]
      let lower = (colouredThrough.confirmed == nil) != (now.confirmed == nil) ? 0 : max(0, values.min() ?? 0)
      let upper = values.max() ?? 0
      let storage = textView.textStorage
      storage.beginEditing()
      var slot = lowerBound(lower)
      while slot < mappings.count, mappings[slot].token <= upper {
        storage.addAttribute(.foregroundColor, value: readColour(mappings[slot].token), range: mappings[slot].range)
        slot += 1
      }
      storage.endEditing()
      colouredThrough = now
    }

    private func lowerBound(_ token: Int) -> Int {
      var low = 0, high = mappings.count
      while low < high {
        let middle = (low + high) / 2
        if mappings[middle].token < token { low = middle + 1 } else { high = middle }
      }
      return low
    }

    /// The layout measured, with top and bottom room so the first and last words reach the line.
    private func prepare() -> (manager: NSLayoutManager, guideY: CGFloat)? {
      guard let textView, let parent, textView.bounds.height > 0 else { return nil }
      let height = textView.bounds.height
      let guideY = min(height - 20, max(40, height * parent.layoutGuideFraction))
      let edge = max(80, max(guideY, height - guideY))
      if abs(textView.textContainerInset.top - edge) > 0.5 || abs(textView.textContainerInset.bottom - edge) > 0.5 {
        textView.textContainerInset.top = edge
        textView.textContainerInset.bottom = edge
      }
      let manager = textView.layoutManager
      manager.ensureLayout(for: textView.textContainer)
      return (manager, guideY)
    }

    /// Where the reading rule rests for the line holding this word: just under that line's text,
    /// halfway into the leading below it, from the measured line bounds (not a font-size guess).
    private func ruleY(_ range: NSRange, manager: NSLayoutManager) -> CGFloat {
      guard let textView else { return 0 }
      let glyph = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil).location
      let used = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
      let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      return used.maxY + max(3, (fragment.maxY - used.maxY) / 2) + textView.textContainerInset.top
    }

    func alignVoice() {
      guard !isDragging, let textView, let parent, let (manager, guideY) = prepare() else { return }
      let height = textView.bounds.height
      if let last = lastAligned, !snapNext, last.token == parent.tokenIndex,
        last.guide == parent.layoutGuideFraction, last.height == height { return }
      let slot = lowerBound(parent.tokenIndex)
      guard slot < mappings.count else { return }
      let target = max(0, ruleY(mappings[slot].range, manager: manager) - guideY)
      let animate = lastAligned != nil && !snapNext && parent.isActivelyRunning && !UIAccessibility.isReduceMotionEnabled
      let destination = CGPoint(x: 0, y: target)
      if animate {
        UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
          textView.contentOffset = destination
        }
      } else {
        textView.layer.removeAllAnimations()
        textView.contentOffset = destination
      }
      lastAligned = (parent.tokenIndex, parent.layoutGuideFraction, height)
      snapNext = false
    }

    /// Words on one line share one scroll position, the rule resting just under that line; the text
    /// glides to the next line during the second half of the line's last word (see lineTransition).
    func alignManual() {
      guard !isDragging, let textView else { return }
      guard let position = parent?.manualPosition?(), !mappings.isEmpty else {
        // Nothing left to settle onto (Reduce Motion turned on, the script emptied).
        if settle != nil { settle = nil; updateDisplayLink() }
        return
      }
      if !snapNext, settle == nil, let last = lastPaint, last.position == position, last.guide == parent?.layoutGuideFraction,
        last.size == textView.bounds.size, abs(textView.contentOffset.y - last.y) <= 0.01 { return }
      guard let (manager, guideY) = prepare() else { return }
      func y(_ slot: Int) -> CGFloat { ruleY(mappings[slot].range, manager: manager) - guideY }
      var low = 0, high = mappings.count
      while low < high {
        let middle = (low + high) / 2
        if Double(mappings[middle].token) <= position { low = middle + 1 } else { high = middle }
      }
      let current = max(0, low - 1)
      let here = y(current)
      var next = current + 1
      while next < mappings.count, abs(y(next) - here) < 2 { next += 1 }
      var target = here
      if next < mappings.count {
        let lastToken = Double(mappings[next - 1].token), nextFirst = Double(mappings[next].token)
        target = here + (y(next) - here) * CGFloat(PadPresenterLayout.lineTransition(position: position, lastToken: lastToken, nextFirstToken: nextFirst))
      }
      target = max(0, target)
      if let settle {
        let t = (CACurrentMediaTime() - settle.start) / 0.2
        if t >= 1 || UIAccessibility.isReduceMotionEnabled { self.settle = nil; updateDisplayLink() } else {
          target = settle.from + (target - settle.from) * CGFloat(1 - (1 - t) * (1 - t))
        }
      }
      lastPaint = (position, parent?.layoutGuideFraction ?? 0, textView.bounds.size, target)
      if abs(textView.contentOffset.y - target) > 0.01 {
        textView.layer.removeAllAnimations()
        textView.contentOffset = CGPoint(x: 0, y: target)
      }
      snapNext = false
    }

    /// Re-aligns after a size change; a no-op while nothing moved.
    func relayout() {
      guard let parent else { return }
      if parent.manualPosition == nil { alignVoice() } else { alignManual() }
    }

    func updateDisplayLink() {
      // A settle finishes even when the drag paused Manual.
      let wanted = parent?.manualPosition != nil && parent?.isActivelyRunning == true || settle != nil
      if wanted, displayLink == nil {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
      } else if !wanted {
        stopDisplayLink()
      }
    }
    func stopDisplayLink() {
      displayLink?.invalidate()
      displayLink = nil
    }
    @objc private func tick() { alignManual() }

    // MARK: Touch

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      isDragging = true
      scrollView.layer.removeAllAnimations()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { finishDrag() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishDrag() }

    /// The word nearest the reading line becomes the reading position.
    private func finishDrag() {
      isDragging = false
      if let textView, parent?.manualPosition != nil, !UIAccessibility.isReduceMotionEnabled {
        settle = (textView.contentOffset.y, CACurrentMediaTime())
        dragSeekRevision = lastSeekRevision &+ 1
      }
      guard let textView, let parent, let (manager, guideY) = prepare(), !mappings.isEmpty else { return }
      let line = textView.contentOffset.y + guideY
      var best = 0
      var bestDistance = CGFloat.greatestFiniteMagnitude
      // Mappings run top to bottom, so the search stops once words move away from the line.
      for slot in mappings.indices {
        let distance = abs(ruleY(mappings[slot].range, manager: manager) - line)
        if distance < bestDistance { bestDistance = distance; best = slot } else if distance > bestDistance + 200 { break }
      }
      lastAligned = (mappings[best].token, parent.layoutGuideFraction, textView.bounds.height)
      (parent.onUserScroll ?? parent.onSeek)(mappings[best].token)
    }

    @objc func singleTapped() { parent?.onSingleTap?() }

    @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
      guard let textView, let parent, !mappings.isEmpty else { return }
      var point = gesture.location(in: textView)
      point.x -= textView.textContainerInset.left
      point.y -= textView.textContainerInset.top
      let manager = textView.layoutManager
      let glyph = manager.glyphIndex(for: point, in: textView.textContainer)
      let character = manager.characterIndexForGlyph(at: glyph)
      let nearest = mappings.min { a, b in
        distance(character, a.range) < distance(character, b.range)
      }
      if let nearest { parent.onSeek(nearest.token) }
    }
    private func distance(_ point: Int, _ range: NSRange) -> Int {
      max(0, range.location - point, point - NSMaxRange(range))
    }
  }
}
