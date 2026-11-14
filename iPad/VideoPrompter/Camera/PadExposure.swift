@preconcurrency import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// Capture and decode queues submit at most one pending analysis frame. The picture never waits
/// for the aids, and an overloaded device discards analysis work rather than accumulating delay.
final class PadExposure: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  let queue = DispatchQueue(label: "VideoPrompter.padExposure", qos: .userInitiated)
  private let slot = DispatchSemaphore(value: 1)
  private let processor = CameraExposure(settings: .init(), onFrame: { _ in })
  private var settings = CameraExposure.Settings()
  @MainActor private(set) var frame = CameraExposure.Frame()
  static let changed = Notification.Name("VideoPrompter.padExposureChanged")

  func update(_ value: CameraExposure.Settings) {
    queue.async {
      self.settings = value
      if !value.isOn { self.publish(.init()) }
    }
  }
  private func publish(_ frame: CameraExposure.Frame, releaseSlot: Bool = false) {
    Task { @MainActor in
      defer { if releaseSlot { self.slot.signal() } }
      self.frame = frame
      NotificationCenter.default.post(name: Self.changed, object: self)
    }
  }
  func receive(_ pixels: CVPixelBuffer) {
    guard slot.wait(timeout: .now()) == .success else { return }
    queue.async {
      guard self.settings.isOn else { self.slot.signal(); return }
      // Full-range Y' is the Mac's exact input; Core Image normalises other decoded formats.
      let frame = self.processor.processDecoded(pixels, settings: self.settings)
      self.publish(frame, releaseSlot: true)
    }
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { receive(pixels) }
  }
}

/// Same stripe path, thickness, black/white fill and LUT images as CameraStageView on the Mac.
@MainActor final class PadExposureLayer: CALayer {
  private let colour = CALayer()
  private let stripes = CAShapeLayer()
  private let maskImage = CALayer()
  private weak var feed: PadExposure?
  private var settings = CameraExposure.Settings()

  override init() {
    super.init()
    MainActor.assumeIsolated {
    addSublayer(colour)
    addSublayer(stripes)
    stripes.fillColor = nil
    stripes.strokeColor = UIColor.black.cgColor
    stripes.backgroundColor = UIColor.white.cgColor
    stripes.mask = maskImage
    masksToBounds = true
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  override init(layer: Any) { super.init(layer: layer) }

  func bind(_ feed: PadExposure, settings: CameraExposure.Settings) {
    if self.feed !== feed {
      NotificationCenter.default.removeObserver(self)
      self.feed = feed
      NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: PadExposure.changed, object: feed)
    }
    self.settings = settings
    refresh()
  }
  @objc private func refresh() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    colour.contents = settings.falseColour ? feed?.frame.falseColour : nil
    maskImage.contents = settings.zebras ? feed?.frame.zebraMask : nil
    stripes.isHidden = !settings.zebras || feed?.frame.zebraMask == nil
    CATransaction.commit()
  }
  override func layoutSublayers() {
    super.layoutSublayers()
    colour.frame = bounds
    stripes.frame = bounds
    maskImage.frame = bounds
    stripes.path = CameraOverlay.zebraPath(picture: bounds)
    stripes.lineWidth = CameraOverlay.zebraLineWidth(picture: bounds)
  }
  deinit { NotificationCenter.default.removeObserver(self) }
}

/// Offscreen reference frames pass through the production processor and stripe geometry too.
struct ExposureReferencePicture: UIViewRepresentable {
  let image: UIImage
  let guides: CameraGuides
  func makeUIView(context: Context) -> ReferenceView { ReferenceView() }
  func updateUIView(_ view: ReferenceView, context: Context) { view.update(image, guides: guides) }
  final class ReferenceView: UIView {
    private let picture = CALayer()
    private let exposure = PadExposureLayer()
    private let feed = PadExposure()
    private var imageSize = CGSize(width: 16, height: 9)
    private var rotation = CameraRotation.none
    private var guides = CameraGuides()
    private let guideLayer = CAShapeLayer()
    private let shadeLayer = CAShapeLayer()
    override init(frame: CGRect) {
      super.init(frame: frame)
      picture.cornerRadius = AlphaStyle.cardCorner
      picture.masksToBounds = true
      exposure.cornerRadius = AlphaStyle.cardCorner
      layer.addSublayer(picture)
      layer.addSublayer(exposure)
      guideLayer.fillColor = nil
      guideLayer.lineWidth = 1.5
      shadeLayer.fillRule = .evenOdd
      layer.addSublayer(shadeLayer)
      layer.addSublayer(guideLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func update(_ image: UIImage, guides: CameraGuides) {
      picture.contents = image.cgImage
      imageSize = image.size
      rotation = guides.rotation
      self.guides = guides
      exposure.bind(feed, settings: guides.exposure)
      feed.update(guides.exposure)
      if let cg = image.cgImage {
        // Same queue as live frames; fixtures alone provide a still CIImage.
        feed.reference(CIImage(cgImage: cg))
      }
      setNeedsLayout()
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      let rect = rotation.fittedRect(aspect: imageSize, in: bounds)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for target in [picture, exposure] {
        target.setAffineTransform(.identity)
        target.bounds = CGRect(origin: .zero, size: rotation.swapsAxes ? CGSize(width: rect.height, height: rect.width) : rect.size)
        target.position = CGPoint(x: rect.midX, y: rect.midY)
        target.setAffineTransform(rotation.displayTransform(mirrored: false))
      }
      guideLayer.frame = bounds
      shadeLayer.frame = bounds
      guideLayer.path = CameraOverlay.guidePath(picture: rect, guides: guides)
      guideLayer.strokeColor = guides.strokeColor
      shadeLayer.path = guides.marker == nil ? nil : CameraOverlay.shadePath(picture: rect, guides: guides)
      shadeLayer.fillColor = guides.shadeColor
      CATransaction.commit()
    }
  }
}

extension PadExposure {
  fileprivate func reference(_ image: CIImage) {
    queue.async { self.publish(self.processor.process(image: image, settings: self.settings)) }
  }
}
