#!/usr/bin/env bash
# One-click installer for mem-alert / tunnel-alert / heartbeat.
# Run from the directory containing these files:  sudo ./install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "Please run as root: sudo ./install.sh"; exit 1; fi

SRC="$(cd "$(dirname "$0")" && pwd)"
echo "Installing from: $SRC"

# 1. dependency
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found, installing..."
  apt-get update && apt-get install -y curl ca-certificates
fi

# 2. scripts
for s in mem-alert.sh tunnel-alert.sh heartbeat.sh; do
  install -m 0755 "$SRC/$s" "/usr/local/bin/$s"
  echo "  installed /usr/local/bin/$s"
done

# 3. config (do NOT overwrite existing env with secrets)
if [ -f /etc/mem-alert.env ]; then
  echo "  /etc/mem-alert.env already exists -> keeping it (not overwritten)"
else
  install -m 0600 "$SRC/mem-alert.env" /etc/mem-alert.env
  echo "  installed /etc/mem-alert.env (REMEMBER to fill in Telegram/Gmail values!)"
fi

# 4. systemd units
for u in mem-alert.service mem-alert.timer \
         tunnel-alert.service tunnel-alert.timer \
         heartbeat.service heartbeat.timer; do
  install -m 0644 "$SRC/$u" "/etc/systemd/system/$u"
  echo "  installed /etc/systemd/system/$u"
done

# 5. enable timers
systemctl daemon-reload
systemctl enable --now mem-alert.timer tunnel-alert.timer heartbeat.timer

echo
echo "Done. Active timers:"
systemctl list-timers mem-alert.timer tunnel-alert.timer heartbeat.timer --no-pager || true
echo
echo "Test commands:"
echo "  sudo /usr/local/bin/heartbeat.sh        # should send a heartbeat now"
echo "  sudo rm -f /var/run/mem-alert.state && sudo sed -i 's/^MEM_AVAIL_WARN_PCT=.*/MEM_AVAIL_WARN_PCT=100/' /etc/mem-alert.env && sudo /usr/local/bin/mem-alert.sh   # force a mem alert (revert after!)"