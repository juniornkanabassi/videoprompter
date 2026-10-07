@preconcurrency import AVFoundation
import CoreGraphics
import Vision

/// How far the picture is turned for display. Cam B hands over a 3840x2160 landscape feed while
/// Junior physically shoots vertical, so 90° and 270° are the normal case rather than the
/// exception. The angle is counter-clockwise, which is what both
/// `CGAffineTransform(rotationAngle:)` in the preview layer's own space and
/// `AVCaptureConnection.videoRotationAngle` measure.
enum CameraRotation: Int, CaseIterable, Codable, Identifiable, Sendable {
  case none = 0, quarter = 90, half = 180, threeQuarters = 270
  var id: Int { rawValue }
  var label: String { "\(rawValue)°" }
  var radians: CGFloat { CGFloat(rawValue) * .pi / 180 }
  /// True when width and height swap on screen: a rotated 16:9 feed shows as 9:16.
  var swapsAxes: Bool { self == .quarter || self == .threeQuarters }
  /// The orientation to hand `VNImageRequestHandler` so that an upright face found there means
  /// this rotation is the one that puts the picture upright.
  var visionOrientation: CGImagePropertyOrientation {
    switch self {
    case .none: .up
    case .quarter: .right
    case .half: .down
    case .threeQuarters: .left
    }
  }

  /// Aspect-fit rectangle for a picture of `aspect` turned by this rotation inside `bounds`.
  /// Nothing is cropped: a rotated 16:9 feed shows as 9:16 with bars down the sides, and the
  /// composition guides are drawn on this rectangle so they turn with the picture.
  func fittedRect(aspect: CGSize, in bounds: CGRect) -> CGRect {
    guard aspect.width > 0, aspect.height > 0, !bounds.isEmpty else { return bounds }
    let shown = swapsAxes ? CGSize(width: aspect.height, height: aspect.width) : aspect
    let scale = min(bounds.width / shown.width, bounds.height / shown.height)
    return bounds.centred(CGSize(width: shown.width * scale, height: shown.height * scale))
  }
}

extension CGRect {
  /// A rectangle of `size` with the same centre as this one.
  func centred(_ size: CGSize) -> CGRect {
    CGRect(x: midX - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height)
  }
}

/// Auto orientation: one frame every couple of seconds through `VNDetectFaceRectanglesRequest`
/// in each of the four orientations, and the one with the most convincing upright face wins.
/// The data output is attached only while Auto is on and the window is showing; the rest of the
/// time the camera path stays preview-layer only, with no frame callbacks at all.
/// `@unchecked Sendable`: every member is touched on the session's serial queue only — the
/// sample-buffer callback, and `attach`/`detach`, which `SharedCameraSession` dispatches there.
final class CameraAutoOrientation: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  /// What one `VNFaceObservation` is worth to the choice, so the chooser can be tested without
  /// a camera or a Vision run.
  struct Face: Equatable, Sendable {
    let confidence: Float
    let boundingBox: CGRect
  }
  struct Candidate: Equatable, Sendable {
    let rotation: CameraRotation
    let confidence: Float
    let area: CGFloat
    /// Biggest and most confident together: either alone picks a wrong orientation too often.
    var score: Double { Double(confidence) * Double(area) }
  }

  /// The largest face Vision found at this orientation, or nothing when it found none.
  static func candidate(_ rotation: CameraRotation, faces: [Face]) -> Candidate? {
    faces.map { Candidate(rotation: rotation, confidence: $0.confidence, area: $0.boundingBox.width * $0.boundingBox.height) }
      .max { $0.area < $1.area }
  }

  /// A face found at a wrong orientation is either absent, small or unsure, so the product of
  /// confidence and area separates the upright one. Nothing convincing at all leaves the
  /// rotation where it is.
  static func bestRotation(among candidates: [Candidate], minimumConfidence: Float = 0.5)
    -> CameraRotation?
  {
    candidates
      .filter { $0.confidence >= minimumConfidence && $0.area > 0 }
      .max { $0.score < $1.score }?
      .rotation
  }

  private let output = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "VideoPrompter.camera.orientation")
  private let interval: TimeInterval
  private let onRotation: @Sendable (CameraRotation) -> Void
  private var lastSampled = Date.distantPast

  init(interval: TimeInterval = 2, onRotation: @escaping @Sendable (CameraRotation) -> Void) {
    self.interval = interval
    self.onRotation = onRotation
    super.init()
    output.alwaysDiscardsLateVideoFrames = true
    // A thumbnail is plenty for a face rectangle, and it keeps a 4K feed off this path.
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelBufferWidthKey as String: 320,
      kCVPixelBufferHeightKey as String: 180,
    ]
    output.setSampleBufferDelegate(self, queue: queue)
  }

  func attach(to session: AVCaptureSession) {
    guard !session.outputs.contains(output) else { return }
    session.beginConfiguration()
    if session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
  }
  func detach(from session: AVCaptureSession) {
    guard session.outputs.contains(output) else { return }
    session.beginConfiguration()
    session.removeOutput(output)
    session.commitConfiguration()
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let now = Date()
    // ponytail: wall-clock gate on a discarding output, not a frame-rate change on the device —
    // pin `activeVideoMinFrameDuration` instead if a card ever makes the discards expensive.
    guard now.timeIntervalSince(lastSampled) >= interval,
      let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }
    lastSampled = now
    let candidates = CameraRotation.allCases.compactMap { rotation -> Candidate? in
      let request = VNDetectFaceRectanglesRequest()
      try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: rotation.visionOrientation)
        .perform([request])
      let faces = (request.results ?? []).map {
        Face(confidence: $0.confidence, boundingBox: $0.boundingBox)
      }
      return Self.candidate(rotation, faces: faces)
    }
    if let best = Self.bestRotation(among: candidates) { onRotation(best) }
  }
}
