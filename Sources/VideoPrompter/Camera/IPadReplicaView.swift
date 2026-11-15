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
    _script = StateObject(wrappedValue: ReplicaScript(markdown: state.markdown ?? "", language: state.language))
  }

  var body: some View {
    VStack(spacing: 0) {
      if state.activeCleanLook == nil {
      HStack {
        Text("iPad presenter").bold()
        Text(state.running ? "Reading" : "Paused").foregroundStyle(.secondary)
        Spacer()
        if state.look?.horizontalMirror == true { Text("Mirrored on iPad") }
        if state.look?.verticalMirror == true { Text("Flipped on iPad") }
        Text("Word \(state.word) of \(state.words)").monospacedDigit()
      }.font(.callout).padding(12)
      }
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
              alignment: look?.alignment ?? "Left", overVideo: state.pictureMode == .behindScript, showCues: look?.showCues ?? false,
              readingBandOpacity: look?.readingBandOpacity ?? 0.12, highlightActiveWord: true, onSeek: onSeek, onUserScroll: onSeek)
              .disabled(state.editing == true)
          } else {
            Text(state.cameraOnly == true ? "The iPad is showing the camera only" : state.presenting == nil ? "Open a script on the iPad to begin" : "This iPad version does not send the reading view")
              .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }.clipped()
      }
      if state.activeCleanLook == nil {
      Text(state.editing == true ? "Editing on iPad. Reading controls are paused." : "Click a word or scroll to move the iPad’s reading position")
        .font(.caption).foregroundStyle(.secondary).padding(8)
      }
    }
    .background(state.pictureMode == .behindScript || state.activeCleanLook == .pictureAndScript ? Color.clear : Color.black)
    .onChange(of: [state.markdown, state.language]) {
      script.document = Self.document(state.markdown ?? "", language: state.language)
    }
  }
}
extension IPadReplicaView {
  /// The iPad's word numbers count tokens in its script language; an older iPad sends none and parses as English.
  static func document(_ markdown: String, language: String?) -> PrompterDocument {
    PrompterDocument(markdown: markdown, language: language.flatMap(ScriptLanguage.init(rawValue:)) ?? .english)
  }
}
/// Parse once per script change, rather than on every live position update.
private final class ReplicaScript: ObservableObject {
  @Published var document: PrompterDocument
  init(markdown: String, language: String?) { document = IPadReplicaView.document(markdown, language: language) }
}
#endif

#if os(macOS)
/// The wire state owns this preview's aids; never inherit the Mac monitor's saved framing.
extension IPadRemoteView {
  static func replicaGuides(_ state: PadRemote.State, base: CameraGuides = CameraGuides()) -> CameraGuides {
    var guides = base
    guides.thirds = state.guides?.thirds ?? false
    guides.axes = state.guides?.centre ?? false
    guides.bullseye = false
    guides.marker = CameraAspect.presets.first { $0.label == state.guides?.marker }
    guides.zebras = state.guides?.zebras ?? false
    guides.falseColour = state.guides?.falseColour ?? false
    if let value = state.guides?.rotation, let rotation = CameraRotation(rawValue: value) { guides.rotation = rotation }
    if state.activeCleanLook != nil && state.activeCleanLook != .pictureAndScript {
      guides = CameraGuides()
    }
    return guides
  }

  static func microphoneName(_ state: PadRemote.State) -> String {
    let sources = state.voiceSource == "iPad" ? state.localMicrophones : state.macStatus?.microphones
    return sources?.first { $0.id == state.selectedMicrophone }?.name
      ?? (state.voiceSource == "iPad" ? "iPad microphone" : "Mac microphone")
  }
}

/// Adapts the link's lightweight level stream to the same meter the iPad presenter uses.
struct IPadReplicaMeter: View {
  @ObservedObject var meter: RemoteMicMeter
  let name: String
  var isListening: Bool
  @State private var input = InputMeter()
  var body: some View {
    MicMeterView(meter: input, micName: name, isListening: isListening)
      .background(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).fill(Surfaces.scrim))
      .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in update() }
      .onChange(of: meter.levelDB, initial: true) { _, _ in update() }
  }
  private func update() {
    input.show(peakDBFS: Float(meter.levelDB), isClipping: meter.levelDB >= -0.1)
  }
}
#endif
