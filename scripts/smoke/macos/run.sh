#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h:h:h}"
package_root="$project_root/apps/macos"
suite="${1:-workspace}"
if (( $# )); then shift; fi

case "$suite" in
  workspace)
    sources=(macos-workspace-smoke.swift ../../macos-personalization-smoke.swift
      ../../macos-interaction-smoke.swift ../../macos-assignment-deadlines-smoke.swift
      ../../macos-course-ui-smoke.swift macos-classification-smoke.swift
      macos-assignments-smoke.swift macos-canvas-refresh-smoke.swift
      macos-learning-smoke.swift macos-course-documents-smoke.swift
      macos-ocr-smoke.swift macos-transfer-smoke.swift) ;;
  canvas-downloads)
    sources=(macos-canvas-download-smoke.swift macos-canvas-new-files-smoke.swift
      macos-canvas-catalog-smoke.swift macos-canvas-session-smoke.swift
      macos-math-wiki-smoke.swift macos-content-polling-smoke.swift) ;;
  panels) sources=(macos-panel-smoke.swift) ;;
  search|files|exams) sources=("macos-$suite-smoke.swift") ;;
  --help|-h)
    print 'Usage: zsh scripts/smoke/macos/run.sh <workspace|panels|search|files|exams|canvas-downloads> [--skip-build] [suite options]'
    exit 0 ;;
  *) print -u2 "Unknown native smoke suite: $suite"; exit 2 ;;
esac

skip_build=0
suite_arguments=()
for argument in "$@"; do
  if [[ "$argument" == --skip-build ]]; then skip_build=1
  else suite_arguments+=("$argument"); fi
done
cd "$project_root"

sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${SDKROOT:-}" \
    && "${sdk_path:A}" == /Library/Developer/CommandLineTools/SDKs/MacOSX27*.sdk \
    && ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib \
    && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
sdk_interface="$(find "$sdk_path/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print -quit)"
sdk_compiler_version="$(sed -n 's|^// swift-compiler-version: ||p' "$sdk_interface" | head -n 1)"
swift_arguments=(--disable-sandbox --package-path "$package_root" --build-system native --sdk "$sdk_path"
  -Xswiftc -interface-compiler-version -Xswiftc "$sdk_compiler_version")

if [[ "$suite" == workspace || "$suite" == exams || "$suite" == panels ]]; then
  node scripts/build/build-study-web.mjs
fi
if (( ! skip_build )); then swift build "${swift_arguments[@]}"; fi
binary_dir="$(swift build "${swift_arguments[@]}" --show-bin-path)"
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/scholia-$suite.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT

app_objects=("$binary_dir/ScholiaMac.build/"*.swift.o)
app_objects=("${(@)app_objects:#*/ScholiaMacApp.swift.o}")
source_paths=()
for source in "${sources[@]}"; do source_paths+=("$script_dir/$source"); done
swiftc -parse-as-library -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
  -interface-compiler-version "$sdk_compiler_version" \
  -I "$binary_dir/Modules" \
  -Xcc -fmodule-map-file="$binary_dir/ScholiaSearch.build/module.modulemap" \
  -I "$package_root/.build/checkouts/swift-cmark/src/include" \
  -I "$package_root/.build/checkouts/swift-cmark/extensions/include" \
  "${source_paths[@]}" "${app_objects[@]}" \
  "$binary_dir/SwiftMath.build/"*.swift.o "$binary_dir/ScholiaSearch.build/"*.o \
  "$binary_dir/cmark_gfm.build/"*.o "$binary_dir/cmark_gfm_extensions.build/"*.o \
  -framework ApplicationServices -framework Carbon -framework CoreGraphics \
  -framework ImageIO -framework PDFKit -framework Security -framework ServiceManagement \
  -framework JavaScriptCore -framework WebKit -framework Vision -framework Quartz \
  -lsqlite3 -lz -o "$smoke_dir/run"

case "$suite" in
  workspace)
    python3 "$script_dir/study-format-fixtures.py" "$smoke_dir/fixtures"
    "$smoke_dir/run" "$package_root/.build/verification" "${suite_arguments[@]}" --fixtures "$smoke_dir/fixtures" ;;
  panels) "$smoke_dir/run" "$package_root/.build/verification" "${suite_arguments[@]}" ;;
  *) "$smoke_dir/run" "${suite_arguments[@]}" ;;
esac
