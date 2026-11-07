import PrompterCore
import SwiftUI

/// The first success is choosing a job, before configuring the tools for it.
struct LibraryStartView: View {
  @ObservedObject var store: AppStore
  @Binding var importing: Bool
  let practice: () -> Void
  let camera: () -> Void
  var guide: () -> Void = {}

  @ViewBuilder private var otherScriptActions: some View {
    Button("Import File…") { importing = true }
    Button("New Script") { store.create() }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.xxl) {
        VStack(alignment: .leading, spacing: Space.sm) {
          Text("Ready when you are").font(store.uiZoom >= 1.5 ? UIType.title : .largeTitle.bold())
        }
        VStack(alignment: .leading, spacing: Space.sm) {
          Button { store.importClipboard() } label: {
            Text("Paste Copied Text")
          }.buttonStyle(.borderedProminent)
          Text("Copy your script, then paste it here.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
          Button("Quick Reading Practice", action: practice).buttonStyle(.bordered)
            .help("Open a short guided practice, then choose Start reading")
          Text("Try reading for 30 seconds.").font(.callout)
          ReadingWorkflowExample()
        }
        VStack(alignment: .leading, spacing: Space.md) {
          Button(action: camera) { Text("Camera Only") }
          Text("Check your framing or record without a script.")
            .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: Space.sm) {
          Button("Getting Started Guide") { store.showWelcomeScript(); guide() }
          Text("Read the full guide to writing, reading and recording.").font(.callout)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Space.lg) { otherScriptActions }
          VStack(alignment: .leading, spacing: Space.sm) { otherScriptActions }
        }
      }.foregroundStyle(.primary).frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(Space.margin)
    }
  }
}

/// A local illustration: trying each step never starts capture or changes a script.
struct ReadingWorkflowExample: View {
  enum Step: Int, CaseIterable {
    case add, present, read
    var title: String {
      switch self {
      case .add: "1. Add text"
      case .present: "2. Present"
      case .read: "3. Read"
      }
    }
    var caption: String {
      switch self {
      case .add: "Example · Write or paste your words."
      case .present: "Example · Present opens the reading window."
      case .read: "Example · Start reading moves the words."
      }
    }
  }
  @State var step: Step = .add

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack(spacing: Space.sm) {
        ForEach(Step.allCases, id: \.self) { item in
          Button { step = item } label: {
            Text(item.title).underline(step == item)
              .frame(maxWidth: .infinity, minHeight: 24)
          }.buttonStyle(.bordered)
            .accessibilityValue(step == item ? "Selected" : "")
            .accessibilityHint("Shows an example of this step. Does not start reading or recording.")
        }
      }
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(step.caption).font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Space.xs) {
          Image(systemName: step == .add ? "doc.text" : "text.alignleft")
            .accessibilityHidden(true)
          Text("Take a breath. \(Text("Speak").bold().foregroundColor(step == .read ? .yellow : step == .add ? .primary : .white)) in your own time.")
            .font(step == .add ? .body : .title3)
            .fixedSize(horizontal: false, vertical: true)
        }.padding(Space.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(step == .add ? Color.primary : .white)
          .background(step == .add ? Color(nsColor: .textBackgroundColor) : Surfaces.presenterPanel)
      }
      Text("Reading does not record a video.").font(.callout)
    }.foregroundStyle(.primary)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Try the three reading steps")
  }
}

/// Persistent first-use guidance also reaches people who paste straight into a new script.
struct ReadingFirstUseTip: View {
  let dismiss: () -> Void
  static let explanation = "Present, then Start reading. Recording is separate."
  var body: some View {
    HStack(spacing: Space.sm) {
      ViewThatFits(in: .horizontal) {
        Text(Self.explanation).fixedSize(horizontal: false, vertical: true)
        Text("Present to read. Record to film.").fixedSize(horizontal: false, vertical: true)
      }.lineLimit(1)
      Spacer(minLength: 0)
      Button("Got it", action: dismiss)
        .buttonStyle(.plain).frame(minWidth: 24, minHeight: 24)
        .accessibilityLabel("Got it")
        .help("Hide reading tip")
    }.font(.callout).foregroundStyle(.primary.opacity(0.75))
      .accessibilityElement(children: .contain)
  }
}
