#!/bin/zsh
# Bound and diagnose compiler stalls on CI while preserving release optimization.
set -euo pipefail
mode="${1:?Pass build or test}"
[[ "$mode" == build || "$mode" == test ]] || exit 2
script_dir="${0:A:h}"
project_root="${script_dir:h:h}"
cd "$project_root"
log_root="$project_root/results/performance/ci-native"
mkdir -p "$log_root"
swift "$mode" --package-path apps/macos --configuration release --build-system native --jobs 4 &
build_pid=$!
(
  for iteration in {1..18}; do
    sleep 60
    kill -0 "$build_pid" 2>/dev/null || exit 0
    ps -axo pid,ppid,etime,pcpu,rss,comm | awk '/swift|clang/ { print }' > "$log_root/$mode-processes-$iteration.txt"
    if (( iteration == 3 || iteration == 8 || iteration == 15 )); then
      for compiler_pid in ${(f)$(pgrep -x swift-frontend || true)}; do
        sample "$compiler_pid" 1 -file "$log_root/$mode-sample-$iteration-$compiler_pid.txt" >/dev/null 2>&1 || true
      done
    fi
    if (( iteration == 18 )); then
      print -u2 "Native release $mode exceeded 18 minutes; compiler samples are in $log_root"
      kill -TERM "$build_pid" 2>/dev/null || true
    fi
  done
) &
monitor_pid=$!
trap 'kill "$monitor_pid" 2>/dev/null || true' EXIT
build_status=0
wait "$build_pid" || build_status=$?
exit "$build_status"
