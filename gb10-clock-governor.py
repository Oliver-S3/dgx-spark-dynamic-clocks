#!/usr/bin/env python3
"""GB10 clock governor — hold a temperature target by walking the `nvidia-smi -lgc`
cap up/down. Runs at your ceiling when cool, steps the cap down as the HOTTEST
sensor nears the target, hands clocks back as it cools, resets to default on exit.
Needs a NOPASSWD sudo rule for nvidia-smi -lgc/-rgc."""
import argparse, subprocess, time, signal, sys, glob

import argparse, subprocess, time, signal, sys, glob, os

LADDER = [2400, 2200, 2000, 1800, 1700, 1500, 1300, 1200]   # MHz caps, high -> low

def _nv(args):
    # Run nvidia-smi directly when root (systemd service); else passwordless sudo.
    exe = ["nvidia-smi"] if os.geteuid() == 0 else ["sudo", "-n", "nvidia-smi"]
    return subprocess.run(exe + args, capture_output=True, text=True, timeout=10)

def hottest():                       # max over ALL ACPI zones + nvidia-smi GPU die
    t = []
    for f in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try: t.append(int(open(f).read()) / 1000.0)
        except: pass
    try: t += [float(x) for x in _nv(["--query-gpu=temperature.gpu",
                   "--format=csv,noheader,nounits"]).stdout.split() if x.strip()]
    except: pass
    return max(t) if t else None     # None = no readings; don't move the ladder blind

def set_clock(mhz):
    try: return _nv(["-lgc", "0,%d" % mhz]).returncode == 0
    except: return False

def reset_clock():
    try: _nv(["-rgc"])
    except: pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", type=float, default=80)   # °C to hold, on the hottest zone
    ap.add_argument("--hard",   type=float, default=85)   # emergency: jump straight down
    ap.add_argument("--band",   type=float, default=2.0)  # hysteresis
    ap.add_argument("--clock-floor", type=int, default=1500)
    ap.add_argument("--clock-max",   type=int, default=2400)
    ap.add_argument("--interval",    type=float, default=8)
    a = ap.parse_args()

    ladder = [m for m in LADDER if a.clock_floor <= m <= a.clock_max] or [a.clock_floor]
    ci = 0                                                # ci=0 -> highest clock
    clock_ok = set_clock(ladder[ci])
    signal.signal(signal.SIGTERM, lambda *_: (reset_clock(), sys.exit(0)))
    signal.signal(signal.SIGINT,  lambda *_: (reset_clock(), sys.exit(0)))

    while True:
        t = hottest()
        if t is None:                                    # sensors unreadable -> hold, retry
            time.sleep(a.interval); continue
        if t > a.target + a.band or t >= a.hard:         # HOT -> cap the clock down
            if clock_ok and ci < len(ladder) - 1:
                ci += 1; set_clock(ladder[ci])
        elif t < a.target - a.band:                      # COOL -> hand the clocks back
            if clock_ok and ci > 0:
                ci -= 1; set_clock(ladder[ci])
        time.sleep(a.interval)

if __name__ == "__main__":
    main()
