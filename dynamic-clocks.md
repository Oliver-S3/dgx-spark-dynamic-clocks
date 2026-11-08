# GB10 Dynamic Clock Governor (SparkCluster)

A systemd service that runs a closed-loop clock governor on each GB10 node using a
**two-tier** sensor strategy: it holds the **GPU die** near a target temperature via
`nvidia-smi -lgc` (walking the runtime clock ceiling up/down), while a hard **board-zone**
ceiling guards VRM/VRAM without driving normal throttling. Clocks and throughput
self-adjust to the thermal situation instead of running flat at max boost.

> **Status note (2026-11-08).** This document is the design history of the governor. The live
> role on both nodes is now `gb10-zone-guard.service`; `gb10-clock-governor.service` is
> installed but disabled.

## TL;DR

- Under a heavy sustained decode load, `nvidia-smi -lgc` **does** throttle the clock on GB10.
  (Earlier "no-op" verdicts were a measurement bug: malformed `-lgc 0 1500` with a space and
  reading the wrong clock field — "Applications Clocks", which never reflects `-lgc`.)
- **v2 uses a two-tier controller:** the **GPU die** is the primary target (held via the clock
  ladder), and the **hottest board zone** is a hard `--ceiling` safety fallback. Controlling the
  die makes clocks hold **steady** instead of chasing noisy board zones.
- Live on both nodes with `--target 65 --ceiling 92`: the clock pins to the **top ladder rung**
  (~2380–2392 MHz) with **zero throttling** and board temps 71–88 °C (under the 92 °C ceiling).
- The service runs as **root** so it works on every node without a passwordless-nvidia-smi
  sudoers entry. Unit + deploy script are version-controlled here.

## The clock-cap mechanism

- `nvidia-smi -lgc 0,<mhz>` sets a runtime clock ceiling on GPU 0. Syntax MUST be one
  comma-joined arg (`-lgc 0,1500`); `-lgc 0 1500` (space) silently fails.
- The cap applies until reboot or `nvidia-smi -rgc` (reset). It is revert-safe.
- Read the **running** clock, not "Applications Clocks". Correct field:

  ```
  nvidia-smi -q -d CLOCK   # "Clocks -> Graphics" reflects the cap; "Applications Clocks -> Graphics" does not
  ```
- Sudo: `sudo -n nvidia-smi -lgc 0,<mhz>` / `-rgc`. Running the service as **root** makes this
  passwordless everywhere, so no per-node sudoers rule is required.

## The governor script: `gb10-clock-governor.py`

Closed-loop ladder of clock ceilings, driven by a **two-tier** sensor strategy:

- **Ladder:** `[2400, 2200, 2000, 1800, 1700, 1500, 1300, 1200]` MHz.
- **Primary — GPU die** (`nvidia-smi temperature.gpu`): steps the clock **down** when
  `die > target + band` (default band 2.0 °C) or `die >= --hard`, **up** when `die < target - band`.
  `--clock-floor 1500` / `--clock-max 2400` clamp the ladder.
- **Safety ceiling — hottest board zone** (max over all `/sys/class/thermal/thermal_zone*/temp`):
  a hard `--ceiling` (default 92 °C) that forces a throttle-down only near a component limit.
  Board zones guard VRM/VRAM; they do **not** drive normal throttling. On the GB10 board/ACPI
  zones run hotter than the die — that gap is exactly why the die is the controlled variable.
- **`--dry-run`:** logs the clock the ladder *would* set against the live clock, applying **no**
  `-lgc`. Safe to validate the logic on a live, shared-GPU node before deploying.
- **Signals:** SIGTERM/SIGINT reset clocks to default (`-rgc`) then exit. `Restart=on-failure`
  in the unit restarts it if it dies.
- Usage: `python3 gb10-clock-governor.py --target 65 --ceiling 92` (deploy), or add
  `--dry-run` to log the proposed clock without applying `-lgc`.

## Both original designs hammered the clock

Neither v1 nor v2 held a steady clock. Both reacted to a sensor too noisy to control on level alone,
which is why both were replaced.

**v1 (board-zone target).** The GB10's board/ACPI zones run ~20–30 °C hotter than the die and swing
hard — the worst measured swing is **68.2 → 50.0 °C between samples 5 s apart** (~22 °C). Chasing
that raw sample, the clock swung **≈1410 ↔ 2392 MHz**, nearly the whole ladder, while the die stayed
cool (~50–70 °C) and never justified the drop.

**v2 (die target, board ceiling).** v2 demoted board zones to a hard `--ceiling 92` and targeted the
die at 65 °C. That looked clean in short runs but did not survive a back-to-back benchmark sweep:

| v2 config | clock range observed | clock avg | board max |
| --- | --- | --- | --- |
| `--target 65 --clock-max 2400` | **1976 ↔ 2392 MHz** | 2183 | 85 °C |
| `--target 65 --ceiling 89` | **1787 ↔ 2392 MHz** | 2158 | 87 °C |

The die swings **57 → 68 °C within a single 8 s tick**. Against a 65 °C target with a 2 °C band the
trigger was crossed on nearly every sample, so the ladder walked down and up repeatedly — a ~600 MHz
peak-to-peak swing, the same hammering as v1 from a different sensor.

**And the throttling bought nothing:** those runs peaked at 84–87 °C on the board, no cooler than
running flat at 2200 MHz with no governor (84 °C). Time was spent stepping down for heat already
dissipating — zones fall from 83 °C to 61 °C in ~12 s once load ends.

## What replaced it

Two changes fix both failures:

1. **Persistence, not level** — `--ceiling-samples N`: a zone must sit at/above `--ceiling` for N
   *consecutive* samples. Verified live: a forced test accumulated `ceil_run=1, 2` then the zone
   fell, the counter reset and **no throttle occurred**; a sustained test stepped down only on the
   third consecutive sample and reset afterwards (one rung, not a cascade).
2. **A clock cap as the primary protection**, die target raised so it is not the normal driver.

Current policy `--target 85 --ceiling 89 --ceiling-samples 3 --clock-max 2200`:

- 2200 cap bounds absolute heat for 24/7 workloads
- die must exceed **87 °C** (`85 + band`) to act — heaviest load tested peaked at 68 °C
- board zones must hold 89 °C for **24 s** (3 × 8 s) before the clock moves

Under the benchmark that hammered v2, this held **dead flat at 2190 MHz** with a board peak of 82 °C.

## Tuning the knobs

| Setting | Controls | Default | Where to change it |
| --- | --- | --- | --- |
| `--target` | GPU **die** °C to hold (primary control) | 65 | Service `ExecStart` → `daemon-reload` + `restart`. |
| `--ceiling` | Hottest **board** zone that forces a throttle-down | 92 | Service `ExecStart` → `daemon-reload` + `restart`. |
| `--ceiling-samples` | Consecutive samples a zone must sit at/above `--ceiling` before stepping down; `1` = react to a single sample | 1 | Service `ExecStart` → `daemon-reload` + `restart`. |
| `--band` | Clock only moves outside `target ± band` | 2.0 °C | Script (~line 84). Edit + redeploy. |
| `--hard` | Die emergency °C — step toward the floor | 89 °C | Script (~line 82). Edit + redeploy. |
| `--clock-max` / `--clock-floor` | Highest / lowest ladder rung | 2400 / 1500 MHz | Script (~lines 86–85). Edit + redeploy. |
| `--interval` | Seconds between samples | 8 | Script (~line 87). Edit + redeploy. |
| `LADDER` | The ceiling steps themselves | `[2400,2200,…,1200]` MHz | Script (line 23). Edit + redeploy. |

Note the **shipped unit** overrides the script defaults for the policy knobs:

```
ExecStart=/usr/bin/python3 /home/oliver/gb10-clock-governor.py \
    --target 85 --ceiling 89 --ceiling-samples 3 --clock-max 2200
```

so the effective die target is 85 °C, the board ceiling 89 °C with a 3-sample gate, and the top
rung 2200 MHz. The `65 / 92 / 2400` defaults above apply only when a knob is omitted from
`ExecStart`.

**Changing `--target` / `--ceiling`** (the common tweaks): edit `ExecStart` in the unit on each
node, then `sudo systemctl daemon-reload && sudo systemctl restart gb10-clock-governor.service`.
All other knobs are **script** edits — change, re-deploy to both nodes, restart.

## Test results (v2, live — `--target 65 --ceiling 92`)

Both nodes under a deepseek-v4.x decode workload (concurrency 12, `max_tokens` 2048), 4-minute
samples, die as the controlled variable:

| Node | Die (steady) | Board (steady / max) | Clock (steady) | Throttle events |
|------|--------------|----------------------|----------------|-----------------|
| spark-1 | ~62 °C | 75–84 °C / 84 °C | ~2392 MHz (top rung) | 0 |
| spark-2 | ~63 °C | 71–88 °C / 88 °C | ~2379 MHz (top rung) | 0 |

Both nodes pinned to the **top ladder rung the entire run** with **zero throttle events**; the
board stayed well under the 92 °C ceiling. This is the target behaviour — a steady clock instead
of the v1 board-zone oscillation (~1410↔2392 MHz). The v1 80/85 °C board-zone numbers are retained
in `README.md` for history but are not directly comparable (a board-zone target ≈ 60 °C die).

## Service design: `gb10-clock-governor.service`

- Runs as **root** → `nvidia-smi` passwordless on any node (spark-2 has no passwordless rule).
- `ExecStart` runs the governor at `--target 65 --ceiling 92`. No `ExecStop` (the governor resets
  on SIGTERM anyway; a stray `ExecStop` caused a startup hang in the v1 unit).
- `Restart=on-failure`, `RestartSec=5`. Enabled at boot (`WantedBy=multi-user.target`).
- Unit file is `gb10-clock-governor.service` (this repo).

## Deployment (per node)

Per node:

```bash
# 1. put the script where the unit's ExecStart points (edit the unit if your home differs):
install -m 0755 gb10-clock-governor.py ~/gb10-clock-governor.py

# 2. install + enable (needs root):
sudo install -o root -g root -m 0644 gb10-clock-governor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gb10-clock-governor.service

# 3. verify exactly one writer exists:
pgrep -af gb10-clock-governor.py
```

- The full install (`cp /etc`, `daemon-reload`, `enable`) needs **password sudo**. A passwordless
  `nvidia-smi -lgc/-rgc` sudoers rule is optional — the service runs as root so it calls
  `nvidia-smi` directly and needs no per-node rule at all.
- Verify: `systemctl status gb10-clock-governor.service` and
  `nvidia-smi -q -d CLOCK | grep Graphics` (running clock should sit near the top rung under load).

## Safety notes

- **Revert-safe:** the clock cap clears on reboot and on clean stop (`-rgc`).
- **Shared-GPU caveat:** on a node where another workload uses the same GPU, throttling the
  clock lowers that workload's throughput at the cost of a lower temperature. Confirm the
  trade-off is acceptable before enabling.
- **No container / EC / firmware writes** — this only sets a runtime GPU clock ceiling.
- Watchdog gap: `Restart=on-failure` restarts on crash, but a hard SIGKILL leaves the `-lgc`
  ceiling in place until reboot. If a no-kill watchdog is wanted, wrap the governor in a small
  supervisor that re-applies `-rgc` if the governor process disappears.
