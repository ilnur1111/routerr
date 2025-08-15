#!/bin/sh
# disable_ipv6_v2.1.sh — аккуратное и идемпотентное отключение IPv6 на OpenWrt (с ребутом)

set -eu

log() { echo "[IPv6-OFF] $*"; }
ok()  { echo "  ✔ $*"; }
warn(){ echo "  ! $*"; }
die() { echo "  ✖ $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти от root"

STAMP="$(date +%Y%m%d-%H%M%S)"
# Бэкапы на всякий
cp /etc/config/network "/etc/config/network.bak.$STAMP" 2>/dev/null || true
cp /etc/config/dhcp     "/etc/config/dhcp.bak.$STAMP"     2>/dev/null || true
cp /etc/config/firewall "/etc/config/firewall.bak.$STAMP" 2>/dev/null || true

log "1) Отключаем IPv6/делегирование на всех интерфейсах, кроме loopback"
IFACES="$(uci show network | sed -n "s/^network\.\([^.]*\)=interface.*/\1/p")"
for ifc in $IFACES; do
  [ "$ifc" = "loopback" ] && continue
  uci set "network.$ifc.ipv6=0" || true
  uci set "network.$ifc.delegate=0" || true
done
ok "ipv6=0 и delegate=0 поставлены глобально"

log "2) Удаляем wan6 (dhcpv6), если есть"
if uci -q show network.wan6 >/dev/null; then
  uci -q delete network.wan6 || true
  ok "network.wan6 удалён"
else
  warn "network.wan6 не найден — пропускаю"
fi

log "3) Режем DHCPv6/RA на всех DHCP-секциях (LAN/guest/iot/…)"
DSECS="$(uci show dhcp | sed -n "s/^dhcp\.\([^.]*\)=dhcp.*/\1/p")"
for s in $DSECS; do
  uci -q delete "dhcp.$s.dhcpv6" || true
  uci -q delete "dhcp.$s.ra"     || true
done
ok "DHCPv6 и RA удалены"

log "4) Удаляем ULA-префикс (если был)"
uci -q delete network.globals.ula_prefix || true
ok "ULA префикс удалён"

log "5) Отключаем и останавливаем odhcpd (RA/DHCPv6-сервер)"
/etc/init.d/odhcpd stop    || true
/etc/init.d/odhcpd disable || true
ok "odhcpd отключён"

log "6) Включаем фильтрацию AAAA во всех инстансах dnsmasq"
DNSSECS="$(uci show dhcp | sed -n "s/^dhcp\.\([^.]*\)=dnsmasq.*/\1/p")"
if [ -z "$DNSSECS" ]; then
  # На всякий случай создадим одну секцию
  uci add dhcp dnsmasq >/dev/null
  DNSSECS="$(uci show dhcp | sed -n "s/^dhcp\.\([^.]*\)=dnsmasq.*/\1/p")"
fi
for s in $DNSSECS; do
  uci set "dhcp.$s.filter_aaaa=1"
done
ok "dnsmasq настроен на выдачу только A-записей"

log "7) Делаем sysctl персистентным и применяем его сейчас"
mkdir -p /etc/sysctl.d
SYSCTL_FILE="/etc/sysctl.d/99-disable-ipv6.conf"
cat > "$SYSCTL_FILE" <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
# Применим немедленно (и на будущее загрузится сервисом sysctl)
sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
ok "sysctl записан в $SYSCTL_FILE и применён"

log "8) Коммитим и перезапускаем сервисы"
uci commit network
uci commit dhcp
/etc/init.d/network restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall reload
ok "network/dnsmasq/firewall обновлены"

# --- Опция: жёстко дропать IPv6 на firewall (раскомментируй блок ниже, если нужно) ---
: <<'HARD_DROP_V6'
log "9) (опционально) Добавляем правило firewall: DROP для всего IPv6"
# Проверяем существование по имени правила (корректно для UCI)
if uci show firewall | grep -q "name='block_ipv6_all'"; then
  warn "правило block_ipv6_all уже есть — пропускаю"
else
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='block_ipv6_all'
  uci set firewall.@rule[-1].family='ipv6'
  uci set firewall.@rule[-1].src='*'
  uci set firewall.@rule[-1].dest='*'
  uci set firewall.@rule[-1].proto='all'
  uci set firewall.@rule[-1].target='DROP'
  uci commit firewall
  /etc/init.d/firewall restart
  ok "правило block_ipv6_all добавлено"
fi
HARD_DROP_V6

log "Готово. IPv6 отключён системно, WAN6 удалён, AAAA отрезаны."
log "Ребут через 2 секунды для полной идемпотентности..."
sleep 2
reboot
