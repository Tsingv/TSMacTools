#!/bin/bash
set -euo pipefail

usage() {
  printf 'Usage: %s [--release] [--help]\n' "${0##*/}"
  printf 'Build TSMacTools (Debug by default; --release selects Release).\n'
  printf 'Keeps DerivedData for incremental rebuilds and never cleans automatically.\n'
}

configuration=Debug
case "$#" in
  0) ;;
  1)
    case "$1" in
      --release) configuration=Release ;;
      --help|-h) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
app_path="$project_root/DerivedData/Build/Products/$configuration/TSMacTools.app"

# Prefer incremental CLI builds:
# - stable DerivedData path (never cleaned here)
# - skip compiler index store (Xcode IDE indexing is unaffected)
# - Debug builds only the active architecture with incremental Swift
# - Release keeps whole-module optimization
build_settings=(
  COMPILER_INDEX_STORE_ENABLE=NO
)
if [[ "$configuration" == Debug ]]; then
  build_settings+=(
    ONLY_ACTIVE_ARCH=YES
    SWIFT_COMPILATION_MODE=incremental
    DEBUG_INFORMATION_FORMAT=dwarf
  )
else
  build_settings+=(
    SWIFT_COMPILATION_MODE=wholemodule
  )
fi

xcodebuild \
  -project "$project_root/MacTools.xcodeproj" \
  -scheme MacTools \
  -configuration "$configuration" \
  -derivedDataPath "$project_root/DerivedData" \
  -parallelizeTargets \
  "${build_settings[@]}" \
  build

if [[ ! -d "$app_path" ]]; then
  printf 'Build finished but the application was not found: %s\n' "$app_path" >&2
  exit 1
fi

printf '\nBuild succeeded (%s).\nApplication: %s\n' "$configuration" "$app_path"
printf '\nInstall to /Applications (quit TSMacTools first):\n'
printf 'sudo /usr/bin/ditto %q %q\n' "$app_path" '/Applications/TSMacTools.app'
