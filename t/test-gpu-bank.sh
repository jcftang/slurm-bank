#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "${HERE}/.." && pwd)
SOURCE_DIR=${SBANK_TEST_SOURCE:-$ROOT/src}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/locks" "$TMP/state"

cat > "$TMP/bin/sacctmgr" <<'EOS'
#!/usr/bin/env bash
set -u
S=${MOCK_STATE:?}
args="$*"
if [[ "$args" == *"list associations"* ]]; then
  [[ "$args" == *"WOPLimits"* ]] || exit 3
  acct=$(cat "$S/account")
  parent=$(cat "$S/parent")
  cpu=$(cat "$S/cpu")
  gpu=$(cat "$S/gpu")
  if [ "$gpu" = unset ]; then gfield=""; else gfield="gres/gpu=$gpu"; fi
  if [ -f "$S/assoc_extra_user" ]; then echo "$acct|user1||$parent|101|$cpu|$gfield"; fi
  echo "$acct|||$parent|42|$cpu|$gfield"
  exit 0
fi
if [[ "$args" == *"list cluster"* ]]; then
  if [ "$(cat "$S/tracked")" = yes ]; then
    echo "$(cat "$S/cluster")|billing=1,cpu=64,gres/gpu=4"
  else
    echo "$(cat "$S/cluster")|billing=1,cpu=64"
  fi
  exit 0
fi
if [[ "$args" == *"modify account"* ]]; then
  if [ -f "$S/sleep_modify" ]; then sleep 2; fi
  if [ -f "$S/fail_modify" ]; then exit 1; fi
  for a in "$@"; do
    case "$a" in
      GrpTRESMins=gres/gpu=*) echo "${a##*=}" > "$S/gpu" ;;
      GrpCPUMins=*) echo "${a##*=}" > "$S/cpu" ;;
    esac
  done
  exit 0
fi
exit 2
EOS
chmod +x "$TMP/bin/sacctmgr"

cat > "$TMP/bin/sshare" <<'EOS'
#!/usr/bin/env bash
set -u
S=${MOCK_STATE:?}
if [ -f "$S/fail_sshare" ]; then exit 1; fi
acct=$(cat "$S/account")
gpu=$(cat "$S/gpu")
used=$(cat "$S/used")
run=$(cat "$S/run")
share_gpu="$gpu"
[ -f "$S/share_gpu_override" ] && share_gpu=$(cat "$S/share_gpu_override")
if [ "$share_gpu" = unset ]; then limits=""; else limits="gres/gpu=$share_gpu"; fi
if [ "$used" = 0 ]; then raw=""; else raw="gres/gpu=$used"; fi
if [ "$run" = 0 ]; then running=""; else running="gres/gpu=$run"; fi
echo "CLUSTER: $(cat "$S/cluster")"
if [ -f "$S/sshare_extra_account" ]; then echo "42||$limits|$raw|$running"; fi
if [ -f "$S/sshare_child_account" ]; then echo "43||gres/gpu=9999|gres/gpu=9000|gres/gpu=900"; fi
echo "42||$limits|$raw|$running"
if [ -f "$S/bump_run_after_first" ]; then
  count=0; [ -f "$S/sshare_count" ] && count=$(cat "$S/sshare_count")
  count=$((count + 1)); echo "$count" > "$S/sshare_count"
  if [ "$count" -eq 1 ]; then cat "$S/bump_run_after_first" > "$S/run"; fi
fi
EOS
chmod +x "$TMP/bin/sshare"

cat > "$TMP/bin/scontrol" <<'EOS'
#!/usr/bin/env bash
set -u
S=${MOCK_STATE:?}
priority=${MOCK_PRIORITY_TYPE:-priority/multifactor}
enforce=${MOCK_ENFORCE:-safe}
tres=${MOCK_ACCOUNTING_TRES:-gres/gpu,billing,cpu,mem,node}
echo "PriorityType             = $priority"
echo "AccountingStorageTRES    = $tres"
echo "AccountingStorageEnforce = $enforce"
EOS
chmod +x "$TMP/bin/scontrol"

init_state() {
  echo gpuacct > "$TMP/state/account"
  echo tcluster > "$TMP/state/cluster"
  echo root > "$TMP/state/parent"
  echo 6000 > "$TMP/state/cpu"
  echo unset > "$TMP/state/gpu"
  echo 0 > "$TMP/state/used"
  echo 0 > "$TMP/state/run"
  echo yes > "$TMP/state/tracked"
  rm -f "$TMP/state"/fail_* "$TMP/state"/*override "$TMP/state"/assoc_extra_user "$TMP/state"/sshare_extra_account "$TMP/state"/sshare_child_account "$TMP/state"/bump_run_after_first "$TMP/state"/sshare_count
}

run_cmd() {
  local which=$1; shift
  (
    export MOCK_STATE="$TMP/state" PATH="$TMP/bin:$PATH" SLURMBANK_LOCK_DIR="$TMP/locks" SLURMBANK_DIR="$SOURCE_DIR"
    SACCTMGR="$TMP/bin/sacctmgr"
    FLAGS_TRUE=0; FLAGS_FALSE=1; FLAGS_debug=1
    debug(){ :; }
    die(){ echo "ERROR:$*" >&2; exit 1; }
    declare -A fmap smap
    DEFINE_string(){ local n=$1 d=$2 s=$4; eval "FLAGS_${n}=\"$d\""; fmap[$n]=$n; smap[$s]=$n; }
    FLAGS(){
      while [ $# -gt 0 ]; do
        case "$1" in
          --account) FLAGS_account=$2; shift 2;; -a) FLAGS_account=$2; shift 2;;
          --cluster) FLAGS_cluster=$2; shift 2;; -c) FLAGS_cluster=$2; shift 2;;
          --time) FLAGS_time=$2; shift 2;; -t) FLAGS_time=$2; shift 2;;
          --tres) FLAGS_tres=$2; shift 2;; -r) FLAGS_tres=$2; shift 2;;
          *) echo "bad arg $1" >&2; return 2;;
        esac
      done
      FLAGS_ARGV=''
    }
    . "$SOURCE_DIR/sbank-$which"
    "cmd_$which" "$@"
  )
}

pass=0; fail=0
ok(){ echo "ok - $1"; pass=$((pass+1)); }
notok(){ echo "NOT OK - $1"; fail=$((fail+1)); }
expect_ok(){ local name=$1; shift; if "$@" >"$TMP/test.out" 2>"$TMP/test.err"; then ok "$name"; else cat "$TMP/test.err"; notok "$name"; fi; }
expect_fail(){ local name=$1; shift; if "$@" >"$TMP/test.out" 2>"$TMP/test.err"; then notok "$name"; else ok "$name"; fi; }
assert_file(){ local name=$1 file=$2 expected=$3; local got; got=$(cat "$file"); if [ "$got" = "$expected" ]; then ok "$name"; else echo "got=$got expected=$expected"; notok "$name"; fi; }

init_state
expect_ok "first GPU deposit on unlimited account" run_cmd deposit -c tcluster -a gpuacct -t 10 -r gres/gpu
# 0 used + 0 run + 2 safety + 600 deposit
assert_file "first deposit initializes full credit plus safety" "$TMP/state/gpu" 602

init_state; echo 600 > "$TMP/state/used"; echo 300 > "$TMP/state/run"
expect_ok "first deposit preserves historical usage and running commitments" run_cmd deposit -c tcluster -a gpuacct -t 10 -r gres/gpu
assert_file "first deposit baseline includes committed state" "$TMP/state/gpu" 1502

init_state; echo 6000 > "$TMP/state/gpu"; echo 1200 > "$TMP/state/used"; echo 600 > "$TMP/state/run"
expect_ok "GPU deduct within withdrawable credit" run_cmd deduct -c tcluster -a gpuacct -t 10 -r gres/gpu
assert_file "GPU deduct lowers allocation" "$TMP/state/gpu" 5400

init_state; echo 6000 > "$TMP/state/gpu"; echo 5000 > "$TMP/state/used"; echo 500 > "$TMP/state/run"
expect_fail "GPU deduct refuses to consume usage/running commitment" run_cmd deduct -c tcluster -a gpuacct -t 10 -r gres/gpu
assert_file "failed deduct leaves limit unchanged" "$TMP/state/gpu" 6000

init_state
expect_fail "GPU deduct refuses unlimited account" run_cmd deduct -c tcluster -a gpuacct -t 1 -r gres/gpu

init_state; echo 6000 > "$TMP/state/gpu"; echo 1000 > "$TMP/state/used"; echo 200 > "$TMP/state/run"
expect_fail "leading-zero hours rejected" run_cmd deposit -c tcluster -a gpuacct -t 010 -r gres/gpu
expect_fail "08 rejected instead of octal error" run_cmd deposit -c tcluster -a gpuacct -t 08 -r gres/gpu
expect_fail "huge hours rejected before overflow" run_cmd deposit -c tcluster -a gpuacct -t 9223372036854775807 -r gres/gpu

init_state; echo 9223372036854775800 > "$TMP/state/gpu"; echo 0 > "$TMP/state/used"; echo 0 > "$TMP/state/run"
expect_fail "existing-limit addition overflow rejected" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
assert_file "overflow rejection leaves limit" "$TMP/state/gpu" 9223372036854775800

init_state; echo 6000 > "$TMP/state/gpu"; echo 5000 > "$TMP/state/share_gpu_override"
expect_fail "DB/slurmctld limit mismatch rejected" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu

init_state; echo no > "$TMP/state/tracked"
expect_fail "untracked generic GPU TRES rejected" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu

init_state; echo '' > "$TMP/state/parent"
expect_fail "root association GPU banking rejected" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu

init_state; touch "$TMP/state/assoc_extra_user"; echo 6000 > "$TMP/state/gpu"
expect_ok "user associations do not confuse account selection" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
assert_file "account-level limit changed" "$TMP/state/gpu" 6060

init_state; echo 6000 > "$TMP/state/gpu"; touch "$TMP/state/sshare_extra_account"
expect_fail "ambiguous sshare account output fails closed" run_cmd deduct -c tcluster -a gpuacct -t 1 -r gres/gpu

init_state; echo 6000 > "$TMP/state/gpu"; touch "$TMP/state/sshare_child_account"
expect_ok "child-account sshare rows are ignored by association ID" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
assert_file "exact association receives update despite child row" "$TMP/state/gpu" 6060

init_state; echo 6000 > "$TMP/state/gpu"; echo 5000 > "$TMP/state/used"; echo 0 > "$TMP/state/run"; echo 500 > "$TMP/state/bump_run_after_first"
expect_fail "deduct refresh catches newly committed running GPU time" run_cmd deduct -c tcluster -a gpuacct -t 10 -r gres/gpu
assert_file "race-rejected deduct leaves limit" "$TMP/state/gpu" 6000

init_state; echo 600 > "$TMP/state/bump_run_after_first"
expect_ok "initial deposit refresh includes job that starts mid-command" run_cmd deposit -c tcluster -a gpuacct -t 10 -r gres/gpu
assert_file "initial deposit uses refreshed running baseline" "$TMP/state/gpu" 1202

init_state; echo 6000 > "$TMP/state/gpu"; touch "$TMP/state/fail_modify"
expect_fail "failed sacctmgr modification propagates failure" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
assert_file "failed modification leaves limit" "$TMP/state/gpu" 6000

init_state; echo 6000 > "$TMP/state/gpu"; touch "$TMP/state/sleep_modify"
run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu >"$TMP/lock-first.out" 2>"$TMP/lock-first.err" &
lock_pid=$!
sleep 0.2
expect_fail "account flock rejects concurrent sbank mutation" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
wait "$lock_pid" || notok "first locked mutation completes"
rm -f "$TMP/state/sleep_modify"

init_state
expect_ok "CPU deposit still works" run_cmd deposit -c tcluster -a gpuacct -t 5
assert_file "CPU deposit arithmetic" "$TMP/state/cpu" 6300
expect_ok "CPU deduct still works" run_cmd deduct -c tcluster -a gpuacct -t 5
assert_file "CPU deduct arithmetic" "$TMP/state/cpu" 6000

init_state; echo unset > "$TMP/state/cpu"
expect_fail "CPU unlimited limit not assumed to be zero" run_cmd deposit -c tcluster -a gpuacct -t 1

init_state; echo 6000 > "$TMP/state/gpu"
export MOCK_PRIORITY_TYPE=priority/basic
expect_fail "GPU banking requires priority/multifactor" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
unset MOCK_PRIORITY_TYPE

init_state; echo 6000 > "$TMP/state/gpu"
export MOCK_ACCOUNTING_TRES=gres/gpu:a100,billing,cpu,mem,node
expect_fail "typed GPU tracking alone does not satisfy generic gres/gpu banking" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
unset MOCK_ACCOUNTING_TRES

init_state; echo 6000 > "$TMP/state/gpu"
export MOCK_ENFORCE=associations
expect_fail "GPU banking requires limits enforcement" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
unset MOCK_ENFORCE

init_state; echo 6000 > "$TMP/state/gpu"
export MOCK_ENFORCE=limits
expect_ok "GPU banking accepts limits enforcement" run_cmd deposit -c tcluster -a gpuacct -t 1 -r gres/gpu
unset MOCK_ENFORCE

printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
