import Combine

/// The presenter shell needs lifecycle and document changes, but not each recognised word.
/// Keep SessionStore's published reading API for the text view, CLI and replay consumers.
@MainActor
final class PresenterSessionState: ObservableObject {
  private var subscriptions: Set<AnyCancellable> = []

  init(session: SessionStore) {
    session.$document.dropFirst().sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &subscriptions)
    session.$state.removeDuplicates().dropFirst().sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &subscriptions)
    session.$settings.removeDuplicates().dropFirst().sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &subscriptions)
    session.$anchorNotice.removeDuplicates().dropFirst().sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &subscriptions)
  }
}
