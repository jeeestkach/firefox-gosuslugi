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

# Выполняет шаг, связанный с КриптоПро, в отдельном подпроцессе: любая ошибка в нём (даже неожиданная)
# только печатает сообщение и не останавливает установку Firefox. $1 — название шага, дальше — команда.
# «( … ) || …» не подходит: в таком контексте bash отключает set -e внутри, и ошибки проходят молча.
run_isolated() {
  local title="$1" rc; shift
  set +e
  ( set -e; "$@" )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || echo "  ⚠ ${title}: ошибка (код ${rc}). Этот шаг пропущен, установка Firefox продолжается."
  return 0
}

# Запускает команду с ограничением по времени и печатает её вывод. $1 — секунды, дальше — команда.
# Возвращает код команды; при превышении времени — 124.
with_timeout() {
  local secs="$1" out pid i=0 rc=0; shift
  out="$(mktemp /tmp/ffgos-cmd.XXXXXX)"
  "$@" >"$out" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((secs * 5)) ]; then
      kill -KILL "$pid" 2>/dev/null || true
      echo "(нет ответа за ${secs} с — остановлено)" >>"$out"; rc=124; break
    fi
    sleep 0.2; i=$((i + 1))
  done
  if [ "$rc" -eq 0 ]; then wait "$pid" 2>/dev/null || rc=$?; else wait "$pid" 2>/dev/null || true; fi
  cat "$out"; rm -f "$out"
  return "$rc"
}

# Версия программы по её Info.plist. $1 — путь к .app.
app_version() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?"; }

# Идентификатор программы (org.mozilla.firefox и т.п.). $1 — путь к .app.
app_bundle_id() { defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null || true; }

# Состояние дополнения в профиле: active / disabled / missing. $1 — папка профиля, $2 — id дополнения.
addon_state() {
  osascript -l JavaScript - "$1/extensions.json" "$2" <<'JS' 2>/dev/null || echo "missing"
function run(argv) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (!s || s.isNil()) return "missing";
  var a = (JSON.parse(ObjC.unwrap(s)).addons || []).filter(function (x) { return x.id === argv[1]; })[0];
  return a ? (a.active ? "active" : "disabled") : "missing";
}
JS
}

# Утилиты КриптоПро (переопределяются только для проверок установщика).
CP_BIN="${CP_BIN:-/opt/cprocsp/bin}"
CP_SBIN="${CP_SBIN:-/opt/cprocsp/sbin}"
CP_KEYS_DIR="${CP_KEYS_DIR:-/var/opt/cprocsp/keys/$(id -un)}"
CP_TIMEOUT="${CP_TIMEOUT:-20}"   # сколько секунд ждать ответа утилит КриптоПро

# Разбирает вывод «certmgr -list» в строки: владелец|издатель|действует до|встроенная лицензия|ключ|контейнер.
cert_records() {
  awk '
    function flush() { if (have) printf "%s|%s|%s|%s|%s|%s\n", subj, iss, na, lic, pk, cont; have = 0; subj = iss = na = lic = pk = cont = "" }
    /^[0-9]+-------/ { flush(); have = 1; next }
    /^====/ { flush(); next }
    have && index($0, " : ") {
      k = substr($0, 1, index($0, " : ") - 1); sub(/[ \t]+$/, "", k); v = substr($0, index($0, " : ") + 3)
      if (k == "Subject") subj = v; else if (k == "Issuer") iss = v; else if (k == "Not valid after") na = v
      else if (k == "Embedded License") lic = v; else if (k == "PrivateKey Link") pk = v; else if (k == "Container") cont = v
    }
    END { flush() }'
}

# Имя из DN (значение CN=…). $1 — строка Subject/Issuer.
dn_cn() {
  local cn; cn="$(printf '%s' "$1" | sed -n 's/.*CN=\([^,]*\).*/\1/p')"
  [ -n "$cn" ] && printf '%s' "$cn" || printf '%s' "$1"
}

# «дд/мм/гггг …» → «дд.мм.гггг (осталось N дн.)». $1 — значение Not valid after.
expiry_text() {
  local d t now left; d="${1%% *}"
  t="$(date -j -f "%d/%m/%Y" "$d" "+%s" 2>/dev/null || true)"
  now="$(date "+%s" 2>/dev/null || true)"
  # Если дату не удалось разобрать — показываем её как есть, без подсчёта дней.
  case "$t$now" in ''|*[!0-9]*) printf '%s' "$1"; return ;; esac
  left=$(( (t - now) / 86400 ))
  if [ "$left" -ge 0 ]; then printf '%s (осталось %s дн.)' "$(printf '%s' "$d" | tr '/' '.')" "$left"
  else printf '%s (ИСТЁК %s дн. назад)' "$(printf '%s' "$d" | tr '/' '.')" "$(( -left ))"; fi
}

# Печатает отчёт о подписях КриптоПро: лицензия, сертификаты, срок, встроенная лицензия, где лежит ключ.
signature_report() {
  echo "── Электронная подпись (КриптоПро) ──"
  if [ ! -x "$CP_BIN/certmgr" ]; then
    echo "  КриптоПро CSP не установлен — сертификатов подписи на этом Mac нет"
    return 0
  fi
  echo "  Лицензия КриптоПро на этом компьютере (общая, «на рабочее место»):"
  local lic; lic="$(with_timeout "$CP_TIMEOUT" "$CP_SBIN/cpconfig" -license -view || true)"
  printf '%s\n' "$lic" | sed '/^[[:space:]]*$/d' | head -6 | sed 's/^/      /'
  case "$lic" in
    *[Ee]xpired*|*истек*|*Истек*) echo "      → истекла: подписывать можно только сертификатом со встроенной лицензией" ;;
    *[Pp]ermanent*|*бессроч*|*Бессроч*) echo "      → бессрочная" ;;
    *[Ee]xpires*) echo "      → временная (пробная, «демо»): после окончания нужна лицензия или сертификат со встроенной" ;;
  esac
  local list recs n lrc=0
  list="$(with_timeout "$CP_TIMEOUT" "$CP_BIN/certmgr" -list -store uMy)" || lrc=$?
  recs="$(printf '%s\n' "$list" | cert_records)"
  n="$(printf '%s' "$recs" | grep -c '|' || true)"
  echo "  Сертификаты в хранилище «Личное»: $n"
  if [ "$n" -eq 0 ] && [ "$lrc" -ne 0 ]; then
    echo "      (ответ certmgr, код ${lrc}: $(printf '%s\n' "$list" | sed '/^[[:space:]]*$/d' | tail -2 | tr '\n' ' '))"
  fi
  [ "$n" -gt 0 ] || return 0
  local subj iss na elic pk cont rest folder
  while IFS='|' read -r subj iss na elic pk cont; do
    echo "  • $(dn_cn "$subj")"
    echo "      выдан:        $(dn_cn "$iss")"
    echo "      действует до: $(expiry_text "$na")"
    if [ -n "$elic" ]; then
      echo "      встроенная лицензия КриптоПро: ✓ есть ($elic) — подпись работает и при «демо»-лицензии"
    else
      echo "      встроенная лицензия КриптоПро: не найдена — нужна лицензия на рабочее место"
    fi
    case "$pk" in
      Yes|yes|Да|да)
        case "$cont" in
          HDIMAGE*)
            rest="${cont#HDIMAGE}"; while [ "${rest#\\}" != "$rest" ]; do rest="${rest#\\}"; done; folder="${rest%%\\*}"
            echo "      закрытый ключ: на диске этого Mac (носитель HDIMAGE)"
            if [ -d "$CP_KEYS_DIR/$folder" ]; then echo "        папка: $CP_KEYS_DIR/$folder"
            else echo "        папка: $CP_KEYS_DIR/$folder (не найдена по этому пути)"; fi ;;
          FLASH*) echo "      закрытый ключ: на флешке (носитель FLASH): $cont" ;;
          "")     echo "      закрытый ключ: есть, носитель не указан" ;;
          *)      echo "      закрытый ключ: на внешнем носителе/токене: $cont" ;;
        esac ;;
      *) echo "      закрытый ключ: не привязан — этим сертификатом подписывать нельзя" ;;
    esac
  done <<EOF
$recs
EOF
  if [ -d "$CP_KEYS_DIR" ]; then
    local dirs; dirs="$(ls -1d "$CP_KEYS_DIR"/*.000 2>/dev/null || true)"
    [ -n "$dirs" ] && { echo "  Все папки с ключами на диске ($CP_KEYS_DIR):"; printf '%s\n' "$dirs" | sed 's#.*/#      #'; }
  fi
  return 0
}

# Скачивает расширение КриптоПро в чистый профиль и проверяет, что Firefox его включил.
# Запускается через run_isolated: ошибка здесь не мешает созданию профиля и значка.
install_cryptopro_extension() {
  CPX_XPI="$(mktemp /tmp/cpext.XXXXXX)"; CPX_PNG=""; CPX_HL=""
  trap 'rm -f "${CPX_XPI:-}" "${CPX_PNG:-}"; [ -z "${CPX_HL:-}" ] || kill "$CPX_HL" 2>/dev/null; true' EXIT
  local ok=0 manifest files
  if curl -fsSL --retry 3 --retry-delay 2 --max-time 60 --ciphers "$CURL_CIPHERS" ${CURL_OPTS:-} -o "$CPX_XPI" "$CP_EXT_URL"; then
    # Вывод unzip сначала в переменные: связка «unzip | grep -q» при pipefail падает случайным образом.
    manifest="$(unzip -p "$CPX_XPI" manifest.json 2>/dev/null || true)"
    files="$(unzip -l "$CPX_XPI" 2>/dev/null || true)"
    case "$manifest" in *"\"$CP_EXT_ID\""*)
      case "$files" in *META-INF/mozilla.rsa*) ok=1 ;; esac ;;
    esac
  fi
  if [ "$ok" != 1 ]; then
    echo "⚠ Не удалось скачать расширение КриптоПро. Установите его вручную: откройте"
    echo "  «Firefox Госуслуги» и перейдите по ссылке $CP_EXT_URL → «Добавить»."
    return 0
  fi
  mv -f "$CPX_XPI" "$PROF/extensions/$CP_EXT_ID.xpi"
  echo "✓ Расширение КриптоПро скачано, проверяю установку в Firefox…"
  # Невидимый запуск Firefox с этим профилем: он регистрирует расширение и сразу закрывается.
  CPX_PNG="$(mktemp /tmp/ffgos-shot.XXXXXX)"
  "$FF/Contents/MacOS/firefox" --headless --no-remote --profile "$PROF" --screenshot "$CPX_PNG" about:blank >/dev/null 2>&1 &
  CPX_HL=$!
  for _ in $(seq 1 60); do kill -0 "$CPX_HL" 2>/dev/null || break; sleep 1; done
  kill "$CPX_HL" 2>/dev/null || true
  wait "$CPX_HL" 2>/dev/null || true
  CPX_HL=""
  case "$(addon_state "$PROF" "$CP_EXT_ID")" in
    active)   echo "✓ Расширение КриптоПро установлено и включено" ;;
    disabled) echo "⚠ Расширение КриптоПро установлено, но выключено: включите его в меню ☰ → «Дополнения и темы»" ;;
    *)        echo "⚠ Firefox не подтвердил установку расширения КриптоПро. Установите его вручную:"
              echo "  откройте «Firefox Госуслуги» и перейдите по ссылке $CP_EXT_URL → «Добавить»." ;;
  esac
}

# Разбирает system_profiler -xml (память, диски, видеокарта) и печатает строки отчёта. $1 — файл XML.
hw_profile_lines() {
  osascript -l JavaScript - "$1" <<'JS'
function run(argv) {
  var data = $.NSData.dataWithContentsOfFile(argv[0]);
  if (!data || data.isNil()) return "  (сведения о памяти и дисках недоступны)";
  var pl = ObjC.deepUnwrap($.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 0, null, null));
  var dimms = [], memType = "", memSpeed = "", drives = [], gpus = [], out = [];
  var str = function (v) { return typeof v === "string"; };
  function walk(o, t) {
    if (Array.isArray(o)) { o.forEach(function (x) { walk(x, t); }); return; }
    if (!o || typeof o !== "object") return;
    t = o._dataType || t;
    // Учитываем только настоящие записи: в XML есть служебный раздел с описанием колонок,
    // где на месте значений стоят словари.
    if (t === "SPMemoryDataType") {
      if (str(o.dimm_size)) dimms.push(o);
      if (str(o.dimm_type) && !memType) memType = o.dimm_type;
      if (str(o.dimm_speed) && !memSpeed) memSpeed = o.dimm_speed;
    }
    if ((t === "SPSerialATADataType" || t === "SPNVMeDataType") && typeof o.size_in_bytes === "number" &&
        (str(o.device_model) || str(o.spsata_medium_type))) drives.push({ t: t, o: o });
    if (t === "SPDisplaysDataType" && str(o.sppci_model)) gpus.push(o);
    for (var k in o) if (k !== "_dataType") walk(o[k], t);
  }
  walk(pl, "");
  var mem = [];
  if (memType && memType !== "empty") mem.push(memType);
  if (memSpeed && memSpeed !== "empty") mem.push(memSpeed);
  if (dimms.length) {
    var used = dimms.filter(function (d) { return !/^empty$/i.test(String(d.dimm_size)); }).length;
    mem.push("занято слотов: " + used + " из " + dimms.length);
  }
  out.push("MEMDETAIL\t" + mem.join(", "));
  gpus.forEach(function (g) {
    var vram = [g.spdisplays_vram, g._spdisplays_vram, g.spdisplays_vram_shared].filter(str)[0] || "";
    out.push("GPU\t" + g.sppci_model + (vram ? ", " + vram : ""));
  });
  drives.forEach(function (d) { try {
    var o = d.o, kind;
    if (d.t === "SPNVMeDataType") kind = "SSD (NVMe)";
    else if (/solid/i.test(o.spsata_medium_type || "")) kind = "SSD";
    else if (/rotational/i.test(o.spsata_medium_type || "")) kind = "жёсткий диск (HDD)";
    else kind = "диск";
    var gb = Math.round(Number(o.size_in_bytes) / 1e9);
    out.push("DISK\t" + String(o.device_model || o._name || "диск").replace(/\s+/g, " ").trim() + " — " + kind + ", " + gb + " ГБ");
  } catch (e) {} });
  return out.join("\n");
}
JS
}

# Печатает сведения о компьютере: модель, macOS, процессор, память, видеокарта, диски, свободное место.
hardware_report() {
  echo "── Этот Mac ──"
  local model_id name os cpu cores mem_gb xml lines free_gb
  model_id="${HW_MODEL:-$(sysctl -n hw.model 2>/dev/null || echo "?")}"
  # Маркетинговое название macOS кэширует в настройках «Об этом Mac» (например, «iMac (27 дюймов, конец 2013 г.)»).
  name="$(defaults read com.apple.SystemProfiler "CPU Names" 2>/dev/null | sed -n 's/^[^=]*= *"\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' | head -1 || true)"
  os="$(sw_vers -productVersion 2>/dev/null || echo "?")"
  cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null | sed 's/([RT]M)//g; s/  */ /g' || true)"
  cores="$(sysctl -n hw.physicalcpu 2>/dev/null || echo "?")"
  mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  if [ -n "$name" ]; then echo "  Модель:       ${name} (${model_id})"; else echo "  Модель:       ${model_id}"; fi
  echo "  macOS:        ${os}"
  echo "  Процессор:    ${cpu:-?}, ядер: ${cores}"
  if [ -n "${SP_XML_FILE:-}" ]; then xml="$SP_XML_FILE"; else
    xml="$(mktemp /tmp/ffgos-hw.XXXXXX)"
    with_timeout 60 system_profiler -xml SPMemoryDataType SPSerialATADataType SPNVMeDataType SPDisplaysDataType >"$xml" || true
  fi
  lines="$(hw_profile_lines "$xml" 2>/dev/null || true)"
  [ -n "${SP_XML_FILE:-}" ] || rm -f "$xml"
  local detail; detail="$(printf '%s\n' "$lines" | sed -n 's/^MEMDETAIL	//p')"
  echo "  Память:       ${mem_gb} ГБ${detail:+ (${detail})}"
  printf '%s\n' "$lines" | sed -n 's/^GPU	/  Видеокарта:   /p'
  echo "  Диски:"
  if printf '%s\n' "$lines" | grep -q '^DISK	'; then
    printf '%s\n' "$lines" | sed -n 's/^DISK	/    • /p'
  else
    echo "    (не удалось определить)"
  fi
  if diskutil apfs list 2>/dev/null | grep -Eq 'Fusion:[[:space:]]+Yes'; then
    echo "    (Fusion Drive: SSD и жёсткий диск объединены в один диск)"
  fi
  free_gb=$(( $(df -k / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0) / 1000000 ))
  echo "  Свободно на системном диске: ~${free_gb} ГБ"
  return 0
}

# Замер скорости записи диска: пишет временный файл 1 ГБ, ждёт реальной записи (sync) и удаляет его.
# Скорость чтения без прав администратора честно не измерить: macOS отдаёт свежий файл из памяти.
disk_speed_test() {
  local real best="" mbps avail_gb model run
  model="${HW_MODEL:-$(sysctl -n hw.model 2>/dev/null || echo "?")}"
  avail_gb=$(( $(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo 0) / 1000000 ))
  if [ "$avail_gb" -lt 3 ]; then echo "  Мало свободного места (~${avail_gb} ГБ) — замер пропущен"; return 0; fi
  # Глобальная переменная, а не local: ловушка EXIT срабатывает уже после выхода из функции.
  DT_FILE="$(mktemp /tmp/ffgos-speed.XXXXXX)"
  trap 'rm -f "${DT_FILE:-}"' EXIT
  echo "  Три замера записи файла 1 ГБ (файл каждый раз удаляется), берём лучший…"
  for run in 1 2 3; do
    real="$( { LC_ALL=C /usr/bin/time -p /bin/sh -c 'dd if=/dev/zero of="$1" bs=1m count=1024 2>/dev/null && sync' _ "$DT_FILE"; } 2>&1 | LC_ALL=C awk '/^real/ {print $2}')"
    rm -f "$DT_FILE"
    real="${real/,/.}"
    case "$real" in ''|*[!0-9.]*) continue ;; esac
    if [ -z "$best" ] || LC_ALL=C awk -v a="$real" -v b="$best" 'BEGIN { exit !(a < b) }'; then best="$real"; fi
  done
  if [ -z "$best" ]; then echo "  Не удалось измерить скорость"; return 0; fi
  mbps="$(LC_ALL=C awk -v r="$best" 'BEGIN { if (r > 0) printf "%.0f", 1024 / r; else print 0 }')"
  echo "  Скорость записи вашего диска: ~${mbps} МБ/с (лучший из трёх: 1 ГБ за ${best} с)"
  if [ "$mbps" -lt 250 ]; then echo "    → это скорость жёсткого диска (HDD)"
  elif [ "$mbps" -lt 650 ]; then echo "    → уровень SATA SSD"
  else echo "    → уровень PCIe/NVMe SSD"; fi
  echo
  echo "  Для сравнения — последовательная скорость (типичные значения):"
  case "$model" in
    iMac14,2)
      echo "    • жёсткий диск 7200 об/мин (штатный в iMac 2013) ........ 120–200 МБ/с"
      echo "    • внешний SSD по USB 3.0 (без разборки) .................. ~350–450 МБ/с"
      echo "    • SATA SSD вместо жёсткого диска (нужно снимать экран) .... ~500–550 МБ/с"
      echo "    • SSD в слот PCIe: родной Apple или NVMe через переходник"
      echo "      Sintech (нужно снимать экран; шина PCIe 2.0 x2) ......... ~750–780 МБ/с"
      echo "      Быстрее ~780 МБ/с в этом iMac не будет даже у новейших NVMe — предел шины."
      ;;
    *)
      echo "    • жёсткий диск 7200 об/мин ........ 120–200 МБ/с"
      echo "    • SATA SSD ........................ ~500–550 МБ/с"
      echo "    • NVMe SSD (PCIe 3.0/4.0) ......... 1500–7000 МБ/с (зависит от шины компьютера)"
      ;;
  esac
  echo "  Главное отличие SSD от жёсткого диска — случайный доступ (загрузка macOS, запуск программ):"
  echo "  у любого SSD он в десятки раз быстрее, поэтому компьютер ощущается намного быстрее,"
  echo "  чем показывает разница в МБ/с."
  return 0
}

# PID окон Firefox, запущенных именно с этим чистым профилем (по полному пути; основной Firefox не попадает).
PROF_RE="$(printf '%s' "$PROF" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
clean_profile_pids() { pgrep -f -- "--profile $PROF_RE( |\$)" || true; }

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

run_isolated "Сведения о компьютере" hardware_report
echo
if [ "${DISK_TEST:-}" = 1 ] || { [ -z "${ASSUME_YES:-}" ] && ask_yes "Измерить скорость диска? Будет записан и сразу удалён файл 1 ГБ (10–60 секунд)"; }; then
  echo "── Скорость диска ──"
  run_isolated "Замер скорости диска" disk_speed_test
  echo
fi

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

# --- 3а. Электронная подпись: сертификаты, срок, лицензия, где лежит ключ ---------------------
run_isolated "Отчёт об электронной подписи" signature_report
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
RUNNING_PIDS="$(clean_profile_pids)"

echo "── Что будет сделано ──"
if [ -n "$RUNNING_PIDS" ]; then
  echo "  0. Закрыть открытое окно «Firefox Госуслуги» — иначе изменения не применятся"
  echo "     (ваш основной Firefox не закрывается)"
fi
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
if [ -n "$RUNNING_PIDS" ]; then
  kill -TERM $RUNNING_PIDS 2>/dev/null || true
  for _ in $(seq 1 20); do [ -z "$(clean_profile_pids)" ] && break; sleep 1; done
  left="$(clean_profile_pids)"; [ -n "$left" ] && kill -KILL $left 2>/dev/null || true
  sleep 1
  echo "✓ Окно «Firefox Госуслуги» закрыто"
fi
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
// Расширение КриптоПро кладётся в папку профиля — включать его без отдельного подтверждения
// и проверять эту папку при каждом запуске (иначе Firefox видит её только при первом запуске).
user_pref("extensions.autoDisableScopes", 14);
user_pref("extensions.startupScanScopes", 1);
// Запрет дополнениям встраиваться в эти сайты (первые адреса — стандартный список Mozilla).
// Сайты судов (ej.sudrf.ru, *.arbitr.ru) НЕ включены: там расширение КриптоПро нужно для подписи.
user_pref("extensions.webextensions.restrictedDomains", "accounts-static.cdn.mozilla.net,accounts.firefox.com,addons.cdn.mozilla.net,addons.mozilla.org,api.accounts.firefox.com,content.cdn.mozilla.net,discovery.addons.mozilla.org,oauth.accounts.firefox.com,profile.accounts.firefox.com,support.mozilla.org,sync.services.mozilla.com,esia.gosuslugi.ru,www.gosuslugi.ru,gosuslugi.ru,lk.gosuslugi.ru,www.sberbank.ru,online.sberbank.ru");
EOF
echo "✓ Профиль: $PROF"

run_isolated "Установка расширения КриптоПро" install_cryptopro_extension

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
