# Session 2026-11-08 — zone-guard cutover and deploy parity

Nodes: `spark-1` and `spark-2` (DGX Spark GB10, 2-node TP2). Session ran 2026-11-07 evening
local (UTC-5) = 2026-11-08 ~01:30–02:25 UTC.

## Trigger

- spark-1's hottest ACPI zone sat **90.4–94.6 °C for a full 65 s** at 2190 MHz (zones 0 and 5
  read 93.6 °C in a snapshot). Die was 62–66 °C throughout; no HW/SW slowdown flags.
- The production governor (`--target 85 --ceiling 89 --ceiling-samples 3 --clock-max 2200`)
  was stepping 2200→2000 and back **every tick** while the zone stayed hot.

## Findings

1. **The governor's board-ceiling branch is self-cancelling.** A confirmed ceiling hit
   (`ceiling_run >= 3`) takes one rung down and resets `ceiling_run`; on the next sample the
   counter is 1, and the die (62–66 °C) is below `target - band` (83 °C), so the die branch
   steps straight back up. Net: an 8 s sawtooth 2200↔2000 with no relief to the hotspot. This
   is structural — with a die target of 85 °C, the die branch is permanently "cool".

2. **The standalone guard engaged correctly, but the step bought no cooling.**

   | Time | Action | Zone |
   |---|---|---|
   | 01:39:05 | STEP-DOWN 2200→2000 after 3 consecutive ≥88 samples | 88.7 |
   | 01:39:13 – 01:39:54 | holding 2000, AT-FLOOR | 88.8 – 89.0 |
   | later, at 2200 | holding top rung | 86.7 – 88.9 |

   Within burst noise: dropping one rung did **not** move the board/ACPI zones. What moved them
   was the workload/die cooling (die 76 → 73 °C). Conclusion: for these zones the clock cap is
   not the lever — the load is. Worth an explicit A/B before spending throughput on 2000.

3. **Ladder state is not persisted.** `ci` initialises to 0 on every start, so a restart (or
   reboot) returns the guard to the top rung even if it had been holding 2000. Observed live on
   spark-1: `v2=2000` at 01:40:42 → `v2=2200` at 01:40:45 after a restart.

4. **Stopping/killing a writer unlocks the clock.** Both scripts reset with `-rgc` on SIGTERM.
   For the detached guard, killing it left the GPU uncapped (could boost to ~2418 MHz) with
   nothing to re-apply a ceiling. Fixed for the guard: it now re-asserts its rung every sample,
   not only when it decides to act.

5. **`/tmp` log crash-loop.** Root could not append to `/tmp/zone-guard.log` (mode 600, owned by
   `oliver`): `fs.protected_regular = 2` refuses an `O_CREAT` append in sticky `/tmp` even for
   root. The unit crash-looped (`restart counter is at 66`) and **spark-1 was left ungoverned**
   — the dying guard never set a clock, and the previous writer's SIGTERM had already run
   `-rgc`. spark-2 escaped it only because its unit created the file as root first.
   Fixed: both scripts fall back to stderr on a log-open `OSError`; the zone-guard unit sets
   `Environment=GOV_LOG=/var/log/gb10-zone-guard.log`.

6. **`deploy.sh` bugs found live.**
   - `systemctl enable --now` is a no-op on an already-active unit, so a redeploy left the old
     in-memory script running (PIDs unchanged). Now: `enable` + unconditional `restart`.
   - `git reset --hard` replaces `deploy.sh` while bash is still reading the old inode, so new
     logic in a just-pulled script was silently skipped. Now: hash before reset, re-exec once
     if the on-disk copy changed.

## Repo drift found (before the fixes)

- **Neither node had a checkout of this repo.** Deployment was hand-copied loose files.
- spark-1: governor script matched HEAD byte-for-byte; `gb10-zone-guard.py` was **absent**;
  the installed governor unit was a hand-edited variant (`Documentation=file:///home/oliver/
  Development/SparkCluster/...`, a path that exists on neither node); no zone-guard unit.
- spark-2: governor script matched HEAD; zone-guard script present but never run; same
  hand-edited unit.
- Repo docs and tooling (`README.md`, `dynamic-clocks.md`, `monitor.py`, `test_variants.sh`,
  `verify-gov.sh`) were absent from both nodes.

## Shipped

| Commit | Change |
|---|---|
| `a91335d` | guard re-asserts its rung every tick; `deploy.sh` (git-based); `gb10-zone-guard.service`; README deploy section |
| `02ab49c` | zone-guard unit: `--die-guard 89` emergency die backstop |
| `4281f48` | `deploy.sh` installs **both** unit files so `/etc` matches the checkout |
| `3e22d30` | log fallback to stderr; unit `GOV_LOG=/var/log/gb10-zone-guard.log` |
| `dbcb069` | `deploy.sh`: `restart` after install; quiet stray `pkill` |
| `1551046` | `deploy.sh`: re-exec when the reset replaces the script under it |

## Verified end state (2026-11-08 02:23–02:24 UTC)

| | spark-1 | spark-2 |
|---|---|---|
| Checkout HEAD | `dbcb069` | `dbcb069` |
| `gb10-zone-guard.service` | active, enabled | active, enabled |
| `gb10-clock-governor.service` | inactive, disabled | inactive, disabled |
| Running PID | 1828896 | 758690 |
| Unit hashes | `66e4c8d` / `df00809` | `66e4c8d` / `df00809` |
| Script hashes | `15c3c76` / `469aa8e` | `15c3c76` / `469aa8e` |
| Log | `/var/log/gb10-zone-guard.log` (root, 644) | same |
| Clock | 2197 MHz | 2190 MHz |
| Hottest zone | 81.0 °C | 79.3 °C |
| Guard state | `cool_run=3`, holding top rung | `cool_run=3`, holding top rung |

Both nodes were in a cool phase at verification time, so neither was throttling.

## Commands

```bash
# deploy / update either node (installs one unit, disables the other, restarts)
cd ~/dgx-spark-dynamic-clocks && ./deploy.sh zone-guard

# verification
pgrep -af gb10-
systemctl is-active gb10-zone-guard.service
nvidia-smi -q -d CLOCK | sed -n '/Clocks/,/Applications Clocks/p' | head -4
tail -f /var/log/gb10-zone-guard.log      # or: journalctl -u gb10-zone-guard -f
git -C ~/dgx-spark-dynamic-clocks rev-parse --short HEAD
```

## Open items

- **Persist the ladder state** (`ci`) across restart/reboot so a restart does not climb back to
  the top rung.
- **Decide SIGTERM semantics for the guard:** `-rgc` on stop leaves the GPU unlocked; for a
  guard it may be safer to leave the last cap in place (it clears on reboot anyway).
- **A/B the floor rung:** log a longer window at 2200 vs 2000 on both nodes to settle whether
  the step buys any zone cooling or is pure throughput cost.
- **Docs are stale on policy:** `README.md` / `dynamic-clocks.md` still present the governor as
  the shipped design, while both nodes now run the zone guard. Either reconcile the docs or
  treat the guard as the primary role.
- **spark-2 timezone:** its logs are ~5 h behind spark-1's UTC timestamps; compare `v2=` /
  `hot_run` / `cool_run` columns rather than timestamps.
