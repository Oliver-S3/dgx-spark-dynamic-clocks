#!/usr/bin/env python3
"""GB10 clock governor — hold the DIE temperature by walking the `nvidia-smi -lgc`
cap up/down. Runs at your ceiling when cool, steps the cap down as the DIE nears
the target, hands clocks back as it cools, and forces a throttle-down if any board
thermal zone hits a safety ceiling. Resets to default on exit.

Two-tier control:
  * primary target : GPU die temperature (temperature.gpu)  -> steady clocks
  * safety ceiling : hottest ACPI board zone               -> component guard

Unlike the single-sensor version (which chased the hottest *board* zone and let the
clock swing with board noise while the die stayed cool), the die is the controlled
variable. The board zones only force a throttle-down at a hard ceiling, guarding
VRM/VRAM without driving normal throttling.

--dry-run prints the clock the ladder WOULD set and applies nothing — safe to run on
a node that is live (e.g. shared inference) for validating the logic before deploying.

Needs a NOPASSWD sudo rule for nvidia-smi -lgc/-rgc (or run as root).
"""
import argparse, subprocess, time, signal, sys, glob, os

LADDER = [2400, 2200, 2000, 1800, 1700, 1500, 1300, 1200]   # MHz caps, high -> low

def _nv(args):
    # Prefer a plain nvidia-smi (readable by any user; writes need root). Only fall
    # back to passwordless sudo if the plain call fails (e.g. a privileged write run
    # as a non-root user). Returns the first successful invocation.
    for exe in (["nvidia-smi"], ["sudo", "-n", "nvidia-smi"]):
        try:
            r = subprocess.run(exe + args, capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                return r
        except Exception:
            pass
    return subprocess.run(["nvidia-smi"] + args, capture_output=True, text=True, timeout=10)

def die():
    try:
        out = _nv(["--query-gpu=temperature.gpu",
                   "--format=csv,noheader,nounits"]).stdout
        return float([x for x in out.split() if x.strip()][0])
    except:
        return None

def board_hot():                       # max over ALL ACPI board zones only
    t = []
    for f in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try: t.append(int(open(f).read()) / 1000.0)
        except: pass
    return max(t) if t else None       # None = unreadable; don't move the ladder blind

def real_clock():                      # the clock the running governor actually set
    try:
        out = _nv(["-q", "-d", "CLOCK"]).stdout
        sec = None
        for line in out.splitlines():
            s = line.strip()
            if s == "Clocks":
                sec = "c"
            elif s.startswith("Applications Clocks"):
                sec = None
            elif sec == "c" and s.startswith("Graphics"):
                for tok in s.split():
                    if tok.isdigit():
                        return int(tok)
        return None
    except:
        return None

def set_clock(mhz):
    try: return _nv(["-lgc", "0,%d" % mhz]).returncode == 0
    except: return False

def reset_clock():
    try: _nv(["-rgc"])
    except: pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target",      type=float, default=65)  # °C to hold, on the DIE
    ap.add_argument("--hard",        type=float, default=89)  # die emergency: step down
    ap.add_argument("--ceiling",     type=float, default=92)  # board zone hard limit
    ap.add_argument("--ceiling-samples", type=int, default=1,
                    help="consecutive samples a board zone must sit at/above --ceiling "
                         "before stepping down; 1 (default) = react to a single sample")
    ap.add_argument("--band",        type=float, default=2.0) # hysteresis
    ap.add_argument("--clock-floor", type=int,   default=1500)
    ap.add_argument("--clock-max",   type=int,   default=2400)
    ap.add_argument("--interval",    type=float, default=8)
    ap.add_argument("--dry-run",     action="store_true")
    a = ap.parse_args()

    ladder = [m for m in LADDER if a.clock_floor <= m <= a.clock_max] or [a.clock_floor]
    ci = 0                                                # ci=0 -> highest clock
    if not a.dry_run:
        clock_ok = set_clock(ladder[ci])
    def _sig(*_):
        if not a.dry_run:
            reset_clock()
        sys.exit(0)
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)

    # GOV_LOG lets a non-root test run keep its own log: /tmp/gov-shadow.log may be owned
    # by root from an earlier run. Default is unchanged for the production service.
    logf = open(os.environ.get("GOV_LOG", "/tmp/gov-shadow.log"), "a")
    ceiling_run = 0                                       # consecutive samples at/above ceiling
    while True:
        td = die(); tb = board_hot()
        if td is None or tb is None:                     # sensors unreadable -> hold
            time.sleep(a.interval); continue
        # A board zone only counts as HOT once it has stayed at/above --ceiling for
        # --ceiling-samples consecutive samples. Zones on this box are bursty -- measured
        # jumping ~22 °C between two 8 s samples -- so with the default of 1 they can drop
        # the clock for a spike that is already gone by the next read.
        ceiling_run = ceiling_run + 1 if tb >= a.ceiling else 0
        ceiling_hot = ceiling_run >= a.ceiling_samples
        # HOT if the die is past target, the die hits hard, OR a board zone hits ceiling
        if td > a.target + a.band or td >= a.hard or ceiling_hot:
            if ci < len(ladder) - 1:
                ci += 1
            ceiling_run = 0                              # one step per confirmed burst
        elif td < a.target - a.band:                     # COOL -> hand clocks back
            if ci > 0:
                ci -= 1
        proposed = ladder[ci]
        if not a.dry_run:
            set_clock(proposed)
        logf.write("%s die=%.1f board=%.1f ceil_run=%d real=%s v2=%s\n"
                   % (time.strftime('%H:%M:%S'), td, tb, ceiling_run,
                      real_clock(), proposed))
        logf.flush()
        time.sleep(a.interval)

if __name__ == "__main__":
    main()
