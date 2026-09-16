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
  private let guideLayer = CAShapeLayer()
  private var guides = CameraGuides()
  private var mirrored = false
  private var uid: String?
  /// True while the connection turns the picture itself, which also turns the rectangle
  /// `layerRectConverted` reports, so the guides follow without a second calculation.
  private var rotatesInConnection = false
  private var holding = false
  private var windowObservers: [NSObjectProtocol] = []
  /// Where an automatic rotation goes when Vision picks one.
  var onAutoRotation: ((CameraRotation) -> Void)?

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
    SharedCameraSession.shared.setAutoOrientation(guides.automaticRotation && holding, for: self) { rotation in
      Task { @MainActor [weak self] in self?.onAutoRotation?(rotation) }
    }
    guideLayer.strokeColor = guides.strokeColor
    shade.fillColor = guides.shadeColor
    applyConnection()
    needsLayout = true
  }

  /// Mirroring and, where this macOS offers it, the rotation itself both belong to the
  /// connection. The layer transform is the fallback for a connection that will not take the
  /// angle.
  private func applyConnection() {
    guard let connection = preview.connection else {
      rotatesInConnection = false
      return
    }
    connection.automaticallyAdjustsVideoMirroring = false
    connection.isVideoMirrored = mirrored
    let angle = CGFloat(guides.rotation.rawValue)
    rotatesInConnection = connection.isVideoRotationAngleSupported(angle)
    if rotatesInConnection { connection.videoRotationAngle = angle }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let picture: CGRect
    preview.setAffineTransform(.identity)
    if rotatesInConnection {
      preview.frame = bounds
      let video = preview.layerRectConverted(
        fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
      picture = video.isEmpty ? bounds : video
    } else {
      // Lay the layer out unturned, then turn it about its own centre: it lands exactly on the
      // aspect-fitted rectangle, so a turned 16:9 feed shows as 9:16 with nothing cropped.
      let aspect = SharedCameraSession.shared.pictureSize ?? CGSize(width: 16, height: 9)
      let fitted = guides.rotation.fittedRect(aspect: aspect, in: bounds)
      preview.bounds = CGRect(
        origin: .zero,
        size: guides.rotation.swapsAxes
          ? CGSize(width: fitted.height, height: fitted.width) : fitted.size)
      preview.position = CGPoint(x: fitted.midX, y: fitted.midY)
      preview.setAffineTransform(CGAffineTransform(rotationAngle: guides.rotation.radians))
      picture = fitted
    }
    guideLayer.frame = bounds
    shade.frame = bounds
    guideLayer.path = CameraOverlay.guidePath(picture: picture, guides: guides)
    shade.path = CameraOverlay.shadePath(picture: picture, guides: guides)
    CATransaction.commit()
  }

  /// A window that is closed, minimised or fully covered holds nothing: a 4K capture is not free,
  /// and with both windows showing the camera the session is still opened only once.
  func setHolding(_ on: Bool) {
    guard on != holding else { return }
    holding = on
    if on {
      SharedCameraSession.shared.retain()
    } else {
      SharedCameraSession.shared.release()
    }
    SharedCameraSession.shared.setAutoOrientation(guides.automaticRotation && on, for: self) { rotation in
      Task { @MainActor [weak self] in self?.onAutoRotation?(rotation) }
    }
    if on { applyConnection() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers = []
    guard let window else {
      setHolding(false)
      return
    }
    for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
      windowObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self] note in
          MainActor.assumeIsolated {
            self?.setHolding(
              name == NSWindow.didChangeOcclusionStateNotification
                && (note.object as? NSWindow)?.occlusionState.contains(.visible) == true)
          }
        })
    }
    setHolding(window.occlusionState.contains(.visible))
  }

  deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }

  func stop() {
    setHolding(false)
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers = []
  }
}
