#if DEBUG
import BREEDebugLog

@inline(__always)
func breeDebugLog(_ message: @autoclosure () -> String) {
    BREEDebugLog.logDebugEvent(message())
}
#else
// Release no-op so call sites need no #if DEBUG guards.
@inline(__always)
func breeDebugLog(_ message: @autoclosure () -> String) {}
#endif
