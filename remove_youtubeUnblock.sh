#!/bin/sh
# Удаление youtubeUnblock и связанного окружения на OpenWrt (fw4/nft)
# Безопасно для повторных запусков. Сообщения — на русском.
# Опции окружения:
#   REMOVE_KMODS=1     — попытаться удалить kmod-nft-queue, kmod-nfnetlink-queue, kmod-nf-conntrack
#   FIX_MINIUPNPD=1    — починить include miniupnpd под fw4 (убрать legacy-поля)

set -eu

die() { echo "ОШИБКА: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
log() { printf '%s\n' "$*"; }

FW=iptables
have fw4 && FW=nft

INC="/usr/share/nftables.d/ruleset-post/537-youtubeUnblock.nft"

# Считываем mark/queue_num из UCI до того, как, возможно, удалим конфиг
YT_MARK_HEX="0x8000"
YT_QNUM="537"

if have uci; then
  M="$(uci -q get youtubeUnblock.youtubeUnblock.packet_mark || echo '')"
  Q="$(uci -q get youtubeUnblock.youtubeUnblock.queue_num || echo '')"

  if [ -n "$M" ]; then
    # packet_mark в UCI обычно в десятичном виде
    YT_MARK_HEX="$(printf '0x%X' "$M" 2>/dev/null || echo '0x8000')"
  fi

  [ -n "$Q" ] && YT_QNUM="$Q"
fi

log "=== Начало удаления youtubeUnblock ==="
log "[детектировано] firewall: $FW"

# 1) Остановить сервис и выключить автозапуск (если есть init-скрипт)
if [ -x /etc/init.d/youtubeUnblock ]; then
  log "Шаг 1: Останавливаю службу youtubeUnblock…"
  /etc/init.d/youtubeUnblock stop >/dev/null 2>&1 || true
  log "Шаг 2: Отключаю автозапуск youtubeUnblock…"
  /etc/init.d/youtubeUnblock disable >/dev/null 2>&1 || true
else
  log "Примечание: init-скрипт youtubeUnblock не найден — пропускаю остановку/disable"
fi

# 1.1) Чистим UCI-конфиг
if have uci; then
  if uci -q show youtubeUnblock >/dev/null 2>&1; then
    log "Шаг 2a: Удаляю UCI-конфиг youtubeUnblock…"
    uci -q delete youtubeUnblock || true
    uci commit youtubeUnblock >/dev/null 2>&1 || true
  else
    log "Примечание: UCI-конфиг youtubeUnblock уже отсутствует"
  fi
fi

# На всякий случай добиваем сам файл, если он остался пустым
[ -f /etc/config/youtubeUnblock ] && rm -f /etc/config/youtubeUnblock || true

# 2) Снять runtime-правила nft и удалить include
if [ "$FW" = "nft" ] && have nft; then
  log "Шаг 3: Удаляю runtime-правила nft (если есть)…"

  # Ищем правила в output, которые принимают пакеты с нашим mark/очередью
  HANDLE_IDS="$(nft -a list chain inet fw4 output 2>/dev/null | \
    awk -v m="$YT_MARK_HEX" -v q="$YT_QNUM" '
      /mark and/ || /queue num/ {
        if ((m != "" && index($0, m)) || (q != "" && index($0, "queue num " q))) {
          gsub(/;$/,"",$NF); print $NF
        }
      }')"

  if [ -n "${HANDLE_IDS:-}" ]; then
    for h in $HANDLE_IDS; do
      nft delete rule inet fw4 output handle "$h" 2>/dev/null || true
    done
  fi

  # Стереть и удалить цепочку youtubeUnblock, если существует
  if nft list chain inet fw4 youtubeUnblock >/dev/null 2>&1; then
    nft flush chain inet fw4 youtubeUnblock 2>/dev/null || true
    nft delete chain inet fw4 youtubeUnblock 2>/dev/null || true
  fi

  log "Шаг 4: Удаляю include-файл правил (если есть)…"
  if [ -f "$INC" ]; then
    rm -f "$INC" || die "Не удалось удалить $INC"
  fi

  log "Шаг 5: Перезагружаю firewall (fw4)…"
  /etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true
else
  log "Примечание: fw4/nft не обнаружен или команда 'nft' недоступна — пропускаю снятие правил"
fi

# 3) Удалить пакеты (LuCI — это веб-интерфейс, у него нет init.d сервиса)
log "Шаг 6: Удаляю пакеты…"
opkg remove luci-app-youtubeUnblock >/dev/null 2>&1 || log "  Примечание: luci-app-youtubeUnblock уже отсутствует"
opkg remove youtubeUnblock          >/dev/null 2>&1 || log "  Примечание: youtubeUnblock уже отсутствует"

# 3.1) Добиваем возможные хвосты от init-скрипта
if [ ! -e /usr/bin/youtubeUnblock ] && [ -f /etc/init.d/youtubeUnblock ]; then
  log "Шаг 6a: Удаляю оставшийся init-скрипт /etc/init.d/youtubeUnblock…"
  rm -f /etc/init.d/youtubeUnblock || true
fi

# symlink'и в /etc/rc.d
for f in /etc/rc.d/*youtubeUnblock*; do
  [ -e "$f" ] || continue
  rm -f "$f" || true
done

# 4) (опционально) удалить kmod’ы
if [ "${REMOVE_KMODS:-0}" = "1" ]; then
  log "Шаг 7 (необязательно): Пытаюсь удалить kmod-пакеты…"
  opkg remove kmod-nft-queue kmod-nfnetlink-queue kmod-nf-conntrack >/dev/null 2>&1 || \
    log "  Примечание: kmod-пакеты заняты зависимостями или уже удалены"
fi

# 5) (опционально) починка miniupnpd include под fw4
if [ "${FIX_MINIUPNPD:-0}" = "1" ] && have uci; then
  log "Шаг 8 (необязательно): Исправляю include miniupnpd под fw4…"
  uci -q set firewall.miniupnpd=include
  uci -q set firewall.miniupnpd.type='script'
  uci -q set firewall.miniupnpd.path='/usr/share/miniupnpd/firewall.include'
  uci -q del firewall.miniupnpd.family || true
  uci -q del firewall.miniupnpd.reload || true
  uci commit firewall
  /etc/init.d/firewall reload >/dev/null 2>&1 || true
fi

# 6) Быстрые проверки
log "Шаг 9: Проверки…"
if [ "$FW" = "nft" ] && have nft; then
  if nft list chain inet fw4 youtubeUnblock >/dev/null 2>&1; then
    log "  ВНИМАНИЕ: цепочка 'inet fw4 youtubeUnblock' всё ещё существует"
  else
    log "  OK: цепочка 'inet fw4 youtubeUnblock' отсутствует"
  fi
fi

if opkg list-installed | grep -q '^youtubeUnblock'; then
  log "  ВНИМАНИЕ: пакет youtubeUnblock всё ещё установлен"
else
  log "  OK: пакет youtubeUnblock удалён"
fi

if opkg list-installed | grep -q '^luci-app-youtubeUnblock'; then
  log "  ВНИМАНИЕ: пакет luci-app-youtubeUnblock всё ещё установлен"
else
  log "  OK: пакет luci-app-youtubeUnblock удалён"
fi

if [ -f /etc/config/youtubeUnblock ]; then
  log "  ВНИМАНИЕ: /etc/config/youtubeUnblock всё ещё существует"
else
  log "  OK: конфиг /etc/config/youtubeUnblock удалён"
fi

log "=== Удаление завершено ==="
