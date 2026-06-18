#!/usr/bin/env bash
# Memory pressure early-warning. Alerts via Telegram and/or Gmail before OOM.
# Run periodically via systemd timer (every 1 min recommended).
set -uo pipefail

CONFIG="${MEM_ALERT_CONFIG:-/etc/mem-alert.env}"
[ -f "$CONFIG" ] && . "$CONFIG"

# ---- defaults (override in /etc/mem-alert.env) ----
MEM_AVAIL_WARN_PCT="${MEM_AVAIL_WARN_PCT:-15}"   # warn when available mem < this %
SWAP_USED_WARN_PCT="${SWAP_USED_WARN_PCT:-70}"   # warn when swap used > this %
COOLDOWN_SEC="${COOLDOWN_SEC:-900}"              # min seconds between repeat alerts
STATE_FILE="${STATE_FILE:-/var/run/mem-alert.state}"
HOSTNAME_TAG="${HOSTNAME_TAG:-$(hostname)}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

GMAIL_USER="${GMAIL_USER:-}"                      # full gmail address
GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD:-}"      # 16-char app password (NOT login pw)
GMAIL_TO="${GMAIL_TO:-$GMAIL_USER}"

now() { date +%s; }
ts()  { date '+%Y-%m-%d %H:%M:%S %Z'; }

read_mem() {
  # all values in kB
  MemTotal=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  MemAvailable=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  SwapTotal=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  SwapFree=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  AvailPct=$(( MemTotal>0 ? MemAvailable*100/MemTotal : 100 ))
  if [ "$SwapTotal" -gt 0 ]; then
    SwapUsedPct=$(( (SwapTotal-SwapFree)*100/SwapTotal ))
  else
    SwapUsedPct=0
  fi
}

recent_oom() {
  # look for OOM in the last 5 minutes via journald (fallback dmesg)
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --since "5 min ago" 2>/dev/null | grep -iE "Out of memory: Killed process|oom-kill" | tail -n 3
  else
    dmesg -T 2>/dev/null | grep -iE "Out of memory: Killed process|oom-kill" | tail -n 3
  fi
}

top_mem_procs() {
  ps -eo pid,comm,rss --sort=-rss 2>/dev/null | awk 'NR<=6{printf "  %s\n",$0}'
}

send_telegram() {
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
  curl -s --max-time 15 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode text="$1" >/dev/null
}

send_gmail() {
  [ -n "$GMAIL_USER" ] && [ -n "$GMAIL_APP_PASSWORD" ] || return 0
  local subject="$1" body="$2" tmp
  tmp=$(mktemp)
  {
    echo "From: ${GMAIL_USER}"
    echo "To: ${GMAIL_TO}"
    echo "Subject: ${subject}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo
    echo "$body"
  } > "$tmp"
  curl -s --max-time 25 --ssl-reqd \
    --url "smtps://smtp.gmail.com:465" \
    --user "${GMAIL_USER}:${GMAIL_APP_PASSWORD}" \
    --mail-from "${GMAIL_USER}" \
    --mail-rcpt "${GMAIL_TO}" \
    --upload-file "$tmp" >/dev/null
  rm -f "$tmp"
}

main() {
  read_mem
  local reasons=""
  [ "$AvailPct" -lt "$MEM_AVAIL_WARN_PCT" ] && reasons="${reasons}- Available RAM low: ${AvailPct}% (threshold ${MEM_AVAIL_WARN_PCT}%)\n"
  [ "$SwapUsedPct" -gt "$SWAP_USED_WARN_PCT" ] && reasons="${reasons}- Swap usage high: ${SwapUsedPct}% (threshold ${SWAP_USED_WARN_PCT}%)\n"
  local oom; oom=$(recent_oom)
  [ -n "$oom" ] && reasons="${reasons}- OOM detected in last 5 min!\n"

  if [ -z "$reasons" ]; then
    # healthy: clear cooldown so next event alerts immediately
    rm -f "$STATE_FILE"
    exit 0
  fi

  # cooldown to avoid spam
  if [ -f "$STATE_FILE" ]; then
    local last; last=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    if [ $(( $(now) - last )) -lt "$COOLDOWN_SEC" ]; then
      exit 0
    fi
  fi
  echo "$(now)" > "$STATE_FILE"

  local body
  body="[MEM ALERT] ${HOSTNAME_TAG}  $(ts)
$(printf "%b" "$reasons")
MemTotal: $((MemTotal/1024)) MB
MemAvailable: $((MemAvailable/1024)) MB (${AvailPct}%)
Swap used: ${SwapUsedPct}%

Top memory processes (pid comm rss-kB):
$(top_mem_procs)
${oom:+
Recent OOM lines:
$oom}"

  send_telegram "$body"
  send_gmail "[MEM ALERT] ${HOSTNAME_TAG} low memory" "$body"
}

main "$@"