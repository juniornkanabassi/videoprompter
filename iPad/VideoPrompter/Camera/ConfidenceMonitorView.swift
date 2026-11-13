import AVFoundation
import PrompterCore
import SwiftUI
import UIKit

/// Present instead of the regular presenter while pictureMode is monitorOnly.
struct ConfidenceMonitorView: View {
  @EnvironmentObject private var store: PadStore
  @ObservedObject var camera: PadCamera
  @ObservedObject private var link: MacLink

  private let referencePicture: UIImage?
  init(camera: PadCamera, referencePicture: UIImage? = nil) {
    self.camera = camera; self.link = camera.link; self.referencePicture = referencePicture
  }

  @State private var fill = false
  @State private var showScript = false

  private let accent = Color(red: 245 / 255, green: 207 / 255, blue: 74 / 255)  // #f5cf4a
  private let amber = Color(red: 0.90, green: 0.64, blue: 0.26)
  private var tallyColour: Color {
    switch store.recordingState {
    case .recording: return Color(red: 0.78, green: 0.18, blue: 0.15)
    case .standby: return Color(white: 0.23)
    case .unknown: return amber
    }
  }
  private var tally: String {
    switch store.recordingState {
    case .recording: return "REC · Mac"
    case .standby: return "Standby"
    case .unknown: return "REC unknown"
    }
  }
  private var orientationX: CGFloat { store.mirror ? -1 : 1 }
  private var orientationY: CGFloat { store.flip ? -1 : 1 }
  private var source: String {
    store.cameraSources.first(where: { $0.id == store.selectedCamera })?.name ?? "Mac"
  }
  private var resolution: String {
    guard let size = camera.link.pictureSize else { return "No picture" }
    return size.height > 720 ? "1080p" : "720p"
  }

  var body: some View {
    GeometryReader { _ in
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          HStack(spacing: 12) {
            chip(tally, colour: tallyColour)
            chip("\(source) · \(resolution)", colour: Color(white: 0.15))
          }
          .scaleEffect(x: orientationX, y: orientationY)
          Spacer(minLength: 8)
          button(fill ? "Fit screen" : "Fill screen") { fill.toggle() }
          button("Script line", active: showScript) { showScript.toggle() }
          icon("arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Mirror", active: store.mirror) { store.setMirror(!store.mirror) }
          icon("arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Flip", active: store.flip) { store.setFlip(!store.flip) }
          button("Done") { store.setPictureMode(.off) }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        VStack(spacing: 0) {
        HStack(spacing: 24) {
          GeometryReader { area in
            let size = fitSize(in: area.size, fill: fill)
            Group {
              if let referencePicture { Image(uiImage: referencePicture).resizable().scaledToFit() }
              else { MonitorPicture(link: camera.link, fill: fill) }
            }
              .frame(width: size.width, height: size.height)
              .overlay {
                if store.recordingState != .standby {
                  Rectangle().strokeBorder(tallyColour, lineWidth: store.recordingState == .recording ? 8 : 5)
                }
              }
              .overlay(alignment: .bottomLeading) {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                  let age = context.date.timeIntervalSince(link.lastFrameTime ?? .distantPast)
                  let paused = age > 0.3
                  let status = paused ? "Picture paused · last frame \(link.lastFrameTime == nil ? "unknown" : "\(Int(max(0, age))) s ago")"
                    : link.transportKind == "Wi-Fi" && link.framesSkipped > 0 ? "Wi-Fi · \(link.framesSkipped) frames skipped" : "Live"
                  chip(status, colour: paused ? amber : Color(white: 0.15))
                      }
                .padding(16)
              }
              .position(x: area.size.width / 2, y: area.size.height / 2)
              .clipped()
          }
          MonitorMeter(meter: store.micMeter)
            .frame(width: 60).padding(.vertical, 16)
        }
        if showScript { scriptLine.frame(height: 180) }
        }.scaleEffect(x: orientationX, y: orientationY)
      }
      .background(.black)
    }
    .ignoresSafeArea()
    .statusBarHidden()
  }

  private func fitSize(in area: CGSize, fill: Bool) -> CGSize {
    let ratio: CGFloat = 16 / 9
    let width = fill ? max(area.width, area.height * ratio) : min(area.width, area.height * ratio)
    return CGSize(width: width, height: width / ratio)
  }

  /// A bounded window around the spoken word: earlier words dimmed on the left, the current word in
  /// the accent colour in the middle, upcoming words on the right.
  private var scriptLine: some View {
    let tokens = store.session.document.spokenTokens
    let index = min(max(0, store.session.tokenIndex), max(0, tokens.count - 1))
    let before = tokens.prefix(index).suffix(12).map(\.text).joined(separator: " ")
    let current = index < tokens.count ? tokens[index].text : ""
    let after = tokens.dropFirst(index + 1).prefix(12).map(\.text).joined(separator: " ")
    let font = Font.system(size: 44, weight: .semibold)
    return HStack(spacing: 16) {
      Text(before).foregroundStyle(Color.white.opacity(0.4)).lineLimit(1).truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .trailing)
      Text(current).foregroundStyle(accent).lineLimit(1).fixedSize()
      Text(after).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(font)
    .padding(.horizontal, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .top) { Rectangle().fill(accent.opacity(0.6)).frame(height: 4) }
    .clipped()
  }

  private func chip(_ title: String, colour: Color) -> some View {
    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
      .padding(.horizontal, 16).frame(height: 44).background(colour, in: Capsule())
  }
  private func button(_ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
    Button(title, action: action).font(.system(size: 16, weight: .medium))
      .padding(.horizontal, 16).frame(minHeight: 48)
      .foregroundStyle(active ? Color.yellow : Color.white)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }
  private func icon(_ name: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: name).frame(width: 48, height: 48) }
      .foregroundStyle(active ? Color.yellow : Color.white)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
      .accessibilityLabel(label).accessibilityValue(active ? "On" : "Off")
  }
}

/// Observes the meter itself, so level-only updates redraw just this.
private struct MonitorMeter: View {
  @ObservedObject var meter: RemoteMicMeter
  var body: some View { DBMeter(levelDB: meter.levelDB, axis: .vertical) }
}

private struct MonitorPicture: UIViewRepresentable {
  @ObservedObject var link: MacLink
  var fill: Bool
  func makeUIView(context: Context) -> PictureView { PictureView(layer: link.displayLayer) }
  func updateUIView(_ view: PictureView, context: Context) {
    view.display.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    view.setNeedsLayout()
  }
  final class PictureView: UIView {
    let display: AVSampleBufferDisplayLayer
    init(layer: AVSampleBufferDisplayLayer) {
      display = layer
      super.init(frame: .zero)
      backgroundColor = .black
      clipsToBounds = true
      display.removeFromSuperlayer()
      self.layer.addSublayer(display)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      display.transform = CATransform3DIdentity
      display.frame = bounds
      CATransaction.commit()
    }
  }
}
