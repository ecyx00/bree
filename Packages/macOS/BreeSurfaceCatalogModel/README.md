# BreeSurfaceCatalogModel

The surface catalog's value types: the vocabulary shared by `SurfaceCatalog`, the Cloud sidebar, the socket commands and the CLI. Pure `Hashable`/`Codable`/`Sendable` values plus the bree-tui snapshot parser that produces them. No app imports; depends on `BreeCore`, `BREEDebugLog` and `BreeAppSupport` (for device-ID canonicalization).

```swift
import BreeSurfaceCatalogModel

let id = SurfaceResourceID(machine: .cloud("vm-1"), kind: .terminal, key: "t1")
assert(SurfaceResourceID(rawValue: id.rawValue) == id)
```

`SurfaceCatalog` itself (the owner, `@MainActor`, app-coupled) stays in the app target.

## Moved files

From `Sources/Surfaces/`: `SurfaceCatalogModel.swift`, `SurfaceCatalogSnapshot.swift`, `SurfaceResourcePlacement.swift`, `CloudVMTabState.swift`, `CloudTabNameAuthority.swift`, `CloudTabNameSource.swift`, `BreeTuiSnapshotParser.swift`, `CloudVMState+SnapshotComparison.swift` (it holds `CloudVMState`'s `==`), `SurfaceMachineID.swift`, `SurfaceDeviceInstanceID.swift`, `SurfaceDevicePresence.swift`, `SurfaceProjectionIdentity.swift`.
From `Sources/Cloud/`: `VMMachineKind.swift` (was also a member of the `bree-cli` target, so the CLI links this package), `CloudTuiTerminalProjectionTarget.swift`.

`SurfaceResourceID+Ports.swift` is new: the parser's listening-port helpers (from `SurfaceCatalog+CloudPorts.swift`) and `SurfaceResourceID.portKey`/`desktopDisplayKey` (from `SurfaceSocketCommands.swift`), which the moved parser calls.

## What changed besides the move

- Declarations became `public`. Structs that relied on the synthesized memberwise initializer got an explicit `public init` with the same parameters and defaults.
- `breeDebugLog(...)` (an app global) became `BREEDebugLog.logDebugEvent(...)`, still under `#if DEBUG`.

## Current-main boundary

`SurfaceProjectionIdentity` is also a package value: catalog exports carry stable
surface/workspace ownership metadata beside runtime projection selectors. Its
`Workspace` capture extension stays in the app; the package neither looks up nor
owns live workspaces. Snapshot creation/deletion metadata retains its optional
wire fields and backwards-compatible decoding.

`SurfaceResourceGroup` and `SurfaceProjectionLayout` still live in the app. Their
pure declarations are candidates for a later boundary change; catalog projection
orchestration, provider lookup, and layout application must remain above this
value layer. This extraction does not move the navigation coordinator or establish
a Cloud package.

Run the production value tests without launching the app:

```sh
swift test --package-path Packages/macOS/BreeSurfaceCatalogModel
```
