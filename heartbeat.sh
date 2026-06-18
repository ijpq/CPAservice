#!/usr/bin/env bash
# Daily heartbeat: confirms monitoring is alive. Sends a short status summary.
set -uo pipefail

CONFIG="${HEARTBEAT_CONFIG:-/etc/mem-alert.env}"
[ -f "$CONFIG" ] && . "$CONFIG"

HOSTNAME_TAG="${HOSTNAME_TAG:-$(hostname)}"
CF_SERVICE="${CF_SERVICE:-cloudflared}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
GMAIL_USER="${GMAIL_USER:-}"
GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD:-}"
GMAIL_TO="${GMAIL_TO:-$GMAIL_USER}"

ts() { date '+%Y-%m-%d %H:%M:%S %Z'; }

send_telegram() {
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
  curl -s --max-time 15 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode text="$1" >/dev/null
}

send_gmail() {
  [ -n "$GMAIL_USER" ] && [ -n "$GMAIL_APP_PASSWORD" ] || return 0
  local subject="$1" body="$2" tmp; tmp=$(mktemp)
  { echo "From: ${GMAIL_USER}"; echo "To: ${GMAIL_TO}"; echo "Subject: ${subject}";
    echo "MIME-Version: 1.0"; echo "Content-Type: text/plain; charset=UTF-8"; echo; echo "$body"; } > "$tmp"
  curl -s --max-time 25 --ssl-reqd --url "smtps://smtp.gmail.com:465" \
    --user "${GMAIL_USER}:${GMAIL_APP_PASSWORD}" \
    --mail-from "${GMAIL_USER}" --mail-rcpt "${GMAIL_TO}" --upload-file "$tmp" >/dev/null
  rm -f "$tmp"
}

# memory snapshot
MemTotal=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MemAvailable=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
SwapTotal=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SwapFree=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
AvailPct=$(( MemTotal>0 ? MemAvailable*100/MemTotal : 100 ))
if [ "$SwapTotal" -gt 0 ]; then SwapUsedPct=$(( (SwapTotal-SwapFree)*100/SwapTotal )); else SwapUsedPct=0; fi

cf_state=$(systemctl is-active "${CF_SERVICE}" 2>/dev/null || echo "n/a")
mem_timer=$(systemctl is-active mem-alert.timer 2>/dev/null || echo "n/a")
tun_timer=$(systemctl is-active tunnel-alert.timer 2>/dev/null || echo "n/a")
upt=$(uptime -p 2>/dev/null || echo "?")

# OOM in last 24h?
oom24=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep -ciE "Out of memory: Killed process|oom-kill")

body="[HEARTBEAT] ${HOSTNAME_TAG}  $(ts)
Monitoring is alive.

Memory: available ${AvailPct}% ($((MemAvailable/1024)) / $((MemTotal/1024)) MB), swap used ${SwapUsedPct}%
OOM kills (24h): ${oom24}
cloudflared: ${cf_state}
Timers: mem-alert=${mem_timer}, tunnel-alert=${tun_timer}
Uptime: ${upt}"

send_telegram "$body"
send_gmail "[HEARTBEAT] ${HOSTNAME_TAG} monitoring alive" "$body"