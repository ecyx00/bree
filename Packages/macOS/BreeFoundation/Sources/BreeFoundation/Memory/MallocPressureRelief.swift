import Darwin
public import Foundation

/// Process-wide heap relief: returns free malloc pages to the OS.
public enum MallocPressureRelief {
    /// Posted (on the main queue) before the heap is trimmed so caches that can
    /// be rebuilt on demand (icons, previews, search documents) drop first.
    public static let dropCachesNotification = Notification.Name("com.bree.memory-relief.drop-caches")

    /// Posted (any thread) after something that frees a lot of heap closed:
    /// a terminal surface was freed or a workspace was removed.
    public static let itemClosedNotification = Notification.Name("com.bree.memory-relief.item-closed")

    /// Returns the number of bytes the call reported releasing.
    @discardableResult
    public static func relieveHeap() -> Int {
        malloc_zone_pressure_relief(nil, 0)
    }
}
