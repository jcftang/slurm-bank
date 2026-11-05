#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(sed 's/^slurm-bank-//' VERSION)
shell_version=$(sed -n 's/^SBANK_VERSION=//p' src/sbank-version)
rpm_version=$(awk '/^Version:/ { print $2 }' slurm-bank.spec)
test "$version" = "$shell_version"
test "$version" = "$rpm_version"
make build
for page in *.1; do
    test -s "$page"
    groff -Tutf8 -man "$page" > /dev/null
done
mkdir -p artifacts
# Unlike make dist, this does not depend on a remote html branch.
git archive --format=tar --prefix="slurm-bank-$version/" HEAD | gzip > "artifacts/slurm-bank-$version.tar.gz"
archive=$(mktemp -d)
trap 'rm -rf "$archive"' EXIT
tar -xzf "artifacts/slurm-bank-$version.tar.gz" -C "$archive"
test -f "$archive/slurm-bank-$version/slurm-bank.spec"
test -f "$archive/slurm-bank-$version/src/sbank-bank-common"
test -e "$archive/slurm-bank-$version/src/shflags"
make -C "$archive/slurm-bank-$version" build
