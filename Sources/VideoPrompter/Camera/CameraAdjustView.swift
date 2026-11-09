@preconcurrency import AVFoundation
import SwiftUI

/// Camera and shot controls for the presenter Adjust panel.
struct CameraAdjustView: View {
  @ObservedObject var model: CameraModel
  var devicesOverride: [CameraDevice]? = nil
  @State private var renaming: CameraDevice?
  @State private var nickname = ""
  private var devices: [CameraDevice] { devicesOverride ?? model.devices }

  var body: some View {
    VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
        Text("Camera").font(.title2.bold())
        Text("Pick the camera, then make the picture upright. Remembered for each camera.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(spacing: AlphaStyle.controlGap) {
        ForEach(devices) { device in
          HStack {
            Button { model.selectedUID = device.uid } label: {
              HStack(spacing: Space.sm) {
                Image(systemName: "video")
                VStack(alignment: .leading) {
                  Text(device.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
                  Text(detail(device)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if device.uid == model.selectedUID { Image(systemName: "checkmark").foregroundStyle(AlphaStyle.accent) }
              }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(device.uid == model.selectedUID ? .isSelected : [])
            Button("Rename") { renaming = device; nickname = device.nickname ?? "" }.frame(minWidth: AlphaStyle.minTarget, minHeight: AlphaStyle.minTarget)
          }.padding(Space.sm).background(device.uid == model.selectedUID ? AlphaStyle.selectedFill : .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner).stroke(device.uid == model.selectedUID ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
        }
        }.accessibilityElement(children: .contain).accessibilityLabel("Camera selection")
        Text("SHOT").font(.caption.bold()).foregroundStyle(.secondary)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: AlphaStyle.controlGap) { shotCards }.fixedSize(horizontal: true, vertical: false)
          VStack(spacing: AlphaStyle.controlGap) { shotCards }
        }.accessibilityElement(children: .contain).accessibilityLabel("Shot")
        Text("If you are on your side, pick the other Vertical.").font(.callout).foregroundStyle(.secondary)
        DisclosureGroup("Advanced") {
          shot("Upside down", detail: "Turned over", icon: "rotate.right", rotation: .half)
          Button("Automatic") { model.guides.automaticRotation = true }.frame(minHeight: 44)
            .accessibilityAddTraits(model.guides.automaticRotation ? .isSelected : [])
        }
    }
    .onAppear { if devicesOverride == nil { model.refreshDevices() } }
    .sheet(item: $renaming) { device in
      VStack(alignment: .leading, spacing: Space.md) {
        Text("Rename camera").font(.headline)
        TextField(device.originalName, text: $nickname)
        HStack { Button("Cancel") { renaming = nil }; Button("Save") { model.renameCamera(device.uid, to: nickname); renaming = nil } }
      }.padding(Space.md).frame(width: 320)
    }
  }
  @ViewBuilder private var shotCards: some View {
          shot("Landscape", detail: "As it comes", icon: "rectangle", rotation: .none)
          shot("Vertical", detail: "Turned left", icon: "rotate.left", rotation: .quarter)
          shot("Vertical", detail: "Turned right", icon: "rotate.right", rotation: .threeQuarters)
  }
  private func detail(_ device: CameraDevice) -> String {
    if device.uid == model.selectedUID, let info = model.sourceInfo { return info.formatDescription }
    if let capture = AVCaptureDevice(uniqueID: device.uid) {
      let info = CameraSourceInfo(device: capture, displayName: device.displayName)
      return info.formatDescription
    }
    return CameraSourceInfo.ConnectionKind.classify(deviceType: "", transportType: 0, manufacturer: "", modelID: "", name: device.originalName).rawValue
  }
  private func shot(_ title: String, detail: String, icon: String, rotation: CameraRotation) -> some View {
    let selected = !model.guides.automaticRotation && model.guides.rotation == rotation
    return Button { model.setRotation(rotation) } label: {
      VStack(spacing: Space.sm) {
        Image(systemName: icon).font(.title2)
        if selected { Image(systemName: "checkmark").foregroundStyle(AlphaStyle.accent) }
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }.padding(.horizontal, Space.sm).frame(minWidth: 120, maxWidth: .infinity, minHeight: 112)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Space.md))
        .overlay(RoundedRectangle(cornerRadius: Space.md).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
  }
}
