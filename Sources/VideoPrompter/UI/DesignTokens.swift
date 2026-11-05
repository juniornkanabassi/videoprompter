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
  static let body = Font.body
  static let secondary = Font.callout
  static let caption = Font.caption
  static let heading = Font.headline
}
