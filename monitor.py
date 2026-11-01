#!/usr/bin/env python3
"""Live clock monitor — reuses the governor's proven nvidia-smi clock parse so we
compare apples to apples. Reads (die, board-max, running clock) every N seconds."""
import importlib.util, time, sys, glob

spec = importlib.util.spec_from_file_location("gov", "/home/oliver/gb10-clock-governor.py")
gov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gov)                      # runs defs only; __name__ != "__main__"
nv = gov._nv

def die():
    try:
        out = nv(["--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"]).stdout
        return float([x for x in out.split() if x.strip()][0])
    except:
        return None

def board_hot():
    t = []
    for f in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try: t.append(int(open(f).read()) / 1000.0)
        except: pass
    return max(t) if t else None

secs = int(sys.argv[1]) if len(sys.argv) > 1 else 240
iv = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
end = time.time() + secs
while time.time() < end:
    d, b, c = die(), board_hot(), gov.real_clock()
    ds = f"{d:.1f}" if d is not None else "NA"
    bs = f"{b:.1f}" if b is not None else "NA"
    print(f"{time.strftime('%H:%M:%S')} die={ds} board={bs} clock={c}", flush=True)
    time.sleep(iv)
