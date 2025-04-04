#!/bin/sh
echo "=== Начало установки youtubeUnblock и luci-app-youtubeUnblock ==="

# Шаг 0. Обновление списка пакетов
echo "Обновляем список пакетов..."
opkg update
[ $? -eq 0 ] && echo "  Список пакетов обновлен" || { echo "  Ошибка обновления списка пакетов"; exit 1; }

# Шаг 1. Установка модулей для nftables
echo "Устанавливаем модули kmod-nft-queue и kmod-nfnetlink-queue..."
opkg install kmod-nft-queue kmod-nfnetlink-queue
[ $? -eq 0 ] && echo "  Модули установлены" || { echo "  Ошибка установки модулей"; exit 1; }

echo "Проверяем установку kmod-nft..."
opkg list-installed | grep kmod-nft
[ $? -eq 0 ] && echo "  Пакеты kmod-nft обнаружены" || { echo "  Пакеты kmod-nft не найдены"; exit 1; }

echo "Загружаем модули nfnetlink_queue и nft_queue..."
modprobe nfnetlink_queue
[ $? -eq 0 ] && echo "  Модуль nfnetlink_queue загружен" || { echo "  Ошибка загрузки nfnetlink_queue"; exit 1; }
modprobe nft_queue
[ $? -eq 0 ] && echo "  Модуль nft_queue загружен" || { echo "  Ошибка загрузки nft_queue"; exit 1; }

# Шаг 2. Переходим в /tmp
echo "Переходим в каталог /tmp..."
cd /tmp || { echo "  Ошибка: не удалось перейти в /tmp"; exit 1; }

# Шаг 3. Скачивание youtubeUnblock IPK
echo "Скачиваем пакет youtubeUnblock..."
wget https://github.com/Waujito/youtubeUnblock/releases/download/v1.0.0/youtubeUnblock-1.0.0-10-f37c3dd-aarch64_cortex-a53-openwrt-23.05.ipk
[ $? -eq 0 ] && echo "  Пакет youtubeUnblock скачан" || { echo "  Ошибка скачивания youtubeUnblock"; exit 1; }

echo "Просмотр содержимого /tmp:"
ls -lh /tmp

# Шаг 4. Переименование youtubeUnblock
echo "Переименовываем скачанный файл youtubeUnblock..."
mv /tmp/f819f1ad-5f84-4888-9102-3a2ee54ce469* /tmp/youtubeUnblock-1.0.0-10-f37c3dd-aarch64_cortex-a53-openwrt-23.05.ipk
[ $? -eq 0 ] && echo "  Файл переименован успешно" || { echo "  Ошибка переименования файла youtubeUnblock"; exit 1; }

# Шаг 5. Установка youtubeUnblock
echo "Устанавливаем youtubeUnblock..."
opkg install /tmp/youtubeUnblock-1.0.0-10-f37c3dd-aarch64_cortex-a53-openwrt-23.05.ipk
[ $? -eq 0 ] && echo "  youtubeUnblock установлен успешно" || { echo "  Ошибка установки youtubeUnblock"; exit 1; }

echo "Проверяем установку youtubeUnblock..."
opkg list-installed | grep youtubeUnblock
[ $? -eq 0 ] && echo "  youtubeUnblock обнаружен в системе" || { echo "  youtubeUnblock не обнаружен"; exit 1; }

# Шаг 6. Включение автозапуска youtubeUnblock
echo "Включаем автозапуск youtubeUnblock..."
/etc/init.d/youtubeUnblock enable
[ $? -eq 0 ] && echo "  youtubeUnblock настроен на автозапуск" || { echo "  Ошибка включения автозапуска youtubeUnblock"; exit 1; }

# Блок перезагрузки системы удален
# Если требуется, можно добавить инструкцию о том, что перезагрузка должна выполняться вручную.

# Шаг 7. Скачивание luci-app-youtubeUnblock
echo "Скачиваем пакет luci-app-youtubeUnblock..."
wget https://github.com/Waujito/youtubeUnblock/releases/download/v1.0.0/luci-app-youtubeUnblock-1.0.0-10-f37c3dd.ipk
[ $? -eq 0 ] && echo "  Пакет luci-app-youtubeUnblock скачан" || { echo "  Ошибка скачивания luci-app-youtubeUnblock"; exit 1; }

echo "Просмотр содержимого /tmp:"
ls -lh /tmp

# Шаг 8. Переименование luci-app-youtubeUnblock
echo "Переименовываем скачанный файл luci-app-youtubeUnblock..."
mv /tmp/0335bf23-4502-4637-ab76-0c9471a48f68* /tmp/luci-app-youtubeUnblock-1.0.0-10-f37c3dd.ipk
[ $? -eq 0 ] && echo "  Файл переименован успешно" || { echo "  Ошибка переименования файла luci-app-youtubeUnblock"; exit 1; }

# Шаг 9. Установка luci-app-youtubeUnblock
echo "Устанавливаем luci-app-youtubeUnblock..."
opkg install /tmp/luci-app-youtubeUnblock-1.0.0-10-f37c3dd.ipk
[ $? -eq 0 ] && echo "  luci-app-youtubeUnblock установлен успешно" || { echo "  Ошибка установки luci-app-youtubeUnblock"; exit 1; }

echo "=== Установка завершена успешно ==="