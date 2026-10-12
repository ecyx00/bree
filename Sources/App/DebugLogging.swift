#if DEBUG
import CMUXDebugLog

@inline(__always)
func cmuxDebugLog(_ message: @autoclosure () -> String) {
    CMUXDebugLog.logDebugEvent(message())
}
#else
// Release no-op so call sites need no #if DEBUG guards.
@inline(__always)
func cmuxDebugLog(_ message: @autoclosure () -> String) {}
#endif
