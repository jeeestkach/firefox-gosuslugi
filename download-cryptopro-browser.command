#!/bin/bash
# Помощник по установке КриптоПро для подписи в браузере на macOS (в т.ч. 10.15 Catalina).
# Скрипт только СКАЧИВАЕТ файлы в «Загрузки» и ОТКРЫВАЕТ официальные страницы.
# Он ничего не устанавливает и не меняет в системе. Установку вы делаете сами, вручную.
set -euo pipefail

DL="$HOME/Downloads"
CG_VER="128.0.6613.137"   # последняя сборка Chromium-Gost для macOS 10.15 Catalina
PLUGIN_PAGE="https://www.cryptopro.ru/products/cades/plugin"
CHROME_EXT_PAGE="https://chromewebstore.google.com/detail/extension-for-cades-brows/pfhgbfnnjiafkhfdkmpiflachepdcjod"
FF_XPI_URL="https://www.cryptopro.ru/sites/default/files/products/cades/extensions/firefox_cryptopro_extension_latest.xpi"
TEST_PAGE="https://www.cryptopro.ru/sites/default/files/products/cades/demopage/cades_bes_sample.html"
# Без ГОСТ-шифров: иначе LibreSSL в macOS получает ГОСТ-сертификат cryptopro.ru и не может его проверить.
CURL_CIPHERS="ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384"

case "$(uname -m)" in
  arm64) CG_ARCH="arm64" ;;
  *)     CG_ARCH="amd64" ;;   # Intel-Mac, в т.ч. iMac 2013
esac
CG_FILE="chromium-gost-${CG_VER}-macos-${CG_ARCH}.tar.bz2"
CG_URL="https://github.com/deemru/Chromium-Gost/releases/download/${CG_VER}/${CG_FILE}"

# Спрашивает «да/нет»; по умолчанию — нет. $1 — вопрос. 0 = да.
ask_yes() {
  [ "${ASSUME_YES:-}" = 1 ] && return 0
  [ -t 0 ] || return 1
  local a
  read -r -p "$1 [д/Н] " a || return 1
  case "$a" in Д*|д*|Y*|y*) return 0 ;; *) return 1 ;; esac
}

pause_exit() {
  if [ -t 0 ]; then read -r -p "Нажмите Enter, чтобы закрыть окно…" _ || true; fi
  exit "${1:-0}"
}

# Открывает страницу в браузере по умолчанию (в тестах подавляется через NO_OPEN=1).
open_page() { [ "${NO_OPEN:-}" = 1 ] || open "$1" >/dev/null 2>&1 || true; }

# Выполняет шаг в отдельном подпроцессе: ошибка печатается и не роняет остальной скрипт.
run_isolated() {
  local title="$1" rc; shift
  set +e
  ( set -e; "$@" )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || echo "  ⚠ ${title}: ошибка (код ${rc}). Этот шаг пропущен, скрипт продолжает."
  return 0
}

# Скачивает URL в «Загрузки», проверяет размер и первые байты, печатает имя, размер и SHA-256.
# $1 — URL, $2 — имя файла, $3 — минимальный размер в байтах, $4 — ожидаемая сигнатура (hex, напр. 425a68 для bzip2; пусто — не проверять).
download_checked() {
  local url="$1" name="$2" minsize="$3" magic="${4:-}" dest="$DL/$2" got sig
  mkdir -p "$DL"
  echo "  Скачиваю $name …"
  if ! curl -fL --progress-bar --retry 3 --retry-delay 2 --max-time 1200 --ciphers "$CURL_CIPHERS" ${CURL_OPTS:-} -o "$dest.part" "$url"; then
    rm -f "$dest.part"; echo "  ✗ Не удалось скачать $name"; return 1
  fi
  got="$(wc -c < "$dest.part" | tr -d ' ')"
  if [ "$got" -lt "$minsize" ]; then
    rm -f "$dest.part"; echo "  ✗ $name скачался неполным (${got} байт). Возможно, вместо файла отдали страницу."; return 1
  fi
  if [ -n "$magic" ]; then
    sig="$(head -c $(( ${#magic} / 2 )) "$dest.part" | xxd -p 2>/dev/null | tr -d '\n' | cut -c1-${#magic})"
    if [ "$sig" != "$magic" ]; then
      rm -f "$dest.part"; echo "  ✗ $name — неверный формат файла (получена страница, а не файл)."; return 1
    fi
  fi
  mv -f "$dest.part" "$dest"
  local human
  if [ "$got" -ge 1048576 ]; then human="$(( got / 1048576 )) МБ"; else human="$(( got / 1024 )) КБ"; fi
  echo "  ✓ Сохранено: $dest"
  echo "    размер: $human"
  echo "    SHA-256: $(shasum -a 256 "$dest" | awk '{print $1}')"
  return 0
}

echo "=================================================="
echo "   КриптоПро для браузеров — помощник загрузки"
echo "=================================================="
echo
echo "Этот скрипт только скачивает файлы в «Загрузки» и открывает нужные"
echo "страницы. Он ничего не устанавливает и не меняет в системе."
echo

# --- Что уже есть в системе ------------------------------------------------------------------
echo "── Что уже установлено ──"
if [ -x "/opt/cprocsp/bin/certmgr" ] || [ -d "/opt/cprocsp" ]; then
  echo "  ✓ КриптоПро CSP найден"
else
  echo "  ✗ КриптоПро CSP не найден — без него подпись работать не будет"
fi
if [ -f "/Library/Application Support/Mozilla/NativeMessagingHosts/ru.cryptopro.nmcades.json" ] \
   || [ -f "$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/ru.cryptopro.nmcades.json" ]; then
  echo "  ✓ КриптоПро ЭЦП Browser plug-in найден"
else
  echo "  ✗ КриптоПро ЭЦП Browser plug-in не найден"
fi
echo

# --- Что скрипт скачать НЕ может (и почему) --------------------------------------------------
echo "── Что нужно скачать вручную (по-другому нельзя) ──"
echo "  1. КриптоПро CSP + ЭЦП Browser plug-in — только после регистрации на cryptopro.ru."
echo "     В этом же установщике лежит расширение для Safari (отдельного файла нет)."
echo "  2. Расширение для Chrome — ставится из интернет-магазина Chrome (это не файл, а кнопка)."
echo "  Ниже скрипт откроет обе страницы в браузере."
echo

# --- Что скрипт может скачать напрямую -------------------------------------------------------
echo "── Что скрипт может скачать сам ──"
echo "  • Chromium-Gost ${CG_VER} (${CG_ARCH}) — браузер с уже встроенными расширениями"
echo "    КриптоПро и поддержкой ГОСТ. Надёжнее всего для входа по подписи на ГАС «Правосудие»."
echo "  • Расширение КриптоПро для Firefox (файл .xpi)."
echo

if ask_yes "Скачать Chromium-Gost ${CG_VER} (около 116 МБ)?"; then
  run_isolated "Загрузка Chromium-Gost" download_checked "$CG_URL" "$CG_FILE" 50000000 "425a68"
  echo
fi
if ask_yes "Скачать расширение КриптоПро для Firefox (.xpi)?"; then
  run_isolated "Загрузка расширения Firefox" download_checked "$FF_XPI_URL" "cryptopro_firefox_extension.xpi" 20000 "504b"
  echo
fi

# --- Открыть страницы ------------------------------------------------------------------------
if ask_yes "Открыть официальные страницы (плагин КриптоПро, расширение Chrome, тест)?"; then
  echo "  Открываю страницы в браузере…"
  open_page "$PLUGIN_PAGE"
  open_page "$CHROME_EXT_PAGE"
  open_page "$TEST_PAGE"
  echo "  ✓ Открыто (проверьте вкладки браузера)"
  echo
fi

# --- Что делать дальше -----------------------------------------------------------------------
echo "── Порядок установки ──"
echo "  1. На странице КриптоПро зарегистрируйтесь и скачайте установщик для macOS."
echo "     Установка: правый клик по .pkg → «Открыть» → «Открыть» (обойти Gatekeeper)."
echo "  2. Safari: Настройки → Расширения → включить «CryptoPro Extension…»."
echo "     Если его нет — открыть Программы → CryptoPro_ECP и включить там."
echo "  3. Chrome: на открытой странице магазина нажать «Установить»."
echo "     Важно: для входа по подписи на ej.sudrf.ru сайту нужно СТАРОЕ расширение;"
echo "     новое из магазина пройдёт тест, но на этом сайте вход может не заработать."
echo "     Тогда используйте скачанный Chromium-Gost — там встроено нужное расширение."
echo "  4. Проверка: открыть тестовую страницу и ответить «Да» на запрос доступа."
echo
echo "  Подсказка: плагин ставится ПОВЕРХ КриптоПро CSP. Если CSP ещё нет,"
echo "  сначала поставьте его (та же страница, вкладка «Скачать КриптоПро CSP»)."

pause_exit 0
