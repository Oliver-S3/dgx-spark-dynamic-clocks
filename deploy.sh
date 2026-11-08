#!/usr/bin/env bash
# Deploy this repo onto a GB10 node so the node runs an exact commit, not hand-copied files.
#
#   ./deploy.sh governor      # die-target governor (default)
#   ./deploy.sh zone-guard    # persistence-based board-zone guard
#
# Needs password sudo for the /etc/systemd/system install and daemon-reload.
# Leaves exactly ONE clock writer enabled: the unit for the selected role.
set -euo pipefail

ROLE=${1:-governor}
REPO_URL=${REPO_URL:-https://github.com/Oliver-S3/dgx-spark-dynamic-clocks.git}
DEST=${DEST:-$HOME/dgx-spark-dynamic-clocks}
BRANCH=${BRANCH:-main}

case "$ROLE" in
  governor)   UNIT=gb10-clock-governor.service ;;
  zone-guard) UNIT=gb10-zone-guard.service ;;
  *) echo "usage: $0 [governor|zone-guard]" >&2; exit 2 ;;
esac

# 1. Checkout at origin/HEAD (fresh clone, or fast-forward an existing one).
if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch --prune origin
  git -C "$DEST" reset --hard "origin/$BRANCH"
else
  git clone --branch "$BRANCH" "$REPO_URL" "$DEST"
fi
echo "repo: $DEST @ $(git -C "$DEST" rev-parse --short HEAD)"

# 2. Install the scripts where the units' ExecStart expects them.
install -m 0755 "$DEST/gb10-clock-governor.py" "$HOME/gb10-clock-governor.py"
install -m 0755 "$DEST/gb10-zone-guard.py"    "$HOME/gb10-zone-guard.py"
install -m 0755 "$DEST/monitor.py"            "$HOME/monitor.py"
install -m 0755 "$DEST/verify-gov.sh"         "$HOME/verify-gov.sh"

# 3. Install the chosen unit, and stop/disable the other so one writer cannot fight another.
sudo install -o root -g root -m 0644 "$DEST/$UNIT" /etc/systemd/system/
sudo systemctl daemon-reload
for u in gb10-clock-governor.service gb10-zone-guard.service; do
  [ "$u" = "$UNIT" ] || sudo systemctl disable --now "$u" 2>/dev/null || true
done
# Hand-launched (detached) guards are not systemd-managed and would be a second
# writer. Kill only the user-owned strays; the root unit processes are already stopped.
pkill -f 'gb10-zone-guard.py' || true
pkill -f 'gb10-clock-governor.py' || true
sleep 1
sudo systemctl enable --now "$UNIT"

# 4. Verify the node now matches the checkout.
sleep 2
echo "--- writers ---"
pgrep -af gb10- || true
echo "--- unit ---"
systemctl is-active "$UNIT"
echo "--- clock ---"
nvidia-smi -q -d CLOCK | sed -n '/Clocks/,/Applications Clocks/p' | head -4
echo "--- hashes (must match the checkout) ---"
sha256sum "$HOME/gb10-clock-governor.py" "$HOME/gb10-zone-guard.py"
sha256sum "$DEST/gb10-clock-governor.py" "$DEST/gb10-zone-guard.py"
