#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
search_bench_dir="$(mktemp -d "${TMPDIR:-/tmp}/needle-native.XXXXXX")"
trap 'rm -rf "$search_bench_dir"' EXIT
search_bench_flags=(-O3)
if [[ "${1:-}" == "--sanitize" ]]; then
  search_bench_flags=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
  shift
  set -- --test "$@"
fi
"${CC:-clang}" "${search_bench_flags[@]}" -D_GNU_SOURCE \
  -I apps/macos/Sources/ScholiaSearch/include \
  apps/macos/Sources/ScholiaSearch/ScholiaSearch.c scripts/benchmark-needle-native.c \
  -lsqlite3 -o "$search_bench_dir/needle-native"
"$search_bench_dir/needle-native" "$@"
