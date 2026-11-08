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

node scripts/build/build-native-resources.mjs
source_arguments=()
for source in "${sources[@]:1}"; do source_arguments+=(--source "$script_dir/$source"); done
build_arguments=()
if (( skip_build )); then build_arguments+=(--skip-build); fi
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/scholia-$suite.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
run_check() {
  zsh "$project_root/scripts/macos/run-release-check.sh" "${build_arguments[@]}" \
    "$script_dir/${sources[1]}" "${source_arguments[@]}" "$@"
}

case "$suite" in
  workspace)
    python3 "$script_dir/study-format-fixtures.py" "$smoke_dir/fixtures"
    run_check "$package_root/.build/verification" "${suite_arguments[@]}" --fixtures "$smoke_dir/fixtures" ;;
  panels) run_check "$package_root/.build/verification" "${suite_arguments[@]}" ;;
  *) run_check "${suite_arguments[@]}" ;;
esac
