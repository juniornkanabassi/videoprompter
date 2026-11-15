import PrompterCore
import SwiftUI

struct LibraryStartView: View {
  @ObservedObject var store: AppStore
  @ObservedObject private var link = IPadCameraSender.shared
  @Environment(\.openWindow) private var openWindow
  @Binding var importing: Bool
  let practice: () -> Void
  let camera: () -> Void
  var guide: () -> Void = {}
  var openScripts: () -> Void = {}
  var continueScript: () -> Void = {}
  var lastTitle: String? = nil

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: geometry.size.height < 560 ? Space.sm : Space.xxl) {
          VStack(spacing: Space.sm) {
            Text("What do you want to do?").font(geometry.size.height < 560 ? .title2.bold() : .largeTitle.bold())
            Text("Video Prompter Alpha is for reading your script and checking your camera. It does not record.")
              .font(.system(size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.md) { cards(width: max(280, (min(1200, geometry.size.width - 2 * (geometry.size.height < 560 ? Space.md : Space.margin)) - 2 * Space.md) / 3)) }
              .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Space.md) { cards(width: nil) }
          }
          WrapLayout(spacing: Space.md) {
            if store.scripts.isEmpty { Button("Practice with an example script", action: practice) }
            Button("Help") { store.showWelcomeScript(); guide() }
            Button("Import file…") { importing = true }
          }.buttonStyle(.borderless).font(.system(size: 16)).foregroundStyle(.secondary)
        }.frame(maxWidth: 1200).frame(maxWidth: .infinity)
          .padding(geometry.size.height < 560 ? Space.md : Space.margin)
      }
    }
  }

  @ViewBuilder private func cards(width: CGFloat?) -> some View {
    card("Read a script", symbol: "doc.text", description: "Paste it or start a new one. It scrolls as you speak.") {
      if let lastTitle, !store.scripts.isEmpty {
        Button("Continue “\(lastTitle)”", action: continueScript).buttonStyle(.link)
      }
      if !store.scripts.isEmpty {
        Button("Open scripts", action: openScripts).buttonStyle(AlphaPrimaryButtonStyle())
      }
      WrapLayout(spacing: Space.sm) {
        if store.scripts.isEmpty {
          Button("Paste script") { store.importClipboard() }.buttonStyle(AlphaPrimaryButtonStyle())
        } else {
          Button("Paste script") { store.importClipboard() }.buttonStyle(AlphaSecondaryButtonStyle())
        }
        Button("New script") { store.create() }.buttonStyle(AlphaSecondaryButtonStyle())
      }
    }
    .frame(width: width)
    card("Camera only", symbol: "video", description: "See yourself and check framing, focus and exposure. No script needed.") {
      Button("Open camera", action: camera).buttonStyle(AlphaSecondaryButtonStyle())
    }
    .frame(width: width)
    card("iPad Control", symbol: "ipad", description: "Use your iPad as the prompter or camera, run from this Mac.") {
      Text(Self.iPadStatus(link.iPadState, transport: link.transport))
        .font(.caption).padding(Space.sm).background(Color.primary.opacity(0.08), in: Capsule())
      Button(link.iPadState == nil ? "Connect an iPad" : "Open iPad Control") { openWindow(id: "ipad-remote") }
        .buttonStyle(AlphaSecondaryButtonStyle())
    }
    .frame(width: width)
  }

  static func iPadStatus(_ state: PadRemote.State?, transport: String?) -> String {
    guard let state else { return "No iPad connected" }
    return ["Connected", state.deviceName ?? "iPad", transport].compactMap { $0 }.joined(separator: " · ")
  }

  private func card<Content: View>(_ title: String, symbol: String, description: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(AlphaStyle.accent)
        .frame(height: 40, alignment: .leading).accessibilityHidden(true)
      Text(title).font(.title.bold())
      Text(description).font(.system(size: 16)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      content()
    }.padding(Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      .overlay(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).stroke(Color.primary.opacity(0.15)))
  }
}

/// Yellow with black text: the one primary action on a card.
private struct AlphaPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .semibold)).foregroundStyle(AlphaStyle.onAccent)
      .padding(.horizontal, Space.lg).frame(minHeight: 32)
      .background(AlphaStyle.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Space.md))
  }
}

private struct AlphaSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
      .padding(.horizontal, Space.lg).frame(minHeight: 32)
      .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: Space.md))
  }
}

struct ReadingFirstUseTip: View {
  let dismiss: () -> Void
  /// A smaller line for the editor's narrow layout, so the tip leaves the writing area room.
  var compact = false
  static let explanation = "Click Open presenter, then Start reading."
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
      Text(Self.explanation).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button("Got it", action: dismiss)
        .buttonStyle(.plain).frame(minWidth: AlphaStyle.minTarget, minHeight: AlphaStyle.minTarget)
        .accessibilityLabel("Got it")
        .help("Hide reading tip")
    }.font(.system(size: compact ? 13 : 15)).foregroundStyle(.primary)
      .accessibilityElement(children: .contain)
  }
}
