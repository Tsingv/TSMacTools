#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="${FAN_HELPER_OUTPUT:-DerivedData/FanHelper}"
identity=85B37EA8D5B9719CB5F443613573AD1F4986B17B
mkdir -p "$output"
flags=(-O)
if [[ ${CONFIGURATION:-Release} == Debug ]]; then flags=(-Onone -g); fi
xcrun swiftc "${flags[@]}" -parse-as-library -emit-module -emit-library -static -module-name MacToolsCore Sources/MacToolsCore/*.swift -o "$output/libMacToolsCore.a" -emit-module-path "$output/MacToolsCore.swiftmodule"
xcrun swiftc "${flags[@]}" Tools/FanHelper/main.swift -I "$output" "$output/libMacToolsCore.a" -o "$output/TSMacToolsFanHelper"
/usr/bin/codesign --force --options runtime --identifier local.clearain.MacTools.FanHelper --sign "$identity" "$output/TSMacToolsFanHelper"
/usr/bin/codesign --verify --strict -R '=identifier "local.clearain.MacTools.FanHelper" and certificate leaf = H"85B37EA8D5B9719CB5F443613573AD1F4986B17B"' "$output/TSMacToolsFanHelper"
if [[ -n ${TARGET_BUILD_DIR:-} && -n ${CONTENTS_FOLDER_PATH:-} ]]; then
  destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchServices"
  mkdir -p "$destination"
  /usr/bin/ditto "$output/TSMacToolsFanHelper" "$destination/TSMacToolsFanHelper"
fi
