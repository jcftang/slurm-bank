#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
make install DESTDIR="$stage" PREFIX=/usr
bin="$stage/usr/bin"
for file in src/sbank src/sbank-* src/*.pl src/shflags; do
    cmp "$file" "$bin/${file##*/}"
done
for file in sbank _sbank-balance.pl _sbank-common-cpu_hrs.pl; do
    test -x "$bin/$file"
done
test -s "$bin/shflags"
test ! -L "$bin/shflags"
for page in sbank sbank-deposit sbank-balance sbank-project sbank-user sbank-time sbank-cluster sbank-submit sbank-version sbank-refund; do
    test -s "$stage/usr/share/man/man1/$page.1"
done
# Invoke the installed entry point directly before running the broader suites.
mkdir "$stage/mock"
printf '#!/bin/sh\nexit 0\n' > "$stage/mock/sacctmgr"
chmod +x "$stage/mock/sacctmgr"
expected=$(sed 's/^slurm-bank-//' VERSION)
test "$(PATH="$stage/mock:$PATH" "$bin/sbank" version)" = "$expected"
SBANK_TEST_SOURCE="$bin" bash t/functional.sh
SBANK_TEST_SOURCE="$bin" bash t/test-gpu-bank.sh
