# DGX Spark (GB10) dynamic clock governor — a temperature-target clock profile

A small systemd service that runs a closed-loop clock governor on each NVIDIA DGX Spark / GB10
node. It holds the GPU near a target temperature (validated at **85 °C**) by walking the
`nvidia-smi -lgc` runtime clock ceiling up/down, so clocks and throughput self-adjust to the
thermal situation instead of running flat at max boost.

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

The governor walks a fixed ladder of ceilings driven by the **hottest** sensor on the node:

- **Ladder:** `[2400, 2200, 2000, 1800, 1700, 1500, 1300, 1200]` MHz (high → low).
- Steps the clock **down** when `hottest > target + band` (default band `2.0 °C`) or when
  `hottest >= --hard` (emergency jump). Steps **up** when `hottest < target - band`.
- **Hottest sensor** = max over all `/sys/class/thermal/thermal_zone*/temp` and
  `nvidia-smi temperature.gpu`. On the GB10 the board/ACPI zones (5/6, and 0) read hotter than
  the GPU die — that's the value held at the target.
- **SIGTERM/SIGINT** reset the clocks to default (`-rgc`) and exit; `Restart=on-failure` in the
  unit restarts it if it ever dies.

```bash
python3 gb10-clock-governor.py --target 85        # °C to hold on the hottest zone
python3 gb10-clock-governor.py --target 85 --band 2.0 --interval 8 --hard 87
```

## Measured effect (heavy sustained decode load)

Steady-state under a deepseek-v4.x decode workload (concurrency 12, `max_tokens` 2048):

| Target | Hottest zone | Clock (steady) | Decode throughput | Power |
|--------|--------------|----------------|-------------------|-------|
| 80 °C  | ~80.8 °C     | ~1787 MHz      | 128.8 out tok/s   | ~32 W |
| **85 °C** | ~84.0 °C  | ~1981 MHz      | **143.1 out tok/s (+11 %)** | ~38 W |

At **85 °C** the governor holds the hottest zone around ~84 °C and runs ~2000 MHz, giving
**~11 % more decode throughput** than 80 °C for ~3 °C more heat. The 85-vs-80 gap is consistent;
the absolute steady-state clock drifts somewhat with thermal soak length.

## Files

| File | Purpose |
| --- | --- |
| `gb10-clock-governor.py` | The governor (closed-loop clock ladder). |
| `gb10-clock-governor.service` | systemd unit: runs the governor as **root**, `Restart=on-failure`, enabled at boot. |
| `verify-gov.sh` | Prints the running clock, GPU temp, and hottest thermal zone — for a quick check. |
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
