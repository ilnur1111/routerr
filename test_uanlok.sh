#!/bin/sh
# youtubeUnblock — умный тест стратегий (НЕ сохраняет конфиг)
# Отладочная версия: подробные логи на каждом шаге.
# 1) база без YU -> 2) перебор стратегий -> 3) дотюнинг -> 4) рейтинг + рекомендация
# Всё возвращает как было (trap EXIT). Сообщения — русские. Совместим с busybox sh.

set -eu

# ======= НАСТРОЙКИ ОТЛАДКИ (переопределяются окружением) =======
DEBUG="${YU_DEBUG:-1}"                # 1 = печатать отладку
CURL_VERBOSE="${YU_CURL_VERBOSE:-0}"  # 1 = curl -v (в логфайл)
TRACE_SH="${YU_TRACE_SH:-0}"          # 1 = set -x

RUNS="${YU_TEST_RUNS:-2}"             # повторы на стратегию (берём лучший)
TIMEOUT="${YU_TEST_TIMEOUT:-20}"      # общий таймаут curl, сек
CTO="${YU_CONNECT_TIMEOUT:-5}"         # connect-timeout, сек
DO_TR="${YU_TRACE:-1}"                # 1 = короткий traceroute (если установлен)
SLEEP_RESTART="${YU_SLEEP:-1}"        # пауза после рестарта сервиса
ANCHOR="${YU_ANCHOR:-google.com}"     # якорь для --connect-to
CURL_IPVER="${YU_IPVER:--4}"          # жёстко IPv4

# Канонические URL из README
TEST_YU="https://test.googlevideo.com/v2/cimg/android/blobs/sha256:6fd8bdac3da660bde7bd0b6f2b6a46e1b686afb74b9a4614def32532b73f5eaa"
TEST_REF="https://mirror.gcr.io/v2/cimg/android/blobs/sha256:6fd8bdac3da660bde7bd0b6f2b6a46e1b686afb74b9a4614def32532b73f5eaa"

# ======= УТИЛИТЫ И ЛОГИ =======
TS() { date '+%Y-%m-%d %H:%M:%S'; }
LOGFILE="/tmp/yu_tester_$(date +%s).log"

log() { printf '%s %s\n' "$(TS)" "$*" | tee -a "$LOGFILE"; }
dlog() { [ "$DEBUG" = "1" ] && printf '%s [DBG] %s\n' "$(TS)" "$*" | tee -a "$LOGFILE" >/dev/null; true; }
die() { printf '%s [ERR] %s\n' "$(TS)" "$*" | tee -a "$LOGFILE" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Нужен '$1'"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$TRACE_SH" = "1" ] && { PS4='+ $(TS) [SH] '; set -x; }

need uci; need curl
[ -x /etc/init.d/youtubeUnblock ] || die "youtubeUnblock не установлен (нет /etc/init.d/youtubeUnblock)"

log "== youtubeUnblock: умный тест (НЕ сохраняю настройки) =="
log "Лог: $LOGFILE"
dlog "ENV: DEBUG=$DEBUG CURL_VERBOSE=$CURL_VERBOSE TRACE_SH=$TRACE_SH RUNS=$RUNS TIMEOUT=$TIMEOUT CTO=$CTO ANCHOR=$ANCHOR CURL_IPVER=$CURL_IPVER"
dlog "curl: $(curl -V 2>/dev/null | head -n1)"

FW=iptables; have fw4 && FW=nft
dlog "Firewall stack: $FW"
dlog "Modules: $(lsmod 2>/dev/null | awk '/nfnetlink_queue|nft_queue/ {print $1}' | xargs -r echo)"

CUR_STRAT="$(uci -q get youtubeUnblock.youtubeUnblock.conf_strat || echo '')"
CUR_ARGS="$(uci -q get youtubeUnblock.youtubeUnblock.args || echo '')"
dlog "UCI before: conf_strat='${CUR_STRAT}' args='${CUR_ARGS}'"

# ======= CURL МЕРИЛКА =======
curl_try() {
  mode="$1"; shift
  url="$1"; shift || true
  vflag=""; [ "$CURL_VERBOSE" = "1" ] && vflag="-v"
  # shellcheck disable=SC2086
  curl $CURL_IPVER -m "$TIMEOUT" --connect-timeout "$CTO" -skL -o /dev/null $vflag \
       -w "mode=$mode code=%{http_code} rip=%{remote_ip} rport=%{remote_port} conn=%{time_connect} ssl=%{time_appconnect} ttfb=%{time_starttransfer} spd=%{speed_download} url=%{url_effective}\n" \
       "$@" "$url" 2>>"$LOGFILE"
}

curl_speed_one() {
  url="$1"
  out="$(curl_try "anchor(${ANCHOR})" "$url" --connect-to ::${ANCHOR}:443 -H 'Host: mirror.gcr.io')" || true
  dlog "$out"
  spd="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++){if($i~/^spd=/){sub("spd=","",$i);print $i}}}')"
  code="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++){if($i~/^code=/){sub("code=","",$i);print $i}}}')"
  if [ -n "$spd" ] && [ "$spd" != "0" ] && [ -n "$code" ] && [ "$code" != "000" ]; then echo "$spd"; return 0; fi

  out="$(curl_try 'fallback(www.google.com)' "$url" --connect-to ::www.google.com:443 -H 'Host: mirror.gcr.io')" || true
  dlog "$out"
  spd="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++){if($i~/^spd=/){sub("spd=","",$i);print $i}}}')"
  code="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++){if($i~/^code=/){sub("code=","",$i);print $i}}}')"
  if [ -n "$spd" ] && [ "$spd" != "0" ] && [ -n "$code" ] && [ "$code" != "000" ]; then echo "$spd"; return 0; fi

  out="$(curl_try 'direct' "$url")" || true
  dlog "$out"
  spd="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++){if($i~/^spd=/){sub("spd=","",$i);print $i}}}')"
  echo "${spd:-0}"
}

curl_speed() {
  url="$1"; n="$RUNS"; best=0; i=1
  while [ "$i" -le "$n" ]; do
    spd="$(curl_speed_one "$url")"
    case "$spd" in ''|*[!0-9.]* ) spd=0;; esac
    dlog "curl_speed attempt #$i -> $spd B/s"
    awk -v a="$spd" -v b="$best" 'BEGIN{exit !(a>b)}' && best="$spd" || true
    i=$((i+1))
  done
  echo "$best"
}

# ======= БЭКАП/ВОССТАНОВЛЕНИЕ UCI =======
apply_args() {
  args="$1"
  log "   [apply] args: $args"
  uci set youtubeUnblock.youtubeUnblock.conf_strat='args'
  uci set youtubeUnblock.youtubeUnblock.args="$args"
  uci commit youtubeUnblock
  /etc/init.d/youtubeUnblock restart >/dev/null 2>&1 || { dlog "restart FAILED"; return 1; }
  sleep "$SLEEP_RESTART"
  if [ "$FW" = "nft" ] && have nft; then
    nft -a list chain inet fw4 youtubeUnblock >/dev/null 2>&1 && dlog "nft chain present" || dlog "nft chain MISSING"
  fi
  return 0
}

ORIG_STRAT="$CUR_STRAT"; ORIG_ARGS="$CUR_ARGS"
restore_cfg() {
  log "   [restore] возвращаю исходный UCI…"
  if [ -n "$ORIG_STRAT" ]; then uci set youtubeUnblock.youtubeUnblock.conf_strat="$ORIG_STRAT"; else uci -q del youtubeUnblock.youtubeUnblock.conf_strat || true; fi
  if [ -n "$ORIG_ARGS" ]; then uci set youtubeUnblock.youtubeUnblock.args="$ORIG_ARGS"; else uci -q del youtubeUnblock.youtubeUnblock.args || true; fi
  uci commit youtubeUnblock
  /etc/init.d/youtubeUnblock restart >/dev/null 2>&1 || true
  dlog "UCI after restore: conf_strat='$(uci -q get youtubeUnblock.youtubeUnblock.conf_strat 2>/dev/null || echo)'; args='$(uci -q get youtubeUnblock.youtubeUnblock.args 2>/dev/null || echo)'"
}
cleanup(){ restore_cfg; log "Лог сохранён: $LOGFILE"; }
trap cleanup EXIT INT TERM

# ======= 0) БАЗА БЕЗ YU =======
log "-- Останавливаю youtubeUnblock для базового замера…"
/etc/init.d/youtubeUnblock stop >/dev/null 2>&1 || true
sleep 1

log "-- Префлайт: DNS и reachability"
dlog "nslookup google.com:"; nslookup google.com 2>&1 | sed 's/^/   /' | tee -a "$LOGFILE" >/dev/null || true
dlog "nslookup mirror.gcr.io:"; nslookup mirror.gcr.io 2>&1 | sed 's/^/   /' | tee -a "$LOGFILE" >/dev/null || true

SPD_REF="$(curl_speed "$TEST_REF")"
SPD_BASE="$(curl_speed "$TEST_YU")"
log "   Эталонная скорость (REF): ${SPD_REF} B/s"
log "   Базовая скорость (без YU): ${SPD_BASE} B/s"
case "$SPD_REF" in ''|0) die "Эталонный тест REF=0. Проверь маршрут/фаервол до Google (см. $LOGFILE).";; esac

OK_REF="$(awk -v b="$SPD_BASE" -v r="$SPD_REF" 'BEGIN{ if(r>0 && b/r>=0.9) print 1; else print 0 }')"
[ "$OK_REF" = "1" ] && { log "== Блокировок не видно (BASE ≈ REF). youtubeUnblock можно оставить по умолчанию."; exit 0; }

if [ "$DO_TR" = "1" ] && have traceroute; then
  log "-- traceroute до googlevideo.com (подсказка):"
  traceroute -w 1 -m 6 googlevideo.com 2>/dev/null | sed 's/^/   /' | tee -a "$LOGFILE" >/dev/null || true
fi

# ======= 1) КАНДИДАТЫ СТРАТЕГИЙ =======
# threads=1 (рекомендация автора), QUIC дропаем: --udp-mode=drop --udp-filter-quic=parse
# Добавлены наборы: base/gv/gvset, md5/tcp/pastseq/ttl, с и без UDP-drop.
CAND="/tmp/yu_candidates.txt"
cat >"$CAND" <<'EOF'
# base + UDP drop
base_md5_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=md5sum --frag-sni-faked=1
base_tcp_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=tcp_check
base_pst_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=pastseq
base_ttl5_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=ttl --faking-ttl=5
# googlevideo только
gv_md5_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --fbegin --sni-domains=googlevideo.com --faking-strategy=md5sum --frag-sni-faked=1 --fend
gv_tcp_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --fbegin --sni-domains=googlevideo.com --faking-strategy=tcp_check --fend
# расширенный набор доменов (влияет меньше, но иногда помогает)
gvset_md5_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --fbegin --sni-domains=googlevideo.com,youtubei.googleapis.com,yt3.ggpht.com --faking-strategy=md5sum --frag-sni-faked=1 --fend
gvset_tcp_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --fbegin --sni-domains=googlevideo.com,youtubei.googleapis.com,yt3.ggpht.com --faking-strategy=tcp_check --fend
# без UDP drop (на случай, если провайдер не фильтрует QUIC)
base_md5|--syslog --threads=1 --faking-strategy=md5sum --frag-sni-faked=1
gv_md5|--syslog --threads=1 --fbegin --sni-domains=googlevideo.com --faking-strategy=md5sum --frag-sni-faked=1 --fend
base_rand_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=randseq
EOF

# ======= 2) ГРУБЫЙ ПЕРЕБОР =======
BEST_NAME=""; BEST_ARGS=""; BEST_SPD=0
RANK="/tmp/yu_rank.txt"; : >"$RANK"

log "-- Перебор стратегий…"
while IFS='|' read -r NAME ARGS; do
  case "$NAME" in ''|\#*) continue;; esac
  log "   > $NAME"
  if ! apply_args "$ARGS"; then
    log "     ! не удалось запустить с args (пропуск)"
    continue
  fi
  SPD="$(curl_speed "$TEST_YU")"
  log "     скорость: ${SPD} B/s"
  echo "$SPD|$NAME|$ARGS" >>"$RANK"
  case "$SPD" in ''|*[!0-9.]* ) SPD=0;; esac
  awk -v a="$SPD" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_NAME="$NAME"; BEST_ARGS="$ARGS"; BEST_SPD="$SPD"; } || true
done <"$CAND"

[ -n "$BEST_NAME" ] || die "Не удалось подобрать стратегию (все кандидаты провалились?)"
IMPR="$(awk -v b="$BEST_SPD" -v s="$SPD_BASE" 'BEGIN{ if(s>0){printf "%.2f",(b-s)/s}else{print "inf"} }')"
log "-- Лидер после перебора: $BEST_NAME (${BEST_SPD} B/s), прирост к базе: ${IMPR}x"

# ======= 3) ЛОКАЛЬНЫЙ ДОТЮНИНГ =======
TUNE_ARGS="$BEST_ARGS"

# (a) SNI detection: parse/brute
for MODE in parse brute; do
  case "$TUNE_ARGS" in *"--sni-detection="* ) TRY="$(echo "$TUNE_ARGS" | sed -E 's/--sni-detection=[^ ]+//g') --sni-detection=$MODE" ;;
                           * ) TRY="$TUNE_ARGS --sni-detection=$MODE" ;;
  esac
  if apply_args "$TRY"; then
    SPD_TRY="$(curl_speed "$TEST_YU")"
    log "   тюнинг sni-detection=$MODE -> ${SPD_TRY} B/s"
    awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
  fi
done

# (b) TTL sweep 1..10, если выбрана ttl-стратегия ИЛИ в любом случае протестируем ttl как альтернативу
test_ttl_strategy() {
  base="$1"
  for T in 1 2 3 4 5 6 7 8 9 10; do
    TRY="$(printf "%s" "$base" | sed -E 's/--faking-ttl=[0-9]+//g') --faking-ttl=$T"
    if apply_args "$TRY"; then
      SPD_TRY="$(curl_speed "$TEST_YU")"
      log "   тюнинг TTL=$T -> ${SPD_TRY} B/s"
      awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
    fi
  done
}

case "$TUNE_ARGS" in *"--faking-strategy=ttl"*) test_ttl_strategy "$TUNE_ARGS" ;;
  *) # попробовать ttl как альтернативу к текущему лучшему набору флагов
     ALT="$(printf "%s" "$TUNE_ARGS" | sed -E 's/--faking-strategy=[^ ]+//g; s/--faking-ttl=[0-9]+//g') --faking-strategy=ttl --faking-ttl=5"
     apply_args "$ALT" && test_ttl_strategy "$ALT" || true
     ;;
esac

# (c) flip frag-sni-faked, если не было явного
case "$TUNE_ARGS" in *"--frag-sni-faked="* ) : ;; *)
  for F in 0 1; do
    TRY="$TUNE_ARGS --frag-sni-faked=$F"
    if apply_args "$TRY"; then
      SPD_TRY="$(curl_speed "$TEST_YU")"
      log "   тюнинг frag-sni-faked=$F -> ${SPD_TRY} B/s"
      awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
    fi
  done
esac

# (d) если внезапно без UDP drop — проверить с drop (и наоборот)
case "$TUNE_ARGS" in *"--udp-mode=drop"*) for MODE in without; do
    TRY="$(printf "%s" "$TUNE_ARGS" | sed -E 's/--udp-mode=drop//g; s/--udp-filter-quic=parse//g')"
    apply_args "$TRY" && SPD_TRY="$(curl_speed "$TEST_YU")" && log "   тюнинг udp-drop($MODE) -> ${SPD_TRY} B/s" && \
      awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
  done ;;
  *) for MODE in with; do
    TRY="$TUNE_ARGS --udp-mode=drop --udp-filter-quic=parse"
    apply_args "$TRY" && SPD_TRY="$(curl_speed "$TEST_YU")" && log "   тюнинг udp-drop($MODE) -> ${SPD_TRY} B/s" && \
      awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
  done ;;
esac

# (e) микро-тюнинг потоков (1/2)
for TH in 1 2; do
  TRY="$(printf "%s" "$TUNE_ARGS" | sed -E 's/--threads=[0-9]+//g') --threads=$TH"
  if apply_args "$TRY"; then
    SPD_TRY="$(curl_speed "$TEST_YU")"
    log "   тюнинг threads=$TH -> ${SPD_TRY} B/s"
    awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
  fi
done

# ======= 4) ИТОГ =======
log ""
log "== РЕЙТИНГ СТРАТЕГИЙ (по лучшему замеру, B/s) =="
if have sort; then sort -nr "/tmp/yu_rank.txt" | awk -F'|' '{printf "  - %s B/s  |  %s  |  %s\n",$1,$2,$3}';
else awk -F'|' '{printf "  - %s B/s  |  %s  |  %s\n",$1,$2,$3}' "/tmp/yu_rank.txt"; fi

log ""
log "== РЕКОМЕНДОВАННЫЕ args (НЕ применены) =="
echo "$TUNE_ARGS"
log "Ожидаемая скорость: ${BEST_SPD} B/s"
MBIT="$(awk -v b="$BEST_SPD" 'BEGIN{if(b>0) printf("%.2f", b*8/1000000); else print "0.00"}')"
log "Ожидаемая скорость: ~${MBIT} Мбит/с"

log ""
log "Чтобы применить (вручную):"
printf "%s\n" "uci set youtubeUnblock.youtubeUnblock.conf_strat='args'"
printf "%s\n" "uci set youtubeUnblock.youtubeUnblock.args='$(printf "%s" "$TUNE_ARGS" | sed "s/'/'\\\\''/g")'"
printf "%s\n" "uci commit youtubeUnblock"
/bin/echo "/etc/init.d/youtubeUnblock restart"

# cleanup() сработает в trap
exit 0
