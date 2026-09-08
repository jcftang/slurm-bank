#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/slurm-bank-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
STAGED_SRC="$TMP_ROOT/src"
LOG="$TMP_ROOT/commands.log"
ERR="$TMP_ROOT/stderr"
ASSOC_LIMIT_STATE="$TMP_ROOT/assoc-limit"
mkdir -p "$FAKE_BIN" "$STAGED_SRC"
: > "$LOG"
printf '%s\n' 120 > "$ASSOC_LIMIT_STATE"

export SBANK_TEST_LOG="$LOG"
export ASSOC_LIMIT_STATE
export FAKE_BALANCE=1000
export FAKE_DEFAULT_ACCOUNT=defaultacct
export FAKE_LOCAL_CLUSTER=localcluster
export FAKE_SACCT_ACCOUNT=refundacct
export FAKE_SACCT_ELAPSED=01:00:00
export FAKE_SINFO_OUTPUT=$'16 debug\n32 batch'
export SLURMBANK_LOCK_DIR="$TMP_ROOT/locks"

# Stage the production shell code so helper programs can be replaced without
# modifying the checkout. The real shFlags implementation is still used.
cp "$REPO_ROOT/src/sbank" "$STAGED_SRC/"
cp "$REPO_ROOT/src/sbank-common" "$STAGED_SRC/"
cp "$REPO_ROOT/src/sbank-bank-common" "$STAGED_SRC/"
for command in balance cluster deduct deposit project refund submit time user version; do
    cp "$REPO_ROOT/src/sbank-$command" "$STAGED_SRC/"
done
ln -s "$REPO_ROOT/shFlags/src/shflags" "$STAGED_SRC/shflags"
chmod +x "$STAGED_SRC/sbank"

cat > "$STAGED_SRC/_sbank-balance.pl" <<'EOF_HELPER'
#!/usr/bin/env bash
printf '_sbank-balance.pl %s\n' "$*" >> "$SBANK_TEST_LOG"
printf '%s\n' "${FAKE_BALANCE:-1000}"
EOF_HELPER
chmod +x "$STAGED_SRC/_sbank-balance.pl"

cat > "$STAGED_SRC/_sbank-common-cpu_hrs.pl" <<'EOF_HELPER'
#!/usr/bin/env bash
printf '_sbank-common-cpu_hrs.pl %s\n' "$*" >> "$SBANK_TEST_LOG"
printf '100\n'
EOF_HELPER
chmod +x "$STAGED_SRC/_sbank-common-cpu_hrs.pl"

cat > "$FAKE_BIN/sacctmgr" <<'EOF_FAKE'
#!/usr/bin/env bash
printf 'sacctmgr %s\n' "$*" >> "$SBANK_TEST_LOG"
args="$*"
case "$args" in
    *"list associations"*"Format=Account,User,Partition,ParentName,ID,GrpCPUMins,GrpTRESMins%1000"*"WOPLimits"*)
        account=
        for arg in "$@"; do
            case "$arg" in
                Accounts=*) account=${arg#Accounts=} ;;
            esac
        done
        printf '%s|||root|42|%s|\n' "$account" "$(cat "$ASSOC_LIMIT_STATE")"
        ;;
    *"modify account"*"GrpCPUMins="*)
        for arg in "$@"; do
            case "$arg" in
                GrpCPUMins=*) printf '%s\n' "${arg#GrpCPUMins=}" > "$ASSOC_LIMIT_STATE" ;;
            esac
        done
        ;;
    *"list association cluster="*"format=Account,GrpCPUMins"*)
        printf 'ROOT|0|\nproject-a|6000|\nproject-b|12000|\n'
        ;;
    *"list accounts withassoc"*"accounts=PROJECT-A"*)
        printf 'project-a|alice|\nproject-a|bob|\n'
        ;;
    *"list accounts withassoc"*"users=alice"*)
        printf 'project-a|alice|\nproject-b|alice|\n'
        ;;
    *"list accounts withassoc"*)
        printf 'ROOT|root|\nproject-a|alice|\nproject-a|bob|\nproject-b|alice|\nproject-b|charlie|\n'
        ;;
    *"list associations"*"format=account,GrpCPUMins"*)
        printf 'testacct|%s|\n' "$(cat "$ASSOC_LIMIT_STATE")"
        ;;
    *"list associations"*"format=cluster%30,account%30"*)
        printf 'cluster-a account-a\ncluster-b account-b\n'
        ;;
    *"list cluster"*)
        printf ' cluster-a \n cluster-b \n'
        ;;
    *"list users"*"format=DefaultAccount%30"*)
        printf '%s\n' "${FAKE_DEFAULT_ACCOUNT:-defaultacct}"
        ;;
    *"list users"*)
        printf 'testuser testacct None\n'
        ;;
esac
EOF_FAKE
chmod +x "$FAKE_BIN/sacctmgr"

cat > "$FAKE_BIN/scontrol" <<'EOF_FAKE'
#!/usr/bin/env bash
printf 'scontrol %s\n' "$*" >> "$SBANK_TEST_LOG"
if [ "$*" = "show config" ]; then
    printf 'ClusterName = %s\n' "${FAKE_LOCAL_CLUSTER:-localcluster}"
fi
EOF_FAKE
chmod +x "$FAKE_BIN/scontrol"

cat > "$FAKE_BIN/sinfo" <<'EOF_FAKE'
#!/usr/bin/env bash
printf 'sinfo %s\n' "$*" >> "$SBANK_TEST_LOG"
case "$*" in
    *"-o %C"*"-M all"*)
        printf 'CLUSTER: cluster-a\n0/0/0/16\nCLUSTER: cluster-b\n0/0/0/32\n'
        ;;
    *"-o %C"*)
        printf '0/0/0/32\n'
        ;;
    *)
        printf '%s\n' "${FAKE_SINFO_OUTPUT:-16 debug}"
        ;;
esac
EOF_FAKE
chmod +x "$FAKE_BIN/sinfo"

cat > "$FAKE_BIN/sacct" <<'EOF_FAKE'
#!/usr/bin/env bash
printf 'sacct %s\n' "$*" >> "$SBANK_TEST_LOG"
case "$*" in
    *account*) printf '%s\n' "${FAKE_SACCT_ACCOUNT:-refundacct}" ;;
    *elapsed*) printf '%s\n' "${FAKE_SACCT_ELAPSED:-01:00:00}" ;;
esac
EOF_FAKE
chmod +x "$FAKE_BIN/sacct"

cat > "$FAKE_BIN/sbatch" <<'EOF_FAKE'
#!/usr/bin/env bash
printf 'sbatch %s\n' "$*" >> "$SBANK_TEST_LOG"
printf 'Submitted batch job 4242\n'
EOF_FAKE
chmod +x "$FAKE_BIN/sbatch"

cat > "$FAKE_BIN/sshare" <<'EOF_FAKE'
#!/usr/bin/env bash
printf 'sshare %s\n' "$*" >> "$SBANK_TEST_LOG"
args=" $* "
if [[ "$args" != *" -a "* ]]; then
    # Without -a, sshare returns only the invoking/selected user's rows.
    printf 'project-a||x|x|36000|\nproject-a|alice|x|x|7200|\nproject-b||x|x|72000|\nproject-b|alice|x|x|14400|\n'
elif [[ "$*" == *,* ]]; then
    printf 'ROOT||x|x|0|\nROOT|root|x|x|0|\nproject-a||x|x|36000|\nproject-a|alice|x|x|7200|\nproject-a|bob|x|x|3600|\nproject-b||x|x|72000|\nproject-b|alice|x|x|14400|\nproject-b|charlie|x|x|18000|\n'
elif [[ "$*" == *"-A PROJECT-A"* ]]; then
    printf 'project-a||x|x|36000|\nproject-a|alice|x|x|7200|\nproject-a|bob|x|x|3600|\n'
elif [[ "$*" == *"-A PROJECT-B"* ]]; then
    printf 'project-b||x|x|72000|\nproject-b|alice|x|x|14400|\nproject-b|charlie|x|x|18000|\n'
else
    printf 'ROOT||x|x|0|\nROOT|root|x|x|0|\nproject-a||x|x|36000|\nproject-a|alice|x|x|7200|\nproject-a|bob|x|x|3600|\nproject-b||x|x|72000|\nproject-b|alice|x|x|14400|\nproject-b|charlie|x|x|18000|\n'
fi
EOF_FAKE
chmod +x "$FAKE_BIN/sshare"

cat > "$FAKE_BIN/sreport" <<'EOF_FAKE'
#!/usr/bin/env bash
printf 'sreport %s\n' "$*" >> "$SBANK_TEST_LOG"
case "$*" in
    *"account=PROJECT-A"*)
        printf 'localcluster|project-a||x|900|\nlocalcluster|project-a|alice|x|120|\nlocalcluster|project-a|bob|x|60|\n'
        ;;
    *)
        printf 'localcluster|project-a||x|900|\nlocalcluster|project-a|alice|x|120|\nlocalcluster|project-b||x|1200|\nlocalcluster|project-b|alice|x|240|\n'
        ;;
esac
EOF_FAKE
chmod +x "$FAKE_BIN/sreport"

# The application uses bc for two simple arithmetic expressions. Keeping a
# fake here makes the suite independent of optional distro packages.
cat > "$FAKE_BIN/bc" <<'EOF_FAKE'
#!/usr/bin/env bash
expr=$(cat)
case "$expr" in
    *';'*) expr=${expr#*;} ;;
esac
awk "BEGIN { print $expr }"
EOF_FAKE
chmod +x "$FAKE_BIN/bc"

export PATH="$STAGED_SRC:$FAKE_BIN:/usr/bin:/bin"
SBANK="$STAGED_SRC/sbank"

TESTS=0
FAILURES=0
OUT=''
RC=0
STDERR=''

ok() {
    TESTS=$((TESTS + 1))
    printf 'ok %d - %s\n' "$TESTS" "$1"
}

not_ok() {
    TESTS=$((TESTS + 1))
    FAILURES=$((FAILURES + 1))
    printf 'not ok %d - %s\n' "$TESTS" "$1"
    [ $# -gt 1 ] && printf '  %s\n' "$2"
}

run() {
    : > "$ERR"
    set +e
    OUT=$("$@" 2>"$ERR")
    RC=$?
    set -e
    STDERR=$(cat "$ERR")
}

assert_eq() {
    local expected=$1 actual=$2 name=$3
    if [ "$actual" = "$expected" ]; then
        ok "$name"
    else
        not_ok "$name" "expected=[$expected] actual=[$actual]"
    fi
}

assert_rc() {
    local expected=$1 name=$2
    if [ "$RC" -eq "$expected" ]; then
        ok "$name"
    else
        not_ok "$name" "expected rc=$expected actual rc=$RC; stderr=[$STDERR]"
    fi
}

assert_contains() {
    local haystack=$1 needle=$2 name=$3
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        ok "$name"
    else
        not_ok "$name" "missing [$needle] in [$haystack]"
    fi
}

assert_log_contains() {
    local needle=$1 name=$2
    if grep -Fq -- "$needle" "$LOG"; then
        ok "$name"
    else
        not_ok "$name" "missing log entry [$needle]; log=[$(cat "$LOG")]"
    fi
}

assert_log_not_contains() {
    local needle=$1 name=$2
    if grep -Fq -- "$needle" "$LOG"; then
        not_ok "$name" "unexpected log entry [$needle]; log=[$(cat "$LOG")]"
    else
        ok "$name"
    fi
}

reset_log() {
    : > "$LOG"
}

make_job() {
    local file=$1
    shift
    {
        printf '#!/bin/bash\n'
        while [ $# -gt 0 ]; do
            printf '#SBATCH %s\n' "$1"
            shift
        done
        printf 'hostname\n'
    } > "$file"
}

printf 'TAP version 13\n'

run "$SBANK"
assert_rc 1 'top-level invocation without a command fails'
assert_contains "$OUT" 'Available commands are:' 'top-level usage lists commands'

run "$SBANK" does-not-exist
assert_rc 1 'unknown command fails'
assert_contains "$OUT" 'Available commands are:' 'unknown command prints usage'

run "$SBANK" version
assert_rc 0 'version command succeeds'
assert_eq '1.4.3' "$OUT" 'version command reports expected version'

run "$SBANK" time calc -t 4-00:00:00
assert_eq '96' "$OUT" 'time calc handles days-hours:minutes:seconds'
run "$SBANK" time calc -t 2-03:15
assert_eq '51' "$OUT" 'time calc handles days-hours:minutes'
run "$SBANK" time calc -t 2-03
assert_eq '51' "$OUT" 'time calc handles days-hours'
run "$SBANK" time calc -t 03:01:00
assert_eq '3' "$OUT" 'time calc handles hours:minutes:seconds'
run "$SBANK" time calc -t 61:00
assert_eq '1' "$OUT" 'time calc handles minutes:seconds'
run "$SBANK" time calc -t 60
assert_eq '1' "$OUT" 'time calc handles minutes'
run "$SBANK" time calc -t 1
assert_eq '1' "$OUT" 'time calc rounds a sub-hour request up to one hour'

run "$SBANK" time estimate -n 32 -t 4
assert_eq '128' "$OUT" 'time estimate computes task-hours'
run "$SBANK" time estimate -N 2 -c 8 -t 3
assert_eq '48' "$OUT" 'time estimate computes node core-hours'
run "$SBANK" time estimate -N 2 -t 1
assert_eq '64' "$OUT" 'time estimate discovers cores per node when omitted'
run "$SBANK" time estimate -t 1
assert_rc 1 'time estimate rejects requests without nodes or tasks'
run "$SBANK" time estimate -n 2 -t 0
assert_rc 1 'time estimate rejects zero time'

JOB_TASKS="$TMP_ROOT/job-tasks.sh"
make_job "$JOB_TASKS" '-t 02:00:00' '-n 4' '-A testacct'
run "$SBANK" time estimatescript -s "$JOB_TASKS"
assert_eq '8' "$OUT" 'time estimatescript computes task-based script cost'

JOB_NODES="$TMP_ROOT/job-nodes.sh"
make_job "$JOB_NODES" '-t 01:00:00' '-N 2' '-c 8' '-A testacct'
run "$SBANK" time estimatescript -s "$JOB_NODES"
assert_eq '16' "$OUT" 'time estimatescript computes node-based script cost'

run "$SBANK" time estimatescript -s "$TMP_ROOT/missing.sh"
assert_rc 1 'time estimatescript rejects missing files'

reset_log
run "$SBANK" cluster list
assert_eq 'localcluster' "$OUT" 'cluster list returns local cluster'
assert_log_contains 'scontrol show config' 'cluster list queries scontrol'

reset_log
run "$SBANK" cluster list -a
assert_contains "$OUT" 'cluster-a' 'cluster list --all includes first accounting cluster'
assert_contains "$OUT" 'cluster-b' 'cluster list --all includes second accounting cluster'
assert_log_contains 'sacctmgr -n list cluster format=cluster%30' 'cluster list --all queries sacctmgr'

reset_log
run "$SBANK" cluster cpupernode
assert_eq '32' "$OUT" 'cluster cpupernode returns maximum by default'
run "$SBANK" cluster cpupernode -m
assert_eq '16' "$OUT" 'cluster cpupernode --min returns minimum'
run "$SBANK" cluster cpupernode -c remote
assert_log_contains 'sinfo -h --format %c %P -Mremote' 'cluster cpupernode forwards cluster selection'

reset_log
run "$SBANK" cluster create -c newcluster
assert_rc 0 'cluster create succeeds with fake accounting backend'
assert_log_contains 'sacctmgr -i create cluster newcluster' 'cluster create emits expected sacctmgr mutation'
run "$SBANK" cluster delete -c newcluster
assert_log_contains 'sacctmgr -i delete cluster newcluster' 'cluster delete emits expected sacctmgr mutation'

reset_log
run "$SBANK" cluster cpuhrs -c remote
assert_log_contains '_sbank-common-cpu_hrs.pl -t hours -i year -M remote' 'cluster cpuhrs reports yearly usage'
assert_log_contains '_sbank-common-cpu_hrs.pl -t hours -i month -M remote' 'cluster cpuhrs reports monthly usage'
assert_log_contains '_sbank-common-cpu_hrs.pl -t hours -i week -M remote' 'cluster cpuhrs reports weekly usage'
assert_log_contains '_sbank-common-cpu_hrs.pl -t hours -i day -M remote' 'cluster cpuhrs reports daily usage'

reset_log
run "$SBANK" project create -c cluster-a -a project-a
assert_log_contains 'sacctmgr -i add account project-a cluster=cluster-a parent=root GrpCPUMins=0' 'project create initializes zero-minute account'
run "$SBANK" project delete -c cluster-a -a project-a
assert_log_contains 'sacctmgr -i delete account project-a cluster=cluster-a parent=root' 'project delete removes expected account'
run "$SBANK" project expire -c cluster-a -a project-a
assert_log_contains 'sacctmgr -i modify account account=project-a set GrpCPUMins=0 where cluster=cluster-a' 'project expire zeroes account limit'

reset_log
run "$SBANK" project useradd -c cluster-a -a project-a -u alice
assert_log_contains 'sacctmgr -i add user alice account=project-a cluster=cluster-a' 'project useradd creates association'
assert_log_contains 'sacctmgr -i update users cluster=cluster-a set DefaultAccount=project-a where user=alice,cluster=cluster-a' 'project useradd sets default account by default'
run "$SBANK" project userdel -c cluster-a -a project-a -u alice
assert_log_contains 'sacctmgr -i delete user alice account=project-a cluster=cluster-a' 'project userdel removes association'

reset_log
run "$SBANK" project list -c cluster-a
assert_contains "$OUT" 'cluster-a account-a' 'project list returns accounting associations'
assert_log_contains 'cluster=cluster-a' 'project list filters by cluster'

reset_log
run "$SBANK" user create -c cluster-a -a project-a -u alice
assert_log_contains 'sacctmgr -i add user cluster=cluster-a name=alice account=project-a' 'user create emits expected sacctmgr mutation'
run "$SBANK" user list -c cluster-a -a project-a -u alice
assert_contains "$OUT" 'testuser testacct None' 'user list returns fake user data'
assert_log_contains 'cluster=cluster-a' 'user list forwards cluster filter'
assert_log_contains 'DefaultAccount=project-a' 'user list forwards account filter'
assert_log_contains 'names=alice' 'user list forwards username filter'

run "$SBANK" user account -u alice
assert_contains "$OUT" 'defaultacct' 'user account returns default account'
reset_log
OLD_USER=${USER:-}
export USER=bob
run "$SBANK" user account
export USER=$OLD_USER
assert_log_contains 'names=bob' 'user account falls back to current USER'

printf '%s\n' 120 > "$ASSOC_LIMIT_STATE"
reset_log
run "$SBANK" deposit -c cluster-a -a project-a -t 2
assert_rc 0 'deposit succeeds'
assert_log_contains 'sacctmgr -i modify account account=project-a set GrpCPUMins=240 where cluster=cluster-a' 'deposit adds hours converted to minutes'

reset_log
run "$SBANK" deposit -c cluster-a -a project-a -t 0
assert_rc 0 'zero-hour deposit is a no-op'
assert_log_not_contains 'modify account' 'zero-hour deposit does not mutate accounting limit'

printf '%s\n' 300 > "$ASSOC_LIMIT_STATE"
reset_log
run "$SBANK" deduct -c cluster-a -a project-a -t 2
assert_log_contains 'sacctmgr -i modify account account=project-a set GrpCPUMins=180 where cluster=cluster-a' 'deduct subtracts hours converted to minutes'

export FAKE_BALANCE=1000
reset_log
run "$SBANK" balance statement -c cluster-a -a project-a -u alice -s 2026-01-01 -A -U
assert_eq '1000' "$OUT" 'balance statement returns helper result'
assert_log_contains '_sbank-balance.pl -c cluster-a -a project-a -u alice -s 2026-01-01 -A -U' 'balance statement forwards all filters'

run "$SBANK" balance request -c cluster-a -a project-a -t 250
assert_eq '750' "$OUT" 'balance request returns post-request balance'
run "$SBANK" balance request -c cluster-a -a project-a -t 1200
assert_eq '-200' "$OUT" 'balance request returns negative balance when insufficient'
assert_contains "$STDERR" 'does not have enough time' 'balance request warns when insufficient'

export FAKE_DEFAULT_ACCOUNT=defaultacct
export FAKE_LOCAL_CLUSTER=localcluster
run "$SBANK" balance request -t 100
assert_eq '900' "$OUT" 'balance request discovers default account and local cluster'
assert_contains "$STDERR" 'using default: defaultacct' 'balance request reports default-account fallback'

export FAKE_BALANCE=100
run "$SBANK" balance checkscript -c cluster-a -s "$JOB_TASKS"
assert_eq '92' "$OUT" 'balance checkscript estimates script and checks remaining balance'

export FAKE_BALANCE=100
reset_log
run "$SBANK" submit -s "$JOB_TASKS"
assert_rc 0 'submit completes when mock balance check succeeds'
assert_log_contains 'sbatch ' 'submit invokes sbatch'
assert_log_contains "$JOB_TASKS" 'submit passes script path to backend commands'

printf '%s\n' 120 > "$ASSOC_LIMIT_STATE"
export FAKE_SACCT_ELAPSED=01:00:00
reset_log
run "$SBANK" refund job -a project-a -j 123
assert_rc 0 'refund with explicit account succeeds'
assert_log_contains 'sacct -n --format elapsed%30 -j 123' 'refund reads job elapsed time'
assert_log_contains 'set GrpCPUMins=180 where cluster=localcluster' 'refund deposits elapsed hours into local cluster account'

printf '%s\n' 120 > "$ASSOC_LIMIT_STATE"
export FAKE_SACCT_ACCOUNT=refundacct
reset_log
run "$SBANK" refund job -j 456
assert_log_contains 'sacct -n --format account%30 -j 456' 'refund discovers account from job when omitted'
assert_log_contains 'account=refundacct set GrpCPUMins=180 where cluster=localcluster' 'refund credits discovered job account'

run "$SBANK" refund job -j 0
assert_rc 1 'refund rejects non-positive job ids'

# Exercise the real Perl balance helper with deterministic Slurm command data.
BALANCE_HELPER="$REPO_ROOT/src/_sbank-balance.pl"
run perl "$BALANCE_HELPER" -c localcluster -b project-a
assert_rc 0 'Perl balance helper raw-balance query succeeds'
assert_eq '90' "$OUT" 'Perl balance helper converts minute limit and second usage to hours'

run perl "$BALANCE_HELPER" -c localcluster -a project-a
assert_rc 0 'Perl balance helper named-account report succeeds'
assert_contains "$OUT" 'PROJECT-A' 'Perl balance helper normalizes account names'
assert_contains "$OUT" 'alice' 'Perl balance helper includes first account user'
assert_contains "$OUT" 'bob' 'Perl balance helper includes second account user'
assert_contains "$OUT" '100' 'Perl balance helper formats account limit in hours'
assert_contains "$OUT" '90' 'Perl balance helper formats available hours'

run perl "$BALANCE_HELPER" -c localcluster -A
assert_rc 0 'Perl balance helper all-account report succeeds'
assert_contains "$OUT" 'PROJECT-B' 'Perl balance helper reports multiple accounts'
assert_contains "$OUT" 'charlie' 'Perl balance helper reports users across accounts'

run perl "$BALANCE_HELPER" -c localcluster -u alice -U
assert_rc 0 'Perl balance helper user-only report succeeds'
assert_contains "$OUT" 'alice' 'Perl balance helper user-only report includes selected user'
assert_contains "$OUT" 'PROJECT-A' 'Perl balance helper user-only report includes first membership'
assert_contains "$OUT" 'PROJECT-B' 'Perl balance helper user-only report includes second membership'

run perl "$BALANCE_HELPER" -c localcluster -a project-a -s 2026-01-01
assert_rc 0 'Perl balance helper historical sreport mode succeeds'
assert_contains "$OUT" 'User/Account Utilisation' 'Perl balance helper historical mode uses historical header'
assert_contains "$OUT" 'alice' 'Perl balance helper historical mode parses user usage'
assert_log_contains 'sreport -t minutes -np cluster AccountUtilizationByUser' 'Perl balance helper invokes sreport for historical mode'

run perl "$BALANCE_HELPER" -c localcluster -b missing
if [ "$RC" -ne 0 ]; then ok 'Perl balance helper rejects unknown accounts'; else not_ok 'Perl balance helper rejects unknown accounts' 'expected non-zero status'; fi
assert_contains "$STDERR" "account 'MISSING' doesn't exist" 'Perl balance helper explains unknown-account error'

run perl "$BALANCE_HELPER" -c localcluster -b project-a -s 2026-01-01
if [ "$RC" -ne 0 ]; then ok 'Perl balance helper rejects historical raw-balance mode'; else not_ok 'Perl balance helper rejects historical raw-balance mode' 'expected non-zero status'; fi
assert_contains "$STDERR" "doesn't make sense for the unformatted balance query" 'Perl balance helper explains incompatible options'

CPU_HELPER="$REPO_ROOT/src/_sbank-common-cpu_hrs.pl"
if perl -MSwitch -e 1 >/dev/null 2>&1; then
    run perl "$CPU_HELPER" -M localcluster -i day -t hours
    assert_rc 0 'CPU-hours helper day report succeeds'
    assert_contains "$OUT" 'Cores =     32' 'CPU-hours helper parses total core count'
    assert_contains "$OUT" 'Period = day' 'CPU-hours helper reports requested interval'
    assert_contains "$OUT" '768 hrs' 'CPU-hours helper calculates daily available CPU hours'

    run perl "$CPU_HELPER" -M localcluster -p debug -i week -t minutes
    assert_contains "$OUT" 'Partition = debug' 'CPU-hours helper forwards and reports partition'
    assert_contains "$OUT" '322,560 mins' 'CPU-hours helper formats weekly CPU minutes'

    run perl "$CPU_HELPER" -M all -i day -t hours
    assert_contains "$OUT" 'Cluster = cluster-a' 'CPU-hours helper parses first federated cluster'
    assert_contains "$OUT" 'Cluster = cluster-b' 'CPU-hours helper parses second federated cluster'
    assert_contains "$OUT" '384 hrs' 'CPU-hours helper calculates first cluster capacity'
    assert_contains "$OUT" '768 hrs' 'CPU-hours helper calculates second cluster capacity'
else
    ok 'CPU-hours helper tests # SKIP Perl Switch module is not installed'
fi

printf '1..%d\n' "$TESTS"
if [ "$FAILURES" -ne 0 ]; then
    printf '# %d of %d assertions failed\n' "$FAILURES" "$TESTS" >&2
    exit 1
fi
printf '# all %d assertions passed\n' "$TESTS"
