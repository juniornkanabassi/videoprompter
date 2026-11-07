import SwiftUI

/// The four-point spacing scale for application chrome, independent of script typography.
enum Space {
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 20
  static let xxl: CGFloat = 24
  static let section: CGFloat = 32
  static let margin: CGFloat = 20
}

/// Native text styles scale with accessibility settings. Script fonts remain user-controlled.
enum UIType {
  static let title = Font.title2.weight(.semibold)
  static let body = Font.body
  static let secondary = Font.callout
  static let caption = Font.caption
  static let heading = Font.headline
}

/// Opaque presenter chrome stays dark over every possible camera picture.
enum Surfaces {
  static let presenterPanel = Color(nsColor: NSColor(name: nil) { appearance in
    let increased = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
    return NSColor(white: increased == .accessibilityHighContrastAqua || increased == .accessibilityHighContrastDarkAqua ? 0.08 : 0.12, alpha: 1)
  })
  static let scrim = Color.black.opacity(0.9)
}

enum Palette {
  static func onDarkQuiet(_ contrast: ColorSchemeContrast) -> Color {
    .white.opacity(contrast == .increased ? 1 : 0.8)
  }
  static func quietOpacity(_ contrast: ColorSchemeContrast) -> Double {
    contrast == .increased ? 1 : 0.75
  }
}
