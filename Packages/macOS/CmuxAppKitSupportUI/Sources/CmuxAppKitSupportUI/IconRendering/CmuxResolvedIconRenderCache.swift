public import AppKit
public import Foundation

/// Bounded process-wide cache of rendered icon bitmaps, keyed by source, size, tint, weight and
/// appearance. Rendering scans pixels, so repeated rows of the same file type must not re-render.
///
/// The cache is dropped when the app posts the memory-relief notification, and by the system
/// under pressure (`NSCache`).
@MainActor
public final class CmuxResolvedIconRenderCache {
    /// Shared instance used by ``CmuxResolvedIconImageView``.
    public static let shared = CmuxResolvedIconRenderCache(countLimit: 256)

    /// Name posted by `MallocPressureRelief.dropCachesNotification` (CmuxFoundation); duplicated
    /// here because this package does not depend on CmuxFoundation.
    static let dropCachesNotificationName = Notification.Name("com.bree.memory-relief.drop-caches")

    private let cache = NSCache<NSString, NSImage>()
    /// Number of cache hits since creation (tests and diagnostics).
    public private(set) var hitCount = 0

    /// Creates a cache holding at most `countLimit` images.
    public init(countLimit: Int) {
        cache.countLimit = countLimit
        // The observer lives as long as the cache; the shared instance is never released.
        _ = NotificationCenter.default.addObserver(
            forName: Self.dropCachesNotificationName, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    /// Returns the cached image for `key`, if any.
    public func image(forKey key: String) -> NSImage? {
        guard let image = cache.object(forKey: key as NSString) else { return nil }
        hitCount += 1
        return image
    }

    /// Stores `image` under `key`.
    public func setImage(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    /// Drops every cached image.
    public func removeAll() {
        cache.removeAllObjects()
    }
}
