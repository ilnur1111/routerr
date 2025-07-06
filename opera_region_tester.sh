#!/bin/sh
# opera_region_tester.sh — тест EU / AM / AS, сохраняет выбранный регион
set -e

PORT=18080
PROXY_URL="http://127.0.0.1:$PORT"
TMPDIR=/tmp/opera_region_test
SIZE=5000000                                   # 5 МБ
TEST_URL="https://speed.cloudflare.com/__down?bytes=${SIZE}"

mkdir -p "$TMPDIR"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root"; exit 1; }; }

check_opera() {
  OPERA_BIN="$(command -v opera-proxy || true)"
  [ -n "$OPERA_BIN" ] || { echo "ERROR: opera-proxy not found"; exit 1; }
}

get_regions() {
  REGIONS=$("$OPERA_BIN" -list-countries 2>/dev/null | awk -F, 'NR>1{print $1}')
  [ -n "$REGIONS" ] || REGIONS="EU AM AS"
}

kill_proxy()  { killall -q opera-proxy 2>/dev/null || true; sleep 1; }

run_proxy_tmp() {                            # $1 = region
  kill_proxy
  "$OPERA_BIN" -country "$1" -bind-address 127.0.0.1:$PORT >/dev/null 2>&1 &
  sleep 6
}

measure_region() {                           # $1 = region
  r=$1; echo "=== Testing $r ==="
  run_proxy_tmp "$r"
  t=$( { time -p curl -s -o /dev/null -x "$PROXY_URL" "$TEST_URL"; } 2>&1 |
       awk '/real/{print $2}' )
  [ -n "$t" ] || { echo "$r 9999 0" | tee -a "$TMPDIR/results.txt"; return; }
  dl=$(awk -v sz=$SIZE -v tt=$t 'BEGIN{printf "%.1f", (sz*8)/(tt*1000000)}')
  echo "$r $t $dl" | tee -a "$TMPDIR/results.txt"
}

print_results() {
  echo; echo "===== RESULTS ====="
  printf "%-4s %-10s %-10s\n" Reg Time_s DL_Mbps
  sort -k3 -nr "$TMPDIR/results.txt" |
    while read r t d; do printf "%-4s %-10s %-10s\n" "$r" "$t" "$d"; done
  BEST=$(sort -k3 -nr "$TMPDIR/results.txt" | head -n1 | awk '{print $1}')
  echo; echo "Best region: $BEST"
}

choose_region() {
  echo; echo "Select region (0 = best):"
  idx=1; for r in $REGIONS; do echo "[$idx] $r"; idx=$((idx+1)); done
  echo "[0] $BEST (recommended)"; printf "> "
  read -r CHOICE < /dev/tty
  if [ "$CHOICE" = "0" ]; then CHOSEN=$BEST
  else
    idx=1
    for r in $REGIONS; do [ "$idx" = "$CHOICE" ] && CHOSEN=$r; idx=$((idx+1)); done
  fi
  [ -n "$CHOSEN" ] || { echo "ERROR: invalid choice"; exit 1; }
}

patch_init() {                                # $1 = EU/AM/AS
  INIT=/etc/init.d/opera-proxy
  if grep -q 'procd_set_param[[:space:]]\+command[[:space:]]\+.*opera-proxy' "$INIT"; then
    sed -i -E \
      "s@(procd_set_param[[:space:]]+command[[:space:]]+[^ ]*opera-proxy)([^#]*)@\1 -country $1@" \
      "$INIT"
  elif grep -q '/opera-proxy' "$INIT"; then
    sed -i -E "s@(/opera-proxy)([[:space:]]|\"|$)@\1 -country $1 @@" "$INIT"
  else
    echo "ERROR: cannot patch $INIT"; exit 1
  fi
}

apply_region() {
  echo "Applying region $CHOSEN ..."
  patch_init "$CHOSEN"
  /etc/init.d/opera-proxy enable
  /etc/init.d/opera-proxy restart
  sleep 5
}

verify_region() {
  country=$(curl -s --proxy "$PROXY_URL" https://ipinfo.io/country || echo "?")
  echo "Proxy reports country: $country"
}

main() {
  need_root
  check_opera
  get_regions
  rm -f "$TMPDIR/results.txt"

  for r in $REGIONS; do measure_region "$r"; done
  kill_proxy
  print_results
  choose_region
  apply_region
  verify_region
  echo "Done."
}

main "$@"
