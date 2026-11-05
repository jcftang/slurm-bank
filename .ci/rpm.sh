#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
version=$(cat VERSION)
git archive --format=tar --prefix="$version/" HEAD | gzip > "$top/SOURCES/$version.tar.gz"
rpmbuild -ba --without docs --define "_topdir $top" slurm-bank.spec
mapfile -t packages < <(find "$top/RPMS" -name '*.rpm')
test "${#packages[@]}" -eq 1
rpm -qp --requires "${packages[0]}" | tee /tmp/rpm-requires.log
grep -Eq '^perl([[:space:](]|$)' /tmp/rpm-requires.log
grep -Eq '^slurm([[:space:]]|$)' /tmp/rpm-requires.log
dnf install -y "${packages[0]}"
test -f /usr/bin/sbank-bank-common
test -f /usr/bin/shflags
test -f /etc/bash_completion.d/sbank
test -s /usr/share/man/man1/sbank.1
SBANK_TEST_SOURCE=/usr/bin bash t/functional.sh
SBANK_TEST_SOURCE=/usr/bin bash t/test-gpu-bank.sh
mkdir -p artifacts
cp "${packages[@]}" "$top"/SRPMS/*.rpm artifacts/
