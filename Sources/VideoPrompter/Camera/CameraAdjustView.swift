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
    ScrollView {
      VStack(alignment: .leading, spacing: Space.md) {
        Text("Camera").font(.title2.bold())
        Text("Pick the camera, then make the picture upright. Remembered for each camera.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ForEach(devices) { device in
          HStack {
            Button { model.selectedUID = device.uid } label: {
              HStack(spacing: Space.sm) {
                Image(systemName: "video")
                VStack(alignment: .leading) {
                  Text(device.displayName).font(.headline)
                  Text(detail(device)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if device.uid == model.selectedUID { Image(systemName: "checkmark").foregroundStyle(.yellow) }
              }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button("Rename") { renaming = device; nickname = device.nickname ?? "" }.frame(minHeight: 44)
          }.padding(Space.sm).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Space.md))
        }
        Text("SHOT").font(.caption.bold()).foregroundStyle(.secondary)
        HStack(spacing: Space.sm) {
          shot("Landscape", detail: "As it comes", icon: "rectangle", rotation: .none)
          shot("Vertical", detail: "Turned left", icon: "rotate.left", rotation: .quarter)
          shot("Vertical", detail: "Turned right", icon: "rotate.right", rotation: .threeQuarters)
        }
        Text("If you are on your side, pick the other Vertical.").font(.callout).foregroundStyle(.secondary)
        DisclosureGroup("Advanced") {
          Button("Upside down") { model.setRotation(.half) }.frame(minHeight: 44)
          Button("Automatic") { model.guides.automaticRotation = true }.frame(minHeight: 44)
        }
      }.padding(Space.md)
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
  private func detail(_ device: CameraDevice) -> String {
    if device.uid == model.selectedUID, let info = model.sourceInfo { return info.summary.replacingOccurrences(of: info.displayName + " · " + info.connection.rawValue, with: info.connectionDescription) }
    if let capture = AVCaptureDevice(uniqueID: device.uid) {
      let info = CameraSourceInfo(device: capture, displayName: device.displayName)
      return info.summary.replacingOccurrences(of: info.displayName + " · " + info.connection.rawValue, with: info.connectionDescription)
    }
    return CameraSourceInfo.ConnectionKind.classify(deviceType: "", transportType: 0, manufacturer: "", modelID: "", name: device.originalName).rawValue
  }
  private func shot(_ title: String, detail: String, icon: String, rotation: CameraRotation) -> some View {
    let selected = !model.guides.automaticRotation && model.guides.rotation == rotation
    return Button { model.setRotation(rotation) } label: {
      VStack(spacing: Space.sm) {
        Image(systemName: icon).font(.title2)
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, minHeight: 112)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Space.md))
        .overlay(RoundedRectangle(cornerRadius: Space.md).stroke(selected ? Color.yellow : .clear, lineWidth: 2))
    }.buttonStyle(.plain).accessibilityValue(selected ? "Selected" : "")
  }
}
