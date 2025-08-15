#!/bin/sh
# Установщик youtubeUnblock 1.1.0 для OpenWrt (fw4/nft)
# Проверено на: Cudy TR3000 (Filogic, aarch64_cortex-a53)
# Особенности:
#  - Без проверки версии OpenWrt (работает на 24.10.2 и др., если есть fw4/nft)
#  - Автопоиск правильных .ipk по странице релиза v1.1.0
#  - Русские сообщения и комментарии

set -eu

# ---------- утилиты ----------
die() { echo "ОШИБКА: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
fetch() { # fetch <url> <out>
  if have curl; then curl -fL --retry 3 -o "$2" "$1";
  elif have wget; then wget -q -O "$2" "$1";
  elif have uclient-fetch; then uclient-fetch -q -O "$2" "$1";
  else die "Нужен curl или wget (или uclient-fetch)"; fi
}
log() { printf '%s\n' "$*"; }

# ---------- окружение ----------
FW=iptables; have fw4 && FW=nft
[ "$FW" = "nft" ] || die "Обнаружен iptables. Этот установщик рассчитан на fw4/nft."

ARCH="$(opkg print-architecture | awk '/^arch / && $2 !~ /(all|noarch)/{print $2; exit}')"
[ -n "$ARCH" ] || die "Не удалось определить архитектуру opkg"

VER="1.1.0"
BASE_ASSETS="https://github.com/Waujito/youtubeUnblock/releases/expanded_assets/v${VER}"
BASE_DOWNLOAD="https://github.com/Waujito/youtubeUnblock/releases/download/v${VER}"

# Список возможных «серий» OpenWrt в имени пакета (сначала актуальная)
SERIES_CAND=""
if [ -r /etc/openwrt_release ]; then
  . /etc/openwrt_release
  if [ -n "${DISTRIB_RELEASE:-}" ]; then
    SR="openwrt-$(echo "$DISTRIB_RELEASE" | cut -d. -f1,2)"
    SERIES_CAND="$SR"
  fi
fi
SERIES_CAND="${SERIES_CAND} openwrt-24.10 openwrt-23.05"

INC="/usr/share/nftables.d/ruleset-post/537-youtubeUnblock.nft"
TMPDIR="/tmp"
ASSETS_HTML="${TMPDIR}/yu_assets_${VER}.html"
umask 022

log "=== Установка youtubeUnblock ${VER} (fw4/nft) ==="
log "[детектировано] arch: ${ARCH} ; firewall: ${FW}"

# ---------- [0] opkg update ----------
log "[0] Обновляю список пакетов (opkg update)…"
opkg update >/dev/null || die "opkg update завершился с ошибкой"

# ---------- [1] kmod'ы для nft ----------
log "[1] Устанавливаю модули ядра: kmod-nfnetlink-queue kmod-nft-queue kmod-nf-conntrack"
opkg install kmod-nfnetlink-queue kmod-nft-queue kmod-nf-conntrack >/dev/null || die "Не удалось установить kmod-пакеты"

# ---------- [2] получаем список артефактов релиза ----------
log "[2] Получаю список артефактов релиза ${VER}…"
fetch "$BASE_ASSETS" "$ASSETS_HTML" || die "Не удалось получить список артефактов релиза"

# luci-пакет (обычно noarch)
PKG_LUCI="$(sed -n "s#.*download/v${VER}/\\(luci-app-youtubeUnblock-[^\"']*\\.ipk\\).*#\\1#p" "$ASSETS_HTML" | head -n1 || true)"
[ -n "$PKG_LUCI" ] || die "Не найден luci-app пакет в релизе v${VER}"

# основной пакет под нашу архитектуру/серию
PKG_YU=""
for S in $SERIES_CAND; do
  CAND="$(sed -n "s#.*download/v${VER}/\\(youtubeUnblock-[^\"']*-${ARCH}-${S}\\.ipk\\).*#\\1#p" "$ASSETS_HTML" | head -n1 || true)"
  if [ -n "$CAND" ]; then PKG_YU="$CAND"; log "  Найден пакет под систему: ${PKG_YU}"; break; fi
done
[ -n "$PKG_YU" ] || die "Не найден пакет youtubeUnblock для arch=${ARCH} среди серий: ${SERIES_CAND}. Проверь релиз."

# ---------- [3] скачиваем .ipk ----------
cd "$TMPDIR" || die "Не удалось перейти в /tmp"
YU_URL="${BASE_DOWNLOAD}/${PKG_YU}"
LUCI_URL="${BASE_DOWNLOAD}/${PKG_LUCI}"

log "[3] Скачиваю пакеты из релиза ${VER}…"
fetch "$YU_URL"   "$PKG_YU"   || die "Не удалось скачать ${YU_URL}"
fetch "$LUCI_URL" "$PKG_LUCI" || die "Не удалось скачать ${LUCI_URL}"
[ -s "$PKG_YU" ] && [ -s "$PKG_LUCI" ] || die "Скачанные файлы пусты"

# ---------- [4] (опционально) проверка SHA256 ----------
VERIFY="${YU_VERIFY_SHA:-0}"
if [ "$VERIFY" = "1" ]; then
  have sha256sum || die "Нет sha256sum для проверки"
  [ -n "${YU_SHA256:-}" ]   || die "YU_SHA256 не задан"
  [ -n "${LUCI_SHA256:-}" ] || die "LUCI_SHA256 не задан"
  echo "${YU_SHA256}  ${PKG_YU}"    | sha256sum -c - || die "SHA256 не совпал для ${PKG_YU}"
  echo "${LUCI_SHA256}  ${PKG_LUCI}"| sha256sum -c - || die "SHA256 не совпал для ${PKG_LUCI}"
  log "[4] SHA256 проверены"
else
  log "[4] Проверка SHA256 пропущена (установить YU_VERIFY_SHA=1 для включения)"
fi

# ---------- [5] установка .ipk ----------
log "[5] Устанавливаю пакеты…"
opkg install "./${PKG_YU}" "./${PKG_LUCI}" >/dev/null || die "opkg install завершился с ошибкой"
[ -x /etc/init.d/youtubeUnblock ] || die "После установки не найден /etc/init.d/youtubeUnblock"
have nft || die "Команда 'nft' не найдена — необходим пакет nftables"

# ---------- [6] гарантируем include для fw4 ----------
log "[6] Проверяю include nft: ${INC}"
if [ ! -f "$INC" ]; then
  mkdir -p "$(dirname "$INC")" || die "Не удалось создать каталог для include"
  cat >"$INC" <<'EOF'
add chain inet fw4 youtubeUnblock { type filter hook postrouting priority mangle - 1; policy accept; }
add rule  inet fw4 youtubeUnblock 'tcp dport 443 ct original packets < 20 counter queue num 537 bypass'
add rule  inet fw4 youtubeUnblock 'meta l4proto udp ct original packets < 9 counter queue num 537 bypass'
insert rule inet fw4 output 'mark and 0x8000 == 0x8000 counter accept'
EOF
  log "  (+) include создан: $INC"
else
  log "  (=) include уже существует: $INC"
fi

# ---------- [7] перезагрузка firewall и сервисов ----------
log "[7] Перезагружаю firewall (fw4)…"
/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || die "Не удалось перезагрузить fw4"
have modprobe && { modprobe nfnetlink_queue 2>/dev/null || true; modprobe nft_queue 2>/dev/null || true; }

log "[8] Включаю автозапуск и перезапускаю youtubeUnblock…"
/etc/init.d/youtubeUnblock enable >/dev/null || die "Не удалось включить автозапуск"
/etc/init.d/youtubeUnblock restart >/dev/null || die "Не удалось перезапустить сервис"

# ---------- [9] быстрые проверки ----------
log "[9] Проверки…"
if nft -a list chain inet fw4 youtubeUnblock >/dev/null 2>&1; then
  log "  OK: цепочка 'inet fw4 youtubeUnblock' присутствует в nft"
else
  die "Цепочка 'youtubeUnblock' не найдена в nft"
fi

if logread -l 200 | grep -iq youtubeunblock; then
  log "  OK: в системном логе есть записи youtubeUnblock"
else
  log "  ПРИМЕЧАНИЕ: логов пока может не быть — это нормально сразу после установки"
fi

log "=== Готово. При необходимости: /etc/init.d/firewall reload && /etc/init.d/youtubeUnblock restart ==="
