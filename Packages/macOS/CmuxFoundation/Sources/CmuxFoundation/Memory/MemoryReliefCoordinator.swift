import Foundation

/// Decides when the app should hand freed heap back to the OS and drop its
/// own rebuildable caches. The policy lives here; the action is injected so the
/// triggers stay testable without touching the real malloc zones.
///
/// Triggers:
/// - ``noteClose()`` (workspace or panel closed): debounced, so closing many
///   items in a row relieves once after the burst.
/// - ``noteInactive()`` / ``noteActive()``: relieves once after the app has
///   been inactive for `idleDelay`; coming back cancels the pending relief.
/// - ``noteLaunch()``: one relief after launch transients have settled.
/// - ``noteMemoryPressure()``: relieves immediately.
public actor MemoryReliefCoordinator {
    public enum Reason: Sendable, Equatable {
        case close, idle, launch, memoryPressure
    }

    private let closeDebounce: Duration
    private let idleDelay: Duration
    private let launchDelay: Duration
    private let relieve: @Sendable (Reason) async -> Void
    private var closeTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?

    public init(
        closeDebounce: Duration = .seconds(3),
        idleDelay: Duration = .seconds(60),
        launchDelay: Duration = .seconds(45),
        relieve: @escaping @Sendable (Reason) async -> Void
    ) {
        self.closeDebounce = closeDebounce
        self.idleDelay = idleDelay
        self.launchDelay = launchDelay
        self.relieve = relieve
    }

    public func noteClose() {
        closeTask?.cancel()
        closeTask = schedule(after: closeDebounce, reason: .close)
    }

    public func noteInactive() {
        idleTask?.cancel()
        idleTask = schedule(after: idleDelay, reason: .idle)
    }

    public func noteActive() {
        idleTask?.cancel()
        idleTask = nil
    }

    public func noteLaunch() {
        launchTask?.cancel()
        launchTask = schedule(after: launchDelay, reason: .launch)
    }

    public func noteMemoryPressure() async {
        await relieve(.memoryPressure)
    }

    private func schedule(after delay: Duration, reason: Reason) -> Task<Void, Never> {
        let relieve = relieve
        return Task {
            do { try await Task.sleep(for: delay) } catch { return }
            await relieve(reason)
        }
    }
}
