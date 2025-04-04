#!/bin/sh
echo "=== Начало процесса отключения IPv6 ==="

# Шаг 1. Отключение IPv6 на LAN и WAN
echo "Шаг 1: Отключаем IPv6 на LAN и WAN..."
uci set 'network.lan.ipv6=0'
[ $? -eq 0 ] && echo "  LAN IPv6 отключен успешно" || { echo "  Ошибка: не удалось отключить LAN IPv6"; exit 1; }
uci set 'network.wan.ipv6=0'
[ $? -eq 0 ] && echo "  WAN IPv6 отключен успешно" || { echo "  Ошибка: не удалось отключить WAN IPv6"; exit 1; }

# Шаг 2. Отключение DHCPv6 на LAN
echo "Шаг 2: Отключаем DHCPv6 на LAN..."
uci set 'dhcp.lan.dhcpv6=disabled'
[ $? -eq 0 ] && echo "  DHCPv6 на LAN установлен в disabled" || { echo "  Ошибка: не удалось отключить DHCPv6 на LAN"; exit 1; }
uci commit
[ $? -eq 0 ] && echo "  Конфигурация сохранена" || { echo "  Ошибка: не удалось сохранить конфигурацию"; exit 1; }

# Шаг 3. Удаляем параметры DHCPv6 и RA
echo "Шаг 3: Удаляем настройки DHCPv6 и RA..."
uci -q delete dhcp.lan.dhcpv6
uci -q delete dhcp.lan.ra
uci commit
[ $? -eq 0 ] && echo "  Настройки DHCPv6 и RA удалены" || { echo "  Ошибка: не удалось удалить настройки DHCPv6 и RA"; exit 1; }

# Шаг 4. Отключение делегирования LAN
echo "Шаг 4: Отключаем делегирование LAN..."
uci set network.lan.delegate="0"
uci commit
[ $? -eq 0 ] && echo "  Делегирование LAN отключено" || { echo "  Ошибка: не удалось отключить делегирование LAN"; exit 1; }

# Шаг 5. Удаление ULA префикса
echo "Шаг 5: Удаляем ULA префикс..."
uci -q delete network.globals.ula_prefix
uci commit
[ $? -eq 0 ] && echo "  ULA префикс удалён" || { echo "  Ошибка: не удалось удалить ULA префикс"; exit 1; }

# Шаг 6. Отключение и остановка odhcpd
echo "Шаг 6: Отключаем и останавливаем odhcpd..."
/etc/init.d/odhcpd disable
/etc/init.d/odhcpd stop
uci commit
[ $? -eq 0 ] && echo "  odhcpd отключён и остановлен" || { echo "  Ошибка: не удалось отключить/остановить odhcpd"; exit 1; }

# Шаг 7. Перезапуск сети
echo "Шаг 7: Перезапускаем сеть..."
/etc/init.d/network restart
[ $? -eq 0 ] && echo "  Сеть перезапущена успешно" || { echo "  Ошибка: не удалось перезапустить сеть"; exit 1; }

# Шаг 8. Отключение IPv6 через sysctl и /proc
echo "Шаг 8: Отключаем IPv6 через sysctl и /proc..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1
[ $? -eq 0 ] && echo "  IPv6 отключён на всех интерфейсах (sysctl)" || { echo "  Ошибка: не удалось отключить IPv6 (sysctl)"; exit 1; }
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
[ $? -eq 0 ] && echo "  /proc настроен для отключения IPv6" || { echo "  Ошибка: не удалось записать в /proc для отключения IPv6"; exit 1; }
sysctl -w net.ipv6.conf.default.disable_ipv6=1
[ $? -eq 0 ] && echo "  IPv6 отключён на интерфейсе по умолчанию" || { echo "  Ошибка: не удалось отключить IPv6 на интерфейсе по умолчанию"; exit 1; }
sysctl -w net.ipv6.conf.lo.disable_ipv6=1
[ $? -eq 0 ] && echo "  IPv6 отключён на loopback интерфейсе" || { echo "  Ошибка: не удалось отключить IPv6 на loopback интерфейсе"; exit 1; }

# Шаг 9. Настройка dnsmasq для фильтрации AAAA записей
echo "Шаг 9: Настраиваем dnsmasq на выдачу только IPv4 записей..."
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci commit
[ $? -eq 0 ] && echo "  dnsmasq настроен: выдача только IPv4 записей" || { echo "  Ошибка: не удалось настроить dnsmasq"; exit 1; }
service dnsmasq restart
[ $? -eq 0 ] && echo "  dnsmasq перезапущен" || { echo "  Ошибка: не удалось перезапустить dnsmasq"; exit 1; }

echo "=== Все шаги выполнены успешно. Система перезагрузится. ==="
reboot
