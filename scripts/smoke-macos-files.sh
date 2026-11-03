#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
package_root="${script_dir:h}/apps/macos"
sdk_path="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
sdk_interface="$sdk_path/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
sdk_compiler_version="$(sed -n 's|^// swift-compiler-version: ||p' "$sdk_interface" | head -n 1)"
swift_arguments=(--disable-sandbox --package-path "$package_root" --build-system native --sdk "$sdk_path"
  -Xswiftc -interface-compiler-version -Xswiftc "$sdk_compiler_version")
swift build "${swift_arguments[@]}"
binary_dir="$(swift build "${swift_arguments[@]}" --show-bin-path)"
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/scholia-files.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
app_objects=("$binary_dir/ScholiaMac.build/"*.swift.o)
app_objects=("${(@)app_objects:#*/ScholiaMacApp.swift.o}")
swiftc -parse-as-library -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
  -interface-compiler-version "$sdk_compiler_version" \
  -I "$binary_dir/Modules" \
  -Xcc -fmodule-map-file="$binary_dir/ScholiaSearch.build/module.modulemap" \
  -I "$package_root/.build/checkouts/swift-cmark/src/include" \
  -I "$package_root/.build/checkouts/swift-cmark/extensions/include" \
  "$script_dir/macos-files-smoke.swift" "${app_objects[@]}" \
  "$binary_dir/SwiftMath.build/"*.swift.o "$binary_dir/ScholiaSearch.build/"*.o \
  "$binary_dir/cmark_gfm.build/"*.o "$binary_dir/cmark_gfm_extensions.build/"*.o \
  -framework ApplicationServices -framework Carbon -framework CoreGraphics \
  -framework ImageIO -framework PDFKit -framework Security -framework ServiceManagement \
  -framework JavaScriptCore -framework WebKit -framework Vision -framework Quartz -lsqlite3 -lz -o "$smoke_dir/files-smoke"
"$smoke_dir/files-smoke"
