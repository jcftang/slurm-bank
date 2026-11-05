#!/usr/bin/env bash
# This script creates a private accounting database INSIDE the disposable image.
set -euo pipefail
cd /opt/slurm-bank
test "$(id -u)" -eq 0
test "$(hostname)" = sbank-ci
mkdir -p /artifacts /run/munge /run/mysqld /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
chown munge:munge /run/munge
chown mysql:mysql /run/mysqld
chown slurm:slurm /var/log/slurm /var/spool/slurmctld
pids=()
finish() {
    status=$?
    trap - EXIT
    squeue -a -o '%.18i %.9P %.8j %.8u %.2t %.10M %.6D %R' > /artifacts/squeue.log 2>&1 || true
    sacctmgr -nP list associations > /artifacts/associations.log 2>&1 || true
    sshare -a -l > /artifacts/sshare.log 2>&1 || true
    cp /var/log/slurm/*.log /artifacts/ 2>/dev/null || true
    if ((${#pids[@]})); then kill "${pids[@]}" 2>/dev/null || true; fi
    exit "$status"
}
trap finish EXIT
wait_for() {
    local attempt
    for attempt in {1..90}; do
        if "$@"; then return 0; fi
        sleep 1
    done
    printf 'Timed out waiting for: %s\n' "$*" >&2
    return 1
}

if [[ ! -s /etc/munge/munge.key ]]; then
    head -c 1024 /dev/urandom > /etc/munge/munge.key
fi
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
runuser -u munge -- /usr/sbin/munged --foreground > /artifacts/munge.log 2>&1 &
pids+=("$!")
wait_for bash -c 'munge -n | unmunge >/dev/null 2>&1'
if [[ ! -d /var/lib/mysql/mysql ]]; then
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql
fi
mariadbd --user=mysql --bind-address=127.0.0.1 --innodb-buffer-pool-size=64M \
    --socket=/run/mysqld/mysqld.sock > /artifacts/mariadb.log 2>&1 &
pids+=("$!")
wait_for mariadb-admin ping --silent
mariadb <<'SQL'
CREATE DATABASE slurm_acct_db;
CREATE USER 'slurm'@'localhost' IDENTIFIED BY 'ci-only-password';
GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost';
SQL
cat > /etc/slurm/slurmdbd.conf <<'CONF'
AuthType=auth/munge
DbdHost=sbank-ci
SlurmUser=slurm
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=slurm
StoragePass=ci-only-password
StorageLoc=slurm_acct_db
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd.pid
CONF
chown slurm:slurm /etc/slurm/slurmdbd.conf
chmod 600 /etc/slurm/slurmdbd.conf
cat > /etc/slurm/slurm.conf <<'CONF'
ClusterName=sbankci
SlurmctldHost=sbank-ci
SlurmUser=slurm
AuthType=auth/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU
SlurmdParameters=config_overrides
PriorityType=priority/multifactor
PriorityDecayHalfLife=0
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=sbank-ci
AccountingStorageTRES=gres/gpu
AccountingStorageEnforce=safe
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=5
GresTypes=gpu
SchedulerParameters=default_queue_depth=100
NodeName=sbank-ci CPUs=2 RealMemory=512 Gres=gpu:1 State=UNKNOWN
PartitionName=debug Nodes=sbank-ci Default=YES MaxTime=03:00:00 State=UP
CONF
# A stand-in device is enough to test GPU-minute accounting and scheduling.
# This does not test GPU hardware, drivers, or device isolation.
printf 'NodeName=sbank-ci Name=gpu File=/dev/null\n' > /etc/slurm/gres.conf
printf 'CgroupPlugin=disabled\n' > /etc/slurm/cgroup.conf
slurmdbd -D > /artifacts/slurmdbd-console.log 2>&1 &
pids+=("$!")
wait_for sacctmgr -nP list cluster
sacctmgr -i add cluster sbankci
slurmctld -D > /artifacts/slurmctld-console.log 2>&1 &
pids+=("$!")
slurmd -D > /artifacts/slurmd-console.log 2>&1 &
pids+=("$!")
node_ready() { sinfo -h -o '%T' | grep -Eq '^idle$'; }
wait_for node_ready
cluster_has_gpu() { sacctmgr -nP list cluster format=Cluster,TRES%1000 | grep -q 'gres/gpu='; }
wait_for cluster_has_gpu
export SLURMBANK_LOCK_DIR=/tmp/sbank-locks
bash .ci/slurm/assertions.sh
