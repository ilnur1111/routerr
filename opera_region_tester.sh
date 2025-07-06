#!/bin/sh
# opera_region_tester.sh  —  тест всех регионов opera-proxy и установка лучшего/выбранного
set -e

PORT=18080
PROXY_URL="http://127.0.0.1:$PORT"
TMPDIR=/tmp/opera_region_test
mkdir -p "$TMPDIR"

### ──────────────────────── базовые проверки ─────────────────────────
need_root() { [ "$(id -u)" -eq 0 ] || { echo "🚫  Запустите скрипт от root!"; exit 1; }; }

check_opera() {
    OPERA_BIN="$(command -v opera-proxy || true)"
    [ -n "$OPERA_BIN" ] || { echo "🚫  opera-proxy не найден. Установите пакет и повторите."; exit 1; }
}

install_speedtest() {
    if ! command -v speedtest-cli >/dev/null 2>&1; then
        echo "▶  Устанавливаю python3 и speedtest-cli …"
        opkg update
        opkg install python3 python3-pip || opkg install python3 python3
        command -v pip3 >/dev/null 2>&1 || python3 -m ensurepip --upgrade
        pip3 install --no-cache-dir speedtest-cli
    fi
}

get_regions() {
    REGIONS=$("$OPERA_BIN" -list-countries 2>/dev/null | awk -F, 'NR>1{print $1}')
    [ -n "$REGIONS" ] || REGIONS="EU AM AS"
}

### ──────────────────────── запуск / остановка ────────────────────────
kill_proxy()  { killall -q opera-proxy 2>/dev/null || true; sleep 1; }

run_proxy_tmp() {             # $1 = регион
    kill_proxy
    "$OPERA_BIN" -country "$1" -listen 127.0.0.1:$PORT >/dev/null 2>&1 &
    sleep 6
}

### ──────────────────────── измерения ────────────────────────────────
measure_region() {            # $1 = регион
    region="$1"
    printf "\n=== Тест %s ===\n" "$region"
    run_proxy_tmp "$region"

    SPEED=$(HTTP_PROXY=$PROXY_URL HTTPS_PROXY=$PROXY_URL \
            speedtest-cli --simple 2>/dev/null || true)

    PING_MS=$(echo "$SPEED" | awk '/Ping/{print $2}')
    DL=$(echo "$SPEED"      | awk '/Download/{print $2}')
    UL=$(echo "$SPEED"      | awk '/Upload/{print $2}')

    [ -n "$PING_MS" ] || PING_MS=9999
    [ -n "$DL" ]      || DL=0
    [ -n "$UL" ]      || UL=0

    echo "$region $PING_MS $DL $UL" | tee -a "$TMPDIR/results.txt"
}

print_summary() {
    printf "\n===== ИТОГ =====\n"
    printf "%-4s %-8s %-8s %-8s\n" "Reg" "Ping" "DL" "UL"
    sort -k3 -nr "$TMPDIR/results.txt" |
    while read r p d u; do printf "%-4s %-8s %-8s %-8s\n" "$r" "$p" "$d" "$u"; done
    BEST=$(sort -k3 -nr "$TMPDIR/results.txt" | head -n1 | awk '{print $1}')
    printf "\n🚀  Лучший по скорости: %s\n" "$BEST"
}

choose_region() {
    printf "\nВыберите регион (0 = лучший):\n"
    idx=1
    for r in $REGIONS; do printf "[%d] %s\n" "$idx" "$r"; idx=$((idx+1)); done
    printf "[0] %s (рекомендуется)\n> " "$BEST"
    read -r CHOICE < /dev/tty
    if [ "$CHOICE" = "0" ]; then CHOSEN="$BEST"
    else
        idx=1
        for r in $REGIONS; do [ "$idx" = "$CHOICE" ] && CHOSEN="$r"; idx=$((idx+1)); done
    fi
    [ -n "$CHOSEN" ] || { echo "🚫  Неверный выбор."; exit 1; }
}

### ──────────────────────── сохранение региона ───────────────────────
patch_init() {                # $1 = регион
    INIT=/etc/init.d/opera-proxy
    grep -q -- '-country' "$INIT" \
        &&  sed -i -E "s/-country [A-Z]{2}/-country $1/" "$INIT" \
        ||  sed -i -E "s@(opera-proxy[^\n]*)@\1 -country $1@" "$INIT"
    chmod +x "$INIT"
}

apply_region() {
    echo "▶  Применяю регион $CHOSEN …"
    patch_init "$CHOSEN"
    /etc/init.d/opera-proxy enable
    /etc/init.d/opera-proxy restart
}

verify_region() {
    OUT=$(curl -s --proxy "$PROXY_URL" https://ipinfo.io/country || echo "?")
    printf "🌍  Прокси выдал страну: %s\n" "$OUT"
    echo "$OUT" | grep -qi "$CHOSEN" && echo "✅  Регион установлен." \
                                         || echo "⚠️   Ожидали $CHOSEN"
}

### ──────────────────────── main ─────────────────────────────────────
main() {
    need_root
    check_opera
    install_speedtest
    get_regions
    rm -f "$TMPDIR/results.txt"

    for r in $REGIONS; do measure_region "$r"; done
    kill_proxy
    print_summary
    choose_region
    apply_region
    verify_region
    echo "✔  Готово."
}

main "$@"
