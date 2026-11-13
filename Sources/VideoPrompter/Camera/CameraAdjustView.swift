@preconcurrency import AVFoundation
import SwiftUI

/// Camera and shot controls for the presenter Adjust panel.
struct CameraAdjustView: View {
  @ObservedObject var model: CameraModel
  var devicesOverride: [CameraDevice]? = nil
  var sourceInfoOverride: [String: CameraSourceInfo]? = nil
  var initiallyAdvanced = false
  var advancedOnly = false
  var showsShotHeading = true
  var shotOnly = false
  @State private var advancedOpen = false
  @State private var renaming: CameraDevice?
  @State private var nickname = ""
  private var devices: [CameraDevice] { devicesOverride ?? model.devices }

  var body: some View {
    VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
      if advancedOnly { advancedControls } else {
        if !shotOnly {
        Text("Camera").font(.title2.bold())
        Text("Pick the camera, then make the picture upright.")
          .cardCaption().fixedSize(horizontal: false, vertical: true)
        ChoiceTiles(items: devices, columns: 2, minTileWidth: 300) { device in
          let info = sourceInfo(device)
          let selected = device.uid == model.selectedUID
          let detail = [info.connectionDescription, info.videoFormat].compactMap { $0 }.joined(separator: " · ")
          ZStack(alignment: .top) {
            Button { model.selectedUID = device.uid } label: { Color.clear.contentShape(Rectangle()) }
              .buttonStyle(.plain)
              .accessibilityLabel(device.displayName).accessibilityValue(detail)
              .accessibilityAddTraits(selected ? .isSelected : [])
            HStack(alignment: .center, spacing: Space.sm) {
              HStack(alignment: .top, spacing: Space.sm) {
                Image(systemName: "video").font(.title3).frame(width: Space.xxl + Space.xs)
                VStack(alignment: .leading, spacing: Space.xs) {
                  Text(device.displayName).cardTitle().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                  // Connection and picture format on their own lines, so neither is cut in the middle.
                  Text(info.connectionDescription).cardCaption().fixedSize(horizontal: false, vertical: true)
                  if let format = info.videoFormat {
                    // Where the room is short, the size and the rate go on separate lines instead of splitting at a dot.
                    ViewThatFits(in: .horizontal) {
                      Text(format).cardCaption().lineLimit(1).fixedSize()
                      VStack(alignment: .leading, spacing: 0) {
                        ForEach(format.components(separatedBy: " · "), id: \.self) { Text($0).cardCaption() }
                      }
                    }
                  }
                }
              }.allowsHitTesting(false)
              Spacer(minLength: 0)
              // Rename is a quiet text button and the check sits beside it, so every row ends on one right edge.
              Button { renaming = device; nickname = device.nickname ?? "" } label: {
                HStack(spacing: Space.xs) {
                  Image(systemName: "pencil")
                  Text("Rename").lineLimit(1)
                }.font(.system(size: 14, weight: .medium)).foregroundStyle(.primary.opacity(0.75))
                  .frame(minHeight: AlphaStyle.minTarget).contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityLabel("Rename \(device.displayName)").help("Rename this camera")
              Image(systemName: "checkmark.circle.fill").cardTitle().foregroundStyle(AlphaStyle.accent)
                .opacity(selected ? 1 : 0).frame(width: Space.xl).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).accessibilityElement(children: .contain)
          }.modifier(ChoiceTileStyle(selected: selected, minHeight: 52, showsBadge: false))
        }.accessibilityElement(children: .contain).accessibilityLabel("Camera selection")
        }
        if showsShotHeading { Text("Shot").font(.system(size: 17, weight: .semibold)) }
        ChoiceTiles(items: Self.shots, columns: 3) { shot($0) }
          .accessibilityElement(children: .contain).accessibilityLabel("Shot")
        DisclosureGroup(isExpanded: $advancedOpen) {
          advancedControls
        } label: { Text("Advanced").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).frame(minHeight: AlphaStyle.minTarget) }
      }
    }
    .onAppear { advancedOpen = initiallyAdvanced; if devicesOverride == nil { model.refreshDevices() } }
    .sheet(item: $renaming) { device in
      VStack(alignment: .leading, spacing: Space.md) {
        Text("Rename camera").font(.headline)
        TextField(device.originalName, text: $nickname)
        HStack { Button("Cancel") { renaming = nil }; Button("Save") { model.renameCamera(device.uid, to: nickname); renaming = nil } }
      }.padding(Space.md).frame(width: 320)
    }
  }
  var advancedControls: some View {
    VStack(alignment: .leading, spacing: AlphaStyle.controlGap) {
      ChoiceTiles(items: [Self.upsideDown], columns: 1) { shot($0) }
      Toggle("Automatic", isOn: Binding(get: { model.guides.automaticRotation }, set: { model.guides.automaticRotation = $0 }))
        .toggleStyle(AccentSwitchStyle())
    }
  }
  private struct Shot: Identifiable {
    let id: String, title: String, detail: String, rotation: CameraRotation
  }
  private static let shots = [
    Shot(id: "none", title: "Landscape", detail: "Upright", rotation: .none),
    Shot(id: "quarter", title: "Vertical left", detail: "Top on the left", rotation: .quarter),
    Shot(id: "threeQuarters", title: "Vertical right", detail: "Top on the right", rotation: .threeQuarters)]
  private static let upsideDown = Shot(id: "half", title: "Upside down", detail: "Top at the bottom", rotation: .half)
  private func sourceInfo(_ device: CameraDevice) -> CameraSourceInfo {
    if let info = sourceInfoOverride?[device.uid] { return info }
    if device.uid == model.selectedUID, let info = model.sourceInfo { return info }
    if devicesOverride == nil, let capture = AVCaptureDevice(uniqueID: device.uid) {
      return CameraSourceInfo(device: capture, displayName: device.displayName, useMaximumFrameRate: true)
    }
    return CameraSourceInfo(displayName: device.displayName, connection: .classify(deviceType: "", transportType: 0, manufacturer: "", modelID: "", name: device.originalName))
  }
  private func shot(_ shot: Shot) -> some View {
    let rotation = shot.rotation
    let selected = !model.guides.automaticRotation && model.guides.rotation == rotation
    return Button { model.setRotation(rotation) } label: {
      VStack(spacing: Space.xs) {
        ShotGlyph(rotation: rotation)
        Text(shot.title).cardTitle().multilineTextAlignment(.center)
        Text(shot.detail).cardCaption().multilineTextAlignment(.center)
      }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }.buttonStyle(.plain).modifier(ChoiceTileStyle(selected: selected, minHeight: 96))
      .accessibilityLabel("\(shot.title), \(shot.detail)")
      .accessibilityValue(selected ? "Selected" : "Not selected").accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Camera and Shot tiles share one height, radius and selection style.
struct ChoiceTileStyle: ViewModifier {
  var selected: Bool
  var minHeight: CGFloat = 120
  var showsBadge = true
  func body(content: Content) -> some View {
    content.frame(maxWidth: .infinity, minHeight: minHeight).modifier(InputCardStyle(selected: selected, showsBadge: showsBadge))
  }
}

/// A picture frame turned the way the camera is, with an arrow to the side that is the top, so the three
/// shots cannot be mistaken for each other.
private struct ShotGlyph: View {
  let rotation: CameraRotation
  private var portrait: Bool { rotation == .quarter || rotation == .threeQuarters }
  private var topTurn: Angle {
    switch rotation { case .none: .degrees(0); case .quarter: .degrees(-90); case .half: .degrees(180); case .threeQuarters: .degrees(90) }
  }
  var body: some View {
    let size = portrait ? CGSize(width: 36, height: 52) : CGSize(width: 52, height: 36) // grid: ok glyph drawing
    RoundedRectangle(cornerRadius: 6).stroke(.primary, lineWidth: 2).frame(width: size.width, height: size.height) // grid: ok glyph drawing
      .overlay { Image(systemName: "arrow.up.to.line").font(.system(size: 20, weight: .bold)).rotationEffect(topTurn) } // grid: ok glyph drawing
      .frame(height: 56).accessibilityHidden(true) // grid: ok glyph drawing
  }
}

/// Tiles in rows of `columns` that all keep the same width and, per row, the same height. The column count
/// follows the room offered, never the text, so a long camera name does not change the layout.
struct ChoiceTiles<Item: Identifiable, Tile: View>: View {
  let items: [Item]
  let columns: Int
  var minTileWidth: CGFloat = 120
  @ViewBuilder var tile: (Item) -> Tile
  @State private var width: CGFloat = 10_000
  var body: some View {
    let fitting = max(1, min(columns, Int((width + AlphaStyle.controlGap) / (minTileWidth + AlphaStyle.controlGap))))
    grid(fitting).onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
  }
  private func grid(_ columns: Int) -> some View {
    // fixedSize below: rows take their content's height even where a parent offers a tall, bounded space.
    Grid(horizontalSpacing: AlphaStyle.controlGap, verticalSpacing: AlphaStyle.controlGap) {
      ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
        GridRow {
          ForEach(items[start..<min(start + columns, items.count)]) { tile($0).frame(maxHeight: .infinity) }
          // An empty cell keeps a short last row at the same tile width.
          if start + columns > items.count { ForEach(0..<(start + columns - items.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, minHeight: 0) } }
        }
      }
    }.fixedSize(horizontal: false, vertical: true)
  }
}
