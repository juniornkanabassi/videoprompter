import AVFoundation
import SwiftUI
import UIKit

/// Present instead of the regular presenter while pictureMode is monitorOnly.
struct ConfidenceMonitorView: View {
  @EnvironmentObject private var store: PadStore
  @ObservedObject var camera: PadCamera
  @State private var fill = false
  @State private var showScript = false

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
    GeometryReader { geometry in
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          HStack(spacing: 10) {
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
        HStack(spacing: 24) {
          GeometryReader { area in
            let size = fitSize(in: area.size, fill: fill)
            MonitorPicture(link: camera.link, fill: fill)
              .frame(width: size.width, height: size.height)
              .scaleEffect(x: orientationX, y: orientationY)
              .overlay {
                if store.recordingState != .standby {
                  Rectangle().strokeBorder(tallyColour, lineWidth: store.recordingState == .recording ? 8 : 5)
                }
              }
              .position(x: area.size.width / 2, y: area.size.height / 2)
              .clipped()
          }
          DBMeter(levelDB: store.micLevelDB, axis: .vertical)
            .frame(width: 60).padding(.vertical, 16)
            .scaleEffect(x: orientationX, y: orientationY)
        }
        if showScript { scriptLine.frame(height: min(180, geometry.size.height * 0.18)) }
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

  private var scriptLine: some View {
    let tokens = store.session.document.spokenTokens
    let index = min(max(0, store.session.tokenIndex), tokens.count)
    let current = index < tokens.count ? tokens[index].text : ""
    let remaining = tokens.dropFirst(min(index + 1, tokens.count)).prefix(29).map(\.text).joined(separator: " ")
    return HStack(spacing: 0) {
      (Text(current).foregroundColor(.yellow) + Text(remaining.isEmpty ? "" : " " + remaining))
        .font(.system(size: 48, weight: .semibold)).lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .top) { Rectangle().fill(Color.yellow.opacity(0.6)).frame(height: 3) }
    .clipped()
    .scaleEffect(x: orientationX, y: orientationY)
  }

  private func chip(_ title: String, colour: Color) -> some View {
    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
      .padding(.horizontal, 16).frame(height: 44).background(colour, in: Capsule())
  }
  private func button(_ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
    Button(title, action: action).font(.system(size: 16, weight: .medium))
      .padding(.horizontal, 14).frame(minHeight: 48)
      .foregroundStyle(active ? Color.yellow : Color.white)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
  }
  private func icon(_ name: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: name).frame(width: 48, height: 48) }
      .foregroundStyle(active ? Color.yellow : Color.white)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
      .accessibilityLabel(label).accessibilityValue(active ? "On" : "Off")
  }
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
