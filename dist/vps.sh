#!/usr/bin/env bash

# =========================================================
#  Project:  VPS Optimize
#  Generated: scripts/build.sh
#  Source modules: src/*.sh
#  Compatibility marker: VPS 全能控制面板
# =========================================================

# ---------------------------------------------------------
# Module: common.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Общие константы, определение платформы, вспомогательные функции для пакетов и удалённых скриптов.

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

# Лёгкая ротация логов по размеру для файлов, в которые пишут вспомогательные скрипты.
# Намеренно не создаёт новый файл после mv; демоны, держащие открытый fd, требуют journald,
# перезагрузки/рестарта или кода, умеющего переоткрывать файлы.
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
    echo -e "${RED}❌ Ошибка ${action} пакета: $*${PLAIN}"
    echo -e "${YELLOW}Лог: ${log_file}${PLAIN}"
    if [[ -s "$log_file" ]]; then
        echo -e "${YELLOW}Последние 20 строк:${PLAIN}"
        tail -n 20 "$log_file" 2>/dev/null || true
    else
        echo -e "${YELLOW}Лог пуст, возможно, менеджер пакетов не запустился или система не поддерживает операцию.${PLAIN}"
    fi
}

install_pkg() {
    local pkgs=("$@")
    local rc=0 log_file
    [[ ${#pkgs[@]} -gt 0 ]] || return 0
    log_file=$(pkg_log_file install) || return 1
    if is_debian; then
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
        echo -e "${RED}❌ Автоматическая установка пакетов не поддерживается на текущей системе: OS=${OS:-unknown} ID_LIKE=${OS_LIKE:-unknown}${PLAIN}"
        rm -f "$log_file"
        return 1
    fi
    if [[ "$rc" -eq 0 ]]; then
        rm -f "$log_file"
    else
        print_pkg_failure_log "установка" "$log_file" "${pkgs[@]}"
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
        echo -e "${RED}❌ Автоматическое удаление пакетов не поддерживается на текущей системе: OS=${OS:-unknown} ID_LIKE=${OS_LIKE:-unknown}${PLAIN}"
        rm -f "$log_file"
        return 1
    fi
    if [[ "$rc" -eq 0 ]]; then
        rm -f "$log_file"
    else
        print_pkg_failure_log "удаление" "$log_file" "${pkgs[@]}"
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
        echo -e "${CYAN}▶ Установка минимальных совместимых компонентов...${PLAIN}"
        if install_pkg "${pkgs[@]}"; then
            echo -e "${GREEN}✅ Минимальные совместимые компоненты проверены/установлены.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Некоторые компоненты не установились, проверьте источники пакетов или сеть.${PLAIN}"
            echo -e "${CYAN}▶ Повторная установка по одному для повышения совместимости...${PLAIN}"
            for pkg in "${pkgs[@]}"; do
                install_pkg "$pkg" || echo -e "${YELLOW}  - Пропуск неустановимого компонента: ${pkg}${PLAIN}"
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
        echo -e "${YELLOW}⚠️ ${label} не прошёл проверку идентификатора VPS-Optimize, регистрация ярлыка отклонена.${PLAIN}"
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
            echo -e "${GREEN}✅ Ярлык 'cy' синхронизирован с текущей новой версией.${PLAIN}"
            sleep 1
        fi
        return 0
    fi

    if [[ -f "$script_path" ]]; then
        quarantine_path "$script_path" "/tmp/vps-optimize-quarantine" >/dev/null 2>&1 || return 1
        echo -e "${YELLOW}⚠️ Недействительный старый ярлык изолирован, выполняется перерегистрация.${PLAIN}"
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
            echo -e "${YELLOW}⚠️ Регистрация ярлыка отложена, выполните обновление скрипта через [17] для завершения.${PLAIN}"
            return 1
        fi
    fi

    if ! copy_shortcut_candidate "$candidate_file" "$script_path" "скрипт-кандидат для ярлыка"; then
        rm -f "$candidate_file"
        echo -e "${YELLOW}⚠️ Не удалось зарегистрировать ярлык, проверьте права на /usr/local/bin.${PLAIN}"
        return 1
    fi
    rm -f "$candidate_file"
    echo -e "${GREEN}✅ Ярлык 'cy' зарегистрирован глобально! Теперь можно вызвать панель командой cy.${PLAIN}"
    sleep 1
}

run_safe() {
    local desc="$1"
    shift
    echo -e "${CYAN}▶ Выполняется: ${desc}...${PLAIN}"
    # Отбрасываем нормальный вывод, сохраняем ошибки; при ошибке прерываем и предупреждаем
    if "$@" >/dev/null; then
        echo -e "${GREEN}✅ ${desc} - успешно!${PLAIN}"
    else
        echo -e "${RED}❌ ${desc} - ошибка! Проверьте сеть или источники пакетов.${PLAIN}"
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
        echo -e "${RED}❌ Локальный файл скрипта нечитаем: ${local_file}${PLAIN}"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Отсутствует curl/wget, попытка автоматической установки...${PLAIN}"
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
        echo -e "${RED}❌ Не удалось загрузить удалённый скрипт, проверьте сеть, DNS или доступ к GitHub.${PLAIN}"
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
        echo -e "${RED}❌ В системе отсутствует sha256sum, невозможно проверить обновление.${PLAIN}"
        return 1
    fi

    check_file=$(mktemp /tmp/cy_update_check.XXXXXX.sha256) || return 1
    printf '%s  %s\n' "$expected" "$file" > "$check_file"
    if ! sha256sum -c "$check_file" >/dev/null 2>&1; then
        rm -f "$check_file"
        echo -e "${RED}❌ Ошибка проверки sha256, замена /usr/local/bin/cy отклонена.${PLAIN}"
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
            echo "Сопровождаемый скрипт проекта VPS-Optimize"
            return 0
            ;;
        "https://get.docker.com")
            echo "Официальный установочный скрипт Docker"
            return 0
            ;;
        "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"|\
        "https://raw.githubusercontent.com/mhsanaei/3x-ui/v2.9.4/install.sh")
            echo "Официальный установочный скрипт 3x-ui"
            return 0
            ;;
        "https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh")
            echo "Официальный установочный скрипт S-UI"
            return 0
            ;;
        "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh")
            echo "Официальный установочный скрипт EasyTier"
            return 0
            ;;
        "https://tailscale.com/install.sh")
            echo "Официальный установочный скрипт Tailscale"
            return 0
            ;;
        "https://github.com/233boy/sing-box/raw/main/install.sh"|\
        "https://github.com/233boy/Xray/raw/main/install.sh")
            echo "Официальный установочный скрипт 233boy"
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
            echo "Встроенный внешний скрипт проекта"
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
        echo -e "${GREEN}Известный источник: ${trusted_source}${PLAIN}"
    else
        trusted_source=""
        echo -e "${RED}⚠️ Неизвестный источник: URL отсутствует в белом списке VPS-Optimize.${PLAIN}"
    fi
    if [[ "$url" != https://* && "$url" != file://* ]]; then
        echo -e "${RED}❌ Источник не является HTTPS, загрузка и выполнение отклонены.${PLAIN}"
        return 1
    fi

    if [[ -z "$trusted_source" || "${VPSO_REMOTE_SCRIPT_CONFIRM:-1}" != "0" ]]; then
        confirm_remote_script_execution || return 1
    fi

    tmp_file=$(mktemp /tmp/vps-remote.XXXXXX.sh) || {
        echo -e "${RED}❌ Не удалось создать временный файл, выполнение отменено.${PLAIN}"
        return 1
    }
    if ! download_remote_script "$url" "$tmp_file"; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Ошибка загрузки, проверьте сеть или источник.${PLAIN}"
        return 1
    fi
    if ! bash -n "$tmp_file" >/dev/null 2>&1; then
        echo -e "${RED}❌ Удалённый скрипт не прошёл синтаксическую проверку Bash, выполнение прервано.${PLAIN}"
        echo -e "${YELLOW}Загруженный файл сохранён для диагностики: ${tmp_file}${PLAIN}"
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
    echo -e "${CYAN}▶ Установка acme.sh...${PLAIN}"
    if ! download_remote_script "https://get.acme.sh" "$tmp_file"; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Не удалось загрузить установочный скрипт acme.sh.${PLAIN}"
        return 1
    fi
    if ! sh -n "$tmp_file" >/dev/null 2>&1; then
        echo -e "${RED}❌ Установочный скрипт acme.sh не прошёл синтаксическую проверку sh, выполнение прервано.${PLAIN}"
        echo -e "${YELLOW}Загруженный файл сохранён для диагностики: ${tmp_file}${PLAIN}"
        return 1
    fi
    sh "$tmp_file" "email=${acme_email}" >/dev/null 2>&1
    rc=$?
    rm -f "$tmp_file"
    return "$rc"
}

# ---------------------------------------------------------
# Module: ui.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Вспомогательные функции для вывода UI и подтверждений.

print_breadcrumb() {
    echo -e "${CYAN}VPS-Optimize > $*${PLAIN}"
}

pause_return() {
    local prompt="${1:-Нажмите любую клавишу для продолжения...}"
    read -n 1 -s -r -p "$prompt"
    echo ""
}

confirm_danger() {
    local title="$1"
    local impact="$2"
    local rollback="$3"
    local advice="${4:-}"
    local snapshot_advice="${5:-Рекомендуется создать снимок VPS или убедиться в наличии консоли восстановления у провайдера.}"
    local confirm
    echo -e "${RED}⚠️ Операция с высоким риском: ${title}${PLAIN}"
    echo ""
    echo -e "${YELLOW}Название операции: ${PLAIN}${title}"
    echo -e "${YELLOW}Что будет изменено: ${PLAIN}"
    echo -e "- ${impact}"
    echo ""
    echo -e "${YELLOW}Возможные риски: ${PLAIN}"
    echo "- Неудачная операция может привести к временной недоступности SSH, панелей, прокси, сертификатов, контейнеров или сети."
    echo "- Несоответствие настроек безопасности облачного провайдера, брандмауэра, адресов прослушивания или сертификатов может привести к потере удалённого доступа."
    echo ""
    echo -e "${BLUE}Способы восстановления: ${PLAIN}"
    echo -e "- ${rollback}"
    echo "- Использовать текущую неразорванную SSH-сессию для восстановления конфигурации."
    echo "- Использовать консоль облачного провайдера, VNC или режим восстановления."
    echo "- Использовать резервное копирование и откат для восстановления сохранённых конфигураций."
    echo ""
    echo -e "${CYAN}Рекомендуется ли создать снимок: ${PLAIN}${snapshot_advice}"
    echo -e "${CYAN}Рекомендации: ${PLAIN}"
    echo "- Создан снимок VPS."
    echo "- Проверены правила безопасности облачного провайдера и системного брандмауэра."
    echo "- Текущая SSH-сессия не будет закрыта."
    [[ -n "$advice" ]] && echo -e "- ${advice}"
    echo ""
    read_trimmed confirm "Для продолжения введите yes, Enter для отмены (регистр не важен): "
    is_yes "$confirm"
}

confirm_risk_action() {
    confirm_danger "$@"
}

render_menu() {
    local items_name="$1"
    local -n menu_items="$items_name"
    local item number title description handler risk

    for item in "${menu_items[@]}"; do
        IFS='|' read -r number title description handler risk <<< "$item"
        echo -e "${GREEN}  ${number}. ${title}${PLAIN}   ${YELLOW}(${description})${PLAIN}"
    done
}

dispatch_menu_choice() {
    local choice="$1"
    local items_name="$2"
    local -n menu_items="$items_name"
    local item number title description handler risk

    for item in "${menu_items[@]}"; do
        IFS='|' read -r number title description handler risk <<< "$item"
        if [[ "$choice" == "$number" ]]; then
            if [[ -n "$risk" ]] && declare -F confirm_menu_risk >/dev/null; then
                confirm_menu_risk "$risk" || return 0
            fi
            "$handler"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------
# Module: input.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Нормализация ввода и вспомогательные функции для запросов.

trim_input() {
    local value="$*"
    value="${value//$'\r'/}"
    value="${value//$'\xc2\xa0'/ }"
    value="${value//$'\xe3\x80\x80'/ }"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_ascii_digits() {
    local value="$1"
    value="${value//０/0}"
    value="${value//１/1}"
    value="${value//２/2}"
    value="${value//３/3}"
    value="${value//４/4}"
    value="${value//５/5}"
    value="${value//６/6}"
    value="${value//７/7}"
    value="${value//８/8}"
    value="${value//９/9}"
    printf '%s' "$value"
}

normalize_menu_choice_input() {
    local value lower
    value="$(normalize_ascii_digits "$(trim_input "$1")")"
    case "$value" in
        [0-9].|[0-9][0-9].) value="${value%.}" ;;
        [0-9]\)|[0-9][0-9]\)) value="${value%)}" ;;
        [0-9]、|[0-9][0-9]、) value="${value%、}" ;;
        [0-9]．|[0-9][0-9]．) value="${value%．}" ;;
        [0-9]）|[0-9][0-9]）) value="${value%）}" ;;
    esac
    lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        q|quit|exit|back|return|返回|退出) printf '0' ;;
        *) printf '%s' "$value" ;;
    esac
}

read_trimmed() {
    local __target="$1"
    local prompt="${2:-}"
    local __raw_input
    read -r -p "$prompt" __raw_input
    case "$__target" in
        mode_choice|action_choice)
            printf -v "$__target" '%s' "$(trim_input "$__raw_input")"
            ;;
        p_choice|final_p|*port*)
            if declare -F normalize_port_input >/dev/null 2>&1; then
                printf -v "$__target" '%s' "$(normalize_port_input "$__raw_input")"
            else
                printf -v "$__target" '%s' "$(trim_input "$__raw_input")"
            fi
            ;;
        *choice*|action|c|t)
            printf -v "$__target" '%s' "$(normalize_menu_choice_input "$__raw_input")"
            ;;
        ip|*_ip|*addr*)
            if declare -F normalize_ip_input >/dev/null 2>&1; then
                printf -v "$__target" '%s' "$(normalize_ip_input "$__raw_input")"
            else
                printf -v "$__target" '%s' "$(trim_input "$__raw_input")"
            fi
            ;;
        *)
            printf -v "$__target" '%s' "$(trim_input "$__raw_input")"
            ;;
    esac
}

read_secret_trimmed() {
    local __target="$1"
    local prompt="${2:-}"
    local __raw_input
    read -r -s -p "$prompt" __raw_input
    echo ""
    printf -v "$__target" '%s' "$(trim_input "$__raw_input")"
}

ask_with_default() {
    local prompt="$1"
    local default_value="$2"
    local input
    local value
    read_trimmed input "${prompt} (по умолчанию: ${default_value}): "
    value="${input:-$default_value}"
    case "$prompt" in
        *路径*)
            ;;
        *端口*|*[Pp][Oo][Rr][Tt]*)
            if declare -F normalize_port_input >/dev/null 2>&1; then
                value="$(normalize_port_input "$value")"
            fi
            ;;
        *监听地址*)
            if declare -F normalize_ip_input >/dev/null 2>&1; then
                value="$(normalize_ip_input "$value")"
            fi
            ;;
    esac
    echo "$value"
}

split_csv_to_array() {
    local input="$1"
    local -n out_array=$2
    local idx cleaned
    input="${input//，/,}"
    input="${input//、/,}"
    input="${input//；/,}"
    input="${input//;/,}"
    input="${input//$'\r'/,}"
    input="${input//$'\n'/,}"
    input="${input//$'\t'/,}"
    input="${input// /,}"
    out_array=()
    local raw_array=()
    IFS=',' read -ra raw_array <<< "$input"
    for idx in "${!raw_array[@]}"; do
        cleaned=$(echo "${raw_array[$idx]}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        [[ -n "$cleaned" ]] && out_array+=("$cleaned")
    done
}

split_pipe_to_array() {
    local input="$1"
    local -n out_array=$2
    local item cleaned
    local raw_array=()
    out_array=()
    IFS='|' read -ra raw_array <<< "$input"
    for item in "${raw_array[@]}"; do
        cleaned=$(trim_input "$item")
        [[ -n "$cleaned" ]] && out_array+=("$cleaned")
    done
}

# ---------------------------------------------------------
# Module: validate.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Вспомогательные функции валидации и нормализации.

normalize_domain_input() {
    local domain
    domain="$(trim_input "$1")"
    if declare -F normalize_ascii_digits >/dev/null 2>&1; then
        domain="$(normalize_ascii_digits "$domain")"
    fi
    domain="${domain//。/.}"
    domain="${domain//．/.}"
    domain="${domain//｡/.}"
    domain="${domain//：/:}"
    domain=$(printf '%s' "$domain" | sed 's#／#/#g')
    domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%\?*}"
    domain="${domain%%？*}"
    domain="${domain%%#*}"
    domain="${domain%%＃*}"
    domain="${domain%%/*}"
    domain="${domain%%:*}"
    domain=$(echo "$domain" | tr -d '[:space:]')
    while [[ "$domain" == *. ]]; do
        domain="${domain%.}"
    done
    printf '%s' "$domain"
}

is_valid_hostname() {
    local name="$1"
    local label
    [[ -n "$name" && ${#name} -le 253 ]] || return 1
    [[ "$name" != .* && "$name" != *. ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS='.' read -ra labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

is_valid_domain() {
    local domain="$1"
    echo "$domain" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
}

print_domain_validation_error() {
    local label="${1:-домен}"
    local raw="${2:-}"
    local normalized="${3:-}"
    local trimmed display_value

    [[ -z "$normalized" && -n "$raw" ]] && normalized=$(normalize_domain_input "$raw")
    display_value="${normalized:- (пусто)}"
    echo -e "${RED}❌ Неверный формат ${label}: ${display_value}${PLAIN}"
    echo -e "${YELLOW}Подсказка: вставляйте только домен без протокола, пути, порта или китайской/полноширинной пунктуации, например panel.example.com.${PLAIN}"

    if [[ -z "$raw" ]]; then
        echo -e "${YELLOW}Нормализованное значение для проверки: ${display_value}${PLAIN}"
        return 0
    fi

    trimmed=$(trim_input "$raw")
    if [[ "$trimmed" != "$raw" || "$raw" =~ [[:space:]] ]]; then
        echo -e "${YELLOW}Обнаружены пробельные символы: убедитесь, что нет переводов строк, табуляций, невидимых пробелов.${PLAIN}"
    fi
    if [[ "$trimmed" =~ ^[Hh][Tt][Tt][Pp][Ss]?:// || "$trimmed" == *"://"* || "$trimmed" == */* || "$trimmed" == *\?* || "$trimmed" == *#* || "$trimmed" == *:* ]]; then
        echo -e "${YELLOW}Обнаружено содержимое, похожее на URL: уберите http(s)://, путь, параметры, #фрагмент или :порт.${PLAIN}"
    fi
    if printf '%s' "$trimmed" | grep -q '[：，。／、；？＃＠　]'; then
        echo -e "${YELLOW}Обнаружена китайская/полноширинная пунктуация: замените на английские . , / : и т.д.; точки в домене должны быть английскими.${PLAIN}"
    fi
    if printf '%s' "$trimmed" | LC_ALL=C grep -q '[^ -~]'; then
        echo -e "${YELLOW}Обнаружены не-ASCII символы: возможно, есть нулевая ширина, полноширинные или скрытые символы из источника копирования.${PLAIN}"
    fi
    echo -e "${YELLOW}Нормализованное значение для проверки: ${display_value}${PLAIN}"
}

normalize_path_prefix() {
    local path
    path="$(trim_input "$1")"
    if [[ "$path" =~ ^https?://[^/]+(/.*)?$ ]]; then
        path="${BASH_REMATCH[1]:-/}"
    fi
    path="${path%%\?*}"
    path="${path%%#*}"
    [[ -z "$path" ]] && path="/sub/"
    [[ "$path" != /* ]] && path="/${path}"
    [[ "$path" != */ ]] && path="${path}/"
    printf '%s' "$path"
}

is_valid_path_prefix() {
    local path="$1"
    [[ "$path" != "/" && "$path" != *".."* ]] && echo "$path" | grep -Eq '^/[A-Za-z0-9._~/-]+/$'
}

caddy_path_match_tokens() {
    local path
    local exact
    local seen=" "
    local tokens=""
    for path in "$@"; do
        path=$(normalize_path_prefix "$path")
        exact="${path%/}"
        if [[ "$seen" == *" ${exact} "* ]]; then
            continue
        fi
        tokens+="${exact} ${exact}/* "
        seen+=" ${exact} "
    done
    printf '%s' "${tokens% }"
}

is_yes() {
    local value
    value="$(trim_input "$1")"
    [[ "$value" =~ ^[Yy]([Ee][Ss])?$ ]]
}

is_no() {
    local value
    value="$(trim_input "$1")"
    [[ "$value" =~ ^[Nn]([Oo])?$ ]]
}

is_suspicious_public_ipv4() {
    local ip="$1"
    local a b c d

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$ip"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet <= 255)) || return 1
    done

    # Публичные адреса панелей не должны разрешаться в приватные, петлевые, тестовые, мультикаст
    # или диапазоны бенчмарков/fake-ip. Это проверяется на стороне VPS; локальный прокси с fake-ip
    # может намеренно возвращать 198.18.0.0/15 на компьютере пользователя.
    ((10#$a == 0 || 10#$a == 10 || 10#$a == 127 || 10#$a >= 224)) && return 0
    ((10#$a == 100 && 10#$b >= 64 && 10#$b <= 127)) && return 0
    ((10#$a == 169 && 10#$b == 254)) && return 0
    ((10#$a == 172 && 10#$b >= 16 && 10#$b <= 31)) && return 0
    ((10#$a == 192 && 10#$b == 168)) && return 0
    ((10#$a == 198 && (10#$b == 18 || 10#$b == 19))) && return 0
    ((10#$a == 192 && 10#$b == 0 && 10#$c == 2)) && return 0
    ((10#$a == 198 && 10#$b == 51 && 10#$c == 100)) && return 0
    ((10#$a == 203 && 10#$b == 0 && 10#$c == 113)) && return 0
    return 1
}

resolve_domain_a_records() {
    local domain="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +short A "$domain" @1.1.1.1 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup -type=A "$domain" 1.1.1.1 2>/dev/null | awk '/^Address: / {print $2}' | grep -Ev '^1\.1\.1\.1$' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
    elif command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
    fi
}

check_domain_dns_sanity() {
    local domain="$1"
    local label="${2:-домен}"
    local mode="${3:-warn}"
    local ips ip suspect=0 confirm

    ips=$(resolve_domain_a_records "$domain")
    if [[ -z "$ips" ]]; then
        echo -e "${YELLOW}⚠️ ${label} ${domain} не разрешается в A-запись; если настроен только IPv6/AAAA, убедитесь, что клиент и VPS поддерживают IPv6.${PLAIN}"
        return 1
    fi

    echo -e "${CYAN}▶ Текущие A-записи для ${label} ${domain}: $(echo "$ips" | tr '\n' ' ')${PLAIN}"
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if is_suspicious_public_ipv4 "$ip"; then
            echo -e "${RED}❌ ${label} ${domain} разрешается в подозрительный адрес ${ip}, это не нормальный публичный адрес VPS.${PLAIN}"
            suspect=1
        fi
    done <<< "$ips"

    if [[ "$suspect" -eq 1 ]]; then
        echo -e "${YELLOW}Проверьте DNS на VPS. Если fake-ip включён только на локальном компьютере, 198.18.x.x может быть локальным прокси; если VPS/публичный DNS тоже показывает этот адрес, измените A-запись на реальный публичный IP VPS.${PLAIN}"
        echo -e "${YELLOW}При использовании облачка Cloudflare публичный DNS должен показывать пограничные IP Cloudflare, а не 198.18/10/127/192.168 и т.п.${PLAIN}"
        if [[ "$mode" == "prompt" ]]; then
            read_trimmed confirm "Всё равно продолжить? введите yes (не рекомендуется, регистр не важен): "
            is_yes "$confirm" || return 1
        else
            return 1
        fi
    fi

    return 0
}

is_valid_ipv4_cidr() {
    local value="$1"
    local ip prefix a b c d octet
    ip="${value%%/*}"
    prefix=""
    if [[ "$value" == */* ]]; then
        prefix="${value##*/}"
        [[ -n "$prefix" ]] || return 1
    fi

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$ip"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
    if [[ -n "$prefix" ]]; then
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        (( 10#$prefix >= 0 && 10#$prefix <= 32 )) || return 1
    fi
}

is_valid_ipv6_cidr() {
    local value="$1"
    local ip prefix remainder double_colon_count segment_count segment
    local -a ipv6_segments
    [[ -n "$value" ]] || return 1
    ip="${value%%/*}"
    prefix=""
    if [[ "$value" == */* ]]; then
        prefix="${value##*/}"
        [[ -n "$prefix" ]] || return 1
    fi

    [[ -n "$ip" ]] || return 1
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    [[ "$ip" != *:::* ]] || return 1
    remainder="$ip"
    double_colon_count=0
    while [[ "$remainder" == *"::"* ]]; do
        ((double_colon_count += 1))
        remainder="${remainder#*::}"
    done
    (( double_colon_count <= 1 )) || return 1

    segment_count=0
    IFS=':' read -ra ipv6_segments <<< "$ip"
    for segment in "${ipv6_segments[@]}"; do
        [[ -z "$segment" ]] && continue
        ((segment_count += 1))
        ((${#segment} <= 4)) || return 1
    done
    if (( double_colon_count == 0 )); then
        (( segment_count == 8 )) || return 1
    else
        (( segment_count < 8 )) || return 1
    fi
    if [[ -n "$prefix" ]]; then
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        (( 10#$prefix >= 0 && 10#$prefix <= 128 )) || return 1
    fi
}

validate_ip_cidr_python() {
    local value="$1"
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(1)
PY
}

is_valid_ip_cidr() {
    local value="$1"
    [[ -n "$value" && "$value" != *";"* && "$value" != *"{"* && "$value" != *"}"* ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        validate_ip_cidr_python "$value" && return 0
    fi
    is_valid_ipv4_cidr "$value" || is_valid_ipv6_cidr "$value"
}

normalize_ip_input() {
    local value
    value="$(trim_input "$1")"
    if declare -F normalize_ascii_digits >/dev/null 2>&1; then
        value="$(normalize_ascii_digits "$value")"
    fi
    value="${value//。/.}"
    value="${value//．/.}"
    value="${value//｡/.}"
    value="${value//：/:}"
    value=$(printf '%s' "$value" | sed 's#／#/#g')
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    value="${value#http://}"
    value="${value#https://}"
    value="${value%%\?*}"
    value="${value%%？*}"
    value="${value%%#*}"
    value="${value%%＃*}"
    value="${value%%/*}"
    value=$(echo "$value" | tr -d '[:space:]')
    if [[ "$value" =~ ^\[(.+)\](:[0-9]+)?$ ]]; then
        value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3}):[0-9]+$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    printf '%s' "$value"
}

normalize_backend_addr_input() {
    local value
    value="$(normalize_ip_input "$1")"
    value="$(normalize_loopback_addr "$value")"
    if [[ "$value" =~ ^([^:]+):[0-9]+$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    printf '%s' "$value"
}

normalize_ip_whitelist_input() {
    local input="$1"
    local -n out_array=$2
    local item normalized seen
    if declare -F normalize_ascii_digits >/dev/null 2>&1; then
        input="$(normalize_ascii_digits "$input")"
    fi
    input="${input//。/.}"
    input="${input//．/.}"
    input="${input//｡/.}"
    input="${input//：/:}"
    input=$(printf '%s' "$input" | sed 's#／#/#g')
    input="${input//，/ }"
    input="${input//、/ }"
    input="${input//；/ }"
    input="${input//;/ }"
    input="${input//|/ }"
    input="${input//,/ }"
    input="${input//$'\r'/ }"
    input="${input//$'\n'/ }"
    input="${input//$'\t'/ }"
    out_array=()
    seen=" "
    for item in $input; do
        normalized=$(echo "$(trim_input "$item")" | tr '[:upper:]' '[:lower:]')
        if [[ "$normalized" =~ ^\[(.+)\](/.+)?$ ]]; then
            normalized="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        fi
        [[ -z "$normalized" ]] && continue
        if ! is_valid_ip_cidr "$normalized"; then
            echo -e "${RED}❌ Неверный формат IP/CIDR: ${normalized}${PLAIN}"
            return 1
        fi
        if [[ "$seen" != *" ${normalized} "* ]]; then
            out_array+=("$normalized")
            seen+=" ${normalized} "
        fi
    done
    [[ ${#out_array[@]} -gt 0 ]]
}

normalize_port_input() {
    local value port_candidate
    value="$(trim_input "$1")"
    if declare -F normalize_ascii_digits >/dev/null 2>&1; then
        value="$(normalize_ascii_digits "$value")"
    fi
    value="${value//：/:}"
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    value="${value#http://}"
    value="${value#https://}"
    value="${value%%\?*}"
    value="${value%%？*}"
    value="${value%%#*}"
    value="${value%%＃*}"
    value="${value%%/*}"
    value=$(echo "$value" | tr -d '[:space:]')
    value="${value%)}"
    value="${value%）}"
    value="${value%.}"
    value="${value%．}"
    value="${value%,}"
    value="${value%，}"
    value="${value%;}"
    value="${value%；}"
    if [[ "$value" == *:* ]]; then
        port_candidate="${value##*:}"
        [[ "$port_candidate" =~ ^[0-9]+$ ]] && value="$port_candidate"
    fi
    printf '%s' "$value"
}

is_valid_port() {
    local port
    port="$(normalize_port_input "$1")"
    [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

is_valid_listen_addr() {
    local addr="$1"
    if [[ "$addr" == "127.0.0.1" || "$addr" == "localhost" || "$addr" == "0.0.0.0" || "$addr" == "::1" || "$addr" == "::" ]]; then
        return 0
    fi
    if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS=.
        local -a octets=($addr)
        local octet
        for octet in "${octets[@]}"; do
            [[ "$octet" =~ ^[0-9]+$ ]] || return 1
            (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
        done
        return 0
    fi
    return 1
}

is_valid_backend_addr() {
    local addr="$1"
    [[ -n "$addr" ]] || return 1
    is_valid_listen_addr "$addr" || is_valid_hostname "$addr"
}

backend_addr_resolution_status() {
    local addr="$1"

    addr="${addr#[}"
    addr="${addr%]}"
    if is_valid_listen_addr "$addr"; then
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        getent ahosts "$addr" >/dev/null 2>&1
        return $?
    fi
    return 2
}

tcp_target_reachable() {
    local host="$1"
    local port="$2"
    local attempted=0

    is_valid_port "$port" || return 1
    if command -v nc >/dev/null 2>&1; then
        attempted=1
        nc -z -w 3 "$host" "$port" >/dev/null 2>&1 && return 0
    fi
    if command -v timeout >/dev/null 2>&1; then
        attempted=1
        timeout 5 bash -c 'cat < /dev/null > /dev/tcp/$1/$2' _ "$host" "$port" 2>/dev/null && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        attempted=1
        curl -fsS --connect-timeout 3 --max-time 5 "telnet://$(format_hostport "$host" "$port")" </dev/null >/dev/null 2>&1 && return 0
    fi
    [[ "$attempted" -eq 1 ]] && return 1
    return 2
}

probe_backend_target() {
    local label="$1"
    local addr="$2"
    local port="$3"
    local probe_rc

    if ! is_valid_backend_addr "$addr" || ! is_valid_port "$port"; then
        echo -e "${RED}❌ ${label}: неверный адрес или порт бэкенда ($(format_hostport "$addr" "$port"))${PLAIN}"
        return 1
    fi

    if backend_addr_resolution_status "$addr"; then
        :
    else
        probe_rc=$?
        if [[ "$probe_rc" -eq 2 ]]; then
            echo -e "${YELLOW}⚠️ ${label}: отсутствует инструмент разрешения адресов, пропускаем проверку $(format_hostport "$addr" "$port")${PLAIN}"
            return 2
        fi
        echo -e "${RED}❌ ${label}: не удалось разрешить адрес бэкенда ${addr}${PLAIN}"
        return 1
    fi

    if tcp_target_reachable "$addr" "$port"; then
        echo -e "${GREEN}✅ ${label}: $(format_hostport "$addr" "$port") доступен${PLAIN}"
        return 0
    fi
    probe_rc=$?
    if [[ "$probe_rc" -eq 2 ]]; then
        echo -e "${YELLOW}⚠️ ${label}: отсутствует nc, timeout или curl, пропускаем проверку $(format_hostport "$addr" "$port")${PLAIN}"
        return 2
    fi
    echo -e "${RED}❌ ${label}: $(format_hostport "$addr" "$port") в данный момент недоступен${PLAIN}"
    return 1
}

confirm_backend_target_or_continue() {
    local label="$1"
    local addr="$2"
    local port="$3"
    local probe_rc continue_confirm

    if probe_backend_target "$label" "$addr" "$port"; then
        return 0
    fi
    probe_rc=$?
    [[ "$probe_rc" -eq 2 ]] && return 0

    read_trimmed continue_confirm "Бэкенд сейчас недоступен, всё равно сохранить? (y/n, по умолчанию n): "
    if is_yes "$continue_confirm"; then
        echo -e "${YELLOW}⚠️ Выбрано продолжение; после сохранения проверьте службу бэкенда, адрес и порт.${PLAIN}"
        return 0
    fi
    echo -e "${BLUE}Сохранение отменено.${PLAIN}"
    return 1
}

is_loopback_listen_addr() {
    local addr="$1"
    [[ "$addr" == "127.0.0.1" || "$addr" == "localhost" || "$addr" == "::1" ]]
}

normalize_loopback_addr() {
    local addr="$1"
    [[ "$addr" == "localhost" ]] && addr="127.0.0.1"
    printf '%s' "$addr"
}

normalize_port_rule_input() {
    local value="$1"
    if declare -F normalize_ascii_digits >/dev/null 2>&1; then
        value="$(normalize_ascii_digits "$value")"
    fi
    value="${value//，/,}"
    value="${value//、/,}"
    value="${value//；/,}"
    value="${value//;/,}"
    value="${value//：/:}"
    value="${value//－/-}"
    value="${value//—/-}"
    value=$(echo "$value" | tr -d '[:space:]')

    local item start end extra
    local items=()
    local normalized=()
    IFS=',' read -ra items <<< "$value"
    for item in "${items[@]}"; do
        item="${item//:/-}"
        if [[ "$item" == *-* ]]; then
            IFS='-' read -r start end extra <<< "$item"
            if [[ -z "$extra" && "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
                normalized+=("$((10#$start))-$((10#$end))")
            else
                normalized+=("$item")
            fi
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            normalized+=("$((10#$item))")
        else
            normalized+=("$item")
        fi
    done

    (IFS=','; printf '%s' "${normalized[*]}")
}

is_valid_port_rule_input() {
    local input
    input=$(normalize_port_rule_input "$1")
    [[ -n "$input" ]] || return 1

    local item range_start range_end extra
    local items=()
    IFS=',' read -ra items <<< "$input"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] || return 1
        item="${item//:/-}"
        if [[ "$item" == *-* ]]; then
            IFS='-' read -r range_start range_end extra <<< "$item"
            [[ -z "$extra" ]] || return 1
            is_valid_port "$range_start" && is_valid_port "$range_end" || return 1
            (( 10#$range_start <= 10#$range_end )) || return 1
        else
            is_valid_port "$item" || return 1
        fi
    done
    return 0
}

warn_if_public_bind() {
    local service_name="$1"
    local listen_addr="$2"
    local listen_port="$3"
    local confirm
    if [[ "$listen_addr" == "0.0.0.0" || "$listen_addr" == "::" ]]; then
        confirm_risk_action "${service_name} слушает на публичном адресе ${listen_addr}:${listen_port}" \
            "Адрес прослушивания ${service_name} будет изменён с локального на общедоступный" \
            "Верните 127.0.0.1 и перепримените конфигурацию, затем перезапустите службу" \
            "Продолжайте, только если вам действительно нужно прямое обращение к этой службе из интернета." || return 1
    fi
    return 0
}

format_hostport() {
    local addr="$1"
    local port="$2"
    if [[ "$addr" == *:* && "$addr" != \[*\] ]]; then
        echo "[${addr}]:${port}"
    else
        echo "${addr}:${port}"
    fi
}

nginx_stream_listen_directives() {
    local addr="$1"
    local port="$2"

    if [[ "$addr" == *:* && "$addr" != \[*\] ]]; then
        printf '    listen [%s]:%s;\n' "$addr" "$port"
        return 0
    fi

    printf '    listen %s:%s;\n' "$addr" "$port"
    if [[ "$addr" == "0.0.0.0" ]]; then
        printf '    listen [::]:%s;\n' "$port"
    fi
}

xui_cert_setting_key_sql_list() {
    printf '%s' "'webcertfile','webkeyfile','webcert','webcertkey','webcertkeyfile','certfile','keyfile','cert','key','subcertfile','subkeyfile','subcert','subkey','subcertkey','subcertkeyfile'"
}

dns_is_valid_ipv4() {
    local ip="$1"
    local octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
    return 0
}

dns_is_valid_ipv6() {
    local ip="$1"
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$ip" != *:::* ]]
}

dns_normalize_servers() {
    local family="$1"
    local raw="$2"
    local item
    local items=()
    local result=()

    if declare -F normalize_ascii_digits >/dev/null 2>&1; then
        raw="$(normalize_ascii_digits "$raw")"
    fi
    raw="${raw//。/.}"
    raw="${raw//．/.}"
    raw="${raw//｡/.}"
    raw="${raw//：/:}"
    raw=$(printf '%s' "$raw" | sed 's#／#/#g')
    raw="${raw//，/,}"
    raw="${raw//、/,}"
    raw="${raw//；/,}"
    raw="${raw//;/,}"
    raw="${raw//$'\r'/,}"
    raw="${raw//$'\n'/,}"
    raw="${raw// /,}"
    raw="${raw//$'\t'/,}"
    IFS=',' read -ra items <<< "$raw"

    for item in "${items[@]}"; do
        item="$(trim_input "$item")"
        if [[ "$item" =~ ^\[(.+)\]$ ]]; then
            item="${BASH_REMATCH[1]}"
        fi
        [[ -z "$item" ]] && continue
        if [[ "$family" == "4" ]]; then
            dns_is_valid_ipv4 "$item" || return 1
        else
            dns_is_valid_ipv6 "$item" || return 1
        fi
        result+=("$item")
    done

    [[ ${#result[@]} -gt 0 ]] || return 1
    (IFS=' '; printf '%s' "${result[*]}")
}

# ---------------------------------------------------------
# Module: rollback.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Вспомогательные функции отката и карантина.

quarantine_path() {
    local target="$1"
    local quarantine_root="${2:-/root/vps-optimize-quarantine}"
    local resolved base dest

    if [[ -z "$target" || "$target" == *"*"* || "$target" == *"?"* ]]; then
        echo -e "${RED}❌ Отказано в изоляции пустого или содержащего wildcard пути: ${target}${PLAIN}"
        return 1
    fi

    [[ -e "$target" || -L "$target" ]] || return 0

    resolved=$(readlink -f -- "$target" 2>/dev/null || realpath -m -- "$target" 2>/dev/null || printf '%s' "$target")
    case "$resolved" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
            echo -e "${RED}❌ Отказано в изоляции системного корневого каталога: ${resolved}${PLAIN}"
            return 1
            ;;
    esac

    mkdir -p "$quarantine_root" || return 1
    chmod 700 "$quarantine_root" 2>/dev/null || true
    base=$(basename "$resolved")
    dest="${quarantine_root%/}/$(date +%Y%m%d_%H%M%S)_${base}"
    while [[ -e "$dest" ]]; do
        dest="${dest}_$RANDOM"
    done

    mv -- "$target" "$dest"
    echo -e "${YELLOW}Изолирован: ${resolved} -> ${dest}${PLAIN}"
}

restore_sni_stack_backup_files() {
    local backup_dir="$1"
    local domain conf_file
    [[ -n "$backup_dir" && -d "$backup_dir" ]] || return 1

    mkdir -p /etc/nginx/stream.d /etc/nginx/conf.d /etc/caddy/conf.d /etc/vps-optimize /etc/systemd/system /usr/local/bin
    [[ -f "$backup_dir/nginx.conf" ]] && cp -a "$backup_dir/nginx.conf" /etc/nginx/nginx.conf
    [[ -f "$backup_dir/Caddyfile" ]] && cp -a "$backup_dir/Caddyfile" /etc/caddy/Caddyfile
    [[ -f "$backup_dir/vps-optimize/sni-stack.env" ]] && cp -a "$backup_dir/vps-optimize/sni-stack.env" /etc/vps-optimize/sni-stack.env
    [[ -f "$backup_dir/vps-optimize/xray-sni-routes.conf" ]] && cp -a "$backup_dir/vps-optimize/xray-sni-routes.conf" /etc/vps-optimize/xray-sni-routes.conf
    [[ -f "$backup_dir/vps-optimize/443-engine.conf" ]] && cp -a "$backup_dir/vps-optimize/443-engine.conf" /etc/vps-optimize/443-engine.conf
    [[ -f "$backup_dir/vps-optimize/vpso-mux.yaml" ]] && cp -a "$backup_dir/vps-optimize/vpso-mux.yaml" /etc/vps-optimize/vpso-mux.yaml
    [[ -f "$backup_dir/systemd/vpso-mux.service" ]] && cp -a "$backup_dir/systemd/vpso-mux.service" /etc/systemd/system/vpso-mux.service
    [[ -f "$backup_dir/usr-local-bin/vpso-mux" ]] && cp -a "$backup_dir/usr-local-bin/vpso-mux" /usr/local/bin/vpso-mux

    while IFS= read -r conf_file; do
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/nginx-sni" >/dev/null 2>&1 || true
    done < <(find /etc/nginx/stream.d -maxdepth 1 -type f -name 'vps_sni_*.conf' 2>/dev/null | sort)
    cp -a "$backup_dir/nginx_stream.d/"*.conf /etc/nginx/stream.d/ 2>/dev/null || true

    while IFS= read -r conf_file; do
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/nginx-conf-d" >/dev/null 2>&1 || true
    done < <(find /etc/nginx/conf.d -maxdepth 1 \( -name 'vps_sni_web_*.conf' -o -name 'vps_proxy_*.conf' \) 2>/dev/null | sort)
    cp -a "$backup_dir/nginx_conf.d/"*.conf /etc/nginx/conf.d/ 2>/dev/null || true

    for domain in "$PANEL_DOMAIN" "${SITE_DOMAINS[@]}"; do
        [[ -n "$domain" ]] || continue
        conf_file="/etc/caddy/conf.d/${domain}.caddy"
        [[ -e "$conf_file" ]] && quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/caddy-sni" >/dev/null 2>&1 || true
    done
    cp -a "$backup_dir/caddy_conf.d/"*.caddy /etc/caddy/conf.d/ 2>/dev/null || true
}

rollback_sni_stack_after_failure() {
    local backup_dir="$1"
    local reason="${2:-Ошибка применения конфигурации}"
    echo -e "${RED}❌ ${reason}${PLAIN}"
    echo -e "${YELLOW}▶ Выполняется откат конфигурации Nginx/Caddy из резервной копии, созданной перед операцией...${PLAIN}"
    if restore_sni_stack_backup_files "$backup_dir"; then
        nginx -t >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ Проверка синтаксиса Nginx после отката всё ещё не пройдена, проверьте вручную /etc/nginx/nginx.conf.${PLAIN}"
        caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ Проверка конфигурации Caddy после отката не пройдена, проверьте вручную /etc/caddy/Caddyfile.${PLAIN}"
        restart_service_if_available nginx >/dev/null 2>&1 || true
        restart_service_if_available caddy >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        echo -e "${YELLOW}Откат выполнен к: ${backup_dir}${PLAIN}"
    else
        echo -e "${RED}❌ Автоматический откат не удался, восстановите вручную из каталога резервной копии: ${backup_dir}${PLAIN}"
    fi
    return 1
}

rollback_sni_stack_config() {
    local backup_dir
    backup_dir=$(cat /etc/vps-optimize/sni-stack.last-backup 2>/dev/null)
    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        backup_dir=$(find /etc/vps-optimize/backups -maxdepth 1 -type d -name 'sni-stack_*' 2>/dev/null | sort | tail -n1)
    fi
    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        echo -e "${RED}❌ Не найдена резервная копия SNI stack для отката.${PLAIN}"
        return 1
    fi
    echo -e "${YELLOW}Будет выполнен откат к резервной копии: ${backup_dir}${PLAIN}"
    confirm_risk_action "Откат конфигурации Nginx/Caddy 443" \
        "Текущие конфигурации Nginx/Caddy, связанные с единым входом 443" \
        "Если после отката проблемы сохранятся, восстановите вручную из каталога резервной копии" \
        "Откат перезапишет текущую конфигурацию, убедитесь, что выбрана правильная копия." || return 1

    restore_sni_stack_backup_files "$backup_dir" || { echo -e "${RED}❌ Восстановление файлов отката не удалось.${PLAIN}"; return 1; }

    if nginx -t && caddy validate --config /etc/caddy/Caddyfile; then
        restart_service_if_available nginx >/dev/null 2>&1 || true
        restart_service_if_available caddy >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ Откат выполнен.${PLAIN}"
    else
        echo -e "${RED}❌ Файлы отката восстановлены, но проверка конфигурации не пройдена, проверьте вручную резервную копию: ${backup_dir}${PLAIN}"
        return 1
    fi
}

restore_backup_file() {
    local snapshot="$1"
    local target="$2"

    [[ -f "$snapshot" || -L "$snapshot" ]] || return 0
    mkdir -p "$(dirname "$target")" || return 1
    cp -af -- "$snapshot" "$target"
}

restore_backup_dir() {
    local snapshot="$1"
    local target="$2"
    local quarantine_root="$3"

    [[ -d "$snapshot" ]] || return 0
    mkdir -p "$(dirname "$target")" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        quarantine_path "$target" "$quarantine_root" >/dev/null 2>&1 || return 1
    fi
    cp -a -- "$snapshot" "$target"
}

dns_restore_latest_backup() {
    local backup_dir
    backup_dir=$(cat "${DNS_OPTIMIZE_BACKUP_DIR}/last" 2>/dev/null || true)
    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        echo -e "${YELLOW}⚠️ Не найдена последняя DNS-резервная копия.${PLAIN}"
        return 1
    fi

    confirm_risk_action "Восстановление последней DNS-резервной копии" \
        "/etc/resolv.conf и конфигурации systemd-resolved, созданной VPS-Optimize" \
        "Вернитесь в меню оптимизации DNS и выберите другую конфигурацию" \
        "Если после восстановления возникнут проблемы с разрешением, выберите другую конфигурацию DNS." || return 1

    if [[ -e "$backup_dir/resolv.conf" || -L "$backup_dir/resolv.conf" ]]; then
        [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]] && quarantine_path /etc/resolv.conf "/etc/vps-optimize/quarantine/dns" >/dev/null 2>&1 || true
        cp -a "$backup_dir/resolv.conf" /etc/resolv.conf
    fi

    if [[ -f "$DNS_OPTIMIZE_RESOLVED_DROPIN" ]]; then
        quarantine_path "$DNS_OPTIMIZE_RESOLVED_DROPIN" "/etc/vps-optimize/quarantine/dns" >/dev/null 2>&1 || true
    fi
    if [[ -f "$backup_dir/99-vps-optimize-dns.conf" ]]; then
        mkdir -p /etc/systemd/resolved.conf.d
        cp -a "$backup_dir/99-vps-optimize-dns.conf" "$DNS_OPTIMIZE_RESOLVED_DROPIN"
    fi

    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ DNS-резервная копия восстановлена: ${backup_dir}${PLAIN}"
}

# ---------------------------------------------------------
# Module: backup.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Вспомогательные функции резервного копирования и точка входа в центр резервного копирования.

sni_stack_backup_dir() {
    echo "/etc/vps-optimize/backups/sni-stack_$(date +%Y%m%d_%H%M%S)"
}

create_sni_stack_backup() {
    local backup_dir
    backup_dir="${1:-$(sni_stack_backup_dir)}"
    mkdir -p "$backup_dir/nginx_stream.d" "$backup_dir/nginx_conf.d" "$backup_dir/caddy_conf.d" "$backup_dir/vps-optimize" "$backup_dir/systemd" "$backup_dir/usr-local-bin" "$backup_dir/x-ui"
    [[ -f /etc/nginx/nginx.conf ]] && cp -a /etc/nginx/nginx.conf "$backup_dir/nginx.conf" 2>/dev/null || true
    [[ -d /etc/nginx/stream.d ]] && cp -a /etc/nginx/stream.d/vps_sni_*.conf "$backup_dir/nginx_stream.d/" 2>/dev/null || true
    [[ -d /etc/nginx/conf.d ]] && cp -a /etc/nginx/conf.d/vps_sni_web_*.conf "$backup_dir/nginx_conf.d/" 2>/dev/null || true
    [[ -d /etc/nginx/conf.d ]] && cp -a /etc/nginx/conf.d/vps_proxy_*.conf "$backup_dir/nginx_conf.d/" 2>/dev/null || true
    [[ -f /etc/nginx/conf.d/00-vps-proxy-map.conf ]] && cp -a /etc/nginx/conf.d/00-vps-proxy-map.conf "$backup_dir/nginx_conf.d/" 2>/dev/null || true
    [[ -f /etc/caddy/Caddyfile ]] && cp -a /etc/caddy/Caddyfile "$backup_dir/Caddyfile" 2>/dev/null || true
    [[ -d /etc/caddy/conf.d ]] && cp -a /etc/caddy/conf.d/*.caddy "$backup_dir/caddy_conf.d/" 2>/dev/null || true
    [[ -f /etc/vps-optimize/sni-stack.env ]] && cp -a /etc/vps-optimize/sni-stack.env "$backup_dir/vps-optimize/sni-stack.env" 2>/dev/null || true
    [[ -f /etc/vps-optimize/xray-sni-routes.conf ]] && cp -a /etc/vps-optimize/xray-sni-routes.conf "$backup_dir/vps-optimize/xray-sni-routes.conf" 2>/dev/null || true
    [[ -f /etc/vps-optimize/443-engine.conf ]] && cp -a /etc/vps-optimize/443-engine.conf "$backup_dir/vps-optimize/443-engine.conf" 2>/dev/null || true
    [[ -f /etc/vps-optimize/vpso-mux.yaml ]] && cp -a /etc/vps-optimize/vpso-mux.yaml "$backup_dir/vps-optimize/vpso-mux.yaml" 2>/dev/null || true
    [[ -f /etc/systemd/system/vpso-mux.service ]] && cp -a /etc/systemd/system/vpso-mux.service "$backup_dir/systemd/vpso-mux.service" 2>/dev/null || true
    [[ -f /usr/local/bin/vpso-mux ]] && cp -a /usr/local/bin/vpso-mux "$backup_dir/usr-local-bin/vpso-mux" 2>/dev/null || true
    [[ -d /etc/x-ui ]] && cp -a /etc/x-ui "$backup_dir/x-ui/etc-x-ui" 2>/dev/null || true
    [[ -f /usr/local/x-ui/bin/config.json ]] && cp -a /usr/local/x-ui/bin/config.json "$backup_dir/x-ui/config.json" 2>/dev/null || true
    echo "$backup_dir" > /etc/vps-optimize/sni-stack.last-backup 2>/dev/null || true
    echo -e "${GREEN}✅ Создана резервная копия конфигурации: ${backup_dir}${PLAIN}"
}

make_secure_temp_dir() {
    local prefix="$1"
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/${prefix}.XXXXXX") || return 1
    chmod 700 "$tmp_dir" 2>/dev/null || true
    printf '%s' "$tmp_dir"
}

backup_copy_path() {
    local src="$1"
    local dest_rel="$2"
    local manifest_file="$3"
    local work_dir="$4"
    local dest_dir

    [[ -e "$src" || -L "$src" ]] || return 1
    dest_dir=$(dirname "$dest_rel")
    mkdir -p "$work_dir/$dest_dir" || return 1

    if cp -a -- "$src" "$work_dir/$dest_rel" 2>/dev/null; then
        echo " - $src" >> "$manifest_file"
        return 0
    fi
    return 1
}

backup_copy_xui_databases() {
    local manifest_file="$1"
    local work_dir="$2"
    local copied=1
    local db suffix src
    local db_paths=(
        "/etc/x-ui/x-ui.db"
        "/usr/local/x-ui/x-ui.db"
        "/usr/local/x-ui/bin/x-ui.db"
    )

    for db in "${db_paths[@]}"; do
        for suffix in "" "-wal" "-shm"; do
            src="${db}${suffix}"
            if backup_copy_path "$src" "${src#/}" "$manifest_file" "$work_dir"; then
                copied=0
            fi
        done
    done
    return "$copied"
}

redact_sensitive_output() {
    sed -E \
        -e 's/(authorization:[[:space:]]*(bearer|basic)[[:space:]]+)[^[:space:]]+/\1***REDACTED***/gI' \
        -e 's/((^|[^[:alnum:]_])(token|password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|CF_Token|CF_Key)[[:space:]]*[=:][[:space:]]*)[^[:space:],;"'\''}]+/\1***REDACTED***/gI' \
        -e 's/("(token|password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|CF_Token|CF_Key)"[[:space:]]*:[[:space:]]*")[^"]+/\1***REDACTED***/gI' \
        -e 's/([?&](token|password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret)=)[^&[:space:]]+/\1***REDACTED***/gI' \
        -e 's#(https?://)[^/@[:space:]]+@#\1***REDACTED***@#g'
}

dns_backup_current_config() {
    local ts backup_dir
    ts=$(date +%Y%m%d_%H%M%S)
    backup_dir="${DNS_OPTIMIZE_BACKUP_DIR}/${ts}"
    mkdir -p "$backup_dir"
    chmod 700 "$DNS_OPTIMIZE_BACKUP_DIR" "$backup_dir" 2>/dev/null || true
    [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]] && cp -a /etc/resolv.conf "$backup_dir/resolv.conf" 2>/dev/null || true
    [[ -f "$DNS_OPTIMIZE_RESOLVED_DROPIN" ]] && cp -a "$DNS_OPTIMIZE_RESOLVED_DROPIN" "$backup_dir/99-vps-optimize-dns.conf" 2>/dev/null || true
    echo "$backup_dir" > "${DNS_OPTIMIZE_BACKUP_DIR}/last" 2>/dev/null || true
    echo "$backup_dir"
}

applied_config_editor_command() {
    local editor="${EDITOR:-}"
    if [[ -n "$editor" && "$editor" != *" "* ]] && command -v "$editor" >/dev/null 2>&1; then
        printf '%s' "$editor"
        return 0
    fi

    local candidate
    for candidate in nano vim vi; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

append_applied_config_file() {
    local label="$1"
    local path="$2"
    local kind="$3"
    local existing

    [[ -e "$path" || -L "$path" ]] || return 0
    for existing in "${applied_config_paths[@]}"; do
        [[ "$existing" == "$path" ]] && return 0
    done

    applied_config_labels+=("$label")
    applied_config_paths+=("$path")
    applied_config_kinds+=("$kind")
}

collect_applied_config_files() {
    local scope="${1:-all}"
    local conf_file

    applied_config_labels=()
    applied_config_paths=()
    applied_config_kinds=()

    append_applied_config_file "Основной конфиг Caddy" "/etc/caddy/Caddyfile" "caddy"
    for conf_file in /etc/caddy/conf.d/*.caddy; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Сайт Caddy $(basename "$conf_file")" "$conf_file" "caddy"
    done
    append_applied_config_file "Основной конфиг Nginx" "/etc/nginx/nginx.conf" "nginx"
    for conf_file in /etc/nginx/conf.d/*.conf; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Nginx conf.d $(basename "$conf_file")" "$conf_file" "nginx"
    done
    for conf_file in /etc/nginx/sites-enabled/*; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Nginx sites-enabled $(basename "$conf_file")" "$conf_file" "nginx"
    done

    [[ "$scope" == "proxy" ]] && return 0

    for conf_file in /etc/nginx/stream.d/*.conf; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Nginx stream.d $(basename "$conf_file")" "$conf_file" "nginx"
    done
    append_applied_config_file "Общие параметры 443" "/etc/vps-optimize/sni-stack.env" "entry-mode"
    append_applied_config_file "Состояние движка 443" "/etc/vps-optimize/443-engine.conf" "entry-mode"
    append_applied_config_file "Записи маршрутизации Xray SNI" "/etc/vps-optimize/xray-sni-routes.conf" "xray-routes"
    append_applied_config_file "Конфигурация TCP Peek vpso-mux" "/etc/vps-optimize/vpso-mux.yaml" "vpso-mux"
    append_applied_config_file "systemd vpso-mux" "/etc/systemd/system/vpso-mux.service" "systemd"
    append_applied_config_file "systemd предпроверки vpso-mux 8444" "/etc/systemd/system/vpso-mux-preflight.service" "systemd"
    append_applied_config_file "Конфигурация Traffic Guard" "$TRAFFIC_GUARD_CONFIG" "traffic-guard"
    append_applied_config_file "Служба Traffic Guard" "/etc/systemd/system/vps-traffic-guard.service" "systemd"
    append_applied_config_file "Таймер Traffic Guard" "/etc/systemd/system/vps-traffic-guard.timer" "systemd"
    append_applied_config_file "Конфигурация Cloudflare DNS API" "/root/.config/vps-panel/cloudflare.env" "env"
    append_applied_config_file "Docker daemon.json" "/etc/docker/daemon.json" "docker-json"
    append_applied_config_file "Основной конфиг SSH" "/etc/ssh/sshd_config" "ssh"
    for conf_file in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$conf_file" ]] && append_applied_config_file "SSH drop-in $(basename "$conf_file")" "$conf_file" "ssh"
    done
    append_applied_config_file "Файл hosts" "/etc/hosts" "hosts"
    append_applied_config_file "Файл hostname" "/etc/hostname" "hostname"
    append_applied_config_file "DNS resolv.conf" "/etc/resolv.conf" "dns"
    append_applied_config_file "systemd-resolved DNS drop-in" "$DNS_OPTIMIZE_RESOLVED_DROPIN" "dns"
    append_applied_config_file "Fail2ban jail.local" "/etc/fail2ban/jail.local" "fail2ban"
    append_applied_config_file "x-ui config.json" "/usr/local/x-ui/bin/config.json" "xui-json"
    for conf_file in /etc/sysctl.d/*.conf; do
        [[ -f "$conf_file" ]] && append_applied_config_file "sysctl.d $(basename "$conf_file")" "$conf_file" "sysctl"
    done
    for conf_file in /opt/sublinkpro/docker-compose.yml /opt/miaomiaowu/docker-compose.yml /opt/sub-store/docker-compose.yml /opt/dockge/docker-compose.yml /opt/komari/docker-compose.yml /opt/*/compose.yaml /opt/*/compose.yml /opt/*/docker-compose.yml /opt/*/docker-compose.yaml; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Compose $(basename "$(dirname "$conf_file")")/$(basename "$conf_file")" "$conf_file" "compose"
    done
}

validate_xray_routes_file() {
    local target_file="$1"
    awk -F'|' '
        /^[[:space:]]*($|#)/ { next }
        { for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
        NF != 3 { exit 1 }
        $1 == "" || $2 == "" || $3 !~ /^[0-9]+$/ || $3 < 1 || $3 > 65535 { exit 1 }
    ' "$target_file"
}

validate_hosts_file() {
    local target_file="$1"
    awk '
        /^[[:space:]]*($|#)/ { next }
        NF < 2 { exit 1 }
    ' "$target_file"
}

validate_hostname_file() {
    local target_file="$1"
    local hostname_value
    hostname_value=$(head -n1 "$target_file" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$hostname_value" && "$hostname_value" != *"/"* ]]
}

validate_json_file() {
    local target_file="$1"
    if command -v jq >/dev/null 2>&1; then
        jq empty "$target_file"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$target_file" >/dev/null
    else
        echo -e "${YELLOW}⚠️ jq/python3 не обнаружены, проверка синтаксиса JSON пропущена.${PLAIN}"
        return 0
    fi
}

load_docker_compose_runtime_helper() {
    local helper_path
    local -a helper_paths=()

    declare -F ensure_docker_compose_ready >/dev/null 2>&1 && return 0

    if [[ -n "${SCRIPT_DIR:-}" ]]; then
        helper_paths+=("${SCRIPT_DIR}/src/compose_runtime.sh")
    fi
    helper_paths+=("$(dirname "${BASH_SOURCE[0]}")/compose_runtime.sh")

    for helper_path in "${helper_paths[@]}"; do
        [[ -f "$helper_path" ]] || continue
        # shellcheck source=/dev/null
        . "$helper_path"
        declare -F ensure_docker_compose_ready >/dev/null 2>&1 && return 0
    done

    return 1
}

run_applied_config_compose() {
    local target_file="$1"
    local project_dir
    shift

    if ! load_docker_compose_runtime_helper; then
        echo -e "${RED}❌ Логика автоматической установки/обнаружения Docker Compose не загружена, невозможно применить операции Compose.${PLAIN}"
        return 1
    fi

    ensure_docker_compose_ready || return 1
    project_dir=$(dirname "$target_file")
    (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$target_file" "$@")
}

validate_applied_config_kind() {
    local kind="$1"
    local target_file="$2"

    case "$kind" in
        caddy)
            command -v caddy >/dev/null 2>&1 || { echo -e "${RED}❌ Команда caddy не обнаружена, невозможно проверить конфигурацию.${PLAIN}"; return 1; }
            caddy validate --config /etc/caddy/Caddyfile
            ;;
        nginx)
            command -v nginx >/dev/null 2>&1 || { echo -e "${RED}❌ Команда nginx не обнаружена, невозможно проверить конфигурацию.${PLAIN}"; return 1; }
            nginx -t
            ;;
        systemd)
            if command -v systemd-analyze >/dev/null 2>&1; then
                systemd-analyze verify "$target_file"
            else
                echo -e "${YELLOW}⚠️ systemd-analyze не обнаружен, статическая проверка systemd unit пропущена.${PLAIN}"
            fi
            ;;
        docker-json|xui-json)
            validate_json_file "$target_file"
            ;;
        compose)
            run_applied_config_compose "$target_file" config >/dev/null
            ;;
        ssh)
            command -v sshd >/dev/null 2>&1 || { echo -e "${RED}❌ Команда sshd не обнаружена, невозможно проверить конфигурацию SSH.${PLAIN}"; return 1; }
            sshd -t
            ;;
        vpso-mux)
            if declare -F run_vpso_mux_config_check >/dev/null 2>&1; then
                run_vpso_mux_config_check "$target_file"
            elif [[ -x /usr/local/bin/vpso-mux ]]; then
                /usr/local/bin/vpso-mux -config "$target_file" -check
            else
                echo -e "${YELLOW}⚠️ Бинарный файл vpso-mux не обнаружен, проверка конфигурации во время выполнения пропущена.${PLAIN}"
            fi
            ;;
        entry-mode|traffic-guard|env)
            bash -n "$target_file"
            ;;
        xray-routes)
            validate_xray_routes_file "$target_file"
            ;;
        hosts)
            validate_hosts_file "$target_file"
            ;;
        hostname)
            validate_hostname_file "$target_file"
            ;;
        dns|sysctl)
            return 0
            ;;
        fail2ban)
            if command -v fail2ban-client >/dev/null 2>&1; then
                fail2ban-client -t
            else
                echo -e "${YELLOW}⚠️ fail2ban-client не обнаружен, проверка конфигурации Fail2ban пропущена.${PLAIN}"
            fi
            ;;
        *)
            echo -e "${YELLOW}⚠️ Неизвестный тип конфигурации ${kind}, только сохранение резервной копии, дополнительная проверка не выполняется.${PLAIN}"
            ;;
    esac
}

restart_named_service_if_available() {
    local service_name="$1"
    local rc
    restart_service_if_available "$service_name"
    rc=$?
    [[ "$rc" -eq 0 || "$rc" -eq 2 ]]
}

reload_applied_config_kind() {
    local kind="$1"
    local target_file="$2"
    local previous_file="${3:-}"
    local confirm unit_name

    case "$kind" in
        caddy)
            systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1
            ;;
        nginx)
            systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
            ;;
        systemd)
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            unit_name=$(basename "$target_file")
            read_trimmed confirm "systemd выполнил daemon-reload, перезапустить/перезагрузить ${unit_name} сейчас? (y/n, по умолчанию n): "
            if is_yes "$confirm"; then
                systemctl try-reload-or-restart "$unit_name" >/dev/null 2>&1 || systemctl restart "$unit_name" >/dev/null 2>&1
            else
                echo -e "${BLUE}Изменения unit сохранены, ${unit_name} не перезапущен.${PLAIN}"
            fi
            ;;
        docker-json)
            read_trimmed confirm "Docker daemon.json проверен, перезапустить Docker сейчас, чтобы изменения вступили в силу? (y/n, по умолчанию n): "
            if is_yes "$confirm"; then
                restart_named_service_if_available docker
            else
                echo -e "${YELLOW}⚠️ Docker не перезапущен, изменения в daemon.json пока не вступили в силу.${PLAIN}"
            fi
            ;;
        compose)
            read_trimmed confirm "Конфигурация Compose проверена, выполнить up -d для применения изменений? (y/n, по умолчанию n): "
            if is_yes "$confirm"; then
                run_applied_config_compose "$target_file" up -d
            else
                echo -e "${YELLOW}⚠️ Изменения Compose сохранены, но контейнеры не пересозданы.${PLAIN}"
            fi
            ;;
        ssh)
            if confirm_risk_action "Перезапустить службу SSH" \
                "Текущее состояние службы SSH" \
                "Восстановите ${target_file}.bak_* из текущей неразорванной SSH-сессии или через консоль облачного провайдера" \
                "Убедитесь, что новая конфигурация SSH прошла проверку sshd -t."; then
                restart_service_if_available sshd >/dev/null 2>&1 || restart_service_if_available ssh >/dev/null 2>&1
            else
                echo -e "${YELLOW}⚠️ SSH не перезапущен, изменения могут не вступить в силу.${PLAIN}"
            fi
            ;;
        vpso-mux)
            if confirm_risk_action "Перезапустить vpso-mux" \
                "Процесс分流ера (маршрутизатора) TCP Peek/vpso-mux" \
                "Восстановите ${target_file}.bak_* из текущей SSH-сессии или вернитесь в меню 443 для повторного применения/отката режима входа" \
                "Убедитесь, что текущий режим входа на публичном 443 и бэкенд-порты на хосте работают корректно."; then
                restart_named_service_if_available vpso-mux
            else
                echo -e "${YELLOW}⚠️ vpso-mux не перезапущен, изменения могут не вступить в силу.${PLAIN}"
            fi
            ;;
        entry-mode|xray-routes)
            if declare -F reapply_current_entry_mode >/dev/null 2>&1; then
                if confirm_risk_action "Повторно применить текущий режим входа 443" \
                    "Конфигурация входа на публичном 443, маршруты Caddy/Nginx/vpso-mux/Xray" \
                    "Скрипт создаст резервную копию режима входа и откатит при сбое; также можно восстановить из центра резервного копирования" \
                    "Убедитесь, что домены, порты и значение ENTRY_MODE в конфигурационных файлах совпадают."; then
                    reapply_current_entry_mode
                else
                    echo -e "${YELLOW}⚠️ Конфигурация сохранена, но режим входа 443 не был повторно применен.${PLAIN}"
                fi
            else
                echo -e "${YELLOW}⚠️ Конфигурация сохранена; вернитесь в меню 443 и повторно примените текущий режим входа.${PLAIN}"
            fi
            ;;
        traffic-guard)
            if [[ -n "$previous_file" ]] && declare -F traffic_guard_restore_ssh_only_firewall_from_config >/dev/null 2>&1; then
                traffic_guard_restore_ssh_only_firewall_from_config "$previous_file" || {
                    echo -e "${RED}❌ Не удалось снять правила блокировки с сохранением только SSH, применённые до редактирования, применение отменено.${PLAIN}"
                    return 1
                }
            fi
            if confirm_risk_action "Перезапустить таймер Traffic Guard" \
                "vps-traffic-guard.timer и период проверки порога трафика" \
                "Перередактируйте ${target_file} или восстановите из ${target_file}.bak_*; при необходимости отключите vps-traffic-guard.timer" \
                "Если ACTION=poweroff, убедитесь в порогах, периоде биллинга и способе восстановления у провайдера."; then
                systemctl daemon-reload >/dev/null 2>&1 || true
                systemctl restart vps-traffic-guard.timer >/dev/null 2>&1
            else
                echo -e "${YELLOW}⚠️ Таймер Traffic Guard не перезапущен, убедитесь, что конфигурация вступит в силу при следующем запуске.${PLAIN}"
            fi
            ;;
        hostname)
            local hostname_value
            hostname_value=$(head -n1 "$target_file" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$hostname_value" ]]; then
                hostnamectl set-hostname "$hostname_value" >/dev/null 2>&1 || hostname "$hostname_value" 2>/dev/null || true
            fi
            ;;
        dns)
            if confirm_risk_action "Перезапустить systemd-resolved" \
                "Служба DNS-разрешения системы и конфигурация resolved drop-in" \
                "Восстановите ${target_file}.bak_* или вернитесь в меню оптимизации DNS для переключения на исходную конфигурацию" \
                "Убедитесь, что текущая SSH-сессия сохраняется, при необходимости можно использовать прямой IP для устранения неполадок."; then
                restart_named_service_if_available systemd-resolved
            else
                echo -e "${BLUE}Конфигурация DNS сохранена, systemd-resolved не перезапущен.${PLAIN}"
            fi
            ;;
        sysctl)
            if confirm_risk_action "Применить конфигурацию sysctl" \
                "Текущие параметры sysctl работающего ядра" \
                "Восстановите ${target_file}.bak_* и выполните sysctl --system, или вручную откатите проблемные параметры" \
                "Убедитесь в надёжности источника параметров; ошибочные сетевые параметры могут нарушить удалённое соединение."; then
                sysctl --system >/dev/null
            else
                echo -e "${YELLOW}⚠️ Изменения sysctl пока не применены к работающему ядру.${PLAIN}"
            fi
            ;;
        fail2ban)
            if confirm_risk_action "Перезапустить fail2ban" \
                "Служба Fail2ban и правила защиты входа" \
                "Восстановите ${target_file}.bak_* и перезапустите fail2ban, или временно отключите проблемный jail" \
                "Убедитесь, что текущий источник SSH не будет ошибочно заблокирован новыми правилами."; then
                restart_named_service_if_available fail2ban
            else
                echo -e "${YELLOW}⚠️ Fail2ban не перезапущен, изменения могут не вступить в силу.${PLAIN}"
            fi
            ;;
        xui-json)
            if confirm_risk_action "Перезапустить x-ui/3x-ui" \
                "Процесс панели x-ui/3x-ui и рабочая конфигурация config.json" \
                "Восстановите ${target_file}.bak_* и перезапустите панель, или используйте официальную команду x-ui/3x-ui для входа в меню управления и восстановления" \
                "Убедитесь, что порт панели, путь к сертификатам и настройки единого входа 443 совпадают."; then
                restart_named_service_if_available x-ui
                restart_named_service_if_available 3x-ui
            else
                echo -e "${YELLOW}⚠️ x-ui/3x-ui не перезапущен, изменения могут не вступить в силу.${PLAIN}"
            fi
            ;;
        env|hosts)
            echo -e "${BLUE}Конфигурация сохранена; этот файл обычно считывается системой или скриптом позднее, немедленная перезагрузка не требуется.${PLAIN}"
            ;;
        *)
            echo -e "${BLUE}Конфигурация сохранена; автоматическая перезагрузка для ${kind} не определена.${PLAIN}"
            ;;
    esac
}

edit_applied_config_file() {
    local target_file="$1"
    local target_kind="$2"
    local target_label="${3:-$1}"
    local backup_file editor confirm rollback_confirm

    [[ -e "$target_file" || -L "$target_file" ]] || { echo -e "${RED}❌ Файл не существует: ${target_file}${PLAIN}"; return 1; }
    [[ -f "$target_file" || -L "$target_file" ]] || { echo -e "${RED}❌ Не является обычным конфигурационным файлом: ${target_file}${PLAIN}"; return 1; }

    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    echo -e "${BOLD}Текущий файл: ${target_label}${PLAIN}"
    echo -e "${CYAN}${target_file}${PLAIN}"
    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    nl -ba "$target_file"
    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    read_trimmed confirm "Открыть редактор для изменения этого файла? (y/n, по умолчанию n): "
    is_yes "$confirm" || return 0

    editor=$(applied_config_editor_command) || {
        echo -e "${RED}❌ Не найден доступный редактор. Установите nano/vim/vi или установите EDITOR.${PLAIN}"
        return 1
    }
    backup_file="${target_file}.bak_$(date +%s)"
    cp -p "$target_file" "$backup_file" || { echo -e "${RED}❌ Не удалось создать резервную копию, редактирование отменено.${PLAIN}"; return 1; }
    echo -e "${CYAN}Резервная копия перед редактированием: ${backup_file}${PLAIN}"

    "$editor" "$target_file" || {
        echo -e "${RED}❌ Редактор завершился с ошибкой, конфигурация не перезагружена.${PLAIN}"
        return 1
    }

    if cmp -s "$target_file" "$backup_file"; then
        echo -e "${BLUE}Конфигурация не изменилась.${PLAIN}"
        return 0
    fi

    echo -e "${CYAN}▶ Выполняется проверка конфигурации...${PLAIN}"
    if ! validate_applied_config_kind "$target_kind" "$target_file"; then
        echo -e "${RED}❌ Проверка не удалась, служба не будет перезагружена.${PLAIN}"
        read_trimmed rollback_confirm "Восстановить резервную копию до редактирования? (Y/n, по умолчанию yes): "
        if ! is_no "$rollback_confirm"; then
            cp -p "$backup_file" "$target_file" && echo -e "${GREEN}✅ Восстановлено: ${target_file}${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Оставлены изменения, не прошедшие проверку, исправьте их вручную перед применением.${PLAIN}"
        fi
        return 1
    fi

    if reload_applied_config_kind "$target_kind" "$target_file" "$backup_file"; then
        echo -e "${GREEN}✅ Конфигурация сохранена и выполнены возможные шаги проверки/применения.${PLAIN}"
        echo -e "${CYAN}Резервный файл: ${backup_file}${PLAIN}"
    else
        echo -e "${RED}❌ Проверка конфигурации пройдена, но применение/перезагрузка не удались.${PLAIN}"
        read_trimmed rollback_confirm "Восстановить резервную копию до редактирования? (Y/n, по умолчанию yes): "
        if ! is_no "$rollback_confirm"; then
            cp -p "$backup_file" "$target_file" && reload_applied_config_kind "$target_kind" "$target_file" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ Попытка восстановления конфигурации до редактирования выполнена.${PLAIN}"
        fi
        return 1
    fi
}

func_edit_applied_config_center() {
    local scope="${1:-all}"
    local -a applied_config_labels=()
    local -a applied_config_paths=()
    local -a applied_config_kinds=()
    collect_applied_config_files "$scope"

    clear
    echo -e "${CYAN}================================================${PLAIN}"
    if [[ "$scope" == "proxy" ]]; then
        echo -e "${BOLD}📝 Просмотр/редактирование применённых конфигураций обратного прокси${PLAIN}"
    else
        echo -e "${BOLD}📝 Просмотр/редактирование применённых скриптом конфигураций${PLAIN}"
    fi
    echo -e "${CYAN}================================================${PLAIN}"
    if [[ ${#applied_config_paths[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Не обнаружено редактируемых применённых конфигурационных файлов.${PLAIN}"
        return 0
    fi

    local i
    for i in "${!applied_config_paths[@]}"; do
        printf '%b%3d. %s%b\n' "$GREEN" "$((i + 1))" "${applied_config_labels[$i]} -> ${applied_config_paths[$i]}" "$PLAIN"
    done
    echo -e "${RED}  0. Отмена${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local choice idx
    read_trimmed choice "Выберите конфигурационный файл для просмотра/редактирования: "
    [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" ]] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#applied_config_paths[@]} )); then
        echo -e "${RED}❌ Неверный выбор.${PLAIN}"
        return 1
    fi

    idx=$((choice - 1))
    edit_applied_config_file "${applied_config_paths[$idx]}" "${applied_config_kinds[$idx]}" "${applied_config_labels[$idx]}"
}

func_backup_center() {
    local backup_root="/etc/vps-optimize/backups/manual"
    mkdir -p "$backup_root"
    chmod 700 "$backup_root" 2>/dev/null || true

    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Резервное копирование и откат"
        echo -e "${BOLD}🗂️ Центр резервного копирования и отката конфигураций${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "Текущий каталог резервных копий: ${YELLOW}${backup_root}${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Создать полную резервную копию конфигурации${PLAIN}       ${YELLOW}(система/панели/Caddy/конфиги скрипта)${PLAIN}"
        echo -e "${GREEN}  2. Просмотреть список существующих резервных копий${PLAIN}"
        echo -e "${GREEN}  3. Одним нажатием выполнить откат из резервной копии${PLAIN}"
        echo -e "${GREEN}  4. Изолировать старые резервные копии${PLAIN}             ${YELLOW}(оставить только последние 5, старые переместить в карантин)${PLAIN}"
        echo -e "${CYAN}  5. Просмотр/редактирование применённых скриптом конфигураций${PLAIN} ${YELLOW}(резервирование, проверка, выбор reload/restart)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться в главное меню / q вернуться на уровень выше${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local b_choice
        read_trimmed b_choice "👉 Выберите действие: "

        case $b_choice in
            1)
                local ts
                ts=$(date +%Y%m%d_%H%M%S)
                local work_dir
                local tar_file="${backup_root}/backup_${ts}.tar.gz"
                local manifest_file
                local copied=0

                work_dir=$(make_secure_temp_dir "vps_backup_${ts}") || {
                    echo -e "${RED}❌ Не удалось создать безопасный временный каталог, резервное копирование отменено.${PLAIN}"
                    sleep 2
                    continue
                }
                manifest_file="${work_dir}/manifest.txt"
                {
                    echo "Манифест резервной копии VPS-Optimize"
                    echo "Создано: $(date -Is 2>/dev/null || date)"
                    echo "Файл резервной копии: ${tar_file}"
                    echo "Включённые пути:"
                } > "$manifest_file"

                backup_copy_path /etc/ssh/sshd_config etc/ssh/sshd_config "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/hostname etc/hostname "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/hosts etc/hosts "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/nginx.conf etc/nginx/nginx.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/stream.d etc/nginx/stream.d "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/conf.d etc/nginx/conf.d "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/sites-available etc/nginx/sites-available "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/sites-enabled etc/nginx/sites-enabled "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/caddy/Caddyfile etc/caddy/Caddyfile "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/caddy/conf.d etc/caddy/conf.d "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/caddy/certs etc/caddy/certs "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /root/cert root/cert "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /root/.acme.sh root/.acme.sh "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /root/.config/vps-panel/cloudflare.env root/.config/vps-panel/cloudflare.env "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/sni-stack.env etc/vps-optimize/sni-stack.env "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/sni-stack.last-backup etc/vps-optimize/sni-stack.last-backup "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/443-engine.conf etc/vps-optimize/443-engine.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/vpso-mux.yaml etc/vps-optimize/vpso-mux.yaml "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/systemd/system/vpso-mux.service etc/systemd/system/vpso-mux.service "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /usr/local/bin/vpso-mux usr/local/bin/vpso-mux "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/traffic-guard.conf etc/vps-optimize/traffic-guard.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /var/lib/vps-optimize/traffic-guard var/lib/vps-optimize/traffic-guard "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /usr/local/bin/vps-traffic-guard-check usr/local/bin/vps-traffic-guard-check "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/systemd/system/vps-traffic-guard.service etc/systemd/system/vps-traffic-guard.service "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/systemd/system/vps-traffic-guard.timer etc/systemd/system/vps-traffic-guard.timer "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/resolv.conf etc/resolv.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/docker/daemon.json etc/docker/daemon.json "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/fail2ban/jail.local etc/fail2ban/jail.local "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/sysctl.d etc/sysctl.d "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/x-ui etc/x-ui "$manifest_file" "$work_dir" && copied=1
                backup_copy_xui_databases "$manifest_file" "$work_dir" && copied=1

                if [[ "$copied" -eq 0 ]]; then
                    quarantine_path "$work_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                    echo -e "${YELLOW}⚠️ Не обнаружено конфигурационных файлов для резервирования, создание отменено.${PLAIN}"
                else
                    if ( umask 077 && tar -czf "$tar_file" -C "$work_dir" . ) >/dev/null 2>&1; then
                        chmod 600 "$tar_file" 2>/dev/null || true
                        echo -e "${GREEN}✅ Резервная копия создана: ${tar_file}${PLAIN}"
                        echo -e "${YELLOW}⚠️ Резервная копия содержит закрытые ключи сертификатов, базы данных панелей и API-токены, храните её в надёжном месте.${PLAIN}"
                    else
                        echo -e "${RED}❌ Не удалось упаковать резервную копию, проверьте свободное место на диске и права доступа.${PLAIN}"
                    fi
                    quarantine_path "$work_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                fi
                ;;

            2)
                local backups
                backups=$(ls -1t "$backup_root"/backup_*.tar.gz 2>/dev/null)
                if [[ -z "$backups" ]]; then
                    echo -e "${YELLOW}⚠️ Нет доступных резервных копий.${PLAIN}"
                else
                    echo -e "${CYAN}👇 Список резервных копий (новые -> старые):${PLAIN}"
                    local idx=1
                    while IFS= read -r f; do
                        echo -e "  ${GREEN}${idx}.${PLAIN} $(basename "$f")"
                        idx=$((idx+1))
                    done <<< "$backups"
                fi
                ;;

            3)
                mapfile -t backups < <(ls -1t "$backup_root"/backup_*.tar.gz 2>/dev/null)
                if [[ ${#backups[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}⚠️ Нет доступных резервных копий, откат невозможен.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                echo -e "${CYAN}👇 Доступные резервные копии для отката:${PLAIN}"
                for i in "${!backups[@]}"; do
                    echo -e "  ${GREEN}$((i+1)).${PLAIN} $(basename "${backups[$i]}")"
                done

                local r_choice
                read_trimmed r_choice "👉 Введите номер резервной копии для отката: "
                if ! [[ "$r_choice" =~ ^[0-9]+$ ]] || [[ "$r_choice" -lt 1 ]] || [[ "$r_choice" -gt ${#backups[@]} ]]; then
                    echo -e "${RED}❌ Неверный номер, откат отменён.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                local target_file="${backups[$((r_choice-1))]}"
                confirm_danger "Откат системной конфигурации из резервной копии" "Будут перезаписаны текущие конфигурации SSH, Caddy, Docker, Fail2ban, sysctl и другие, включённые в резервную копию." "После отката скрипт попытается перезапустить соответствующие службы; сохраните текущую SSH-сессию и будьте готовы использовать консоль восстановления провайдера." || {
                    echo -e "${BLUE}Откат отменён.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                }

                local restore_dir
                local restore_failed=0
                local restore_quarantine="/etc/vps-optimize/quarantine/manual-restore"
                restore_dir=$(make_secure_temp_dir "vps_restore") || {
                    echo -e "${RED}❌ Не удалось создать безопасный временный каталог, откат прерван.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                }

                if ! tar -tzf "$target_file" >/dev/null 2>&1; then
                    quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                    echo -e "${RED}❌ Не удалось прочитать файл резервной копии, откат прерван.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi
                if tar -tzf "$target_file" 2>/dev/null | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
                    quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                    echo -e "${RED}❌ Файл резервной копии содержит"
