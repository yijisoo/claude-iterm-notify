#!/bin/bash
# Run all test files and report an aggregate result.
# Usage: tests/run.sh [test_file.sh ...]   (default: all test_*.sh)
set -uo pipefail
cd "$(dirname "$0")"

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  files=(test_*.sh)
fi

rc=0
for f in "${files[@]}"; do
  printf '\n========== %s ==========\n' "$f"
  bash "$f" || rc=1
done

printf '\n==============================\n'
if [ "$rc" -eq 0 ]; then
  printf '\033[32mALL SUITES PASSED\033[0m\n'
else
  printf '\033[31mSOME SUITES FAILED\033[0m\n'
fi
exit "$rc"
