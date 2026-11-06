import AppKit
import PrompterCore
import SwiftUI

/// Uses the presenter's text renderer, without a session, scrolling or capture.
struct ReadingLayoutPreview: View {
  let settings: PrompterSettings
  let overVideo: Bool
  static let sample = "Read this **line**.\n\nPause. Begin again."
  static let scale = 0.65

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text("Reading preview · scaled sample").font(.callout)
      ScrollView {
        ReadingSampleText(settings: settings, overVideo: overVideo)
          .frame(maxWidth: .infinity)
          .padding(Space.md)
      }.frame(height: min(260, max(180, settings.fontSize * 4.5)))
        .background(Color(nsColor: NSColor(hex: settings.backgroundColorHex) ?? .black)
          .opacity(settings.backdropOpacity(withVideo: overVideo)))
        .background(.gray)
        .clipped()
        .scaleEffect(x: settings.horizontalMirror ? -1 : 1, y: settings.verticalMirror ? -1 : 1)
        .rotationEffect(.degrees(Double(settings.rotation)))
      Text("65% of reading size. Scroll the sample if needed.")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
    }.accessibilityElement(children: .contain)
      .accessibilityLabel("Reading layout preview")
  }
}

struct ReadingSampleText: NSViewRepresentable {
  let settings: PrompterSettings
  let overVideo: Bool

  func makeNSView(context: Context) -> NSTextView {
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    text.isEditable = false
    text.isSelectable = false
    text.drawsBackground = false
    text.textContainerInset = .zero
    text.textContainer?.lineFragmentPadding = 0
    text.textContainer?.widthTracksTextView = false
    text.setAccessibilityLabel("Sample of current reading appearance")
    return text
  }

  func updateNSView(_ text: NSTextView, context: Context) {
    let renderer = ScriptTextView.Coordinator(onSeek: { _ in })
    renderer.textView = text
    renderer.tokenIndex = 2
    renderer.render(document: PrompterDocument(markdown: ReadingLayoutPreview.sample),
      fontName: settings.fontName, fontSize: settings.fontSize, textOpacity: settings.textOpacity,
      fontWeight: settings.fontWeight, textColorHex: settings.textColorHex,
      lineSpacing: settings.lineSpacing, paragraphSpacing: settings.paragraphSpacing,
      alignment: settings.alignment, highlightActiveWord: settings.highlightActiveWord, overVideo: overVideo)
    // Scale after rendering, including spacing floors, so this is the same layout in miniature.
    guard let storage = text.textStorage else { return }
    let range = NSRange(location: 0, length: storage.length)
    storage.enumerateAttributes(in: range) { attributes, range, _ in
      if let font = attributes[.font] as? NSFont {
        storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * ReadingLayoutPreview.scale), range: range)
      }
      if let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
        paragraph.lineSpacing *= ReadingLayoutPreview.scale
        paragraph.paragraphSpacing *= ReadingLayoutPreview.scale
        paragraph.paragraphSpacingBefore *= ReadingLayoutPreview.scale
        storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
      }
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
    guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
    let width = proposal.width ?? 320
    guard width > 0, width.isFinite else { return .zero }
    let column = max(40, width * settings.textWidth)
    nsView.textContainerInset.width = (width - column) / 2
    container.containerSize = NSSize(width: column, height: 10_000)
    layout.ensureLayout(for: container)
    return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
  }
}
