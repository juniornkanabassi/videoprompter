#if os(macOS)
import PrompterCore
import SwiftUI

/// The remote reading surface shares the Mac's word mapping and seek gestures.
/// Mirror and flip are reported in the header; the operator always reads upright.
struct IPadReplicaView: View {
  let state: PadRemote.State
  let onSeek: (Int) -> Void
  @StateObject private var script: ReplicaScript

  init(state: PadRemote.State, onSeek: @escaping (Int) -> Void) {
    self.state = state
    self.onSeek = onSeek
    _script = StateObject(wrappedValue: ReplicaScript(markdown: state.markdown ?? ""))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("iPad presenter").bold()
        Text(state.running ? "Reading" : "Paused").foregroundStyle(.secondary)
        Spacer()
        if state.look?.horizontalMirror == true { Text("Mirrored on iPad") }
        if state.look?.verticalMirror == true { Text("Flipped on iPad") }
        Text("Word \(state.word) of \(state.words)").monospacedDigit()
      }.font(.callout).padding(12)
      GeometryReader { geometry in
        let look = state.look
        let size = InputValidation.fontSize.repair(look?.fontSize ?? 44)
        let guide = InputValidation.guideFraction.repair(look?.guideFraction ?? 0.35)
        ZStack(alignment: .top) {
          if state.presenting != nil, state.markdown != nil {
            ScriptTextView(
              document: script.document, tokenIndex: max(0, state.word - 1),
              isActivelyRunning: state.running, seekRevision: state.seekRevision ?? 0,
              guideFraction: guide, fontName: look?.fontName ?? "Lexend Deca", fontSize: size,
              textOpacity: InputValidation.textOpacity.repair(look?.textOpacity ?? 1),
              fontWeight: look?.fontWeight ?? "Regular", textColorHex: look?.textColorHex ?? "#FFFFFF",
              lineSpacing: InputValidation.lineSpacing.repair(look?.lineSpacing ?? 0.16),
              paragraphSpacing: InputValidation.paragraphSpacing.repair(look?.paragraphSpacing ?? 0.34),
              horizontalMargin: ScriptTextView.sideInset(width: geometry.size.width, textWidth: InputValidation.textWidth.repair(look?.textWidth ?? 0.75)),
              alignment: look?.alignment ?? "Left", showCues: look?.showCues ?? false,
              readingBandOpacity: look?.readingBandOpacity ?? 0.12, highlightActiveWord: true, onSeek: onSeek, onUserScroll: onSeek)
              .disabled(state.editing == true)
          } else {
            Text(state.cameraOnly == true ? "The iPad is showing the camera only" : state.presenting == nil ? "Open a script on the iPad to begin" : "This iPad version does not send the reading view")
              .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }.clipped()
      }
      Text(state.editing == true ? "Editing on iPad. Reading controls are paused." : "Click a word or scroll to move the iPad’s reading position")
        .font(.caption).foregroundStyle(.secondary).padding(8)
    }
    .background(state.pictureMode == .behindScript ? Color.clear : Color.black)
    .onChange(of: state.markdown) { _, markdown in
      script.document = PrompterDocument(markdown: markdown ?? "")
    }
  }
}
/// Parse once per script change, rather than on every live position update.
private final class ReplicaScript: ObservableObject {
  @Published var document: PrompterDocument
  init(markdown: String) { document = PrompterDocument(markdown: markdown) }
}
#endif
