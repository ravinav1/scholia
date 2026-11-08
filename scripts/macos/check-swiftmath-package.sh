#!/bin/zsh
# Run after build-macos-app.sh, with no concurrent native build/check. This probe
# temporarily moves only this checkout's generated SwiftMath resource bundle;
# trap restoration keeps it available for subsequent command-line/XCTest runs.
set -euo pipefail
script_dir="${0:A:h}"
project_root="${script_dir:h:h}"
package_root="$project_root/apps/macos"
app_path="${1:-$project_root/dist/macos/Scholia.app}"
configuration="${2:-release}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  print -u2 "Usage: $0 [Scholia.app] [debug|release]"
  exit 2
fi
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${SDKROOT:-}" && "${sdk_path:A}" == /Library/Developer/CommandLineTools/SDKs/MacOSX27*.sdk \
    && ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib \
    && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
interfaces=("$sdk_path/usr/lib/swift/Swift.swiftmodule/"*-apple-macos.swiftinterface)
sdk_compiler_version="$(sed -n 's|^// swift-compiler-version: ||p' "$interfaces[1]" | head -n 1)"
binary_dir="$(swift build --disable-sandbox --package-path "$package_root" --configuration "$configuration" --build-system native --show-bin-path)"
build_bundle="$binary_dir/SwiftMath_SwiftMath.bundle"
[[ -d "$build_bundle" && -d "$app_path/Contents/Resources/SwiftMath_SwiftMath.bundle" ]]
probe_work="$(mktemp -d "${TMPDIR:-/tmp}/scholia-font-probe.XXXXXX")"
hidden_bundle=""
cleanup_probe() {
  if [[ -n "$hidden_bundle" && -d "$hidden_bundle" ]]; then
    if [[ -e "$build_bundle" ]]; then
      print -u2 "Concurrent build replaced $build_bundle; preserved original resources at $hidden_bundle"
    else
      mv "$hidden_bundle" "$build_bundle"
    fi
  fi
  rm -rf "$probe_work"
}
trap cleanup_probe EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
probe_app="$probe_work/SwiftMathProbe.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources"
cp -R "$app_path/Contents/Resources/SwiftMath_SwiftMath.bundle" "$probe_app/Contents/Resources/"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.scholia.swiftmath-resource-check</string>
<key>CFBundleExecutable</key><string>SwiftMathProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
font_objects=("${(@f)$(python3 - "$binary_dir/SwiftMath.build/output-file-map.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    mapping = json.load(stream)
for source, outputs in mapping.items():
    if source and outputs.get('object'):
        print(outputs['object'])
PY
)}")
swiftc -O -parse-as-library -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
    -interface-compiler-version "$sdk_compiler_version" -I "$binary_dir/Modules" \
    "$script_dir/check-swiftmath-package.swift" "${font_objects[@]}" \
    -framework AppKit -framework CoreText -framework CoreGraphics \
    -o "$probe_app/Contents/MacOS/SwiftMathProbe"
codesign --force --deep --sign - "$probe_app"
codesign --verify --deep --strict --verbose=2 "$probe_app"
# The copied executable outside .app validates the lazy Bundle.module fallback
# independently after restoration of the build resource bundle.
cp "$probe_app/Contents/MacOS/SwiftMathProbe" "$probe_work/SwiftMathCLIProbe"
hidden_bundle="$binary_dir/.SwiftMath_SwiftMath.bundle.probe-$$"
[[ ! -e "$hidden_bundle" ]]
mv "$build_bundle" "$hidden_bundle"
[[ ! -e "$build_bundle" ]]
"$probe_app/Contents/MacOS/SwiftMathProbe" --standalone
mv "$hidden_bundle" "$build_bundle"
hidden_bundle=""
"$probe_work/SwiftMathCLIProbe"
codesign --verify --deep --strict --verbose=2 "$app_path"
print 'PASS signed package fonts with build fallback absent; SwiftPM fallback restored and verified.'
