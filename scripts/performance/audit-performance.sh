#!/bin/zsh
# Isolated native service audit; UI timings use benchmark-native.swift separately.
set -euo pipefail
script_dir="${0:A:h}"
project_root="${script_dir:h:h}"
exec zsh "$project_root/scripts/macos/run-release-check.sh" \
  "$script_dir/audit-performance.swift" "$@"
