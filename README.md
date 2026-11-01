# DGX Spark (GB10) dynamic clock governor — a temperature-target clock profile

A small systemd service that runs a closed-loop clock governor on each NVIDIA DGX Spark / GB10
node. It holds the **GPU die** near a target temperature by walking the `nvidia-smi -lgc`
runtime clock ceiling up/down, so clocks and throughput self-adjust to the thermal situation
instead of running flat at max boost. A hard board-zone ceiling guards VRM/VRAM without
driving normal throttling.

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

## Why die-targeted, not board-zone?

The GB10's board/ACPI thermal zones run ~20–30 °C **hotter** than the GPU die and swing hard — a
single zone can jump ~10 °C in a few seconds. The original (v1) design chased the **hottest board
zone**, so the clock followed the board's noise (≈1410↔2392 MHz) even though the die itself stayed
cool (~50–70 °C).

We switched to holding the **die** because:

- It's the sensor NVIDIA's own thermal protection watches — the GPU throttles the **die** at
  ~87 °C, so the die is what actually caps performance and longevity.
- It's thermally stable, so controlling it holds the clock steady instead of chasing board spikes.
- Board zones still matter (they sit on top of VRM/VRAM that `nvidia-smi` can't read), so they're
  kept as a hard **ceiling** — but only as a fallback that bites near a component limit, never as
  the normal driver.

Result: the clock pins to the top rung (~2390 MHz) with zero throttling, and the board stays under
its ceiling.

## Tuning the knobs

The two most-common tweaks are passed by the **service**; everything else lives in the **script**.

| Setting | Controls | Default | Where to change it |
| --- | --- | --- | --- |
| `--target` | GPU **die** °C to hold (the primary control) | 65 | Service `ExecStart`, then `daemon-reload` + `restart`. |
| `--ceiling` | Hottest **board** zone that forces a throttle-down | 92 | Service `ExecStart`, then `daemon-reload` + `restart`. |
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
both nodes. (The service runs as root, so the script edits also go to `/home/oliver/gb10-clock-governor.py`.)

## Measured effect (v2 — die target + board ceiling)

Two-tier config `--target 65 --ceiling 92`, both nodes under a deepseek-v4.x decode workload:

| Node | Die (steady) | Board (steady / max) | Clock (steady) | Throttle events |
|------|--------------|----------------------|----------------|-----------------|
| spark-1 | ~62 °C | 75–84 °C / 84 °C | ~2392 MHz (top rung) | 0 |
| spark-2 | ~63 °C | 71–88 °C / 88 °C | ~2379 MHz (top rung) | 0 |

The die settles at the target while the board stays well under the 92 °C ceiling, and the clock
holds the **top ladder rung the entire time** — no oscillation, zero throttling. This is the
intended improvement over the v1 board-zone design, which chased the hottest board zone and let the
clock swing ~1410↔2392 MHz while the die stayed cool (~50–70 °C). (The v1 80/85 °C numbers above
referred to a *board-zone* target ≈ 60 °C die; the v2 die target is a different, cooler sensor, so
the two are not directly comparable by number.)

## Files

| File | Purpose |
| --- | --- |
| `gb10-clock-governor.py` | The governor (closed-loop clock ladder). |
| `gb10-clock-governor.service` | systemd unit: runs the governor as **root**, `Restart=on-failure`, enabled at boot. |
| `verify-gov.sh` | Prints the running clock, GPU temp, and hottest thermal zone — for a quick check. |
| `monitor.py` | Read-only observer: logs die, board, and running clock (reuses the governor's clock parse). Never writes a clock — safe on a live, shared-GPU node for validating the logic. |
| `dynamic-clocks.md` | Extended notes (mechanism, test results, safety). |
| `before.png` / `after.png` | Before/after thermal screenshots. |

**Why the service runs as root.** Root runs `nvidia-smi` directly with no password, so the same
unit works on every node without needing a per-node passwordless-`nvidia-smi` sudoers rule. The
script falls back to `sudo -n nvidia-smi` when not root.

## Deploy (per node)

The install (`cp /etc/systemd/system`, `daemon-reload`, `enable`) needs **password sudo** on the
target node. Run as the deployment user (e.g. `oliver`):

```bash
# 1. push the two files (user-land paths; no password)
scp gb10-clock-governor.service oliver@<spark-1-ip>:/tmp/
scp gb10-clock-governor.py       oliver@<spark-1-ip>:/home/oliver/

# 2. install + enable (password sudo):
sudo cp /tmp/gb10-clock-governor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gb10-clock-governor.service

# 3. verify:
systemctl is-active gb10-clock-governor.service     # -> active
pgrep -af gb10-clock-governor.py                     # -> the governor process
./verify-gov.sh                                       # clock + hottest-zone temp
```

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
sudo rm /home/oliver/gb10-clock-governor.py

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
