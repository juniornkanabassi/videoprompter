@preconcurrency import AVFoundation
import Foundation

/// A single pending main-actor update retains peaks without queuing stale meter readings.
final class AudioMeterDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [Float] = []
  private var scheduled = false
  private var oldestCallback = 0.0
  private var oldestCapture: Double?
  private var previousCallback: Double?
  private var envelope: [Float] = []
  private let onLevels: @MainActor @Sendable ([Float]) -> Void
  private let logsLatency = ProcessInfo.processInfo.environment["VIDEOPROMPTER_AUDIO_LATENCY"] == "1"

  init(onLevels: @escaping @MainActor @Sendable ([Float]) -> Void) { self.onLevels = onLevels }

  func receive(_ buffer: CMSampleBuffer, clock: CMClock? = nil) {
    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    if logsLatency {
      NSLog("Audio buffer: frames=%d duration=%.3f ms", CMSampleBufferGetNumSamples(buffer), CMSampleBufferGetDuration(buffer).seconds * 1000)
    }
    let capture = clock.map {
      CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(buffer), from: $0,
                        to: CMClockGetHostTimeClock()).seconds
    }
    receive(peaks: RecordingAudioTest.channelPeaks(in: buffer), callback: now, capture: capture)
  }

  func receive(peaks: [Float], callback: Double, capture: Double? = nil) {
    lock.lock()
    // Instant attack, 20 dB/second release. Preserve a short transient until the UI consumes it.
    let decay = Float(pow(10, -max(0, callback - (previousCallback ?? callback))))
    previousCallback = callback
    envelope = peaks.enumerated().map { index, peak in
      max(peak, (index < envelope.count ? envelope[index] : 0) * decay)
    }
    if !scheduled { oldestCallback = callback; oldestCapture = capture }
    pending = envelope.enumerated().map { index, peak in max(peak, index < pending.count ? pending[index] : 0) }
    let enqueue = !scheduled
    scheduled = true
    lock.unlock()
    guard enqueue else { return }
    Task { @MainActor [self] in
      let value = lock.withLock { () -> ([Float], Double, Double?) in
        let value = (pending, oldestCallback, oldestCapture)
        pending = []; scheduled = false
        return value
      }
      onLevels(value.0)
      if logsLatency {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let age = value.2.map { (now - $0) * 1000 } ?? .nan
        NSLog("Audio meter: callback-to-publish=%.3f ms capture-to-publish=%.3f ms", (now - value.1) * 1000, age)
      }
    }
  }
}
