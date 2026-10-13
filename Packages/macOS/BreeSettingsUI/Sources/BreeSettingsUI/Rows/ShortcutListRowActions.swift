import BreeFoundation
import BreeSettings

struct ShortcutListRowActions {
    let onStroke: (ShortcutStroke) -> Void
    let onChord: (StoredShortcut) -> Void
    let onBareKeyRejected: () -> Void
    let onClearOrRestore: () -> Void
    let onClearRejections: () -> Void
}
