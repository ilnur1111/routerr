#!/bin/sh
# opera_region_tester.sh — v1.5 (07-Jul-2025)
set -e
PORT=18080
PROXY_URL="http://127.0.0.1:$PORT"
TMPDIR="$(mktemp -d /tmp/opera_region_test.XXXXXX)"
SIZE=5000000
TEST_URL="https://speed.cloudflare.com/__down?bytes=${SIZE}"

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root"; exit 1; }; }
check_opera(){ OPERA_BIN=$(command -v opera-proxy) || { echo "opera-proxy not found"; exit 1; }; }
get_regions(){
  REGIONS=$("$OPERA_BIN" -list-countries 2>/dev/null | awk -F, 'NR>1{print $1}' | tr -d '[:space:]')
  [ -n "$REGIONS" ] || REGIONS="EU AM AS"
}
kill_proxy(){ pkill -q opera-proxy 2>/dev/null || true; }

run_proxy_tmp(){ kill_proxy; "$OPERA_BIN" -country "$1" -bind-address 127.0.0.1:$PORT >/dev/null 2>&1 &; for _ in $(seq 1 12); do netstat -tn 2>/dev/null | grep -q "127\.0\.0\.1:$PORT" && break; sleep 1; done; }

measure_region(){ r=$1; echo "=== Testing $r ==="; run_proxy_tmp "$r"; t=$( { time -p curl -s -o /dev/null -x "$PROXY_URL" "$TEST_URL"; } 2>&1 | awk '/real/{print $2}' ); [ -n "$t" ] || { echo "$r 9999 0" >>"$TMPDIR/results.txt"; return; }; dl=$(awk -v sz=$SIZE -v tt=$t 'BEGIN{printf "%.1f", (sz*8)/(tt*1000000)}'); echo "$r $t $dl" >>"$TMPDIR/results.txt"; }

print_results(){ echo; echo "===== RESULTS ====="; printf "%-4s %-10s %-10s\n" Reg Time_s DL_Mbps; sort -k3 -nr "$TMPDIR/results.txt" | while read r t d; do printf "%-4s %-10s %-10s\n" "$r" "$t" "$d"; done; BEST=$(sort -k3 -nr "$TMPDIR/results.txt" | head -n1 | awk '{print $1}'); echo; echo "Best region: $BEST"; }

patch_init(){                      # $1 = region
  INIT=/etc/init.d/opera-proxy
  sed -i -E 's@-country[[:space:]]+[A-Z]{2}@@g' "$INIT"   # wipe all old
  if grep -q 'procd_set_param[[:space:]]\+command[[:space:]]\+"[^"]*\$PROG"' "$INIT"; then
     # procd_set_param command "$PROG" …
     sed -i -E "s@(procd_set_param[[:space:]]+command[[:space:]]+\"[^\"]*\\\$PROG\")@\1 -country $1@" "$INIT"
     echo "[patch] added -country $1 after \$PROG"
  elif grep -q 'procd_set_param[[:space:]]\+command[[:space:]]+\$PROG' "$INIT"; then
     # same but without quotes
     sed -i -E "s@(procd_set_param[[:space:]]+command[[:space:]]+\\\$PROG)@\1 -country $1@" "$INIT"
     echo "[patch] added -country $1 after \$PROG"
  elif grep -q 'procd_set_param[[:space:]]\+command.*opera-proxy' "$INIT"; then
     # схема A: путь прописан прямо
     sed -i -E "s@(procd_set_param[[:space:]]+command[^\n]*opera-proxy)@\1 -country $1@" "$INIT"
     echo "[patch] added -country $1 to explicit path"
  else
     echo "ERROR: cannot patch $INIT"; exit 1
  fi
}

apply_region(){ echo "Applying region $CHOSEN …"; patch_init "$CHOSEN"; /etc/init.d/opera-proxy enable; /etc/init.d/opera-proxy restart; }

verify_region(){ country=$(curl -s --proxy "$PROXY_URL" https://ipinfo.io/country || echo "?"); echo "Proxy reports country: $country"; }

cleanup(){ kill_proxy; rm -rf "$TMPDIR"; }
trap cleanup EXIT

main(){ need_root; check_opera; get_regions; for r in $REGIONS; do measure_region "$r"; done; kill_proxy; print_results;
  if [ -n "$REG_OVERRIDE" ]; then CHOSEN=$REG_OVERRIDE; echo "Non-interactive: $CHOSEN"; else
    echo; echo "Select region (0 = best):"; idx=1; for r in $REGIONS; do echo "[$idx] $r"; idx=$((idx+1)); done; echo "[0] $BEST (recommended)"; printf "> "; read -r CHOICE < /dev/tty;
    [ "$CHOICE" = "0" ] && CHOSEN=$BEST || { idx=1; for r in $REGIONS; do [ "$idx" = "$CHOICE" ] && CHOSEN=$r; idx=$((idx+1)); done; }
    [ -n "$CHOSEN" ] || { echo "ERROR: invalid choice"; exit 1; }
  fi
  apply_region; verify_region; echo "Done."
}
main "$@"
