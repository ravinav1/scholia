#!/bin/zsh
# Link an isolated native check to the production release objects. Unlike XCTest,
# this also works with Apple's Command Line Tools-only installation.
set -euo pipefail
script_dir="${0:A:h}"
project_root="${script_dir:h:h}"
package_root="$project_root/apps/macos"
skip_build="${SCHOLIA_SKIP_BUILD:-0}"
if [[ "${1:-}" == --skip-build ]]; then skip_build=1; shift; fi
source_path="${1:?Pass a native Swift check source}"
shift
source_paths=("$source_path")
while [[ "${1:-}" == --source ]]; do
    source_paths+=("${2:?Pass an additional check source}")
    shift 2
done
cd "$project_root"
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${SDKROOT:-}" && "${sdk_path:A}" == /Library/Developer/CommandLineTools/SDKs/MacOSX27*.sdk \
    && ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib \
    && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
interfaces=("$sdk_path/usr/lib/swift/Swift.swiftmodule/"*-apple-macos.swiftinterface)
sdk_compiler_version="$(sed -n 's|^// swift-compiler-version: ||p' "$interfaces[1]" | head -n 1)"
swift_arguments=(--disable-sandbox --package-path "$package_root" --configuration release --build-system native --jobs 4 --sdk "$sdk_path"
    -Xswiftc -enable-testing -Xswiftc -interface-compiler-version -Xswiftc "$sdk_compiler_version")
if [[ "$skip_build" != 1 ]]; then swift build "${swift_arguments[@]}"; fi
binary_dir="$(swift build "${swift_arguments[@]}" --show-bin-path)"
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/scholia-release-check.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
# SwiftPM can leave deleted sources' .o files in an incremental build folder.
# Link only objects in its current input map (never resurrect removed features).
app_objects=("${(@f)$(python3 - "$binary_dir/ScholiaMac.build/output-file-map.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    mapping = json.load(stream)
for source, outputs in mapping.items():
    if source and outputs.get('object'):
        print(outputs['object'])
PY
)}")
# A dynamic image keeps the app entry point separate from the check entry point.
# Release cross-file optimization can put AppDelegate references in other objects,
# so dropping ScholiaMacApp.swift.o (the debug smoke approach) is not safe.
swiftc -emit-library -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
    "${app_objects[@]}" \
    "$binary_dir/SwiftMath.build/"*.swift.o "$binary_dir/ScholiaSearch.build/"*.o \
    "$binary_dir/cmark_gfm.build/"*.o "$binary_dir/cmark_gfm_extensions.build/"*.o \
    -framework ApplicationServices -framework Carbon -framework CoreGraphics \
    -framework ImageIO -framework PDFKit -framework Security -framework ServiceManagement \
    -framework JavaScriptCore -framework WebKit -framework Vision -framework Quartz -lsqlite3 -lz \
    -o "$smoke_dir/libScholiaCheck.dylib"
swiftc -O -parse-as-library -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
    -interface-compiler-version "$sdk_compiler_version" -I "$binary_dir/Modules" \
    -Xcc -fmodule-map-file="$binary_dir/ScholiaSearch.build/module.modulemap" \
    -I "$package_root/.build/checkouts/swift-cmark/src/include" \
    -I "$package_root/.build/checkouts/swift-cmark/extensions/include" \
    "${source_paths[@]}" -L "$smoke_dir" -lScholiaCheck -Xlinker -rpath -Xlinker "$smoke_dir" \
    -o "$smoke_dir/check"
"$smoke_dir/check" "$@"
