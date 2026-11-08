# DGX Spark (GB10) dynamic clock governor — a temperature-target clock profile

A small systemd service that runs a closed-loop clock governor on each NVIDIA DGX Spark / GB10
node. It holds the **GPU die** near a target temperature by walking the `nvidia-smi -lgc`
runtime clock ceiling up/down, so clocks and throughput self-adjust to the thermal situation
instead of running flat at max boost. A hard board-zone ceiling guards VRM/VRAM without
driving normal throttling.

> **Current deployment (2026-11-08).** Both nodes run `gb10-zone-guard.service`, not the
> governor; `gb10-clock-governor.service` is installed but disabled. The guard caps the clock at
> 2200 MHz and latches to 2000 after 3 consecutive samples at/above 88 °C on the hottest ACPI
> zone, returning only after 8 samples below 82 °C; a die backstop cascades to the floor at
> 89 °C. Deploy with `./deploy.sh zone-guard`. The governor was retired as the live role because
> its board-ceiling branch self-cancels against the die target: once a ceiling step-down fires,
> the next sample's cool die steps straight back up, so it sawtooths 2200↔2000 every 8 s without
> relieving the hotspot.

> **Why this exists.** The DGX Spark's fans barely ramp at high temperatures and cannot be
> adjusted from userland — NVIDIA's embedded-controller (EC) owns the whole cooling policy and
> lets the hottest ACPI zones climb to ~96–97 °C under load. Forcing fan RPM floors is one
> response (see related work below), but it needs a kernel module pinned to a specific
> kernel/firmware and still can't guarantee a temperature cap. This approach takes the
> opposite lever: keep the **clocks** under control so heat generation stays under the
> throttling point. It's pure userland — a single `nvidia-smi` call per iteration, no kernel
> module, works on any kernel or firmware.

## Attribution

These scripts were created by **griffith.mark**, who provided the dynamic-clock governor in the
NVIDIA Developer Forums thread:

> *"Cooler GB10 Temps — (almost) no performance lost."*
> https://forums.developer.nvidia.com/t/cooler-gb10-temps-almost-no-performance-lost/372662

Thanks to `griffith.mark` for the work this is built on.

A separate, related attempt to control the fans directly is
[`christopherowen/dgx-spark-fan-control`](https://github.com/christopherowen/dgx-spark-fan-control)
(additive RPM floors via a DKMS kernel module) — see the "Why not the fan-control repo?" note below.

## How it works

- `nvidia-smi -lgc 0,<mhz>` sets a **runtime clock ceiling** on GPU 0. Syntax must be one
  comma-joined argument (`-lgc 0,1500`); the space form (`-lgc 0 1500`) silently fails.
- The cap holds until reboot or `nvidia-smi -rgc` (reset) — fully revert-safe.
- Read the **running** clock (`nvidia-smi -q -d CLOCK` → `Clocks → Graphics`) to verify; the
  `Applications Clocks` field does **not** reflect the cap.

The governor walks a fixed ladder of ceilings using a **two-tier** sensor strategy:

- **Ladder:** `[2400, 2200, 2000, 1800, 1700, 1500, 1300, 1200]` MHz (high → low).
- **Primary target — GPU die** (`nvidia-smi temperature.gpu`): steps the clock **down** when
  `die > target + band` (default band `2.0 °C`) or `die >= --hard` (emergency jump), and
  **up** when `die < target - band`. The die is the controlled variable, so clocks hold steady
  instead of chasing noisy board zones.
- **Safety ceiling — hottest board zone** (max over all `/sys/class/thermal/thermal_zone*/temp`):
  a hard `--ceiling` (default `92 °C`) that forces a throttle-down only if a board zone approaches
  a component limit. Board zones guard VRM/VRAM; they no longer drive normal throttling.
- **SIGTERM/SIGINT** reset the clocks to default (`-rgc`) and exit; `Restart=on-failure` in the
  unit restarts it if it ever dies.

```bash
python3 gb10-clock-governor.py --target 65 --ceiling 92   # hold die at 65C, board ceiling 92C
python3 gb10-clock-governor.py --dry-run                  # log the clock it WOULD set, apply nothing
```

## Both original designs hammered the clock — measured

This is the central finding. **Neither v1 nor v2 held a steady clock**, and both were replaced for
the same reason: they reacted to a sensor that is too noisy to control on level alone.

### v1 — chased the hottest board zone

The v1 design targeted the **hottest ACPI board zone**. Board zones on this box are not merely
higher than the die, they are *bursty*: a single zone can move ~10 °C in a few seconds, and the
worst measured swing is **68.2 °C → 50.0 °C between two samples 5 s apart** (~22 °C).

Because the controller compared that raw sample against a target every iteration, the clock chased
the noise:

- clock swung **≈1410 ↔ 2392 MHz** — nearly the whole ladder, repeatedly
- while the die itself stayed cool (~50–70 °C) and never justified the drop

### v2 — chased the die instead, and still hammered

v2 replaced the board target with a **die** target (`--target 65`) and demoted board zones to a hard
`--ceiling 92`. The die is a better-behaved sensor, so v2 looked clean in short runs. Under a
back-to-back 12-question benchmark sweep it did not hold up:

| v2 config | clock range observed | clock avg | board max |
| --- | --- | --- | --- |
| `--target 65 --clock-max 2400` | **1976 ↔ 2392 MHz** | 2183 | 85 °C |
| `--target 65 --ceiling 89` | **1787 ↔ 2392 MHz** | 2158 | 87 °C |

The die swings **57 → 68 °C within a single 8 s tick**. Against a 65 °C target with a 2 °C band,
that means the controller crossed its trigger on nearly every sample: it walked the ladder down,
then back up, then down again. The result was a **~600 MHz peak-to-peak swing** — the same hammering
as v1, just driven by a different sensor.

**Crucially, the throttling bought nothing.** Those v2 runs peaked at 84–87 °C on the board — no
cooler than simply running flat at 2200 MHz with no governor at all (84 °C). The controller spent
its time stepping down for heat that was already dissipating.

### Why "react to the level" is the wrong control

Heat on this box is **transient and self-clearing**: after a load ends, zones fell from 83 °C to
61 °C in about 12 s. A controller sampling every 8 s and acting on a single reading cannot
distinguish a real thermal trend from a burst that is gone by the next tick. Both v1 and v2 made
that mistake in different places — v1 on the board zone, v2 on the die.

### What replaced it

Two changes:

1. **Persistence instead of level** (`--ceiling-samples`). A board zone only counts as hot once it
   has stayed at/above `--ceiling` for N *consecutive* samples. A 2-second spike is ignored.
2. **A clock cap as the primary protection**, with the die target set high enough that it is not
   the normal driver.

The current policy is `--target 85 --ceiling 89 --ceiling-samples 3 --clock-max 2200`:

- the 2200 cap bounds absolute heat generation for 24/7 workloads
- a die of 85 °C is treated as an acceptable sustained limit — it must reach 87 °C (`85 + band`) to
  act, which never happened under the heaviest load tested (peak 68 °C)
- board zones must hold 89 °C for **24 s** (3 × 8 s) before the clock moves, so bursts cannot
  throttle it

Under the same benchmark that hammered v2, this policy held **dead flat at 2190 MHz** with a board
peak of 82 °C. See the sweep table in the next section.

## Why board zones are bursty, and why `--ceiling-samples` exists

## Tuning the knobs

The two most-common tweaks are passed by the **service**; everything else lives in the **script**.

| Setting | Controls | Default | Where to change it |
| --- | --- | --- | --- |
| `--target` | GPU **die** °C to hold (the primary control) | 65 | Service `ExecStart`, then `daemon-reload` + `restart`. |
| `--ceiling` | Hottest **board** zone that forces a throttle-down | 92 | Service `ExecStart`, then `daemon-reload` + `restart`. |
| `--ceiling-samples` | Consecutive samples a zone must sit at/above `--ceiling` before stepping down; `1` = react to a single sample | 1 | Service `ExecStart`, then `daemon-reload` + `restart`. |
| `--band` | Hysteresis — the clock only moves outside `target ± band` | 2.0 °C | Script, line ~84. Edit + redeploy. |
| `--hard` | Die emergency °C — step toward the floor | 89 °C | Script, line ~82. Edit + redeploy. |
| `--clock-max` / `--clock-floor` | Highest / lowest ladder rung | 2400 / 1500 MHz | Script, lines 86–85. Edit + redeploy. |
| `--interval` | Seconds between samples | 8 | Script, line ~87. Edit + redeploy. |
| `LADDER` | The ceiling steps themselves | `[2400,2200,…,1200]` MHz | Script, line 23. Edit + redeploy. |

**Changing `--target` / `--ceiling`** (the common ones): edit the `ExecStart` line in
`gb10-clock-governor.service` on each node, then:

```bash
sudo systemctl daemon-reload && sudo systemctl restart gb10-clock-governor.service
```

Any other knob is a **script** edit — change the value, then re-deploy the script and restart on
both nodes. (The service runs as root, so script edits must also be copied to the path in `ExecStart`.)

## Measured effect (v2 — die target + board ceiling)

An early v2 run, `--target 65 --ceiling 92`, both nodes under a deepseek-v4.x decode workload:

| Node | Die (steady) | Board (steady / max) | Clock (steady) | Throttle events |
|------|--------------|----------------------|----------------|-----------------|
| spark-1 | ~62 °C | 75–84 °C / 84 °C | ~2392 MHz (top rung) | 0 |
| spark-2 | ~63 °C | 71–88 °C / 88 °C | ~2379 MHz (top rung) | 0 |

**This is a best case, not the general behaviour.** On a longer single workload the die happened to
settle at the target without crossing it often. Under a back-to-back benchmark sweep — where the
die rises and falls between questions — the same `--target 65` config hammered the ladder
(1976↔2392 MHz, see "Both original designs hammered the clock" above). Do not read this table as
evidence that v2 is stable; the stability came later, from the persistence gate.

(Also note: the v1 80/85 °C numbers elsewhere refer to a *board-zone* target ≈ 60 °C die; the v2 die
target is a different, cooler sensor, so the two are not directly comparable by number.)

## Why board zones are bursty, and why `--ceiling-samples` exists

On a GB10 the die and the ACPI board zones are **decoupled and both bursty**. Measured on one
node at a flat 2200 MHz cap: the hottest zone jumped **68.2 °C → 50.0 °C between two samples 5 s
apart**, and the die swung **57 → 68 °C within a single 8 s tick**. Heat is transient and
self-clearing — after a load ends, zones fell from 83 °C to 61 °C in about 12 s.

That is why targeting either value on *level alone* oscillates. In a sweep of eight governor
configurations under the same benchmark:

| Configuration | Clock behaviour | Zone max |
| --- | --- | --- |
| flat `-lgc 0,2200`, no governor | dead flat 2190 | 84 °C |
| `--target 65 --clock-max 2200` | **dropped to 1976 repeatedly** | 84 °C |
| `--target 65 --ceiling 89` | dropped to 1787 | 87 °C |
| `--target 85 --ceiling 89 --ceiling-samples 3 --clock-max 2200` | dead flat 2190 | 82 °C |

The die-targeted configurations spent their time stepping down and produced **no cooler zones**
than simply running flat. The persistence rule is the fix: a zone only counts as hot once it has
stayed at/above `--ceiling` for `--ceiling-samples` consecutive samples, so a 2-second spike is
ignored. With `--ceiling-samples 3` at the default 8 s interval that is 24 s of sustained heat.

Verified live: a forced test (`--ceiling 60`) accumulated `ceil_run=1, 2` across a spike that then
fell — the counter reset and **no throttle occurred**. A sustained test stepped down only on the
third consecutive sample, and reset the counter after acting so it moves one rung at a time.

**This box has no stock thermal backstop.** `nvidia-smi` reports no slowdown or shutdown
temperature for the GB10, no board zone has a kernel `crit` trip point, and the throttle flags read
`0x0`. Nothing protects it thermally unless userland does — which is the entire argument for
running the governor.

## Files

| File | Purpose |
| --- | --- |
| `gb10-clock-governor.py` | The governor (closed-loop clock ladder). |
| `gb10-zone-guard.py` | Alternative guard that acts on **zone persistence only** (die ignored by default). Useful when the die is an acceptable proxy and only sustained zone heat matters. |
| `gb10-clock-governor.service` | systemd unit: runs the governor as **root**, `Restart=on-failure`, enabled at boot. |
| `gb10-zone-guard.service` | systemd unit: runs the zone guard as **root**, `Restart=always`, bounded 2200→2000 MHz policy. |
| `deploy.sh` | Git-based deploy: clone/fast-forward the repo on a node, install scripts + one unit, leave exactly one clock writer. |
| `test_variants.sh` | Sweeps clock/thermal variants back-to-back (runs the governor as a plain user via the `sudo -n nvidia-smi` fallback, so no root shell is needed), sampling clocks and zones throughout. |
| `verify-gov.sh` | Prints the running clock, GPU temp, and hottest thermal zone — for a quick check. |
| `monitor.py` | Read-only observer: logs die, board, and running clock (reuses the governor's clock parse). Never writes a clock — safe on a live, shared-GPU node for validating the logic. |
| `dynamic-clocks.md` | Extended notes (mechanism, test results, safety). |
| `before.png` / `after.png` | Before/after thermal screenshots. |

**Why the service runs as root.** Root runs `nvidia-smi` directly with no password, so the same
unit works on every node without needing a per-node passwordless-`nvidia-smi` sudoers rule. The
script falls back to `sudo -n nvidia-smi` when not root.

## Deploy (per node) — git-based

Deployment is deliberately tied to a commit, so a node runs an exact revision instead of a
hand-copied file. The unit install needs **password sudo**; everything else runs as the
deployment user:

```bash
git clone https://github.com/Oliver-S3/dgx-spark-dynamic-clocks.git ~/dgx-spark-dynamic-clocks
cd ~/dgx-spark-dynamic-clocks && ./deploy.sh governor     # or: ./deploy.sh zone-guard
```

`deploy.sh` does, in order:

1. clone, or `fetch` + `reset --hard origin/main`, and print the deployed commit;
2. install `gb10-clock-governor.py`, `gb10-zone-guard.py`, `monitor.py`, `verify-gov.sh` into
   `$HOME` (where each unit's `ExecStart` expects them);
3. install the chosen unit to `/etc/systemd/system/`, `daemon-reload`, **disable the other unit**
   so only one process owns `nvidia-smi -lgc`, then `enable --now` the chosen one;
4. verify: `pgrep -af gb10-`, unit state, running clock, and script hashes vs the checkout.

Confirm the node matches GitHub (same short SHA on every node and on `origin/main`):

```bash
git -C ~/dgx-spark-dynamic-clocks rev-parse --short HEAD
sha256sum ~/gb10-clock-governor.py ~/gb10-zone-guard.py
```

The units ship with `ExecStart=... /home/oliver/...`; change that path in the unit if your
deployment user's home is elsewhere.

## Two clock writers cannot coexist

Only one process may own `nvidia-smi -lgc`. The governor re-applies its rung every interval, so a
manual `nvidia-smi -lgc 0,2200` is overwritten within one tick (~8 s), and two governors fight for
the ladder. Before starting it, confirm nothing else is writing:

```bash
pgrep -af gb10-clock-governor.py     # expect nothing, or exactly one
```

Watch for leftover units too — a manually-created unit pointing at the same script is a second
writer, and `systemctl disable` on one unit does not stop another.

## Safety

- **Revert-safe:** the clock cap clears on reboot and on a clean stop (`-rgc`).
- **No container / EC / firmware writes** — this only sets a runtime GPU clock ceiling.
- **Shared-GPU caveat:** on a node where another workload (e.g. an inference service) uses the
  same GPU, throttling the clock lowers that workload's throughput at the cost of a lower
  temperature. Confirm the trade-off is acceptable before enabling.
- **Watchdog gap:** `Restart=on-failure` restarts on crash, but a hard `SIGKILL` leaves the
  `-lgc` ceiling in place until reboot. If you want no-kill safety, wrap the governor in a tiny
  supervisor that re-applies `-rgc` if the process disappears.

## Rollback / Removing

Per node (spark-1 and spark-2). There is **no sudoers entry or kernel module** to clean up —
the unit runs as root, so removal is just the unit file and the script:

```bash
# 1. Stop now + stop from starting on boot (clean stop resets clocks to default via -rgc)
sudo systemctl disable --now gb10-clock-governor.service

# 2. Remove the unit file
sudo rm /etc/systemd/system/gb10-clock-governor.service

# 3. Remove the governor script
sudo rm ~/gb10-clock-governor.py

# 4. Refresh systemd
sudo systemctl daemon-reload

# 5. Verify clocks are back to default (~2418 MHz). Only if still capped, force a reset:
sudo nvidia-smi -q -d CLOCK | awk '/Clocks/{c=1} /Graphics/{print; exit}'
sudo nvidia-smi -rgc
```

Notes:
- A clean `disable --now` should return the clock to ~2418 MHz automatically. `-rgc` in step 5 is
  the manual fallback if the cap somehow persists.
- The `-lgc` cap is **not** persistent across reboot, but because the service is *enabled* it
  would come back on boot — so `disable` + `rm` is required for a real rollback (don't rely on a
  reboot alone).

## Why not the fan-control repo?

Two independent reasons the fan-floor kernel-module approach (`christopherowen/dgx-spark-fan-control`)
doesn't work directly as a temperature *cap*:

1. **Different lever.** It raises a minimum fan RPM floor to keep clocks *high* (cooler, louder).
   This governor throttles clocks to cap heat (hotter-per-watt, less heat). Same symptom, opposite
   approach. It also can't impose an absolute temperature ceiling — it only adds minimums on top
   of NVIDIA's EC policy.
2. **Kernel/firmware lock.** Its driver is a DKMS module built for `6.17.0-1029-nvidia` (board
   P4242, EC firmware 3.5.8, DGX OS 7.5.0) and "rejects platform responses outside its observed
   contract." It needs matching headers, build tools, root, and — with Secure Boot on — an enrolled
   signing cert. On other kernels/firmware it won't build or load cleanly.

This governor sidesteps both: pure userland, one `nvidia-smi` call, no kernel module.
