#!/bin/sh
# tailscale-firewall.sh
# Добавляет зону tailscale в /etc/config/firewall.

FW=/etc/config/firewall

# Проверяем, нет ли уже зоны tailscale
if grep -q "option name 'tailscale'" "$FW"; then
    echo "[tailscale-firewall] Блок 'tailscale' уже присутствует — изменений нет."
    exit 0
fi

# аппендим конфигурацию
cat >> "$FW" <<'EOF'

config zone
        option name 'tailscale'
        option input 'ACCEPT'
        option output 'ACCEPT'
        option forward 'ACCEPT'
        option masq '1'
        option mtu_fix '1'
        list network 'tailscale'

config forwarding
        option src 'tailscale'
        option dest 'lan'

config forwarding
        option src 'lan'
        option dest 'tailscale'
EOF

echo "[tailscale-firewall] Блок 'tailscale' добавлен."
echo "[tailscale-firewall] Перезапускаю firewall…"
/etc/init.d/firewall restart
echo "[tailscale-firewall] Готово."
