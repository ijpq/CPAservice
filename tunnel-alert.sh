#!/usr/bin/env bash
# Cloudflare Tunnel health watcher (approach A: process state + journal scan).
# Reuses Telegram config from /etc/mem-alert.env. Run via systemd timer.
set -uo pipefail

CONFIG="${TUNNEL_ALERT_CONFIG:-/etc/mem-alert.env}"
[ -f "$CONFIG" ] && . "$CONFIG"

# ---- tunnel-specific defaults (override in /etc/mem-alert.env) ----
CF_SERVICE="${CF_SERVICE:-cloudflared}"          # systemd unit name, or empty to skip
CF_PROC="${CF_PROC:-cloudflared}"                # process name fallback
LOOKBACK_MIN="${LOOKBACK_MIN:-3}"                # scan journal of last N minutes
ERR_THRESHOLD="${ERR_THRESHOLD:-3}"              # # of generic err lines to trigger
TUNNEL_COOLDOWN_SEC="${TUNNEL_COOLDOWN_SEC:-900}"
TUNNEL_STATE_FILE="${TUNNEL_STATE_FILE:-/var/run/tunnel-alert.state}"
HOSTNAME_TAG="${HOSTNAME_TAG:-$(hostname)}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
GMAIL_USER="${GMAIL_USER:-}"
GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD:-}"
GMAIL_TO="${GMAIL_TO:-$GMAIL_USER}"

now() { date +%s; }
ts()  { date '+%Y-%m-%d %H:%M:%S %Z'; }

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

# Pull recent cloudflared log lines from journald.
# Prefer the systemd unit (-u), fall back to syslog identifier (-t).
cf_logs() {
  if [ -n "$CF_SERVICE" ] && systemctl list-unit-files "${CF_SERVICE}.service" >/dev/null 2>&1; then
    journalctl -u "$CF_SERVICE" --since "${LOOKBACK_MIN} min ago" --no-pager 2>/dev/null
  else
    journalctl -t "$CF_PROC" --since "${LOOKBACK_MIN} min ago" --no-pager 2>/dev/null
  fi
}

proc_down_reason=""
proc_running() {
  if [ -n "$CF_SERVICE" ] && systemctl list-unit-files "${CF_SERVICE}.service" >/dev/null 2>&1; then
    if [ "$(systemctl is-active "${CF_SERVICE}" 2>/dev/null)" = "active" ]; then
      return 0
    else
      proc_down_reason="systemd unit ${CF_SERVICE} is $(systemctl is-active "${CF_SERVICE}" 2>/dev/null)"
      return 1
    fi
  fi
  if pgrep -x "$CF_PROC" >/dev/null 2>&1; then
    return 0
  fi
  proc_down_reason="no running process matching '${CF_PROC}'"
  return 1
}

main() {
  local reasons="" logs serious generic
  logs="$(cf_logs)"

  # 1) process / service health
  if ! proc_running; then
    reasons="${reasons}- cloudflared not healthy: ${proc_down_reason}\n"
  fi

  # 2) serious patterns -> alert on ANY single occurrence
  serious="$(printf '%s\n' "$logs" | grep -iE \
    'network is unreachable|failed to dial to edge with quic|Failed to refresh DNS local resolver|no recent network activity' )"
  if [ -n "$serious" ]; then
    local n; n=$(printf '%s\n' "$serious" | grep -c .)
    reasons="${reasons}- serious tunnel errors in last ${LOOKBACK_MIN}m: ${n} line(s)\n"
  fi

  # 3) generic serve errors -> alert only when above threshold (reduce noise)
  generic="$(printf '%s\n' "$logs" | grep -iE \
    'Serve tunnel error|Connection terminated|failed to serve tunnel connection|datagram manager encountered a failure' )"
  if [ -n "$generic" ]; then
    local g; g=$(printf '%s\n' "$generic" | grep -c .)
    if [ "$g" -ge "$ERR_THRESHOLD" ]; then
      reasons="${reasons}- repeated tunnel serve errors in last ${LOOKBACK_MIN}m: ${g} (threshold ${ERR_THRESHOLD})\n"
    fi
  fi

  if [ -z "$reasons" ]; then
    rm -f "$TUNNEL_STATE_FILE"
    exit 0
  fi

  # cooldown
  if [ -f "$TUNNEL_STATE_FILE" ]; then
    local last; last=$(cat "$TUNNEL_STATE_FILE" 2>/dev/null || echo 0)
    [ $(( $(now) - last )) -lt "$TUNNEL_COOLDOWN_SEC" ] && exit 0
  fi
  echo "$(now)" > "$TUNNEL_STATE_FILE"

  local sample; sample="$(printf '%s\n' "$logs" | grep -iE \
    'network is unreachable|failed to dial to edge|Failed to refresh DNS|no recent network activity|Serve tunnel error|Connection terminated|datagram manager encountered a failure' \
    | tail -n 8)"

  local body
  body="[TUNNEL ALERT] ${HOSTNAME_TAG}  $(ts)
$(printf "%b" "$reasons")
Service: ${CF_SERVICE} ($(systemctl is-active "${CF_SERVICE}" 2>/dev/null || echo n/a))
Lookback: ${LOOKBACK_MIN} min

Recent error samples:
${sample:-  (none captured from journald; check container logs if cloudflared runs in Docker)}"

  send_telegram "$body"
  send_gmail "[TUNNEL ALERT] ${HOSTNAME_TAG} cloudflared issue" "$body"
}

main "$@"