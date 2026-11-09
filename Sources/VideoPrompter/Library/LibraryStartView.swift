import PrompterCore
import SwiftUI

struct LibraryStartView: View {
  @ObservedObject var store: AppStore
  @Binding var importing: Bool
  let practice: () -> Void
  let camera: () -> Void
  var guide: () -> Void = {}

  var body: some View {
    ScrollView {
      VStack(spacing: Space.xxl) {
        VStack(spacing: Space.sm) {
          Text("What do you want to do?").font(.largeTitle.bold())
          Text("Video Prompter Alpha is for reading your script and checking your camera. It does not record.")
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: Space.md) { cards }
          VStack(spacing: Space.md) { cards }
        }
        WrapLayout(spacing: Space.sm) {
          Button(action: practice) { Text("Practice with an example script").frame(minHeight: 44) }
          Button { store.showWelcomeScript(); guide() } label: { Text("Help").frame(minHeight: 44) }
          Button { importing = true } label: { Text("Import file…").frame(minHeight: 44) }
        }.buttonStyle(.bordered).controlSize(.large).foregroundStyle(.secondary).frame(minHeight: 44)
      }.frame(maxWidth: 1000).frame(maxWidth: .infinity, minHeight: 600)
        .padding(Space.margin)
    }
  }

  @ViewBuilder private var cards: some View {
    card("Read a script", symbol: "doc.text", description: "Paste it or start a new one. It scrolls as you speak.") {
      WrapLayout(spacing: Space.sm) {
        Button { store.importClipboard() } label: { Text("Paste script").frame(minHeight: 44) }.buttonStyle(.borderedProminent)
        Button { store.create() } label: { Text("New script").frame(minHeight: 44) }
      }
    }
    card("Set up camera", symbol: "video", description: "Pick your camera, turn it upright and check your exposure.") {
      Button(action: camera) { Text("Choose camera").frame(minHeight: 44) }
    }
  }

  private func card<Content: View>(_ title: String, symbol: String, description: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Image(systemName: symbol).font(.title).foregroundStyle(Color.accentColor).accessibilityHidden(true)
      Text(title).font(.title.bold())
      Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      content()
    }.padding(Space.xxl).frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
  }
}

struct ReadingFirstUseTip: View {
  let dismiss: () -> Void
  static let explanation = "Present, then Start reading."
  var body: some View {
    HStack(spacing: Space.sm) {
      ViewThatFits(in: .horizontal) {
        Text(Self.explanation).fixedSize(horizontal: false, vertical: true)
        Text("Present, then Start reading.").fixedSize(horizontal: false, vertical: true)
      }.lineLimit(1)
      Spacer(minLength: 0)
      Button("Got it", action: dismiss)
        .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Got it")
        .help("Hide reading tip")
    }.font(.callout).foregroundStyle(.primary.opacity(0.75))
      .accessibilityElement(children: .contain)
  }
}
