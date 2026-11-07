#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h:h}"
cd "$project_root"
package_root="$project_root/apps/macos"
sdk_path="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$sdk_path" ]]; then sdk_path="$(xcrun --sdk macosx --show-sdk-path)"; fi
interfaces=("$sdk_path/usr/lib/swift/Swift.swiftmodule/"*-apple-macos.swiftinterface)
sdk_compiler_version="$(sed -n 's|^// swift-compiler-version: ||p' "$interfaces[1]" | head -n 1)"
swift_arguments=(--disable-sandbox --package-path "$package_root" --build-system native -c release
  -Xswiftc -enable-testing -Xswiftc -no-whole-module-optimization
  --sdk "$sdk_path" -Xswiftc -interface-compiler-version -Xswiftc "$sdk_compiler_version")
swift build "${swift_arguments[@]}"
binary_dir="$(swift build "${swift_arguments[@]}" --show-bin-path)"
audit_dir="$(mktemp -d "${TMPDIR:-/tmp}/scholia-audit-bin.XXXXXX")"
trap 'rm -rf "$audit_dir"' EXIT
app_objects=("$binary_dir/ScholiaMac.build/"*.swift.o)
app_objects=("${(@)app_objects:#*/ScholiaMacApp.swift.o}")
swiftc -O -parse-as-library -Xlinker -dead_strip -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
  -interface-compiler-version "$sdk_compiler_version" -I "$binary_dir/Modules" \
  -Xcc -fmodule-map-file="$binary_dir/ScholiaSearch.build/module.modulemap" \
  -I "$package_root/.build/checkouts/swift-cmark/src/include" \
  -I "$package_root/.build/checkouts/swift-cmark/extensions/include" \
  "$script_dir/audit-performance.swift" "${app_objects[@]}" \
  "$binary_dir/SwiftMath.build/"*.swift.o "$binary_dir/ScholiaSearch.build/"*.o \
  "$binary_dir/cmark_gfm.build/"*.o "$binary_dir/cmark_gfm_extensions.build/"*.o \
  -framework ApplicationServices -framework Carbon -framework CoreGraphics \
  -framework ImageIO -framework PDFKit -framework Security -framework ServiceManagement \
  -framework JavaScriptCore -framework WebKit -framework Vision -framework Quartz -lsqlite3 -lz \
  -o "$audit_dir/audit"
if [[ " ${*} " == *" --browser "* ]]; then node scripts/build/build-study-web.mjs; fi
"$audit_dir/audit" "$@"
