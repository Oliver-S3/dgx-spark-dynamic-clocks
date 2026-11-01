# GB10 Dynamic Clock Governor (SparkCluster)

A systemd service that runs a closed-loop clock governor on each GB10 node using a
**two-tier** sensor strategy: it holds the **GPU die** near a target temperature via
`nvidia-smi -lgc` (walking the runtime clock ceiling up/down), while a hard **board-zone**
ceiling guards VRM/VRAM without driving normal throttling. Clocks and throughput
self-adjust to the thermal situation instead of running flat at max boost.

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
