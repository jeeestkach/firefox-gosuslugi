#!/bin/bash
# Установщик «Firefox Госуслуги» для macOS (в т.ч. 10.15 Catalina).
# Сначала только показывает установленные Firefox, их профили и дополнения, потом спрашивает
# подтверждение. Создаёт отдельный чистый профиль (из дополнений — только КриптоПро для кнопки
# «Подписать» в ГАС «Правосудие» / «Мой арбитр») и значок на рабочем столе.
# Не изменяет: программы Firefox, другие профили, их дополнения и настройки, список profiles.ini.
set -euo pipefail

FF_ROOT="$HOME/Library/Application Support/Firefox"
CLEAN_NAME="gosuslugi-clean"
PROF="$FF_ROOT/Profiles/$CLEAN_NAME"
MARKER="$PROF/.gosuslugi-clean"
APP="$HOME/Desktop/Firefox Госуслуги.app"
START_URL="https://kad.arbitr.ru/"
CP_EXT_ID="ru.cryptopro.nmcades@cryptopro.ru"
CP_EXT_URL="https://www.cryptopro.ru/sites/default/files/products/cades/extensions/firefox_cryptopro_extension_latest.xpi"
CP_HOST="ru.cryptopro.nmcades.json"
# Без ГОСТ-шифров: иначе LibreSSL в macOS получает ГОСТ-сертификат cryptopro.ru и не может его проверить.
CURL_CIPHERS="ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384"

# Спрашивает «да/нет»; по умолчанию — нет. $1 — вопрос. 0 = да.
# Без окна Терминала отвечает «нет» (ничего не меняем), кроме ASSUME_YES=1 для проверок.
ask_yes() {
  [ "${ASSUME_YES:-}" = 1 ] && return 0
  [ -t 0 ] || return 1
  local a
  read -r -p "$1 [д/Н] " a || return 1
  # Кириллица целыми буквами, не в [ ]: bash 3.2 при локали C сравнивает байты.
  case "$a" in Д*|д*|Y*|y*) return 0 ;; *) return 1 ;; esac
}

# Ждёт Enter перед закрытием окна. $1 — код выхода.
pause_exit() {
  if [ -t 0 ]; then read -r -p "Нажмите Enter, чтобы закрыть окно…" _ || true; fi
  exit "${1:-0}"
}

# Версия программы по её Info.plist. $1 — путь к .app.
app_version() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?"; }

# Идентификатор программы (org.mozilla.firefox и т.п.). $1 — путь к .app.
app_bundle_id() { defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null || true; }

# Печатает дополнения профиля (только установленные пользователем). $1 — папка профиля.
list_addons() {
  osascript -l JavaScript - "$1/extensions.json" <<'JS' 2>/dev/null || echo "      (не удалось прочитать список дополнений)"
function run(argv) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (!s || s.isNil()) return "      (дополнений нет или профиль ни разу не запускался)";
  var d = JSON.parse(ObjC.unwrap(s)), out = [];
  (d.addons || []).forEach(function (a) {
    if (a.location !== "app-profile" || (a.type && a.type !== "extension")) return;
    if (/@mozilla\.(org|com)$/.test(a.id)) return;   // служебные компоненты самого Firefox
    var n = (a.defaultLocale && a.defaultLocale.name) || a.id;
    var warn = /vpn|proxy|прокси|savefrom|downloadhelper/i.test(n + " " + a.id) ? "  ⚠ может мешать входу на Госуслуги" : "";
    out.push("      • " + n + " " + a.version + (a.active ? "" : "  (выключено)") + warn);
  });
  return out.length ? out.join("\n") : "      (дополнений нет)";
}
JS
}

echo "=============================================="
echo "   Firefox для Госуслуг — установщик"
echo "=============================================="
echo
echo "Сейчас я только покажу, что установлено. Ничего не изменится без вашего подтверждения."
echo

# --- 1. Установленные программы Firefox -------------------------------------------------------
shopt -s nullglob
FF_APPS=()
for app in /Applications/*.app "$HOME/Applications"/*.app; do
  case "$(app_bundle_id "$app")" in
    org.mozilla.firefox|org.mozilla.firefoxdeveloperedition|org.mozilla.nightly) FF_APPS+=("$app") ;;
  esac
done
shopt -u nullglob

echo "── Программы Firefox ──"
if [ "${#FF_APPS[@]}" -eq 0 ]; then
  echo "  Firefox не найден. Установите его с https://www.mozilla.org/ru/firefox/ и запустите этот файл снова."
  pause_exit 1
fi
i=1; DEF_IDX=1
for app in "${FF_APPS[@]}"; do
  echo "  $i) $app — версия $(app_version "$app")"
  [ "$app" = "/Applications/Firefox.app" ] && DEF_IDX=$i
  i=$((i + 1))
done
echo

# --- 2. Профили и их дополнения ---------------------------------------------------------------
echo "── Профили Firefox и их дополнения ──"
INI="$FF_ROOT/profiles.ini"
DEFAULTS=""
if [ -f "$INI" ]; then
  DEFAULTS="$(grep -E '^Default=' "$INI" | sed 's/^Default=//' || true)"
  name=""; path=""; rel=1
  # Печатает накопленный раздел [ProfileN]. Глобальные name/path/rel.
  flush_profile() {
    [ -n "$path" ] || return 0
    local full="$path"; [ "$rel" = 1 ] && full="$FF_ROOT/$path"
    local mark=""; printf '%s\n' "$DEFAULTS" | grep -qxF "$path" && mark="  [основной]"
    local ver="не запускался"; [ -f "$full/compatibility.ini" ] && ver="последний запуск в Firefox $(grep -E '^LastVersion=' "$full/compatibility.ini" | sed 's/^LastVersion=//; s/_.*//' || echo "?")"
    echo "  • «${name}»$mark — $ver"
    echo "    $full"
    list_addons "$full"
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \[Profile*) flush_profile; name=""; path=""; rel=1 ;;
      \[*) flush_profile; name=""; path=""; rel=1 ;;
      Name=*) name="${line#Name=}" ;;
      Path=*) path="${line#Path=}" ;;
      IsRelative=*) rel="${line#IsRelative=}" ;;
    esac
  done < "$INI"
  flush_profile
else
  echo "  (профилей пока нет)"
fi
if [ -d "$PROF" ]; then
  echo "  • «${CLEAN_NAME}» — чистый профиль для Госуслуг (уже создан ранее, в список профилей не входит)"
  echo "    $PROF"
  list_addons "$PROF"
fi
echo

# --- 3. Компоненты для подписи и сертификаты -------------------------------------------------
echo "── Компоненты ──"
if [ -f "/Library/Application Support/Mozilla/NativeMessagingHosts/$CP_HOST" ] \
   || [ -f "$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/$CP_HOST" ]; then
  CP_PLUGIN=1; echo "  ✓ КриптоПро ЭЦП Browser plug-in установлен (нужен для кнопки «Подписать»)"
else
  CP_PLUGIN=0; echo "  ✗ КриптоПро ЭЦП Browser plug-in не найден — без него кнопка «Подписать» не заработает"
fi
if security find-certificate -c "Russian Trusted Root CA" >/dev/null 2>&1; then
  echo "  ✓ Корневой сертификат Минцифры есть в «Связке ключей»"
else
  echo "  ✗ Корневого сертификата Минцифры нет в «Связке ключей» (нужен для Сбербанка и др.)"
fi
echo

# --- 4. Выбор программы Firefox --------------------------------------------------------------
FF="${FF_APPS[$((DEF_IDX - 1))]}"
if [ "${#FF_APPS[@]}" -gt 1 ] && [ -t 0 ] && [ "${ASSUME_YES:-}" != 1 ]; then
  read -r -p "Какой Firefox использовать для чистого профиля? Номер [$DEF_IDX]: " n || n=""
  case "$n" in ''|*[!0-9]*) ;; *) [ "$n" -ge 1 ] && [ "$n" -le "${#FF_APPS[@]}" ] && FF="${FF_APPS[$((n - 1))]}" ;; esac
fi

# --- 5. Защита чужих данных ------------------------------------------------------------------
if [ -d "$PROF" ] && [ ! -f "$MARKER" ] \
   && ! grep -qs "Чистый профиль Firefox для Госуслуг" "$PROF/user.js" \
   && [ -n "$(ls -A "$PROF" 2>/dev/null)" ]; then
  echo "✗ Папка $PROF уже существует и создана не этим установщиком."
  echo "  Чтобы ничего не повредить, установка остановлена. Ничего не изменено."
  pause_exit 1
fi
[ -d "$PROF" ] && ACTION="Обновить" || ACTION="Создать"

echo "── Что будет сделано ──"
echo "  1. $ACTION отдельный профиль «${CLEAN_NAME}»:"
echo "     $PROF"
echo "  2. Добавить в него только расширение КриптоПро (скачивается с cryptopro.ru)"
echo "  3. Положить на рабочий стол значок «Firefox Госуслуги» — запускает"
echo "     $FF (версия $(app_version "$FF")) с этим профилем"
echo
echo "── Что НЕ изменится ──"
echo "  • программы Firefox (ни одна версия не удаляется и не обновляется)"
echo "  • другие профили, их дополнения, закладки и настройки"
echo "  • список профилей (profiles.ini) — чистый профиль в него не добавляется"
echo

if ! ask_yes "$ACTION чистый профиль для Госуслуг?"; then
  echo "Ничего не изменено."
  pause_exit 0
fi
echo

# --- 6. Установка ----------------------------------------------------------------------------
mkdir -p "$PROF/extensions"
touch "$MARKER"
cat > "$PROF/user.js" <<'EOF'
// Чистый профиль Firefox для Госуслуг, судов и банков: только расширение КриптоПро, сеть — системная.
user_pref("security.enterprise_roots.enabled", true);   // доверять сертификатам Минцифры из «Связки ключей»
user_pref("network.proxy.type", 5);                     // системные настройки прокси, без своих прокси
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "https://kad.arbitr.ru/");
user_pref("xpinstall.signatures.required", true);
// Расширение КриптоПро кладётся в папку профиля — включать его без отдельного подтверждения.
user_pref("extensions.autoDisableScopes", 14);
// Запрет дополнениям встраиваться в эти сайты (первые адреса — стандартный список Mozilla).
// Сайты судов (ej.sudrf.ru, *.arbitr.ru) НЕ включены: там расширение КриптоПро нужно для подписи.
user_pref("extensions.webextensions.restrictedDomains", "accounts-static.cdn.mozilla.net,accounts.firefox.com,addons.cdn.mozilla.net,addons.mozilla.org,api.accounts.firefox.com,content.cdn.mozilla.net,discovery.addons.mozilla.org,oauth.accounts.firefox.com,profile.accounts.firefox.com,support.mozilla.org,sync.services.mozilla.com,esia.gosuslugi.ru,www.gosuslugi.ru,gosuslugi.ru,lk.gosuslugi.ru,www.sberbank.ru,online.sberbank.ru");
EOF
echo "✓ Профиль: $PROF"

XPI_TMP="$(mktemp /tmp/cpext.XXXXXX)"
XPI_OK=0
if curl -fsSL --retry 3 --retry-delay 2 --max-time 60 --ciphers "$CURL_CIPHERS" ${CURL_OPTS:-} -o "$XPI_TMP" "$CP_EXT_URL"; then
  # Вывод unzip сначала в переменные: связка «unzip | grep -q» при pipefail падает случайным образом.
  XPI_MANIFEST="$(unzip -p "$XPI_TMP" manifest.json 2>/dev/null || true)"
  XPI_FILES="$(unzip -l "$XPI_TMP" 2>/dev/null || true)"
  case "$XPI_MANIFEST" in *"\"$CP_EXT_ID\""*)
    case "$XPI_FILES" in *META-INF/mozilla.rsa*) XPI_OK=1 ;; esac ;;
  esac
fi
if [ "$XPI_OK" = 1 ]; then
  mv -f "$XPI_TMP" "$PROF/extensions/$CP_EXT_ID.xpi"
  echo "✓ Расширение КриптоПро для подписи добавлено в профиль"
else
  rm -f "$XPI_TMP"
  echo "⚠ Не удалось скачать расширение КриптоПро. Установите его вручную: откройте"
  echo "  «Firefox Госуслуги» и перейдите по ссылке $CP_EXT_URL → «Добавить»."
fi

SCRIPT_FILE="$(mktemp /tmp/ffgos.XXXXXX)"
cat > "$SCRIPT_FILE" <<EOF
-- Запускает выбранный Firefox с чистым профилем для Госуслуг и судов
set firefoxApp to "$FF"
set profilePath to "$PROF"
do shell script "open -n -a " & quoted form of firefoxApp & " --args --no-remote --profile " & quoted form of profilePath & " $START_URL"
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
echo "Готово. Не устанавливайте в этот Firefox других дополнений, кроме КриптоПро."
[ "$CP_PLUGIN" = 1 ] || echo "Для подписи установите КриптоПро ЭЦП Browser plug-in: https://www.cryptopro.ru/products/cades/plugin"
echo "Для Сбербанка и других сайтов с сертификатами Минцифры они должны быть"
echo "установлены в «Связку ключей» с параметром «Всегда доверять»."

if [ -z "${NO_LAUNCH:-}" ] && [ "${ASSUME_YES:-}" != 1 ] && ask_yes "Запустить «Firefox Госуслуги» сейчас?"; then
  open "$APP"
fi
pause_exit 0
