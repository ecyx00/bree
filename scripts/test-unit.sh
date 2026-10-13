#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="bree.xcodeproj"
SCHEME="bree-unit"
CONFIGURATION="${BREE_TEST_CONFIGURATION:-Debug}"
DESTINATION="${BREE_TEST_DESTINATION:-platform=macOS}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

# breeTests emits no Swift module, as in CI (scripts/ci/compile-app-host-test-product.sh).
# Nothing imports breeTests.swiftmodule, but its emit-module job type-checks
# every test declaration serially: 26 s of a 31 s one-test-file rebuild. The
# standalone driver with -no-emit-module-separately skips it (4.1 s, #14364).
# Only breeTests changes; every other target keeps its arguments. Switching
# between this and an Xcode build in the same DerivedData rebuilds breeTests
# once each way. BREE_TEST_EMIT_MODULE=1 keeps the module, for example to
# debug test frames with lldb. A caller's own OTHER_SWIFT_FLAGS comes later and
# wins, which drops the flag and brings the module back.
# shellcheck disable=SC2016 # Xcode expands $(TARGET_NAME), not the shell
no_module_settings=(
  'SWIFT_USE_INTEGRATED_DRIVER=$(BREE_TEST_INTEGRATED_DRIVER_$(TARGET_NAME):default=YES)'
  BREE_TEST_INTEGRATED_DRIVER_breeTests=NO
  'OTHER_SWIFT_FLAGS=$(inherited) $(BREE_TEST_SWIFT_FLAGS_$(TARGET_NAME))'
  BREE_TEST_SWIFT_FLAGS_breeTests=-no-emit-module-separately
  'SWIFT_INSTALL_MODULE=$(BREE_TEST_INSTALL_MODULE_$(TARGET_NAME):default=YES)'
  BREE_TEST_INSTALL_MODULE_breeTests=NO
)
if [ "${BREE_TEST_EMIT_MODULE:-0}" = 1 ]; then
  no_module_settings=()
fi

# Toast and Feed command tests expect English strings, so a Mac set to another
# language fails them.
# A caller's own -testLanguage / -testRegion wins.
locale_args=()
case " $* " in *" test "*|*" test-without-building "*)
  case " $* " in *" -testLanguage "*) ;; *) locale_args+=(-testLanguage en) ;; esac
  case " $* " in *" -testRegion "*) ;; *) locale_args+=(-testRegion US) ;; esac ;;
esac

exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  ${no_module_settings[@]+"${no_module_settings[@]}"} \
  ${locale_args[@]+"${locale_args[@]}"} \
  "$@"
