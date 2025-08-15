#!/bin/sh
# youtubeUnblock — умный тест стратегий (НЕ сохраняет конфиг)
# 1) База без YU -> 2) перебор стратегий -> 3) локальный дотюнинг -> 4) рейтинг + рекомендация
# Всё возвращает как было (trap EXIT). Сообщения — русские. Совместим с busybox sh.

set -eu

# ----- утилиты -----
need() { command -v "$1" >/dev/null 2>&1 || { echo "ОШИБКА: нужен $1"; exit 1; }; }
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '%s\n' "$*"; }
die()  { echo "ОШИБКА: $*" >&2; exit 1; }

need uci; need curl
[ -x /etc/init.d/youtubeUnblock ] || die "youtubeUnblock не установлен (нет /etc/init.d/youtubeUnblock)"

# Параметры теста (можно переопределить переменными окружения)
RUNS="${YU_TEST_RUNS:-2}"           # повторов для усреднения/максимума
TIMEOUT="${YU_TEST_TIMEOUT:-20}"    # таймаут curl, сек
DO_TR="${YU_TRACE:-1}"              # 1 = попытаться показать короткий traceroute
SLEEP_RESTART="${YU_SLEEP:-1}"      # пауза после рестарта сервиса

# URL/методика (канонический тест из README)
TEST_YU="https://test.googlevideo.com/v2/cimg/android/blobs/sha256:6fd8bdac3da660bde7bd0b6f2b6a46e1b686afb74b9a4614def32532b73f5eaa"
TEST_REF="https://mirror.gcr.io/v2/cimg/android/blobs/sha256:6fd8bdac3da660bde7bd0b6f2b6a46e1b686afb74b9a4614def32532b73f5eaa"

curl_speed_one() {
  curl -m "$TIMEOUT" -skLo /dev/null --connect-to ::google.com -H 'Host: mirror.gcr.io' \
    -w '%{speed_download}\n' "$1" 2>/dev/null || echo 0
}

curl_speed() {
  # возвращает ЛУЧШИЙ (max) из RUNS замеров, чтобы уменьшить влияние случайных просадок
  url="$1"; n="$RUNS"; best=0
  i=1
  while [ "$i" -le "$n" ]; do
    spd="$(curl_speed_one "$url")"
    case "$spd" in ''|*[!0-9.]* ) spd=0;; esac
    awk "BEGIN{exit !($spd>$best)}" && best="$spd" || true
    i=$((i+1))
  done
  echo "$best"
}

# ----- бэкап конфига и восстановление -----
ORIG_STRAT="$(uci -q get youtubeUnblock.youtubeUnblock.conf_strat || echo '')"
ORIG_ARGS="$(uci -q get youtubeUnblock.youtubeUnblock.args || echo '')"

apply_args() {
  uci set youtubeUnblock.youtubeUnblock.conf_strat='args'
  uci set youtubeUnblock.youtubeUnblock.args="$1"
  uci commit youtubeUnblock
  /etc/init.d/youtubeUnblock restart >/dev/null 2>&1 || return 1
  sleep "$SLEEP_RESTART"
  return 0
}

restore_cfg() {
  if [ -n "$ORIG_STRAT" ]; then
    uci set youtubeUnblock.youtubeUnblock.conf_strat="$ORIG_STRAT"
  else
    uci -q del youtubeUnblock.youtubeUnblock.conf_strat || true
  fi
  if [ -n "$ORIG_ARGS" ]; then
    uci set youtubeUnblock.youtubeUnblock.args="$ORIG_ARGS"
  else
    uci -q del youtubeUnblock.youtubeUnblock.args || true
  fi
  uci commit youtubeUnblock
  /etc/init.d/youtubeUnblock restart >/dev/null 2>&1 || true
}

cleanup() { restore_cfg; }
trap cleanup EXIT INT TERM

log "== youtubeUnblock: умный тест (НЕ сохраняю настройки) =="

# ----- 0) База без YU -----
log "-- Останавливаю youtubeUnblock для базового замера…"
/etc/init.d/youtubeUnblock stop >/dev/null 2>&1 || true
sleep 1

SPD_REF="$(curl_speed "$TEST_REF")"
SPD_BASE="$(curl_speed "$TEST_YU")"
log "   Эталонная скорость (REF): ${SPD_REF} B/s"
log "   Базовая скорость (без YU): ${SPD_BASE} B/s"
case "$SPD_REF" in ''|0) die "Эталонный тест REF=0. Проверь сеть/DNS.";; esac

# если YouTube без YU близко к эталону — блокировки нет, и YU не нужен
OK_REF="$(awk -v b="$SPD_BASE" -v r="$SPD_REF" 'BEGIN{ if(r>0 && b/r>=0.9) print 1; else print 0 }')"
if [ "$OK_REF" = "1" ]; then
  log "== Блокировок не видно (BASE ≈ REF). youtubeUnblock можно оставить по умолчанию."
  exit 0
fi

# Короткий traceroute (подсказка, не влияет на выбор стратегии)
if [ "$DO_TR" = "1" ] && have traceroute; then
  log "-- traceroute до googlevideo.com (подсказка):"
  traceroute -w 1 -m 6 googlevideo.com 2>/dev/null | sed 's/^/   /' || true
fi

# ----- 1) Набор разумных кандидатов -----
CAND="/tmp/yu_candidates.txt"
cat >"$CAND" <<'EOF'
base_md5_qd|--syslog --threads=1 --quic-drop --faking-strategy=md5sum --frag-sni-faked=1
base_tcp_qd|--syslog --threads=1 --quic-drop --faking-strategy=tcp_check
base_pst_qd|--syslog --threads=1 --quic-drop --faking-strategy=pastseq
base_ttl8_qd|--syslog --threads=1 --quic-drop --faking-strategy=ttl --faking-ttl=8
gv_md5_qd|--syslog --threads=1 --quic-drop --fbegin --sni-domains=googlevideo.com --faking-strategy=md5sum --frag-sni-faked=1 --fend
gv_tcp_qd|--syslog --threads=1 --quic-drop --fbegin --sni-domains=googlevideo.com --faking-strategy=tcp_check --fend
base_md5|--syslog --threads=1 --faking-strategy=md5sum --frag-sni-faked=1
gv_md5|--syslog --threads=1 --fbegin --sni-domains=googlevideo.com --faking-strategy=md5sum --frag-sni-faked=1 --fend
base_rand_qd|--syslog --threads=1 --quic-drop --faking-strategy=randseq
EOF

# ----- 2) Грубый перебор -----
BEST_NAME=""; BEST_ARGS=""; BEST_SPD=0
RANK="/tmp/yu_rank.txt"; : >"$RANK"

log "-- Перебор стратегий…"
while IFS='|' read -r NAME ARGS; do
  [ -n "$NAME" ] || continue
  log "   > $NAME"
  if ! apply_args "$ARGS"; then
    log "     ! не удалось запустить с args (пропуск)"
    continue
  fi
  SPD="$(curl_speed "$TEST_YU")"
  log "     скорость: ${SPD} B/s"
  echo "$SPD|$NAME|$ARGS" >>"$RANK"
  case "$SPD" in ''|*[!0-9.]* ) SPD=0;; esac
  awk "BEGIN{exit !($SPD>$BEST_SPD)}" && { BEST_NAME="$NAME"; BEST_ARGS="$ARGS"; BEST_SPD="$SPD"; } || true
done <"$CAND"

[ -n "$BEST_NAME" ] || die "Не удалось подобрать стратегию (все кандидаты провалились?)"
IMPR="$(awk -v b="$BEST_SPD" -v s="$SPD_BASE" 'BEGIN{ if(s>0) printf "%.2f", (b-s)/s; else print "inf" }')"
log "-- Лидер после перебора: $BEST_NAME (${BEST_SPD} B/s), прирост к базе: ${IMPR}x"

# ----- 3) Локальный дотюнинг победителя -----
TUNE_ARGS="$BEST_ARGS"

# a) sni-detection: parse vs brute
for MODE in parse brute; do
  TRY="$TUNE_ARGS --sni-detection=$MODE"
  if apply_args "$TRY"; then
    SPD_TRY="$(curl_speed "$TEST_YU")"
    log "   тюнинг sni-detection=$MODE -> ${SPD_TRY} B/s"
    awk "BEGIN{exit !($SPD_TRY>$BEST_SPD)}" && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
  fi
done

# b) если ttl — подбор TTL
case "$TUNE_ARGS" in *"--faking-strategy=ttl"*)
  for T in 4 8 12 16; do
    TRY="$(echo "$TUNE_ARGS" | sed -E 's/--faking-ttl=[0-9]+//g') --faking-ttl=$T"
    if apply_args "$TRY"; then
      SPD_TRY="$(curl_speed "$TEST_YU")"
      log "   тюнинг TTL=$T -> ${SPD_TRY} B/s"
      awk "BEGIN{exit !($SPD_TRY>$BEST_SPD)}" && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
    fi
  done
;; esac

# c) flip frag-sni-faked (если ключа не было)
case "$TUNE_ARGS" in *"--frag-sni-faked="* ) : ;; *)
  for F in 0 1; do
    TRY="$TUNE_ARGS --frag-sni-faked=$F"
    if apply_args "$TRY"; then
      SPD_TRY="$(curl_speed "$TEST_YU")"
      log "   тюнинг frag-sni-faked=$F -> ${SPD_TRY} B/s"
      awk "BEGIN{exit !($SPD_TRY>$BEST_SPD)}" && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
    fi
  done
esac

# d) финальная проверка с/без quic-drop, если не было указано
case "$TUNE_ARGS" in *"--quic-drop"*) : ;; *)
  for Q in with without; do
    if [ "$Q" = "with" ]; then TRY="$TUNE_ARGS --quic-drop"; else TRY="$TUNE_ARGS"; fi
    if apply_args "$TRY"; then
      SPD_TRY="$(curl_speed "$TEST_YU")"
      log "   тюнинг quic-drop($Q) -> ${SPD_TRY} B/s"
      awk "BEGIN{exit !($SPD_TRY>$BEST_SPD)}" && { BEST_SPD="$SPD_TRY"; TUNE_ARGS="$TRY"; } || true
    fi
  done
esac

# ----- 4) Итог: рейтинг и рекомендация (ничего не сохраняем) -----
log ""
log "== РЕЙТИНГ СТРАТЕГИЙ (по лучшему замеру, B/s) =="
# сортировка по скорости убыв.
if have sort; then
  sort -t'|' -k1,1nr "$RANK" | awk -F'|' '{printf "  - %s B/s  |  %s  |  %s\n",$1,$2,$3}'
else
  # без sort — просто как есть
  awk -F'|' '{printf "  - %s B/s  |  %s  |  %s\n",$1,$2,$3}' "$RANK"
fi

log ""
log "== РЕКОМЕНДОВАННЫЕ args (НЕ применены) =="
echo "$TUNE_ARGS"
log "Ожидаемая скорость: ${BEST_SPD} B/s"
log ""
log "Чтобы применить (вручную):"
printf "%s\n" "uci set youtubeUnblock.youtubeUnblock.conf_strat='args'"
printf "%s\n" "uci set youtubeUnblock.youtubeUnblock.args='$(printf "%s" "$TUNE_ARGS" | sed "s/'/'\\\\''/g")'"
printf "%s\n" "uci commit youtubeUnblock"
/bin/echo "/etc/init.d/youtubeUnblock restart"

exit 0
