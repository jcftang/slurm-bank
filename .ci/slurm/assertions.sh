#!/usr/bin/env bash
set -euo pipefail
cluster=sbankci
account=ci-bank
export SLURMBANK_LOCK_DIR=${SLURMBANK_LOCK_DIR:?}
# Propagation checks are bounded; mutations themselves are never retried.
wait_for() {
    local attempt status
    for attempt in {1..90}; do
        if "$@"; then
            return 0
        else
            status=$?
            [[ $status -ne 2 ]] || return 2
        fi
        sleep 1
    done
    printf 'Timed out waiting for: %s\n' "$*" >&2
    return 1
}
account_cpu() {
    sacctmgr -nP list associations where cluster="$cluster" account="$account" format=User,GrpCPUMins WOPLimits |
        awk -F'|' '$1 == "" { print $2 }'
}
gpu_synced() {
    local record
    record=$(sshare -M "$cluster" -A "$account" -a -nP -o User,GrpTRESMins)
    printf '%s\n' "$record" | grep -Eq "^\|.*gres/gpu=$1(,|$)"
}
job_completed() {
    local state
    state=$(sacct -nP -j "$1" -o JobIDRaw,State | awk -F'|' -v id="$1" '$1 == id {print $2}')
    case "$state" in
        FAILED*|CANCELLED*|TIMEOUT*|NODE_FAIL*) echo "Job $1 ended in $state" >&2; return 2 ;;
    esac
    [[ $state == COMPLETED ]]
}
submit() {
    runuser -u sbankci -- sbatch --parsable -A "$account" --gres=gpu:1 \
        --cpus-per-task=1 --time="$1" --output=/tmp/sbank-ci-%j.log --wrap='sleep 5'
}

sbank project create -c "$cluster" -a "$account"
test "$(account_cpu)" = 0
sbank deposit -c "$cluster" -a "$account" -t 2
test "$(account_cpu)" = 120
sbank deduct -c "$cluster" -a "$account" -t 1
test "$(account_cpu)" = 60
sacctmgr -i add user sbankci cluster="$cluster" account="$account"
# Raise the CPU allocation so only GPU minutes constrain the jobs below.
sacctmgr -i modify account where cluster="$cluster" account="$account" set GrpCPUMins=12000 GrpTRESMins=gres/gpu=0
wait_for gpu_synced 0
sbank deposit -c "$cluster" -a "$account" -t 2 -r gres/gpu
wait_for gpu_synced 120
sbank deduct -c "$cluster" -a "$account" -t 1 -r gres/gpu
wait_for gpu_synced 60
first=$(submit 00:01:00)
first=${first%%;*}
wait_for job_completed "$first"
echo 'PASS: a job within the GPU-minute budget completes'

blocked=$(submit 02:00:00)
blocked=${blocked%%;*}
blocked_for_gpu_minutes() {
    local row
    row=$(squeue -h -j "$blocked" -o '%T|%r')
    [[ $row == PENDING\|AssocGrpGRESMinutes* || $row == PENDING\|AssocGrpGRESRunMinutes* ]]
}
wait_for blocked_for_gpu_minutes
echo 'PASS: Slurm holds a job that exceeds the GPU-minute budget'
sbank deposit -c "$cluster" -a "$account" -t 2 -r gres/gpu
wait_for gpu_synced 180
wait_for job_completed "$blocked"
echo 'PASS: adding credit releases the same held job'

# Acquire the very same advisory lock used by production, then invoke a second
# real CLI process against the running database. It must refuse to mutate.
before=$(account_cpu)
(
    export SLURMBANK_DIR=/usr/local/bin
    . /usr/local/bin/sbank-common
    . /usr/local/bin/sbank-bank-common
    FLAGS_cluster=$cluster FLAGS_account=$account
    sbank_acquire_lock
    if sbank deposit -c "$cluster" -a "$account" -t 1 > /tmp/contended.out 2>&1; then
        echo 'Concurrent deposit unexpectedly succeeded' >&2
        exit 1
    fi
    grep -q 'another sbank deposit/deduct operation' /tmp/contended.out
)
test "$(account_cpu)" = "$before"
echo 'PASS: concurrent mutation is rejected without changing the limit'
sbank project delete -c "$cluster" -a "$account"
test -z "$(account_cpu)"
echo 'PASS: test account is removed'
