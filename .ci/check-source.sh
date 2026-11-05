#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
shopt -s globstar
cd "$(dirname "$0")/.."
shell_files=(src/sbank src/sbank-* src/sbank.bash_completion t/*.sh .ci/**/*.sh wvtest.sh)
bash_files=()
for file in "${shell_files[@]}"; do
    [[ $file == *.pl ]] && continue
    bash -n "$file"
    [[ $file == src/sbank-common ]] || bash_files+=("$file")
done
# Enforce error-level rules; broader legacy warnings need separate cleanup.
shellcheck --shell=bash --severity=error "${bash_files[@]}"
# Baseline four legacy logging calls that deliberately flatten "$@".
shellcheck --shell=bash --severity=error --exclude=SC2145 src/sbank-common
sh -n bump-version expiredb/expireprojects.sh
shellcheck --shell=sh --severity=error bump-version expiredb/expireprojects.sh
for file in src/*.pl mdwn2man wvtestrun; do
    perl -c "$file"
done
