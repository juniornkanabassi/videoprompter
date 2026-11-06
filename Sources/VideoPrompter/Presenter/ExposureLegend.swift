import SwiftUI

/// Meaning stays beside the monitor, numeric calibration stays in detailed help.
struct ExposureGuidance: View {
  let zebras: Bool
  let face: Bool
  let falseColour: Bool

  static let colourMeanings = [
    "Purple: almost black. Detail may be lost in shadows.",
    "Blue: very dark. Brighten important shadow areas if you need to see detail.",
    "Green: a mid-tone reference, not a pass or fail for your face.",
    "Pink: a brighter mid-tone reference. Skin tones and camera profiles vary.",
    "Yellow: nearly white. Check that bright areas still show detail.",
    "Red: at the top of this feed's brightness range. Lower exposure if important areas lose detail."
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      if zebras {
        Text(face
          ? "Face brightness: your face should show stripes on the lit cheek."
          : "Stripes mark very bright areas. Lower exposure on your camera if important parts of the picture lose detail.")
        if face {
          Text("Standard video reference only. Skin tones vary; for log footage, follow your camera's guidance.")
        }
      }
      if falseColour {
        Text("Purple/blue: dark. Green/pink: mid-tones. Yellow/red: very bright. Open the key to judge each colour.")
      }
    }.font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
  }
}

struct ExposureLegend: View {
  @ObservedObject var model: CameraModel
  var body: some View {
    if model.exposureIsConfigured && !model.cleanView && !model.exposureBypassed {
      VStack(alignment: .leading, spacing: Space.xs) {
        if model.guides.zebras { Text("Zebras: " + (model.guides.zebraRange > 0 ? "face brightness, \(model.guides.zebraLevel) IRE ± \(model.guides.zebraRange)" : "bright areas, \(model.guides.zebraLevel) IRE and above")) }
        ExposureGuidance(zebras: model.guides.zebras, face: model.guides.zebraRange > 0,
          falseColour: model.guides.falseColour)
        if model.guides.falseColour {
          DisclosureGroup("False colour key") {
            ForEach(Array(CameraExposure.bands.enumerated()), id: \.offset) { index, band in
              Label { Text(ExposureGuidance.colourMeanings[index]) } icon: {
                Image(systemName: "square.fill").foregroundStyle(Color(red: Double(band.rgb.0)/255, green: Double(band.rgb.1)/255, blue: Double(band.rgb.2)/255))
              }
            }
          }
        }
      }.frame(maxWidth: 360, alignment: .leading).font(.callout).foregroundStyle(.primary).padding(Space.sm).modifier(PresenterGlass(radius: 12)).environment(\.colorScheme, .dark)
    }
  }
}
