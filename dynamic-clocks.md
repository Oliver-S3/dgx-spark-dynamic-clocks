# GB10 Dynamic Clock Governor (SparkCluster)

A systemd service that runs a closed-loop clock governor on each GB10 node, holding the
GPU near a target temperature (validated at **85 °C**) via `nvidia-smi -lgc`, so clocks and
throughput self-adjust to the thermal situation instead of running flat at max boost.

## TL;DR

- Under a heavy sustained decode load, `nvidia-smi -lgc` **does** throttle the clock on GB10.
  (Earlier "no-op" verdicts were a measurement bug: malformed `-lgc 0 1500` with a space and
  reading the wrong clock field — "Applications Clocks", which never reflects `-lgc`.)
- At **85 °C** the governor holds ~84 °C hottest zone and runs ~2000 MHz, giving
  **~11% more decode throughput** than the **80 °C** target (~1790 MHz), for ~3 °C more heat.
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

Closed-loop ladder of clock ceilings, driven by the hottest sensor on the node:

- **Ladder:** `[2400, 2200, 2000, 1800, 1700, 1500, 1300, 1200]` MHz.
- **Target / band:** steps the clock down when `hottest > target + band` (default band 2.0 °C),
  up when `hottest < target - band`. `--clock-floor 1500` / `--clock-max 2400` clamp the ladder.
- **Hottest sensor** = max over all `/sys/class/thermal/thermal_zone*/temp` and
  `nvidia-smi temperature.gpu`. Zones 5/6 (and 0) run hottest (~88–96 °C); GPU die is cooler.
- **Emergency `--hard` jump** toward the floor if a threshold is exceeded.
- **Signals:** SIGTERM/SIGINT reset clocks to default (`-rgc`) then exit. `Restart=on-failure`
  in the unit restarts it if it dies.
- Usage: `python3 gb10-clock-governor.py --target 85 [--band 2.0] [--interval 3]`.

## Test results (`drive.py`, heavy sustained load: deepseek-v4.1-flash, concurrency 12,
max_tokens 2048, hitting :8000)

Steady-state (last 120 s), both targets reached a stable equilibrium (no thermal-throttle
events; the governor held below the 90–97 °C throttle band):

| Target | Hottest zone | Clock (steady) | Decode throughput | Power |
|--------|--------------|----------------|-------------------|-------|
| **80 °C** | 80.8 °C | ~1787 MHz (1800 rung) | **128.8** out tok/s | 32.1 W |
| **85 °C** | 84.0 °C | ~1981 MHz (2000 rung) | **143.1** out tok/s (+11%) | 38.5 W |

- **85 °C ≈ +11% decode throughput** vs 80 °C, for ~3 °C more heat.
- Caveat: steady-state clock is soak-sensitive. Shorter runs settled at the 1800/2000 rungs;
  the earlier 300 s runs both bottomed at the ~1500 MHz floor under longer thermal soak. The
  **85-vs-80 relative gap is consistent** (85 higher); only the absolute floor drifts with soak.

## Service design: `gb10-clock-governor.service`

- Runs as **root** → `nvidia-smi` passwordless on any node (spark-2 has no passwordless rule).
- `ExecStart` runs the governor at 85 °C; `ExecStop` resets clocks (`-rgc`).
- `Restart=on-failure`, `RestartSec=5`. Enabled at boot (`WantedBy=multi-user.target`).
- Unit file is `gb10-clock-governor.service` (this repo).

## Deployment (both sparks)

Per node (spark-1 = `<spark-1-ip>`, spark-2 = `<spark-2-ip>`):

```bash
# 1. governor script + unit (as oliver, passwordless for these paths where permitted;
#    on spark-2 the deploy itself needs password sudo for /home writes only if not permitted)
scp gb10-clock-governor.service oliver@<node>:/tmp/
scp gb10-clock-governor.py  oliver@<node>:/home/oliver/
# 2. install + enable (needs root):
sudo cp /tmp/gb10-clock-governor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gb10-clock-governor.service
```

- The full install (`cp /etc`, `daemon-reload`, `enable`) needs **password sudo**. A passwordless
  `nvidia-smi -lgc/-rgc` sudoers rule is optional — the service runs as root so it calls
  `nvidia-smi` directly and needs no per-node rule at all.
- Verify: `systemctl status gb10-clock-governor.service` and
  `nvidia-smi -q -d CLOCK | grep Graphics` (running clock should sit near the 2000 rung under load).

## Safety notes

- **Revert-safe:** the clock cap clears on reboot and on clean stop (`-rgc`).
- **Shared-GPU caveat:** on a node where another workload uses the same GPU, throttling the
  clock lowers that workload's throughput at the cost of a lower temperature. Confirm the
  trade-off is acceptable before enabling.
- **No container / EC / firmware writes** — this only sets a runtime GPU clock ceiling.
- Watchdog gap: `Restart=on-failure` restarts on crash, but a hard SIGKILL leaves the `-lgc`
  ceiling in place until reboot. If a no-kill watchdog is wanted, wrap the governor in a small
  supervisor that re-applies `-rgc` if the governor process disappears.
