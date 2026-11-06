import SwiftUI

/// The enlarged presenter's single overflow route. The host supplies job-based sections.
struct PresenterToolsMenu<Content: View>: View {
  @ViewBuilder let content: () -> Content
  var body: some View {
    Menu(content: content) {
      HStack(spacing: Space.xs) {
        Text("Tools")
        Image(systemName: "chevron.down").imageScale(.small)
      }.fixedSize()
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("Tools")
    .accessibilityHint("Text, Camera, Exposure and Microphone controls")
  }
}
