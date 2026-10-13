public import Foundation
import Observation
public import SwiftUI

/// Holds the current ``BreeChromePalette`` for the process. The app's palette
/// provider calls ``update(_:)`` whenever the theme, appearance, accessibility
/// options or accent change; SwiftUI reads it through
/// ``SwiftUI/View/breePaletteEnvironment()`` and AppKit through
/// ``BreeChromePalette/current`` plus ``didChangeNotification``.
@MainActor
@Observable
public final class BreeChromePaletteStore {
    public static let shared = BreeChromePaletteStore()

    /// Posted on the default center, with the store as the object, after the
    /// palette changes.
    nonisolated public static let didChangeNotification = Notification.Name("bree.chromePaletteDidChange")

    public private(set) var palette: BreeChromePalette = .fallback

    public init() {}

    /// Publishes `next` and posts ``didChangeNotification`` when it differs.
    public func update(_ next: BreeChromePalette) {
        guard next != palette else { return }
        palette = next
        BreeChromePaletteSnapshotBox.shared.set(next)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

extension BreeChromePalette {
    /// The palette AppKit drawing code should use right now. Redraw on
    /// ``BreeChromePaletteStore/didChangeNotification``.
    @MainActor public static var current: BreeChromePalette { BreeChromePaletteStore.shared.palette }

    /// The same palette, readable from any thread (dynamic `NSColor`
    /// providers, background drawing). Updated inside
    /// ``BreeChromePaletteStore/update(_:)``.
    nonisolated public static var currentSnapshot: BreeChromePalette { BreeChromePaletteSnapshotBox.shared.get() }
}

final class BreeChromePaletteSnapshotBox: @unchecked Sendable {
    static let shared = BreeChromePaletteSnapshotBox()
    private let lock = NSLock()
    private var value: BreeChromePalette = .fallback

    func get() -> BreeChromePalette {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ next: BreeChromePalette) {
        lock.lock()
        value = next
        lock.unlock()
    }
}

struct BreeChromePaletteEnvironmentModifier: ViewModifier {
    @State private var store = BreeChromePaletteStore.shared

    func body(content: Content) -> some View {
        content.environment(\.breePalette, store.palette)
    }
}

public extension View {
    /// Injects the live ``BreeChromePalette`` (`@Environment(\.breePalette)`)
    /// into this subtree. ``breeFontMagnificationEnvironment()`` already
    /// applies it, so every Bree window root has it.
    func breePaletteEnvironment() -> some View {
        modifier(BreeChromePaletteEnvironmentModifier())
    }
}
