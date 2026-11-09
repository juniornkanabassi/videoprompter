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
        VStack(spacing: AlphaStyle.controlGap) {
        ForEach(devices) { device in
          let info = sourceInfo(device)
          let selected = device.uid == model.selectedUID
          HStack(alignment: .center, spacing: Space.sm) {
            Button { model.selectedUID = device.uid } label: {
              HStack(spacing: Space.sm) {
                Image(systemName: "video")
                VStack(alignment: .leading, spacing: Space.xs) {
                  Text(device.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
                  Text(info.connectionDescription).font(.callout).foregroundStyle(.secondary)
                  if let format = info.videoFormat {
                    Text(format).font(.callout).foregroundStyle(.secondary)
                  }
                }
                Spacer(minLength: 0)
              }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(device.displayName)
              .accessibilityValue([info.connectionDescription, info.videoFormat].compactMap { $0 }.joined(separator: ", "))
              .accessibilityAddTraits(selected ? .isSelected : [])
            Button("Rename") { renaming = device; nickname = device.nickname ?? "" }
              .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
              .frame(minWidth: AlphaStyle.minTarget, minHeight: AlphaStyle.minTarget)
              .padding(.top, Space.md)
          }.padding(Space.sm).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
            .overlay(alignment: .topTrailing) { selectionBadge(selected) }
        }
        }.accessibilityElement(children: .contain).accessibilityLabel("Camera selection")
        }
        if showsShotHeading { Text("Shot").font(.system(size: 17, weight: .semibold)) }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: AlphaStyle.controlGap) { shotCards }
          VStack(spacing: AlphaStyle.controlGap) { shotCards }
        }.accessibilityElement(children: .contain).accessibilityLabel("Shot")
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
      shot("Upside down", detail: "Turned over", icon: "rotate.right", rotation: .half)
      HStack {
        Text("Automatic")
        Spacer()
        Toggle("Automatic", isOn: Binding(get: { model.guides.automaticRotation }, set: { model.guides.automaticRotation = $0 }))
          .labelsHidden().toggleStyle(.switch)
      }.frame(minHeight: AlphaStyle.minTarget)
    }
  }
  @ViewBuilder private var shotCards: some View {
          shot("Landscape", detail: "As it comes", icon: "rectangle", rotation: .none)
          shot("Vertical", detail: "Turned left", icon: "rotate.left", rotation: .quarter)
          shot("Vertical", detail: "Turned right", icon: "rotate.right", rotation: .threeQuarters)
  }
  private func sourceInfo(_ device: CameraDevice) -> CameraSourceInfo {
    if let info = sourceInfoOverride?[device.uid] { return info }
    if device.uid == model.selectedUID, let info = model.sourceInfo { return info }
    if devicesOverride == nil, let capture = AVCaptureDevice(uniqueID: device.uid) {
      return CameraSourceInfo(device: capture, displayName: device.displayName, useMaximumFrameRate: true)
    }
    return CameraSourceInfo(displayName: device.displayName, connection: .classify(deviceType: "", transportType: 0, manufacturer: "", modelID: "", name: device.originalName))
  }
  @ViewBuilder private func selectionBadge(_ selected: Bool) -> some View {
    if selected {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(AlphaStyle.accent)
        .padding(Space.xs).accessibilityHidden(true)
    }
  }
  private func shot(_ title: String, detail: String, icon: String, rotation: CameraRotation) -> some View {
    let selected = !model.guides.automaticRotation && model.guides.rotation == rotation
    return Button { model.setRotation(rotation) } label: {
      VStack(spacing: Space.sm) {
        ZStack(alignment: .topTrailing) {
          Image(systemName: rotation == .quarter || rotation == .threeQuarters ? "rectangle.portrait" : "rectangle")
            .font(.title2)
          if rotation != .none {
            Image(systemName: rotation == .half ? "arrow.uturn.down" : rotation == .quarter ? "arrow.turn.up.left" : "arrow.turn.up.right").font(.caption.bold()).offset(x: Space.sm, y: -Space.xs)
          }
        }.frame(height: 32)
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }.padding(.horizontal, Space.sm).frame(minWidth: 120, maxWidth: .infinity, minHeight: 112)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Space.md))
        .overlay(RoundedRectangle(cornerRadius: Space.md).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
        .overlay(alignment: .topTrailing) { selectionBadge(selected) }
    }.buttonStyle(.plain).accessibilityValue(selected ? "Selected" : "Not selected").accessibilityAddTraits(selected ? .isSelected : [])
  }
}
