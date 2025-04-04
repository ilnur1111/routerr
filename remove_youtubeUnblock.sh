#!/bin/sh
echo "=== Начало удаления youtubeUnblock и luci-app-youtubeUnblock ==="

# Шаг 1. Остановка сервиса youtubeUnblock
echo "Шаг 1: Останавливаем службу youtubeUnblock..."
if /etc/init.d/youtubeUnblock stop 2>/dev/null; then
    echo "  youtubeUnblock остановлен успешно"
else
    echo "  youtubeUnblock не запущен или отсутствует"
fi

# Шаг 2. Отключение автозапуска youtubeUnblock
echo "Шаг 2: Отключаем автозапуск youtubeUnblock..."
if /etc/init.d/youtubeUnblock disable 2>/dev/null; then
    echo "  Автозапуск youtubeUnblock отключён"
else
    echo "  youtubeUnblock не найден или автозапуск уже отключён"
fi

# Шаг 3. Удаление пакета youtubeUnblock
echo "Шаг 3: Удаляем пакет youtubeUnblock..."
opkg remove youtubeUnblock
if [ $? -eq 0 ]; then
    echo "  youtubeUnblock успешно удалён"
else
    echo "  Ошибка удаления youtubeUnblock или пакет отсутствует"
fi

# Шаг 4. Остановка и отключение luci-app-youtubeUnblock
echo "Шаг 4: Останавливаем и отключаем автозапуск luci-app-youtubeUnblock..."
if /etc/init.d/luci-app-youtubeUnblock stop 2>/dev/null; then
    echo "  luci-app-youtubeUnblock остановлен успешно"
else
    echo "  luci-app-youtubeUnblock не запущен или отсутствует"
fi

if /etc/init.d/luci-app-youtubeUnblock disable 2>/dev/null; then
    echo "  Автозапуск luci-app-youtubeUnblock отключён"
else
    echo "  luci-app-youtubeUnblock не найден или автозапуск уже отключён"
fi

# Шаг 5. Удаление пакета luci-app-youtubeUnblock
echo "Шаг 5: Удаляем пакет luci-app-youtubeUnblock..."
opkg remove luci-app-youtubeUnblock
if [ $? -eq 0 ]; then
    echo "  luci-app-youtubeUnblock успешно удалён"
else
    echo "  Ошибка удаления luci-app-youtubeUnblock или пакет отсутствует"
fi

echo "=== Удаление завершено успешно ==="
