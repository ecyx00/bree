#!/bin/bash
# Run only on a disposable/leased Mac or hosted CI, never the user's shared Mac.
# Compile production identity/migration and atomics; stub only display/tag metadata.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:?pass an isolated scratch directory}
mkdir -p "$DEST/Sources/IdentityColdStartFixture" "$DEST/Sources/BREEMobileCore" \
  "$DEST/Sources/BreeSettings" "$DEST/Sources/BreeFoundation" \
  "$DEST/Sources/BreeFoundationAtomicsC/include"
cat > "$DEST/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "IdentityColdStartFixture",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BREEMobileCore"),
        .target(name: "BreeSettings"),
        .target(name: "BreeFoundationAtomicsC", publicHeadersPath: "include"),
        .target(name: "BreeFoundation", dependencies: ["BreeFoundationAtomicsC"]),
        .executableTarget(
            name: "IdentityColdStartFixture",
            dependencies: ["BREEMobileCore", "BreeSettings", "BreeFoundation"]
        )
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
cp "$ROOT/Packages/macOS/BreeCloud/Sources/BreeCloud/Environment/MobileHostIdentity.swift" "$DEST/Sources/IdentityColdStartFixture/"
cp "$ROOT/tests/fixtures/mobile-host-identity-cold-start/IdentityColdStartFixture.swift" \
  "$ROOT/tests/fixtures/mobile-host-identity-cold-start/IdentityNotificationProbe.swift" \
  "$DEST/Sources/IdentityColdStartFixture/"
cp "$ROOT/Packages/Shared/BREEMobileCore/Sources/BREEMobileCore/CmxDeviceIDCanonicalization.swift" \
  "$DEST/Sources/BREEMobileCore/"
cp "$ROOT/tests/fixtures/mobile-host-identity-cold-start/DisplayMetadataDependencies.swift" \
  "$DEST/Sources/BreeSettings/"
cp "$ROOT/Packages/macOS/BreeFoundation/Sources/BreeFoundation/Concurrency/AtomicBooleanGate.swift" \
  "$DEST/Sources/BreeFoundation/"
cp "$ROOT/Packages/macOS/BreeFoundation/Sources/BreeFoundationAtomicsC/BreeFoundationAtomicsC.c" \
  "$DEST/Sources/BreeFoundationAtomicsC/"
cp "$ROOT/Packages/macOS/BreeFoundation/Sources/BreeFoundationAtomicsC/include/BreeFoundationAtomicsC.h" \
  "$DEST/Sources/BreeFoundationAtomicsC/include/"
swift build --package-path "$DEST" -Xswiftc -warnings-as-errors
BIN_DIR=$(swift build --package-path "$DEST" --show-bin-path)
python3 "$ROOT/tests/test_mobile_host_identity_cold_start.py" \
  "$BIN_DIR/IdentityColdStartFixture" "$DEST/results.json"
