#!/usr/bin/env bash
# test_variants.sh — sweep clock/thermal governor variants back-to-back, without root.
#
# How it runs a governor unprivileged: gb10-clock-governor.py's _nv() tries plain
# `nvidia-smi` first and falls back to `sudo -n nvidia-smi`. If your account has a
# NOPASSWD rule for `nvidia-smi` (e.g. `/usr/bin/nvidia-smi -lgc *` and `-rgc`), the
# governor runs as an ordinary user and its clock writes still succeed, so this script
# never prompts for a password. Without that rule, run the governor as root instead.
#
# This script runs ON the node whose GPU it measures (the "head"). Commands for that node
# execute locally. A second node (the "worker") is optional: if it is reachable over SSH
# its clocks are logged too, otherwise it is reported as unreachable and left alone.
#
# Configuration is by environment variable — no addresses are baked in:
#   HEAD_HOST   hostname of this node for the guard check      (default: this host)
#   WORKER      ssh destination of the optional second node    (default: empty = skip)
#   GOV         path to the governor script                    (default: ~/gb10-clock-governor.py)
#   BASE_URL    OpenAI-compatible endpoint to benchmark        (default: http://127.0.0.1:8888)
#   MODEL       model id passed to the bench                   (default: whatever the server serves)
#   BENCH       path to a bench client script (optional)       (default: empty = skip benchmarking)
#   PIN         clock cap restored between variants            (default: 2200)
#   OUT         results directory        (default: ~/variant-results/<UTC timestamp>)
#
# Usage:
#   ./test_variants.sh list                 # show the variants and what they do
#   ./test_variants.sh run [name ...]       # run all, or only the named ones
#   ./test_variants.sh status               # clocks, temps, any governor running
#   ./test_variants.sh clean                # kill strays, restore the pin
#   ./test_variants.sh baseline             # just the pinned reference, no governor
#
# Every variant: kill any stray governor -> settle -> record clocks every 4 s in the
# background while the bench runs -> stop governor -> next. Results land in
# $OUT/<variant>/{bench.json,clocks.csv,summary.txt,governor.log,shadow.log}.

set -u

HEAD_HOST=${HEAD_HOST:-$(hostname -s 2>/dev/null || echo localhost)}
WORKER=${WORKER:-}
# This script runs ON the head, so head commands are local. The worker is optional.
GOV=${GOV:-$HOME/gb10-clock-governor.py}
BASE_URL=${BASE_URL:-http://127.0.0.1:8888}
MODEL=${MODEL:-}
BENCH=${BENCH:-}
PIN=${PIN:-2200}
OUT=${OUT:-$HOME/variant-results/$(date -u +%Y%m%dT%H%M%SZ)}
BENCH_SECS=${BENCH_SECS:-1200}

head_run()   { bash -c "$*"; }
WORKER_SSH=(ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=8)
WORKER_OK=0
worker_run() {
  [ "$WORKER_OK" -eq 1 ] || return 1
  "${WORKER_SSH[@]}" "$WORKER" "$*" 2>/dev/null
}
probe_worker() {
  if "${WORKER_SSH[@]}" "$WORKER" true 2>/dev/null; then
    WORKER_OK=1
  else
    WORKER_OK=0
  fi
}

# guard: refuse to run anywhere but the head, so `head_run` really is local.
# HEAD_HOST is overridable because this is a local-only script and the name does not matter.
[ "$(hostname -s 2>/dev/null)" = "$HEAD_HOST" ] || [ -n "${FORCE_LOCAL:-}" ] || {
  echo "this script must run ON $HEAD_HOST (set HEAD_HOST=<this host> or FORCE_LOCAL=1)" >&2
  exit 1
}

say() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { say "ERROR: $*"; exit 1; }

# ---- variants -------------------------------------------------------------------------
# name|governor args ("" = no governor, plain pin)
declare -A VARIANTS=(
  [baseline]=""                                                   # fixed 2200, no governor
  [gov-2200]="--target 65 --clock-max 2200"                       # your policy clipped to Mia's number
  [gov-2400]="--target 65 --clock-max 2400"                       # your production config
  [gov-85]="--target 85"                                          # the permissive one that was running
  [gov-65-89]="--target 65 --ceiling 89"                          # board ceiling pulled in
  [gov-band6]="--target 65 --clock-max 2200 --band 6"             # wide hysteresis vs the bursty die
  [gov-70]="--target 70 --clock-max 2200"                         # die target raised to sit above the swings
  [gov-floor-1800]="--target 70 --clock-max 2200 --clock-floor 1800"  # no rung below 1800
  [zone-guard]="ZONE --clock-max 2200"                            # persistence-based zone guard
  [zone-eager]="ZONE --clock-max 2200 --hot 86 --hot-samples 2"    # fires more readily
  [user-policy]="--target 85 --ceiling 89 --clock-max 2200"        # die 85 / zone 89 / 2200 cap
  [final]="--target 85 --ceiling 89 --ceiling-samples 3 --clock-max 2200"  # + spike tolerance
  [final-eager]="--target 85 --ceiling 88 --ceiling-samples 2 --clock-max 2200"  # tighter zone
)
ORDER=(baseline gov-2200 gov-2400 gov-85 gov-65-89 gov-band6 gov-70 gov-floor-1800 zone-guard zone-eager user-policy final final-eager)

describe() {
  case $1 in
    baseline)  echo "fixed -lgc 0,$PIN on both ranks, no governor (reference point)" ;;
    gov-2200)  echo "--target 65 --clock-max 2200: top rung 2200, steps down when hot" ;;
    gov-2400)  echo "--target 65 --clock-max 2400: your production config" ;;
    gov-85)    echo "--target 85: permissive, holds ~2385 until die hits ~87" ;;
    gov-65-89) echo "--target 65 --ceiling 89: board zones guarded earlier than 92" ;;
    gov-band6) echo "--target 65 --clock-max 2200 --band 6: wide hysteresis vs the bursty die" ;;
    gov-70)    echo "--target 70 --clock-max 2200: die target above the 57-68 swings" ;;
    gov-floor-1800) echo "--target 70 --clock-max 2200 --clock-floor 1800: keeps a high floor" ;;
    zone-guard) echo "zone guard: >=88C for 3 samples steps down; <82C for 8 steps up" ;;
    zone-eager) echo "zone guard eager: >=88C for 2 samples (fires sooner)" ;;
    user-policy) echo "--target 85 --ceiling 89 --clock-max 2200: die 85 ok, zone 89 hard, capped 2200" ;;
    final) echo "--target 85 --ceiling 89 --ceiling-samples 3 --clock-max 2200: 89C for 24s to act" ;;
    final-eager) echo "--target 85 --ceiling 88 --ceiling-samples 2: tighter zone, 16s to act" ;;
  esac
}

# ---- helpers --------------------------------------------------------------------------
gov_pids() { head_run 'pgrep -f "[g]b10-(clock-governor|zone-guard).py" || true' 2>/dev/null; }

kill_gov() {
  local pids; pids=$(gov_pids)
  [ -z "$pids" ] && return 0
  say "  killing stray governor: $(echo $pids | tr '\n' ' ')"
  # SIGTERM makes the governor call -rgc, so the pin must be re-applied afterwards.
  head_run "kill -TERM $pids 2>/dev/null" 2>/dev/null
  sleep 2
  pids=$(gov_pids)
  [ -n "$pids" ] && { say "  still alive, SIGKILL: $pids"; head_run "kill -KILL $pids 2>/dev/null"; sleep 1; }
  return 0
}

re_pin() {
  head_run "sudo -n nvidia-smi -lgc 0,$PIN >/dev/null 2>&1" 2>/dev/null
  sleep 3
}

clocks_head()   { head_run "nvidia-smi --query-gpu=clocks.gr,temperature.gpu --format=csv,noheader,nounits" 2>/dev/null; }
zones_head()    { head_run 'for f in /sys/class/thermal/thermal_zone*/temp; do cat $f; done' 2>/dev/null | sort -n | tail -1 | awk '{printf "%.1f", $1/1000}'; }
clocks_worker() { worker_run "nvidia-smi --query-gpu=clocks.gr,temperature.gpu --format=csv,noheader,nounits" 2>/dev/null; }
zones_worker()  { worker_run 'for f in /sys/class/thermal/thermal_zone*/temp; do cat $f; done' 2>/dev/null | sort -n | tail -1 | awk '{printf "%.1f", $1/1000}'; }

preflight() {
  say "preflight"
  local pids; pids=$(gov_pids)
  if [ -n "$pids" ]; then
    say "  a governor is already running ($pids) -- it will be killed before each variant"
  fi
  local c1 c2
  c1=$(clocks_head); c2=$(clocks_worker)
  say "  head ($HEAD_HOST) : ${c1:-unreadable}"
  if [ "$WORKER_OK" -eq 1 ]; then
    say "  worker ($WORKER): ${c2:-unreadable}"
  else
    say "  worker          : none configured/unreachable (left untouched)"
  fi
  local pin2; pin2=$(worker_run "nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits" 2>/dev/null)
  case "$pin2" in
    ''|*[!0-9]*) say "  WARNING: cannot read the worker clock" ;;
    *) [ "$pin2" -gt 2210 ] && say "  WARNING: worker reads ${pin2} MHz, above the ${PIN} pin -- the pair is not matched" ;;
  esac
  # one lane at a time: confirm Mia owns the GPUs
  local procs; procs=$(head_run "nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l" 2>/dev/null)
  [ "${procs:-0}" -ge 1 ] || say "  note: no compute process on the GPU (idle) -- thermal results will be low"
  say "  $procs compute process(es) on the GPU; endpoint $BASE_URL"
  head_run "curl -sf -m 5 $BASE_URL/v1/models >/dev/null" 2>/dev/null || die "$BASE_URL is not answering"
  mkdir -p "$OUT" && say "  results -> $OUT"
}

sample_clocks() {                      # background recorder: $1 = variant dir
  local f="$1/clocks.csv"
  echo "ts,head_mhz,head_die,head_zone,worker_mhz,worker_die,worker_zone" > "$f"
  while :; do
    local h w hz wz
    h=$(clocks_head); w=$(clocks_worker); hz=$(zones_head); wz=$(zones_worker)
    echo "$(date -u +%H:%M:%S),${h//$'\n'/,},${hz},${w//$'\n'/,},${wz}" >> "$f"
    sleep 4
  done
}

run_one() {
  local name=$1 dir="$OUT/$1" args=${VARIANTS[$1]:-}
  mkdir -p "$dir"
  say "=== $name: $(describe "$name") ==="

  kill_gov
  if [ -n "$args" ]; then
    # plain oliver; _nv() falls back to `sudo -n nvidia-smi` for the clock writes
    local script=$GOV
    case "$args" in
      ZONE\ *) script=$(dirname "$GOV")/gb10-zone-guard.py; args=${args#ZONE } ;;
    esac
    head_run "GOV_LOG=$dir/shadow.log nohup python3 $script $args > $dir/governor.log 2>&1 & echo \$!" > "$dir/gov.pid" 2>/dev/null
    sleep 3
    local gp; gp=$(gov_pids)
    if [ -z "$gp" ]; then
      say "  governor did not stay up; see $dir/governor.log"
      head_run "tail -5 $dir/governor.log" 2>/dev/null
      return 1
    fi
    say "  governor pid $gp: $args"
  else
    re_pin
    say "  no governor; pinned -lgc 0,$PIN"
  fi

  sleep 5
  sample_clocks "$dir" & sampler=$!

  if [ -n "$BENCH" ]; then
    say "  benching..."
    head_run "timeout $BENCH_SECS python3 $BENCH --base-url $BASE_URL \
              ${MODEL:+--model $MODEL} \
              --out $dir/bench.json" > "$dir/bench.log" 2>&1
  else
    say "  no BENCH client set -- holding load for ${BENCH_SECS}s instead"
    # Without a bench client, hold the governor in place long enough to sample thermals.
    sleep "$BENCH_SECS"
  fi
  local rc=$?

  kill $sampler 2>/dev/null; wait $sampler 2>/dev/null

  if [ -n "$BENCH" ] && { [ $rc -ne 0 ] || [ ! -s "$dir/bench.json" ]; }; then
    say "  bench failed (rc=$rc)"
    head_run "tail -3 $dir/bench.log" 2>/dev/null
    kill_gov; re_pin
    return 1
  fi

  if [ -n "$BENCH" ]; then
  head_run "python3 - '$dir' <<'PY'
import json, sys, csv
d = sys.argv[1]
b = json.load(open(d + '/bench.json'))
rows = b['results']
tot_t = sum(r['time'] for r in rows); tot_tok = sum(r.get('completion_tokens') or 0 for r in rows)
dec = [(r.get('completion_tokens') or 0 - 1) / max(r['time'] - 0.35, 1e-3)
       for r in rows if (r.get('completion_tokens') or 0) > 1]
mh = []; wh = []; hd = []; hz = []; wz = []
for row in csv.DictReader(open(d + '/clocks.csv')):
    def n(v):
        try: return float(v)
        except Exception: return None
    a, bb, c, dd = n(row['head_mhz']), n(row['worker_mhz']), n(row['head_die']), n(row['head_zone'])
    e = n(row['worker_zone'])
    if a: mh.append(a)
    if bb: wh.append(bb)
    if c: hd.append(c)
    if dd: hz.append(dd)
    if e: wz.append(e)
def s(v, f): return ('%.0f' % f(v)) if v else 'n/a'
lines = [
  'variant      : %s' % d.rsplit('/',1)[-1],
  'mean_request : %.2f s' % (tot_t/len(rows)),
  'max_request  : %.2f s' % max(r['time'] for r in rows),
  'aggregate    : %.1f tok/s' % (tot_tok/tot_t),
  'mean_decode  : %.1f tok/s' % (sum(dec)/len(dec)),
  'head clock   : avg %s  min %s  max %s MHz' % (s(mh, lambda v: sum(v)/len(v)), s(mh, min), s(mh, max)),
  'worker clock : avg %s  min %s  max %s MHz' % (s(wh, lambda v: sum(v)/len(v)), s(wh, min), s(wh, max)),
  'head die     : avg %s  max %s C' % (s(hd, lambda v: sum(v)/len(v)), s(hd, max)),
  'head zone    : max %s C' % s(hz, max),
  'worker zone  : max %s C' % s(wz, max),
]
open(d + '/summary.txt','w').write('\n'.join(lines) + '\n')
print('\n'.join(lines))
PY" 2>/dev/null | sed 's/^/  /'
  fi

  kill_gov
  re_pin
  say "  done; governor stopped, pin restored to $PIN"
}

probe_worker
case ${1:-list} in
  list)
    say "variants (each runs the benchmark if BENCH is set; governor runs as this user)"
    for v in "${ORDER[@]}"; do printf '  %-10s %s\n' "$v" "$(describe "$v")"; done
    echo
    echo "  ./test_variants.sh run            # all of them"
    echo "  ./test_variants.sh run gov-2200   # just one"
    echo "  ./test_variants.sh status | clean | baseline"
    ;;
  status)
    gp=$(gov_pids); c1=$(clocks_head); z1=$(zones_head)
    c2=$(clocks_worker); z2=$(zones_worker)
    say "governor: ${gp:-none}"
    say "head ($HEAD_HOST) : ${c1:-unreadable}  zone=${z1:-?}C"
    if [ "$WORKER_OK" -eq 1 ]; then
      say "worker ($WORKER) : ${c2:-unreadable}  zone=${z2:-?}C"
    else
      say "worker : not configured/unreachable (left untouched)"
    fi
    ;;
  clean)
    kill_gov; re_pin
    cc1=$(clocks_head); cc2=$(clocks_worker)
    say "head ($HEAD_HOST) : ${cc1:-unreadable}"
    if [ "$WORKER_OK" -eq 1 ]; then say "worker ($WORKER) : ${cc2:-unreadable}"
    else say "worker : not configured"; fi
    ;;
  baseline) OUT=${OUT:-$HOME/variant-results/$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p "$OUT"; run_one baseline ;;
  run)
    shift
    list=("$@"); [ ${#list[@]} -eq 0 ] && list=("${ORDER[@]}")
    preflight || exit 1
    ok=0; bad=0
    for v in "${list[@]}"; do
      if [ -z "${VARIANTS[$v]+x}" ]; then say "unknown variant: $v"; bad=$((bad+1)); continue; fi
      if run_one "$v"; then ok=$((ok+1)); else bad=$((bad+1)); fi
      say ""
    done
    say "sweep complete: $ok ok, $bad failed"
    head_run "python3 - '$OUT' <<'PY'
import glob, os, sys
rows = []
for d in sorted(glob.glob(sys.argv[1] + '/*/')):
    f = os.path.join(d, 'summary.txt')
    if not os.path.exists(f):
        continue
    v = {}
    for line in open(f):
        if ':' in line:
            k, val = line.split(':', 1)
            v[k.strip()] = val.strip()
    rows.append((os.path.basename(d.rstrip('/')), v))
if not rows:
    print('  (no summaries)')
else:
    fmt = '  %-14s %10s %8s %10s %22s %10s'
    print(fmt % ('variant', 'mean_req', 'decode', 'agg', 'head clock avg/min/max', 'die max'))
    print('  ' + '-' * 82)
    for name, v in rows:
        clock = v.get('head clock', '')
        clock = clock.replace('avg ', '').replace(' min ', '/').replace(' max ', '/').replace(' MHz', '') if clock else 'n/a'
        print(fmt % (name,
                     v.get('mean_request', '?'),
                     v.get('mean_decode', '?'),
                     v.get('aggregate', '?'),
                     clock,
                     v.get('head die', '?').replace('avg ', '').replace(' max ', '/').replace(' C', '')))
PY" 2>/dev/null
    say "raw results: $OUT"
    ;;
  *) die "usage: $0 [list|run [variant...]|status|clean|baseline]" ;;
esac
