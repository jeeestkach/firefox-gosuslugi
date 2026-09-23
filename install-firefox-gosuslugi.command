#!/bin/bash
# Установщик «Firefox Госуслуги»: отдельный чистый профиль Firefox без дополнений
# и значок запуска на рабочем столе. Основной профиль Firefox не затрагивается.
# Повторный запуск безопасен: профиль сохраняется, пересоздаются только настройки и значок.
set -euo pipefail

FF="/Applications/Firefox.app"
PROF="$HOME/Library/Application Support/Firefox/Profiles/gosuslugi-clean"
APP="$HOME/Desktop/Firefox Госуслуги.app"
START_URL="https://kad.arbitr.ru/"

# Спрашивает подтверждение, только если скрипт запущен в окне Терминала.
# $1 — текст вопроса. Возвращает 0, если ответ «да» (по умолчанию — да).
ask_yes() {
  [ -t 0 ] || return 1
  read -r -p "$1 [Д/н] " a
  # Кириллица перечислена целыми буквами, не в [ ]: bash 3.2 в Catalina при локали C сравнивает байты.
  case "$a" in Н*|н*|N*|n*) return 1 ;; *) return 0 ;; esac
}

# Ждёт Enter перед закрытием окна, чтобы пользователь успел прочитать сообщение.
pause_exit() {
  [ -t 0 ] && read -r -p "Нажмите Enter, чтобы закрыть окно…" _ || true
  exit "${1:-0}"
}

echo "=== Установка «Firefox Госуслуги» ==="

if [ ! -d "$FF" ]; then
  echo "Firefox не найден в папке «Программы»."
  echo "Установите его с https://www.mozilla.org/ru/firefox/ и запустите этот файл снова."
  pause_exit 1
fi

mkdir -p "$PROF"
cat > "$PROF/user.js" <<'EOF'
// Чистый профиль Firefox для Госуслуг, судов и банков: без дополнений, сеть — системная.
user_pref("security.enterprise_roots.enabled", true);   // доверять сертификатам Минцифры из «Связки ключей»
user_pref("network.proxy.type", 5);                     // системные настройки прокси, без своих прокси
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "https://kad.arbitr.ru/");
user_pref("xpinstall.signatures.required", true);
// Запрет дополнениям встраиваться в эти сайты (первые адреса — стандартный список Mozilla).
user_pref("extensions.webextensions.restrictedDomains", "accounts-static.cdn.mozilla.net,accounts.firefox.com,addons.cdn.mozilla.net,addons.mozilla.org,api.accounts.firefox.com,content.cdn.mozilla.net,discovery.addons.mozilla.org,oauth.accounts.firefox.com,profile.accounts.firefox.com,support.mozilla.org,sync.services.mozilla.com,esia.gosuslugi.ru,www.gosuslugi.ru,gosuslugi.ru,lk.gosuslugi.ru,kad.arbitr.ru,my.arbitr.ru,esia.arbitr.ru,ej.sudrf.ru,www.sberbank.ru,online.sberbank.ru");
EOF
echo "✓ Профиль: $PROF"

SCRIPT_FILE="$(mktemp /tmp/ffgos.XXXXXX)"
cat > "$SCRIPT_FILE" <<EOF
-- Запускает отдельный Firefox с чистым профилем для Госуслуг и судов
set profilePath to "$PROF"
do shell script "open -n -a Firefox --args --no-remote --profile " & quoted form of profilePath & " $START_URL"
EOF
rm -rf "$APP"
osacompile -o "$APP" "$SCRIPT_FILE"
rm -f "$SCRIPT_FILE"
cp "$FF/Contents/Resources/firefox.icns" "$APP/Contents/Resources/applet.icns" 2>/dev/null || true
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
touch "$APP"
echo "✓ Значок на рабочем столе: «Firefox Госуслуги»"

echo
echo "Готово. Не устанавливайте в этот Firefox никаких дополнений."
echo "Для Сбербанка и других сайтов с сертификатами Минцифры они должны быть"
echo "установлены в «Связку ключей» с параметром «Всегда доверять»."

if [ -z "${NO_LAUNCH:-}" ] && ask_yes "Запустить «Firefox Госуслуги» сейчас?"; then
  open "$APP"
fi
pause_exit 0
