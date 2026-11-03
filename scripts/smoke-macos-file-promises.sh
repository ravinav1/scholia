#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
project_root="${script_dir:h}"
sdk_path="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
sdk_interface="$sdk_path/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
sdk_compiler_version="$(sed -n 's|^// swift-compiler-version: ||p' "$sdk_interface" | head -n 1)"
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/scholia-file-promises.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
module_cache="$project_root/apps/macos/.build/ScholiaModuleCache"
mkdir -p "$module_cache"
swiftc -parse-as-library -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
  -interface-compiler-version "$sdk_compiler_version" -module-cache-path "$module_cache" \
  "$project_root/apps/macos/Sources/ScholiaMac/AttachmentDropReader.swift" \
  "$script_dir/macos-file-promises-smoke.swift" -o "$smoke_dir/file-promises-smoke"
"$smoke_dir/file-promises-smoke"
