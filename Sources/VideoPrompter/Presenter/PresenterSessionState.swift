import Combine

/// The presenter shell needs lifecycle and document changes, but not each recognised word.
/// Keep SessionStore's published reading API for the text view, CLI and replay consumers.
@MainActor
final class PresenterSessionState: ObservableObject {
  private var subscription: AnyCancellable?

  init(session: SessionStore) {
    // Each source keeps its own filter; `dropFirst` skips the value the presenter opens with.
    subscription = Publishers.MergeMany(
      Self.changes(session.$document.dropFirst()),
      Self.changes(session.$state.removeDuplicates().dropFirst()),
      Self.changes(session.$settings.removeDuplicates().dropFirst()),
      Self.changes(session.$anchorNotice.removeDuplicates().dropFirst())
    ).sink { [weak self] in self?.objectWillChange.send() }
  }

  private static func changes<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
    publisher.map { _ in () }.eraseToAnyPublisher()
  }
}
