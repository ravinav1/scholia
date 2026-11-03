#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source_app="$project_root/dist/macos/Scholia.app"
destination_app="${SCHOLIA_INSTALL_PATH:-/Applications/Scholia.app}"
migrate_permissions=0
launch_after_install=0
skip_build=0
check_only=0
configuration=debug

for argument in "$@"; do
  case "$argument" in
    --help|-h)
      cat <<'HELP'
Install or update Scholia from this source folder.

Usage: npm run update:macos [-- options]
       npm run install:macos [-- options]

The updater builds the latest local changes, safely replaces
/Applications/Scholia.app, and reopens it. Chats and settings stay in place.
You can also double-click Update Scholia.command or choose Update Scholia
from the installed app's menu.

Options:
  --launch               Open Scholia after installing (default for update:macos).
  --skip-build           Install the already-built copy in dist/macos.
  --check-only           Check signing compatibility without replacing the app.
  --release              Use the slower, fully optimized distribution build.
  --migrate-permissions  Reset stale privacy grants if the signing identity changed.
  --help                 Show this help.

SCHOLIA_INSTALL_PATH overrides /Applications/Scholia.app.
HELP
      exit 0 ;;
    --migrate-permissions) migrate_permissions=1 ;;
    --launch) launch_after_install=1 ;;
    --skip-build) skip_build=1 ;;
    --check-only) check_only=1 ;;
    --release) configuration=release ;;
    *) print -u2 "Unknown option: $argument"; exit 2 ;;
  esac
done

# A second click must not rebuild or replace the app while an update is active.
# The OS releases this lock even if Terminal closes unexpectedly.
installer_lock="${TMPDIR:-/tmp}/scholia-install.lock"
touch "$installer_lock"
zmodload zsh/system
if ! zsystem flock -t 0 -f installer_lock_fd "$installer_lock"; then
  print -u2 "A Scholia update is already running. Wait for it to finish."
  exit 1
fi

if [[ "$skip_build" != "1" ]]; then
  export SCHOLIA_REQUIRE_STABLE_SIGNING=1
  "$script_dir/build-macos-app.sh" "$configuration"
fi

if [[ ! -d "$source_app" ]]; then
  print -u2 "The built app is missing: $source_app"
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$source_app"
signature="$(codesign -dv --verbose=4 "$source_app" 2>&1)"
if [[ "$signature" == *"Signature=adhoc"* ]]; then
  print -u2 "Refusing to install an ad-hoc-signed build because it would lose macOS privacy grants."
  print -u2 "Run npm run setup:macos-signing, then build again."
  exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
if ! codesign --verify -R='anchor apple generic' "$source_app" >/dev/null 2>&1; then
  print -u2 "This build uses local signing. Keychain may ask for Always Allow again because its per-build fingerprint changes."
  print -u2 "Accessibility and Screen Recording identity checks below are separate from Keychain approval."
fi
identity_changed=0
if [[ -d "$destination_app" ]]; then
  old_requirement="$(codesign -d -r- "$destination_app" 2>&1 \
    | sed -n 's/^# designated => //p; s/^designated => //p' \
    | head -n 1)"
  if [[ -z "$old_requirement" ]] \
      || ! codesign --verify --deep --strict -R="$old_requirement" "$source_app" >/dev/null 2>&1; then
    identity_changed=1
  fi
fi

if [[ "$check_only" == "1" ]]; then
  if [[ "$identity_changed" == "1" ]]; then
    printf 'A one-time signing migration is required before future updates can preserve permissions.\n'
  else
    printf 'Update identity is compatible; Accessibility and Screen Recording grants will be preserved.\n'
  fi
  exit 0
fi

destination_parent="${destination_app:h}"
mkdir -p "$destination_parent"
stage_dir="$(mktemp -d "$destination_parent/.scholia-update.XXXXXX")"
cleanup_install() {
  if [[ -d "$stage_dir/Previous-Scholia.app" ]]; then
    print -u2 "The update did not finish. The previous app is preserved at $stage_dir/Previous-Scholia.app"
  else
    rm -rf "$stage_dir"
  fi
}
trap cleanup_install EXIT
staged_app="$stage_dir/Scholia.app"
ditto "$source_app" "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

# Address every instance at these exact bundle paths; AppleScript application
# lookup can resolve to the wrong copy when both have the same bundle identifier.
# Stage and verify first so a failed build/copy does not interrupt the running app.
osascript -l JavaScript "$script_dir/quit-macos-apps.js" "$source_app" "$destination_app"

backup_app=""
if [[ -d "$destination_app" ]]; then
  backup_app="$stage_dir/Previous-Scholia.app"
  mv "$destination_app" "$backup_app"
fi

if ! mv "$staged_app" "$destination_app"; then
  if [[ -n "$backup_app" && -d "$backup_app" && ! -e "$destination_app" ]]; then
    mv "$backup_app" "$destination_app"
  fi
  print -u2 "Installation failed; the previous app was restored."
  exit 1
fi
if ! codesign --verify --deep --strict --verbose=2 "$destination_app"; then
  mv "$destination_app" "$staged_app"
  if [[ -n "$backup_app" && -d "$backup_app" ]]; then
    mv "$backup_app" "$destination_app"
  fi
  print -u2 "Installed app verification failed; the update was rolled back."
  exit 1
fi
if [[ -n "$backup_app" ]]; then
  rm -rf "$backup_app"
fi

if [[ "$identity_changed" == "1" ]]; then
  if [[ "$migrate_permissions" == "1" ]]; then
    tccutil reset Accessibility "$bundle_id" >/dev/null
    tccutil reset ScreenCapture "$bundle_id" >/dev/null
    printf 'Cleared stale Accessibility and Screen Recording entries for the one-time signing migration.\n'
  else
    print -u2 "Signing identity changed. Existing privacy grants cannot carry into this one-time migration."
    print -u2 "Run this installer once with --migrate-permissions, then grant access to the new stable identity."
  fi
else
  printf 'The new build satisfies the installed app requirement; Accessibility and Screen Recording grants are preserved.\n'
fi

printf 'Installed %s\n' "$destination_app"

if [[ "$launch_after_install" == "1" ]]; then
  open "$destination_app"
fi
