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

FW=iptables; have fw4 && FW=nft
INC="/usr/share/nftables.d/ruleset-post/537-youtubeUnblock.nft"

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

# 2) Снять runtime-правила nft и удалить include
if [ "$FW" = "nft" ] && have nft; then
  log "Шаг 3: Удаляю runtime-правила nft (если есть)…"
  # Удалить правило из output (по сигнатуре mark 0x8000) — можем найти и удалить по handle
  HANDLE_IDS="$(nft -a list chain inet fw4 output 2>/dev/null | awk '/mark and 0x8000 == 0x8000/ {gsub(/;$/,"",$NF); print $NF}')"
  if [ -n "$HANDLE_IDS" ]; then
    for h in $HANDLE_IDS; do nft delete rule inet fw4 output handle "$h" 2>/dev/null || true; done
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

log "=== Удаление завершено ==="
