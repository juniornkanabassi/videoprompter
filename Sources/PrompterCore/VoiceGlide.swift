import Foundation

/// Voice's scroll position: a fractional token index that follows the recogniser's word smoothly.
///
/// The recogniser credits words in bursts, often several at once and then nothing for half a
/// second, so scrolling to each new word hopped and stopped. This moves at the reader's recent pace
/// instead, catches up on whatever it is behind, and coasts at most `lead` words past the last
/// credited word, so a gap between bursts does not stop it. The reader is about 0.4 s (over a word)
/// ahead of the recogniser, so the lead never puts the guide ahead of the voice.
///
/// Pure and clock-driven: the Mac and iPad presenters paint it on every display frame through the
/// same path as Manual, and the replay tests run it on recorded readings without a screen.
public struct VoiceGlide: Sendable {
  /// Tuned on the committed readings; `SpeechLogReplayTests` holds the measured bounds.
  static let catchUpSeconds = 0.5
  static let velocitySeconds = 0.15
  static let paceWindow = 3.0
  public static let lead = 1.0
  /// Further than this behind, or back past the lead, is a jump (a skipped passage, a re-read):
  /// it closes fast, then gliding starts again from rest.
  static let jumpWords = 12.0
  static let jumpSeconds = 0.08

  public private(set) var position: Double
  private var velocity = 0.0
  private var lastTime: TimeInterval?
  /// Target changes within the pace window, and the target before them.
  private var changes: [(time: TimeInterval, target: Double)] = []
  private var paceBase: Double

  public init(at position: Double) {
    self.position = position
    paceBase = position
  }

  /// Advances to `time` and returns the position to paint. Call once per display frame.
  public mutating func step(toward target: Int, at time: TimeInterval) -> Double {
    let goal = Double(target)
    let dt = min(max(time - (lastTime ?? time), 0), 0.1)
    lastTime = time
    if goal != (changes.last?.target ?? paceBase) {
      // A move back is a re-read, not pace: count only from there.
      if goal < (changes.last?.target ?? paceBase) { changes.removeAll(); paceBase = goal } else { changes.append((time, goal)) }
    }
    while let first = changes.first, first.time < time - Self.paceWindow {
      paceBase = first.target
      changes.removeFirst()
    }
    let pace = max(0, goal - paceBase) / Self.paceWindow
    let behind = goal - position
    if behind > Self.jumpWords || behind < -Self.lead {
      position += behind * (1 - exp(-dt / Self.jumpSeconds))
      velocity = 0
      return position
    }
    // Full pace until the coasting room runs out over the last word, plus a catch-up on the gap.
    let room = min(max(goal + Self.lead - position, 0), 1)
    let wanted = pace * room + max(0, behind) / Self.catchUpSeconds
    velocity += (wanted - velocity) * (1 - exp(-dt / Self.velocitySeconds))
    position = min(position + velocity * dt, goal + Self.lead)
    return position
  }
}
