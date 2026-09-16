@preconcurrency import AVFoundation
import AppKit

/// The live picture with its guides, shared by the Camera window and the presenter's video
/// background. Both take their frames from `SharedCameraSession`, so the device is opened once;
/// each one has its own preview layer, which is what AVFoundation expects.
///
/// Three layers, all of them `CAShapeLayer` or `AVCaptureVideoPreviewLayer`: rotation is a layer
/// transform or a connection angle, guides and the frame marker are stroked paths, and the
/// shading outside the marker is one even-odd fill. Nothing here runs per frame.
final class CameraStageView: NSView {
  private let preview = AVCaptureVideoPreviewLayer()
  private let shade = CAShapeLayer()
  /// Internal for the geometry test.
  let guideLayer = CAShapeLayer()
  private var guides = CameraGuides()
  private var mirrored = false
  private var uid: String?
  /// True while the connection turns the picture itself; otherwise the layer transform does.
  /// Internal so the geometry test can stand in for a camera connection.
  var rotatesInConnection = false
  private var holding = false
  private var visibility: NSKeyValueObservation?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    preview.session = SharedCameraSession.shared.session
    preview.videoGravity = .resizeAspect
    shade.fillRule = .evenOdd
    shade.strokeColor = nil
    guideLayer.fillColor = nil
    guideLayer.lineWidth = 1
    layer?.addSublayer(preview)
    layer?.addSublayer(shade)
    layer?.addSublayer(guideLayer)
  }
  required init?(coder: NSCoder) { nil }

  func apply(uid: String?, guides: CameraGuides, mirrored: Bool) {
    // Before the guard: `select` ignores a camera it already has, and retries one it could not
    // open yet (no camera access at the time).
    SharedCameraSession.shared.select(uid)
    let changed = uid != self.uid || guides != self.guides || mirrored != self.mirrored
    guard changed else { return }
    self.uid = uid
    self.guides = guides
    self.mirrored = mirrored
    updateAutoOrientation()
    applyConnection()
    needsLayout = true
  }

  /// Mirroring and, where this macOS offers it, the rotation itself both belong to the
  /// connection. The layer transform is the fallback for a connection that will not take the
  /// angle, or that does not exist yet: the first view is made before the camera is attached.
  private func applyConnection() {
    var rotates = false
    if let connection = preview.connection {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = mirrored
      let angle = CGFloat(guides.rotation.rawValue)
      rotates = connection.isVideoRotationAngleSupported(angle)
      connection.videoRotationAngle = rotates ? angle : 0
    }
    // A connection that starts turning after the last layout would turn the picture twice.
    guard rotates != rotatesInConnection else { return }
    rotatesInConnection = rotates
    needsLayout = true
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Where the picture lands follows from its size, its turn and the bounds, never from the
    // preview layer: its own video rectangle is empty until the first frame and lags a resize,
    // which left 0.8.1's guides spread over the whole window.
    let aspect = SharedCameraSession.shared.pictureSize ?? CGSize(width: 16, height: 9)
    let picture = guides.rotation.fittedRect(aspect: aspect, in: bounds)
    if rotatesInConnection {
      preview.setAffineTransform(.identity)
      preview.frame = bounds
    } else {
      Self.place(preview, on: picture, turnedBy: guides.rotation)
    }
    // Sublayers do not inherit the window's scale: at 1x a hairline on a Retina screen blurs.
    let scale = window?.backingScaleFactor ?? 1
    for shape in [shade, guideLayer] {
      shape.frame = bounds
      shape.contentsScale = scale
    }
    guideLayer.strokeColor = guides.strokeColor
    shade.fillColor = guides.shadeColor
    guideLayer.path = CameraOverlay.guidePath(picture: picture, guides: guides)
    shade.path = CameraOverlay.shadePath(picture: picture, guides: guides)
    CATransaction.commit()
  }

  /// Lays the layer out unturned, then turns it about its own centre: it lands exactly on the
  /// aspect-fitted `picture`, so a turned 16:9 feed shows as 9:16 with nothing cropped. The
  /// camera picker's thumbnail uses it too.
  static func place(_ layer: CALayer, on picture: CGRect, turnedBy rotation: CameraRotation) {
    layer.bounds = CGRect(
      origin: .zero,
      size: rotation.swapsAxes ? CGSize(width: picture.height, height: picture.width) : picture.size)
    layer.position = CGPoint(x: picture.midX, y: picture.midY)
    layer.setAffineTransform(CGAffineTransform(rotationAngle: rotation.radians))
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }

  /// A window that is ordered out, closed or minimised holds nothing: a 4K capture is not free,
  /// and with both windows showing the camera the session is still opened only once.
  func setHolding(_ on: Bool) {
    guard on != holding else { return }
    holding = on
    if on {
      SharedCameraSession.shared.retain()
    } else {
      SharedCameraSession.shared.release()
    }
    updateAutoOrientation()
    if on { applyConnection() }
  }

  /// The handler names no view: the detector outlives whichever view created it, and capturing
  /// that view kept it, and its preview layer on the running session, alive.
  private func updateAutoOrientation() {
    SharedCameraSession.shared.setAutoOrientation(guides.automaticRotation && holding, for: self) { rotation in
      Task { @MainActor in CameraModel.shared.setRotation(rotation, automatic: true) }
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // `isVisible` changes the moment a window is ordered in or out (present, close, minimise,
    // orderOut) and reports it through KVO. The occlusion report comes 20–300 ms later, and in
    // 0.8.1 it said "hidden" for a presenter on screen, so a view added then held nothing and
    // showed no picture.
    // ponytail: a fully covered window keeps capturing; bring occlusion back as a release-only
    // hint if that CPU ever matters.
    visibility = window?.observe(\.isVisible, options: .initial) { [weak self] window, _ in
      MainActor.assumeIsolated { self?.setHolding(window.isVisible) }
    }
    if window == nil { setHolding(false) }
  }

  func stop() {
    visibility = nil
    setHolding(false)
  }
}
