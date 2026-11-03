#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
project_root="${script_dir:h}"
package_root="$project_root/apps/macos"
sdk_path="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
sdk_interface="$sdk_path/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
sdk_compiler_version="$(sed -n 's|^// swift-compiler-version: ||p' "$sdk_interface" | head -n 1)"
swift_arguments=(--disable-sandbox --package-path "$package_root" --build-system native --sdk "$sdk_path"
  -Xswiftc -interface-compiler-version -Xswiftc "$sdk_compiler_version")
if [[ " ${*} " != *" --skip-build "* ]]; then swift build "${swift_arguments[@]}"; fi
binary_dir="$(swift build "${swift_arguments[@]}" --show-bin-path)"
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/scholia-paper-live.XXXXXX")"
bridge_pid=""
cleanup() {
  if [[ -n "$bridge_pid" ]]; then kill "$bridge_pid" 2>/dev/null || true; fi
  rm -rf "$smoke_dir"
}
trap cleanup EXIT
export PAPER_LIVE_OUTPUT="$project_root/output/paper-study"
node "$script_dir/prepare-paper-handwriting.mjs"
app_objects=("$binary_dir/ScholiaMac.build/"*.swift.o)
app_objects=("${(@)app_objects:#*/ScholiaMacApp.swift.o}")
swiftc -parse-as-library -sdk "$sdk_path" -target "$(uname -m)-apple-macos14.0" \
  -interface-compiler-version "$sdk_compiler_version" \
  -I "$binary_dir/Modules" \
  -Xcc -fmodule-map-file="$binary_dir/ScholiaSearch.build/module.modulemap" \
  -I "$package_root/.build/checkouts/swift-cmark/src/include" \
  -I "$package_root/.build/checkouts/swift-cmark/extensions/include" \
  "$script_dir/macos-paper-live.swift" "${app_objects[@]}" \
  "$binary_dir/SwiftMath.build/"*.swift.o "$binary_dir/ScholiaSearch.build/"*.o \
  "$binary_dir/cmark_gfm.build/"*.o "$binary_dir/cmark_gfm_extensions.build/"*.o \
  -framework ApplicationServices -framework Carbon -framework CoreGraphics \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework ImageIO -framework PDFKit -framework Security -framework ServiceManagement \
  -framework JavaScriptCore -framework WebKit -framework Vision -framework Quartz -lsqlite3 -lz -o "$smoke_dir/paper-live"
if [[ -z "${PAPER_LIVE_ENDPOINT:-}" ]]; then
  paper_port="$(node --input-type=module -e 'import net from "node:net"; const server=net.createServer(); server.listen(0,"127.0.0.1",()=>{console.log(server.address().port);server.close();});')"
  export PAPER_LIVE_TOKEN="$(node --input-type=module -e 'import {randomBytes} from "node:crypto"; console.log(randomBytes(24).toString("hex"));')"
  export PAPER_LIVE_ENDPOINT="http://127.0.0.1:$paper_port/v1/chat/completions"
  node "$script_dir/codex-bridge.mjs" --port "$paper_port" --timeout 180 --token "$PAPER_LIVE_TOKEN" >"$smoke_dir/bridge.log" 2>&1 &
  bridge_pid=$!
  node --input-type=module -e '
    const url=new URL("/health",process.env.PAPER_LIVE_ENDPOINT);
    let ready=false;
    for(let n=0;n<50;n++) { try { const r=await fetch(url); if(r.ok){ready=true;break;} } catch{} await new Promise(r=>setTimeout(r,100)); }
    if(!ready) throw new Error("The isolated Codex bridge did not become ready.");
  '
fi
"$smoke_dir/paper-live"
