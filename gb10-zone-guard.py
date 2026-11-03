#!/usr/bin/env python3
"""gb10-zone-guard.py — persistence-based BOARD ZONE guard for a DGX Spark GB10.

Why this exists
---------------
The production governor targets the DIE temperature. On this box the die and the ACPI
board zones are decoupled and both are bursty: a zone can jump ~22 °C between two 8 s
samples (measured: 68.2 -> 50.0), and the die swings 57 -> 68 °C in one tick. Targeting
either value on level alone produces constant ladder walking -- measured as clocks falling
to 1976 MHz repeatedly while the zones were no cooler than an ungoverned flat 2200.

What we actually want
---------------------
Keep the hot zones out of the 90s for PROLONGED periods, without wild clock swings. So this
governor acts on PERSISTENCE, not level:

  * HOT is only declared when the max zone is >= --hot (default 88) for --hot-samples
    consecutive samples (default 3, i.e. ~24 s at --interval 8). A 2-second spike never
    counts, so the bursty behaviour cannot make the ladder oscillate.
  * COOL -- and therefore permission to step back up -- only after the max zone has stayed
    < --cool (default 82) for --cool-samples consecutive samples (default 8, ~64 s).
    This is deliberately slow: once we give clock back we do not snatch it away again on
    the next burst.
  * Each HOT declaration steps down exactly one rung. It cannot cascade within one burst.
  * The die is IGNORED for control by default (--die-guard only as an emergency backstop),
    because the die target was only ever a convenient stand-in for the zones.

Runs as an ordinary user when that account has a NOPASSWD rule for `nvidia-smi`: this
script's _nv() tries plain `nvidia-smi` first and falls back to `sudo -n nvidia-smi`, so
clock writes succeed with no root shell and no password prompt.

Usage
-----
  ./gb10-zone-guard.py --clock-max 2200                 # guard, top rung 2200
  ./gb10-zone-guard.py --clock-max 2200 --dry-run       # log what it WOULD do; touch nothing
  ./gb10-zone-guard.py --hot 86 --hot-samples 2         # more eager
  GOV_LOG=/path/to.log ./gb10-zone-guard.py ...         # own log file

SIGTERM/SIGINT -> -rgc (reset to unrestricted), exactly like the production governor, so
callers must re-pin afterwards if they want a fixed cap.
"""

import argparse
import glob
import os
import signal
import subprocess
import sys
import time

LADDER = [2400, 2200, 2000, 1800, 1700, 1500, 1300, 1200]


def _nv(args):
    """Prefer plain nvidia-smi; fall back to passwordless sudo for privileged writes."""
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
    except Exception:
        return None


def zone_max():
    """Hottest ACPI thermal zone in °C, or None if unreadable."""
    t = []
    for f in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try:
            t.append(int(open(f).read()) / 1000.0)
        except Exception:
            pass
    return max(t) if t else None


def set_clock(mhz):
    try:
        return _nv(["-lgc", "0,%d" % mhz]).returncode == 0
    except Exception:
        return False


def reset_clock():
    try:
        _nv(["-rgc"])
    except Exception:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clock-max",   type=int,   default=2200,
                    help="top ladder rung (default 2200: flat-clock territory)")
    ap.add_argument("--clock-floor", type=int,   default=1500,
                    help="lowest rung it may ever step to")
    ap.add_argument("--hot",         type=float, default=88.0,
                    help="max zone at or above which a sample counts as hot (default 88)")
    ap.add_argument("--cool",        type=float, default=82.0,
                    help="max zone below which a sample counts as cool (default 82)")
    ap.add_argument("--hot-samples", type=int,   default=3,
                    help="consecutive hot samples before stepping DOWN (default 3)")
    ap.add_argument("--cool-samples", type=int,  default=8,
                    help="consecutive cool samples before stepping UP (default 8)")
    ap.add_argument("--interval",    type=float, default=8.0)
    ap.add_argument("--die-guard",   type=float, default=0.0,
                    help="emergency die backstop in °C; 0 disables (default: disabled)")
    ap.add_argument("--dry-run",     action="store_true",
                    help="log decisions but never write the clock")
    a = ap.parse_args()

    ladder = [m for m in LADDER if a.clock_floor <= m <= a.clock_max] or [a.clock_floor]
    ci = 0                       # 0 -> highest rung

    if not a.dry_run:
        set_clock(ladder[ci])

    def _sig(*_):
        if not a.dry_run:
            reset_clock()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)

    logf = open(os.environ.get("GOV_LOG", "/tmp/zone-guard.log"), "a")

    hot_run = 0
    cool_run = 0
    while True:
        tz = zone_max()
        td = die()
        if tz is None:
            logf.write("%s zone unreadable -> hold\n" % time.strftime('%H:%M:%S'))
            logf.flush()
            time.sleep(a.interval)
            continue

        if tz >= a.hot:             # confirmed-hot sample
            hot_run += 1
            cool_run = 0
        elif tz < a.cool:           # confirmed-cool sample
            cool_run += 1
            hot_run = 0
        else:                       # dead band: neither streak continues, and a hot streak is
            hot_run = 0             # broken so a burst cannot creep up to the trigger by
            cool_run = 0            # accumulating non-consecutive samples

        acted = ""
        # Emergency die backstop (off by default): treated like a confirmed hot sample.
        die_emergency = a.die_guard > 0 and td is not None and td >= a.die_guard
        if die_emergency:
            hot_run = max(hot_run, a.hot_samples)

        if hot_run >= a.hot_samples:
            if ci < len(ladder) - 1:
                ci += 1
                acted = "STEP-DOWN"
            else:
                acted = "AT-FLOOR"
            hot_run = 0             # one step per confirmed burst
        elif cool_run >= a.cool_samples:
            if ci > 0:
                ci -= 1
                acted = "STEP-UP"
            cool_run = 0

        proposed = ladder[ci]
        if acted and not a.dry_run:
            set_clock(proposed)
            acted += " applied"
        elif acted:
            acted += " (dry-run)"

        logf.write("%s zone=%.1f die=%s hot_run=%d cool_run=%d v2=%d %s\n"
                   % (time.strftime('%H:%M:%S'),
                      tz,
                      ("%.1f" % td) if td is not None else "n/a",
                      hot_run, cool_run, proposed, acted))
        logf.flush()
        time.sleep(a.interval)


if __name__ == "__main__":
    main()
