import PrompterCore
import SwiftUI

/// First launch, as mockup 07: two yellow-accented choices and one quiet line of extras.
struct LibraryStartView: View {
  @ObservedObject var store: AppStore
  @Binding var importing: Bool
  let practice: () -> Void
  let camera: () -> Void
  var guide: () -> Void = {}

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
        if geometry.size.height < 560 {
          VStack(spacing: Space.sm) {
            Button { store.create() } label: { Label("Read a script", systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 56) }
              .buttonStyle(AlphaPrimaryButtonStyle())
            Button(action: camera) { Label("Set up camera", systemImage: "video").frame(maxWidth: .infinity, minHeight: 56) }
              .buttonStyle(AlphaSecondaryButtonStyle())
          }
        } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: Space.md) { cards }
          VStack(spacing: Space.md) { cards }
        }
        }
        WrapLayout(spacing: Space.md) {
          Button(action: practice) { Text("Practice with an example script").frame(minHeight: AlphaStyle.minTarget).contentShape(Rectangle()) }
          Button { store.showWelcomeScript(); guide() } label: { Text("Help").frame(minHeight: AlphaStyle.minTarget).contentShape(Rectangle()) }
          Button { importing = true } label: { Text("Import file…").frame(minHeight: AlphaStyle.minTarget).contentShape(Rectangle()) }
        }.buttonStyle(.borderless).controlSize(.large).font(.system(size: 16)).foregroundStyle(.secondary)
      }.frame(maxWidth: 1000).frame(maxWidth: .infinity)
        .padding(geometry.size.height < 560 ? Space.md : Space.margin)
    }
  }

  }

  @ViewBuilder private var cards: some View {
    card("Read a script", symbol: "doc.text", description: "Paste it or start a new one. It scrolls as you speak.") {
      WrapLayout(spacing: Space.sm) {
        Button { store.importClipboard() } label: { Label("Paste script", systemImage: "doc.on.clipboard") }
          .buttonStyle(AlphaPrimaryButtonStyle())
        Button { store.create() } label: { Label("New script", systemImage: "plus") }
          .buttonStyle(AlphaSecondaryButtonStyle())
      }
    }
    card("Set up camera", symbol: "video", description: "Pick your camera, turn it upright and check your exposure.") {
      Button(action: camera) { Label("Choose camera", systemImage: "video") }
        .buttonStyle(AlphaSecondaryButtonStyle())
    }
  }

  private func card<Content: View>(_ title: String, symbol: String, description: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(AlphaStyle.accent)
        .frame(height: 40, alignment: .leading).accessibilityHidden(true)
      Text(title).font(.title.bold())
      Text(description).font(.system(size: 16)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      content()
    }.padding(Space.xl).frame(maxWidth: .infinity, alignment: .topLeading)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      .overlay(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).stroke(Color.primary.opacity(0.15)))
  }
}

/// Yellow with black text: the one primary action on a card.
private struct AlphaPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .semibold)).foregroundStyle(AlphaStyle.onAccent)
      .padding(.horizontal, Space.lg).frame(minHeight: AlphaStyle.minTarget)
      .background(AlphaStyle.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Space.md))
  }
}

private struct AlphaSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
      .padding(.horizontal, Space.lg).frame(minHeight: AlphaStyle.minTarget)
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
