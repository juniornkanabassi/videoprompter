import PrompterCore
import SwiftUI

/// The reading setting for the list; absent unless Talk & Read's file exists.
struct TalkAndReadWordsRow: View {
  @ObservedObject var store: AppStore
  @State private var count: Int?
  var body: some View {
    Group {
      if let count {
        VStack(alignment: .leading, spacing: Space.xs) {
          Toggle("Use my Talk & Read word list", isOn: $store.settings.usesTalkAndReadWords)
          Text("Knows \(count) words and names that speech engines mishear.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .task { count = HeardWordList.talkAndReadURL.flatMap { HeardWordList(contentsOf: $0) }?.count }
  }
}
