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
        Text("Pick the camera, then make the picture upright. Remembered for each camera.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ChoiceTiles(items: devices, columns: 2, minTileWidth: 160) { device in
          let info = sourceInfo(device)
          let selected = device.uid == model.selectedUID
          let lines = [info.connectionDescription, info.videoFormat].compactMap { $0 }
          let detail = lines.joined(separator: ", ")
          ZStack(alignment: .top) {
            Button { model.selectedUID = device.uid } label: { Color.clear.contentShape(Rectangle()) }
              .buttonStyle(.plain)
              .accessibilityLabel(device.displayName).accessibilityValue(detail)
              .accessibilityAddTraits(selected ? .isSelected : [])
            VStack(spacing: Space.xs) {
              Image(systemName: "video").font(.title2).frame(height: 32).allowsHitTesting(false)
              HStack(spacing: Space.xs) {
                Text(device.displayName).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                  .fixedSize(horizontal: false, vertical: true).allowsHitTesting(false)
                Button { renaming = device; nickname = device.nickname ?? "" } label: {
                  Image(systemName: "pencil").frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                  .accessibilityLabel("Rename \(device.displayName)").help("Rename this camera")
              }
              ForEach(lines, id: \.self) { line in
                Text(line).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                  .lineLimit(2).fixedSize(horizontal: false, vertical: true).allowsHitTesting(false)
              }
            }.accessibilityElement(children: .contain)
          }.modifier(ChoiceTileStyle(selected: selected))
        }.accessibilityElement(children: .contain).accessibilityLabel("Camera selection")
        }
        if showsShotHeading { Text("Shot").font(.system(size: 17, weight: .semibold)) }
        ChoiceTiles(items: Self.shots, columns: 3) { shot($0) }
          .accessibilityElement(children: .contain).accessibilityLabel("Shot")
        Text("If you are on your side, pick the other Vertical.").font(.callout).foregroundStyle(.secondary)
        DisclosureGroup(isExpanded: $advancedOpen) {
          advancedControls
        } label: { Text("Advanced").font(.system(size: 17, weight: .semibold)).frame(minHeight: AlphaStyle.minTarget) }
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
      HStack {
        Text("Automatic")
        Spacer()
        Toggle("Automatic", isOn: Binding(get: { model.guides.automaticRotation }, set: { model.guides.automaticRotation = $0 }))
          .labelsHidden().toggleStyle(.switch)
      }.frame(minHeight: AlphaStyle.minTarget)
    }
  }
  private struct Shot: Identifiable {
    let id: String, title: String, detail: String, rotation: CameraRotation
  }
  private static let shots = [
    Shot(id: "none", title: "Landscape", detail: "As it comes", rotation: .none),
    Shot(id: "quarter", title: "Vertical", detail: "Turned left", rotation: .quarter),
    Shot(id: "threeQuarters", title: "Vertical", detail: "Turned right", rotation: .threeQuarters)]
  private static let upsideDown = Shot(id: "half", title: "Upside down", detail: "Turned over", rotation: .half)
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
        ZStack(alignment: .topTrailing) {
          Image(systemName: rotation == .quarter || rotation == .threeQuarters ? "rectangle.portrait" : "rectangle")
            .font(.title2)
          if rotation != .none {
            Image(systemName: rotation == .half ? "arrow.uturn.down" : rotation == .quarter ? "arrow.turn.up.left" : "arrow.turn.up.right").font(.caption.bold()).offset(x: Space.sm, y: -Space.xs)
          }
        }.frame(height: 32)
        Text(shot.title).font(.headline).frame(minHeight: 32)
        Text(shot.detail).font(.callout).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }.buttonStyle(.plain).modifier(ChoiceTileStyle(selected: selected))
      .accessibilityLabel("\(shot.title), \(shot.detail)")
      .accessibilityValue(selected ? "Selected" : "Not selected").accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Camera and Shot tiles share one height, radius and selection style.
struct ChoiceTileStyle: ViewModifier {
  var selected: Bool
  func body(content: Content) -> some View {
    content.frame(maxWidth: .infinity, minHeight: 120).modifier(InputCardStyle(selected: selected))
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
