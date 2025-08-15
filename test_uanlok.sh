#!/bin/sh
# youtubeUnblock — умный тест стратегий (НЕ сохраняет конфиг)
# Фокус: стабильная стратегия для 4K. Перебор + тюнинг + ре-валидация.
set -eu

# ===== ПАРАМЕТРЫ (env) =====
DEBUG="${YU_DEBUG:-1}"
CURL_VERBOSE="${YU_CURL_VERBOSE:-0}"
TRACE_SH="${YU_TRACE_SH:-0}"
RUNS="${YU_TEST_RUNS:-3}"
TIMEOUT="${YU_TEST_TIMEOUT:-20}"
CTO="${YU_CONNECT_TIMEOUT:-5}"
DO_TR="${YU_TRACE:-1}"
SLEEP_RESTART="${YU_SLEEP:-1}"
ANCHOR="${YU_ANCHOR:-google.com}"
CURL_IPVER="${YU_IPVER:--4}"
AGG="${YU_AGG:-median}"            # median|p90|max
RECHECK_TOP="${YU_RECHECK_TOP:-3}"
THREADS_LIST="${YU_THREADS:-1 2 3}"
TTL_RANGE="${YU_TTL_RANGE:-1 2 3 4 5 6 7 8 9 10}"

# Эталон/YouTube тест
TEST_YU="https://test.googlevideo.com/v2/cimg/android/blobs/sha256:6fd8bdac3da660bde7bd0b6f2b6a46e1b686afb74b9a4614def32532b73f5eaa"
TEST_REF="https://mirror.gcr.io/v2/cimg/android/blobs/sha256:6fd8bdac3da660bde7bd0b6f2b6a46e1b686afb74b9a4614def32532b73f5eaa"

# ===== ЛОГИ/УТИЛЫ =====
TS(){ date '+%Y-%m-%d %H:%M:%S'; }
LOGFILE="/tmp/yu_tester_$(date +%s).log"
log(){ printf '%s %s\n' "$(TS)" "$*" | tee -a "$LOGFILE"; }
dlog(){ [ "$DEBUG" = "1" ] && printf '%s [DBG] %s\n' "$(TS)" "$*" | tee -a "$LOGFILE" >/dev/null; true; }
die(){ printf '%s [ERR] %s\n' "$(TS)" "$*" | tee -a "$LOGFILE" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Нужен '$1'"; }
have(){ command -v "$1" >/dev/null 2>&1; }
[ "$TRACE_SH" = "1" ] && { PS4='+ $(TS) [SH] '; set -x; }

need uci; need curl
[ -x /etc/init.d/youtubeUnblock ] || die "youtubeUnblock не установлен (/etc/init.d/youtubeUnblock нет)"

log "== youtubeUnblock: умный тест (НЕ сохраняю настройки) =="
log "Лог: $LOGFILE"
dlog "ENV: RUNS=$RUNS TIMEOUT=$TIMEOUT CTO=$CTO AGG=$AGG RECHECK_TOP=$RECHECK_TOP THREADS=[$THREADS_LIST] TTL_RANGE=[$TTL_RANGE]"
dlog "curl: $(curl -V 2>/dev/null | head -n1)"

FW=iptables; command -v fw4 >/dev/null 2>&1 && FW=nft || true
dlog "Firewall: $FW"
dlog "Loaded modules: $(lsmod 2>/dev/null | awk '/nfnetlink_queue|nft_queue/ {print $1}' | xargs -r echo)"

CUR_STRAT="$(uci -q get youtubeUnblock.youtubeUnblock.conf_strat || echo '')"
CUR_ARGS="$(uci -q get youtubeUnblock.youtubeUnblock.args || echo '')"
dlog "UCI before: conf_strat='${CUR_STRAT}' args='${CUR_ARGS}'"

# ===== CURL с метриками =====
curl_try(){
  mode="$1"; shift; url="$1"; shift || true
  v=""; [ "$CURL_VERBOSE" = "1" ] && v="-v"
  # shellcheck disable=SC2086
  curl $CURL_IPVER -m "$TIMEOUT" --connect-timeout "$CTO" -skL -o /dev/null $v \
    -w "mode=$mode code=%{http_code} rip=%{remote_ip} rport=%{remote_port} conn=%{time_connect} ssl=%{time_appconnect} ttfb=%{time_starttransfer} spd=%{speed_download} url=%{url_effective}\n" \
    "$@" "$url" 2>>"$LOGFILE"
}
one_speed(){
  url="$1"
  out="$(curl_try "anchor(${ANCHOR})" "$url" --connect-to ::${ANCHOR}:443 -H 'Host: mirror.gcr.io')" || true
  dlog "$out"
  sp="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^spd=/){sub("spd=","",$i);print $i}}')"
  code="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^code=/){sub("code=","",$i);print $i}}')"
  if [ -n "$sp" ] && [ "$sp" != "0" ] && [ "$code" != "000" ]; then echo "$sp"; return 0; fi
  out="$(curl_try 'fallback(www.google.com)' "$url" --connect-to ::www.google.com:443 -H 'Host: mirror.gcr.io')" || true
  dlog "$out"
  sp="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^spd=/){sub("spd=","",$i);print $i}}')"
  code="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^code=/){sub("code=","",$i);print $i}}')"
  if [ -n "$sp" ] && [ "$sp" != "0" ] && [ "$code" != "000" ]; then echo "$sp"; return 0; fi
  out="$(curl_try 'direct' "$url")" || true
  dlog "$out"
  sp="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^spd=/){sub("spd=","",$i);print $i}}')"
  echo "${sp:-0}"
}
agg(){
  mode="$1"; shift
  case "$mode" in
    median)
      if have sort; then
        sort -n | awk 'NF{a[NR]=$1} END{ if(NR==0){print 0;exit} m=int((NR+1)/2); if(NR%2){print a[m]} else {printf "%.0f\n",(a[m]+a[m+1])/2} }'
      else awk 'END{print 0}'; fi ;;
    p90)
      if have sort; then
        sort -n | awk 'NF{a[NR]=$1} END{ if(NR==0){print 0;exit} idx=int(0.9*(NR-1))+1; print a[idx] }'
      else awk 'END{print 0}'; fi ;;
    max|*) awk 'BEGIN{m=0} {if($1>m)m=$1} END{print m}';;
  esac
}
measure(){
  url="$1"; tmp="/tmp/yu_speeds_$$.txt"; : >"$tmp"
  i=1; while [ "$i" -le "$RUNS" ]; do
    s="$(one_speed "$url")"; case "$s" in ''|*[!0-9.]* ) s=0;; esac
    dlog "speed[$i]=$s B/s"; echo "$s" >>"$tmp"; i=$((i+1))
  done
  res="$(cat "$tmp" | agg "$AGG")"; rm -f "$tmp"; echo "$res"
}

# ===== UCI =====
norm_args(){ printf "%s" "$1" | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//'; }
apply_args(){
  raw="$1"; args="$(norm_args "$raw")"
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
restore_cfg(){
  log "   [restore] возвращаю исходный UCI…"
  if [ -n "$ORIG_STRAT" ]; then uci set youtubeUnblock.youtubeUnblock.conf_strat="$ORIG_STRAT"; else uci -q del youtubeUnblock.youtubeUnblock.conf_strat || true; fi
  if [ -n "$ORIG_ARGS"  ]; then uci set youtubeUnblock.youtubeUnblock.args="$ORIG_ARGS"; else uci -q del youtubeUnblock.youtubeUnblock.args || true; fi
  uci commit youtubeUnblock
  /etc/init.d/youtubeUnblock restart >/dev/null 2>&1 || true
  dlog "UCI after restore: conf_strat='$(uci -q get youtubeUnblock.youtubeUnblock.conf_strat 2>/dev/null || echo)'; args='$(uci -q get youtubeUnblock.youtubeUnblock.args 2>/dev/null || echo)'"
}
cleanup(){ restore_cfg; log "Лог сохранён: $LOGFILE"; }
trap cleanup EXIT INT TERM

# ===== 0) База без YU =====
log "-- Останавливаю youtubeUnblock для базового замера…"
/etc/init.d/youtubeUnblock stop >/dev/null 2>&1 || true
sleep 1
log "-- Префлайт: DNS и reachability"
dlog "nslookup google.com:"; nslookup google.com 2>&1 | sed 's/^/   /' | tee -a "$LOGFILE" >/dev/null || true
dlog "nslookup mirror.gcr.io:"; nslookup mirror.gcr.io 2>&1 | sed 's/^/   /' | tee -a "$LOGFILE" >/dev/null || true

SPD_REF="$(measure "$TEST_REF")"
SPD_BASE="$(measure "$TEST_YU")"
log "   Эталонная скорость (REF): ${SPD_REF} B/s"
log "   Базовая скорость (без YU): ${SPD_BASE} B/s"
case "$SPD_REF" in ''|0) die "Эталонный тест REF=0. Проверь маршрут/фаервол до Google (см. $LOGFILE).";; esac
OK_REF="$(awk -v b="$SPD_BASE" -v r="$SPD_REF" 'BEGIN{ if(r>0 && b/r>=0.9) print 1; else print 0 }')"
[ "$OK_REF" = "1" ] && { log "== Блокировок не видно (BASE ≈ REF). youtubeUnblock можно оставить по умолчанию."; exit 0; }
if [ "$DO_TR" = "1" ] && have traceroute; then
  log "-- traceroute до googlevideo.com (подсказка):"
  traceroute -w 1 -m 6 googlevideo.com 2>/dev/null | sed 's/^/   /' | tee -a "$LOGFILE" >/dev/null || true
fi

# ===== 1) Кандидаты =====
CAND="/tmp/yu_candidates.txt"
cat >"$CAND" <<'EOF'
# base + UDP drop
base_md5_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=md5sum --frag-sni-faked=1
base_tcp_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=tcp_check
base_pst_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=pastseq
base_ttl5_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=ttl --faking-ttl=5
# только googlevideo
gv_md5_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --fbegin --sni-domains=googlevideo.com --faking-strategy=md5sum --frag-sni-faked=1 --fend
gv_tcp_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --fbegin --sni-domains=googlevideo.com --faking-strategy=tcp_check --fend
# расширенный набор доменов (иногда помогает)
gvset_md5_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --fbegin --sni-domains=googlevideo.com,youtubei.googleapis.com,yt3.ggpht.com,ytimg.com --faking-strategy=md5sum --frag-sni-faked=1 --fend
gvset_tcp_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --fbegin --sni-domains=googlevideo.com,youtubei.googleapis.com,yt3.ggpht.com,ytimg.com --faking-strategy=tcp_check --fend
# без UDP drop (если QUIC не режут)
base_md5|--syslog --threads=1 --faking-strategy=md5sum --frag-sni-faked=1
gv_md5|--syslog --threads=1 --fbegin --sni-domains=googlevideo.com --faking-strategy=md5sum --frag-sni-faked=1 --fend
base_rand_udrop|--syslog --threads=1 --udp-mode=drop --udp-filter-quic=parse --faking-strategy=randseq
EOF

BEST_NAME=""; BEST_ARGS=""; BEST_SPD=0
RANK="/tmp/yu_rank.txt"; : >"$RANK"

log "-- Перебор стратегий…"
while IFS='|' read -r NAME ARGS; do
  case "$NAME" in ''|\#*) continue;; esac
  log "   > $NAME"
  if ! apply_args "$ARGS"; then log "     ! не запустилось (пропуск)"; continue; fi
  SPD="$(measure "$TEST_YU")"
  log "     скорость[$AGG]: ${SPD} B/s"
  echo "$SPD|$NAME|$(norm_args "$ARGS")" >>"$RANK"
  case "$SPD" in ''|*[!0-9.]* ) SPD=0;; esac
  awk -v a="$SPD" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_NAME="$NAME"; BEST_ARGS="$(norm_args "$ARGS")"; BEST_SPD="$SPD"; } || true
done <"$CAND"

[ -n "$BEST_NAME" ] || die "Не удалось подобрать стратегию"
IMPR="$(awk -v b="$BEST_SPD" -v s="$SPD_BASE" 'BEGIN{ if(s>0){printf "%.2f",(b-s)/s}else{print "inf"} }')"
log "-- Лидер после перебора: $BEST_NAME (${BEST_SPD} B/s), прирост к базе: ${IMPR}x"

# ===== 2) Локальный дотюнинг =====
TUNE_ARGS="$BEST_ARGS"

# (a) SNI detection parse/brute
for MODE in parse brute; do
  case "$TUNE_ARGS" in *"--sni-detection="*) TRY="$(echo "$TUNE_ARGS" | sed -E 's/--sni-detection=[^ ]+//g') --sni-detection=$MODE";;
                      *) TRY="$TUNE_ARGS --sni-detection=$MODE";;
  esac
  if apply_args "$TRY"; then
    SPD_TRY="$(measure "$TEST_YU")"
    log "   sni-detection=$MODE -> ${SPD_TRY} B/s"
    echo "$SPD_TRY|tune_sni=$MODE|$(norm_args "$TRY")" >>"$RANK"
    awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$(norm_args "$TRY")"; } || true
  fi
done

# (b) TTL sweep 1..10 + альтернатива ttl
test_ttl_strategy(){
  base="$1"
  for T in $TTL_RANGE; do
    TRY="$(printf "%s" "$base" | sed -E 's/--faking-ttl=[0-9]+//g') --faking-ttl=$T"
    if apply_args "$TRY"; then
      SPD_TRY="$(measure "$TEST_YU")"
      log "   TTL=$T -> ${SPD_TRY} B/s"
      echo "$SPD_TRY|tune_ttl=$T|$(norm_args "$TRY")" >>"$RANK"
      awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$(norm_args "$TRY")"; } || true
    fi
  done
}
case "$TUNE_ARGS" in *"--faking-strategy=ttl"*) test_ttl_strategy "$TUNE_ARGS" ;;
  *) ALT="$(printf "%s" "$TUNE_ARGS" | sed -E 's/--faking-strategy=[^ ]+//g; s/--faking-ttl=[0-9]+//g') --faking-strategy=ttl --faking-ttl=5"
     if apply_args "$ALT"; then
       SPD_ALT="$(measure "$TEST_YU")"
       log "   alt ttl start -> ${SPD_ALT} B/s"
       echo "$SPD_ALT|alt_ttl_start|$(norm_args "$ALT")" >>"$RANK"
       awk -v a="$SPD_ALT" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_ALT"; TUNE_ARGS="$(norm_args "$ALT")"; } || true
       test_ttl_strategy "$TUNE_ARGS --faking-strategy=ttl"
     fi ;;
esac

# (c) frag-sni-faked toggle
case "$TUNE_ARGS" in *"--frag-sni-faked="* ) : ;; * )
  for F in 0 1; do
    TRY="$(norm_args "$TUNE_ARGS --frag-sni-faked=$F")"
    if apply_args "$TRY"; then
      SPD_TRY="$(measure "$TEST_YU")"
      log "   frag-sni-faked=$F -> ${SPD_TRY} B/s"
      echo "$SPD_TRY|tune_frag=$F|$TRY" >>"$RANK"
      awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
    fi
  done
esac

# (d) UDP drop toggle
case "$TUNE_ARGS" in *"--udp-mode=drop"*)
  TRY="$(printf "%s" "$TUNE_ARGS" | sed -E 's/--udp-mode=drop//g; s/--udp-filter-quic=[^ ]+//g')"
  if apply_args "$TRY"; then
    SPD_TRY="$(measure "$TEST_YU")"
    log "   udp-drop=without -> ${SPD_TRY} B/s"
    echo "$SPD_TRY|tune_udp=without|$(norm_args "$TRY")" >>"$RANK"
    awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$(norm_args "$TRY")"; } || true
  fi
  ;;
  *)
  TRY="$(norm_args "$TUNE_ARGS --udp-mode=drop --udp-filter-quic=parse")"
  if apply_args "$TRY"; then
    SPD_TRY="$(measure "$TEST_YU")"
    log "   udp-drop=with(parse) -> ${SPD_TRY} B/s"
    echo "$SPD_TRY|tune_udp=with_parse|$TRY" >>"$RANK"
    awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
  fi
  ;;
esac
# (d2) udp-filter-quic parse|brute
for UF in parse brute; do
  case "$TUNE_ARGS" in *"--udp-mode=drop"*)
    TRY="$(printf "%s" "$TUNE_ARGS" | sed -E 's/--udp-filter-quic=[^ ]+//g') --udp-filter-quic=$UF"
    TRY="$(norm_args "$TRY")"
    if apply_args "$TRY"; then
      SPD_TRY="$(measure "$TEST_YU")"
      log "   udp-filter-quic=$UF -> ${SPD_TRY} B/s"
      echo "$SPD_TRY|tune_udpfilter=$UF|$TRY" >>"$RANK"
      awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
    fi
  fi
done

# (e) threads sweep
for TH in $THREADS_LIST; do
  TRY="$(printf "%s" "$TUNE_ARGS" | sed -E 's/--threads=[0-9]+//g') --threads=$TH"
  TRY="$(norm_args "$TRY")"
  if apply_args "$TRY"; then
    SPD_TRY="$(measure "$TEST_YU")"
    log "   threads=$TH -> ${SPD_TRY} B/s"
    echo "$SPD_TRY|tune_threads=$TH|$TRY" >>"$RANK"
    awk -v a="$SPD_TRY" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
  fi
done

# ===== 3) Повторная валидация Top-N (без bash-процесса) =====
if have sort; then
  log "-- Повторная валидация лучших $RECHECK_TOP…"
  sort -nr "$RANK" | head -n "$RECHECK_TOP" | while IFS='|' read -r _ _ ARGS; do
    ARGS="$(norm_args "$ARGS")"
    log "   [recheck] $ARGS"
    if apply_args "$ARGS"; then
      SPD_RE="$(measure "$TEST_YU")"
      log "     повторная скорость[$AGG]: ${SPD_RE} B/s"
      echo "$SPD_RE|recheck|$ARGS" >>"$RANK"
      awk -v a="$SPD_RE" -v b="$BEST_SPD" 'BEGIN{exit !(a>b)}' && { BEST_SPD="$SPD_RE"; TUNE_ARGS="$ARGS"; } || true
    fi
  done
fi

# ===== 4) Итог =====
log ""
log "== РЕЙТИНГ (агрегатор: $AGG) =="
if have sort; then sort -nr "$RANK" | awk -F'|' '{printf "  - %s B/s  |  %s  |  %s\n",$1,$2,$3}'; else cat "$RANK"; fi

log ""
log "== РЕКОМЕНДОВАННЫЕ args (НЕ применены) =="
echo "$TUNE_ARGS"
log "Ожидаемая скорость: ${BEST_SPD} B/s"
MBIT="$(awk -v b="$BEST_SPD" 'BEGIN{if(b>0) printf("%.2f", b*8/1000000); else print "0.00"}')"
log "Ожидаемая скорость: ~${MBIT} Мбит/с"

# Информативно: тянет ли 4K?
FOURK30_OK="$(awk -v m="$MBIT" 'BEGIN{exit !(m>=35)}')"; FOURK60_OK="$(awk -v m="$MBIT" 'BEGIN{exit !(m>=55)}')"
[ -z "$FOURK30_OK" ] && log "✔ 4K30 должно быть стабильно" || log "⚠ 4K30 на грани — попробуй YU_TEST_RUNS=4..6"
[ -z "$FOURK60_OK" ] && log "✔ 4K60 должно быть стабильно" || log "⚠ 4K60 может дропать — посмотри лидеров в рейтинге"

log ""
log "Чтобы применить (вручную):"
printf "%s\n" "uci set youtubeUnblock.youtubeUnblock.conf_strat='args'"
printf "%s\n" "uci set youtubeUnblock.youtubeUnblock.args='$(printf "%s" "$TUNE_ARGS" | sed "s/'/'\\\\''/g")'"
printf "%s\n" "uci commit youtubeUnblock"
/bin/echo "/etc/init.d/youtubeUnblock restart"
exit 0
