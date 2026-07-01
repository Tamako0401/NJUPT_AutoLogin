#!/bin/sh
set -u

BASE="/root/njupt-autologin"
NAME="${1:-}"
CONF="$BASE/accounts/$NAME.conf"
LOCK="$BASE/locks/$NAME.lock"
TAG="njupt-autologin-$NAME"

[ -n "$NAME" ] || exit 1
[ -r "$CONF" ] || {
  logger -t "$TAG" "missing config: $CONF"
  exit 1
}

. "$CONF"
mkdir -p "$BASE/locks"

MWAN_STOPPED=0
TEMP_MAC_SET=0

log() {
  logger -t "$TAG" "$*"
}

mwan_running() {
  pgrep -f 'mwan3track' >/dev/null 2>&1
}

mwan_iface_online() {
  mwan3 status 2>/dev/null | grep -q "interface $IFACE_UCI is online"
}

restore_mwan() {
  if [ "$MWAN_STOPPED" = "1" ]; then
    /etc/init.d/mwan3 start >/dev/null 2>&1 || log "warning: failed to restart mwan3"
    log "mwan3 restored"
    MWAN_STOPPED=0
  fi
}

within_limited_time() {
  dow="$(date +%u)"
  hm="$(date +%H%M)"
  case "$dow" in
    1|2|3|4) [ "$hm" -ge 0701 ] && [ "$hm" -le 2329 ] ;;
    5)       [ "$hm" -ge 0701 ] ;;
    6)       return 0 ;;
    7)       [ "$hm" -le 2329 ] ;;
    *)       return 1 ;;
  esac
}

wait_ipv4() {
  i=0
  while [ "$i" -lt "${WAIT_IPV4_SECONDS:-25}" ]; do
    if ifstatus "$IFACE_UCI" 2>/dev/null | grep -q '"up": true' &&
       ip -4 addr show dev "$DEV" 2>/dev/null | grep -q 'inet '; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

http_code() {
  url="${CHECK_URL:-http://connect.rom.miui.com/generate_204}"
  code="$(curl -4 --interface "$DEV" --connect-timeout "${CHECK_CONNECT_TIMEOUT:-3}" --max-time "${CHECK_MAX_TIME:-8}" -sk -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  [ -n "$code" ] || code="000"
  printf '%s' "$code"
}

set_temp_mac() {
  [ "${RANDOMIZE_MAC_ON_RENEW:-0}" = "1" ] || return 0
  mac="$(awk 'BEGIN{srand(); printf "02:%02x:%02x:%02x:%02x:%02x", int(rand()*256), int(rand()*256), int(rand()*256), int(rand()*256), int(rand()*256)}')"
  if uci -q show "network.$DEV" >/dev/null 2>&1; then
    uci set "network.$DEV.macaddr=$mac"
    uci commit network
    TEMP_MAC_SET=1
    log "set temporary UCI MAC for $DEV"
    return 0
  fi
  ip link set dev "$DEV" down >/dev/null 2>&1 || true
  ip link set dev "$DEV" address "$mac" >/dev/null 2>&1 || log "warning: failed to change MAC for $DEV"
  ip link set dev "$DEV" up >/dev/null 2>&1 || true
}

clear_temp_mac() {
  if [ "$TEMP_MAC_SET" = "1" ]; then
    uci delete "network.$DEV.macaddr" >/dev/null 2>&1 || true
    uci commit network
    TEMP_MAC_SET=0
    log "cleared temporary UCI MAC for $DEV"
  fi
}

renew_iface() {
  [ "${RENEW_BEFORE_LOGIN:-0}" = "1" ] || return 0
  log "renew $IFACE_UCI before login"
  ifdown "$IFACE_UCI" >/dev/null 2>&1 || true
  sleep "${RENEW_DOWN_SLEEP:-2}"
  set_temp_mac
  ifup "$IFACE_UCI" >/dev/null 2>&1 || true
  if wait_ipv4; then
    clear_temp_mac
    log "$IFACE_UCI has IPv4 after renew"
    return 0
  fi
  clear_temp_mac
  log "$IFACE_UCI has no IPv4 after renew"
  return 1
}

run_login() {
  out="/tmp/njupt-autologin-$NAME.$$.log"
  if [ "${TIME_UNLIMITED:-1}" = "1" ]; then
    /bin/bash /root/NJUPT-AutoLogin.sh -i "$DEV" -I "$ISP" -t "${LOGIN_TIMEOUT:-2}" -v -n "$LOGIN_ID" "$LOGIN_PW" >"$out" 2>&1
  else
    /bin/bash /root/NJUPT-AutoLogin.sh -i "$DEV" -I "$ISP" -t "${LOGIN_TIMEOUT:-2}" -v "$LOGIN_ID" "$LOGIN_PW" >"$out" 2>&1
  fi
  rc=$?
  if grep -q 'Time is out of range' "$out" 2>/dev/null; then
    log "login skipped by time window"
    rm -f "$out"
    return 2
  fi
  if grep -q 'Login failed\|Failed to connect\|FAILED' "$out" 2>/dev/null; then
    log "underlying login reported failure rc=$rc"
  else
    log "underlying login exited rc=$rc"
  fi
  rm -f "$out"
  return "$rc"
}

(
  flock -n 9 || {
    log "previous run still active, skip"
    exit 0
  }

  trap 'clear_temp_mac; restore_mwan' EXIT INT TERM

  if [ "${TIME_UNLIMITED:-1}" != "1" ] && ! within_limited_time; then
    log "outside limited-account time window, skip"
    exit 0
  fi

  if ! wait_ipv4; then
    log "$IFACE_UCI/$DEV is not ready, try ifup"
    ifup "$IFACE_UCI" >/dev/null 2>&1 || true
    wait_ipv4 || {
      log "$IFACE_UCI/$DEV still has no IPv4, skip"
      exit 1
    }
  fi

  if [ "${TRUST_MWAN_ONLINE:-1}" = "1" ] && mwan_iface_online; then
    log "$IFACE_UCI already online according to mwan3, skip login"
    exit 0
  fi

  code="$(http_code)"
  if [ "$code" = "204" ]; then
    log "$DEV already online by direct check, skip login"
    exit 0
  fi
  log "$DEV precheck code=$code, login required"

  if [ "${PAUSE_MWAN3:-0}" = "1" ] && mwan_running; then
    /etc/init.d/mwan3 stop >/dev/null 2>&1 || log "warning: failed to stop mwan3"
    MWAN_STOPPED=1
    log "mwan3 stopped for local auth on $DEV"
    sleep "${MWAN_STOP_SLEEP:-2}"
  fi

  code="$(http_code)"
  if [ "$code" = "204" ]; then
    log "$DEV online after pausing mwan3, skip login"
    exit 0
  fi

  renew_iface || true
  log "start login on $DEV / $ISP"
  run_login

  code="$(http_code)"
  if [ "$code" = "204" ]; then
    log "login verified on $DEV code=$code"
    exit 0
  fi

  log "login not verified on $DEV postcheck code=$code"
  exit 1
) 9>"$LOCK"
