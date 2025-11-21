#!/bin/sh
# disable_ipv6_v2.3.sh — аккуратное и идемпотентное отключение IPv6 на OpenWrt (с ребутом)

# Гарантируем наличие /sbin и /usr/sbin при запуске через "curl ... | sh"
PATH="/sbin:/usr/sbin:/bin:/usr/bin:${PATH:-}"

set -eu

log()  { echo "[IPv6-OFF] $*"; }
ok()   { echo "  ✔ $*"; }
warn() { echo "  ! $*"; }
die()  { echo "  ✖ $*"; exit 1; }

usage() {
  cat <<'EOF'
Использование: disable_ipv6.sh [--no-reboot] [--no-backup] [--help]

--no-reboot    Не выполнять автоматический ребут (можно также SKIP_REBOOT=1)
--no-backup    Пропустить создание бэкапов /etc/config/{network,dhcp} (SKIP_BACKUP=1)
-h, --help     Показать эту справку
EOF
}

[ "$(id -u)" -eq 0 ] || die "Запусти от root"
[ -x "$(command -v uci 2>/dev/null)" ] || die "uci не найден в PATH — это точно OpenWrt?"

SKIP_REBOOT="${SKIP_REBOOT:-0}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-reboot) SKIP_REBOOT=1 ;;
    --no-backup) SKIP_BACKUP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный флаг: $1" ;;
  esac
  shift
done

STAMP="$(date +%Y%m%d-%H%M%S)"
if [ "$SKIP_BACKUP" = "1" ]; then
  warn "Бэкапы пропущены (SKIP_BACKUP=1 или --no-backup)"
else
  log "Создаём бэкапы /etc/config/network и /etc/config/dhcp"
  cp /etc/config/network "/etc/config/network.bak.$STAMP" 2>/dev/null || true
  cp /etc/config/dhcp     "/etc/config/dhcp.bak.$STAMP"     2>/dev/null || true
fi

log "1) Отключаем IPv6/делегирование на всех интерфейсах, кроме loopback; чистим ip6assign/ip6hint"
IFACES="$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)=interface.*/\1/p" || true)"
for ifc in $IFACES; do
  [ "$ifc" = "loopback" ] && continue
  uci set "network.$ifc.ipv6=0" || true
  uci set "network.$ifc.delegate=0" || true
  uci -q delete "network.$ifc.ip6assign" || true
  uci -q delete "network.$ifc.ip6hint"   || true
done
ok "ipv6=0, delegate=0 выставлены; ip6assign/ip6hint удалены"

log "2) Удаляем wan6 (dhcpv6), если есть"
if uci -q show network.wan6 >/dev/null; then
  uci -q delete network.wan6 || true
  ok "network.wan6 удалён"
else
  warn "network.wan6 не найден — пропускаю"
fi

log "3) Режем DHCPv6/RA на всех DHCP-секциях (LAN/guest/iot/…)"
DSECS="$(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([^.]*\)=dhcp.*/\1/p" || true)"
for s in $DSECS; do
  uci -q delete "dhcp.$s.dhcpv6" || true
  uci -q delete "dhcp.$s.ra"     || true
done
ok "DHCPv6 и RA удалены на всех DHCP-секциях"

log "4) Удаляем ULA-префикс (если был)"
uci -q delete network.globals.ula_prefix || true
ok "ULA префикс удалён"

log "5) Отключаем и останавливаем odhcpd (RA/DHCPv6-сервер)"
/etc/init.d/odhcpd stop    || true
/etc/init.d/odhcpd disable || true
ok "odhcpd остановлен и отключён из автозагрузки"

log "6) Включаем фильтрацию AAAA во всех инстансах dnsmasq (если dnsmasq используется)"
DNSSECS="$(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([^.]*\)=dnsmasq.*/\1/p" || true)"
if [ -n "$DNSSECS" ]; then
  for s in $DNSSECS; do
    uci set "dhcp.$s.filter_aaaa=1"
  done
  ok "dnsmasq настроен на выдачу только A-записей (AAAA фильтруются)"
else
  warn "секций dnsmasq не найдено — пропускаю настройку AAAA; включи фильтрацию в своём резолвере (AdGuard Home/SmartDNS/https-dns-proxy)"
fi

log "7) Делаем sysctl персистентным и применяем его сейчас"
mkdir -p /etc/sysctl.d
SYSCTL_FILE="/etc/sysctl.d/99-disable-ipv6.conf"
cat > "$SYSCTL_FILE" <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
ok "sysctl записан и применён (ядро IPv6 выключено)"

log "8) Коммитим и перезапускаем сервисы"
uci commit network
uci commit dhcp
/etc/init.d/network restart
if [ -x /etc/init.d/dnsmasq ]; then
  if uci -q show dhcp 2>/dev/null | grep -q "=dnsmasq"; then
    /etc/init.d/dnsmasq restart
    ok "dnsmasq перезапущен"
  else
    warn "секций dnsmasq не найдено — перезапуск пропущен"
  fi
else
  warn "dnsmasq не обнаружен — перезапуск пропущен"
fi

log "Готово. IPv6 отключён системно, wan6 удалён, AAAA отрезаны (если dnsmasq используется)."
if [ "$SKIP_REBOOT" = "1" ]; then
  warn "Ребут пропущен (SKIP_REBOOT=1 или --no-reboot) — перезапусти вручную при необходимости"
else
  log "Ребут через 2 секунды для полной идемпотентности..."
  sleep 2
  reboot
fi
