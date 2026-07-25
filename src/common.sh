# shellcheck shell=bash
# Общие константы, определение платформы, помощники пакетов и удалённых скриптов.

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
PLAIN='\033[0m'
BOLD='\033[1m'

SCRIPT_VERSION="v2.5"
UPDATE_URL="https://raw.githubusercontent.com/sacredx72/VPS-Optimize/main/dist/vps.sh"
UPDATE_SHA256_URL="${UPDATE_URL}.sha256"
SCRIPT_UPDATE_CACHE="/etc/vps-optimize/update-check.cache"
TRAFFIC_GUARD_CONFIG="/etc/vps-optimize/traffic-guard.conf"
TRAFFIC_GUARD_CHECKER="/usr/local/bin/vps-traffic-guard-check"
TRAFFIC_GUARD_STATE_DIR="/var/lib/vps-optimize/traffic-guard"
TRAFFIC_GUARD_LOG="/var/log/vps-traffic-guard.log"
DNS_OPTIMIZE_BACKUP_DIR="/etc/vps-optimize/backups/dns"
DNS_OPTIMIZE_RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf"
VPSO_DEFAULT_LOG_MAX_BYTES=$((5 * 1024 * 1024))
VPSO_DEFAULT_LOG_ROTATE_KEEP=3

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS=$ID
    OS_LIKE=${ID_LIKE:-""}
else
    OS="unknown"
    OS_LIKE="unknown"
fi

APT_UPDATED=0

is_debian() {
    [[ "$OS" =~ debian|ubuntu ]] || [[ "$OS_LIKE" =~ debian|ubuntu ]]
}

is_redhat() {
    [[ "$OS" =~ centos|rhel|rocky|almalinux|fedora ]] || [[ "$OS_LIKE" =~ centos|rhel|fedora ]]
}

apt_update_once() {
    [[ "$APT_UPDATED" == "1" ]] && return 0
    apt-get update -qq >/dev/null 2>&1 && APT_UPDATED=1
}

file_size_bytes() {
    local file="$1"
    local size
    [[ -e "$file" ]] || { echo 0; return 0; }
    size=$(wc -c < "$file" 2>/dev/null | awk '{print $1}')
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    echo "$size"
}

format_bytes() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    awk -v b="$bytes" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b = b / 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]
        else printf "%.2f %s", b, u[i]
    }'
}

# Лёгкая ротация логов по размеру файла.
# Не создаёт новый файл после mv; демоны с открытым fd нуждаются в journald,
# reload/restart или коде, который умеет переоткрывать файлы.
rotate_log_file() {
    local log_file="$1"
    local max_bytes="${2:-$VPSO_DEFAULT_LOG_MAX_BYTES}"
    local keep="${3:-$VPSO_DEFAULT_LOG_ROTATE_KEEP}"
    local size i old_path new_path

    [[ -n "$log_file" && -f "$log_file" ]] || return 0
    [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes="$VPSO_DEFAULT_LOG_MAX_BYTES"
    [[ "$keep" =~ ^[0-9]+$ ]] || keep="$VPSO_DEFAULT_LOG_ROTATE_KEEP"
    (( max_bytes > 0 && keep > 0 )) || return 0

    size=$(file_size_bytes "$log_file")
    (( size >= max_bytes )) || return 0

    rm -f "${log_file}.${keep}" 2>/dev/null || true
    for ((i = keep - 1; i >= 1; i--)); do
        old_path="${log_file}.${i}"
        new_path="${log_file}.$((i + 1))"
        [[ -e "$old_path" ]] && mv -f "$old_path" "$new_path" 2>/dev/null || true
    done
    mv -f "$log_file" "${log_file}.1" 2>/dev/null || true
}

pkg_log_file() {
    local action="${1:-pkg}"
    local log_dir="/var/log/vps-optimize"

    if mkdir -p "$log_dir" 2>/dev/null && [[ -w "$log_dir" ]]; then
        mktemp "${log_dir}/pkg-${action}.XXXXXX.log"
    else
        mktemp "/tmp/vps-optimize-pkg-${action}.XXXXXX.log"
    fi
}

print_pkg_failure_log() {
    local action="$1"
    local log_file="$2"
    shift 2
    echo -e "${RED}❌ Ошибка ${action} пакета(ов): $*${PLAIN}"
    echo -e "${YELLOW}Лог: ${log_file}${PLAIN}"
    if [[ -s "$log_file" ]]; then
        echo -e "${YELLOW}Последние 20 строк:${PLAIN}"
        tail -n 20 "$log_file" 2>/dev/null || true
    else
        echo -e "${YELLOW}Лог пуст. Возможно, пакетный менеджер не запустился или система не поддерживает эту операцию.${PLAIN}"
    fi
}

install_pkg() {
    local pkgs=("$@")
    local rc=0 log_file
    [[ ${#pkgs[@]} -gt 0 ]] || return 0
    log_file=$(pkg_log_file install) || return 1
    if is_debian; then
        # Используем apt-get вместо apt, чтобы убрать предупреждение "stable CLI interface"
        export DEBIAN_FRONTEND=noninteractive
        apt_update_once >>"$log_file" 2>&1 || true
        apt-get install -y -qq "${pkgs[@]}" >>"$log_file" 2>&1
        rc=$?
        unset DEBIAN_FRONTEND
    elif is_redhat; then
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y -q "${pkgs[@]}" >>"$log_file" 2>&1
        else
            yum install -y -q "${pkgs[@]}" >>"$log_file" 2>&1
        fi
        rc=$?
    else
        echo -e "${RED}❌ Текущая система не поддерживает автоматическую установку пакетов: OS=${OS:-unknown} ID_LIKE=${OS_LIKE:-unknown}${PLAIN}"
        rm -f "$log_file"
        return 1
    fi
    if [[ "$rc" -eq 0 ]]; then
        rm -f "$log_file"
    else
        print_pkg_failure_log "установки" "$log_file" "${pkgs[@]}"
    fi
    return "$rc"
}

remove_pkg() {
    local pkgs=("$@")
    local rc=0 log_file
    [[ ${#pkgs[@]} -gt 0 ]] || return 0
    log_file=$(pkg_log_file remove) || return 1
    if is_debian; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y -qq "${pkgs[@]}" >>"$log_file" 2>&1
        rc=$?
        unset DEBIAN_FRONTEND
    elif is_redhat; then
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y -q "${pkgs[@]}" >>"$log_file" 2>&1
        else
            yum remove -y -q "${pkgs[@]}" >>"$log_file" 2>&1
        fi
        rc=$?
    else
        echo -e "${RED}❌ Текущая система не поддерживает автоматическое удаление пакетов: OS=${OS:-unknown} ID_LIKE=${OS_LIKE:-unknown}${PLAIN}"
        rm -f "$log_file"
        return 1
    fi
    if [[ "$rc" -eq 0 ]]; then
        rm -f "$log_file"
    else
        print_pkg_failure_log "удаления" "$log_file" "${pkgs[@]}"
    fi
    return "$rc"
}

minimal_compat_packages() {
    if is_debian; then
        printf '%s\n' \
            ca-certificates curl wget gnupg gpg lsb-release apt-transport-https debian-archive-keyring \
            sudo bash coreutils findutils grep sed gawk util-linux git nano htop lsof net-tools iputils-ping dnsutils \
            iproute2 iptables procps psmisc cron dbus chrony jq unzip tar gzip openssl
    elif is_redhat; then
        printf '%s\n' \
            ca-certificates curl wget gnupg2 redhat-lsb-core iproute iptables procps-ng psmisc cronie \
            sudo bash coreutils findutils grep sed gawk util-linux git nano htop lsof net-tools iputils bind-utils \
            dbus chrony jq unzip tar gzip openssl
    fi
}

ensure_minimal_system_compat() {
    local pkgs=()
    local pkg

    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && pkgs+=("$pkg")
    done < <(minimal_compat_packages)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        echo -e "${CYAN}▶ Дополняю минимальные компоненты совместимости системы...${PLAIN}"
        if install_pkg "${pkgs[@]}"; then
            echo -e "${GREEN}✅ Минимальные компоненты совместимости проверены/установлены.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Часть компонентов не установилась. Проверьте репозитории или сеть.${PLAIN}"
            echo -e "${CYAN}▶ Перехожу к установке по одному, чтобы повысить совместимость...${PLAIN}"
            for pkg in "${pkgs[@]}"; do
                install_pkg "$pkg" || echo -e "${YELLOW}  - Пропущен недоступный компонент: ${pkg}${PLAIN}"
            done
        fi
    fi

    systemctl enable --now cron >/dev/null 2>&1 || true
    systemctl enable --now crond >/dev/null 2>&1 || true
    systemctl enable --now dbus >/dev/null 2>&1 || true
    systemctl enable --now chrony >/dev/null 2>&1 || true
    systemctl enable --now chronyd >/dev/null 2>&1 || true
    update-ca-certificates >/dev/null 2>&1 || update-ca-trust >/dev/null 2>&1 || true
}

is_vps_optimize_generated_script() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -Fq "Project:  VPS Optimize" "$file" || return 1
    grep -Fq "Generated: scripts/build.sh" "$file" || return 1
    grep -Fq "VPS 全能控制面板" "$file" || return 1
    grep -Fq "main_menu" "$file" || return 1
}

copy_shortcut_candidate() {
    local source_file="$1"
    local target_file="$2"
    local label="$3"
    local target_dir tmp_file

    if ! is_vps_optimize_generated_script "$source_file" || ! bash -n "$source_file" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ${label} не прошёл проверку идентификатора VPS-Optimize. Регистрация ярлыка отклонена.${PLAIN}"
        return 1
    fi
    target_dir=$(dirname "$target_file")
    mkdir -p "$target_dir" 2>/dev/null || return 1
    tmp_file=$(mktemp "${target_file}.XXXXXX") || return 1
    if ! cp "$source_file" "$tmp_file" 2>/dev/null \
        || ! chmod +x "$tmp_file" \
        || ! mv -f "$tmp_file" "$target_file"; then
        rm -f "$tmp_file"
        return 1
    fi
}

script_version_from_file() {
    local file="$1"
    local line version
    line=$(grep -m1 '^SCRIPT_VERSION=' "$file" 2>/dev/null || true)
    version="${line#SCRIPT_VERSION=}"
    version="${version%\"}"
    version="${version#\"}"
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

download_verified_update_script() {
    local output_file="$1"
    local sha_file
    sha_file=$(mktemp /tmp/cy_update.XXXXXX.sha256) || return 1
    if download_remote_script "$UPDATE_URL" "$output_file" \
        && bash -n "$output_file" >/dev/null 2>&1 \
        && is_vps_optimize_generated_script "$output_file" \
        && download_remote_script "$UPDATE_SHA256_URL" "$sha_file" \
        && verify_file_sha256 "$output_file" "$sha_file" >/dev/null; then
        rm -f "$sha_file"
        return 0
    fi
    rm -f "$sha_file" "$output_file"
    return 1
}

sync_shortcut_from_newer_current_script() {
    local current_file="$1"
    local shortcut_file="$2"
    local current_version shortcut_version

    [[ -f "$current_file" && -f "$shortcut_file" ]] || return 1
    is_vps_optimize_generated_script "$current_file" || return 1
    current_version=$(script_version_from_file "$current_file" 2>/dev/null || true)
    shortcut_version=$(script_version_from_file "$shortcut_file" 2>/dev/null || true)
    [[ -n "$current_version" && -n "$shortcut_version" ]] || return 1
    declare -F version_is_newer >/dev/null 2>&1 || return 1
    version_is_newer "$current_version" "$shortcut_version" || return 1
    copy_shortcut_candidate "$current_file" "$shortcut_file" "текущий скрипт"
}

create_shortcut() {
    local script_path="${VPSO_SHORTCUT_PATH:-/usr/local/bin/cy}"
    local release_path current_file candidate_file
    current_file="${VPSO_CURRENT_SCRIPT_PATH:-$(readlink -f "$0" 2>/dev/null || true)}"

    if [[ -f "$script_path" ]] \
        && is_vps_optimize_generated_script "$script_path" \
        && bash -n "$script_path" >/dev/null 2>&1; then
        if sync_shortcut_from_newer_current_script "$current_file" "$script_path"; then
            echo -e "${GREEN}✅ Ярлык 'cy' синхронизирован с более новой версией.${PLAIN}"
            sleep 1
        fi
        return 0
    fi

    if [[ -f "$script_path" ]]; then
        quarantine_path "$script_path" "/tmp/vps-optimize-quarantine" >/dev/null 2>&1 || return 1
        echo -e "${YELLOW}⚠️ Недействительный старый ярлык изолирован. Выполняется повторная регистрация.${PLAIN}"
    fi

    candidate_file=$(mktemp /tmp/cy_shortcut.XXXXXX.sh) || return 1
    if ! download_verified_update_script "$candidate_file" 2>/dev/null; then
        rm -f "$candidate_file"
        candidate_file=$(mktemp /tmp/cy_shortcut.XXXXXX.sh) || return 1
        if {
            release_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/dist/vps.sh"
            if [[ -f "$release_path" ]]; then
                cp "$release_path" "$candidate_file"
            elif [[ -f "$current_file" ]]; then
                cp "$current_file" "$candidate_file"
            else
                false
            fi
        }; then
            :
        else
            rm -f "$candidate_file"
            echo -e "${YELLOW}⚠️ Регистрация ярлыка отложена. Позже выполните обновление скрипта в главном меню [17].${PLAIN}"
            return 1
        fi
    fi

    if ! copy_shortcut_candidate "$candidate_file" "$script_path" "кандидат ярлыка"; then
        rm -f "$candidate_file"
        echo -e "${YELLOW}⚠️ Не удалось зарегистрировать ярлык. Проверьте права на /usr/local/bin.${PLAIN}"
        return 1
    fi
    rm -f "$candidate_file"
    echo -e "${GREEN}✅ Ярлык 'cy' зарегистрирован глобально! Теперь можно вызывать панель командой cy.${PLAIN}"
    sleep 1
}

run_safe() {
    local desc="$1"
    shift
    echo -e "${CYAN}▶ Выполняется: ${desc}...${PLAIN}"
    # Отбрасываем обычный вывод, оставляем ошибки. При неудаче — останавливаемся и предупреждаем.
    if "$@" >/dev/null; then
        echo -e "${GREEN}✅ ${desc} — успешно!${PLAIN}"
    else
        echo -e "${RED}❌ ${desc} — ошибка! Проверьте сеть или источники зависимостей.${PLAIN}"
        return 1
    fi
}

restart_service_if_available() {
    local svc="$1"
    command -v systemctl >/dev/null 2>&1 || return 2
    if systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q . || systemctl list-units "${svc}.service" --no-legend 2>/dev/null | grep -q .; then
        systemctl restart "$svc" >/dev/null 2>&1
    else
        return 2
    fi
}

download_remote_script() {
    local url="$1"
    local output_file="$2"
    local downloaded=1
    local local_file

    if [[ "$url" == file://* ]]; then
        local_file="${url#file://}"
        if [[ -f "$local_file" ]] && cp "$local_file" "$output_file" 2>/dev/null; then
            return 0
        fi
        echo -e "${RED}❌ Локальный файл скрипта недоступен для чтения: ${local_file}${PLAIN}"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Отсутствуют curl/wget. Пытаюсь автоматически установить инструменты загрузки...${PLAIN}"
        install_pkg curl wget >/dev/null 2>&1 || true
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --retry-delay 1 --retry-connrefused "$url" -o "$output_file"; then
            downloaded=0
        fi
    fi
    if [[ "$downloaded" -ne 0 ]] && command -v wget >/dev/null 2>&1; then
        if wget -q --timeout=15 --tries=3 -O "$output_file" "$url"; then
            downloaded=0
        fi
    fi

    if [[ "$downloaded" -ne 0 ]]; then
        echo -e "${RED}❌ Не удалось скачать удалённый скрипт. Проверьте сеть, DNS или доступность GitHub.${PLAIN}"
        return 1
    fi
    [[ -s "$output_file" ]]
}

verify_file_sha256() {
    local file="$1"
    local checksum_file="$2"
    local expected check_file

    expected=$(awk 'NR == 1 {print $1}' "$checksum_file" 2>/dev/null | tr 'A-F' 'a-f')
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo -e "${RED}❌ Неверный формат файла sha256: ${checksum_file}${PLAIN}"
        return 1
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        echo -e "${RED}❌ В системе отсутствует sha256sum, проверка обновления невозможна.${PLAIN}"
        return 1
    fi

    check_file=$(mktemp /tmp/cy_update_check.XXXXXX.sha256) || return 1
    printf '%s  %s\n' "$expected" "$file" > "$check_file"
    if ! sha256sum -c "$check_file" >/dev/null 2>&1; then
        rm -f "$check_file"
        echo -e "${RED}❌ Проверка sha256 не пройдена. Перезапись /usr/local/bin/cy отклонена.${PLAIN}"
        return 1
    fi
    rm -f "$check_file"

    echo -e "${GREEN}✅ Проверка sha256 пройдена.${PLAIN}"
}

is_trusted_remote_script_url() {
    local url="$1"
    case "$url" in
        "https://raw.githubusercontent.com/sacredx72/VPS-Optimize/main/dog.sh"|\
        "https://raw.githubusercontent.com/sacredx72/VPS-Optimize/main/xui-custom-manager.sh")
            echo "Скрипт обслуживания проекта VPS-Optimize"
            return 0
            ;;
        "https://get.docker.com")
            echo "Официальный скрипт установки Docker"
            return 0
            ;;
        "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"|\
        "https://raw.githubusercontent.com/mhsanaei/3x-ui/v2.9.4/install.sh")
            echo "Официальный скрипт установки 3x-ui"
            return 0
            ;;
        "https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh")
            echo "Официальный скрипт установки S-UI"
            return 0
            ;;
        "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh")
            echo "Официальный скрипт установки EasyTier"
            return 0
            ;;
        "https://tailscale.com/install.sh")
            echo "Официальный скрипт установки Tailscale"
            return 0
            ;;
        "https://github.com/233boy/sing-box/raw/main/install.sh"|\
        "https://github.com/233boy/Xray/raw/main/install.sh")
            echo "Официальный скрипт 233boy"
            return 0
            ;;
        "https://yabs.sh"|\
        "https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh"|\
        "https://about.superbench.pro"|\
        "https://bench.sh"|\
        "https://check.unlock.media"|\
        "https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh"|\
        "https://IP.Check.Place"|\
        "https://run.NodeQuality.com"|\
        "https://raw.githubusercontent.com/lx969788249/lxspacepy/master/pyinstall.sh"|\
        "https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh"|\
        "https://raw.githubusercontent.com/qqrrooty/EZgost/main/gost.sh"|\
        "https://raw.githubusercontent.com/Aurora-Admin-Panel/deploy/main/install.sh"|\
        "https://us.arloor.dev/https://github.com/arloor/nftables-nat-rust/releases/download/v2.0.0/setup.sh"|\
        "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"|\
        "https://git.io/aria2.sh"|\
        "http://v7.hostcli.com/install/install-ubuntu_6.0.sh"|\
        "https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/build_backend.sh"|\
        "https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh"|\
        "https://raw.githubusercontent.com/poouo/Forwardx/main/scripts/install-panel-local.sh"|\
        "https://raw.githubusercontent.com/Sagit-chu/flvx/main/panel_install.sh"|\
        "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh"|\
        "https://raw.githubusercontent.com/Jimmyzxk/DNS-Alice-Unlock/refs/heads/main/dns-unlock.sh"|\
        "https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh")
            echo "Встроенный жёстко заданный внешний источник скрипта"
            return 0
            ;;
    esac
    return 1
}

confirm_remote_script_execution() {
    local confirm

    if declare -F read_trimmed >/dev/null 2>&1; then
        read_trimmed confirm "Продолжить загрузку и выполнение удалённого скрипта? (y/N): "
    else
        read -r -p "Продолжить загрузку и выполнение удалённого скрипта? (y/N): " confirm
    fi
    confirm="${confirm:-no}"
    if declare -F is_yes >/dev/null 2>&1; then
        is_yes "$confirm"
    else
        [[ "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]
    fi
}

run_remote_script() {
    local desc="$1"
    local url="$2"
    shift 2
    local tmp_file rc trusted_source
    echo -e "${CYAN}▶ ${desc}${PLAIN}"
    echo -e "${YELLOW}Источник скрипта: ${url}${PLAIN}"
    if trusted_source=$(is_trusted_remote_script_url "$url"); then
        echo -e "${GREEN}Известный встроенный источник: ${trusted_source}${PLAIN}"
    else
        trusted_source=""
        echo -e "${RED}⚠️ Неизвестный источник: этот URL отсутствует в белом списке удалённых скриптов VPS-Optimize.${PLAIN}"
    fi
    if [[ "$url" != https://* && "$url" != file://* ]]; then
        echo -e "${RED}❌ Источник не HTTPS. Загрузка и выполнение отклонены.${PLAIN}"
        return 1
    fi

    if [[ -z "$trusted_source" || "${VPSO_REMOTE_SCRIPT_CONFIRM:-1}" != "0" ]]; then
        confirm_remote_script_execution || return 1
    fi

    tmp_file=$(mktemp /tmp/vps-remote.XXXXXX.sh) || {
        echo -e "${RED}❌ Не удалось создать временный файл. Выполнение отменено.${PLAIN}"
        return 1
    }
    if ! download_remote_script "$url" "$tmp_file"; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Ошибка загрузки. Проверьте сеть или источник скрипта.${PLAIN}"
        return 1
    fi
    if ! bash -n "$tmp_file" >/dev/null 2>&1; then
        echo -e "${RED}❌ Удалённый скрипт не прошёл проверку синтаксиса Bash. Выполнение прервано.${PLAIN}"
        echo -e "${YELLOW}Файл сохранён для разбора: ${tmp_file}${PLAIN}"
        return 1
    fi

    chmod +x "$tmp_file"
    bash "$tmp_file" "$@"
    rc=$?
    rm -f "$tmp_file"
    return "$rc"
}

pause_after_external_script() {
    local prompt="${1:-Нажмите Enter для продолжения...}"
    local junk

    if [[ -r /dev/tty ]]; then
        while IFS= read -r -s -n 1 -t 0.05 junk < /dev/tty; do :; done
        read -r -p "$prompt" junk < /dev/tty
    else
        read -r -p "$prompt" junk
    fi
}

install_acme_sh() {
    local acme_email="$1"
    local tmp_file rc
    tmp_file=$(mktemp /tmp/vps-acme.XXXXXX.sh)
    echo -e "${CYAN}▶ Устанавливаю acme.sh...${PLAIN}"
    if ! download_remote_script "https://get.acme.sh" "$tmp_file"; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Не удалось скачать скрипт установки acme.sh.${PLAIN}"
        return 1
    fi
    if ! sh -n "$tmp_file" >/dev/null 2>&1; then
        echo -e "${RED}❌ Скрипт установки acme.sh не прошёл проверку синтаксиса sh. Выполнение прервано.${PLAIN}"
        echo -e "${YELLOW}Файл сохранён для разбора: ${tmp_file}${PLAIN}"
        return 1
    fi
    sh "$tmp_file" "email=${acme_email}" >/dev/null 2>&1
    rc=$?
    rm -f "$tmp_file"
    return "$rc"
}
