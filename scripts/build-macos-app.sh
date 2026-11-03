#!/bin/zsh
set -euo pipefail
unsetopt bgnice

script_dir="${0:A:h}"
project_root="${script_dir:h}"
package_root="$project_root/apps/macos"
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  print -u2 "Usage: $0 [debug|release]"
  exit 2
fi
output_app="$project_root/dist/macos/Scholia.app"
module_cache="$package_root/.build/ScholiaModuleCache"

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  print -u2 "Install Node.js 24 or newer, then run Update Scholia.command again."
  exit 1
fi
if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)'; then
  print -u2 "Scholia needs Node.js 24 or newer. Installed: $(node --version)"
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 "Install Apple's developer tools with xcode-select --install, then run Update Scholia.command again."
  exit 1
fi

# Install once, and refresh when either dependency manifest changes.
cd "$project_root"
dependencies_hash="$(shasum -a 256 package.json package-lock.json)"
dependencies_stamp="$project_root/node_modules/.scholia-macos-dependencies"
if [[ ! -f "$dependencies_stamp" ]] || [[ "$(<"$dependencies_stamp")" != "$dependencies_hash" ]]; then
  printf 'Preparing Scholia dependencies…\n'
  npm ci --no-audit --no-fund
  printf '%s\n' "$dependencies_hash" > "$dependencies_stamp"
fi

mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
swift_arguments=(--disable-sandbox --package-path "$package_root" --configuration "$configuration" --build-system native --disable-index-store --product ScholiaMac)
# Local updates reuse per-file compilation. Explicit release builds keep Swift's
# full optimization for distribution, which takes considerably longer to rebuild.
if [[ "$configuration" == debug ]]; then
  printf 'Building incrementally for local use (changed Swift files only after the first build).\n'
else
  printf 'Building an optimized release; this can take several minutes.\n'
fi
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
# The macOS 27 Command Line Tools SDK uses SwiftUIMacros without shipping its
# plugin. Prefer the installed 26.5 SDK in that setup; explicit SDKROOT wins.
if [[ -z "${SDKROOT:-}" \
    && "${sdk_path:A}" == /Library/Developer/CommandLineTools/SDKs/MacOSX27*.sdk \
    && ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib \
    && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  printf 'Using the macOS 26.5 SDK for Command Line Tools SwiftUI support.\n'
fi
swift_arguments+=(--sdk "$sdk_path")
sdk_interface="$(find "$sdk_path/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print -quit)"
if [[ -f "$sdk_interface" ]]; then
  sdk_compiler_version="$(sed -n 's|^// swift-compiler-version: ||p' "$sdk_interface" | head -n 1)"
  installed_compiler_version="$(swiftc --version | head -n 1)"
  if [[ -n "$sdk_compiler_version" && "$sdk_compiler_version" != "$installed_compiler_version" ]]; then
    swift_arguments+=(-Xswiftc -interface-compiler-version -Xswiftc "$sdk_compiler_version")
  fi
fi

build_started=$SECONDS
swift build "${swift_arguments[@]}" &
swift_build_pid=$!
(
  while kill -0 "$swift_build_pid" 2>/dev/null; do
    sleep 20 >/dev/null 2>&1
    if kill -0 "$swift_build_pid" 2>/dev/null; then
      printf 'Swift is still compiling (%ss elapsed)…\n' "$(( SECONDS - build_started ))"
    fi
  done
) &
build_progress_pid=$!
trap 'kill "$build_progress_pid" "$swift_build_pid" 2>/dev/null || true' EXIT INT TERM
build_exit_code=0
wait "$swift_build_pid" || build_exit_code=$?
kill "$build_progress_pid" 2>/dev/null || true
wait "$build_progress_pid" 2>/dev/null || true
trap - EXIT INT TERM
if (( build_exit_code != 0 )); then exit "$build_exit_code"; fi
printf 'Swift build finished in %ss. Packaging Scholia…\n' "$(( SECONDS - build_started ))"
binary_dir="$(swift build "${swift_arguments[@]}" --show-bin-path)"

# Keep the running bundle intact until its replacement is packaged and signed.
mkdir -p "${output_app:h}"
package_work="$(mktemp -d "${output_app:h}/.scholia-build.XXXXXX")"
app_root="$package_work/Scholia.app"
contents="$app_root/Contents"
icon_work=""
cleanup_package() {
  if [[ -n "$icon_work" ]]; then rm -rf "$icon_work"; fi
  if [[ -d "$package_work/Previous-Scholia.app" ]]; then
    print -u2 "The previous build is preserved at $package_work/Previous-Scholia.app"
  else
    rm -rf "$package_work"
  fi
}
trap cleanup_package EXIT
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary_dir/ScholiaMac" "$contents/MacOS/Scholia"
cp "$package_root/Info.plist" "$contents/Info.plist"
/usr/bin/plutil -insert ScholiaSourceRoot -string "$project_root" "$contents/Info.plist"
resource_bundles=("$binary_dir"/*.bundle(N))
for resource_bundle in "${resource_bundles[@]}"; do
  cp -R "$resource_bundle" "$contents/Resources/"
done
mkdir -p "$contents/Resources/ThirdPartyLicenses"
for dependency in swift-cmark SwiftMath; do
  dependency_root="$package_root/.build/checkouts/$dependency"
  if [[ -f "$dependency_root/LICENSE" ]]; then
    cp "$dependency_root/LICENSE" "$contents/Resources/ThirdPartyLicenses/$dependency.txt"
  elif [[ -f "$dependency_root/LICENSE.txt" ]]; then
    cp "$dependency_root/LICENSE.txt" "$contents/Resources/ThirdPartyLicenses/$dependency.txt"
  elif [[ -f "$dependency_root/COPYING" ]]; then
    cp "$dependency_root/COPYING" "$contents/Resources/ThirdPartyLicenses/$dependency.txt"
  fi
done
node "$project_root/scripts/build-study-web.mjs"
cp -R "$project_root/dist/web" "$contents/Resources/StudyWeb"
mkdir -p "$contents/Resources/Bridge/lib"
cp "$project_root/scripts/codex-bridge.mjs" "$contents/Resources/Bridge/codex-bridge.mjs"
cp "$project_root/scripts/claude-code-bridge.mjs" "$contents/Resources/Bridge/claude-code-bridge.mjs"
cp "$project_root/scripts/lib/codex-cli-arguments.mjs" "$contents/Resources/Bridge/lib/codex-cli-arguments.mjs"
cp "$project_root/scripts/lib/codex-images.mjs" "$contents/Resources/Bridge/lib/codex-images.mjs"
cp "$project_root/scripts/lib/codex-model-catalog.mjs" "$contents/Resources/Bridge/lib/codex-model-catalog.mjs"
cp "$project_root/scripts/lib/codex-usage.mjs" "$contents/Resources/Bridge/lib/codex-usage.mjs"
node "$project_root/scripts/build-semantic-runtime.mjs" "$contents/Resources/SemanticSearch"

icon_work="$(mktemp -d "${TMPDIR:-/tmp}/scholia-icon.XXXXXX")"
icon_source="$icon_work/icon.svg.png"
if ! qlmanage -t -s 1024 -o "$icon_work" "$project_root/apps/chrome/assets/icon.svg" >/dev/null 2>&1; then
  icon_source="$project_root/apps/chrome/assets/icon-128.png"
fi
if [[ -f "$icon_source" ]]; then
  if ! sips -s format icns "$icon_source" --out "$contents/Resources/Scholia.icns" >/dev/null 2>&1; then
    iconset="$icon_work/Scholia.iconset"
    mkdir -p "$iconset"
    sips -z 16 16 "$icon_source" --out "$iconset/icon_16x16.png" >/dev/null
    sips -z 32 32 "$icon_source" --out "$iconset/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$icon_source" --out "$iconset/icon_32x32.png" >/dev/null
    sips -z 64 64 "$icon_source" --out "$iconset/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$icon_source" --out "$iconset/icon_128x128.png" >/dev/null
    sips -z 256 256 "$icon_source" --out "$iconset/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$icon_source" --out "$iconset/icon_256x256.png" >/dev/null
    sips -z 512 512 "$icon_source" --out "$iconset/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$icon_source" --out "$iconset/icon_512x512.png" >/dev/null
    cp "$icon_source" "$iconset/icon_512x512@2x.png"
    iconutil -c icns "$iconset" -o "$contents/Resources/Scholia.icns"
  fi
fi

signing_identity="${SCHOLIA_CODESIGN_IDENTITY:-}"
local_signing_identity="${SCHOLIA_LOCAL_CODESIGN_IDENTITY:-Scholia Local Code Signing}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v needle="\"$local_signing_identity\"" 'index($0, needle) { print substr(needle, 2, length(needle) - 2); exit }')"
fi
if [[ -z "$signing_identity" && "${SCHOLIA_AUTO_LOCAL_SIGNING:-1}" == "1" ]]; then
  "$script_dir/setup-macos-signing.sh"
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v needle="\"$local_signing_identity\"" 'index($0, needle) { print substr(needle, 2, length(needle) - 2); exit }')"
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
fi
if [[ "${SCHOLIA_REQUIRE_STABLE_SIGNING:-0}" == "1" && "$signing_identity" == "-" ]]; then
  print -u2 "A stable code-signing identity is required. Run npm run setup:macos-signing, then build again."
  exit 1
fi
codesign_arguments=(--force --deep --sign "$signing_identity" --entitlements "$project_root/apps/macos/Scholia.entitlements")
if [[ "$signing_identity" == Developer\ ID\ Application:* ]]; then
  codesign_arguments+=(--options runtime --timestamp)
elif [[ "$signing_identity" != "-" ]]; then
  codesign_arguments+=(--options runtime)
fi
if [[ "$signing_identity" == "$local_signing_identity" ]]; then
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")"
  certificate_sha1="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v needle="\"$signing_identity\"" 'index($0, needle) { print $2; exit }')"
  if [[ -z "$certificate_sha1" ]]; then
    print -u2 "Could not read the local signing certificate fingerprint."
    exit 1
  fi
  codesign_arguments+=("-r=designated => identifier \"$bundle_id\" and certificate leaf = H\"$certificate_sha1\"")
fi
codesign "${codesign_arguments[@]}" "$app_root"
codesign --verify --deep --strict --verbose=2 "$app_root"
if [[ "$signing_identity" == "-" ]]; then
  print -u2 "Warning: ad-hoc signing cannot preserve macOS privacy grants across rebuilt versions."
  print -u2 "Set SCHOLIA_CODESIGN_IDENTITY or install an Apple signing identity before granting permissions."
else
  printf 'Signed with %s so macOS can retain Accessibility and Screen Recording grants across updates.\n' "$signing_identity"
  codesign -d -r- "$app_root" 2>&1 | sed -n '/designated =>/p'
  if ! codesign --verify -R='anchor apple generic' "$app_root" >/dev/null 2>&1; then
    print -u2 "Keychain uses a per-build fingerprint for local signing; Always Allow may be requested again after an update."
    print -u2 "An Apple Development or Developer ID Application identity gives Keychain a stable team identity across builds."
  fi
fi
osascript -l JavaScript "$script_dir/quit-macos-apps.js" "$output_app"
if [[ -e "$output_app" ]]; then
  mv "$output_app" "$package_work/Previous-Scholia.app"
fi
if ! mv "$app_root" "$output_app"; then
  if [[ -d "$package_work/Previous-Scholia.app" && ! -e "$output_app" ]]; then
    mv "$package_work/Previous-Scholia.app" "$output_app"
  fi
  print -u2 "Could not replace the built app."
  exit 1
fi
rm -rf "$package_work/Previous-Scholia.app"
printf 'Built %s\n' "$output_app"
