import SwiftUI

// The exposure adjustment panels, shared by the Mac and the iPad.

#if os(macOS)
typealias ExposureHost = CameraModel
#else
/// The iPad has no CameraModel: these panels edit their guides binding alone, so the Mac's model
/// hooks (no case, so never called) exist only to keep one body for both platforms.
enum ExposureHost {
  func exposureBinding(_ key: WritableKeyPath<CameraGuides, Bool>) -> Binding<Bool> { switch self {} }
  func zebraBinding<T>(_ key: WritableKeyPath<CameraGuides, T>) -> Binding<T> { switch self {} }
  func chooseZebraPreset(_ purpose: CameraGuides.ZebraPurpose) { switch self {} }
  func setGreyCardCheck(_ enabled: Bool) { switch self {} }
  var effectiveGuides: CameraGuides { switch self {} }
  var exposureControls: Binding<CameraGuides> { switch self {} }
}
#endif

private func announceGreyCardEnded() {
  #if os(macOS)
  NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: "Grey card check ended.", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  #else
  UIAccessibility.post(notification: .announcement, argument: "Grey card check ended.")
  #endif
}

/// Use the renderer's ranges, so the detailed key cannot drift from its colours.
struct FalseColourKey: View {
  var settings = CameraExposure.Settings()
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("False colour").fontWeight(.semibold)
      ForEach(Array(settings.legendBands.enumerated()), id: \.offset) { _, band in
        HStack {
          Rectangle().fill(Color(red: Double(band.colour & 255)/255, green: Double((band.colour >> 8) & 255)/255, blue: Double((band.colour >> 16) & 255)/255)).frame(width: 32, height: 24)
          VStack(alignment: .leading) {
            Text(band.label).font(.system(size: 17, weight: .semibold))
            Text(band.range + " IRE").font(.system(size: 15)).monospacedDigit().foregroundStyle(.secondary)
          }
          Spacer()
        }.accessibilityElement(children: .ignore)
          .accessibilityLabel(band.label).accessibilityValue(band.range + " IRE")
      }
      Text("Everything else shows in grey. Measured from the incoming picture.")
    }.font(.callout).fixedSize(horizontal: false, vertical: true)
  }
}

struct ZebraAdjustView: View {
  @Binding var guides: CameraGuides
  var model: ExposureHost? = nil
  @Environment(\.dynamicTypeSize) private var typeSize
  init(guides: Binding<CameraGuides>, model: ExposureHost? = nil) {
    self._guides = model?.exposureControls ?? guides
    self.model = model
  }
  #if os(macOS)
  init(model: CameraModel) {
    self.init(guides: model.exposureControls, model: model)
  }
  #endif
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("Zebras").font(.title2.bold()); Spacer(); Toggle("Zebras", isOn: model?.exposureBinding(\.zebras) ?? $guides.manualExposure(\.zebras)).labelsHidden().toggleStyle(.switch).frame(minWidth: AlphaStyle.minTarget, minHeight: AlphaStyle.minTarget) }.frame(minHeight: AlphaStyle.minTarget)
      Text("Stripes show where the picture is at a brightness you choose.").foregroundStyle(.secondary)
      if guides.greyCardCheck { Text("Grey card check on · Zebra target 41 ±2 IRE").font(.callout.bold()) }
      // At accessibility text sizes two cards side by side break words ("High-lights"), so they stack.
      let cards = Group {
        preset("My skin", detail: "Range · \(guides.skinReference.level) ±\(guides.skinReference.range) IRE", description: "Is my face exposed right?", purpose: .faceReference)
        preset("Highlights", detail: "Limit · 95 IRE and up", description: "Is anything too bright?", purpose: .brightAreas)
      }
      if typeSize.isAccessibilitySize { VStack(spacing: AlphaStyle.controlGap) { cards } }
      else { Grid(horizontalSpacing: AlphaStyle.controlGap, verticalSpacing: AlphaStyle.controlGap) { GridRow { cards } } }
      HStack(spacing: 4) {
        ForEach([true, false], id: \.self) { range in
          Button(range ? "Range" : "Limit") { (model?.zebraBinding(\.zebraRangeMode) ?? $guides.manualExposure(\.zebraRangeMode)).wrappedValue = range }
            .buttonStyle(.plain).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(guides.zebraRangeMode == range ? AlphaStyle.onAccent : .primary)
            .background(guides.zebraRangeMode == range ? AlphaStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityAddTraits(guides.zebraRangeMode == range ? .isSelected : [])
        }
      }.padding(4).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
      ExposureNumberRow(title: "Level", subject: "zebra level", subtitle: "Centre of the stripes", value: (model?.zebraBinding(\.zebraLevel) ?? $guides.manualExposure(\.zebraLevel)), limits: 0...100, suffix: " IRE")
      if guides.zebraRangeMode { ExposureNumberRow(title: "Plus or minus", subject: "zebra range", subtitle: "How wide the band is", value: (model?.zebraBinding(\.zebraRange) ?? $guides.manualExposure(\.zebraRange)), limits: 1...10, prefix: "±") }
      HStack(spacing: 12) {
        PresenterZebraSwatch().frame(width: 44, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
        Text(effectiveExposure.exposure.zebraReadout).font(.system(size: 17, weight: .semibold))
      }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
      Text("Each mode keeps its own values, so switching to Limit and back does not lose your range. Your skin colour in false colour is set separately.").font(.system(size: 14)).foregroundStyle(.secondary)
      Text("IRE measures brightness in the incoming picture, from 0 (black) to 100 (white).").font(.system(size: 14)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var effectiveExposure: CameraGuides { model?.effectiveGuides ?? guides }
  private func preset(_ title: String, detail: String, description: String, purpose: CameraGuides.ZebraPurpose) -> some View {
    let selected = guides.validatedZebraPurpose == purpose && !guides.greyCardCheck
    return Button {
      if let model { model.chooseZebraPreset(purpose) }
      else { guides.changeExposure { $0.useZebraPreset(purpose); $0.zebras = true } }
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline).padding(.trailing, Space.lg)
        Text(description).font(.callout)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: 2))
        .overlay(alignment: .topTrailing) { if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(AlphaStyle.accent).padding(Space.sm) } }
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct ExposureNumberRow: View {
  let title: String
  let subject: String
  var subtitle = ""
  @Binding var value: Int
  let limits: ClosedRange<Int>
  var prefix = ""
  var suffix = ""
  func accessibilityLabel(increasing: Bool) -> String {
    "\(increasing ? "Increase" : "Decrease") \(subject), currently \(value) IRE"
  }
  private var heading: some View {
    VStack(alignment: .leading) {
      Text(title).font(.system(size: 17, weight: .semibold))
      if !subtitle.isEmpty { Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary) }
    }.fixedSize(horizontal: false, vertical: true)
  }
  private var controls: some View {
    HStack {
      Button { value = max(limits.lowerBound, value - 1) } label: {
        Image(systemName: "minus").font(.system(size: 20)).frame(width: 46, height: 46) // grid: ok Match the 46 pt Adjust controls.
          .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      }.buttonStyle(.plain).accessibilityLabel(accessibilityLabel(increasing: false))
      HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
        Text("\(prefix)\(value)").font(.system(size: 30, weight: .semibold))
        Text("IRE").font(.system(size: 15)).foregroundStyle(.secondary)
      }.monospacedDigit().frame(minWidth: 100)
      Button { value = min(limits.upperBound, value + 1) } label: {
        Image(systemName: "plus").font(.system(size: 20)).frame(width: 46, height: 46) // grid: ok Match the 46 pt Adjust controls.
          .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      }.buttonStyle(.plain).accessibilityLabel(accessibilityLabel(increasing: true))
    }
  }
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack { heading; Spacer(); controls }.frame(minWidth: 420).fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: Space.sm) { heading; controls }
    }
  }
}

private struct TonePicture: View {
  let name: String
  var body: some View {
    let bundled = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "SkinTones")
    #if os(macOS)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fallback = root.appendingPathComponent("Resources/SkinTones/\(name).png")
    if let image = NSImage(contentsOf: bundled ?? fallback) {
      Image(nsImage: image).resizable().scaledToFill().clipped()
    } else {
      Color.gray
    }
    #else
    if let bundled, let image = UIImage(contentsOfFile: bundled.path) {
      Image(uiImage: image).resizable().scaledToFill().clipped()
    } else {
      Color.gray
    }
    #endif
  }
}

struct SkinTonePicker: View {
  @Binding var guides: CameraGuides

  init(guides: Binding<CameraGuides>) { self._guides = guides }
  #if os(macOS)
  init(model: CameraModel) { self._guides = model.exposureControls }
  #endif
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Skin tone").font(.headline)
      Text("Choose the face closest to your skin tone. Turn on False colour to check your skin in pink.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
        ForEach(CameraGuides.SkinTone.allCases, id: \.self) { tone in
          let selected = guides.skinTone == tone
          Button {
            if let reference = tone.reference { guides.skinReference = reference }
            guides.selectedSkinTone = tone
          } label: {
            VStack(spacing: 4) {
              Group {
                if tone == .custom {
                  Image(systemName: "slider.horizontal.3").font(.system(size: 28)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray.opacity(0.2))
                } else { TonePicture(name: tone.rawValue.lowercased()) }
              }.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
              Text(tone.rawValue).font(.system(size: 16, weight: .bold))
              if let ref = tone.reference { Text("\(ref.level) ±\(ref.range) IRE").font(.system(size: 14)) }
              else { Text("Set your own").font(.system(size: 14)) }
            }.frame(maxWidth: .infinity, minHeight: 112, alignment: .top).overlay(alignment: .topTrailing) { if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(AlphaStyle.accent) } }.padding(8)
              .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
              .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: 2))
          }.buttonStyle(.plain)
            .accessibilityLabel(tone.reference.map { "\(tone.rawValue) skin tone, \($0.level) plus or minus \($0.range) IRE" } ?? "Custom skin tone")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
      if guides.skinTone == .custom && !guides.greyCardCheck {
        ExposureNumberRow(title: "Level", subject: "skin reference level", value: Binding(get: { guides.skinReference.level }, set: { guides.skinReference.level = $0; guides.selectedSkinTone = .custom }), limits: 0...100, suffix: " IRE")
        ExposureNumberRow(title: "Plus or minus", subject: "skin reference range", value: Binding(get: { guides.skinReference.range }, set: { guides.skinReference.range = $0; guides.selectedSkinTone = .custom }), limits: 1...10, prefix: "±")
      }
      Text(guides.greyCardCheck ? "Green shows 38 to 43 IRE" : "Pink shows skin at \(max(0, guides.skinReference.level - guides.skinReference.range)) to \(min(100, guides.skinReference.level + guides.skinReference.range)) IRE")
        .font(.callout.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }.disabled(guides.greyCardCheck)
  }
}

struct FalseColourAdjustView: View {
  @Binding var guides: CameraGuides
  var model: ExposureHost? = nil
  init(guides: Binding<CameraGuides>, model: ExposureHost? = nil) {
    self._guides = model?.exposureControls ?? guides
    self.model = model
  }
  #if os(macOS)
  init(model: CameraModel) {
    self.init(guides: model.exposureControls, model: model)
  }
  #endif
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("False colour").font(.title2.bold()); Spacer(); Toggle("False colour", isOn: model?.exposureBinding(\.falseColour) ?? $guides.manualExposure(\.falseColour)).labelsHidden().toggleStyle(.switch).frame(minWidth: AlphaStyle.minTarget, minHeight: AlphaStyle.minTarget) }.frame(minHeight: AlphaStyle.minTarget)
      SkinTonePicker(guides: $guides)
      HStack(alignment: .top, spacing: 12) {
        TonePicture(name: "greycard").frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 8) {
          if !guides.greyCardCheck {
          HStack { Text("Grey card check").font(.headline); Spacer(); Toggle("Grey card check", isOn: Binding(get: { guides.greyCardCheck }, set: { value in
            if let model { model.setGreyCardCheck(value) } else { guides.greyCardCheck = value }
            if !value { announceGreyCardEnded() }
          })).labelsHidden().toggleStyle(.switch).frame(minWidth: AlphaStyle.minTarget, minHeight: AlphaStyle.minTarget) }.frame(minHeight: AlphaStyle.minTarget)
          }
          if guides.greyCardCheck {
            Text("Grey card check on · Zebra target 41 ±2 IRE").font(.callout.bold())
            Button("Finish grey card check") {
              if let model { model.setGreyCardCheck(false) } else { guides.greyCardCheck = false }
              announceGreyCardEnded()
            }.frame(minHeight: AlphaStyle.minTarget)
          }
          Text("Hold an 18% grey card where your face will be. Adjust exposure until the card turns green (Mid grey, 41 IRE). " + (guides.greyCardCheck ? "Choose Finish grey card check to go back to your skin settings." : "Turn this off to go back to your skin settings.")).font(.callout).foregroundStyle(.secondary)
        }
      }.padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
      FalseColourKey(settings: guides.exposure)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
