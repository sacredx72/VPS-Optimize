#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_PROFILE="${CONFIG_PROFILE:-/etc/xui-custom-manager.conf}"
CONFIG_FILE="${CONFIG_FILE:-/etc/xui-custom-reset.json}"
BACKUP_DIR="${BACKUP_DIR:-/root/x-ui-backups}"
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
XUI_ETC_DIR="${XUI_ETC_DIR:-/etc/x-ui}"
XUI_PROGRAM_DIR="${XUI_PROGRAM_DIR:-/usr/local/x-ui}"
XUI_SUPPORTED_VERSION_RANGES="${XUI_SUPPORTED_VERSION_RANGES:-2.9.x 3.x}"
LOG_FILE="${LOG_FILE:-/var/log/xui-custom-manager.log}"
RESET_STATE="${RESET_STATE:-/var/lib/xui-custom-manager/reset-state.json}"
RESET_SERVICE="${RESET_SERVICE:-/etc/systemd/system/xui-custom-reset.service}"
RESET_TIMER="${RESET_TIMER:-/etc/systemd/system/xui-custom-reset.timer}"
LOCAL_RUNNER="/usr/local/bin/xui-custom-manager.sh"
XCM_PATH="/usr/local/bin/xcm"

RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
PLAIN='\033[0m'

RUN_CHECK=0
DRY_RUN=0
SELF_TEST=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --reset-check)
            RUN_CHECK=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --self-test)
            SELF_TEST=1
            ;;
        -h|--help)
            echo "Использование: $0 [--reset-check] [--dry-run] [--self-test]"
            exit 0
            ;;
        *)
            echo "Неизвестный параметр: $1"
            exit 1
            ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ] && [ "$SELF_TEST" -ne 1 ]; then
    echo "Пожалуйста, запустите от root."
    exit 1
fi

if [ -f "$CONFIG_PROFILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_PROFILE"
fi

LOCAL_RUNNER="/usr/local/bin/xui-custom-manager.sh"
XCM_PATH="/usr/local/bin/xcm"

if [ "$SELF_TEST" -ne 1 ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
fi

if { [ "$RUN_CHECK" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; } && [ "$SELF_TEST" -ne 1 ] && [ ! -t 1 ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "===== $(date '+%F %T') выполнение reset-check ====="
fi

clear_screen() {
    if command -v clear >/dev/null 2>&1; then
        clear
    else
        printf '\033c'
    fi
}

pause() {
    echo
    read -rp "Нажмите Enter, чтобы вернуться в меню..."
}

confirm_yes() {
    local message="$1"
    local answer
    echo
    echo -e "${YELLOW}${message}${PLAIN}"
    read -rp "Введите YES для подтверждения: " answer
    [ "$answer" = "YES" ]
}

need_tty() {
    if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
        echo "Ошибка: для этой функции требуется интерактивный терминал."
        return 1
    fi
}

require_interactive_menu() {
    if [ -t 0 ]; then
        return 0
    fi
    if [ -r /dev/tty ]; then
        exec </dev/tty
        return 0
    fi
    echo "Ошибка: для меню управления требуется интерактивный терминал, но stdin не доступен."
    echo "Пожалуйста, запустите непосредственно в SSH: bash $LOCAL_RUNNER"
    echo "В неинтерактивной среде используйте: bash $LOCAL_RUNNER --reset-check --dry-run"
    return 1
}

read_menu_choice() {
    local __var_name="$1"
    local __prompt="${2:-👉 Выберите действие: }"
    local __value
    read -rp "$__prompt" __value
    printf -v "$__var_name" '%s' "$__value"
}

ensure_dirs() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$RESET_STATE")"
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$(dirname "$RESET_STATE")"
}

detect_xui_version() {
    local command_line output version
    local -a parts
    local commands=(
        "x-ui version"
        "x-ui -v"
        "/usr/local/x-ui/x-ui version"
        "/usr/local/x-ui/x-ui -v"
    )

    for command_line in "${commands[@]}"; do
        read -r -a parts <<< "$command_line"
        output="$("${parts[@]}" 2>&1 || true)"
        version="$(printf '%s\n' "$output" | grep -Eo 'v?[0-9]+([.][0-9]+){2,3}' | head -n 1 | sed 's/^v//')"
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    done

    echo "unknown"
}

format_supported_version_ranges() {
    local output
    output="${XUI_SUPPORTED_VERSION_RANGES// /, }"
    echo "$output"
}

xui_version_is_supported() {
    local detected_version="${1:-}"
    local range
    detected_version="${detected_version:-$(detect_xui_version)}"
    for range in $XUI_SUPPORTED_VERSION_RANGES; do
        case "$range" in
            2.9.x)
                [[ "$detected_version" == 2.9.* ]] && return 0
                ;;
            3.x)
                [[ "$detected_version" == 3.* ]] && return 0
                ;;
            *)
                [[ "$detected_version" == "$range" ]] && return 0
                ;;
        esac
    done
    return 1
}

print_xui_version_warning() {
    local detected_version="${1:-}"
    local supported_ranges
    detected_version="${detected_version:-$(detect_xui_version)}"
    supported_ranges="$(format_supported_version_ranges)"
    if xui_version_is_supported "$detected_version"; then
        echo -e "${GREEN}Совместимость: текущая 3x-ui v${detected_version} входит в поддерживаемый диапазон, но перед записью в БД всё равно будет выполнена проверка таблиц/полей.${PLAIN}"
    else
        echo -e "${YELLOW}Предупреждение: текущая 3x-ui v${detected_version} не входит в поддерживаемый диапазон.${PLAIN}"
        echo -e "${YELLOW}Поддерживаемые версии: ${supported_ranges}. Для остальных версий разрешены только резервное копирование, просмотр, предпросмотр и самопроверка, но не запись в БД и не включение автоматического сброса.${PLAIN}"
    fi
}

check_xui_db_schema_readonly() {
    if [ ! -f "$XUI_DB" ]; then
        echo "База данных не найдена: $XUI_DB" >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Отсутствует python3, невозможно выполнить проверку схемы (только чтение)." >&2
        return 1
    fi

    XUI_DB="$XUI_DB" python3 <<'PY'
import os
import sqlite3
import sys

db_path = os.environ["XUI_DB"]
required = {
    "inbounds": {"id", "remark", "port", "up", "down", "total", "traffic_reset", "last_traffic_reset_time"},
    "client_traffics": {"id", "inbound_id", "email", "up", "down", "total", "enable"},
}
optional_relation = {
    "clients": {"id", "email"},
    "client_inbounds": {"client_id", "inbound_id"},
}

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
except Exception as exc:
    print(f"Не удалось открыть БД только для чтения: {exc}", file=sys.stderr)
    sys.exit(1)

try:
    missing = []
    def table_columns(table):
        rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
        return {row[1] for row in rows}

    for table, columns in required.items():
        existing = table_columns(table)
        if not existing:
            missing.append(f"{table}.*")
            continue
        for column in sorted(columns - existing):
            missing.append(f"{table}.{column}")
    relation_tables_found = any(table_columns(table) for table in optional_relation)
    if relation_tables_found:
        for table, columns in optional_relation.items():
            existing = table_columns(table)
            if not existing:
                missing.append(f"{table}.*")
                continue
            for column in sorted(columns - existing):
                missing.append(f"{table}.{column}")
    if missing:
        print("Проверка совместимости полей БД не пройдена, отсутствуют: " + ", ".join(missing), file=sys.stderr)
        sys.exit(1)
finally:
    conn.close()
PY
}

require_verified_xui_for_write() {
    local detected_version
    detected_version="$(detect_xui_version)"
    if ! xui_version_is_supported "$detected_version"; then
        print_xui_version_warning "$detected_version"
        echo -e "${RED}Ошибка: текущая версия 3x-ui не поддерживается, запись в БД и включение таймера запрещены.${PLAIN}"
        return 1
    fi
    if ! check_xui_db_schema_readonly; then
        print_xui_version_warning "$detected_version"
        echo -e "${RED}Ошибка: не удалось подтвердить совместимость полей БД, запись в БД и включение таймера запрещены.${PLAIN}"
        return 1
    fi
}

install_runtime_deps() {
    local missing=()

    command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "Ошибка: отсутствуют зависимости: ${missing[*]}, и apt-get не найден. Установите их вручную и повторите."
        return 1
    fi

    local apt_log_dir apt_log
    if [ -d /var/log ] && [ -w /var/log ]; then
        apt_log_dir="/var/log"
    else
        apt_log_dir="/tmp"
    fi
    apt_log="$(mktemp "${apt_log_dir}/xui-custom-manager-apt-XXXXXX.log")"

    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq >"$apt_log" 2>&1 || ! apt-get install -y "${missing[@]}" >>"$apt_log" 2>&1; then
        unset DEBIAN_FRONTEND
        echo "Ошибка: автоматическая установка зависимостей не удалась, лог: $apt_log"
        echo "Последние 20 строк:"
        tail -n 20 "$apt_log" 2>/dev/null || true
        return 1
    fi
    unset DEBIAN_FRONTEND
    rm -f "$apt_log"
}

timer_active_status() {
    if systemctl is-active --quiet xui-custom-reset.timer 2>/dev/null; then
        echo "включён"
    else
        echo "отключён"
    fi
}

timer_enabled_status() {
    if systemctl is-enabled --quiet xui-custom-reset.timer 2>/dev/null; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

runner_status() {
    if [ -x "$LOCAL_RUNNER" ]; then
        echo "установлен"
    else
        echo "не установлен"
    fi
}

register_xcm_shortcut() {
    local need_write=0

    mkdir -p "$(dirname "$XCM_PATH")"

    if [ ! -f "$XCM_PATH" ]; then
        need_write=1
    elif ! grep -q "CACHE_FILE=.*xui-custom-manager.sh" "$XCM_PATH" 2>/dev/null; then
        need_write=1
    elif ! grep -q "wget" "$XCM_PATH" 2>/dev/null; then
        need_write=1
    fi

    if [ "$need_write" -eq 1 ]; then
        cat > "$XCM_PATH" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

URL="https://raw.githubusercontent.com/Chunlion/VPS-Optimize/main/xui-custom-manager.sh"
CACHE_DIR="/usr/local/lib/xui-custom-manager"
CACHE_FILE="$CACHE_DIR/xui-custom-manager.sh"
TMP_FILE="$(mktemp)"

mkdir -p "$CACHE_DIR"

validate_downloaded_manager() {
    if ! bash -n "$TMP_FILE"; then
        echo "Предупреждение: синтаксическая проверка загруженного xui-custom-manager.sh не пройдена, сохраняем старый кеш."
        return 1
    fi
    if ! grep -Eq 'xui-custom-manager|CONFIG_PROFILE' "$TMP_FILE"; then
        echo "Предупреждение: загруженный xui-custom-manager.sh не содержит ключевых идентификаторов, сохраняем старый кеш."
        return 1
    fi
}

if command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 10 --retry 2 "$URL" -o "$TMP_FILE" && validate_downloaded_manager; then
    install -m 755 "$TMP_FILE" "$CACHE_FILE"
    rm -f "$TMP_FILE"
    exec bash "$CACHE_FILE" "$@"
fi

if command -v wget >/dev/null 2>&1 && wget -qO "$TMP_FILE" --timeout=10 --tries=2 "$URL" && validate_downloaded_manager; then
    install -m 755 "$TMP_FILE" "$CACHE_FILE"
    rm -f "$TMP_FILE"
    exec bash "$CACHE_FILE" "$@"
fi

rm -f "$TMP_FILE"

if [ -f "$CACHE_FILE" ]; then
    echo "Предупреждение: не удалось загрузить последнюю версию, используем локальный кеш."
    exec bash "$CACHE_FILE" "$@"
fi

echo "Ошибка: не удалось загрузить последнюю версию, и локальный кеш отсутствует."
exit 1
EOF
    fi

    chmod 755 "$XCM_PATH"
}

validate_manager_script_source() {
    local source_file="$1"
    local first_line

    if [ ! -r "$source_file" ]; then
        echo "Ошибка: исходный скрипт недоступен для чтения: $source_file"
        return 1
    fi
    IFS= read -r first_line < "$source_file" || first_line=""
    if [ "$first_line" != "#!/usr/bin/env bash" ]; then
        echo "Ошибка: отказ установки локального runner'а, первая строка исходного скрипта должна быть #!/usr/bin/env bash."
        return 1
    fi
    if ! bash -n "$source_file"; then
        echo "Ошибка: отказ установки локального runner'а, bash -n не пройден."
        return 1
    fi
    if ! grep -Eq 'xui-custom-manager|CONFIG_PROFILE' "$source_file"; then
        echo "Ошибка: отказ установки локального runner'а, исходный скрипт не содержит ключевых идентификаторов xui-custom-manager."
        return 1
    fi
}

install_local_runner() {
    local self_path
    self_path="$(readlink -f "${BASH_SOURCE[0]}")"

    mkdir -p "$(dirname "$LOCAL_RUNNER")"

    if [ "$self_path" = "$LOCAL_RUNNER" ] && [ -x "$LOCAL_RUNNER" ]; then
        return 0
    fi

    validate_manager_script_source "$self_path" || return 1
    install -m 755 "$self_path" "$LOCAL_RUNNER"
}

ensure_reset_timer_installed() {
    require_verified_xui_for_write || return 1
    install_local_runner

    cat > "$RESET_SERVICE" <<EOF
[Unit]
Description=x-ui custom reset check
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $LOCAL_RUNNER --reset-check
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal
EOF

    cat > "$RESET_TIMER" <<'EOF'
[Unit]
Description=Run x-ui custom reset check daily

[Timer]
OnCalendar=*-*-* 00:10:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now xui-custom-reset.timer
}

disable_reset_timer() {
    systemctl disable --now xui-custom-reset.timer >/dev/null 2>&1 || true
}

backup_database() {
    ensure_dirs

    if [ ! -f "$XUI_DB" ]; then
        echo "Ошибка: база данных не найдена: $XUI_DB"
        return 1
    fi

    local ts backup_file
    ts="$(date +%F_%H%M%S)"
    backup_file="$BACKUP_DIR/x-ui.db.$ts.bak"

    if sqlite3 "$XUI_DB" ".backup '$backup_file'"; then
        chmod 600 "$backup_file"
        echo "$backup_file"
        return 0
    fi

    echo "Ошибка: резервное копирование БД не удалось, запись отменена."
    return 1
}

backup_all() {
    ensure_dirs
    install_runtime_deps

    echo "Выполняется резервное копирование..."

    if [ -f "$XUI_DB" ]; then
        local db_backup
        db_backup="$(backup_database)" || return 1
        echo "Резервная копия БД: $db_backup"
    else
        echo "База данных не найдена, пропуск: $XUI_DB"
    fi

    local ts
    ts="$(date +%F_%H%M%S)"

    if [ -d "$XUI_ETC_DIR" ]; then
        tar -czf "$BACKUP_DIR/x-ui-etc.$ts.tar.gz" -C "$(dirname "$XUI_ETC_DIR")" "$(basename "$XUI_ETC_DIR")"
        chmod 600 "$BACKUP_DIR/x-ui-etc.$ts.tar.gz"
        echo "Резервная копия каталога конфигурации: $BACKUP_DIR/x-ui-etc.$ts.tar.gz"
    else
        echo "Каталог конфигурации не найден, пропуск: $XUI_ETC_DIR"
    fi

    if [ -d "$XUI_PROGRAM_DIR" ]; then
        tar -czf "$BACKUP_DIR/x-ui-program.$ts.tar.gz" -C "$(dirname "$XUI_PROGRAM_DIR")" "$(basename "$XUI_PROGRAM_DIR")"
        chmod 600 "$BACKUP_DIR/x-ui-program.$ts.tar.gz"
        echo "Резервная копия каталога программы: $BACKUP_DIR/x-ui-program.$ts.tar.gz"
    else
        echo "Каталог программы не найден, пропуск: $XUI_PROGRAM_DIR"
    fi
}

restore_backup() {
    local kind="$1"
    local pattern label target_dir

    ensure_dirs
    install_runtime_deps

    case "$kind" in
        db)
            pattern="x-ui.db.*.bak"
            label="БД"
            ;;
        program)
            pattern="x-ui-program.*.tar.gz"
            label="каталог программы"
            target_dir="$(dirname "$XUI_PROGRAM_DIR")"
            ;;
        etc)
            pattern="x-ui-etc.*.tar.gz"
            label="каталог конфигурации"
            target_dir="$(dirname "$XUI_ETC_DIR")"
            ;;
        *)
            echo "Неизвестный тип восстановления: $kind"
            return 1
            ;;
    esac

    while true; do
        clear_screen
        echo "================================================"
        echo "Восстановление $label"
        echo "================================================"

        local files=()
        mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pattern" | sort -r)

        if [ "${#files[@]}" -eq 0 ]; then
            echo "Резервные копии $label не найдены."
            echo "------------------------------------------------"
            echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
            echo "================================================"
            read_menu_choice _ "👉 Выберите действие: "
            return 0
        fi

        local i
        for i in "${!files[@]}"; do
            echo " $((i + 1)). ${files[$i]}"
        done
        echo "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo "================================================"

        local choice
        read_menu_choice choice "👉 Выберите файл резервной копии: "
        if [[ "$choice" =~ ^(0|q|Q)$ ]]; then
            return 0
        fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
            echo -e "${RED}❌ Неверный выбор!${PLAIN}"
            sleep 1
            continue
        fi

        local selected="${files[$((choice - 1))]}"
        confirm_yes "Восстановление перезапишет текущий $label. Перед восстановлением будет создана резервная копия текущего состояния." || {
            echo "Отменено."
            return 0
        }

        require_verified_xui_for_write || return 1

        echo "Создание резервной копии текущего состояния..."
        backup_all || return 1

        echo "Остановка x-ui..."
        systemctl stop x-ui || true

        if [ "$kind" = "db" ]; then
            cp -a "$selected" "$XUI_DB"
            chmod 600 "$XUI_DB"
        else
            tar -xzf "$selected" -C "$target_dir"
        fi

        echo "Запуск x-ui..."
        systemctl start x-ui || true
        echo
        print_health_report
        return 0
    done
}

cleanup_backups() {
    clear_screen
    echo "================================================"
    echo "Очистка старых резервных копий"
    echo "================================================"
    ensure_dirs

    local patterns=("x-ui.db.*.bak" "x-ui-etc.*.tar.gz" "x-ui-program.*.tar.gz")
    local labels=("БД" "каталог конфигурации" "каталог программы")
    local i

    for i in "${!patterns[@]}"; do
        local files=()
        mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${patterns[$i]}" | sort -r)

        if [ "${#files[@]}" -le 10 ]; then
            echo "${labels[$i]}: сейчас ${#files[@]} файлов, очистка не требуется."
            continue
        fi

        echo
        echo "${labels[$i]}: оставляем последние 10, можно удалить один старый файл."
        local idx
        for idx in "${!files[@]}"; do
            if [ "$idx" -ge 10 ]; then
                echo " $((idx + 1)). ${files[$idx]}"
            fi
        done
        echo -e "${RED}  0. Пропустить / q${PLAIN}"

        local choice
        read_menu_choice choice "👉 Выберите файл для удаления: "
        if [[ "$choice" =~ ^(0|q|Q)$ ]]; then
            continue
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 11 ] && [ "$choice" -le "${#files[@]}" ]; then
            local selected="${files[$((choice - 1))]}"
            confirm_yes "Подтвердите удаление файла: $selected" && rm -f -- "$selected" && echo "Удалено: $selected"
        else
            echo "Неверный выбор, пропускаем."
        fi
    done

    echo
    echo "Очистка завершена."
}

run_custom_reset_ui() {
    install_runtime_deps
    need_tty || return 1

    local xui_write_allowed=0
    local detected_version
    detected_version="$(detect_xui_version)"
    if xui_version_is_supported "$detected_version" && check_xui_db_schema_readonly >/dev/null 2>&1; then
        xui_write_allowed=1
    fi

    local tmp_py
    tmp_py="$(mktemp --suffix=.py)"
    trap 'rm -f "$tmp_py"' RETURN

    cat > "$tmp_py" <<'PY'
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

db_path = os.environ.get("XUI_DB", "/etc/x-ui/x-ui.db")
config_path = Path(os.environ.get("CONFIG_FILE", "/etc/xui-custom-reset.json"))
write_allowed = os.environ.get("XUI_WRITE_ALLOWED") == "1"
supported_ranges = os.environ.get("XUI_SUPPORTED_VERSION_RANGES", "2.9.x 3.x")
detected_version = os.environ.get("XUI_DETECTED_VERSION", "unknown")

ANSI = {
    "red": "\033[0;31m",
    "green": "\033[1;32m",
    "yellow": "\033[1;33m",
    "blue": "\033[1;34m",
    "magenta": "\033[1;35m",
    "cyan": "\033[1;36m",
    "white": "\033[1;37m",
    "bold": "\033[1m",
    "plain": "\033[0m",
}

def paint(text, color):
    return f"{ANSI[color]}{text}{ANSI['plain']}"

def title(text):
    print(paint("================================================", "cyan"))
    print(paint(text, "bold"))
    print(paint("================================================", "cyan"))

def separator():
    print(paint("------------------------------------------------", "blue"))

def menu_line(number, label, hint=""):
    line = f" {paint(str(number) + '.', 'cyan')} {paint(label, 'green')}"
    if hint:
        line += f" {paint(hint, 'yellow')}"
    print(line)

def status_value(enabled, enabled_text="Вкл", disabled_text="Выкл"):
    return paint(enabled_text, "green") if enabled else paint(disabled_text, "red")

def clear_screen():
    print("\033c", end="")

def pause():
    input("\nНажмите Enter, чтобы вернуться в меню...")

def print_write_blocked():
    print(paint(f"Ошибка: текущая 3x-ui v{detected_version} не входит в поддерживаемый диапазон, или проверка таблиц/полей БД не пройдена.", "red"))
    print(paint(f"Поддерживаемые версии: {', '.join(supported_ranges.split())}.", "yellow"))
    print(paint("При несоответствии разрешены только резервное копирование, просмотр, предпросмотр и самопроверка; изменение конфигурации, запись в БД и включение автоматического сброса запрещены.", "yellow"))

def require_config_write():
    if write_allowed:
        return True
    print_write_blocked()
    pause()
    return False

def valid_day(value):
    try:
        day = int(value)
    except Exception:
        return None
    return day if 1 <= day <= 31 else None

def default_config():
    return {"enabled": False, "default_day": 1, "inbounds": {}}

def normalize_config(data):
    if not isinstance(data, dict):
        raise ValueError("Корневой элемент конфигурации не является объектом")
    data.setdefault("enabled", False)
    data["enabled"] = bool(data.get("enabled"))
    day = valid_day(data.get("default_day", 1))
    data["default_day"] = day or 1
    if not isinstance(data.get("inbounds"), dict):
        data["inbounds"] = {}
    for iid, cfg in list(data["inbounds"].items()):
        if not isinstance(cfg, dict):
            data["inbounds"].pop(iid, None)
            continue
        cfg["enabled"] = bool(cfg.get("enabled", False))
        cfg["day"] = valid_day(cfg.get("day", data["default_day"])) or data["default_day"]
        cfg["reset_inbound"] = bool(cfg.get("reset_inbound", True))
        cfg["reset_clients_without_custom_day"] = bool(cfg.get("reset_clients_without_custom_day", False))
        if not isinstance(cfg.get("clients"), dict):
            cfg["clients"] = {}
        for email, ccfg in list(cfg["clients"].items()):
            if not isinstance(ccfg, dict):
                cfg["clients"].pop(email, None)
                continue
            cday = valid_day(ccfg.get("day", 0))
            if not cday:
                cfg["clients"].pop(email, None)
                continue
            ccfg["enabled"] = bool(ccfg.get("enabled", True))
            ccfg["day"] = cday
    return data

def load_config():
    if not config_path.exists():
        return default_config()
    try:
        with config_path.open("r", encoding="utf-8") as f:
            return normalize_config(json.load(f))
    except Exception as exc:
        print(f"Ошибка чтения конфигурации: {config_path}")
        print(f"Причина: {exc}")
        print("Пожалуйста, проверьте конфигурационный файл вручную или восстановите из резервной копии.")
        sys.exit(1)

def save_config(data):
    if not write_allowed:
        print_write_blocked()
        return False
    data = normalize_config(data)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = config_path.with_name(config_path.name + f".tmp.{os.getpid()}")
    with tmp_path.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp_path, config_path)
    os.chmod(config_path, 0o600)
    return True

def input_choice(prompt, valid_choices):
    while True:
        try:
            choice = input(prompt).strip()
        except (EOFError, KeyboardInterrupt):
            print("\nОтменено.")
            sys.exit(100)
        if choice in valid_choices:
            return choice
        print("Неверный выбор, попробуйте снова.")

def ask_day(prompt, allow_zero=False):
    while True:
        try:
            raw = input(prompt).strip()
        except (EOFError, KeyboardInterrupt):
            print("\nОтменено.")
            sys.exit(100)
        try:
            day = int(raw)
        except Exception:
            print("Введите число.")
            continue
        if allow_zero and day == 0:
            return 0
        if 1 <= day <= 31:
            return day
        print("День должен быть в диапазоне 1-31.")

def trunc(text, limit=20):
    text = text or "нет примечания"
    return text if len(text) <= limit else text[:limit] + "..."

def timer_status():
    return subprocess.run(["systemctl", "is-active", "--quiet", "xui-custom-reset.timer"]).returncode == 0

def load_db():
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        try:
            inbounds = conn.execute("SELECT id, remark, port, traffic_reset FROM inbounds ORDER BY id").fetchall()
        except sqlite3.OperationalError:
            inbounds = conn.execute("SELECT id, remark, port, 'unknown' AS traffic_reset FROM inbounds ORDER BY id").fetchall()
        clients = load_clients(conn)
        conn.close()
        return inbounds, clients
    except Exception as exc:
        print(paint(f"Ошибка чтения БД: {exc}", "red"))
        sys.exit(1)

def table_columns(conn, table):
    try:
        return {row[1] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}
    except sqlite3.OperationalError:
        return set()

def has_normalized_clients(conn):
    return (
        {"id", "email"} <= table_columns(conn, "clients")
        and {"client_id", "inbound_id"} <= table_columns(conn, "client_inbounds")
    )

def load_clients(conn):
    if has_normalized_clients(conn):
        rows = conn.execute(
            """
            SELECT COALESCE(ct.id, 0) AS id,
                   ci.inbound_id AS inbound_id,
                   c.email AS email
            FROM client_inbounds ci
            JOIN clients c ON c.id = ci.client_id
            LEFT JOIN client_traffics ct ON ct.email = c.email
            WHERE COALESCE(c.email, '') <> ''
            ORDER BY ci.inbound_id, c.id
            """
        ).fetchall()
        return [dict(row) for row in rows]
    try:
        return conn.execute("SELECT id, inbound_id, email FROM client_traffics ORDER BY id").fetchall()
    except sqlite3.OperationalError:
        return []

config = load_config()
inbounds, clients = load_db()
clients_by_inbound = {}
for client in clients:
    clients_by_inbound.setdefault(str(client["inbound_id"]), []).append(client)

def show_config():
    clear_screen()
    title("🧭 x-ui расширенный набор - текущая конфигурация пользовательского сброса")
    print(json.dumps(config, ensure_ascii=False, indent=2))
    pause()

def manage_clients(inbound_id, inbound_cfg):
    clients_for_inbound = clients_by_inbound.get(str(inbound_id), [])
    while True:
        clear_screen()
        title("🧭 x-ui расширенный набор - индивидуальная дата для клиента")
        print(f"{paint('ID входящего: ', 'cyan')}{paint(inbound_id, 'white')}")
        print(paint("Примечание: если не задано индивидуально, клиент следует правилам входящего.", "yellow"))
        separator()

        if not clients_for_inbound:
            print(paint("В этом входящем нет клиентов.", "yellow"))
        for idx, client in enumerate(clients_for_inbound, start=1):
            email = client["email"] or "без email"
            ccfg = inbound_cfg.get("clients", {}).get(email, {})
            if ccfg.get("enabled") and ccfg.get("day"):
                status = paint(f"ежемесячно {ccfg['day']} числа", "green")
            else:
                status = paint("не задано индивидуально", "yellow")
            print(f" {paint(str(idx) + '.', 'cyan')} {paint(email, 'white')}")
            print(f"    {status}")

        separator()
        print(f" {paint('0.', 'red')} Назад / q")
        print(paint("================================================", "cyan"))

        valid = {"0", "q", "Q"} | {str(i) for i in range(1, len(clients_for_inbound) + 1)}
        choice = input_choice("👉 Выберите клиента: ", valid)
        if choice in {"0", "q", "Q"}:
            return

        email = clients_for_inbound[int(choice) - 1]["email"] or ""
        if not require_config_write():
            continue
        day = ask_day("Введите 1-31 для установки даты клиента, 0 для удаления индивидуальной даты: ", allow_zero=True)
        inbound_cfg.setdefault("clients", {})
        if day == 0:
            inbound_cfg["clients"].pop(email, None)
            print("Индивидуальная дата клиента удалена.")
        else:
            inbound_cfg["clients"][email] = {"enabled": True, "day": day}
            print(f"Установлена дата: ежемесячно {day} числа.")
        save_config(config)

def manage_inbound(inbound):
    iid = str(inbound["id"])
    config.setdefault("inbounds", {})
    cfg = config["inbounds"].setdefault(iid, {})
    cfg.setdefault("enabled", False)
    cfg.setdefault("day", config.get("default_day", 1))
    cfg.setdefault("reset_inbound", True)
    cfg.setdefault("reset_clients_without_custom_day", False)
    cfg.setdefault("clients", {})
    if write_allowed:
        save_config(config)

    while True:
        clear_screen()
        title("🧭 x-ui расширенный набор - настройка входящего")
        print(f"{paint('ID: ', 'cyan')}{paint(iid, 'white')}")
        print(f"{paint('Порт: ', 'cyan')}{paint(str(inbound['port']), 'white')}")
        print(f"{paint('Примечание: ', 'cyan')}{paint(inbound['remark'] or 'нет', 'white')}")
        print()
        print(f"{paint('Внешний сброс: ', 'cyan')}{status_value(cfg.get('enabled'))}")
        print(f"{paint('Дата входящего: ', 'cyan')}{paint('ежемесячно ' + str(cfg.get('day', config.get('default_day', 1))) + ' числа', 'white')}")
        print(f"{paint('Сброс up/down самого входящего: ', 'cyan')}{paint('сброс', 'green') if cfg.get('reset_inbound', True) else paint('без сброса', 'yellow')}")
        print(f"{paint('Клиенты без индивидуальной даты: ', 'cyan')}{paint('следуют входящему', 'green') if cfg.get('reset_clients_without_custom_day', False) else paint('игнорируются', 'yellow')}")
        if inbound["traffic_reset"] == "monthly":
            print()
            print(paint("Напоминание: в панели всё ещё включён monthly, переключите в 3x-ui на never/не сбрасывать.", "yellow"))
        separator()
        menu_line(1, "Включить/выключить внешний сброс для этого входящего")
        menu_line(2, "Установить дату сброса для этого входящего")
        menu_line(3, "Включить/выключить сброс up/down самого входящего")
        menu_line(4, "Включить/выключить следование клиентов входящему")
        menu_line(5, "Управление индивидуальными датами клиентов")
        separator()
        print(f" {paint('0.', 'red')} Назад / q")
        print(paint("================================================", "cyan"))

        choice = input_choice("👉 Выберите действие: ", {"0", "q", "Q", "1", "2", "3", "4", "5"})
        if choice in {"0", "q", "Q"}:
            return
        if choice in {"1", "2", "3", "4"} and not require_config_write():
            continue
        if choice == "1":
            cfg["enabled"] = not cfg.get("enabled", False)
        elif choice == "2":
            cfg["day"] = ask_day("Введите дату ежемесячного сброса для этого входящего (1-31): ")
        elif choice == "3":
            cfg["reset_inbound"] = not cfg.get("reset_inbound", True)
        elif choice == "4":
            cfg["reset_clients_without_custom_day"] = not cfg.get("reset_clients_without_custom_day", False)
        elif choice == "5":
            manage_clients(iid, cfg)
        save_config(config)

def choose_inbound():
    while True:
        clear_screen()
        title("🧭 x-ui расширенный набор - выбор входящего")

        if not inbounds:
            print(paint("Входящие не найдены.", "yellow"))
        for idx, inbound in enumerate(inbounds, start=1):
            iid = str(inbound["id"])
            cfg = config.get("inbounds", {}).get(iid, {})
            enabled = status_value(cfg.get("enabled"))
            day = cfg.get("day", config.get("default_day", 1))
            print(f" {paint(str(idx) + '.', 'cyan')} ID={paint(iid, 'white')}   порт={paint(str(inbound['port']), 'white')}   примечание={paint(trunc(inbound['remark']), 'white')}")
            print(f"    Внешний сброс: {enabled}   дата: {paint('ежемесячно ' + str(day) + ' числа', 'green')}")
            if inbound["traffic_reset"] == "monthly":
                print(f"    Панель: {paint('monthly', 'red')}  {paint('ВНИМАНИЕ: переключите в панели на never/не сбрасывать', 'yellow')}")
            else:
                print(f"    Панель: {paint(inbound['traffic_reset'] or 'unknown', 'white')}")
            print()

        separator()
        print(f" {paint('0.', 'red')} Назад / q")
        print(paint("================================================", "cyan"))

        valid = {"0", "q", "Q"} | {str(i) for i in range(1, len(inbounds) + 1)}
        choice = input_choice("👉 Выберите входящий: ", valid)
        if choice in {"0", "q", "Q"}:
            return
        manage_inbound(inbounds[int(choice) - 1])

while True:
    clear_screen()
    title("🧭 x-ui расширенный набор - пользовательская дата сброса трафика")
    print(f"{paint('Глобальный статус: ', 'cyan')}{status_value(config.get('enabled'), 'Включён', 'Отключён')}")
    print(f"{paint('Дата по умолчанию: ', 'cyan')}{paint('ежемесячно ' + str(config.get('default_day', 1)) + ' числа', 'white')}")
    print(f"{paint('Автоматическая проверка: ', 'cyan')}{status_value(timer_status(), 'включена', 'отключена')}")
    print()
    if not write_allowed:
        print(paint(f"Совместимость: текущая 3x-ui v{detected_version} не входит в поддерживаемый диапазон, или проверка таблиц/полей БД не пройдена.", "yellow"))
        print(paint("В текущем режиме разрешены только просмотр конфигурации и предпросмотр, изменение конфигурации и включение автоматического сброса запрещены.", "yellow"))
        print()
    print(paint("Подсказка: в панели 3x-ui отключите встроенный monthly для соответствующих входящих.", "yellow"))
    print(paint("Если хотите только посмотреть, кого затронет сброс, выберите [4] — сначала будет предпросмотр, и только после ввода YES выполнится запись.", "yellow"))
    separator()
    menu_line(1, "Включить/выключить пользовательский сброс")
    menu_line(2, "Установить дату сброса по умолчанию", f"текущая: {config.get('default_day', 1)}-е")
    menu_line(3, "Управление датами сброса для входящих/клиентов")
    menu_line(4, "Предпросмотр и ручной запуск сброса")
    menu_line(5, "Просмотреть текущую конфигурацию (JSON)")
    separator()
    print(f" {paint('0.', 'red')} В главное меню / q")
    print(paint("================================================", "cyan"))

    choice = input_choice("👉 Выберите действие: ", {"0", "q", "Q", "1", "2", "3", "4", "5"})
    if choice in {"0", "q", "Q"}:
        sys.exit(0)
    if choice == "1":
        if not require_config_write():
            continue
        config["enabled"] = not config.get("enabled", False)
        save_config(config)
        sys.exit(200 if config["enabled"] else 201)
    if choice == "2":
        if not require_config_write():
            continue
        config["default_day"] = ask_day("Введите дату по умолчанию (1-31): ")
        save_config(config)
    elif choice == "3":
        choose_inbound()
    elif choice == "4":
        sys.exit(202)
    elif choice == "5":
        show_config()
PY

    set +e
    XUI_DB="$XUI_DB" CONFIG_FILE="$CONFIG_FILE" XUI_WRITE_ALLOWED="$xui_write_allowed" XUI_SUPPORTED_VERSION_RANGES="$XUI_SUPPORTED_VERSION_RANGES" XUI_DETECTED_VERSION="$detected_version" python3 "$tmp_py" </dev/tty
    local ret=$?
    rm -f "$tmp_py"
    trap - RETURN
    set -e

    case "$ret" in
        0|100)
            return 0
            ;;
        200)
            if ensure_reset_timer_installed; then
                echo "Пользовательский сброс включён, автоматическая проверка установлена и запущена."
                echo "Состояние таймера: $(timer_active_status)"
            else
                echo "Ошибка: пользовательский сброс включён, но не удалось установить или запустить автоматическую проверку."
                echo "Вы всё ещё можете выполнить сброс вручную через 'Предпросмотр и ручной запуск'."
            fi
            pause
            ;;
        201)
            disable_reset_timer
            echo "Пользовательский сброс отключён, таймер автоматической проверки остановлен."
            echo "Конфигурационный файл сохранён: $CONFIG_FILE"
            pause
            ;;
        202)
            run_reset_check_interactive
            ;;
        *)
            echo "Меню пользовательского сброса завершилось с кодом: $ret"
            pause
            ;;
    esac
}

run_traffic_ui() {
    install_runtime_deps
    need_tty || return 1

    local writes_file tmp_py
    writes_file="$(mktemp)"
    tmp_py="$(mktemp --suffix=.py)"
    trap 'rm -f "$tmp_py" "$writes_file"' RETURN

    cat > "$tmp_py" <<'PY'
import json
import os
import sqlite3
import sys
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

db_path = os.environ.get("XUI_DB", "/etc/x-ui/x-ui.db")
writes_file = os.environ["WRITES_FILE"]
GIB = Decimal(1024) ** 3

ANSI = {
    "red": "\033[0;31m",
    "green": "\033[1;32m",
    "yellow": "\033[1;33m",
    "blue": "\033[1;34m",
    "cyan": "\033[1;36m",
    "white": "\033[1;37m",
    "bold": "\033[1m",
    "plain": "\033[0m",
}

def paint(text, color):
    return f"{ANSI[color]}{text}{ANSI['plain']}"

def title(text):
    print(paint("================================================", "cyan"))
    print(paint(text, "bold"))
    print(paint("================================================", "cyan"))

def separator():
    print(paint("------------------------------------------------", "blue"))

def menu_line(number, label, hint=""):
    line = f" {paint(str(number) + '.', 'cyan')} {paint(label, 'green')}"
    if hint:
        line += f" {paint(hint, 'yellow')}"
    print(line)

def clear_screen():
    print("\033c", end="")

def format_gib(value):
    try:
        amount = Decimal(int(value or 0)) / GIB
    except Exception:
        amount = Decimal(0)
    return f"{amount.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)} GiB"

def parse_gib(raw):
    try:
        value = Decimal(raw.strip())
    except (InvalidOperation, AttributeError):
        raise ValueError("Введите корректное число")
    if value < 0:
        raise ValueError("Трафик не может быть отрицательным")
    return int((value * GIB).to_integral_value(rounding=ROUND_HALF_UP))

def input_choice(prompt, valid_choices):
    while True:
        try:
            choice = input(prompt).strip()
        except (EOFError, KeyboardInterrupt):
            print("\nОтменено.")
            sys.exit(100)
        if choice in valid_choices:
            return choice
        print("Неверный выбор, попробуйте снова.")

def ask_gib(prompt):
    while True:
        try:
            return parse_gib(input(prompt))
        except (EOFError, KeyboardInterrupt):
            print("\nОтменено.")
            sys.exit(100)
        except ValueError as exc:
            print(f"Некорректный ввод: {exc}")

def trunc(text, limit=20):
    text = text or "нет примечания"
    return text if len(text) <= limit else text[:limit] + "..."

def table_columns(conn, table):
    try:
        return {row[1] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}
    except sqlite3.OperationalError:
        return set()

def has_normalized_clients(conn):
    return (
        {"id", "email"} <= table_columns(conn, "clients")
        and {"client_id", "inbound_id"} <= table_columns(conn, "client_inbounds")
    )

def load_clients_for_inbound(conn, inbound_id):
    if has_normalized_clients(conn):
        return conn.execute(
            """
            SELECT ct.id AS id,
                   c.email AS email,
                   COALESCE(ct.up, 0) AS up,
                   COALESCE(ct.down, 0) AS down,
                   COALESCE(ct.total, 0) AS total
            FROM client_inbounds ci
            JOIN clients c ON c.id = ci.client_id
            JOIN client_traffics ct ON ct.email = c.email
            WHERE ci.inbound_id = ?
              AND COALESCE(c.email, '') <> ''
            ORDER BY c.id
            """,
            (inbound_id,),
        ).fetchall()
    try:
        return conn.execute(
            "SELECT id, email, up, down, total FROM client_traffics WHERE inbound_id=? ORDER BY id",
            (inbound_id,),
        ).fetchall()
    except sqlite3.OperationalError:
        return []

def load_rows():
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    inbounds = conn.execute("SELECT id, remark, port, up, down, total FROM inbounds ORDER BY id").fetchall()
    return conn, inbounds

try:
    conn, inbounds = load_rows()
except Exception as exc:
    print(f"Ошибка чтения БД: {exc}")
    sys.exit(1)

def build_write(target, up, down):
    before_up = int(target["up"] or 0)
    before_down = int(target["down"] or 0)
    return {
        "table": target["table"],
        "id": target["id"],
        "label": target["label"],
        "before_up": before_up,
        "before_down": before_down,
        "after_up": int(up),
        "after_down": int(down),
    }

def calibrate_target(target):
    clear_screen()
    title("🧭 x-ui расширенный набор - ввод корректируемых значений")
    print(f"{paint('Объект: ', 'cyan')}{paint(target['label'], 'white')}")
    print(f"{paint('Текущий использованный трафик: ', 'cyan')}{paint(format_gib((target['up'] or 0) + (target['down'] or 0)), 'green')}")
    print()
    print(paint("Выберите способ ввода:", "yellow"))
    menu_line(1, "Ввести общий использованный трафик, записать всё в down")
    menu_line(2, "Ввести общий использованный трафик, распределить пропорционально текущим up/down")
    menu_line(3, "Ввести up и down отдельно")
    separator()
    print(f" {paint('0.', 'red')} Назад / q")
    print(paint("================================================", "cyan"))
    mode = input_choice("👉 Выберите действие: ", {"0", "q", "Q", "1", "2", "3"})
    if mode in {"0", "q", "Q"}:
        return None

    cur_up = int(target["up"] or 0)
    cur_down = int(target["down"] or 0)
    cur_total = cur_up + cur_down

    if mode in ("1", "2"):
        total = ask_gib("Введите общий использованный трафик (GiB): ")
        if mode == "1" or cur_total <= 0:
            new_up, new_down = 0, total
        else:
            new_up = int(Decimal(total) * Decimal(cur_up) / Decimal(cur_total))
            new_down = total - new_up
    else:
        new_up = ask_gib("Введите трафик up (GiB): ")
        new_down = ask_gib("Введите трафик down (GiB): ")

    return build_write(target, new_up, new_down)

while True:
    clear_screen()
    title("🧭 x-ui расширенный набор - корректировка использованного трафика")
    print(paint("Здесь корректируется только использованный трафик up/down, лимит total не меняется.", "yellow"))
    print(paint("Единица: GiB (1 GiB = 1024^3 байт)", "yellow"))
    separator()

    if not inbounds:
        print(paint("Нет входящих.", "yellow"))
    for idx, inbound in enumerate(inbounds, start=1):
        used = int(inbound["up"] or 0) + int(inbound["down"] or 0)
        total = int(inbound["total"] or 0)
        total_text = format_gib(total) if total > 0 else "безлимит"
        print(f" {paint(str(idx) + '.', 'cyan')} ID={paint(str(inbound['id']), 'white')}   порт={paint(str(inbound['port']), 'white')}   примечание={paint(trunc(inbound['remark']), 'white')}")
        print(f"    Использовано: {paint(format_gib(used), 'green')} / лимит: {paint(total_text, 'yellow' if total <= 0 else 'white')}")
        print()

    separator()
    print(f" {paint('0.', 'red')} В главное меню / q")
    print(paint("================================================", "cyan"))

    valid_inbounds = {"0", "q", "Q"} | {str(i) for i in range(1, len(inbounds) + 1)}
    choice = input_choice("👉 Выберите входящий: ", valid_inbounds)
    if choice in {"0", "q", "Q"}:
        sys.exit(100)

    inbound = inbounds[int(choice) - 1]
    inbound_id = inbound["id"]

    clients = load_clients_for_inbound(conn, inbound_id)

    while True:
        clear_screen()
        title("🧭 x-ui расширенный набор - выбор объекта для корректировки")
        print(f"{paint('ID входящего: ', 'cyan')}{paint(str(inbound_id), 'white')}")
        print(f"{paint('Порт: ', 'cyan')}{paint(str(inbound['port']), 'white')}")
        print(f"{paint('Примечание: ', 'cyan')}{paint(inbound['remark'] or 'нет', 'white')}")
        separator()

        inbound_used = int(inbound["up"] or 0) + int(inbound["down"] or 0)
        menu_line(1, "Сам входящий")
        print(f"    Использовано: {paint(format_gib(inbound_used), 'green')}")
        print()

        for idx, client in enumerate(clients, start=2):
            used = int(client["up"] or 0) + int(client["down"] or 0)
            total = int(client["total"] or 0)
            total_text = format_gib(total) if total > 0 else "безлимит"
            print(f" {paint(str(idx) + '.', 'cyan')} {paint(client['email'] or 'без email', 'white')}")
            print(f"    Использовано: {paint(format_gib(used), 'green')} / лимит: {paint(total_text, 'yellow' if total <= 0 else 'white')}")
            print()

        all_clients_choice = str(len(clients) + 2)
        if clients:
            menu_line(all_clients_choice, "Корректировать всех клиентов по очереди")
        separator()
        print(f" {paint('0.', 'red')} Назад / q")
        print(paint("================================================", "cyan"))

        valid_objects = {"0", "q", "Q", "1"} | {str(i) for i in range(2, len(clients) + 2)}
        if clients:
            valid_objects.add(all_clients_choice)

        obj_choice = input_choice("👉 Выберите объект: ", valid_objects)
        if obj_choice in {"0", "q", "Q"}:
            break

        targets = []
        if obj_choice == "1":
            targets.append({
                "table": "inbounds",
                "id": inbound_id,
                "label": f"Входящий ID={inbound_id}",
                "up": inbound["up"],
                "down": inbound["down"],
            })
        elif clients and obj_choice == all_clients_choice:
            for client in clients:
                targets.append({
                    "table": "client_traffics",
                    "id": client["id"],
                    "label": client["email"] or f"Клиент ID={client['id']}",
                    "up": client["up"],
                    "down": client["down"],
                })
        else:
            client = clients[int(obj_choice) - 2]
            targets.append({
                "table": "client_traffics",
                "id": client["id"],
                "label": client["email"] or f"Клиент ID={client['id']}",
                "up": client["up"],
                "down": client["down"],
            })

        writes = []
        for target in targets:
            write = calibrate_target(target)
            if write is None:
                writes = []
                break
            writes.append(write)

        if not writes:
            continue

        clear_screen()
        title("🧭 x-ui расширенный набор - подтверждение записи")
        print(paint("Будут изменены только up/down, total не трогаем.", "yellow"))
        print(paint("Перед записью автоматически создается резервная копия БД и перезапускается x-ui.", "yellow"))
        separator()
        for write in writes:
            before_total = write["before_up"] + write["before_down"]
            after_total = write["after_up"] + write["after_down"]
            print(f"{paint('Объект: ', 'cyan')}{paint(write['label'], 'white')}")
            print(f"  До: up {paint(format_gib(write['before_up']), 'yellow')} / down {paint(format_gib(write['before_down']), 'yellow')} / всего {paint(format_gib(before_total), 'yellow')}")
            print(f"  После: up {paint(format_gib(write['after_up']), 'green')} / down {paint(format_gib(write['after_down']), 'green')} / всего {paint(format_gib(after_total), 'green')}")
            print()
        try:
            answer = input("Введите YES для подтверждения записи: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nОтменено.")
            sys.exit(100)
        if answer != "YES":
            print("Отменено, запись не выполнена.")
            sys.exit(100)

        with open(writes_file, "w", encoding="utf-8") as f:
            json.dump(writes, f, ensure_ascii=False)
        sys.exit(200)
PY

    set +e
    XUI_DB="$XUI_DB" WRITES_FILE="$writes_file" python3 "$tmp_py" </dev/tty
    local ret=$?
    rm -f "$tmp_py"
    set -e

    if [ "$ret" -eq 100 ]; then
        rm -f "$writes_file"
        trap - RETURN
        return 0
    fi
    if [ "$ret" -ne 200 ]; then
        rm -f "$writes_file"
        echo "Корректировка трафика отменена или не удалась."
        pause
        trap - RETURN
        return 0
    fi

    require_verified_xui_for_write || {
        rm -f "$writes_file"
        pause
        trap - RETURN
        return 1
    }

    echo "Создание резервной копии БД..."
    local db_backup
    db_backup="$(backup_database)" || {
        rm -f "$writes_file"
        pause
        trap - RETURN
        return 1
    }
    echo "Резервная копия БД: $db_backup"

    echo "Остановка x-ui..."
    systemctl stop x-ui || true

    set +e
    XUI_DB="$XUI_DB" WRITES_FILE="$writes_file" python3 <<'PY'
import json
import os
import sqlite3
import sys

db_path = os.environ["XUI_DB"]
writes_file = os.environ["WRITES_FILE"]

try:
    with open(writes_file, "r", encoding="utf-8") as f:
        writes = json.load(f)
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("BEGIN")
    for write in writes:
        table = write["table"]
        if table not in {"inbounds", "client_traffics"}:
            raise ValueError(f"Недопустимое имя таблицы: {table}")
        cur.execute(f"UPDATE {table} SET up=?, down=? WHERE id=?", (write["after_up"], write["after_down"], write["id"]))
        if cur.rowcount <= 0:
            raise RuntimeError(f"Объект не найден: {write['label']}")
    conn.commit()
    print("Запись выполнена успешно.")
except Exception as exc:
    try:
        conn.rollback()
    except Exception:
        pass
    print(f"Ошибка записи: {exc}")
    sys.exit(1)
finally:
    try:
        conn.close()
    except Exception:
        pass
PY
    local write_ret=$?
    set -e

    rm -f "$writes_file"
    trap - RETURN
    echo "Запуск x-ui..."
    systemctl start x-ui || true

    if [ "$write_ret" -eq 0 ]; then
        echo "Корректировка трафика завершена."
    else
        echo "Корректировка трафика не удалась, база данных сохранена в резервной копии: $db_backup"
    fi
    pause
}

run_reset_engine() {
    install_runtime_deps
    ensure_dirs
    if [ "$DRY_RUN" -ne 1 ]; then
        require_verified_xui_for_write || return 1
    fi

    XUI_DB="$XUI_DB" \
    CONFIG_FILE="$CONFIG_FILE" \
    RESET_STATE="$RESET_STATE" \
    BACKUP_DIR="$BACKUP_DIR" \
    DRY_RUN="$DRY_RUN" \
    PLAN_COUNT_FILE="${PLAN_COUNT_FILE:-}" \
    python3 <<'PY'
import calendar
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

db_path = Path(os.environ["XUI_DB"])
config_path = Path(os.environ["CONFIG_FILE"])
state_path = Path(os.environ["RESET_STATE"])
backup_dir = Path(os.environ["BACKUP_DIR"])
dry_run = os.environ.get("DRY_RUN") == "1"
plan_count_file = os.environ.get("PLAN_COUNT_FILE")

today = date.today()
current_month = today.strftime("%Y-%m")

def write_plan_count(count):
    if not plan_count_file:
        return
    try:
        Path(plan_count_file).write_text(str(count), encoding="utf-8")
    except Exception:
        pass

def non_negative_int(value, default=0):
    try:
        parsed = int(value or default)
    except Exception:
        parsed = default
    return max(parsed, 0)

def load_config():
    if not config_path.exists():
        return {"enabled": False, "default_day": 1, "inbounds": {}}
    try:
        with config_path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as exc:
        print(f"Ошибка чтения конфигурации: {config_path}")
        print(f"Причина: {exc}")
        return None
    if not isinstance(data, dict):
        print(f"Ошибка: неверный формат конфигурации: {config_path}")
        return None
    data.setdefault("enabled", False)
    data.setdefault("default_day", 1)
    data.setdefault("inbounds", {})
    if not isinstance(data["inbounds"], dict):
        data["inbounds"] = {}
    return data

def load_state():
    if not state_path.exists():
        return {"schema_version": 2, "inbounds": {}, "clients": {}}
    try:
        with state_path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as exc:
        print(f"Ошибка чтения файла состояния: {state_path}")
        print(f"Причина: {exc}")
        print("Во избежание повторного сброса скрипт не будет перезаписывать повреждённый файл состояния. Проверьте вручную или восстановите из резервной копии.")
        return None
    if not isinstance(data, dict):
        print(f"Ошибка: неверный формат файла состояния: {state_path}")
        return None
    if "schema_version" not in data:
        data = {
            "schema_version": 2,
            "inbounds": data.get("inbounds", {}) if isinstance(data.get("inbounds"), dict) else {},
            "clients": data.get("clients", {}) if isinstance(data.get("clients"), dict) else {},
        }
    data["schema_version"] = max(non_negative_int(data.get("schema_version", 1), 1), 2)
    data.setdefault("inbounds", {})
    data.setdefault("clients", {})
    if not isinstance(data["inbounds"], dict):
        data["inbounds"] = {}
    if not isinstance(data["clients"], dict):
        data["clients"] = {}
    for records in (data["inbounds"], data["clients"]):
        for key, record in list(records.items()):
            if not isinstance(record, dict):
                records[key] = {"traffic_totals": {"up": 0, "down": 0, "total": 0}}
                continue
            totals = record.get("traffic_totals")
            if not isinstance(totals, dict):
                totals = {}
            totals["up"] = non_negative_int(totals.get("up", 0))
            totals["down"] = non_negative_int(totals.get("down", 0))
            totals["total"] = totals["up"] + totals["down"]
            record["traffic_totals"] = totals
    return data

def save_state(data):
    state_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = state_path.with_name(state_path.name + f".tmp.{os.getpid()}")
    with tmp_path.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp_path, state_path)
    os.chmod(state_path, 0o600)

def safe_day(value, fallback=1):
    try:
        day = int(value)
    except Exception:
        day = fallback
    if day < 1:
        day = fallback
    if day > 31:
        day = 31
    return day

def effective_day(configured_day):
    last_day = calendar.monthrange(today.year, today.month)[1]
    return min(safe_day(configured_day), last_day)

def should_reset(configured_day, state_record):
    day = safe_day(configured_day)
    eff = effective_day(day)
    if today.day < eff:
        return False, f"Ещё не наступил день сброса: {day} числа, в этом месяце эффективный день {eff}"
    if state_record.get("last_reset_month") == current_month:
        reset_date = state_record.get("last_reset_date", "неизвестно")
        return False, f"В этом месяце уже был сброс {reset_date}"
    return True, f"День сброса {day} числа, эффективный день {eff}, в этом месяце ещё не сбрасывалось"

def truncate(text, limit=20):
    text = text or "нет примечания"
    return text if len(text) <= limit else text[:limit] + "..."

def connect_db():
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn

def table_columns(conn, table):
    try:
        return {row[1] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}
    except sqlite3.OperationalError:
        return set()

def has_normalized_clients(conn):
    return (
        {"id", "email"} <= table_columns(conn, "clients")
        and {"client_id", "inbound_id"} <= table_columns(conn, "client_inbounds")
    )

def load_client_links(conn):
    if has_normalized_clients(conn):
        rows = conn.execute(
            """
            SELECT ci.inbound_id AS inbound_id,
                   c.email AS email
            FROM client_inbounds ci
            JOIN clients c ON c.id = ci.client_id
            WHERE COALESCE(c.email, '') <> ''
            ORDER BY ci.inbound_id, c.id
            """
        ).fetchall()
        return [dict(row) for row in rows]
    try:
        return conn.execute("SELECT inbound_id, email FROM client_traffics ORDER BY id").fetchall()
    except sqlite3.OperationalError:
        return []

def load_db_rows(conn):
    try:
        inbounds = conn.execute("SELECT id, remark, port, traffic_reset FROM inbounds ORDER BY id").fetchall()
    except sqlite3.OperationalError:
        inbounds = conn.execute("SELECT id, remark, port, 'unknown' AS traffic_reset FROM inbounds ORDER BY id").fetchall()
    clients = load_client_links(conn)
    return inbounds, clients

def build_plan(config, state, inbounds, clients):
    inbound_map = {str(row["id"]): row for row in inbounds}
    clients_by_inbound = {}
    client_lookup = set()
    for client in clients:
        iid = str(client["inbound_id"])
        email = client["email"] or ""
        clients_by_inbound.setdefault(iid, []).append(client)
        client_lookup.add((iid, email))

    plan_inbounds = []
    plan_clients = []
    skipped = []
    warnings = []
    planned_client_emails = set()
    default_day = safe_day(config.get("default_day", 1))

    def add_client_plan(item):
        email = item.get("email") or ""
        if not email:
            skipped.append((item["label"], "email клиента пуст, пропуск"))
            return
        if email in planned_client_emails:
            skipped.append((item["label"], "этот email уже обработан в текущем плане, трафик клиентов в 3x-ui общий по email"))
            return
        planned_client_emails.add(email)
        plan_clients.append(item)

    for iid, cfg in sorted(config.get("inbounds", {}).items(), key=lambda item: int(item[0]) if str(item[0]).isdigit() else str(item[0])):
        if not isinstance(cfg, dict) or not cfg.get("enabled", False):
            continue

        inbound = inbound_map.get(str(iid))
        if inbound is None:
            skipped.append((f"Входящий ID={iid}", "входящий больше не существует, пропуск"))
            continue

        if inbound["traffic_reset"] == "monthly":
            warnings.append(f"Входящий ID={iid} всё ещё имеет включённый monthly в панели.")
            warnings.append("При использовании внешней даты сброса переключите в 3x-ui на never/не сбрасывать.")

        inbound_day = safe_day(cfg.get("day", default_day), default_day)
        inbound_due, inbound_reason = should_reset(inbound_day, state["inbounds"].get(str(iid), {}))
        inbound_label = f"Входящий ID={iid}, порт={inbound['port']}, примечание={truncate(inbound['remark'])}"

        if cfg.get("reset_inbound", True):
            if inbound_due:
                plan_inbounds.append({"id": str(iid), "label": inbound_label, "reason": inbound_reason})
            else:
                skipped.append((f"Входящий ID={iid}", inbound_reason))
        else:
            skipped.append((f"Входящий ID={iid}", "сброс up/down самого входящего отключён"))

        client_rules = cfg.get("clients", {}) if isinstance(cfg.get("clients"), dict) else {}

        if cfg.get("reset_clients_without_custom_day", False):
            for client in clients_by_inbound.get(str(iid), []):
                email = client["email"] or ""
                custom_rule = client_rules.get(email, {})
                if isinstance(custom_rule, dict) and custom_rule.get("enabled") and safe_day(custom_rule.get("day", 0), 0) > 0:
                    continue
                key = f"{iid}|{email}"
                due, reason = should_reset(inbound_day, state["clients"].get(key, {}))
                label = f"Клиент {email or 'без email'}, входящий ID={iid}"
                if due:
                    add_client_plan({"inbound_id": str(iid), "email": email, "key": key, "label": label, "reason": f"следует входящему, {reason}", "reset_scope": "inbound"})
                else:
                    skipped.append((label, reason))

        for email, ccfg in sorted(client_rules.items()):
            if not isinstance(ccfg, dict) or not ccfg.get("enabled", True):
                continue
            cday = safe_day(ccfg.get("day", 0), 0)
            if cday <= 0:
                continue
            key_tuple = (str(iid), email)
            label = f"Клиент {email or 'без email'}, входящий ID={iid}"
            if key_tuple not in client_lookup:
                skipped.append((label, "клиент больше не существует, пропуск"))
                continue
            key = f"{iid}|{email}"
            due, reason = should_reset(cday, state["clients"].get(key, {}))
            if due:
                add_client_plan({"inbound_id": str(iid), "email": email, "key": key, "label": label, "reason": f"индивидуальная дата клиента, {reason}", "reset_scope": "client"})
            else:
                skipped.append((label, reason))

    return plan_inbounds, plan_clients, skipped, warnings

def print_preview(plan_inbounds, plan_clients, skipped, warnings):
    print("================================================")
    print("Предпросмотр сброса")
    print("================================================")
    print(f"Дата: {today.isoformat()}")
    print("Режим: предпросмотр, запись в БД не выполняется")
    print("При реальном выполнении сбрасываются только up/down за текущий месяц; клиенты включаются по логике панели; all_time и total не изменяются.")
    print()
    if not plan_inbounds and not plan_clients:
        print("В этом месяце нет объектов для сброса.")
    else:
        print("Будут сброшены:")
        for item in plan_inbounds:
            print(f"  {item['label']}")
            print(f"    Причина: {item['reason']}")
            print()
        for item in plan_clients:
            print(f"  {item['label']}")
            print(f"    Причина: {item['reason']}")
            print()
    print("Не будут сброшены:")
    if not skipped:
        print("  нет")
    else:
        for label, reason in skipped:
            print(f"  {label}")
            print(f"    Причина: {reason}")
    if warnings:
        print()
        print("Предупреждения:")
        seen = set()
        for warning in warnings:
            if warning in seen:
                continue
            seen.add(warning)
            print(f"  {warning}")
    print("================================================")

def backup_database():
    backup_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(backup_dir, 0o700)
    backup_path = backup_dir / f"x-ui.db.{time.strftime('%Y-%m-%d_%H%M%S')}.bak"
    src = sqlite3.connect(db_path)
    dst = sqlite3.connect(backup_path)
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()
    os.chmod(backup_path, 0o600)
    return backup_path

def quick_health():
    print()
    print("Краткая проверка состояния:")
    active = subprocess.run(["systemctl", "is-active", "--quiet", "x-ui"]).returncode == 0
    print(f"  Служба x-ui: {'запущена' if active else 'не запущена'}")
    try:
        conn = sqlite3.connect(db_path)
        result = conn.execute("PRAGMA integrity_check;").fetchone()[0]
        conn.close()
        print(f"  Целостность БД: {result}")
    except Exception as exc:
        print(f"  Целостность БД: ошибка проверки: {exc}")

def add_preserved_traffic(state_record, up, down):
    totals = state_record.setdefault("traffic_totals", {})
    previous_up = non_negative_int(totals.get("up", 0))
    previous_down = non_negative_int(totals.get("down", 0))
    up = non_negative_int(up)
    down = non_negative_int(down)
    totals["up"] = previous_up + up
    totals["down"] = previous_down + down
    totals["total"] = totals["up"] + totals["down"]
    return totals

def get_table_columns(cur, table):
    try:
        return {row[1] for row in cur.execute(f"PRAGMA table_info({table})").fetchall()}
    except Exception:
        return set()

def execute_plan(plan_inbounds, plan_clients, state):
    print("Начинаем выполнение пользовательского сброса...")
    backup_path = backup_database()
    print(f"Резервная копия БД: {backup_path}")

    service_stopped = False
    conn = None
    updated_inbounds = []
    updated_clients = []
    skipped_write = []

    try:
        subprocess.run(["systemctl", "stop", "x-ui"], check=False)
        service_stopped = True

        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        cur.execute("BEGIN")
        inbound_columns = get_table_columns(cur, "inbounds")
        client_columns = get_table_columns(cur, "client_traffics")
        reset_time_ms = int(time.time() * 1000)
        inbounds_to_mark = set()
        reset_client_emails = set()

        for item in plan_inbounds:
            row = cur.execute("SELECT up, down FROM inbounds WHERE id=?", (item["id"],)).fetchone()
            if row is None:
                skipped_write.append((item["label"], "в момент записи входящий уже не существует"))
                continue
            cur.execute("UPDATE inbounds SET up=0, down=0 WHERE id=?", (item["id"],))
            if cur.rowcount > 0:
                item["preserved_totals"] = add_preserved_traffic(
                    state["inbounds"].setdefault(item["id"], {}),
                    row[0],
                    row[1],
                )
                updated_inbounds.append(item)
                inbounds_to_mark.add(item["id"])
            else:
                skipped_write.append((item["label"], "в момент записи входящий уже не существует"))

        for item in plan_clients:
            if item["email"] in reset_client_emails:
                skipped_write.append((item["label"], "этот email уже сброшен в текущем запуске"))
                continue
            row = cur.execute("SELECT up, down FROM client_traffics WHERE email=?", (item["email"],)).fetchone()
            if row is None:
                skipped_write.append((item["label"], "в момент записи клиент уже не существует"))
                continue
            if "enable" in client_columns:
                cur.execute(
                    "UPDATE client_traffics SET enable=1, up=0, down=0 WHERE email=?",
                    (item["email"],),
                )
            else:
                cur.execute(
                    "UPDATE client_traffics SET up=0, down=0 WHERE email=?",
                    (item["email"],),
                )
            if cur.rowcount > 0:
                reset_client_emails.add(item["email"])
                item["preserved_totals"] = add_preserved_traffic(
                    state["clients"].setdefault(item["key"], {}),
                    row[0],
                    row[1],
                )
                updated_clients.append(item)
                if item.get("reset_scope") == "inbound":
                    inbounds_to_mark.add(item["inbound_id"])
            else:
                skipped_write.append((item["label"], "в момент записи клиент уже не существует"))

        if "last_traffic_reset_time" in inbound_columns:
            for inbound_id in sorted(inbounds_to_mark, key=lambda value: int(value) if str(value).isdigit() else str(value)):
                cur.execute(
                    "UPDATE inbounds SET last_traffic_reset_time=? WHERE id=?",
                    (reset_time_ms, inbound_id),
                )

        conn.commit()

        for item in updated_inbounds:
            state["inbounds"].setdefault(item["id"], {}).update({"last_reset_month": current_month, "last_reset_date": today.isoformat()})
        for item in updated_clients:
            state["clients"].setdefault(item["key"], {}).update({"last_reset_month": current_month, "last_reset_date": today.isoformat()})
        save_state(state)

        if updated_inbounds or updated_clients:
            print("Сброс выполнен:")
            for item in updated_inbounds:
                print(f"  {item['label']}, кумулятивный исторический трафик сохранён: {item['preserved_totals']['total']} байт")
            for item in updated_clients:
                print(f"  {item['label']}, кумулятивный исторический трафик сохранён: {item['preserved_totals']['total']} байт")
        else:
            print("Ни один объект не был изменён, файл состояния не обновлён.")
        for label, reason in skipped_write:
            print(f"Пропущено: {label}, {reason}")
        return 0
    except Exception as exc:
        if conn is not None:
            try:
                conn.rollback()
            except Exception:
                pass
        print(f"Ошибка выполнения: {exc}")
        return 1
    finally:
        if conn is not None:
            conn.close()
        if service_stopped:
            subprocess.run(["systemctl", "start", "x-ui"], check=False)
        quick_health()

def main():
    config = load_config()
    if config is None:
        write_plan_count(0)
        return 1

    if not config.get("enabled", False):
        if dry_run:
            print("================================================")
            print("Предпросмотр сброса")
            print("================================================")
            print(f"Дата: {today.isoformat()}")
            print("Режим: предпросмотр, запись в БД не выполняется")
            print("При реальном выполнении сбрасываются только up/down за текущий месяц; клиенты включаются по логике панели; all_time и total не изменяются.")
            print()
            print("Пользовательский сброс отключён, пропускаем.")
            print("================================================")
        else:
            print("Пользовательский сброс отключён, пропускаем.")
        write_plan_count(0)
        return 0

    state = load_state()
    if state is None:
        write_plan_count(0)
        return 1

    if not db_path.exists():
        print(f"Ошибка: база данных не найдена: {db_path}")
        write_plan_count(0)
        return 1

    try:
        conn = connect_db()
        inbounds, clients = load_db_rows(conn)
        conn.close()
    except Exception as exc:
        print(f"Ошибка чтения БД: {exc}")
        write_plan_count(0)
        return 1

    plan_inbounds, plan_clients, skipped, warnings = build_plan(config, state, inbounds, clients)
    plan_count = len(plan_inbounds) + len(plan_clients)
    write_plan_count(plan_count)

    if dry_run:
        print_preview(plan_inbounds, plan_clients, skipped, warnings)
        return 0

    for warning in warnings:
        print(f"Предупреждение: {warning}")

    if plan_count == 0:
        print("В этом месяце нет объектов для сброса.")
        return 0

    return execute_plan(plan_inbounds, plan_clients, state)

try:
    sys.exit(main())
except KeyboardInterrupt:
    print("Отменено.")
    sys.exit(100)
except Exception as exc:
    print(f"Исключение: {exc}")
    sys.exit(1)
PY
}

run_reset_check_interactive() {
    clear_screen

    local count_file count
    count_file="$(mktemp)"

    set +e
    PLAN_COUNT_FILE="$count_file" DRY_RUN=1 run_reset_engine
    local dry_ret=$?
    set -e

    count="0"
    if [ -f "$count_file" ]; then
        count="$(tr -cd '0-9' < "$count_file")"
    fi
    rm -f "$count_file"
    count="${count:-0}"

    if [ "$dry_ret" -ne 0 ]; then
        echo
        echo "Предпросмотр не удался, запись в БД не выполнялась."
        pause
        return 0
    fi

    if [ "$count" -eq 0 ]; then
        pause
        return 0
    fi

    echo
    local answer
    read -rp "Выполнить сброс согласно предпросмотру? Введите YES для подтверждения: " answer
    if [ "$answer" != "YES" ]; then
        echo "Отменено, запись не выполнялась."
        pause
        return 0
    fi

    echo
    DRY_RUN=0 run_reset_engine
    pause
}

collect_db_ports() {
    if [ ! -f "$XUI_DB" ]; then
        return 0
    fi

    XUI_DB="$XUI_DB" python3 <<'PY' 2>/dev/null || true
import os
import sqlite3

db_path = os.environ["XUI_DB"]
conn = sqlite3.connect(db_path)
cols = [row[1] for row in conn.execute("PRAGMA table_info(inbounds)").fetchall()]
if "port" not in cols:
    raise SystemExit(0)
if "enable" in cols:
    rows = conn.execute("SELECT port FROM inbounds WHERE enable=1").fetchall()
else:
    rows = conn.execute("SELECT port FROM inbounds").fetchall()
for (port,) in rows:
    try:
        port = int(port)
    except Exception:
        continue
    if port > 0:
        print(port)
conn.close()
PY
}

collect_process_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnpH 2>/dev/null \
            | awk '/x-ui|3x-ui/ {print $4}' \
            | awk -F: '{print $NF}' \
            | grep -E '^[0-9]+$' || true
    fi
}

port_is_listening() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
        return $?
    fi

    return 2
}

print_monthly_conflicts() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$XUI_DB" ]; then
        echo "Конфликт monthly: не обнаружен"
        return 0
    fi

    XUI_DB="$XUI_DB" CONFIG_FILE="$CONFIG_FILE" python3 <<'PY' 2>/dev/null || true
import json
import os
import sqlite3

db_path = os.environ["XUI_DB"]
config_path = os.environ["CONFIG_FILE"]

try:
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)
except Exception:
    print("Конфликт monthly: ошибка чтения конфигурации")
    raise SystemExit(0)

enabled_ids = [str(k) for k, v in config.get("inbounds", {}).items() if isinstance(v, dict) and v.get("enabled")]
if not enabled_ids:
    print("Конфликт monthly: не обнаружен")
    raise SystemExit(0)

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
try:
    rows = conn.execute("SELECT id, remark, traffic_reset FROM inbounds").fetchall()
except sqlite3.OperationalError:
    rows = []
conflicts = [row for row in rows if str(row["id"]) in enabled_ids and row["traffic_reset"] == "monthly"]
conn.close()

if not conflicts:
    print("Конфликт monthly: не обнаружен")
else:
    print("Конфликт monthly: обнаружено предупреждение")
    for row in conflicts:
        remark = row["remark"] or "нет примечания"
        if len(remark) > 20:
            remark = remark[:20] + "..."
        print(f"  Входящий ID={row['id']} примечание={remark}")
    print("  Рекомендация: в панели 3x-ui отключите monthly и выберите never/не сбрасывать.")
PY
}

print_health_report() {
    install_runtime_deps

    print_xui_version_warning

    echo "Служба x-ui:"
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        echo -e "  ${GREEN}запущена${PLAIN}"
    else
        echo -e "  ${RED}не запущена${PLAIN}"
    fi

    echo "Файл БД:"
    if [ -f "$XUI_DB" ]; then
        echo -e "  ${GREEN}существует: $XUI_DB${PLAIN}"
        local integrity
        integrity="$(sqlite3 "$XUI_DB" "PRAGMA integrity_check;" 2>&1 || true)"
        if [ "$integrity" = "ok" ]; then
            echo -e "  ${GREEN}целостность: ok${PLAIN}"
        else
            echo -e "  ${RED}целостность нарушена: $integrity${PLAIN}"
        fi
        local schema_result
        if schema_result="$(check_xui_db_schema_readonly 2>&1)"; then
            echo -e "  ${GREEN}совместимость полей: ok${PLAIN}"
        else
            echo -e "  ${RED}совместимость полей: $schema_result${PLAIN}"
        fi
    else
        echo -e "  ${RED}отсутствует: $XUI_DB${PLAIN}"
    fi

    echo "Локальный исполнитель:"
    if [ -x "$LOCAL_RUNNER" ]; then
        echo -e "  ${GREEN}установлен: $LOCAL_RUNNER${PLAIN}"
    else
        echo -e "  ${YELLOW}не установлен: $LOCAL_RUNNER${PLAIN}"
    fi

    echo "xcm:"
    if [ -x "$XCM_PATH" ]; then
        echo -e "  ${GREEN}зарегистрирован: $XCM_PATH${PLAIN}"
    else
        echo -e "  ${YELLOW}не зарегистрирован: $XCM_PATH${PLAIN}"
    fi

    echo "Таймер автоматической проверки:"
    if [ -f "$RESET_TIMER" ]; then
        echo "  Файл: существует"
    else
        echo "  Файл: отсутствует"
    fi
    echo "  enabled: $(timer_enabled_status)"
    echo "  active: $(timer_active_status)"

    echo "Порты прослушивания:"
    local ports=()
    mapfile -t ports < <({ collect_db_ports; collect_process_ports; } | sort -n | uniq)
    if [ "${#ports[@]}" -eq 0 ]; then
        echo "  Не найдены порты входящих из БД."
    else
        local port
        for port in "${ports[@]}"; do
            if port_is_listening "$port"; then
                echo -e "  ${GREEN}$port прослушивается${PLAIN}"
            else
                echo -e "  ${YELLOW}$port не прослушивается, проверьте службу x-ui / xray${PLAIN}"
            fi
        done
    fi

    print_monthly_conflicts

    echo "Ключевые слова в логах:"
    local log_hit=0
    if [ -f "$LOG_FILE" ] && tail -n 100 "$LOG_FILE" | grep -Eiq "panic|error|failed|no such column"; then
        log_hit=1
    fi
    if journalctl -u x-ui -n 100 --no-pager 2>/dev/null | grep -Eiq "panic|error|failed|no such column"; then
        log_hit=1
    fi
    if [ "$log_hit" -eq 1 ]; then
        echo -e "  ${YELLOW}Обнаружены ключевые слова ошибок, перейдите в [5] для просмотра логов.${PLAIN}"
    else
        echo -e "  ${GREEN}Явных ключевых слов ошибок не найдено.${PLAIN}"
    fi

    echo "Режим предпросмотра:"
    echo "  В разделе 'Пользовательская дата сброса -> Предпросмотр и ручной запуск' можно посмотреть план на текущий месяц."
}

run_self_test() {
    local failures=0
    local self_path detected_version

    self_path="$(readlink -f "${BASH_SOURCE[0]}")"

    selftest_pass() {
        echo "PASS: $*"
    }
    selftest_fail() {
        echo "FAIL: $*"
        failures=$((failures + 1))
    }
    selftest_warn() {
        echo "WARN: $*"
    }

    echo "xui-custom-manager самопроверка"
    echo "========================================"

    if bash -n "$self_path"; then
        selftest_pass "текущий скрипт: bash -n пройден"
    else
        selftest_fail "текущий скрипт: bash -n не пройден"
    fi

    if command -v python3 >/dev/null 2>&1; then
        selftest_pass "python3 найден: $(command -v python3)"
    else
        selftest_fail "python3 не найден"
    fi

    if command -v sqlite3 >/dev/null 2>&1; then
        selftest_pass "sqlite3 найден: $(command -v sqlite3)"
    else
        selftest_fail "sqlite3 не найден"
    fi

    detected_version="$(detect_xui_version)"
    echo "Обнаруженная версия 3x-ui: $detected_version"
    echo "Поддерживаемые версии: $(format_supported_version_ranges)"
    if xui_version_is_supported "$detected_version"; then
        selftest_pass "3x-ui версия входит в поддерживаемый диапазон"
    else
        selftest_fail "запись в БД недоступна: текущая версия 3x-ui не поддерживается"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        if command -v python3 >/dev/null 2>&1 && CONFIG_FILE="$CONFIG_FILE" python3 <<'PY'
import json
import os

with open(os.environ["CONFIG_FILE"], "r", encoding="utf-8") as f:
    json.load(f)
PY
        then
            selftest_pass "конфигурационный JSON читается: $CONFIG_FILE"
        else
            selftest_fail "конфигурационный JSON не читается: $CONFIG_FILE"
        fi
    else
        selftest_warn "конфигурационный файл отсутствует, пропуск проверки JSON: $CONFIG_FILE"
    fi

    if [ -f "$XUI_DB" ]; then
        if command -v python3 >/dev/null 2>&1 && XUI_DB="$XUI_DB" python3 <<'PY'
import os
import sqlite3
import sys

db_path = os.environ["XUI_DB"]
conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
try:
    result = conn.execute("PRAGMA integrity_check;").fetchone()[0]
    print(result)
    if result != "ok":
        sys.exit(1)
finally:
    conn.close()
PY
        then
            selftest_pass "БД: integrity_check (только чтение) выполняется: $XUI_DB"
        else
            selftest_fail "БД: integrity_check (только чтение) не выполняется: $XUI_DB"
        fi

        if check_xui_db_schema_readonly; then
            selftest_pass "БД: ключевые поля совместимы"
        else
            selftest_fail "БД: ключевые поля не совместимы"
        fi
    else
        selftest_warn "БД отсутствует, пропуск проверки целостности/схемы: $XUI_DB"
    fi

    if [ -e "$LOCAL_RUNNER" ]; then
        if [ -x "$LOCAL_RUNNER" ]; then
            selftest_pass "LOCAL_RUNNER исполняемый: $LOCAL_RUNNER"
        else
            selftest_fail "LOCAL_RUNNER существует, но не исполняемый: $LOCAL_RUNNER"
        fi
        if bash -n "$LOCAL_RUNNER"; then
            selftest_pass "LOCAL_RUNNER: bash -n пройден"
        else
            selftest_fail "LOCAL_RUNNER: bash -n не пройден"
        fi
    else
        selftest_warn "LOCAL_RUNNER отсутствует: $LOCAL_RUNNER"
    fi

    if [ -e "$XCM_PATH" ]; then
        if [ -x "$XCM_PATH" ]; then
            selftest_pass "XCM_PATH исполняемый: $XCM_PATH"
        else
            selftest_fail "XCM_PATH существует, но не исполняемый: $XCM_PATH"
        fi
        if bash -n "$XCM_PATH"; then
            selftest_pass "XCM_PATH: bash -n пройден"
        else
            selftest_fail "XCM_PATH: bash -n не пройден"
        fi
    else
        selftest_warn "XCM_PATH отсутствует: $XCM_PATH"
    fi

    echo "========================================"
    if [ "$failures" -eq 0 ]; then
        echo "PASS"
        return 0
    fi
    echo "FAIL: $failures ошибок"
    return 1
}

health_check() {
    clear_screen
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧪 x-ui расширенный набор - проверка состояния${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    print_health_report
}

menu_logs() {
    while true; do
        clear_screen
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🧾 x-ui расширенный набор - просмотр логов и ошибок${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: просмотр логов внешнего скрипта, автоматической проверки и службы x-ui.${PLAIN}"
        echo -e "${YELLOW}Подсказка: в логах могут быть записи из старых версий, например ошибки чтения меню.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Просмотр лога скрипта${PLAIN}              ${YELLOW}(/var/log/xui-custom-manager.log)${PLAIN}"
        echo -e "${GREEN}  2. Только записи reset-check${PLAIN}          ${YELLOW}(фильтр по автоматическим проверкам)${PLAIN}"
        echo -e "${GREEN}  3. Просмотр лога таймера${PLAIN}             ${YELLOW}(xui-custom-reset.service)${PLAIN}"
        echo -e "${GREEN}  4. Просмотр лога x-ui${PLAIN}                ${YELLOW}(x-ui.service)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        read_menu_choice choice

        case "$choice" in
            1)
                clear_screen
                echo "Лог скрипта: $LOG_FILE"
                echo "Примечание: здесь могут быть записи из старых версий."
                echo "------------------------------------------------"
                tail -n 100 "$LOG_FILE" || true
                pause
                ;;
            2)
                clear_screen
                echo "reset-check лог: $LOG_FILE"
                echo "------------------------------------------------"
                if [ -f "$LOG_FILE" ]; then
                    local reset_log
                    reset_log="$(awk '
                        /^===== .*reset-check выполнение =====/ { printing=1; print; next }
                        /^===== / && printing { printing=0 }
                        printing { print }
                    ' "$LOG_FILE" | tail -n 120)"
                    if [ -n "$reset_log" ]; then
                        echo "$reset_log"
                    else
                        echo "Нет записей reset-check."
                    fi
                else
                    echo "Файл лога не существует."
                fi
                pause
                ;;
            3)
                clear_screen
                echo "Лог таймера автоматической проверки"
                echo "------------------------------------------------"
                journalctl -u xui-custom-reset.service -n 100 --no-pager || true
                pause
                ;;
            4)
                clear_screen
                echo "Лог службы x-ui"
                echo "------------------------------------------------"
                journalctl -u x-ui -n 100 --no-pager || true
                pause
                ;;
            0|q|Q)
                return 0
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор!${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

menu_backup_restore() {
    while true; do
        clear_screen
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}💾 x-ui расширенный набор - резервирование / восстановление x-ui${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: резервное копирование или восстановление БД, каталогов конфигурации и программы.${PLAIN}"
        echo -e "${YELLOW}Каталог резервных копий: $BACKUP_DIR${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Создать резервную копию${PLAIN}           ${YELLOW}(БД / конфигурация / программа)${PLAIN}"
        echo -e "${GREEN}  2. Восстановить БД${PLAIN}                  ${YELLOW}(x-ui.db)${PLAIN}"
        echo -e "${GREEN}  3. Восстановить каталог программы${PLAIN}    ${YELLOW}(/usr/local/x-ui)${PLAIN}"
        echo -e "${GREEN}  4. Восстановить каталог конфигурации${PLAIN} ${YELLOW}(/etc/x-ui)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        read_menu_choice choice

        case "$choice" in
            1)
                clear_screen
                backup_all
                pause
                ;;
            2)
                restore_backup "db"
                pause
                ;;
            3)
                restore_backup "program"
                pause
                ;;
            4)
                restore_backup "etc"
                pause
                ;;
            0|q|Q)
                return 0
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор!${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

show_quick_guide() {
    clear_screen
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 x-ui расширенный набор - указатель функций${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Выберите то, что вам нужно:${PLAIN}"
    echo "  Настроить разные даты сброса для разных входящих/клиентов -> [1] Пользовательская дата сброса"
    echo "  Посмотреть, кто будет сброшен сегодня, без записи в БД       -> [1] -> [4] Предпросмотр и ручной запуск"
    echo "  Исправить показания использованного трафика в панели        -> [2] Калибровка трафика"
    echo "  Сделать резервную копию или откатить состояние              -> [3] Резервирование / восстановление"
    echo "  Проверить таймер, БД, конфликты monthly                     -> [4] Проверка состояния / monthly"
    echo "  Посмотреть ошибки, логи автоматической проверки или x-ui   -> [5] Просмотр логов и ошибок"
    echo "  Удалить старые резервные копии                             -> [6] Очистка старых копий"
    echo "------------------------------------------------"
    echo "Команды:"
    echo "  xcm                                  открыть это меню"
    echo "  xui-custom-manager.sh --dry-run      только предпросмотр плана сброса"
    echo "  xui-custom-manager.sh --reset-check  выполнить автоматическую проверку сброса"
    echo "------------------------------------------------"
    echo -e "${YELLOW}Важно: перед записью в БД или восстановлением автоматически создаётся резервная копия, и требуется ввод YES.${PLAIN}"
}

main_menu() {
    register_xcm_shortcut

    while true; do
        clear_screen
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}${WHITE}🧭 x-ui расширенный набор${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: дополнение возможностей 3x-ui: пользовательский сброс, калибровка трафика, бэкапы и диагностика.${PLAIN}"
        print_xui_version_warning
        echo -e "${YELLOW}Подсказка: если не знаете, что выбрать, введите ? для индекса; перед записью автоматически создаётся бэкап.${PLAIN}"
        echo -e "${BLUE}------------------------------------------------${PLAIN}"
        echo -e "${CYAN}Конфигурация: ${WHITE}$CONFIG_FILE${PLAIN}"
        echo -e "${CYAN}Бэкапы: ${WHITE}$BACKUP_DIR${PLAIN}"
        echo -e "${CYAN}Лог: ${WHITE}$LOG_FILE${PLAIN}"
        echo -e "${CYAN}Автопроверка: ${GREEN}$(timer_active_status)${PLAIN} ${DIM}|${PLAIN} ${CYAN}Локальный исполнитель: ${GREEN}$(runner_status)${PLAIN} ${DIM}|${PLAIN} ${CYAN}Быстрая команда: ${WHITE}xcm${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}${MAGENTA} ▶ Сброс${PLAIN}"
        echo -e "  ${CYAN}1.${PLAIN} ${GREEN}Пользовательская дата сброса трафика${PLAIN}        ${YELLOW}(входящие / клиенты отдельно)${PLAIN}"
        echo -e "${BOLD}${MAGENTA} ▶ Трафик${PLAIN}"
        echo -e "  ${CYAN}2.${PLAIN} ${GREEN}Калибровка использованного трафика${PLAIN}           ${YELLOW}(меняет up/down, не total)${PLAIN}"
        echo -e "${BOLD}${MAGENTA} ▶ Бэкапы${PLAIN}"
        echo -e "  ${CYAN}3.${PLAIN} ${GREEN}Резервирование / восстановление x-ui${PLAIN}       ${YELLOW}(БД / конфиг / программа)${PLAIN}"
        echo -e "${BOLD}${MAGENTA} ▶ Диагностика${PLAIN}"
        echo -e "  ${CYAN}4.${PLAIN} ${GREEN}Проверка состояния / monthly конфликты${PLAIN}    ${YELLOW}(служба / БД / таймер)${PLAIN}"
        echo -e "  ${CYAN}5.${PLAIN} ${GREEN}Просмотр логов и ошибок${PLAIN}                     ${YELLOW}(скрипт / reset-check / systemd)${PLAIN}"
        echo -e "  ${CYAN}6.${PLAIN} ${GREEN}Очистка старых резервных копий${PLAIN}             ${YELLOW}(удаление по одному файлу)${PLAIN}"
        echo -e "${BLUE}------------------------------------------------${PLAIN}"
        echo -e "  ${BLUE}?.${PLAIN} ${WHITE}Индекс функций / что мне нужно${PLAIN}"
        echo -e "${RED}  0. Выход / q вернуться на уровень выше${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        read_menu_choice choice "👉 Введите номер / ? для индекса / q для выхода: "

        case "$choice" in
            "?"|help|HELP|помощь)
                show_quick_guide
                pause
                ;;
            1)
                run_custom_reset_ui
                ;;
            2)
                run_traffic_ui
                ;;
            3)
                menu_backup_restore
                ;;
            4)
                health_check
                pause
                ;;
            5)
                menu_logs
                ;;
            6)
                cleanup_backups
                pause
                ;;
            0|q|Q)
                clear_screen
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор!${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

if [ "$SELF_TEST" -eq 1 ]; then
    run_self_test
elif [ "$RUN_CHECK" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    run_reset_engine
else
    require_interactive_menu || exit 1
    main_menu
fi
