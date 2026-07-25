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
        "https://raw.githubusercontent.com/AlexeyLCP/lucx-ui/main/install.sh"|\
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
                    echo -e "${RED}❌ Файл резервной копии содержит небезопасные пути, откат прерван.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if ! tar -xzf "$target_file" -C "$restore_dir" >/dev/null 2>&1; then
                    quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                    echo -e "${RED}❌ Не удалось распаковать резервную копию, откат прерван.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if [[ -f "$restore_dir/etc/vps-optimize/traffic-guard.conf" || -f "$restore_dir/usr/local/bin/vps-traffic-guard-check" ]]; then
                    if declare -F traffic_guard_restore_ssh_only_firewall >/dev/null 2>&1 && ! traffic_guard_restore_ssh_only_firewall; then
                        quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                        echo -e "${RED}❌ Не удалось снять текущие правила блокировки с сохранением только SSH, откат прерван.${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    fi
                fi

                restore_backup_file "$restore_dir/etc/ssh/sshd_config" /etc/ssh/sshd_config || restore_failed=1
                restore_backup_file "$restore_dir/etc/hostname" /etc/hostname || restore_failed=1
                restore_backup_file "$restore_dir/etc/hosts" /etc/hosts || restore_failed=1
                restore_backup_file "$restore_dir/etc/nginx/nginx.conf" /etc/nginx/nginx.conf || restore_failed=1
                restore_backup_dir "$restore_dir/etc/nginx/stream.d" /etc/nginx/stream.d "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/nginx/conf.d" /etc/nginx/conf.d "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/nginx/sites-available" /etc/nginx/sites-available "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/nginx/sites-enabled" /etc/nginx/sites-enabled "$restore_quarantine" || restore_failed=1
                restore_backup_file "$restore_dir/etc/caddy/Caddyfile" /etc/caddy/Caddyfile || restore_failed=1
                restore_backup_dir "$restore_dir/etc/caddy/conf.d" /etc/caddy/conf.d "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/caddy/certs" /etc/caddy/certs "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/root/cert" /root/cert "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/root/.acme.sh" /root/.acme.sh "$restore_quarantine" || restore_failed=1
                restore_backup_file "$restore_dir/root/.config/vps-panel/cloudflare.env" /root/.config/vps-panel/cloudflare.env || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/sni-stack.env" /etc/vps-optimize/sni-stack.env || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/sni-stack.last-backup" /etc/vps-optimize/sni-stack.last-backup || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/443-engine.conf" /etc/vps-optimize/443-engine.conf || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/vpso-mux.yaml" /etc/vps-optimize/vpso-mux.yaml || restore_failed=1
                restore_backup_file "$restore_dir/etc/systemd/system/vpso-mux.service" /etc/systemd/system/vpso-mux.service || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/bin/vpso-mux" /usr/local/bin/vpso-mux || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/traffic-guard.conf" /etc/vps-optimize/traffic-guard.conf || restore_failed=1
                restore_backup_dir "$restore_dir/var/lib/vps-optimize/traffic-guard" /var/lib/vps-optimize/traffic-guard "$restore_quarantine" || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/bin/vps-traffic-guard-check" /usr/local/bin/vps-traffic-guard-check || restore_failed=1
                restore_backup_file "$restore_dir/etc/systemd/system/vps-traffic-guard.service" /etc/systemd/system/vps-traffic-guard.service || restore_failed=1
                restore_backup_file "$restore_dir/etc/systemd/system/vps-traffic-guard.timer" /etc/systemd/system/vps-traffic-guard.timer || restore_failed=1
                restore_backup_file "$restore_dir/etc/resolv.conf" /etc/resolv.conf || restore_failed=1
                restore_backup_file "$restore_dir/etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf" /etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf || restore_failed=1
                restore_backup_file "$restore_dir/etc/docker/daemon.json" /etc/docker/daemon.json || restore_failed=1
                restore_backup_file "$restore_dir/etc/fail2ban/jail.local" /etc/fail2ban/jail.local || restore_failed=1
                restore_backup_dir "$restore_dir/etc/sysctl.d" /etc/sysctl.d "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/x-ui" /etc/x-ui "$restore_quarantine" || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/x-ui.db" /usr/local/x-ui/x-ui.db || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/x-ui.db-wal" /usr/local/x-ui/x-ui.db-wal || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/x-ui.db-shm" /usr/local/x-ui/x-ui.db-shm || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/bin/x-ui.db" /usr/local/x-ui/bin/x-ui.db || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/bin/x-ui.db-wal" /usr/local/x-ui/bin/x-ui.db-wal || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/bin/x-ui.db-shm" /usr/local/x-ui/bin/x-ui.db-shm || restore_failed=1

                if [[ -d "$restore_dir/etc/sysctl.d" ]]; then
                    sysctl --system >/dev/null 2>&1
                fi
                if [[ -f "$restore_dir/etc/hostname" ]]; then
                    local restored_hostname
                    restored_hostname=$(cat /etc/hostname 2>/dev/null | head -n1)
                    restored_hostname="$(trim_input "$restored_hostname")"
                    if [[ -n "$restored_hostname" ]]; then
                        hostnamectl set-hostname "$restored_hostname" >/dev/null 2>&1 || hostname "$restored_hostname" 2>/dev/null || true
                    fi
                fi
                if [[ -f "$restore_dir/etc/systemd/system/vps-traffic-guard.timer" || -f "$restore_dir/etc/systemd/system/vps-traffic-guard.service" || -f "$restore_dir/etc/systemd/system/vpso-mux.service" ]]; then
                    systemctl daemon-reload >/dev/null 2>&1 || true
                fi

                local restart_failed=0
                local restart_rc=0
                restart_service_if_available sshd
                restart_rc=$?
                if [[ "$restart_rc" -eq 2 ]]; then
                    restart_service_if_available ssh
                    restart_rc=$?
                fi
                [[ "$restart_rc" -eq 1 ]] && restart_failed=1

                for svc in nginx caddy docker fail2ban systemd-resolved x-ui 3x-ui xray sing-box vpso-mux; do
                    restart_service_if_available "$svc"
                    restart_rc=$?
                    [[ "$restart_rc" -eq 1 ]] && restart_failed=1
                done

                quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                if [[ "$restore_failed" -eq 0 && "$restart_failed" -eq 0 ]]; then
                    echo -e "${GREEN}✅ Откат выполнен! Рекомендуется сразу проверить состояние SSH, обратного прокси и контейнеров.${PLAIN}"
                elif [[ "$restore_failed" -ne 0 ]]; then
                    echo -e "${YELLOW}⚠️ Часть файлов не удалось восстановить, проверьте права доступа, свободное место и ${restore_quarantine}.${PLAIN}"
                else
                    echo -e "${YELLOW}⚠️ Файлы отката записаны, но как минимум одна служба не перезапустилась, немедленно проверьте systemctl status.${PLAIN}"
                fi
                ;;

            4)
                mapfile -t backups < <(ls -1t "$backup_root"/backup_*.tar.gz 2>/dev/null)
                if [[ ${#backups[@]} -le 5 ]]; then
                    echo -e "${BLUE}Количество резервных копий не превышает 5, очистка не требуется.${PLAIN}"
                else
                    confirm_danger "Изоляция старых резервных копий" "Копии, начиная с 6-й и старше, будут перемещены в карантинный каталог, без непосредственного удаления." "При необходимости их можно восстановить вручную из /etc/vps-optimize/quarantine/manual-backups. Последние 5 копий останутся нетронутыми." || {
                        echo -e "${BLUE}Изоляция старых копий отменена.${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    }
                    for i in "${!backups[@]}"; do
                        if [[ "$i" -ge 5 ]]; then
                            quarantine_path "${backups[$i]}" "/etc/vps-optimize/quarantine/manual-backups" >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ Не удалось изолировать: ${backups[$i]}${PLAIN}"
                        fi
                    done
                    echo -e "${GREEN}✅ Изоляция старых копий выполнена, последние 5 резервных копий сохранены.${PLAIN}"
                fi
                ;;

            5)
                func_edit_applied_config_center
                ;;

            "?"|help) show_backup_help ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}" ;;
        esac

        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}

# ---------------------------------------------------------
# Module: runtime.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Проверка прав выполнения перед запуском меню.

# --- Проверка прав ---
ensure_runtime_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Ошибка: запустите скрипт от root!${PLAIN}"
        exit 1
    fi
}

# ---------------------------------------------------------
# Module: system_core.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Базовая инициализация системы, hostname, hosts и системные переключатели.

configure_system_timezone_for_init() {
    local current_tz choice custom_tz target_tz

    if ! command -v timedatectl >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ timedatectl не обнаружен, часовой пояс системы остаётся прежним.${PLAIN}"
        return 0
    fi

    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ -z "$current_tz" ]] && current_tz="не установлен/неизвестен"

    echo -e "${CYAN}Текущий часовой пояс системы: ${current_tz}${PLAIN}"
    echo -e "${GREEN}  1. Оставить текущий${PLAIN} ${YELLOW}(по умолчанию)${PLAIN}"
    echo -e "${GREEN}  2. Asia/Shanghai${PLAIN}"
    echo -e "${GREEN}  3. Asia/Tokyo${PLAIN}"
    echo -e "${GREEN}  4. UTC${PLAIN}"
    echo -e "${GREEN}  5. Пользовательский${PLAIN}"
    read_trimmed choice "Выберите способ настройки часового пояса (по умолчанию 1): "

    case "${choice:-1}" in
        1)
            echo -e "${BLUE}Оставлен текущий часовой пояс: ${current_tz}${PLAIN}"
            return 0
            ;;
        2) target_tz="Asia/Shanghai" ;;
        3) target_tz="Asia/Tokyo" ;;
        4) target_tz="UTC" ;;
        5)
            read_trimmed custom_tz "Введите название часового пояса IANA (например Europe/London): "
            target_tz="$custom_tz"
            ;;
        *)
            echo -e "${YELLOW}⚠️ Не выбран допустимый вариант, оставлен текущий: ${current_tz}${PLAIN}"
            return 0
            ;;
    esac

    if [[ -z "$target_tz" ]]; then
        echo -e "${YELLOW}⚠️ Пользовательский часовой пояс пуст, оставлен текущий: ${current_tz}${PLAIN}"
        return 0
    fi

    if timedatectl set-timezone "$target_tz" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Часовой пояс установлен: ${target_tz}${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ Не удалось установить часовой пояс, оставлен текущий: ${current_tz}${PLAIN}"
        return 1
    fi
}

func_base_init() {
    local failed_steps=()
    local current_cc current_qdisc

    clear
    echo -e "${CYAN}👉 Обновление пакетов, установка базовых инструментов, ограничение логов и включение базового BBR...${PLAIN}"

    if is_debian; then
        export DEBIAN_FRONTEND=noninteractive
        if apt-get update -y && apt-get upgrade -y; then
            APT_UPDATED=1
        else
            failed_steps+=("Обновление системных пакетов")
        fi
        unset DEBIAN_FRONTEND
        install_pkg sudo curl wget git nano unzip htop lsof net-tools iputils-ping dnsutils iptables iproute2 sqlite3 jq \
            || failed_steps+=("Установка базовых инструментов")
    elif is_redhat; then
        if command -v dnf >/dev/null 2>&1; then
            dnf update -y || failed_steps+=("Обновление системных пакетов")
        else
            yum update -y || failed_steps+=("Обновление системных пакетов")
        fi
        install_pkg sudo curl wget git nano unzip htop lsof net-tools iputils bind-utils iptables iproute epel-release sqlite jq \
            || failed_steps+=("Установка базовых инструментов")
    else
        failed_steps+=("Текущий дистрибутив не поддерживается")
    fi

    ensure_minimal_system_compat || failed_steps+=("Минимальные совместимые компоненты")

    if ! mkdir -p /etc/systemd/journald.conf.d/ || ! cat > /etc/systemd/journald.conf.d/99-limit.conf <<EOF
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=100M
EOF
    then
        failed_steps+=("Ограничение журнала journald")
    elif ! systemctl restart systemd-journald >/dev/null 2>&1; then
        failed_steps+=("Перезапуск journald")
    fi

    configure_system_timezone_for_init || failed_steps+=("Настройка часового пояса")

    modprobe tcp_bbr >/dev/null 2>&1 || true
    if ! {
        printf '%s\n' \
            "net.core.default_qdisc = fq" \
            "net.ipv4.tcp_congestion_control = bbr" \
            > /etc/sysctl.d/99-bbr-init.conf
    }; then
        failed_steps+=("Запись конфигурации BBR")
    elif ! sysctl -p /etc/sysctl.d/99-bbr-init.conf >/dev/null 2>&1; then
        failed_steps+=("Загрузка параметров BBR")
    else
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
        current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
        if [[ "$current_cc" != "bbr" || "$current_qdisc" != "fq" ]]; then
            failed_steps+=("Проверка состояния BBR")
        fi
    fi

    if [[ ${#failed_steps[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Базовая инициализация завершена, BBR и fq активированы.${PLAIN}"
        if [[ "${VPSO_BEGINNER_FLOW:-0}" != "1" ]]; then
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата в главное меню..."
        fi
        return 0
    fi

    echo -e "${RED}❌ Базовая инициализация не завершена полностью, ошибки:${PLAIN}"
    printf '  - %s\n' "${failed_steps[@]}"
    echo -e "${YELLOW}Успешные шаги сохранены; исправьте указанные проблемы и запустите инициализацию снова.${PLAIN}"
    if [[ "${VPSO_BEGINNER_FLOW:-0}" != "1" ]]; then
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата в главное меню..."
    fi
    return 1
}

update_hosts_hostname_entry() {
    local old_name="$1"
    local new_name="$2"
    local tmp_file

    tmp_file=$(mktemp /tmp/vps-hosts.XXXXXX) || return 1
    awk -v old="$old_name" -v new="$new_name" '
        BEGIN { updated = 0 }
        $1 == "127.0.1.1" {
            print "127.0.1.1\t" new
            updated = 1
            next
        }
        {
            for (i = 2; i <= NF; i++) {
                if ($i == old) {
                    $i = new
                    updated = 1
                }
            }
            print
        }
        END {
            if (!updated) {
                print "127.0.1.1\t" new
            }
        }
    ' /etc/hosts > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    cp "$tmp_file" /etc/hosts
    rm -f "$tmp_file"
}

func_change_hostname() {
    local current_name new_name ts
    current_name=$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)
    current_name="$(trim_input "$current_name")"
    current_name="${current_name:-localhost}"

    echo -e "Текущее имя хоста: ${CYAN}${current_name}${PLAIN}"
    echo -e "${YELLOW}Имя хоста должно содержать только буквы, цифры, дефисы и точки; каждый сегмент не должен начинаться или заканчиваться дефисом.${PLAIN}"
    read_trimmed new_name "Введите новое имя хоста (Enter для отмены): "
    [[ -z "$new_name" || "$new_name" == "0" ]] && { echo -e "${BLUE}Изменение имени хоста отменено.${PLAIN}"; return 0; }

    if ! is_valid_hostname "$new_name"; then
        echo -e "${RED}❌ Неверный формат имени хоста. Пример: vps01 или node-1.example.com${PLAIN}"
        return 1
    fi

    if [[ "$new_name" == "$current_name" ]]; then
        echo -e "${BLUE}Имя хоста не изменилось.${PLAIN}"
        return 0
    fi

    confirm_risk_action "Изменить имя хоста на ${new_name}" \
        "/etc/hostname, /etc/hosts и текущее имя хоста" \
        "Верните ${current_name} через эту функцию или восстановите из /etc/*.bak_*" \
        "Некоторые службы могут не применить новое имя до перезагрузки." || return 1

    ts=$(date +%s)
    [[ -f /etc/hostname ]] && cp -p /etc/hostname "/etc/hostname.bak_${ts}" 2>/dev/null || true
    [[ -f /etc/hosts ]] && cp -p /etc/hosts "/etc/hosts.bak_${ts}" 2>/dev/null || true

    echo "$new_name" > /etc/hostname || {
        echo -e "${RED}❌ Ошибка записи /etc/hostname.${PLAIN}"
        return 1
    }

    if [[ -f /etc/hosts ]]; then
        update_hosts_hostname_entry "$current_name" "$new_name" || echo -e "${YELLOW}⚠️ Обновление /etc/hosts не удалось, проверьте вручную.${PLAIN}"
    else
        {
            echo "127.0.0.1	localhost"
            echo "127.0.1.1	$new_name"
        } > /etc/hosts
    fi

    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$new_name" >/dev/null 2>&1 || hostname "$new_name" 2>/dev/null || true
    else
        hostname "$new_name" 2>/dev/null || true
    fi

    echo -e "${GREEN}✅ Имя хоста изменено на: ${new_name}${PLAIN}"
    echo -e "${YELLOW}Если некоторые службы всё ещё показывают старое имя, перезапустите их или перезагрузите систему.${PLAIN}"
}

hosts_managed_marker() {
    printf '%s' '# VPS-Optimize local-hosts'
}

hosts_is_valid_ip() {
    local ip="$1"
    [[ "$ip" != */* ]] || return 1
    dns_is_valid_ipv4 "$ip" || dns_is_valid_ipv6 "$ip"
}

hosts_normalize_names() {
    local raw="$1"
    local -n out_array=$2
    local item normalized seen=" "
    raw="${raw//，/,}"
    raw="${raw//、/,}"
    raw="${raw//；/,}"
    raw="${raw//;/,}"
    raw="${raw//,/ }"
    out_array=()
    for item in $raw; do
        normalized=$(normalize_domain_input "$item")
        [[ -z "$normalized" ]] && continue
        if ! is_valid_hostname "$normalized"; then
            echo -e "${RED}❌ Неверный формат имени хоста/домена: ${normalized}${PLAIN}"
            return 1
        fi
        case "$normalized" in
            localhost|localhost.localdomain|ip6-localhost|ip6-loopback)
                echo -e "${RED}❌ Зарезервированные имена нельзя управлять: ${normalized}${PLAIN}"
                return 1
                ;;
        esac
        if [[ "$seen" != *" ${normalized} "* ]]; then
            out_array+=("$normalized")
            seen+=" ${normalized} "
        fi
    done
    [[ ${#out_array[@]} -gt 0 ]]
}

hosts_backup_current() {
    local backup_dir="/etc/vps-optimize/backups/hosts"
    local backup_file
    mkdir -p "$backup_dir" || return 1
    backup_file="${backup_dir}/hosts.$(date +%Y%m%d_%H%M%S).bak"
    if [[ -f /etc/hosts ]]; then
        cp -p /etc/hosts "$backup_file" || return 1
    else
        : > "$backup_file" || return 1
    fi
    printf '%s' "$backup_file"
}

hosts_remove_names_to_tmp() {
    local names_csv="$1"
    local tmp_file="$2"
    local hosts_file="/etc/hosts"
    [[ -f "$hosts_file" ]] || : > "$hosts_file"
    awk -v names_csv="$names_csv" '
        BEGIN {
            split(names_csv, names, ",")
            for (i in names) target[names[i]] = 1
        }
        /^[[:space:]]*#/ || NF == 0 { print; next }
        {
            keep = 0
            line = $1
            for (i = 2; i <= NF; i++) {
                if ($i == "#") break
                if (!($i in target)) {
                    line = line "\t" $i
                    keep = 1
                }
            }
            if (keep) print line
        }
    ' "$hosts_file" > "$tmp_file"
}

hosts_add_or_update_entry() {
    local ip names_input names_csv names_joined backup_file tmp_file
    local -a names=()
    read_trimmed ip "Введите IP-адрес для разрешения (IPv4/IPv6): "
    if ! hosts_is_valid_ip "$ip"; then
        echo -e "${RED}❌ Неверный формат IP.${PLAIN}"
        return 1
    fi
    read_trimmed names_input "Введите домены/имена хостов для привязки (несколько через пробел или запятую): "
    if ! hosts_normalize_names "$names_input" names; then
        return 1
    fi
    names_csv=$(IFS=','; printf '%s' "${names[*]}")
    names_joined=$(IFS=' '; printf '%s' "${names[*]}")
    confirm_risk_action "Запись локального разрешения hosts" \
        "Таблица локального разрешения /etc/hosts" \
        "Восстановите последнюю резервную копию из /etc/vps-optimize/backups/hosts или удалите запись в этом меню" \
        "Это влияет только на локальное разрешение на этом VPS, не изменяет публичный DNS." || return 1

    backup_file=$(hosts_backup_current) || {
        echo -e "${RED}❌ Не удалось создать резервную копию /etc/hosts, отмена.${PLAIN}"
        return 1
    }
    tmp_file=$(mktemp /tmp/vps-hosts.XXXXXX) || return 1
    if hosts_remove_names_to_tmp "$names_csv" "$tmp_file"; then
        printf '%s\t%s\t%s\n' "$ip" "$names_joined" "$(hosts_managed_marker)" >> "$tmp_file"
        cp "$tmp_file" /etc/hosts
        echo -e "${GREEN}✅ Записано локальное разрешение: ${ip} -> ${names_joined}${PLAIN}"
        echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
    else
        echo -e "${RED}❌ Ошибка создания временного файла hosts, отмена.${PLAIN}"
        rm -f "$tmp_file"
        return 1
    fi
    rm -f "$tmp_file"
}

hosts_remove_entry() {
    local names_input names_csv names_joined backup_file tmp_file
    local -a names=()
    read_trimmed names_input "Введите домены/имена хостов для удаления (несколько через пробел или запятую): "
    if ! hosts_normalize_names "$names_input" names; then
        return 1
    fi
    names_csv=$(IFS=','; printf '%s' "${names[*]}")
    names_joined=$(IFS=' '; printf '%s' "${names[*]}")
    confirm_risk_action "Удаление локального разрешения hosts" \
        "Записи в /etc/hosts, соответствующие ${names_joined}" \
        "Восстановите последнюю резервную копию из /etc/vps-optimize/backups/hosts" \
        "Удаляются только совпадающие имена, другие псевдонимы в строке сохраняются." || return 1

    backup_file=$(hosts_backup_current) || {
        echo -e "${RED}❌ Не удалось создать резервную копию /etc/hosts, отмена.${PLAIN}"
        return 1
    }
    tmp_file=$(mktemp /tmp/vps-hosts.XXXXXX) || return 1
    if hosts_remove_names_to_tmp "$names_csv" "$tmp_file"; then
        cp "$tmp_file" /etc/hosts
        echo -e "${GREEN}✅ Удалены совпадающие записи: ${names_joined}${PLAIN}"
        echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
    else
        echo -e "${RED}❌ Ошибка создания временного файла hosts, отмена.${PLAIN}"
        rm -f "$tmp_file"
        return 1
    fi
    rm -f "$tmp_file"
}

hosts_restore_latest_backup() {
    local latest
    latest=$(find /etc/vps-optimize/backups/hosts -maxdepth 1 -type f -name 'hosts.*.bak' 2>/dev/null | sort -r | head -n1)
    if [[ -z "$latest" ]]; then
        echo -e "${YELLOW}Не найдено резервных копий hosts.${PLAIN}"
        return 1
    fi
    confirm_risk_action "Восстановление последней резервной копии hosts" \
        "/etc/hosts будет восстановлен из ${latest}" \
        "Вернитесь в это меню и добавьте/удалите записи, или восстановите вручную" \
        "Восстановление перезапишет текущее локальное разрешение." || return 1
    cp -p "$latest" /etc/hosts || {
        echo -e "${RED}❌ Ошибка восстановления.${PLAIN}"
        return 1
    }
    echo -e "${GREEN}✅ Восстановлено: ${latest}${PLAIN}"
}

func_hosts_manage() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Системные переключатели и очистка > Управление локальным hosts"
        echo -e "${BOLD}🧭 Управление локальным разрешением hosts${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: изменение /etc/hosts на текущем VPS для локального разрешения доменов на указанный IP. Не влияет на публичный DNS.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Просмотр текущего /etc/hosts${PLAIN}"
        echo -e "${GREEN}  2. Добавить / обновить локальное разрешение${PLAIN}"
        echo -e "${YELLOW}  3. Удалить локальное разрешение${PLAIN}"
        echo -e "${CYAN}  4. Восстановить последнюю резервную копию hosts${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        local choice
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1)
                echo -e "${CYAN}--- /etc/hosts ---${PLAIN}"
                sed -n '1,120p' /etc/hosts 2>/dev/null || echo "/etc/hosts не обнаружен"
                pause_return
                ;;
            2) hosts_add_or_update_entry; pause_return ;;
            3) hosts_remove_entry; pause_return ;;
            4) hosts_restore_latest_backup; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# 2. Системные переключатели (исправлено отображение)
# ---------------------------------------------------------
func_system_tweaks() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}⚙️ Системные переключатели и очистка${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        # Получение статусов
        local ipv6_status
        local str_ipv6
        ipv6_status=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        if [[ "$ipv6_status" == "0" ]]; then str_ipv6="${GREEN}Включён${PLAIN}"; else str_ipv6="${RED}Отключён${PLAIN}"; fi

        local str_ipv4_first
        if grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
            str_ipv4_first="${GREEN}Приоритет IPv4${PLAIN}"
        else
            str_ipv4_first="${RED}По умолчанию (IPv6 приоритет)${PLAIN}"
        fi

        local ping_status
        local str_ping
        ping_status=$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)
        if [[ "$ping_status" == "0" ]]; then str_ping="${GREEN}Разрешён Ping${PLAIN}"; else str_ping="${RED}Запрещён Ping${PLAIN}"; fi

        local update_status
        local str_update
        if [[ "$OS" =~ debian|ubuntu ]]; then
            update_status=$(systemctl is-active unattended-upgrades 2>/dev/null)
        else
            update_status=$(systemctl is-active dnf-automatic.timer 2>/dev/null)
        fi
        if [[ "$update_status" == "active" ]]; then str_update="${GREEN}Включены${PLAIN}"; else str_update="${RED}Отключены${PLAIN}"; fi

        local current_hostname
        current_hostname=$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)
        current_hostname="$(trim_input "$current_hostname")"
        current_hostname="${current_hostname:-неизвестно}"

        echo -e "${GREEN}  1. Переключатель IPv6${PLAIN}               Текущее: [ $str_ipv6 ]"
        echo -e "${GREEN}  2. Приоритет IPv4 при выходе${PLAIN}        Текущее: [ $str_ipv4_first ]"
        echo -e "${GREEN}  3. Переключатель ответа на Ping${PLAIN}     Текущее: [ $str_ping ]"
        echo -e "${GREEN}  4. Управление локальным hosts${PLAIN}      (/etc/hosts локальное разрешение)"
        echo -e "${GREEN}  5. Изменить имя хоста${PLAIN}              Текущее: [ ${CYAN}${current_hostname}${PLAIN} ]"
        echo -e "${GREEN}  6. Переключатель автоматических обновлений${PLAIN} Текущее: [ $str_update ]"
        echo -e "${GREEN}  7. Очистка системного мусора${PLAIN}       (логи/кэш/ненужные пакеты)"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local tweak_choice
        read_trimmed tweak_choice "👉 Выберите действие: "

        case $tweak_choice in
            1)
                read_trimmed yn "❓ Включить IPv6? (y включить / n отключить): "
                if is_yes "$yn"; then
                    quarantine_path /etc/sysctl.d/99-disable-ipv6.conf "/etc/vps-optimize/quarantine/sysctl" >/dev/null 2>&1 || true
                    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
                    echo -e "${GREEN}✅ IPv6 включён${PLAIN}"
                elif is_no "$yn"; then
                    [[ -f /etc/sysctl.d/99-disable-ipv6.conf ]] && cp -p /etc/sysctl.d/99-disable-ipv6.conf "/etc/sysctl.d/99-disable-ipv6.conf.bak_$(date +%s)" 2>/dev/null || true
                    echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-disable-ipv6.conf
                    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1
                    echo -e "${RED}✅ IPv6 отключён${PLAIN}"
                fi; sleep 1 ;;
            2)
                read_trimmed yn "❓ Установить приоритет IPv4 при исходящих соединениях? (y включить / n восстановить по умолчанию): "
                if is_yes "$yn"; then
                    [[ -f /etc/gai.conf ]] || touch /etc/gai.conf
                    cp -p /etc/gai.conf "/etc/gai.conf.bak_$(date +%s)" 2>/dev/null || true
                    sed -Ei '/^[[:space:]]*#?[[:space:]]*precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+100\b.*?$/ {s/.+100\b([[:space:]]*#.*)?$/precedence ::ffff:0:0\/96  100\1/; :a;n;b a}; /^[[:space:]]*precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+[0-9]+.*$/ {s/^.*precedence.+::ffff:0:0\/96[^0-9]+([0-9]+).*$/precedence ::ffff:0:0\/96  100\t#исходное значение \1/; :a;n;ba;}; $aprecedence ::ffff:0:0\/96  100' /etc/gai.conf
                    echo -e "${GREEN}✅ Установлен приоритет IPv4${PLAIN}"
                elif is_no "$yn"; then
                    [[ -f /etc/gai.conf ]] || touch /etc/gai.conf
                    cp -p /etc/gai.conf "/etc/gai.conf.bak_$(date +%s)" 2>/dev/null || true
                    sed -i '/precedence ::ffff:0:0\/96  100/d' /etc/gai.conf
                    echo -e "${BLUE}Восстановлены настройки по умолчанию${PLAIN}"
                fi; sleep 1 ;;
            3)
                read_trimmed yn "❓ Разрешить Ping? (y разрешить / n запретить): "
                if is_yes "$yn"; then
                    quarantine_path /etc/sysctl.d/99-disable-ping.conf "/etc/vps-optimize/quarantine/sysctl" >/dev/null 2>&1 || true
                    sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
                    echo -e "${GREEN}✅ Ping разрешён${PLAIN}"
                elif is_no "$yn"; then
                    [[ -f /etc/sysctl.d/99-disable-ping.conf ]] && cp -p /etc/sysctl.d/99-disable-ping.conf "/etc/sysctl.d/99-disable-ping.conf.bak_$(date +%s)" 2>/dev/null || true
                    echo "net.ipv4.icmp_echo_ignore_all = 1" > /etc/sysctl.d/99-disable-ping.conf
                    sysctl -p /etc/sysctl.d/99-disable-ping.conf >/dev/null 2>&1
                    echo -e "${RED}✅ Защита от Ping включена${PLAIN}"
                fi; sleep 1 ;;
            4) func_hosts_manage ;;
            5) func_change_hostname; sleep 1 ;;
            6)
                read_trimmed yn "❓ Включить автоматические обновления? (y включить / n отключить): "
                if is_yes "$yn"; then
                    if [[ "$OS" =~ debian|ubuntu ]]; then
                        install_pkg unattended-upgrades || { echo -e "${RED}❌ Не удалось установить unattended-upgrades.${PLAIN}"; sleep 1; continue; }
                        systemctl enable --now unattended-upgrades >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ Не удалось включить unattended-upgrades, проверьте вручную.${PLAIN}"
                    else
                        install_pkg dnf-automatic || { echo -e "${RED}❌ Не удалось установить dnf-automatic.${PLAIN}"; sleep 1; continue; }
                        systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ Не удалось включить dnf-automatic.timer, проверьте вручную.${PLAIN}"
                    fi
                    echo -e "${GREEN}✅ Автоматические обновления включены${PLAIN}"
                elif is_no "$yn"; then
                    if [[ "$OS" =~ debian|ubuntu ]]; then systemctl disable --now unattended-upgrades >/dev/null 2>&1
                    else systemctl disable --now dnf-automatic.timer >/dev/null 2>&1; fi
                    echo -e "${GREEN}✅ Автоматические обновления отключены${PLAIN}"
                fi; sleep 1 ;;
            7)
                echo -e "${CYAN}👉 Глубокая очистка системного мусора...${PLAIN}"
                if [[ "$OS" =~ debian|ubuntu ]]; then
                    apt autoremove --purge -y >/dev/null 2>&1
                    apt clean >/dev/null 2>&1
                else
                    yum autoremove -y >/dev/null 2>&1
                    yum clean all >/dev/null 2>&1
                fi
                journalctl --vacuum-time=1d > /dev/null 2>&1
                echo -e "${GREEN}✅ Очистка завершена!${PLAIN}"
                sleep 1 ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# Унифицированное управление пакетами и защита выполнения (новое: разместить над func_env_install)
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: firewall.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Управление правилами брандмауэра.

port_connlimit_comment() {
    local port="$1"
    printf 'VPSO_CONN_LIMIT_PORT_%s' "$port"
}

is_valid_connlimit_value() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value > 0 ))
}

ensure_connlimit_tool() {
    local cmd="$1"
    local family_label="$2"

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}⚠️ ${cmd} не обнаружен, попытка установить iptables-совместимый инструмент...${PLAIN}"
    install_pkg iptables || true

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${RED}❌ ${cmd} не обнаружен, невозможно записать правила connlimit для ${family_label}.${PLAIN}"
    echo -e "${YELLOW}Установите iptables/ip6tables и повторите попытку.${PLAIN}"
    return 1
}

try_load_connlimit_module() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe xt_connlimit >/dev/null 2>&1 || true
    fi
}

port_connlimit_runtime_rule_count() {
    local cmd="$1"
    local count

    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '0'
        return 0
    fi

    count=$("$cmd" -S INPUT 2>/dev/null | grep -Fc 'VPSO_CONN_LIMIT_PORT_' || true)
    printf '%s' "${count:-0}"
}

port_connlimit_persisted_rule_count() {
    local file="$1"
    local count

    if [[ ! -f "$file" ]]; then
        printf '0'
        return 0
    fi

    count=$(grep -Fc 'VPSO_CONN_LIMIT_PORT_' "$file" 2>/dev/null || true)
    printf '%s' "${count:-0}"
}

port_connlimit_command_path() {
    local cmd="$1"
    local candidate

    if command -v "$cmd" >/dev/null 2>&1; then
        command -v "$cmd"
        return 0
    fi

    for candidate in "/usr/sbin/${cmd}" "/sbin/${cmd}" "/usr/bin/${cmd}" "/bin/${cmd}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

port_connlimit_systemd_unit_exists() {
    local unit="$1"

    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl list-unit-files "${unit}.service" --no-legend 2>/dev/null | grep -q . && return 0
    systemctl list-units "${unit}.service" --all --no-legend 2>/dev/null | grep -q . && return 0
    return 1
}

port_connlimit_rhel_ipv4_persistence_available() {
    is_redhat || return 1
    port_connlimit_command_path iptables-save >/dev/null 2>&1 || return 1

    [[ -f /etc/sysconfig/iptables ]] && return 0
    port_connlimit_systemd_unit_exists iptables
}

port_connlimit_rhel_ipv6_persistence_available() {
    is_redhat || return 1
    port_connlimit_command_path ip6tables-save >/dev/null 2>&1 || return 1

    [[ -f /etc/sysconfig/ip6tables ]] && return 0
    port_connlimit_systemd_unit_exists ip6tables
}

port_connlimit_persistence_backend() {
    if port_connlimit_command_path netfilter-persistent >/dev/null 2>&1; then
        printf '%s\n' "netfilter-persistent"
        return 0
    fi

    if port_connlimit_rhel_ipv4_persistence_available; then
        printf '%s\n' "rhel-iptables-services"
        return 0
    fi

    printf '%s\n' "none"
}

port_connlimit_saved_file_for_family() {
    local family="$1"
    local backend="${2:-$(port_connlimit_persistence_backend)}"

    case "$backend:$family" in
        netfilter-persistent:4) printf '%s\n' "/etc/iptables/rules.v4" ;;
        netfilter-persistent:6) printf '%s\n' "/etc/iptables/rules.v6" ;;
        rhel-iptables-services:4) printf '%s\n' "/etc/sysconfig/iptables" ;;
        rhel-iptables-services:6) printf '%s\n' "/etc/sysconfig/ip6tables" ;;
        *) return 1 ;;
    esac
}

port_connlimit_saved_rule_count_for_family() {
    local family="$1"
    local backend="${2:-$(port_connlimit_persistence_backend)}"
    local file

    file=$(port_connlimit_saved_file_for_family "$family" "$backend" 2>/dev/null) || {
        printf '0'
        return 0
    }
    port_connlimit_persisted_rule_count "$file"
}

port_connlimit_runtime_rule_fingerprints_for_family() {
    local family="$1"
    local cmd="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    "$cmd" -S INPUT 2>/dev/null | grep -F 'VPSO_CONN_LIMIT_PORT_' | sed "s/^/${family}:/" || true
}

port_connlimit_saved_rule_fingerprints_for_file() {
    local family="$1"
    local file="$2"

    [[ -f "$file" ]] || return 0
    grep -F 'VPSO_CONN_LIMIT_PORT_' "$file" 2>/dev/null | sed "s/^/${family}:/" || true
}

port_connlimit_runtime_rule_fingerprints() {
    {
        port_connlimit_runtime_rule_fingerprints_for_family "IPv4" iptables
        port_connlimit_runtime_rule_fingerprints_for_family "IPv6" ip6tables
    } | sort -u
}

port_connlimit_saved_rule_fingerprints_for_backend() {
    local backend="$1"
    local v4_file v6_file

    v4_file=$(port_connlimit_saved_file_for_family 4 "$backend" 2>/dev/null || true)
    v6_file=$(port_connlimit_saved_file_for_family 6 "$backend" 2>/dev/null || true)
    {
        [[ -n "$v4_file" ]] && port_connlimit_saved_rule_fingerprints_for_file "IPv4" "$v4_file"
        [[ -n "$v6_file" ]] && port_connlimit_saved_rule_fingerprints_for_file "IPv6" "$v6_file"
    } | sort -u
}

port_connlimit_known_saved_rule_fingerprints() {
    {
        port_connlimit_saved_rule_fingerprints_for_file "IPv4" /etc/iptables/rules.v4
        port_connlimit_saved_rule_fingerprints_for_file "IPv6" /etc/iptables/rules.v6
        port_connlimit_saved_rule_fingerprints_for_file "IPv4" /etc/sysconfig/iptables
        port_connlimit_saved_rule_fingerprints_for_file "IPv6" /etc/sysconfig/ip6tables
    } | sort -u
}

port_connlimit_fingerprint_count() {
    local data="$1"

    if [[ -z "$data" ]]; then
        printf '0'
    else
        printf '%s\n' "$data" | grep -c .
    fi
}

print_port_connlimit_health_summary() {
    local backend runtime_rules saved_rules known_saved_rules
    local runtime_count saved_count known_saved_count backend_label consistency risk

    backend=$(port_connlimit_persistence_backend)
    runtime_rules=$(port_connlimit_runtime_rule_fingerprints)
    saved_rules=$(port_connlimit_saved_rule_fingerprints_for_backend "$backend")
    known_saved_rules=$(port_connlimit_known_saved_rule_fingerprints)
    runtime_count=$(port_connlimit_fingerprint_count "$runtime_rules")
    saved_count=$(port_connlimit_fingerprint_count "$saved_rules")
    known_saved_count=$(port_connlimit_fingerprint_count "$known_saved_rules")

    case "$backend" in
        netfilter-persistent) backend_label="${GREEN}netfilter-persistent${PLAIN}" ;;
        rhel-iptables-services) backend_label="${GREEN}rhel-iptables-services${PLAIN}" ;;
        *) backend_label="${YELLOW}Не обнаружен доступный бэкенд${PLAIN}" ;;
    esac

    if [[ "$backend" == "none" ]]; then
        consistency="${YELLOW}Не обнаружен (нет доступного бэкенда)${PLAIN}"
    elif [[ "$runtime_rules" == "$saved_rules" ]]; then
        consistency="${GREEN}Согласовано${PLAIN}"
    else
        consistency="${YELLOW}Не согласовано${PLAIN}"
    fi

    if [[ "$backend" == "none" && "$runtime_count" -gt 0 ]]; then
        risk="${YELLOW}Есть: правила выполняются, но нет доступного бэкенда; после перезагрузки могут потеряться или восстановиться из старого снимка.${PLAIN}"
    elif [[ "$backend" == "none" && "$known_saved_count" -gt 0 ]]; then
        risk="${YELLOW}Есть: обнаружены сохранённые правила скрипта, но нет доступного бэкенда; поведение после перезагрузки требует проверки.${PLAIN}"
    elif [[ "$backend" != "none" && "$runtime_count" -gt 0 && "$saved_count" -eq 0 ]]; then
        risk="${YELLOW}Есть: правила в памяти, но ещё не сохранены в файл; после перезагрузки могут потеряться.${PLAIN}"
    elif [[ "$backend" != "none" && "$runtime_count" -eq 0 && "$saved_count" -gt 0 ]]; then
        risk="${YELLOW}Есть: в памяти нет правил скрипта, но в сохранённом файле есть старые метки; после перезагрузки могут восстановиться.${PLAIN}"
    elif [[ "$backend" != "none" && "$runtime_rules" != "$saved_rules" ]]; then
        risk="${YELLOW}Есть: правила в памяти и сохранённом файле различаются; рекомендуется повторно сохранить/проверить через [8] -> [5] -> [5].${PLAIN}"
    else
        risk="${GREEN}Риск потери/восстановления не обнаружен${PLAIN}"
    fi

    echo -e "${CYAN}🔒 Сводка по сохранению connlimit${PLAIN}"
    if [[ "$runtime_count" -gt 0 ]]; then
        echo -e "Статус правил скрипта   : [ ${GREEN}Присутствуют${PLAIN} ]   В памяти: ${CYAN}${runtime_count}${PLAIN} правил"
    else
        echo -e "Статус правил скрипта   : [ ${BLUE}Правила в памяти не обнаружены${PLAIN} ]"
    fi
    echo -e "Доступный бэкенд        : [ $backend_label ]"
    echo -e "Память/сохранённый файл  : [ $consistency ]   Сохранённых правил: ${CYAN}${saved_count}${PLAIN}"
    echo -e "Риск при перезагрузке   : [ $risk ]"
}

print_port_connlimit_persistence_unavailable() {
    echo -e "${YELLOW}⚠️ Не обнаружен надёжно вызываемый бэкенд для сохранения connlimit.${PLAIN}"
    if is_debian; then
        echo -e "${YELLOW}На Debian/Ubuntu можно установить и включить iptables-persistent / netfilter-persistent перед сохранением.${PLAIN}"
    elif is_redhat; then
        echo -e "${YELLOW}На RHEL/Rocky/Alma/CentOS Stream автоматическое сохранение работает только при обнаружении iptables-services (iptables.service или /etc/sysconfig/iptables).${PLAIN}"
    else
        echo -e "${YELLOW}Текущий дистрибутив не предоставляет проверяемый путь для сохранения iptables; используйте системные средства для сохранения вручную.${PLAIN}"
    fi
    echo -e "${YELLOW}Текущие правила connlimit действуют только до перезагрузки, после могут потеряться или восстановиться из старого снимка.${PLAIN}"
}

print_port_connlimit_persistence_status() {
    local v4_runtime v6_runtime v4_saved v6_saved backend
    local v4_file deb_v4_saved deb_v6_saved rhel_v4_saved rhel_v6_saved

    backend=$(port_connlimit_persistence_backend)
    v4_runtime=$(port_connlimit_runtime_rule_count iptables)
    v6_runtime=$(port_connlimit_runtime_rule_count ip6tables)
    v4_saved=$(port_connlimit_saved_rule_count_for_family 4 "$backend")
    v6_saved=$(port_connlimit_saved_rule_count_for_family 6 "$backend")
    deb_v4_saved=$(port_connlimit_persisted_rule_count /etc/iptables/rules.v4)
    deb_v6_saved=$(port_connlimit_persisted_rule_count /etc/iptables/rules.v6)
    rhel_v4_saved=$(port_connlimit_persisted_rule_count /etc/sysconfig/iptables)
    rhel_v6_saved=$(port_connlimit_persisted_rule_count /etc/sysconfig/ip6tables)
    v4_file=$(port_connlimit_saved_file_for_family 4 "$backend" 2>/dev/null || true)

    echo -e "${CYAN}Проверка сохранения:${PLAIN}"
    echo "  Правила в памяти: IPv4 ${v4_runtime} шт., IPv6 ${v6_runtime} шт."
    echo "  Файлы на Debian/Ubuntu: /etc/iptables/rules.v4 содержит ${deb_v4_saved} шт., /etc/iptables/rules.v6 содержит ${deb_v6_saved} шт."
    echo "  Файлы на RHEL: /etc/sysconfig/iptables содержит ${rhel_v4_saved} шт., /etc/sysconfig/ip6tables содержит ${rhel_v6_saved} шт."

    if [[ "$backend" == "netfilter-persistent" ]]; then
        echo -e "${GREEN}  Обнаружен netfilter-persistent; при добавлении/удалении connlimit скрипт автоматически попытается сохранить, также можно использовать [5] для проверки/сохранения.${PLAIN}"
    elif command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null | grep -q 'install ok installed'; then
        echo -e "${YELLOW}  Обнаружен пакет iptables-persistent, но команда netfilter-persistent не найдена; проверьте, что /usr/sbin в PATH.${PLAIN}"
    elif [[ "$backend" == "rhel-iptables-services" ]]; then
        echo -e "${GREEN}  Обнаружен существующий путь сохранения iptables-services на RHEL; при добавлении/удалении connlimit будет запись в ${v4_file:-/etc/sysconfig/iptables}.${PLAIN}"
        if ! port_connlimit_rhel_ipv6_persistence_available; then
            echo -e "${YELLOW}  Для IPv6 не обнаружен ip6tables.service или /etc/sysconfig/ip6tables; правила IPv6 connlimit могут действовать только до перезагрузки.${PLAIN}"
        fi
    else
        print_port_connlimit_persistence_unavailable
    fi

    if [[ "$backend" == "netfilter-persistent" ]] && command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files netfilter-persistent.service --no-legend 2>/dev/null | grep -q .; then
        local enabled active
        enabled=$(systemctl is-enabled netfilter-persistent 2>/dev/null || true)
        active=$(systemctl is-active netfilter-persistent 2>/dev/null || true)
        echo "  Служба восстановления при загрузке: netfilter-persistent enabled=${enabled:-unknown}, active=${active:-unknown}."
    fi
    if port_connlimit_systemd_unit_exists iptables; then
        local iptables_enabled iptables_active
        iptables_enabled=$(systemctl is-enabled iptables 2>/dev/null || true)
        iptables_active=$(systemctl is-active iptables 2>/dev/null || true)
        echo "  Служба восстановления при загрузке: iptables enabled=${iptables_enabled:-unknown}, active=${iptables_active:-unknown}."
    fi
    if port_connlimit_systemd_unit_exists ip6tables; then
        local ip6tables_enabled ip6tables_active
        ip6tables_enabled=$(systemctl is-enabled ip6tables 2>/dev/null || true)
        ip6tables_active=$(systemctl is-active ip6tables 2>/dev/null || true)
        echo "  Служба восстановления при загрузке: ip6tables enabled=${ip6tables_enabled:-unknown}, active=${ip6tables_active:-unknown}."
    fi

    if (( v4_runtime > 0 && v4_saved == 0 )) || (( v6_runtime > 0 && v6_saved == 0 )); then
        echo -e "${YELLOW}  Обнаружены правила connlimit в памяти, но они отсутствуют в доступном сохранённом файле; после перезагрузки могут потеряться.${PLAIN}"
    elif (( v4_runtime + v6_runtime == 0 && v4_saved + v6_saved > 0 )); then
        echo -e "${YELLOW}  В памяти нет правил скрипта, но в сохранённом файле есть старые метки; если не обновить снимок, после перезагрузки могут восстановиться.${PLAIN}"
    elif (( v4_runtime + v6_runtime > 0 )); then
        echo -e "${GREEN}  В доступном сохранённом файле обнаружены метки правил скрипта; восстановление при загрузке зависит от соответствующей службы.${PLAIN}"
    else
        echo -e "${BLUE}  В данный момент правил connlimit, добавленных скриптом, не обнаружено.${PLAIN}"
    fi
}

enable_port_connlimit_persistence_service() {
    local backend="${1:-$(port_connlimit_persistence_backend)}"

    if [[ "$backend" == "netfilter-persistent" ]] && command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files netfilter-persistent.service --no-legend 2>/dev/null | grep -q .; then
        if systemctl enable netfilter-persistent >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Включена служба восстановления netfilter-persistent при загрузке.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Не удалось включить netfilter-persistent; файл правил сохранён, но восстановление при загрузке нужно проверить вручную.${PLAIN}"
        fi
    fi
    if [[ "$backend" == "rhel-iptables-services" ]] && port_connlimit_systemd_unit_exists iptables; then
        if systemctl enable iptables >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Включена служба восстановления iptables при загрузке.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Не удалось включить iptables; файл правил IPv4 сохранён, но восстановление при загрузке нужно проверить вручную.${PLAIN}"
        fi
    fi
    if [[ "$backend" == "rhel-iptables-services" ]] && port_connlimit_systemd_unit_exists ip6tables; then
        if systemctl enable ip6tables >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Включена служба восстановления ip6tables при загрузке.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Не удалось включить ip6tables; файл правил IPv6 сохранён, но восстановление при загрузке нужно проверить вручную.${PLAIN}"
        fi
    fi
}

save_rhel_port_connlimit_family() {
    local save_cmd="$1"
    local file="$2"
    local label="$3"
    local tmp_file err_file output

    tmp_file=$(mktemp /tmp/vps-connlimit-rules.XXXXXX) || return 1
    err_file=$(mktemp /tmp/vps-connlimit-save.XXXXXX) || {
        rm -f "$tmp_file"
        return 1
    }
    if "$save_cmd" > "$tmp_file" 2>"$err_file"; then
        output=$(<"$err_file")
        mkdir -p "$(dirname "$file")" || {
            rm -f "$tmp_file"
            rm -f "$err_file"
            echo -e "${RED}❌ Не удалось создать $(dirname "$file"), сохранение ${label} connlimit не удалось.${PLAIN}"
            return 1
        }
        if cp "$tmp_file" "$file"; then
            chmod 600 "$file" 2>/dev/null || true
            rm -f "$tmp_file"
            rm -f "$err_file"
            echo -e "${GREEN}✅ Записано в ${file}, снимок ${label} connlimit сохранён.${PLAIN}"
            return 0
        fi
        rm -f "$tmp_file"
        rm -f "$err_file"
        echo -e "${RED}❌ Ошибка записи в ${file}, правила ${label} connlimit могут действовать только до перезагрузки.${PLAIN}"
        return 1
    fi

    output=$(<"$err_file")
    rm -f "$tmp_file"
    rm -f "$err_file"
    echo -e "${RED}❌ ${save_cmd} не удался, сохранение ${label} connlimit не удалось: ${output}${PLAIN}"
    return 1
}

save_rhel_port_connlimit_persistence() {
    local rc=0
    local iptables_save ip6tables_save
    local v6_runtime v6_saved

    iptables_save=$(port_connlimit_command_path iptables-save 2>/dev/null || true)
    if [[ -z "$iptables_save" ]]; then
        echo -e "${RED}❌ iptables-save не обнаружен, невозможно записать файл сохранения IPv4 connlimit на RHEL.${PLAIN}"
        rc=1
    else
        save_rhel_port_connlimit_family "$iptables_save" "/etc/sysconfig/iptables" "IPv4" || rc=1
    fi

    v6_runtime=$(port_connlimit_runtime_rule_count ip6tables)
    v6_saved=$(port_connlimit_persisted_rule_count /etc/sysconfig/ip6tables)
    if port_connlimit_rhel_ipv6_persistence_available; then
        ip6tables_save=$(port_connlimit_command_path ip6tables-save 2>/dev/null || true)
        save_rhel_port_connlimit_family "$ip6tables_save" "/etc/sysconfig/ip6tables" "IPv6" || rc=1
    elif (( v6_runtime > 0 || v6_saved > 0 )); then
        echo -e "${YELLOW}⚠️ Не обнаружен путь сохранения IPv6 на RHEL; текущие правила connlimit IPv6 или старый снимок не могут быть надёжно сохранены скриптом.${PLAIN}"
        rc=1
    fi

    enable_port_connlimit_persistence_service "rhel-iptables-services"
    print_port_connlimit_persistence_status
    return "$rc"
}

save_port_connlimit_persistence() {
    local output backend
    local v4_runtime v6_runtime v4_saved v6_saved

    backend=$(port_connlimit_persistence_backend)
    if [[ "$backend" == "none" ]]; then
        print_port_connlimit_persistence_unavailable
        return 1
    fi

    if [[ "$backend" == "rhel-iptables-services" ]]; then
        save_rhel_port_connlimit_persistence
        return $?
    fi

    local netfilter_cmd
    netfilter_cmd=$(port_connlimit_command_path netfilter-persistent)
    if output=$("$netfilter_cmd" save 2>&1); then
        echo -e "${GREEN}✅ Выполнено netfilter-persistent save, текущий снимок iptables/ip6tables записан в файлы.${PLAIN}"
    else
        echo -e "${RED}❌ netfilter-persistent save не удался: ${output}${PLAIN}"
        echo -e "${YELLOW}В этот раз сохранение не выполнено; текущие правила connlimit могут действовать только до перезагрузки.${PLAIN}"
        return 1
    fi

    enable_port_connlimit_persistence_service "$backend"
    print_port_connlimit_persistence_status

    v4_runtime=$(port_connlimit_runtime_rule_count iptables)
    v6_runtime=$(port_connlimit_runtime_rule_count ip6tables)
    v4_saved=$(port_connlimit_saved_rule_count_for_family 4 "$backend")
    v6_saved=$(port_connlimit_saved_rule_count_for_family 6 "$backend")

    if (( v4_runtime > 0 && v4_saved == 0 )) || (( v6_runtime > 0 && v6_saved == 0 )); then
        echo -e "${RED}❌ После сохранения метки правил скрипта не обнаружены в сохранённом файле; не рассчитывайте на восстановление после перезагрузки.${PLAIN}"
        return 1
    fi

    return 0
}

auto_save_port_connlimit_persistence_after_change() {
    local action_label="$1"

    echo ""
    echo -e "${CYAN}Попытка автоматического сохранения снимка connlimit (после ${action_label})...${PLAIN}"
    if save_port_connlimit_persistence; then
        echo -e "${GREEN}✅ Снимок connlimit обновлён.${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ Правила connlimit применены, но сохранение не подтверждено; после перезагрузки они могут не сохраниться.${PLAIN}"
        echo -e "${YELLOW}Восстановите возможности сохранения или сохраните вручную в соответствии с вашим дистрибутивом.${PLAIN}"
        return 1
    fi
}

func_save_port_connlimit_persistence() {
    print_port_connlimit_persistence_status
    echo ""
    confirm_risk_action "Сохранение снимка ограничений параллельных соединений" \
        "Сохраняет текущий снимок iptables/ip6tables с использованием обнаруженного бэкенда; на Debian/Ubuntu предпочтение netfilter-persistent, на RHEL — существующий iptables-services" \
        "При добавлении/удалении правил connlimit скрипт автоматически сохраняет; этот пункт для ручной проверки или повторной попытки" \
        "Операция не удаляет правила, не меняет настройки UFW/firewalld; обновляется только снимок дополнительных правил connlimit." || {
        echo -e "${BLUE}Сохранение снимка отменено.${PLAIN}"
        return 0
    }

    save_port_connlimit_persistence
}

port_connlimit_loopback_only_listener() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1

    ss -Htlpn 2>/dev/null | awk -v port="$port" '
        function is_target(addr) {
            return addr ~ (":" port "$") || addr ~ ("\\]:" port "$")
        }
        is_target($4) {
            if ($4 ~ /^(127\.0\.0\.1|localhost):/ || $4 ~ /^\[::1\]:/) {
                loopback = 1
            } else {
                public = 1
            }
        }
        END {
            exit (loopback && !public ? 0 : 1)
        }
    '
}

print_port_connlimit_scope_notice() {
    local port="$1"

    echo -e "${YELLOW}Пояснение: эта функция добавляет дополнительные правила iptables/ip6tables connlimit, которые не являются правилами разрешения портов UFW/firewalld.${PLAIN}"
    echo -e "${YELLOW}По умолчанию ограничивается количество одновременных TCP-соединений с каждого исходного IP-адреса, а не общее количество соединений.${PLAIN}"
    echo -e "${YELLOW}При добавлении/удалении автоматически обновляется снимок; если система не поддерживает сохранение, будет выдано предупреждение.${PLAIN}"

    if [[ "$port" == "443" ]]; then
        echo -e "${RED}⚠️ Предупреждение для 443: если включён единый вход 443/мультиплексирование порта, это ограничение действует на весь публичный порт 443.${PLAIN}"
        echo -e "${RED}Оно не может быть применено к конкретному входящему Xray/3x-ui, SNI, UUID или пользователю.${PLAIN}"
    fi

    if port_connlimit_loopback_only_listener "$port"; then
        echo -e "${YELLOW}⚠️ Обнаружено, что порт, возможно, слушает только 127.0.0.1/::1. Эта функция предназначена для ограничения публичных портов.${PLAIN}"
        echo -e "${YELLOW}Если ограничить локальный бэкенд-порт, это может ограничить только соединения от прокси к бэкенду, но не реальные источники из интернета.${PLAIN}"
    fi
}

port_connlimit_has_rule_for_port() {
    local cmd="$1"
    local port="$2"
    local comment
    comment=$(port_connlimit_comment "$port")

    "$cmd" -S INPUT 2>/dev/null | grep -Fq "$comment"
}

run_port_connlimit_rule_action() {
    local cmd="$1"
    local action="$2"
    local port="$3"
    local limit="$4"
    local mask="$5"
    local family_label="$6"
    local comment output
    comment=$(port_connlimit_comment "$port")

    local args=(
        -p tcp --dport "$port" --syn
        -m connlimit --connlimit-above "$limit" --connlimit-mask "$mask" --connlimit-saddr
        -m comment --comment "$comment"
        -j REJECT --reject-with tcp-reset
    )

    case "$action" in
        add)
            if "$cmd" -C INPUT "${args[@]}" >/dev/null 2>&1; then
                echo -e "${BLUE}ℹ️ ${family_label} уже существует правило: порт ${port}, более ${limit} новых соединений с одного IP будут отклонены.${PLAIN}"
                return 0
            fi
            if port_connlimit_has_rule_for_port "$cmd" "$port"; then
                echo -e "${YELLOW}⚠️ ${family_label} уже существует правило для этого порта с меткой скрипта. Добавление приведёт к наложению; для замены сначала удалите старое правило.${PLAIN}"
            fi
            if output=$("$cmd" -I INPUT "${args[@]}" 2>&1); then
                echo -e "${GREEN}✅ ${family_label} добавлено: порт ${port}, максимум ${limit} одновременных соединений с одного IP.${PLAIN}"
                return 0
            fi
            echo -e "${RED}❌ ${family_label} ошибка добавления: ${output}${PLAIN}"
            return 1
            ;;
        delete)
            if ! "$cmd" -C INPUT "${args[@]}" >/dev/null 2>&1; then
                echo -e "${YELLOW}⚠️ ${family_label} правило не найдено: порт ${port}, соединений ${limit}.${PLAIN}"
                return 1
            fi
            if output=$("$cmd" -D INPUT "${args[@]}" 2>&1); then
                echo -e "${GREEN}✅ ${family_label} удалено: порт ${port}, соединений ${limit}.${PLAIN}"
                return 0
            fi
            echo -e "${RED}❌ ${family_label} ошибка удаления: ${output}${PLAIN}"
            return 1
            ;;
        *)
            echo -e "${RED}❌ Неизвестная операция connlimit: ${action}${PLAIN}"
            return 1
            ;;
    esac
}

read_connlimit_port() {
    local __target="$1"
    local port

    read_trimmed port "Введите номер порта (1-65535, Enter или 0 для отмены): "
    if [[ -z "$port" || "$port" == "0" ]]; then
        echo -e "${BLUE}Операция ограничения порта отменена.${PLAIN}"
        return 1
    fi
    if ! is_valid_port "$port"; then
        echo -e "${RED}❌ Неверный порт, должен быть 1-65535.${PLAIN}"
        return 1
    fi

    printf -v "$__target" '%s' "$((10#$port))"
}

read_connlimit_limit() {
    local __target="$1"
    local limit

    read_trimmed limit "Введите максимальное количество одновременных TCP-соединений с одного IP (положительное целое, Enter или 0 для отмены): "
    if [[ -z "$limit" || "$limit" == "0" ]]; then
        echo -e "${BLUE}Операция ограничения порта отменена.${PLAIN}"
        return 1
    fi
    if ! is_valid_connlimit_value "$limit"; then
        echo -e "${RED}❌ Неверное значение, должно быть положительным целым.${PLAIN}"
        return 1
    fi

    printf -v "$__target" '%s' "$((10#$limit))"
}

func_add_port_connlimit_rule() {
    local port limit apply_ipv6 rc=0 touched=0

    read_connlimit_port port || return 0
    read_connlimit_limit limit || return 0
    read_trimmed apply_ipv6 "Применить также для IPv6? (y/n, по умолчанию n): "

    print_port_connlimit_scope_notice "$port"
    echo -e "${CYAN}Будет добавлено правило с меткой: $(port_connlimit_comment "$port")${PLAIN}"

    ensure_connlimit_tool iptables "IPv4" || return 1
    if is_yes "$apply_ipv6"; then
        ensure_connlimit_tool ip6tables "IPv6" || return 1
    fi
    try_load_connlimit_module

    confirm_risk_action "Добавить ограничение параллельных соединений для порта ${port}" \
        "Правило connlimit в цепочке INPUT iptables/ip6tables, новые TCP-соединения свыше ${limit} будут отклоняться" \
        "Удалите правило через этот же пункт меню по порту и лимиту; при необходимости очистите iptables через VNC/консоль" \
        "Это дополнительное ограничение, не является правилом разрешения UFW/firewalld." || {
        echo -e "${BLUE}Добавление ограничения отменено.${PLAIN}"
        return 0
    }

    if run_port_connlimit_rule_action iptables add "$port" "$limit" 32 "IPv4"; then
        touched=1
    else
        rc=1
    fi
    if is_yes "$apply_ipv6"; then
        if run_port_connlimit_rule_action ip6tables add "$port" "$limit" 128 "IPv6"; then
            touched=1
        else
            rc=1
        fi
    fi
    if [[ "$touched" -eq 1 ]]; then
        auto_save_port_connlimit_persistence_after_change "добавление правила" || true
    else
        echo -e "${YELLOW}Добавление не завершено полностью, автоматическое сохранение не выполнено; сначала исправьте ошибки выше.${PLAIN}"
    fi
    return "$rc"
}

func_delete_port_connlimit_rule() {
    local port limit delete_ipv6 rc=0

    read_connlimit_port port || return 0
    read_connlimit_limit limit || return 0
    read_trimmed delete_ipv6 "Удалить также соответствующее правило IPv6? (Y/n, по умолчанию yes): "

    print_port_connlimit_scope_notice "$port"
    echo -e "${CYAN}Будет удалено правило с меткой: $(port_connlimit_comment "$port")${PLAIN}"

    ensure_connlimit_tool iptables "IPv4" || return 1
    if ! is_no "$delete_ipv6"; then
        ensure_connlimit_tool ip6tables "IPv6" || return 1
    fi

    confirm_risk_action "Удалить ограничение параллельных соединений для порта ${port}" \
        "Удаляет только правило connlimit для порта ${port}, лимита ${limit}, с меткой $(port_connlimit_comment "$port")" \
        "Если удалено по ошибке, можно добавить заново через этот же пункт меню" \
        "Это не удаляет правила UFW/firewalld и не очищает iptables массово." || {
        echo -e "${BLUE}Удаление ограничения отменено.${PLAIN}"
        return 0
    }

    run_port_connlimit_rule_action iptables delete "$port" "$limit" 32 "IPv4" || rc=1
    if ! is_no "$delete_ipv6"; then
        run_port_connlimit_rule_action ip6tables delete "$port" "$limit" 128 "IPv6" || rc=1
    fi
    auto_save_port_connlimit_persistence_after_change "удаление правила" || true
    return "$rc"
}

func_show_port_connlimit_rules() {
    local found=0

    echo -e "${CYAN}Текущие правила ограничения параллельных соединений, добавленные VPS-Optimize:${PLAIN}"
    echo -e "${YELLOW}Метка: VPSO_CONN_LIMIT_PORT_<порт>${PLAIN}"
    echo ""

    if command -v iptables >/dev/null 2>&1; then
        echo -e "${BOLD}IPv4:${PLAIN}"
        if iptables -S INPUT 2>/dev/null | grep -F 'VPSO_CONN_LIMIT_PORT_'; then
            found=1
        else
            echo "  Правил IPv4 не обнаружено."
        fi
    else
        echo -e "${YELLOW}IPv4: iptables не обнаружен.${PLAIN}"
    fi

    echo ""
    if command -v ip6tables >/dev/null 2>&1; then
        echo -e "${BOLD}IPv6:${PLAIN}"
        if ip6tables -S INPUT 2>/dev/null | grep -F 'VPSO_CONN_LIMIT_PORT_'; then
            found=1
        else
            echo "  Правил IPv6 не обнаружено."
        fi
    else
        echo -e "${YELLOW}IPv6: ip6tables не обнаружен.${PLAIN}"
    fi

    echo ""
    if [[ "$found" -eq 0 ]]; then
        echo -e "${BLUE}В данный момент правил connlimit от скрипта не обнаружено.${PLAIN}"
    fi
    echo -e "${YELLOW}Эти правила ограничивают количество соединений, они не являются правилами разрешения портов UFW/firewalld.${PLAIN}"
    echo ""
    print_port_connlimit_persistence_status
}

func_show_port_current_connections() {
    local port rows

    read_connlimit_port port || return 0

    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ss не обнаружен, попытка установить iproute2/iproute...${PLAIN}"
        install_pkg iproute2 || install_pkg iproute || true
    fi
    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${RED}❌ ss не обнаружен, невозможно просмотреть текущие соединения.${PLAIN}"
        return 1
    fi

    print_port_connlimit_scope_notice "$port"
    echo -e "${CYAN}Порт ${port}: статистика установленных TCP-соединений по исходным IP:${PLAIN}"
    rows=$(ss -Htan state established 2>/dev/null | awk -v port="$port" '
        function is_local_port(endpoint) {
            return endpoint ~ (":" port "$") || endpoint ~ ("\\]:" port "$")
        }
        function remote_ip(endpoint) {
            if (endpoint ~ /^\[/) {
                sub(/^\[/, "", endpoint)
                sub(/\]:[0-9]+$/, "", endpoint)
                return endpoint
            }
            sub(/:[0-9]+$/, "", endpoint)
            return endpoint
        }
        is_local_port($4) {
            print remote_ip($5)
        }
    ' | sort | uniq -c | sort -nr)

    if [[ -z "$rows" ]]; then
        echo "  В данный момент установленных соединений нет."
    else
        printf '%s\n' "$rows" | awk '{count=$1; $1=""; sub(/^ /, ""); printf "  %-45s %s\n", $0, count}'
    fi
}

show_firewall_menu_help() {
    echo "Меню брандмауэра предназначено для разрешения, удаления, просмотра или отключения системного брандмауэра. Для удаления и отключения требуется ввод yes для подтверждения."
    echo "Автоматическое разрешение создаёт минимальный план, показывая протокол, адрес прослушивания, процесс и Docker-маппинг; петлевые адреса не разрешаются, текущий SSH-порт не может быть исключён."
    echo "План основан только на текущем публичном прослушивании и опубликованных портах Docker; необходимо проверить, нужны ли они для бизнеса; можно исключить необязательные правила по номеру."
    echo "Маппинг Docker может обходить обычные правила UFW/firewalld; исключение из плана не закрывает маппинг контейнеров, требуется также изменить адрес публикации Docker или использовать безопасность Docker."
    echo "Ручное добавление по умолчанию разрешает TCP; можно указать udp или both. Удаление проверяет TCP и UDP."
    echo "Ограничение параллельных соединений используется для ограничения TCP-коннектов с одного IP на публичном порте; IPv4 использует iptables connlimit, IPv6 — ip6tables connlimit."
    echo "Это дополнительное ограничение, не является правилом разрешения портов UFW/firewalld; они могут сосуществовать."
    echo "При добавлении/удалении connlimit автоматически обновляется снимок; пункт [5] позволяет проверить или сохранить вручную. При отсутствии поддержки будет предупреждение."
    echo "Если ограничивается публичный 443 и включён единый вход 443/мультиплексирование, ограничение применяется ко всему публичному 443 и не может быть точным для конкретного входящего, SNI, UUID или пользователя."
}

func_port_connlimit_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Управление брандмауэром > Ограничение параллельных соединений"
        echo -e "${BOLD}Ограничение параллельных соединений на порт${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: ограничить количество одновременных TCP-соединений с одного IP на публичном порте.${PLAIN}"
        echo -e "${YELLOW}Пояснение: это дополнительные правила connlimit, не являющиеся правилами разрешения UFW/firewalld.${PLAIN}"
        echo -e "${YELLOW}Сохранение: при добавлении/удалении автоматически обновляется; [5] для ручной проверки/повторной попытки.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Добавить ограничение параллельных соединений для порта${PLAIN}"
        echo -e "${GREEN}  2. Удалить ограничение параллельных соединений для порта${PLAIN}"
        echo -e "${GREEN}  3. Просмотреть текущие правила ограничения${PLAIN}"
        echo -e "${GREEN}  4. Просмотреть текущие соединения для порта${PLAIN}"
        echo -e "${GREEN}  5. Сохранить/проверить сохранение при перезагрузке${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  0. Вернуться на уровень выше${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local connlimit_choice
        read_trimmed connlimit_choice "👉 Выберите действие: "
        case "$connlimit_choice" in
            1) func_add_port_connlimit_rule; pause_return ;;
            2) func_delete_port_connlimit_rule; pause_return ;;
            3) func_show_port_connlimit_rules; pause_return ;;
            4) func_show_port_current_connections; pause_return ;;
            5) func_save_port_connlimit_persistence; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

firewall_detect_public_listener_rules() {
    firewall_collect_public_listener_details | awk -F'|' '
        NF >= 2 {
            print $1 "/" $2
        }
    ' | sort -t/ -k1,1n -k2,2 -u
}

firewall_collect_public_listener_details() {
    ss -H -lntup 2>/dev/null | awk '
        $1 ~ /^(tcp|udp)/ {
            proto = ($1 ~ /^tcp/) ? "tcp" : "udp"
            endpoint = $5
            port = endpoint
            sub(/^.*:/, "", port)
            address = endpoint
            sub(/:[0-9]+$/, "", address)
            normalized = tolower(address)
            gsub(/^\[|\]$/, "", normalized)
            sub(/%.*/, "", normalized)
            if (normalized == "localhost" ||
                normalized ~ /^127\./ ||
                normalized == "::1" ||
                normalized ~ /^::ffff:127\./) {
                next
            }
            process = "-"
            details = ""
            for (i = 7; i <= NF; i++) {
                details = details (details ? " " : "") $i
            }
            if (match(details, /users:\(\("[^"]+"/)) {
                process = substr(details, RSTART, RLENGTH)
                sub(/^users:\(\("/, "", process)
                sub(/".*$/, "", process)
            }
            if (port ~ /^[0-9]+$/ && port >= 1 && port <= 65535) {
                print port "|" proto "|" address "|" process "|Системный слушатель|"
            }
        }
    '
}

firewall_is_loopback_address() {
    local address
    address=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    address="${address#[}"
    address="${address%]}"
    address="${address%%%*}"
    [[ "$address" == "localhost" || "$address" == 127.* || "$address" == "::1" || "$address" == ::ffff:127.* ]]
}

firewall_collect_docker_listener_details() {
    command -v docker >/dev/null 2>&1 || return 0

    local container line container_port protocol binding host_address host_port
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        while IFS= read -r line; do
            if [[ "$line" =~ ^([0-9]+)/(tcp|udp)[[:space:]]+-\>[[:space:]]+(.+):([0-9]+)$ ]]; then
                container_port="${BASH_REMATCH[1]}"
                protocol="${BASH_REMATCH[2]}"
                host_address="${BASH_REMATCH[3]}"
                host_port="${BASH_REMATCH[4]}"
                if ! firewall_is_loopback_address "$host_address" && is_valid_port "$host_port"; then
                    binding="${host_port} -> ${container_port}/${protocol}"
                    printf '%s|%s|%s|docker:%s|Docker|%s\n' \
                        "$host_port" "$protocol" "$host_address" "$container" "$binding"
                fi
            fi
        done < <(docker port "$container" 2>/dev/null || true)
    done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
}

firewall_add_unique_plan_value() {
    local current="$1"
    local value="$2"
    local item
    local -a current_items=()
    [[ -n "$value" && "$value" != "-" ]] || {
        printf '%s\n' "$current"
        return 0
    }
    IFS=';' read -ra current_items <<< "$current"
    for item in "${current_items[@]}"; do
        if [[ "$item" == "$value" ]]; then
            printf '%s\n' "$current"
            return 0
        fi
    done
    if [[ -n "$current" ]]; then
        printf '%s;%s\n' "$current" "$value"
    else
        printf '%s\n' "$value"
    fi
}

firewall_detect_ssh_port() {
    local ssh_port=""
    local -a ssh_connection_parts=()
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -ra ssh_connection_parts <<< "$SSH_CONNECTION"
        ssh_port="${ssh_connection_parts[3]:-}"
        is_valid_port "$ssh_port" || ssh_port=""
    fi
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(ss -H -tlnp 2>/dev/null | awk '
            /users:\(\("sshd"/ {
                port = $5
                sub(/^.*:/, "", port)
                if (port ~ /^[0-9]+$/) {
                    print port
                    exit
                }
            }
        ' || true)
    fi
    [[ -n "$ssh_port" ]] || ssh_port=$(awk 'tolower($1) == "port" { print $2; exit }' /etc/ssh/sshd_config 2>/dev/null || true)
    ssh_port="${ssh_port:-22}"
    is_valid_port "$ssh_port" || ssh_port=22
    printf '%s\n' "$ssh_port"
}

firewall_build_minimum_plan() {
    local ssh_port="${1:-}"
    local port protocol address process source mapping key
    local -A addresses=()
    local -A processes=()
    local -A sources=()
    local -A mappings=()
    local -A protected=()
    local -A seen=()
    local -a keys=()

    while IFS='|' read -r port protocol address process source mapping; do
        [[ -n "$port" && -n "$protocol" ]] || continue
        key="${port}/${protocol}"
        if [[ -z "${seen[$key]:-}" ]]; then
            keys+=("$key")
            seen["$key"]=1
            protected["$key"]="no"
        fi
        addresses["$key"]=$(firewall_add_unique_plan_value "${addresses[$key]:-}" "$address")
        processes["$key"]=$(firewall_add_unique_plan_value "${processes[$key]:-}" "$process")
        sources["$key"]=$(firewall_add_unique_plan_value "${sources[$key]:-}" "$source")
        mappings["$key"]=$(firewall_add_unique_plan_value "${mappings[$key]:-}" "$mapping")
    done < <(
        firewall_collect_public_listener_details
        firewall_collect_docker_listener_details
    )

    [[ -n "$ssh_port" ]] || ssh_port=$(firewall_detect_ssh_port 2>/dev/null || true)
    if is_valid_port "$ssh_port"; then
        key="${ssh_port}/tcp"
        if [[ -z "${seen[$key]:-}" ]]; then
            keys+=("$key")
            seen["$key"]=1
            addresses["$key"]="Защищено SSH конфигурацией"
        fi
        processes["$key"]=$(firewall_add_unique_plan_value "${processes[$key]:-}" "sshd")
        sources["$key"]=$(firewall_add_unique_plan_value "${sources[$key]:-}" "Защита SSH")
        protected["$key"]="yes"
    fi

    for key in "${keys[@]}"; do
        port="${key%/*}"
        protocol="${key#*/}"
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$port" "$protocol" "${addresses[$key]:--}" "${processes[$key]:--}" \
            "${sources[$key]:--}" "${mappings[$key]:--}" "${protected[$key]:-no}"
    done | sort -t'|' -k1,1n -k2,2
}

firewall_print_minimum_plan() {
    local plan="$1"
    local index=0 port protocol address process source mapping protected
    echo -e "${CYAN}👇 Минимальный план брандмауэра:${PLAIN}"
    while IFS='|' read -r port protocol address process source mapping protected; do
        [[ -n "$port" ]] || continue
        index=$((index + 1))
        printf '  [%d] %s/%s\n' "$index" "$port" "$protocol"
        printf '      Адрес прослушивания: %s\n' "${address:--}"
        printf '      Процесс: %s\n' "${process:--}"
        printf '      Источник: %s\n' "${source:--}"
        printf '      Docker маппинг: %s\n' "${mapping:--}"
        if [[ "$protected" == "yes" ]]; then
            echo "      Защищено: текущий SSH-порт, не может быть исключён"
        fi
    done <<< "$plan"
}

firewall_select_minimum_plan_rules() {
    local plan="$1"
    local exclusions="${2:-}"
    local count index item item_number port protocol address process source mapping protected
    local -A excluded=()
    local -a exclusion_items=()

    exclusions="${exclusions//[[:space:]]/}"
    count=$(grep -c '^[0-9]' <<< "$plan" || true)
    if [[ -n "$exclusions" ]]; then
        [[ "$exclusions" =~ ^[0-9]+(,[0-9]+)*$ ]] || {
            echo "Неверный формат номеров для исключения, используйте запятые, например 2,4." >&2
            return 1
        }
        IFS=',' read -ra exclusion_items <<< "$exclusions"
        for item in "${exclusion_items[@]}"; do
            item_number=$((10#$item))
            if (( item_number < 1 || item_number > count )); then
                echo "Номер ${item} вне диапазона плана." >&2
                return 1
            fi
            excluded["$item_number"]=1
        done
    fi

    index=0
    while IFS='|' read -r port protocol address process source mapping protected; do
        [[ -n "$port" ]] || continue
        index=$((index + 1))
        if [[ -n "${excluded[$index]:-}" && "$protected" == "yes" ]]; then
            echo "Номер ${index} — текущий SSH-порт, оставлен принудительно." >&2
        elif [[ -n "${excluded[$index]:-}" ]]; then
            continue
        fi
        printf '%s/%s\n' "$port" "$protocol"
    done <<< "$plan"
}

normalize_firewall_protocol() {
    local protocol
    protocol=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$protocol" in
        tcp|udp|both) printf '%s\n' "$protocol" ;;
        *) return 1 ;;
    esac
}

firewall_apply_port_rule() {
    local action="$1"
    local port_rule="$2"
    local protocol="$3"
    local output command_rc

    if [[ "$OS" =~ debian|ubuntu ]]; then
        port_rule="${port_rule//-/:}"
        if [[ "$action" == "add" ]]; then
            output=$(ufw allow "${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        else
            output=$(ufw delete allow "${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        fi
    else
        port_rule="${port_rule//:/-}"
        if [[ "${VPSO_FIREWALLD_OFFLINE_MODE:-0}" == "1" && "$action" == "add" ]]; then
            output=$(firewall-offline-cmd --add-port="${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        elif [[ "$action" == "add" ]]; then
            output=$(firewall-cmd --permanent --add-port="${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        else
            output=$(firewall-cmd --permanent --remove-port="${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        fi
    fi
    if [[ "$command_rc" -ne 0 ]]; then
        echo -e "${RED}❌ ${action} ${port_rule}/${protocol} не удалось: ${output:-неизвестная ошибка}${PLAIN}"
        return 1
    fi
}

firewall_apply_port_input() {
    local action="$1"
    local port_input="$2"
    local protocol="$3"
    local rc=0 port_rule current_protocol
    local protocols=()
    local port_rules=()

    if [[ "$protocol" == "both" ]]; then
        protocols=(tcp udp)
    else
        protocols=("$protocol")
    fi
    IFS=',' read -ra port_rules <<< "$port_input"
    for port_rule in "${port_rules[@]}"; do
        if [[ "$action" == "delete" && "$protocol" == "both" && "$OS" =~ debian|ubuntu ]]; then
            local legacy_port_rule="${port_rule//-/:}"
            if ufw delete allow "$legacy_port_rule" >/dev/null 2>&1; then
                continue
            fi
        fi
        for current_protocol in "${protocols[@]}"; do
            firewall_apply_port_rule "$action" "$port_rule" "$current_protocol" || rc=1
        done
    done
    return "$rc"
}

func_firewall_manage() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Управление брандмауэром"
        echo -e "${BOLD}🛡️ Управление правилами брандмауэра${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local fw_status
        local str_fw
        if [[ "$OS" =~ debian|ubuntu ]]; then
            fw_status=$(ufw status 2>/dev/null | grep -wi active)
        else
            fw_status=$(systemctl is-active firewalld 2>/dev/null)
        fi

        if [[ "$fw_status" == *"active"* ]]; then
            str_fw="${GREEN}Активен${PLAIN}"
        else
            str_fw="${RED}Отключён / не настроен${PLAIN}"
        fi

        echo -e "Текущий статус брандмауэра: [ $str_fw ]"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Просмотр списка разрешённых правил${PLAIN}"
        echo -e "${GREEN}  2. Включить брандмауэр и применить минимальный план${PLAIN} ${YELLOW}(можно просмотреть/исключить, не перезаписывает существующие правила)${PLAIN}"
        echo -e "${GREEN}  3. Разрешить порт вручную${PLAIN} ${YELLOW}(TCP/UDP, пакетно/диапазон)${PLAIN}"
        echo -e "${GREEN}  4. Удалить разрешённый порт${PLAIN} ${YELLOW}(TCP/UDP, пакетно/диапазон)${PLAIN}"
        echo -e "${GREEN}  5. Ограничение параллельных соединений на порт${PLAIN} ${YELLOW}(по IP)${PLAIN}"
        echo -e "${RED}  6. Отключить брандмауэр${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${BLUE}  0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local fw_choice
        read_trimmed fw_choice "👉 Выберите действие: "

        case $fw_choice in
            1)
                echo -e "${CYAN}👇 Список текущих правил брандмауэра:${PLAIN}"
                if [[ "$OS" =~ debian|ubuntu ]]; then
                    ufw status numbered
                else
                    firewall-cmd --list-ports
                fi
                read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                ;;
            2)
                echo -e "${CYAN}👉 Проверка публичных слушателей, процессов и опубликованных портов Docker...${PLAIN}"
                local firewall_plan active_rules exclusions selection_cancelled
                firewall_plan=$(firewall_build_minimum_plan)

                if [[ -z "$firewall_plan" ]]; then
                    echo -e "${RED}❌ Не удалось определить порты для разрешения, включение отменено во избежание блокировки SSH.${PLAIN}"
                    echo -e "${YELLOW}Убедитесь, что ss/iproute2 доступны, или используйте [3] для ручного добавления SSH-порта.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi
                firewall_print_minimum_plan "$firewall_plan"
                echo -e "${YELLOW}План основан на текущем публичном прослушивании и Docker-маппинге; вы должны проверить, нужны ли они для бизнеса.${PLAIN}"
                if grep -Fq '|Docker|' <<< "$firewall_plan"; then
                    echo -e "${RED}⚠️ Маппинг Docker может обходить обычные правила UFW/firewalld; исключение из плана не закрывает маппинг контейнеров.${PLAIN}"
                    echo -e "${YELLOW}Для ограничения также измените адрес публикации Docker или используйте [11 Docker безопасность].${PLAIN}"
                fi

                selection_cancelled=0
                while true; do
                    read_trimmed exclusions "👉 Введите номера для исключения (через запятую, Enter для сохранения всех, q отмена): "
                    if [[ "$exclusions" =~ ^[qQ]$ ]]; then
                        selection_cancelled=1
                        break
                    fi
                    if active_rules=$(firewall_select_minimum_plan_rules "$firewall_plan" "$exclusions"); then
                        break
                    fi
                done
                if [[ "$selection_cancelled" -eq 1 ]]; then
                    echo -e "${BLUE}Включение брандмауэра отменено.${PLAIN}"
                    sleep 1
                    continue
                fi
                echo -e "${CYAN}Будут разрешены: $(echo "$active_rules" | tr '\n' ' ')${PLAIN}"
                confirm_risk_action "Включить брандмауэр и применить минимальный план разрешений" \
                    "Политика по умолчанию для входящих соединений и выбранные правила TCP/UDP" \
                    "Сохраните текущую SSH-сессию, используйте консоль провайдера/VNC для отключения брандмауэра или восстановления бизнес-портов" \
                    "Убедитесь, что план покрывает текущий SSH и все необходимые публичные службы." || {
                    echo -e "${BLUE}Включение брандмауэра отменено.${PLAIN}"
                    sleep 1
                    continue
                }

                local firewall_rc=0 rule_entry rule_port rule_protocol
                local firewalld_was_inactive=0
                if [[ "$OS" =~ debian|ubuntu ]]; then
                    if ! install_pkg ufw || ! command -v ufw >/dev/null 2>&1; then
                        echo -e "${RED}❌ Не удалось установить UFW, брандмауэр не включён.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    ufw default deny incoming >/dev/null 2>&1 || firewall_rc=1
                    ufw default allow outgoing >/dev/null 2>&1 || firewall_rc=1
                else
                    if ! install_pkg firewalld || ! command -v firewall-cmd >/dev/null 2>&1; then
                        echo -e "${RED}❌ Не удалось установить firewalld, брандмауэр не включён.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    if ! systemctl is-active --quiet firewalld; then
                        if ! command -v firewall-offline-cmd >/dev/null 2>&1; then
                            echo -e "${RED}❌ Отсутствует firewall-offline-cmd, невозможно безопасно добавить SSH-порт до запуска firewalld.${PLAIN}"
                            sleep 2
                            continue
                        fi
                        firewalld_was_inactive=1
                        VPSO_FIREWALLD_OFFLINE_MODE=1
                    fi
                fi
                while IFS= read -r rule_entry; do
                    [[ -n "$rule_entry" ]] || continue
                    rule_port="${rule_entry%/*}"
                    rule_protocol="${rule_entry#*/}"
                    firewall_apply_port_rule add "$rule_port" "$rule_protocol" || firewall_rc=1
                done <<< "$active_rules"
                unset VPSO_FIREWALLD_OFFLINE_MODE

                if [[ "$OS" =~ debian|ubuntu ]]; then
                    if [[ "$firewall_rc" -eq 0 ]]; then
                        ufw --force enable >/dev/null 2>&1 || firewall_rc=1
                        ufw status 2>/dev/null | grep -qi active || firewall_rc=1
                    fi
                elif [[ "$firewall_rc" -eq 0 ]]; then
                    if [[ "$firewalld_was_inactive" -eq 1 ]]; then
                        systemctl enable --now firewalld >/dev/null 2>&1 || firewall_rc=1
                        systemctl is-active --quiet firewalld || firewall_rc=1
                    else
                        firewall-cmd --reload >/dev/null 2>&1 || firewall_rc=1
                    fi
                fi

                if [[ "$firewall_rc" -ne 0 ]]; then
                    echo -e "${RED}❌ Конфигурация брандмауэра не завершена полностью, исправьте ошибки выше.${PLAIN}"
                    echo -e "${YELLOW}План разрешений: $(echo "$active_rules" | tr '\n' ' ')${PLAIN}"
                    sleep 3
                    continue
                fi
                echo -e "${GREEN}✅ Брандмауэр включён, разрешены: $(echo "$active_rules" | tr '\n' ' ')${PLAIN}"
                sleep 2
                ;;
            3)
                local add_p add_protocol
                echo -e "${YELLOW}💡 Форматы: одиночный порт(80), несколько портов(80,443), диапазон(8000:9000 или 8000-9000)${PLAIN}"
                read_trimmed add_p "👉 Введите порт для разрешения: "
                add_p=$(normalize_port_rule_input "$add_p")
                if [[ -z "$add_p" || "$add_p" == "0" ]]; then
                    echo -e "${BLUE}Добавление правила отменено.${PLAIN}"
                    sleep 1
                    continue
                fi

                if is_valid_port_rule_input "$add_p"; then
                    if [[ "$OS" =~ debian|ubuntu ]]; then
                        install_pkg ufw
                        if ! command -v ufw >/dev/null 2>&1; then
                            echo -e "${RED}❌ ufw не обнаружен, невозможно записать правило.${PLAIN}"
                            sleep 2
                            continue
                        fi
                        if ! ufw status 2>/dev/null | grep -qi active; then
                            echo -e "${YELLOW}⚠️ UFW в данный момент не активен, правило будет добавлено, но для применения требуется включить UFW через [1].${PLAIN}"
                        fi
                    elif ! systemctl is-active --quiet firewalld 2>/dev/null; then
                        echo -e "${RED}❌ Firewalld не запущен. Во избежание блокировки порта сначала используйте [2] для включения и автоматического разрешения активных портов.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    read_trimmed add_protocol "👉 Выберите протокол tcp/udp/both (по умолчанию tcp): "
                    add_protocol=$(normalize_firewall_protocol "${add_protocol:-tcp}" 2>/dev/null || true)
                    if [[ -z "$add_protocol" ]]; then
                        echo -e "${RED}❌ Протокол должен быть tcp, udp или both.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    if firewall_apply_port_input add "$add_p" "$add_protocol" \
                        && { [[ "$OS" =~ debian|ubuntu ]] || firewall-cmd --reload >/dev/null 2>&1; }; then
                        echo -e "${GREEN}✅ Правило [${add_p}/${add_protocol}] добавлено.${PLAIN}"
                    else
                        echo -e "${RED}❌ Правило [${add_p}/${add_protocol}] не добавлено полностью, проверьте ошибки.${PLAIN}"
                    fi
                else
                    echo -e "${RED}❌ Неверный формат порта!${PLAIN}"
                fi
                sleep 2
                ;;
            4)
                local del_p del_protocol
                echo -e "${YELLOW}💡 Форматы: одиночный порт(80), несколько портов(80,443), диапазон(8000:9000 или 8000-9000)${PLAIN}"
                read_trimmed del_p "👉 Введите порт для удаления: "
                del_p=$(normalize_port_rule_input "$del_p")
                if [[ -z "$del_p" || "$del_p" == "0" ]]; then
                    echo -e "${BLUE}Удаление правила отменено.${PLAIN}"
                    sleep 1
                    continue
                fi

                if is_valid_port_rule_input "$del_p"; then
                    confirm_risk_action "Удалить правило разрешения порта ${del_p}" \
                        "Правило разрешения порта в системном брандмауэре" \
                        "Вернитесь в меню брандмауэра и разрешите порт вручную, или восстановите через консоль провайдера/VNC" \
                        "Убедитесь, что не удаляете текущий SSH-порт или бизнес-порт." || {
                        echo -e "${BLUE}Удаление правила отменено.${PLAIN}"
                        sleep 1
                        continue
                    }
                    if [[ "$OS" =~ debian|ubuntu ]]; then
                        install_pkg ufw
                        if ! command -v ufw >/dev/null 2>&1; then
                            echo -e "${RED}❌ ufw не обнаружен, невозможно удалить правило.${PLAIN}"
                            sleep 2
                            continue
                        fi
                    elif ! systemctl is-active --quiet firewalld 2>/dev/null; then
                        echo -e "${RED}❌ Firewalld не запущен, невозможно удалить правила.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    read_trimmed del_protocol "👉 Выберите протокол tcp/udp/both (по умолчанию both): "
                    del_protocol=$(normalize_firewall_protocol "${del_protocol:-both}" 2>/dev/null || true)
                    if [[ -z "$del_protocol" ]]; then
                        echo -e "${RED}❌ Протокол должен быть tcp, udp или both.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    if firewall_apply_port_input delete "$del_p" "$del_protocol" \
                        && { [[ "$OS" =~ debian|ubuntu ]] || firewall-cmd --reload >/dev/null 2>&1; }; then
                        echo -e "${GREEN}✅ Правило [${del_p}/${del_protocol}] удалено.${PLAIN}"
                    else
                        echo -e "${RED}❌ Правило [${del_p}/${del_protocol}] не удалено полностью, проверьте ошибки.${PLAIN}"
                    fi
                else
                    echo -e "${RED}❌ Неверный формат порта!${PLAIN}"
                fi
                sleep 2
                ;;
            5) func_port_connlimit_menu ;;
            6)
                confirm_risk_action "Отключить системный брандмауэр" \
                    "Служба ufw/firewalld и контроль доступа" \
                    "Включите брандмауэр повторно и восстановите правила; при необходимости ограничьте доступ через безопасную группу провайдера" \
                    "Убедитесь, что после отключения не будут открыты базы данных, панели или внутренние службы." || {
                    echo -e "${BLUE}Отключение брандмауэра отменено.${PLAIN}"
                    sleep 1
                    continue
                }
                echo -e "${RED}⚠️ Отключение брандмауэра...${PLAIN}"
                if [[ "$OS" =~ debian|ubuntu ]]; then
                    if ufw disable >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi inactive; then
                        echo -e "${GREEN}✅ Брандмауэр отключён.${PLAIN}"
                    else
                        echo -e "${RED}❌ Не удалось отключить UFW или статус active.${PLAIN}"
                    fi
                else
                    if systemctl disable --now firewalld >/dev/null 2>&1 && ! systemctl is-active --quiet firewalld; then
                        echo -e "${GREEN}✅ Брандмауэр отключён.${PLAIN}"
                    else
                        echo -e "${RED}❌ Не удалось отключить firewalld или служба всё ещё работает.${PLAIN}"
                    fi
                fi
                sleep 2
                ;;
            "?"|help) show_firewall_menu_help; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# Module: caddy_certificates.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Подготовка аккаунта acme.sh, выдача сертификатов через Cloudflare DNS и манифесты сертификатов.

get_acme_account_email() {
    local account_conf="/root/.acme.sh/account.conf"
    if [[ -f "$account_conf" ]]; then
        local existing_email
        existing_email=$(grep '^ACCOUNT_EMAIL=' "$account_conf" 2>/dev/null | cut -d"'" -f2 | cut -d'"' -f2)
        if echo "$existing_email" | grep -Eq '^[a-zA-Z0-9._%+-]+@(gmail\.com|outlook\.com|yahoo\.com|hotmail\.com)$'; then
            echo "$existing_email"
            return
        fi
    fi

    local prefix
    prefix=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 12 2>/dev/null || echo "user$RANDOM$RANDOM")
    local domains=("gmail.com" "outlook.com" "yahoo.com" "hotmail.com")
    local domain="${domains[$((RANDOM % ${#domains[@]}))]}"
    echo "${prefix}@${domain}"
}

prepare_acme_account() {
    local acme_bin="$1"
    local acme_email="$2"
    local account_log="${3:-/tmp/vps_acme_account_$(date +%s).log}"
    local account_conf="/root/.acme.sh/account.conf"
    local le_ca_dir="/root/.acme.sh/ca/acme-v02.api.letsencrypt.org"

    if [[ ! -x "$acme_bin" ]]; then
        return 1
    fi

    mkdir -p /root/.acme.sh
    if [[ -f "$account_conf" ]]; then
        if grep -q '^ACCOUNT_EMAIL=' "$account_conf"; then
            sed -i "s|^ACCOUNT_EMAIL=.*|ACCOUNT_EMAIL='${acme_email}'|" "$account_conf"
        else
            printf "ACCOUNT_EMAIL='%s'\n" "$acme_email" >> "$account_conf"
        fi
    else
        printf "ACCOUNT_EMAIL='%s'\n" "$acme_email" > "$account_conf"
    fi

    export ACCOUNT_EMAIL="$acme_email"
    "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    if "$acme_bin" --register-account --server letsencrypt --accountemail "$acme_email" >"$account_log" 2>&1 || \
       "$acme_bin" --register-account --server letsencrypt -m "$acme_email" >>"$account_log" 2>&1 || \
       "$acme_bin" --update-account --server letsencrypt --accountemail "$acme_email" >>"$account_log" 2>&1 || \
       "$acme_bin" --update-account --server letsencrypt -m "$acme_email" >>"$account_log" 2>&1; then
        return 0
    fi

    # Если состояние аккаунта повреждено (например, старый email), изолируем кеш LE и повторяем.
    quarantine_path "$le_ca_dir" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
    quarantine_path "/root/.acme.sh/ca/acme-staging-v02.api.letsencrypt.org" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
    if "$acme_bin" --register-account --server letsencrypt --accountemail "$acme_email" >>"$account_log" 2>&1 || \
       "$acme_bin" --register-account --server letsencrypt -m "$acme_email" >>"$account_log" 2>&1 || \
       "$acme_bin" --update-account --server letsencrypt --accountemail "$acme_email" >>"$account_log" 2>&1 || \
       "$acme_bin" --update-account --server letsencrypt -m "$acme_email" >>"$account_log" 2>&1; then
        return 0
    fi

    return 1
}

quarantine_legacy_caddy_443_configs() {
    local conf_dir="/etc/caddy/conf.d"
    local quarantine_dir="/etc/caddy/conf.d_quarantine_443_$(date +%s)"
    local moved_count=0

    if [[ ! -d "$conf_dir" ]]; then
        return 0
    fi

    while IFS= read -r conf_file; do
        local first_site_line
        first_site_line=$(grep -m1 -E '^[[:space:]]*[^#[:space:]].*\{' "$conf_file" 2>/dev/null | sed 's/^[[:space:]]*//')

        [[ -z "$first_site_line" ]] && continue

        # Новый стандарт Reality+CF: https://domain:port { + bind 127.0.0.1
        if [[ "$first_site_line" =~ ^https://[^[:space:]]+:[0-9]+[[:space:]]*\{ ]]; then
            continue
        fi

        mkdir -p "$quarantine_dir"
        mv "$conf_file" "$quarantine_dir/" >/dev/null 2>&1
        ((moved_count++))
    done < <(find "$conf_dir" -maxdepth 1 -type f -name "*.caddy" 2>/dev/null | sort)

    if [[ "$moved_count" -gt 0 ]]; then
        echo -e "${YELLOW}⚠️ Автоматически изолированы ${moved_count} старых конфигураций сайтов (могут занимать 443) в: ${quarantine_dir}${PLAIN}"
    fi
}

issue_cf_dns_cert_with_retry() {
    local domain="$1"
    local cf_token_raw="$2"
    local acme_bin="$3"
    local cf_token
    local acme_log
    local acme_email

    cf_token=$(echo "$cf_token_raw" | tr -d '\r\n')
    if [[ -z "$cf_token" || ! -x "$acme_bin" || -z "$domain" ]]; then
        return 1
    fi

    acme_log="/tmp/vps_acme_${domain}_$(date +%s).log"
    acme_email=$(get_acme_account_email)

    # Принудительно используем Let's Encrypt, чтобы избежать требований EAB от ZeroSSL.
    if ! prepare_acme_account "$acme_bin" "$acme_email" "$acme_log"; then
        mkdir -p /root/cert
        cp -f "$acme_log" /root/cert/acme_last_error.log >/dev/null 2>&1 || true
        echo -e "${RED}❌ Не удалось инициализировать аккаунт acme: ${domain}${PLAIN}"
        echo -e "${YELLOW}   Последний лог ошибок: /root/cert/acme_last_error.log${PLAIN}"
        local account_hint
        account_hint=$(grep -Ei 'error|invalid|unauthorized|forbidden|failed|contact|account' "$acme_log" | tail -n 12)
        if [[ -n "$account_hint" ]]; then
            echo -e "${YELLOW}   Ключевые ошибки:${PLAIN}"
            echo "$account_hint"
        fi
        return 1
    fi

    if CF_Token="$cf_token" "$acme_bin" --issue --server letsencrypt --dns dns_cf -d "$domain" --keylength ec-256 >"$acme_log" 2>&1; then
        return 0
    fi

    # Если старые остатки мешают, изолируем историю и принудительно перевыпускаем.
    "$acme_bin" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
    quarantine_path "/root/.acme.sh/${domain}_ecc" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
    quarantine_path "/root/.acme.sh/${domain}" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true

    if CF_Token="$cf_token" "$acme_bin" --issue --server letsencrypt --dns dns_cf -d "$domain" --keylength ec-256 --force >>"$acme_log" 2>&1; then
        return 0
    fi

    if CF_Token="$cf_token" "$acme_bin" --renew --server letsencrypt -d "$domain" --force --ecc >>"$acme_log" 2>&1; then
        return 0
    fi

    mkdir -p /root/cert
    cp -f "$acme_log" /root/cert/acme_last_error.log >/dev/null 2>&1 || true
    echo -e "${RED}❌ Окончательная ошибка acme.sh: ${domain}${PLAIN}"
    echo -e "${YELLOW}   Лог ошибок: /root/cert/acme_last_error.log${PLAIN}"

    local acme_hint
    acme_hint=$(grep -Ei 'error|invalid|unauthorized|forbidden|failed|timeout|SERVFAIL|NXDOMAIN|permission' "$acme_log" | tail -n 12)
    if [[ -n "$acme_hint" ]]; then
        echo -e "${YELLOW}   Ключевые ошибки:${PLAIN}"
        echo "$acme_hint"
    else
        echo -e "${YELLOW}   Не удалось извлечь ключевые ошибки, вывод хвоста лога:${PLAIN}"
        tail -n 12 "$acme_log"
    fi

    return 1
}

verify_cf_token_online() {
    local cf_token_raw="$1"
    local cf_token
    local verify_resp

    cf_token=$(echo "$cf_token_raw" | tr -d '\r\n')
    if [[ -z "$cf_token" ]]; then
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        return 2
    fi

    verify_resp=$(curl -s --max-time 10 -H "Authorization: Bearer ${cf_token}" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)
    if echo "$verify_resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        return 0
    fi
    return 1
}

caddy_conf_site_listen_port() {
    local conf_file="$1"
    sed -n '1{s@^[[:space:]]*https://[^[:space:]]*:\([0-9]\+\)[[:space:]]*{.*$@\1@p;q}' "$conf_file"
}

caddy_conf_site_bind_addr() {
    local conf_file="$1"
    awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*bind[[:space:]]+/ {print $2; exit}
    ' "$conf_file"
}

caddy_conf_site_listen_target() {
    local conf_file="$1"
    local listen_port
    local listen_addr

    listen_port=$(caddy_conf_site_listen_port "$conf_file")
    [[ -z "$listen_port" ]] && return 1

    listen_addr=$(caddy_conf_site_bind_addr "$conf_file")
    [[ -z "$listen_addr" ]] && listen_addr="0.0.0.0"

    if [[ "$listen_addr" == *:* && "$listen_addr" != \[* ]]; then
        echo "[${listen_addr}]:${listen_port}"
    else
        echo "${listen_addr}:${listen_port}"
    fi
}

caddy_conf_first_reverse_proxy_target() {
    local conf_file="$1"
    awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*reverse_proxy[[:space:]]+/ {
            target=$2
            sub(/\{[[:space:]]*$/, "", target)
            print target
            exit
        }
    ' "$conf_file"
}

caddy_reverse_proxy_target_port() {
    local target="$1"
    local port

    target="${target#http://}"
    target="${target#https://}"
    target="${target%%/*}"

    port=$(printf '%s\n' "$target" | sed -n 's@^\[[^]]\+\]:\([0-9]\+\)$@\1@p')
    if [[ -z "$port" ]]; then
        port=$(printf '%s\n' "$target" | sed -n 's@^.*:\([0-9]\+\)$@\1@p')
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    echo "$port"
}

caddy_reverse_proxy_target_host() {
    local target="$1"

    target="${target#http://}"
    target="${target#https://}"
    target="${target%%/*}"
    if [[ "$target" =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$target" =~ ^(.+):[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

caddy_listen_addr_port_is_visible() {
    local addr="$1"
    local port="$2"
    local host_regex

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ -z "$addr" ]] && addr="0.0.0.0"
    addr="${addr#\[}"
    addr="${addr%\]}"

    case "$addr" in
        "127.0.0.1") host_regex='(127\.0\.0\.1|0\.0\.0\.0|\*)' ;;
        "localhost") host_regex='(127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\[::\]|\*)' ;;
        "0.0.0.0") host_regex='(0\.0\.0\.0|\*)' ;;
        "::1") host_regex='(\[::1\]|\[::\]|\*)' ;;
        "::") host_regex='(\[::\]|\*)' ;;
        *) host_regex=$(printf '%s' "$addr" | sed 's/[.[\*^$()+?{}|\\]/\\&/g') ;;
    esac

    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "^${host_regex}:${port}$"
}

caddy_listen_port_is_visible() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"
}

generate_caddy_cf_manifest() {
    local summary_file="/root/cert/caddy_cf_manifest.txt"
    mkdir -p /root/cert
    : > "$summary_file"
    echo "Манифест автоматизации Caddy CF DNS - $(date '+%F %T')" >> "$summary_file"
    echo "------------------------------------------------" >> "$summary_file"

    local found=false
    if [[ -d /etc/caddy/conf.d ]]; then
        while IFS= read -r conf_file; do
            local domain
            local listen_target
            local backend
            domain=$(basename "$conf_file" .caddy)

            if [[ ! -f "/etc/caddy/certs/${domain}.crt" || ! -f "/etc/caddy/certs/${domain}.key" ]]; then
                continue
            fi

            listen_target=$(caddy_conf_site_listen_target "$conf_file")
            backend=$(caddy_conf_first_reverse_proxy_target "$conf_file")

            [[ -z "$listen_target" ]] && listen_target="неизвестно"
            [[ -z "$backend" ]] && backend="неизвестно"

            echo "Домен: ${domain}" >> "$summary_file"
            echo "  Бэкенд: ${backend}" >> "$summary_file"
            echo "  Caddy слушает: ${listen_target}" >> "$summary_file"
            echo "  Сертификат CRT: /root/cert/${domain}.crt" >> "$summary_file"
            echo "  Сертификат KEY: /root/cert/${domain}.key" >> "$summary_file"
            echo "  Файл конфигурации: ${conf_file}" >> "$summary_file"
            echo "------------------------------------------------" >> "$summary_file"
            found=true
        done < <(find /etc/caddy/conf.d -maxdepth 1 -type f -name "*.caddy" 2>/dev/null | sort)
    fi

    if ! $found; then
        echo "В данный момент нет управляемых конфигураций сайтов CF DNS." >> "$summary_file"
        echo "------------------------------------------------" >> "$summary_file"
    fi
}

# ---------------------------------------------------------
# 3. Установка окружения и ПО (рефакторинг: защита от перезаписи, строгая обработка ошибок)
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: caddy_proxy.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Обычные обратные прокси Caddy/Nginx вне единого входа 443.

write_caddy_reverse_proxy_conf() {
    local domain="$1"
    local backend_addr="$2"
    local port="$3"
    local is_https="$4"
    local conf_file="$5"
    local ip_whitelist_ranges="${6:-}"
    local backend_hostport
    backend_hostport=$(format_hostport "$backend_addr" "$port")

    if is_yes "$is_https"; then
        cat <<EOF > "$conf_file"
$domain {
$(caddy_ip_whitelist_block "$ip_whitelist_ranges")    reverse_proxy https://${backend_hostport} {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF
    else
        cat <<EOF > "$conf_file"
$domain {
$(caddy_ip_whitelist_block "$ip_whitelist_ranges")    reverse_proxy ${backend_hostport}
}
EOF
    fi
}

validate_caddy_config_with_log() {
    local log_file="$1"
    caddy validate --config /etc/caddy/Caddyfile >"$log_file" 2>&1
}

print_caddy_validate_failure() {
    local title="$1"
    local log_file="$2"
    local generated_conf="${3:-}"

    echo -e "${RED}❌ ${title}${PLAIN}"
    if [[ -s "$log_file" ]]; then
        echo -e "${YELLOW}Ошибка Caddy:${PLAIN}"
        tail -n 40 "$log_file" 2>/dev/null || true
        echo -e "${YELLOW}Полный лог: ${log_file}${PLAIN}"
    else
        echo -e "${YELLOW}Caddy не вернул подробной ошибки, выполните вручную: caddy validate --config /etc/caddy/Caddyfile${PLAIN}"
    fi
    if [[ -n "$generated_conf" && -f "$generated_conf" ]]; then
        echo -e "${YELLOW}Новая конфигурация: ${generated_conf}${PLAIN}"
        sed -n '1,80p' "$generated_conf" 2>/dev/null || true
    fi
}

func_caddy_add_reverse_proxy() {
    echo -e "${CYAN}▶ Проверка и установка Caddy...${PLAIN}"
    if ! install_caddy_if_needed; then
        echo -e "${RED}❌ Не удалось установить Caddy, проверьте источник пакетов, сеть или версию системы.${PLAIN}"
        return 1
    fi
    if ! ensure_caddy_module_layout; then
        echo -e "${RED}❌ Не удалось инициализировать каталог конфигурации Caddy, проверьте права /etc/caddy.${PLAIN}"
        return 1
    fi

    local validate_log
    validate_log=$(mktemp /tmp/vps-caddy-validate.XXXXXX.log) || return 1
    if ! validate_caddy_config_with_log "$validate_log"; then
        print_caddy_validate_failure "Текущая конфигурация Caddy не прошла проверку, новый прокси не записан." "$validate_log"
        echo -e "${YELLOW}Сначала исправьте /etc/caddy/Caddyfile или /etc/caddy/conf.d/*.caddy, затем добавьте домен.${PLAIN}"
        return 1
    fi

    local domain domain_input backend_addr port is_https
    read_trimmed domain_input "Введите разрешённый домен (например panel.site.com): "
    read_trimmed port "Введите локальный порт бэкенда (например 40000): "
    backend_addr=$(ask_with_default "Адрес бэкенда" "127.0.0.1")
    backend_addr=$(normalize_backend_addr_input "$backend_addr")
    domain=$(normalize_domain_input "$domain_input")

    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        return 1
    fi
    if ! is_valid_port "$port"; then
        echo -e "${RED}❌ Неверный порт: ${port}, должен быть 1-65535.${PLAIN}"
        return 1
    fi

    if ! is_valid_backend_addr "$backend_addr"; then
        echo -e "${RED}❌ Неверный адрес бэкенда: ${backend_addr}${PLAIN}"
        return 1
    fi

    local domain_conf="/etc/caddy/conf.d/${domain}.caddy"
    if grep -q "^[[:space:]]*$domain" /etc/caddy/Caddyfile 2>/dev/null || [[ -e "$domain_conf" ]]; then
        echo -e "${RED}❌ Ошибка: конфигурация для этого домена уже существует! Очистите или смените домен.${PLAIN}"
        return 1
    fi

    read_trimmed is_https "❓ Бэкенд использует собственный SSL-сертификат? (y/n): "

    local enable_ip_whitelist ip_whitelist_input ip_whitelist_ranges current_client_ip
    local -a ip_whitelist_array=()
    read_trimmed enable_ip_whitelist "❓ Разрешить доступ к этому домену только с указанных IP/CIDR? (y/n, по умолчанию n): "
    if is_yes "$enable_ip_whitelist"; then
        current_client_ip=$(detect_ssh_client_ip)
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен в белый список.${PLAIN}"
        read_trimmed ip_whitelist_input "Введите IP/CIDR, разрешённые для ${domain} (несколько через пробел или запятую): "
        if ! normalize_ip_whitelist_input "$ip_whitelist_input" ip_whitelist_array; then
            echo -e "${RED}❌ Белый список пуст или неверный формат, настройка прокси отменена.${PLAIN}"
            return 1
        fi
        append_vps_public_ips_to_whitelist ip_whitelist_array
        ip_whitelist_ranges=$(join_array_by_space "${ip_whitelist_array[@]}")
    else
        ip_whitelist_ranges=""
    fi

    local backup_file="/etc/caddy/Caddyfile.bak_$(date +%s)"
    [[ -f /etc/caddy/Caddyfile ]] && cp -p /etc/caddy/Caddyfile "$backup_file"

    write_caddy_reverse_proxy_conf "$domain" "$backend_addr" "$port" "$is_https" "$domain_conf" "$ip_whitelist_ranges"

    echo -e "${CYAN}▶ Проверка конфигурации Caddy...${PLAIN}"
    if validate_caddy_config_with_log "$validate_log"; then
        if systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Конфигурация обратного прокси Caddy добавлена и активна! https://$domain${PLAIN}"
            [[ -n "$ip_whitelist_ranges" ]] && echo -e "${GREEN}✅ Для ${domain} включён IP-белый список: ${ip_whitelist_ranges}${PLAIN}"
            echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
        else
            echo -e "${RED}❌ Конфигурация Caddy проверена, но перезагрузка службы не удалась, откат...${PLAIN}"
            [[ -f "$backup_file" ]] && mv "$backup_file" /etc/caddy/Caddyfile
            quarantine_path "$domain_conf" "/etc/vps-optimize/quarantine/caddy-conf" >/dev/null 2>&1 || true
            systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
            return 1
        fi
    else
        print_caddy_validate_failure "После записи нового прокси проверка Caddy не удалась, автоматический откат." "$validate_log" "$domain_conf"
        [[ -f "$backup_file" ]] && mv "$backup_file" /etc/caddy/Caddyfile
        quarantine_path "$domain_conf" "/etc/vps-optimize/quarantine/caddy-conf" >/dev/null 2>&1 || true
        return 1
    fi
}

nginx_proxy_conf_path() {
    local domain="$1"
    echo "/etc/nginx/conf.d/vps_proxy_${domain}.conf"
}

install_nginx_http_if_needed() {
    command -v nginx >/dev/null 2>&1 && return 0
    echo -e "${CYAN}▶ Nginx не обнаружен, установка...${PLAIN}"
    if is_debian || is_redhat; then
        install_pkg nginx || return 1
    else
        echo -e "${RED}❌ Автоматическая установка Nginx не поддерживается на текущей системе.${PLAIN}"
        return 1
    fi
    command -v nginx >/dev/null 2>&1
}

ensure_nginx_http_conf_d() {
    local nginx_conf="/etc/nginx/nginx.conf"
    mkdir -p /etc/nginx/conf.d || return 1
    [[ -f "$nginx_conf" ]] || { echo -e "${RED}❌ ${nginx_conf} не найден.${PLAIN}"; return 1; }
    if grep -q '/etc/nginx/conf.d/\*.conf' "$nginx_conf" 2>/dev/null; then
        return 0
    fi
    if grep -Eq '^[[:space:]]*http[[:space:]]*\{' "$nginx_conf" 2>/dev/null; then
        cp -p "$nginx_conf" "${nginx_conf}.bak_$(date +%s)" 2>/dev/null || true
        sed -i '/^[[:space:]]*http[[:space:]]*{/a\    include /etc/nginx/conf.d/*.conf;' "$nginx_conf"
        return 0
    fi
    echo -e "${RED}❌ В nginx.conf не найден блок http {}, невозможно безопасно добавить include conf.d.${PLAIN}"
    return 1
}

write_nginx_proxy_map_conf() {
    mkdir -p /etc/nginx/conf.d || return 1
    cat <<'EOF' > /etc/nginx/conf.d/00-vps-proxy-map.conf
map $http_upgrade $vps_proxy_connection_upgrade {
    default upgrade;
    '' close;
}
EOF
}

nginx_ip_whitelist_block() {
    local ranges="$1"
    [[ -z "$ranges" ]] && return 0
    {
        echo "    # vps-optimize-ip-whitelist-start"
        local range
        for range in $ranges; do
            echo "    allow ${range};"
        done
        echo "    deny all;"
        echo "    # vps-optimize-ip-whitelist-end"
    }
}

strip_nginx_ip_whitelist_block() {
    local conf_file="$1"
    local tmp_file
    tmp_file=$(mktemp /tmp/nginx-ipwl.XXXXXX) || return 1
    awk '
        /# vps-optimize-ip-whitelist-start/ {skip=1; next}
        /# vps-optimize-ip-whitelist-end/ {skip=0; next}
        !skip {print}
    ' "$conf_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv "$tmp_file" "$conf_file"
}

insert_nginx_ip_whitelist_block() {
    local conf_file="$1"
    local ranges="$2"
    local tmp_file block
    strip_nginx_ip_whitelist_block "$conf_file" || return 1
    tmp_file=$(mktemp /tmp/nginx-ipwl.XXXXXX) || return 1
    block=$(nginx_ip_whitelist_block "$ranges")
    awk -v block="$block" '
        inserted == 0 && /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/ {
            printf "%s\n", block
            print
            inserted=1
            next
        }
        {print}
        END { if (inserted == 0) exit 1 }
    ' "$conf_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv "$tmp_file" "$conf_file"
}

nginx_proxy_whitelist_ranges_from_conf() {
    local conf_file="$1"
    awk '
        /# vps-optimize-ip-whitelist-start/ {in_block=1; next}
        /# vps-optimize-ip-whitelist-end/ {in_block=0; next}
        in_block && /^[[:space:]]*allow[[:space:]]+/ {
            gsub(/^[[:space:]]*allow[[:space:]]+/, "", $0)
            gsub(/[;[:space:]]+$/, "", $0)
            if ($0 != "") print $0
        }
    ' "$conf_file" | paste -sd' ' -
}

nginx_proxy_ipv6_enabled() {
    local if_inet6="${VPSO_PROC_NET_IF_INET6:-/proc/net/if_inet6}"
    local disable_ipv6="${VPSO_PROC_SYS_DISABLE_IPV6:-/proc/sys/net/ipv6/conf/all/disable_ipv6}"
    [[ -s "$if_inet6" && "$(cat "$disable_ipv6" 2>/dev/null || echo 1)" != "1" ]]
}

nginx_proxy_domain_exists() {
    local domain="$1"
    [[ -e "$(nginx_proxy_conf_path "$domain")" ]] && return 0
    grep -RqsE "server_name[[:space:]].*\\b${domain}\\b" /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null
}

nginx_proxy_warn_if_single_entry_enabled() {
    if [[ -f /etc/vps-optimize/sni-stack.env || -f /etc/vps-optimize/443-engine.conf ]]; then
        echo -e "${RED}❌ Обнаружена конфигурация единого входа 443. HTTPS-прокси Nginx будет занимать публичный порт 443, продолжение отклонено.${PLAIN}"
        echo -e "${YELLOW}Используйте: главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси].${PLAIN}"
        return 1
    fi
    return 0
}

quarantine_legacy_nginx_https_proxy_configs() {
    local conf_file moved=0
    for conf_file in /etc/nginx/conf.d/vps_proxy_*.conf; do
        [[ -e "$conf_file" ]] || continue
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/nginx-proxy-to-443-entry" >/dev/null 2>&1 || true
        moved=$((moved + 1))
    done
    if [[ "$moved" -gt 0 ]]; then
        echo -e "${YELLOW}⚠️ Изолированы ${moved} старых конфигураций Nginx HTTPS прокси, чтобы не занимать публичный 443.${PLAIN}"
    fi
}

nginx_proxy_ensure_certificate() {
    local domain="$1"
    local cert_file="/etc/caddy/certs/${domain}.crt"
    local key_file="/etc/caddy/certs/${domain}.key"
    local reuse_cert CF_TOKEN verify_rc

    if [[ -s "$cert_file" && -s "$key_file" ]]; then
        read_trimmed reuse_cert "Обнаружен существующий сертификат ${cert_file}, использовать повторно? (Y/n, по умолчанию yes): "
        if ! is_no "$reuse_cert"; then
            echo -e "${GREEN}✅ Использован существующий сертификат: ${cert_file}${PLAIN}"
            return 0
        fi
    fi

    echo -e "${YELLOW}Сертификат для Nginx прокси будет получен через acme.sh + Cloudflare DNS API.${PLAIN}"
    echo -e "${YELLOW}Сертификат будет установлен в /etc/caddy/certs/${domain}.crt|key и символическая ссылка в /root/cert/.${PLAIN}"
    read_secret_trimmed CF_TOKEN "Введите Cloudflare API Token (нужны права на DNS-правки для этого домена): "
    if [[ -z "$CF_TOKEN" || ${#CF_TOKEN} -lt 20 ]]; then
        echo -e "${RED}❌ Неверная длина Cloudflare Token.${PLAIN}"
        return 1
    fi
    verify_cf_token_online "$CF_TOKEN"
    verify_rc=$?
    if [[ "$verify_rc" -eq 0 ]]; then
        echo -e "${GREEN}✅ Проверка Cloudflare Token пройдена.${PLAIN}"
    elif [[ "$verify_rc" -eq 2 ]]; then
        echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку.${PLAIN}"
    else
        echo -e "${RED}❌ Ошибка онлайн-проверки Cloudflare Token.${PLAIN}"
        return 1
    fi
    issue_and_install_cert_for_domain "$domain" "$CF_TOKEN" || return 1
    [[ -s "$cert_file" && -s "$key_file" ]] || { echo -e "${RED}❌ Сертификат отсутствует: ${cert_file}|${key_file}${PLAIN}"; return 1; }
}

write_nginx_reverse_proxy_conf() {
    local domain="$1"
    local port="$2"
    local is_https="$3"
    local conf_file="$4"
    local ip_whitelist_ranges="${5:-}"
    local backend_scheme="http"
    local proxy_ssl_block=""
    local ip_whitelist_block=""
    local listen_80_ipv6=""
    local listen_443_ipv6=""

    if is_yes "$is_https"; then
        backend_scheme="https"
        proxy_ssl_block="    proxy_ssl_server_name on;
    proxy_ssl_verify off;"
    fi
    ip_whitelist_block=$(nginx_ip_whitelist_block "$ip_whitelist_ranges")
    if nginx_proxy_ipv6_enabled; then
        listen_80_ipv6="    listen [::]:80;"
        listen_443_ipv6="    listen [::]:443 ssl http2;"
    fi

    cat <<EOF > "$conf_file"
server {
    listen 80;
${listen_80_ipv6}
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
${listen_443_ipv6}
    server_name ${domain};

    ssl_certificate /etc/caddy/certs/${domain}.crt;
    ssl_certificate_key /etc/caddy/certs/${domain}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    location / {
${ip_whitelist_block}
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$vps_proxy_connection_upgrade;
${proxy_ssl_block}
        proxy_pass ${backend_scheme}://127.0.0.1:${port};
    }
}
EOF
}

func_nginx_add_reverse_proxy() {
    echo -e "${CYAN}▶ Настройка HTTPS прокси Nginx...${PLAIN}"
    nginx_proxy_warn_if_single_entry_enabled || return 1
    local domain domain_input port is_https conf_file enable_ip_whitelist ip_whitelist_input ip_whitelist_ranges current_client_ip
    local -a ip_whitelist_array=()
    read_trimmed domain_input "Введите разрешённый домен (например panel.example.com): "
    read_trimmed port "Введите локальный порт бэкенда (например 40000): "
    domain=$(normalize_domain_input "$domain_input")

    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        return 1
    fi
    if ! is_valid_port "$port"; then
        echo -e "${RED}❌ Неверный порт: ${port}, должен быть 1-65535.${PLAIN}"
        return 1
    fi

    conf_file=$(nginx_proxy_conf_path "$domain")
    if nginx_proxy_domain_exists "$domain"; then
        echo -e "${RED}❌ Конфигурация для этого домена уже существует в Nginx, очистите или смените домен.${PLAIN}"
        return 1
    fi
    if [[ -e "/etc/caddy/conf.d/${domain}.caddy" ]] || grep -q "^[[:space:]]*$domain" /etc/caddy/Caddyfile 2>/dev/null; then
        echo -e "${RED}❌ Домен уже существует в Caddy, не используйте один домен в Caddy и Nginx одновременно.${PLAIN}"
        return 1
    fi

    read_trimmed is_https "Бэкенд использует собственный HTTPS-сертификат? (y/n, по умолчанию n): "
    read_trimmed enable_ip_whitelist "Разрешить доступ к Nginx домену только с указанных IP/CIDR? (y/n, по умолчанию n): "
    if is_yes "$enable_ip_whitelist"; then
        current_client_ip=$(detect_ssh_client_ip)
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен в белый список.${PLAIN}"
        read_trimmed ip_whitelist_input "Введите IP/CIDR, разрешённые для ${domain} (несколько через пробел или запятую): "
        if ! normalize_ip_whitelist_input "$ip_whitelist_input" ip_whitelist_array; then
            echo -e "${RED}❌ Белый список пуст или неверный формат, настройка прокси отменена.${PLAIN}"
            return 1
        fi
        append_vps_public_ips_to_whitelist ip_whitelist_array
        ip_whitelist_ranges=$(join_array_by_space "${ip_whitelist_array[@]}")
    else
        ip_whitelist_ranges=""
    fi
    nginx_proxy_ensure_certificate "$domain" || return 1
    install_nginx_http_if_needed || { echo -e "${RED}❌ Не удалось установить Nginx, проверьте источник пакетов, сеть или версию системы.${PLAIN}"; return 1; }
    ensure_nginx_http_conf_d || return 1
    harden_nginx_public_errors
    write_nginx_proxy_map_conf || return 1
    write_nginx_reverse_proxy_conf "$domain" "$port" "$is_https" "$conf_file" "$ip_whitelist_ranges" || return 1

    echo -e "${CYAN}▶ Проверка конфигурации Nginx...${PLAIN}"
    if ! nginx -t >/dev/null 2>&1; then
        echo -e "${RED}❌ Проверка конфигурации Nginx не удалась, новая конфигурация изолирована.${PLAIN}"
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/nginx-proxy" >/dev/null 2>&1 || true
        nginx -t
        return 1
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    if systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Nginx прокси активен: https://${domain}${PLAIN}"
        echo -e "${GREEN}✅ Бэкенд: 127.0.0.1:${port}${PLAIN}"
        [[ -n "$ip_whitelist_ranges" ]] && echo -e "${GREEN}✅ Для ${domain} включён IP-белый список: ${ip_whitelist_ranges}${PLAIN}"
        echo -e "${CYAN}Файл конфигурации: ${conf_file}${PLAIN}"
        echo -e "${CYAN}Путь к сертификату: /etc/caddy/certs/${domain}.crt и /etc/caddy/certs/${domain}.key${PLAIN}"
    else
        echo -e "${RED}❌ Проверка конфигурации Nginx пройдена, но перезагрузка службы не удалась. Возможно, Caddy, единый вход 443 или другая служба заняла 80/443.${PLAIN}"
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/nginx-proxy" >/dev/null 2>&1 || true
        return 1
    fi
}

func_nginx_add_insecure() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🛡️ Nginx пропуск проверки сертификата бэкенда HTTPS${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    nginx_proxy_warn_if_single_entry_enabled || return 1

    local domain domain_input port conf_file backup_file ip_whitelist_ranges
    read_trimmed domain_input "Введите домен (например panel.example.com): "
    read_trimmed port "Введите локальный HTTPS-порт бэкенда (например 40000): "
    domain=$(normalize_domain_input "$domain_input")
    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        return 1
    fi
    if ! is_valid_port "$port"; then
        echo -e "${RED}❌ Неверный порт: ${port}, должен быть 1-65535.${PLAIN}"
        return 1
    fi

    nginx_proxy_ensure_certificate "$domain" || return 1
    install_nginx_http_if_needed || return 1
    ensure_nginx_http_conf_d || return 1
    harden_nginx_public_errors
    write_nginx_proxy_map_conf || return 1

    conf_file=$(nginx_proxy_conf_path "$domain")
    if [[ -f "$conf_file" ]]; then
        backup_file="${conf_file}.bak_$(date +%s)"
        cp -p "$conf_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, отмена.${PLAIN}"; return 1; }
        ip_whitelist_ranges=$(nginx_proxy_whitelist_ranges_from_conf "$conf_file")
        echo -e "${CYAN}Создана резервная копия текущей конфигурации: ${backup_file}${PLAIN}"
    else
        ip_whitelist_ranges=""
    fi

    write_nginx_reverse_proxy_conf "$domain" "$port" "y" "$conf_file" "$ip_whitelist_ranges" || return 1
    if nginx -t >/dev/null 2>&1; then
        if systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Nginx настроен на HTTPS бэкенд с пропуском проверки сертификата: ${domain} -> https://127.0.0.1:${port}${PLAIN}"
            [[ -n "$ip_whitelist_ranges" ]] && echo -e "${GREEN}✅ IP-белый список сохранён: ${ip_whitelist_ranges}${PLAIN}"
        else
            echo -e "${RED}❌ Проверка Nginx пройдена, но перезагрузка службы не удалась.${PLAIN}"
            [[ -n "$backup_file" && -f "$backup_file" ]] && cp -p "$backup_file" "$conf_file"
            return 1
        fi
    else
        echo -e "${RED}❌ Проверка конфигурации Nginx не удалась, откат.${PLAIN}"
        [[ -n "$backup_file" && -f "$backup_file" ]] && cp -p "$backup_file" "$conf_file"
        nginx -t
        return 1
    fi
}

func_proxy_add_insecure() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🛡️ Пропуск проверки сертификата бэкенда HTTPS${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${GREEN}  1. Caddy пропуск проверки${PLAIN}"
    echo -e "${GREEN}  2. Nginx пропуск проверки${PLAIN}"
    echo -e "${RED}  0. Отмена${PLAIN}"
    local choice
    read_trimmed choice "Выберите действие: "
    case "$choice" in
        1) func_caddy_add_insecure ;;
        2) func_nginx_add_insecure ;;
        0|q|Q|"") echo -e "${BLUE}Отмена.${PLAIN}" ;;
        *) echo -e "${RED}❌ Неверный выбор.${PLAIN}" ;;
    esac
}

func_nginx_manage_ip_whitelist() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔐 IP-белый список Nginx для доменов${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Применяется для доменов, где не включён единый вход 443 и Nginx HTTPS прокси обслуживает напрямую.${PLAIN}"
    echo -e "${YELLOW}Если домен уже использует единый вход 443, используйте главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси] -> [5 Управление IP-белым списком домена], не ограничивайте на уровне Nginx HTTP.${PLAIN}"
    echo -e "------------------------------------------------"

    local domain domain_input conf_file action backup_file
    read_trimmed domain_input "Введите домен для управления (например panel.example.com): "
    domain=$(normalize_domain_input "$domain_input")
    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        return 1
    fi
    conf_file=$(nginx_proxy_conf_path "$domain")
    if [[ ! -f "$conf_file" ]]; then
        echo -e "${RED}❌ ${conf_file} не найден. Этот пункт управляет только конфигурациями Nginx HTTPS прокси, созданными скриптом.${PLAIN}"
        return 1
    fi

    echo -e "Текущий файл конфигурации: ${conf_file}"
    if grep -q '# vps-optimize-ip-whitelist-start' "$conf_file" 2>/dev/null; then
        echo -e "${YELLOW}Текущее состояние: включён управляемый скриптом IP-белый список.${PLAIN}"
        echo -e "Текущий белый список: $(nginx_proxy_whitelist_ranges_from_conf "$conf_file")"
    else
        echo -e "${BLUE}Текущее состояние: управляемый скриптом IP-белый список не включён.${PLAIN}"
    fi
    echo -e "1. Установить/перезаписать белый список"
    echo -e "2. Очистить белый список"
    echo -e "0/q. Отмена"
    read_trimmed action "Выберите действие: "

    backup_file="${conf_file}.bak_$(date +%s)"
    case "$action" in
        1)
            local ip_whitelist_input ip_whitelist_ranges current_client_ip
            local -a ip_whitelist_array=()
            current_client_ip=$(detect_ssh_client_ip)
            [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен.${PLAIN}"
            read_trimmed ip_whitelist_input "Введите IP/CIDR, разрешённые для ${domain} (несколько через пробел или запятую): "
            if ! normalize_ip_whitelist_input "$ip_whitelist_input" ip_whitelist_array; then
                echo -e "${RED}❌ Белый список пуст или неверный формат, отмена.${PLAIN}"
                return 1
            fi
            append_vps_public_ips_to_whitelist ip_whitelist_array
            ip_whitelist_ranges=$(join_array_by_space "${ip_whitelist_array[@]}")
            cp -p "$conf_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, отмена.${PLAIN}"; return 1; }
            if insert_nginx_ip_whitelist_block "$conf_file" "$ip_whitelist_ranges" && nginx -t >/dev/null 2>&1; then
                if systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ Для ${domain} включён IP-белый список Nginx: ${ip_whitelist_ranges}${PLAIN}"
                    echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
                else
                    echo -e "${RED}❌ Перезагрузка Nginx не удалась, откат...${PLAIN}"
                    cp -p "$backup_file" "$conf_file"
                    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
                    return 1
                fi
            else
                echo -e "${RED}❌ Проверка Nginx после записи не удалась, откат...${PLAIN}"
                cp -p "$backup_file" "$conf_file"
                nginx -t
                return 1
            fi
            ;;
        2)
            if ! grep -q '# vps-optimize-ip-whitelist-start' "$conf_file" 2>/dev/null; then
                echo -e "${BLUE}Для этого домена нет блока белого списка, созданного скриптом.${PLAIN}"
                return 0
            fi
            cp -p "$conf_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, отмена.${PLAIN}"; return 1; }
            if strip_nginx_ip_whitelist_block "$conf_file" && nginx -t >/dev/null 2>&1; then
                systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
                echo -e "${GREEN}✅ IP-белый список Nginx для ${domain} очищен.${PLAIN}"
                echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
            else
                echo -e "${RED}❌ Проверка Nginx после очистки не удалась, откат...${PLAIN}"
                cp -p "$backup_file" "$conf_file"
                return 1
            fi
            ;;
        0|q|Q|"")
            echo -e "${BLUE}Отмена.${PLAIN}"
            ;;
        *)
            echo -e "${RED}❌ Неверное действие.${PLAIN}"
            ;;
    esac
}

func_proxy_manage_ip_whitelist() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔐 IP-белый список доменов (Caddy / Nginx)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${GREEN}  1. IP-белый список Caddy${PLAIN}"
    echo -e "${GREEN}  2. IP-белый список Nginx${PLAIN}"
    echo -e "${RED}  0. Отмена${PLAIN}"
    local choice
    read_trimmed choice "Выберите действие: "
    case "$choice" in
        1) func_caddy_manage_ip_whitelist ;;
        2) func_nginx_manage_ip_whitelist ;;
        0|q|Q|"") echo -e "${BLUE}Отмена.${PLAIN}" ;;
        *) echo -e "${RED}❌ Неверный выбор.${PLAIN}" ;;
    esac
}

func_nginx_clear_proxy_config() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧹 Очистка конфигураций HTTPS прокси Nginx${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Будут изолированы только файлы /etc/nginx/conf.d/vps_proxy_*.conf и 00-vps-proxy-map.conf, созданные VPS-Optimize.${PLAIN}"
    echo -e "${YELLOW}Не затрагиваются /etc/nginx/stream.d и конфигурации единого входа 443.${PLAIN}"
    echo -e "------------------------------------------------"

    local -a files=()
    local conf_file backup_dir moved=0
    for conf_file in /etc/nginx/conf.d/vps_proxy_*.conf /etc/nginx/conf.d/00-vps-proxy-map.conf; do
        [[ -f "$conf_file" ]] && files+=("$conf_file")
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        echo -e "${BLUE}Конфигураций HTTPS прокси Nginx, созданных скриптом, не обнаружено.${PLAIN}"
        return 0
    fi
    printf '  - %s\n' "${files[@]}"
    if ! confirm_danger "Очистка конфигураций HTTPS прокси Nginx" \
        "Указанные конфигурации Nginx HTTPS будут перемещены в карантин, связанные домены перестанут обслуживаться через Nginx." \
        "Восстановите вручную из карантина /etc/vps-optimize/quarantine/nginx-proxy и выполните nginx -t && systemctl reload nginx."; then
        echo -e "${BLUE}Очистка отменена.${PLAIN}"
        return 0
    fi

    backup_dir="/etc/vps-optimize/backups/nginx-proxy-clear_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    for conf_file in "${files[@]}"; do
        cp -p "$conf_file" "$backup_dir/$(basename "$conf_file")" 2>/dev/null || true
        if quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/nginx-proxy" >/dev/null 2>&1; then
            moved=$((moved + 1))
        else
            echo -e "${YELLOW}⚠️ Не удалось изолировать: ${conf_file}${PLAIN}"
        fi
    done
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ Изолировано ${moved} конфигураций HTTPS прокси Nginx.${PLAIN}"
        echo -e "${CYAN}Резервная копия: ${backup_dir}${PLAIN}"
    else
        echo -e "${RED}❌ Проверка Nginx после очистки не удалась, проверьте nginx -t.${PLAIN}"
        nginx -t
        return 1
    fi
}

func_proxy_clear_config() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧹 Очистка конфигураций прокси (Caddy / Nginx)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${GREEN}  1. Очистка Caddy прокси${PLAIN}"
    echo -e "${GREEN}  2. Очистка HTTPS прокси Nginx${PLAIN}"
    echo -e "${RED}  0. Отмена${PLAIN}"
    local choice
    read_trimmed choice "Выберите действие: "
    case "$choice" in
        1) func_caddy_clear_config ;;
        2) func_nginx_clear_proxy_config ;;
        0|q|Q|"") echo -e "${BLUE}Отмена.${PLAIN}" ;;
        *) echo -e "${RED}❌ Неверный выбор.${PLAIN}" ;;
    esac
}

append_editable_proxy_config_file() {
    local label="$1"
    local path="$2"
    local kind="$3"
    [[ -f "$path" ]] || return 0
    proxy_config_labels+=("$label")
    proxy_config_paths+=("$path")
    proxy_config_kinds+=("$kind")
}

collect_editable_proxy_config_files() {
    proxy_config_labels=()
    proxy_config_paths=()
    proxy_config_kinds=()

    append_editable_proxy_config_file "Основной конфиг Caddy" "/etc/caddy/Caddyfile" "caddy"
    local conf_file
    for conf_file in /etc/caddy/conf.d/*.caddy; do
        [[ -f "$conf_file" ]] && append_editable_proxy_config_file "Сайт Caddy $(basename "$conf_file")" "$conf_file" "caddy"
    done
    append_editable_proxy_config_file "Основной конфиг Nginx" "/etc/nginx/nginx.conf" "nginx"
    for conf_file in /etc/nginx/conf.d/*.conf; do
        [[ -f "$conf_file" ]] && append_editable_proxy_config_file "Nginx conf.d $(basename "$conf_file")" "$conf_file" "nginx"
    done
    for conf_file in /etc/nginx/sites-enabled/*; do
        [[ -f "$conf_file" ]] && append_editable_proxy_config_file "Nginx sites-enabled $(basename "$conf_file")" "$conf_file" "nginx"
    done
}

proxy_config_editor_command() {
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

validate_proxy_config_kind() {
    local kind="$1"
    case "$kind" in
        caddy)
            command -v caddy >/dev/null 2>&1 || { echo -e "${RED}❌ caddy не обнаружен, невозможно проверить конфигурацию.${PLAIN}"; return 1; }
            caddy validate --config /etc/caddy/Caddyfile
            ;;
        nginx)
            command -v nginx >/dev/null 2>&1 || { echo -e "${RED}❌ nginx не обнаружен, невозможно проверить конфигурацию.${PLAIN}"; return 1; }
            nginx -t
            ;;
        *)
            echo -e "${RED}❌ Неизвестный тип конфигурации: ${kind}${PLAIN}"
            return 1
            ;;
    esac
}

reload_proxy_config_kind() {
    local kind="$1"
    case "$kind" in
        caddy) systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 ;;
        nginx) systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

func_edit_applied_proxy_config() {
    local -a proxy_config_labels=()
    local -a proxy_config_paths=()
    local -a proxy_config_kinds=()
    collect_editable_proxy_config_files

    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}📝 Просмотр/редактирование применённых конфигураций${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    if [[ ${#proxy_config_paths[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Не обнаружено редактируемых конфигурационных файлов Caddy/Nginx.${PLAIN}"
        return 0
    fi

    local i
    for i in "${!proxy_config_paths[@]}"; do
        printf '%b%3d. %s%b\n' "$GREEN" "$((i + 1))" "${proxy_config_labels[$i]} -> ${proxy_config_paths[$i]}" "$PLAIN"
    done
    echo -e "${RED}  0. Отмена${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local choice idx target_file target_kind backup_file editor confirm rollback_confirm
    read_trimmed choice "Выберите конфигурационный файл для просмотра/редактирования: "
    [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" ]] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#proxy_config_paths[@]} )); then
        echo -e "${RED}❌ Неверный выбор.${PLAIN}"
        return 1
    fi

    idx=$((choice - 1))
    target_file="${proxy_config_paths[$idx]}"
    target_kind="${proxy_config_kinds[$idx]}"
    [[ -f "$target_file" ]] || { echo -e "${RED}❌ Файл не существует: ${target_file}${PLAIN}"; return 1; }

    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    echo -e "${BOLD}Текущий файл: ${target_file}${PLAIN}"
    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    nl -ba "$target_file"
    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    read_trimmed confirm "Открыть редактор для изменения этого файла? (y/n, по умолчанию n): "
    is_yes "$confirm" || return 0

    editor=$(proxy_config_editor_command) || {
        echo -e "${RED}❌ Не найден доступный редактор. Установите nano/vim/vi или установите EDITOR.${PLAIN}"
        return 1
    }
    backup_file="${target_file}.bak_$(date +%s)"
    cp -p "$target_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, редактирование отменено.${PLAIN}"; return 1; }
    echo -e "${CYAN}Резервная копия перед редактированием: ${backup_file}${PLAIN}"

    "$editor" "$target_file" || {
        echo -e "${RED}❌ Редактор завершился с ошибкой, конфигурация не перезагружена.${PLAIN}"
        return 1
    }

    if cmp -s "$target_file" "$backup_file"; then
        echo -e "${BLUE}Конфигурация не изменилась.${PLAIN}"
        return 0
    fi

    echo -e "${CYAN}▶ Проверка конфигурации...${PLAIN}"
    if ! validate_proxy_config_kind "$target_kind"; then
        echo -e "${RED}❌ Проверка не удалась, служба не будет перезагружена.${PLAIN}"
        read_trimmed rollback_confirm "Восстановить резервную копию до редактирования? (Y/n, по умолчанию yes): "
        if ! is_no "$rollback_confirm"; then
            cp -p "$backup_file" "$target_file" && echo -e "${GREEN}✅ Восстановлено: ${target_file}${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Оставлены изменения, не прошедшие проверку, исправьте вручную перед reload.${PLAIN}"
        fi
        return 1
    fi

    if reload_proxy_config_kind "$target_kind"; then
        echo -e "${GREEN}✅ Конфигурация проверена и перезагружена.${PLAIN}"
        echo -e "${CYAN}Резервный файл: ${backup_file}${PLAIN}"
    else
        echo -e "${RED}❌ Проверка конфигурации пройдена, но reload/restart службы не удались.${PLAIN}"
        read_trimmed rollback_confirm "Восстановить резервную копию до редактирования? (Y/n, по умолчанию yes): "
        if ! is_no "$rollback_confirm"; then
            cp -p "$backup_file" "$target_file" && reload_proxy_config_kind "$target_kind" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ Попытка восстановления конфигурации до редактирования выполнена.${PLAIN}"
        fi
        return 1
    fi
}

func_caddy_reverse_proxy_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Обратный прокси"
        echo -e "${BOLD}🌐 Обратный прокси (Caddy / Nginx)${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: управление прокси для доменов, не подключённых к единому входу 443. Для единого входа 443 используйте главное меню [19].${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Добавить Caddy прокси${PLAIN}"
        echo -e "${GREEN}  2. Добавить Nginx HTTPS прокси${PLAIN} ${YELLOW}(использует acme.sh + CF DNS сертификаты)${PLAIN}"
        echo -e "${CYAN}  3. Просмотр сертификатов Caddy/общих путей${PLAIN}"
        echo -e "${CYAN}  4. Пропуск проверки сертификата бэкенда HTTPS${PLAIN} ${YELLOW}(Caddy/Nginx, для самоподписанных бэкендов)${PLAIN}"
        echo -e "${CYAN}  5. IP-белый список доменов${PLAIN} ${YELLOW}(Caddy/Nginx)${PLAIN}"
        echo -e "${CYAN}  6. Просмотр/редактирование применённых конфигураций${PLAIN} ${YELLOW}(Caddy/Nginx, проверка и reload)${PLAIN}"
        echo -e "${RED}  7. Очистка конфигураций прокси${PLAIN} ${YELLOW}(Caddy/Nginx)${PLAIN}"
        echo -e "${RED}  8. Удалить сертификат/конфигурацию домена ACME${PLAIN} ${YELLOW}(также очищает конфигурации Nginx, созданные скриптом)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local caddy_choice
        read_trimmed caddy_choice "👉 Выберите действие: "
        case "$caddy_choice" in
            1) func_caddy_add_reverse_proxy ;;
            2) func_nginx_add_reverse_proxy ;;
            3) func_view_caddy_cert ;;
            4) func_proxy_add_insecure ;;
            5) func_proxy_manage_ip_whitelist ;;
            6) func_edit_applied_proxy_config ;;
            7) func_proxy_clear_config ;;
            8) func_caddy_delete_cert ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
        echo ""
        pause_return "Нажмите любую клавишу для продолжения..."
    done
}

# ---------------------------------------------------------
# Module: environment.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Установка общих сред выполнения и зависимостей.

func_env_install() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Базовые компоненты и службы"
        echo -e "${BOLD}📦 Базовые компоненты и службы${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: установка базовых компонентов, туннелей и служб. Обратный прокси Caddy/Nginx — через главное меню [4], единый вход 443 — через [19].${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Базовая среда выполнения${PLAIN}"
        echo -e "${GREEN}  1. Docker Engine        ${YELLOW}  2. Python окружение   ${GREEN}  3. iperf3 инструмент${PLAIN}"
        echo -e "${BOLD}${BLUE}▶ Туннели, прокси и службы${PLAIN}"
        echo -e "${GREEN}  4. WARP разблокировка   ${YELLOW}  5. Realm проброс портов${GREEN}  6. Gost туннель${PLAIN}"
        echo -e "${GREEN}  7. Forwardx панель      ${YELLOW}  8. Argox узел         ${GREEN}  9. Aurora панель${PLAIN}"
        echo -e "${GREEN} 10. nftables NAT трансляция${YELLOW} 11. Aria2 загрузка    ${GREEN} 12. PVE виртуализация${PLAIN}"
        echo -e "${GREEN} 13. FLVX панель          ${YELLOW} 14. EasyTier сеть     ${GREEN} 15. Tailscale сеть${PLAIN}"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local env_choice
        read_trimmed env_choice "👉 Выберите: "
        
        case $env_choice in
            1) 
                echo -e "${CYAN}▶ Установка Docker Engine...${PLAIN}"
                run_remote_script "Установка Docker Engine" "https://get.docker.com" || echo -e "${RED}❌ Ошибка установки Docker, проверьте сеть!${PLAIN}"
                ;;
            2) run_remote_script "Установка Python окружения" "https://raw.githubusercontent.com/lx969788249/lxspacepy/master/pyinstall.sh" ;;
            3) run_safe "Установка iperf3" install_pkg iperf3 ;;
            4) run_remote_script "Установка WARP разблокировки" "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" ;;
            5) run_remote_script "Установка Realm проброса портов" "https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh" install ;;
            6) run_remote_script "Установка Gost туннеля" "https://raw.githubusercontent.com/qqrrooty/EZgost/main/gost.sh" ;;
            7) run_remote_script "Установка Forwardx панели" "https://raw.githubusercontent.com/poouo/Forwardx/main/scripts/install-panel-local.sh" install ;;
            8) run_remote_script "Установка Argox узла" "https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh" ;;
            9) run_remote_script "Установка Aurora панели" "https://raw.githubusercontent.com/Aurora-Admin-Panel/deploy/main/install.sh" ;;
            10) run_remote_script "Установка nftables NAT трансляции" "https://us.arloor.dev/https://github.com/arloor/nftables-nat-rust/releases/download/v2.0.0/setup.sh" toml ;;
            11) run_remote_script "Установка Aria2 загрузчика" "https://git.io/aria2.sh" ;;
            12) run_remote_script "Установка PVE виртуализации" "https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/build_backend.sh" ;;
            13) run_remote_script "Установка FLVX панели" "https://raw.githubusercontent.com/Sagit-chu/flvx/main/panel_install.sh" ;;
            14) run_remote_script "Установка EasyTier сети" "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh" install ;;
            15)
                if run_remote_script "Установка Tailscale сети" "https://tailscale.com/install.sh"; then
                    echo -e "${GREEN}✅ После установки выполните tailscale up и следуйте инструкциям для входа.${PLAIN}"
                fi
                ;;
            "?"|help) echo "Меню базовых компонентов устанавливает Docker, Python, WARP, туннели и службы. Обратный прокси — через [4], единый вход 443 — через [19]."; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный ввод!${PLAIN}" ;;
        esac
        echo ""
        pause_after_external_script "Нажмите Enter для продолжения..."
    done
}

# ---------------------------------------------------------
# Старый мастер Reality+CF отключён, меню [19] использует новый SNI stack.
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: caddy_legacy.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Заглушка совместимости с отключённым старым мастером Caddy + Reality.

func_caddy_cf_reality_wizard_legacy_disabled() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧩 Мастер автоматизации Reality 443 + Cloudflare DNS${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Этот мастер заставит Caddy слушать только локальный порт, не занимая публичные 80/443.${PLAIN}"
    echo -e "${YELLOW}Рекомендуется для: 3x-ui Reality уже занял 443, но веб-службам нужен HTTPS на том же домене.${PLAIN}"
    echo -e "------------------------------------------------"

    read_trimmed reality_occupied "❓ Порт 443 уже занят VLESS-Reality 3x-ui? (y/n): "
    if is_no "$reality_occupied"; then
        echo -e "${BLUE}ℹ️ Вы выбрали, что 443 не занят, мастер всё равно будет использовать локальный режим во избежание конфликтов.${PLAIN}"
    fi

    local listen_port
    read_trimmed listen_port "👉 Введите локальный TLS-порт Caddy (по умолчанию 8443): "
    listen_port=${listen_port:-8443}
    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [[ "$listen_port" -lt 1 || "$listen_port" -gt 65535 ]]; then
        echo -e "${RED}❌ Неверный порт! Должен быть 1-65535.${PLAIN}"
        return
    fi
    if is_yes "$reality_occupied" && [[ "$listen_port" -eq 443 ]]; then
        echo -e "${RED}❌ 443 уже используется Reality, используйте локальный высокий порт (например 8443/9443).${PLAIN}"
        return
    fi

    local cf_token
    echo -e "${CYAN}👇 Введите Cloudflare API Token (нужны права Zone.DNS.Edit)${PLAIN}"
    read_secret_trimmed cf_token "CF Token: "
    if [[ -z "$cf_token" || ${#cf_token} -lt 20 ]]; then
        echo -e "${RED}❌ Неверная длина Token, отмена.${PLAIN}"
        return
    fi
    echo -e "${CYAN}▶ Онлайн-проверка Cloudflare Token...${PLAIN}"
    verify_cf_token_online "$cf_token"
    local verify_rc=$?
    if [[ "$verify_rc" -eq 0 ]]; then
        echo -e "${GREEN}✅ Проверка Token пройдена.${PLAIN}"
    elif [[ "$verify_rc" -eq 2 ]]; then
        echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку.${PLAIN}"
    else
        echo -e "${RED}❌ Ошибка онлайн-проверки Token: проверьте права или правильность ввода.${PLAIN}"
        echo -e "${YELLOW}Требуются права: Zone.DNS.Edit + Zone.Zone.Read${PLAIN}"
        return
    fi

    if ! install_caddy_if_needed; then
        echo -e "${RED}❌ Не удалось установить Caddy, проверьте сеть.${PLAIN}"
        return
    fi

    local acme_bin="/root/.acme.sh/acme.sh"
    local acme_email
    acme_email=$(get_acme_account_email)
    if [[ ! -x "$acme_bin" ]]; then
        if ! install_acme_sh "$acme_email"; then
            echo -e "${RED}❌ Не удалось установить acme.sh, проверьте сеть.${PLAIN}"
            return
        fi
    fi
    if [[ ! -x "$acme_bin" ]]; then
        echo -e "${RED}❌ acme.sh не найден или неисполняем.${PLAIN}"
        return
    fi
    if ! prepare_acme_account "$acme_bin" "$acme_email"; then
        echo -e "${RED}❌ Не удалось инициализировать аккаунт acme.${PLAIN}"
        return
    fi

    local cf_env_dir="/root/.config/vps-panel"
    local cf_env_file="${cf_env_dir}/cloudflare.env"
    mkdir -p "$cf_env_dir"
    chmod 700 "$cf_env_dir"
    local escaped_token
    escaped_token=${cf_token//\'/\'"\'"\'}
    printf "CF_Token='%s'\n" "$escaped_token" > "$cf_env_file"
    chmod 600 "$cf_env_file"

    mkdir -p /etc/caddy/conf.d /etc/caddy/certs /root/cert

    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        cat <<EOF > /etc/caddy/Caddyfile
# Управляется VPS-Optimize
import conf.d/*
EOF
    elif ! grep -q "import conf.d/\*" /etc/caddy/Caddyfile; then
        echo -e "\nimport conf.d/*" >> /etc/caddy/Caddyfile
    fi

    echo -e "${CYAN}▶ Сканирование и изоляция старых конфигураций Caddy (во избежание захвата 443)...${PLAIN}"
    quarantine_legacy_caddy_443_configs

    echo -e "${YELLOW}👇 Добавление правил обратного прокси для доменов (можно несколько)${PLAIN}"
    echo -e "${YELLOW}Формат: домен -> локальный порт, например panel.example.com -> 8000${PLAIN}"
    echo -e "------------------------------------------------"

    local success_count=0
    local fail_count=0
    local summary_file="/root/cert/caddy_cf_manifest.txt"

    while true; do
        local domain domain_input backend_port continue_add
        read_trimmed domain_input "👉 Введите домен (Enter для завершения): "
        domain=$(normalize_domain_input "$domain_input")
        if [[ -z "$domain" ]]; then
            break
        fi

        if ! is_valid_domain "$domain"; then
            print_domain_validation_error "домен" "$domain_input" "$domain"
            ((fail_count++))
            continue
        fi

        read_trimmed backend_port "👉 Введите локальный порт бэкенда для этого домена: "
        if ! is_valid_port "$backend_port"; then
            echo -e "${RED}❌ Неверный порт: $backend_port${PLAIN}"
            ((fail_count++))
            continue
        fi

        local conf_file="/etc/caddy/conf.d/${domain}.caddy"
        if [[ -f "$conf_file" ]]; then
            echo -e "${RED}❌ Конфигурация для домена уже существует: $conf_file${PLAIN}"
            ((fail_count++))
            continue
        fi

        # shellcheck disable=SC1090
        source "$cf_env_file"
        echo -e "${CYAN}▶ Запрос сертификата DNS для ${domain}...${PLAIN}"
        if ! issue_cf_dns_cert_with_retry "$domain" "$CF_Token" "$acme_bin"; then
            echo -e "${RED}❌ Ошибка запроса сертификата: ${domain}${PLAIN}"
            echo -e "${YELLOW}   Подсказка: используйте главное меню [19] -> [12] -> [14] для автоматического исправления.${PLAIN}"
            ((fail_count++))
            continue
        fi

        local cert_file="/etc/caddy/certs/${domain}.crt"
        local key_file="/etc/caddy/certs/${domain}.key"

        if ! "$acme_bin" --install-cert -d "$domain" --ecc \
            --fullchain-file "$cert_file" \
            --key-file "$key_file" \
            --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true" >/dev/null 2>&1; then
            echo -e "${RED}❌ Ошибка установки сертификата: ${domain}${PLAIN}"
            ((fail_count++))
            continue
        fi

        if id caddy >/dev/null 2>&1; then
            chown root:caddy "$cert_file" "$key_file" >/dev/null 2>&1
            chmod 640 "$cert_file" "$key_file"
        else
            chmod 600 "$cert_file" "$key_file"
        fi

        ln -sfn "$cert_file" "/root/cert/${domain}.crt"
        ln -sfn "$key_file" "/root/cert/${domain}.key"

        cat <<EOF > "$conf_file"
https://${domain}:${listen_port} {
    bind 127.0.0.1
    tls ${cert_file} ${key_file}
    reverse_proxy 127.0.0.1:${backend_port}
}
EOF

        echo -e "${GREEN}✅ Домен ${domain} готов: сертификат выдан + прокси настроен.${PLAIN}"
        ((success_count++))

        read_trimmed continue_add "Продолжить добавление следующего домена? (y/n): "
        if ! is_yes "$continue_add"; then
            break
        fi
    done

    echo -e "${CYAN}▶ Проверка и загрузка конфигурации Caddy...${PLAIN}"
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        systemctl enable caddy >/dev/null 2>&1
        systemctl restart caddy >/dev/null 2>&1
        echo -e "${GREEN}✅ Caddy успешно перезагружен, конфигурация активна.${PLAIN}"
    else
        echo -e "${RED}❌ Проверка конфигурации Caddy не удалась! Проверьте синтаксис новых файлов в /etc/caddy/conf.d/.${PLAIN}"
        echo -e "${YELLOW}Сертификаты сохранены, после исправления конфигурации выполните: systemctl restart caddy${PLAIN}"
    fi

    generate_caddy_cf_manifest

    echo -e "------------------------------------------------"
    echo -e "${GREEN}🎯 Мастер выполнен: успешно ${success_count}, ошибок ${fail_count}.${PLAIN}"
    echo -e "${CYAN}Каталог символических ссылок сертификатов:${PLAIN} /root/cert"
    echo -e "${CYAN}Файл манифеста:${PLAIN} ${summary_file}"
    echo -e "${YELLOW}💡 Ручная настройка 3x-ui:${PLAIN}"
    echo -e "1) В узле Reality установите fallback/dest на: 127.0.0.1:${listen_port}"
    echo -e "2) Каждый fallback SNI должен соответствовать введённому домену для корректного попадания на сертификат и прокси"
    echo -e "3) Если нужен реальный IP посетителя, позже включите PROXY Protocol"
}

# ---------------------------------------------------------
# Новая функция: меню обслуживания сертификатов CF DNS
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: sni_stack_config.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Вспомогательные функции для конфигурации единого входа 443: окружение, маршруты, прослушивание, белые списки.

detect_vps_public_ip_by_family() {
    local family="$1"
    local curl_flag="-4"
    local endpoint ip
    local endpoints=()

    command -v curl >/dev/null 2>&1 || return 1

    if [[ "$family" == "6" ]]; then
        curl_flag="-6"
        endpoints=("https://api6.ipify.org" "https://ipv6.icanhazip.com")
    else
        endpoints=("https://api.ipify.org" "https://ipv4.icanhazip.com")
    fi

    for endpoint in "${endpoints[@]}"; do
        ip=$(curl "$curl_flag" -fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '\r' | awk 'NF {print $1; exit}')
        ip=$(trim_input "$ip")
        if [[ "$family" == "6" ]]; then
            is_valid_ipv6_cidr "$ip" && { echo "$ip"; return 0; }
        else
            is_valid_ipv4_cidr "$ip" && ! is_suspicious_public_ipv4 "$ip" && { echo "$ip"; return 0; }
        fi
    done
    return 1
}

append_vps_public_ips_to_whitelist() {
    local -n out_array=$1
    local ip existing seen added=0
    seen=" "
    for existing in "${out_array[@]}"; do
        seen+=" ${existing} "
    done

    for ip in "$(detect_vps_public_ip_by_family 4 2>/dev/null)" "$(detect_vps_public_ip_by_family 6 2>/dev/null)"; do
        [[ -n "$ip" ]] || continue
        if [[ "$seen" != *" ${ip} "* ]]; then
            out_array+=("$ip")
            seen+=" ${ip} "
            echo -e "${GREEN}✅ Автоматически добавлен публичный IP VPS: ${ip}${PLAIN}"
            added=1
        fi
    done

    if [[ "$added" -eq 0 ]]; then
        echo -e "${YELLOW}⚠️ Не удалось автоматически получить публичный IP VPS; если нужен доступ с самого VPS, добавьте IP вручную.${PLAIN}"
    fi

    append_local_service_ips_to_whitelist "$1" seen
}

append_local_service_ips_to_whitelist() {
    local -n out_array=$1
    local -n seen_ref=$2
    local entry subnet local_added=0
    local -a local_ranges=("127.0.0.1/32" "::1/128")

    if command -v docker >/dev/null 2>&1; then
        while IFS= read -r subnet; do
            subnet=$(trim_input "$subnet")
            [[ -n "$subnet" ]] && local_ranges+=("$subnet")
        done < <(docker network inspect $(docker network ls -q 2>/dev/null) \
            --format '{{range .IPAM.Config}}{{if .Subnet}}{{.Subnet}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | sort -u)
    fi

    for entry in "${local_ranges[@]}"; do
        [[ -n "$entry" ]] || continue
        is_valid_ip_cidr "$entry" || continue
        if [[ "$seen_ref" != *" ${entry} "* ]]; then
            out_array+=("$entry")
            seen_ref+=" ${entry} "
            echo -e "${GREEN}✅ Автоматически добавлен локальный/контейнерный источник: ${entry}${PLAIN}"
            local_added=1
        fi
    done

    if [[ "$local_added" -eq 0 ]]; then
        echo -e "${BLUE}ℹ️ Локальные/контейнерные источники уже в белом списке.${PLAIN}"
    fi
}

join_array_by_space() {
    local IFS=' '
    echo "$*"
}

detect_ssh_client_ip() {
    local client_ip=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        client_ip="${SSH_CONNECTION%% *}"
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        client_ip="${SSH_CLIENT%% *}"
    fi
    echo "$client_ip"
}

caddy_ip_whitelist_block() {
    local ranges="$1"
    [[ -z "$ranges" ]] && return 0
    cat <<EOF
    # vps-optimize-ip-whitelist-start
    @vps_ip_denied not remote_ip ${ranges}
    abort @vps_ip_denied
    # vps-optimize-ip-whitelist-end

EOF
}

normalize_web_proxy_engine() {
    local engine="${1:-caddy}"
    engine=$(echo "$engine" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    case "$engine" in
        ""|"caddy") echo "caddy" ;;
        "nginx"|"nginx-local"|"nginx-http") echo "nginx" ;;
        *) return 1 ;;
    esac
}

current_web_proxy_engine() {
    WEB_PROXY_ENGINE=$(normalize_web_proxy_engine "${WEB_PROXY_ENGINE:-caddy}" 2>/dev/null || echo "caddy")
    echo "$WEB_PROXY_ENGINE"
}

web_proxy_engine_label() {
    case "$(normalize_web_proxy_engine "${1:-${WEB_PROXY_ENGINE:-caddy}}" 2>/dev/null || echo caddy)" in
        nginx) echo "Nginx локальный HTTPS прокси" ;;
        *) echo "Caddy локальный HTTPS прокси" ;;
    esac
}

web_proxy_backend() {
    format_hostport "$CADDY_LISTEN_ADDR" "$CADDY_LISTEN_PORT"
}

web_proxy_engine_supports_web_whitelist() {
    local mode="${1:-${ENTRY_MODE:-$(get_entry_mode)}}"
    mode=$(normalize_entry_mode_name "$mode" 2>/dev/null || echo "nginx-stream")

    # Xray fallback переподключается к локальному Web-прокси, поэтому Caddy remote_ip
    # и Nginx allow/deny не могут надёжно определить исходный адрес клиента.
    [[ "$mode" == "xray-fallback" ]] && return 1
    return 0
}

assert_web_proxy_whitelist_supported() {
    local mode="${1:-${ENTRY_MODE:-$(get_entry_mode)}}"
    local engine="${2:-${WEB_PROXY_ENGINE:-caddy}}"
    if [[ ${#SNI_IP_WHITELIST_DOMAINS[@]} -eq 0 ]]; then
        return 0
    fi
    if web_proxy_engine_supports_web_whitelist "$mode" "$engine"; then
        return 0
    fi
    echo -e "${RED}❌ Режим xray-fallback не поддерживает веб-белые списки.${PLAIN}"
    echo -e "${YELLOW}Причина: после fallback Xray на локальный Web-прокси, Caddy/Nginx не могут надёжно получить реальный IP клиента.${PLAIN}"
    echo -e "${YELLOW}Используйте режимы Nginx Stream/TCP Peek, или очистите веб-белый список перед использованием этой комбинации.${PLAIN}"
    return 1
}

xui_setting_default_value() {
    local key="$1"
    case "$key" in
        webListen|subListen|webDomain|subDomain|webCertFile|webKeyFile|subCertFile|subKeyFile|subURI|subClashURI) echo "" ;;
        webPort) echo "2053" ;;
        webBasePath) echo "/" ;;
        subPort) echo "2096" ;;
        subPath) echo "/sub/" ;;
        subClashPath) echo "/clash/" ;;
        *) echo "" ;;
    esac
}

xui_backend_addr_from_listen() {
    local listen_addr
    listen_addr="$(trim_input "$1")"
    case "$listen_addr" in
        ""|"0.0.0.0"|"::") echo "127.0.0.1" ;;
        "localhost") echo "127.0.0.1" ;;
        *) echo "$listen_addr" ;;
    esac
}

detect_xui_command() {
    if [[ -x /usr/local/x-ui/x-ui ]]; then
        echo "/usr/local/x-ui/x-ui"
    elif command -v x-ui >/dev/null 2>&1; then
        command -v x-ui
    elif command -v 3x-ui >/dev/null 2>&1; then
        command -v 3x-ui
    fi
}

xui_cli_show_value() {
    local key="$1"
    local xui_bin info cli_key
    xui_bin=$(detect_xui_command) || return 1
    info=$("$xui_bin" setting -show true 2>/dev/null || true)
    [[ -n "$info" ]] || return 1
    case "$key" in
        webPort) cli_key="port" ;;
        webBasePath) cli_key="webBasePath" ;;
        *) cli_key="$key" ;;
    esac
    printf '%s\n' "$info" | awk -F': ' -v k="$cli_key" '$1 == k {print $2; exit}'
}

xui_db_setting_value() {
    local key="$1"
    local db_path value
    command -v sqlite3 >/dev/null 2>&1 || return 1
    while IFS= read -r db_path; do
        [[ -n "$db_path" && -f "$db_path" ]] || continue
        value=$(sqlite3 "$db_path" "select value from settings where lower(key)=lower('${key}') limit 1;" 2>/dev/null || true)
        if [[ -z "$value" ]]; then
            value=$(sqlite3 "$db_path" "select value from setting where lower(key)=lower('${key}') limit 1;" 2>/dev/null || true)
        fi
        value="$(trim_input "$value")"
        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done < <(find_xui_database_candidates)
    return 1
}

xui_detect_setting_value() {
    local key="$1"
    local default_value="${2:-$(xui_setting_default_value "$key")}"
    local value
    value="$(xui_cli_show_value "$key" 2>/dev/null || true)"
    value="$(trim_input "$value")"
    if [[ -z "$value" ]]; then
        value="$(xui_db_setting_value "$key" 2>/dev/null || true)"
        value="$(trim_input "$value")"
    fi
    printf '%s' "${value:-$default_value}"
}

detect_xui_single_443_defaults() {
    XUI_DETECTED_BIN="$(detect_xui_command 2>/dev/null || true)"
    XUI_DETECTED_DB="$(find_xui_database_candidates | head -n1)"
    XUI_DETECTED_WEB_LISTEN="$(xui_detect_setting_value webListen)"
    XUI_DETECTED_WEB_PORT="$(xui_detect_setting_value webPort 2053)"
    XUI_DETECTED_WEB_BASE_PATH="$(normalize_path_prefix "$(xui_detect_setting_value webBasePath /)")"
    XUI_DETECTED_SUB_LISTEN="$(xui_detect_setting_value subListen)"
    XUI_DETECTED_SUB_PORT="$(xui_detect_setting_value subPort 2096)"
    XUI_DETECTED_SUB_PATH="$(normalize_path_prefix "$(xui_detect_setting_value subPath /sub/)")"
    XUI_DETECTED_SUB_CLASH_PATH="$(normalize_path_prefix "$(xui_detect_setting_value subClashPath /clash/)")"
    XUI_DETECTED_PANEL_ADDR="$(xui_backend_addr_from_listen "$XUI_DETECTED_WEB_LISTEN")"
    XUI_DETECTED_SUB_ADDR="$(xui_backend_addr_from_listen "$XUI_DETECTED_SUB_LISTEN")"
}

print_xui_single_443_detected_defaults() {
    if [[ -z "${XUI_DETECTED_BIN:-}" && -z "${XUI_DETECTED_DB:-}" ]]; then
        echo -e "${YELLOW}⚠️ 3x-ui команда или база данных не обнаружены, будут использованы значения по умолчанию для мастера 443.${PLAIN}"
        return 0
    fi
    echo -e "${CYAN}▶ Обнаружены текущие настройки 3x-ui, они будут использованы как значения по умолчанию (Enter для подтверждения):${PLAIN}"
    [[ -n "${XUI_DETECTED_BIN:-}" ]] && echo -e "  Команда: ${XUI_DETECTED_BIN}"
    [[ -n "${XUI_DETECTED_DB:-}" ]] && echo -e "  База данных: ${XUI_DETECTED_DB}"
    echo -e "  Бэкенд панели: ${XUI_DETECTED_PANEL_ADDR}:${XUI_DETECTED_WEB_PORT}${XUI_DETECTED_WEB_BASE_PATH}"
    echo -e "  Бэкенд подписки: ${XUI_DETECTED_SUB_ADDR}:${XUI_DETECTED_SUB_PORT}${XUI_DETECTED_SUB_PATH}"
    echo -e "  Путь Clash/Mihomo: ${XUI_DETECTED_SUB_CLASH_PATH}"
}

clear_xui_cert_settings_for_single_443() {
    local xui_bin cert_cmd_done=false db_found=false cert_key_sql db_path service_name
    xui_bin=$(detect_xui_command 2>/dev/null || true)

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${CYAN}▶ Установка sqlite3 для очистки путей сертификатов в базе 3x-ui...${PLAIN}"
        install_pkg sqlite3 sqlite >/dev/null 2>&1 || true
    fi

    for service_name in x-ui 3x-ui x-panel; do
        systemctl stop "$service_name" >/dev/null 2>&1 || true
    done

    if [[ -n "$xui_bin" ]]; then
        if "$xui_bin" cert -webCert "" -webCertKey "" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Пути сертификатов панели очищены через официальную команду 3x-ui cert.${PLAIN}"
            cert_cmd_done=true
        else
            echo -e "${YELLOW}⚠️ Официальная команда cert не сработала, будет попытка очистки базы данных.${PLAIN}"
        fi
    fi

    if command -v sqlite3 >/dev/null 2>&1; then
        cert_key_sql=$(xui_cert_setting_key_sql_list)
        while IFS= read -r db_path; do
            [[ -f "$db_path" ]] || continue
            if sqlite3 "$db_path" "update settings set value='' where lower(key) in (${cert_key_sql});" 2>/dev/null || \
               sqlite3 "$db_path" "update setting set value='' where lower(key) in (${cert_key_sql});" 2>/dev/null; then
                echo -e "${GREEN}✅ Очищены поля сертификатов: ${db_path}${PLAIN}"
                db_found=true
            fi
        done < <(find_xui_database_candidates)
    fi

    for service_name in x-ui 3x-ui x-panel; do
        if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q . || systemctl status "$service_name" >/dev/null 2>&1; then
            systemctl restart "$service_name" >/dev/null 2>&1 || systemctl start "$service_name" >/dev/null 2>&1 || true
        fi
    done

    if ! $cert_cmd_done && ! $db_found; then
        echo -e "${YELLOW}⚠️ Не найдены автоматически очищаемые настройки сертификатов 3x-ui, очистите пути вручную в панели и перезапустите.${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}✅ Попытка очистки путей сертификатов 3x-ui выполнена, сертификаты для единого входа 443 будет обслуживать Web-прокси.${PLAIN}"
}

find_xui_database_candidates() {
    local db_path extra_db
    local seen_dbs=" "
    local db_candidates=(
        "/etc/x-ui/x-ui.db"
        "/usr/local/x-ui/x-ui.db"
        "/usr/local/x-ui/bin/x-ui.db"
        "/etc/x-panel/x-panel.db"
    )

    for db_path in "${db_candidates[@]}"; do
        [[ -f "$db_path" ]] || continue
        [[ "$seen_dbs" == *" ${db_path} "* ]] && continue
        seen_dbs+=" ${db_path} "
        echo "$db_path"
    done

    while IFS= read -r extra_db; do
        [[ -f "$extra_db" ]] || continue
        [[ "$seen_dbs" == *" ${extra_db} "* ]] && continue
        seen_dbs+=" ${extra_db} "
        echo "$extra_db"
    done < <(find /etc /usr/local/x-ui /opt -maxdepth 4 -type f \( -name "x-ui.db" -o -name "x-panel.db" \) 2>/dev/null | sort -u)
}

check_xui_cert_settings_for_single_443() {
    local cert_key_sql db_path rows key value
    local checked=0 found=0

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ sqlite3 не обнаружен, проверка путей сертификатов 3x-ui пропущена.${PLAIN}"
        return 2
    fi

    cert_key_sql=$(xui_cert_setting_key_sql_list)
    while IFS= read -r db_path; do
        [[ -n "$db_path" ]] || continue
        checked=1
        rows=$(sqlite3 -separator '|' "$db_path" "select key,value from settings where lower(key) in (${cert_key_sql}) and length(trim(coalesce(value,''))) > 0;" 2>/dev/null || true)
        [[ -n "$rows" ]] || continue

        found=1
        echo -e "${YELLOW}⚠️ ${db_path} содержит пути сертификатов панели/подписки 3x-ui. Для 3.x новых установок выбирайте Skip SSL; для 2.x/старых конфигураций при едином входе 443 рекомендуется очистить:${PLAIN}"
        while IFS='|' read -r key value; do
            [[ -n "$key" ]] || continue
            echo -e "  ${key}=${value}"
        done <<< "$rows"
    done < <(find_xui_database_candidates)

    if [[ "$checked" -eq 0 ]]; then
        echo -e "${YELLOW}⚠️ База данных 3x-ui не найдена, проверка путей сертификатов пропущена.${PLAIN}"
        return 2
    fi

    if [[ "$found" -eq 1 ]]; then
        echo -e "${YELLOW}Рекомендация: для 3.x новых установок в установщике выберите Skip SSL / не запрашивать SSL; для 2.x/старых конфигураций используйте [5 Панели, узлы и подписки] -> [3 Восстановление SSL панели] или очистите пути сертификатов в панели 3x-ui и перезапустите.${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}✅ Пути сертификатов 3x-ui не содержат остатков.${PLAIN}"
    return 0
}

cleanup_old_nginx_sni_stream_configs() {
    mkdir -p /etc/nginx/stream.d
    local old_dir="/etc/nginx/stream.d/backup_vps_sni_$(date +%Y%m%d_%H%M%S)"
    local moved=0
    while IFS= read -r conf_file; do
        mkdir -p "$old_dir"
        mv "$conf_file" "$old_dir/" >/dev/null 2>&1 && ((moved++))
    done < <(find /etc/nginx/stream.d -maxdepth 1 -type f -name 'vps_sni_*.conf' 2>/dev/null | sort)
    if [[ "$moved" -gt 0 ]]; then
        echo -e "${YELLOW}⚠️ Изолированы ${moved} старых конфигураций Nginx SNI в: ${old_dir}${PLAIN}"
    fi
}

probe_reality_sni() {
    local sni="$1"
    echo -e "${CYAN}▶ Проверка доступности REALITY SNI: ${sni}:443${PLAIN}"
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ openssl не обнаружен, проверка SNI пропущена.${PLAIN}"
        return 0
    fi
    if timeout 12 openssl s_client -connect "${sni}:443" -servername "$sni" </dev/null 2>/tmp/vps_reality_sni_probe.log | grep -q "BEGIN CERTIFICATE"; then
        echo -e "${GREEN}✅ REALITY SNI доступен и возвращает сертификат.${PLAIN}"
        return 0
    fi
    echo -e "${RED}❌ Ошибка проверки REALITY SNI: ${sni}:443 не вернул сертификат.${PLAIN}"
    echo -e "${YELLOW}Используйте другой реальный HTTPS-домен, не шаблонный и не свой панельный домен.${PLAIN}"
    return 1
}

print_sni_stack_preview() {
    local entry_mode entry_label web_engine web_label web_backend
    entry_mode="${ENTRY_MODE:-nginx-stream}"
    entry_mode=$(normalize_entry_mode_name "$entry_mode" 2>/dev/null || echo "nginx-stream")
    web_engine=$(current_web_proxy_engine)
    web_label=$(web_proxy_engine_label "$web_engine")
    web_backend=$(web_proxy_backend)
    case "$entry_mode" in
        "nginx-stream") entry_label="Режим Nginx Stream" ;;
        "xray-fallback") entry_label="Режим Xray Fallback" ;;
        "tcp-peek") entry_label="Режим TCP Peek + Splice / разделитель vpso-mux" ;;
        *) entry_label="$entry_mode" ;;
    esac

    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Предпросмотр конфигурации единого входа 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "Режим ENTRY_MODE: ${entry_mode}"
    echo -e "Web-движок WEB_PROXY_ENGINE: ${web_engine} (${web_label})"
    echo -e "Публичный вход: ${NGINX_LISTEN_ADDR}:${NGINX_LISTEN_PORT} -> ${entry_label}"
    echo -e "Домен панели: ${PANEL_DOMAIN} -> ${web_backend} -> http://${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "Путь панели: https://${PANEL_DOMAIN}${PANEL_WEB_PATH:-/panel/}"
    echo -e "Путь обычной подписки: https://${PANEL_DOMAIN}${SUB_URI_PATH:-/sub/} -> http://${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT}"
    echo -e "Путь Clash/Mihomo: https://${PANEL_DOMAIN}${CLASH_URI_PATH:-/clash/} -> http://${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT}"
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local i
        for i in "${!SITE_DOMAINS[@]}"; do
            echo -e "Веб-сайт/прокси домен: ${SITE_DOMAINS[$i]} -> ${web_backend} -> ${SITE_BACKEND_ADDRS[$i]}:${SITE_BACKEND_PORTS[$i]}"
        done
    fi
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            echo -e "TCP/SNI входящий: ${TCP_ROUTE_SNIS[$tcp_i]} -> ${TCP_ROUTE_ADDRS[$tcp_i]}:${TCP_ROUTE_PORTS[$tcp_i]}"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            echo -e "Xray входящий маршрут: ${XRAY_SNI_ROUTE_SNIS[$xray_route_i]} -> ${XRAY_SNI_ROUTE_ADDRS[$xray_route_i]}:${XRAY_SNI_ROUTE_PORTS[$xray_route_i]}"
        done
    fi
    if [[ ${#SNI_IP_WHITELIST_DOMAINS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}IP-белые списки доменов:${PLAIN}"
        local wl_i
        for wl_i in "${!SNI_IP_WHITELIST_DOMAINS[@]}"; do
            echo -e "  ${SNI_IP_WHITELIST_DOMAINS[$wl_i]} только ${SNI_IP_WHITELIST_RANGES[$wl_i]}"
        done
    fi
    if [[ "$entry_mode" == "xray-fallback" ]]; then
        echo -e "Xray основной входящий: публичный ${NGINX_LISTEN_PORT} принимается Xray, обычный HTTPS fallback на ${web_backend}"
        echo -e "Примечание: скрипт не создаёт и не изменяет внутреннюю конфигурацию входящих 3x-ui/Xray."
    else
        echo -e "REALITY SNI: ${REALITY_SNI} -> ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
        echo -e "Стандартный/неизвестный SNI -> ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
    fi
    echo -e ""
    echo -e "${YELLOW}После подтверждения будет создана резервная копия текущей конфигурации и сгенерирован вход в соответствии с выбранным ENTRY_MODE.${PLAIN}"
    confirm_risk_action "Запись общей конфигурации единого входа 443" \
        "${entry_label}, ${web_label} конфигурация и правила маршрутизации 443" \
        "Восстановите из автоматически созданной резервной копии или используйте откат в меню обслуживания 443" \
        "Убедитесь, что публичный порт 443 не занят другими службами."
}

caddy_format_configs() {
    command -v caddy >/dev/null 2>&1 || return 0
    caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1 || true
    if [[ -d /etc/caddy/conf.d ]]; then
        while IFS= read -r conf_file; do
            caddy fmt --overwrite "$conf_file" >/dev/null 2>&1 || true
        done < <(find /etc/caddy/conf.d -maxdepth 1 -type f -name "*.caddy" 2>/dev/null | sort)
    fi
}

sni_stack_env_path() {
    echo "/etc/vps-optimize/sni-stack.env"
}

canonical_legacy_entry_mode_name() {
    case "$1" in
        "nginx_stream") echo "nginx-stream" ;;
        "xray_fallback") echo "xray-fallback" ;;
        "tcp_peek") echo "tcp-peek" ;;
        *) return 1 ;;
    esac
}

rewrite_legacy_entry_mode_assignment() {
    local file="$1"
    local key="$2"
    local legacy_value="$3"
    local canonical_value assignment_count

    canonical_value=$(canonical_legacy_entry_mode_name "$legacy_value" 2>/dev/null) || return 1
    [[ -f "$file" && -w "$file" ]] || return 1

    assignment_count=$(grep -Ec "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null || true)
    [[ "$assignment_count" == "1" ]] || return 1
    grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*('${legacy_value}'|\"${legacy_value}\"|${legacy_value})[[:space:]]*$" "$file" 2>/dev/null || return 1

    sed -i -E \
        -e "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)'${legacy_value}'[[:space:]]*$|\\1'${canonical_value}'|" \
        -e "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)\"${legacy_value}\"[[:space:]]*$|\\1\"${canonical_value}\"|" \
        -e "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)${legacy_value}[[:space:]]*$|\\1${canonical_value}|" \
        "$file"
}

get_entry_mode() {
    local env_file mode=""
    env_file=$(sni_stack_env_path)

    if [[ ! -f "$env_file" ]]; then
        echo "not-configured"
        return 0
    fi

    mode=$(
        # shellcheck disable=SC1090
        unset ENTRY_MODE
        source "$env_file" 2>/dev/null || true
        printf '%s' "${ENTRY_MODE:-}"
    )

    case "$mode" in
        ""|"nginx-stream"|"nginx_stream")
            rewrite_legacy_entry_mode_assignment "$env_file" "ENTRY_MODE" "$mode" 2>/dev/null || true
            echo "nginx-stream"
            ;;
        "xray-fallback"|"xray_fallback")
            rewrite_legacy_entry_mode_assignment "$env_file" "ENTRY_MODE" "$mode" 2>/dev/null || true
            echo "xray-fallback"
            ;;
        "tcp-peek"|"tcp_peek")
            rewrite_legacy_entry_mode_assignment "$env_file" "ENTRY_MODE" "$mode" 2>/dev/null || true
            echo "tcp-peek"
            ;;
        *)
            echo "invalid:${mode}"
            ;;
    esac
}

print_entry_mode_compat_notice() {
    local env_file
    local state_file env_mode state_engine normalized
    env_file=$(sni_stack_env_path)
    state_file=$(single_443_engine_state_path 2>/dev/null || echo "/etc/vps-optimize/443-engine.conf")

    if [[ -f "$env_file" ]]; then
        env_mode=$(
            # shellcheck disable=SC1090
            unset ENTRY_MODE
            source "$env_file" 2>/dev/null || true
            printf '%s' "${ENTRY_MODE:-}"
        )
        if [[ -z "$env_mode" ]]; then
            echo -e "${YELLOW}Совместимость: ${env_file} не содержит ENTRY_MODE, сейчас читается как nginx-stream; при сохранении будет записано ENTRY_MODE='nginx-stream'.${PLAIN}"
        else
            case "$env_mode" in
                "nginx_stream"|"xray_fallback"|"tcp_peek")
                    normalized=$(normalize_entry_mode_name "$env_mode" 2>/dev/null || echo "nginx-stream")
                    if ! rewrite_legacy_entry_mode_assignment "$env_file" "ENTRY_MODE" "$env_mode" 2>/dev/null; then
                        echo -e "${YELLOW}Совместимость: обнаружен старый ENTRY_MODE='${env_mode}', сейчас читается как '${normalized}'; при сохранении будет новое имя.${PLAIN}"
                    fi
                    ;;
            esac
        fi
    fi

    if [[ -f "$state_file" ]]; then
        state_engine=$(
            # shellcheck disable=SC1090
            unset engine
            source "$state_file" 2>/dev/null || true
            printf '%s' "${engine:-}"
        )
        case "$state_engine" in
            "nginx_stream"|"xray_fallback"|"tcp_peek")
                normalized=$(normalize_entry_mode_name "$state_engine" 2>/dev/null || echo "nginx-stream")
                if ! rewrite_legacy_entry_mode_assignment "$state_file" "engine" "$state_engine" 2>/dev/null; then
                    echo -e "${YELLOW}Совместимость: обнаружен старый engine='${state_engine}', сейчас читается как '${normalized}'; при переключении/повторном применении будет новое имя.${PLAIN}"
                fi
                ;;
        esac
    fi
}

set_entry_mode() {
    local mode="$1"
    local env_file
    env_file=$(sni_stack_env_path)

    case "$mode" in
        "nginx_stream") mode="nginx-stream" ;;
        "xray_fallback") mode="xray-fallback" ;;
        "tcp_peek") mode="tcp-peek" ;;
    esac

    case "$mode" in
        "nginx-stream"|"xray-fallback"|"tcp-peek") ;;
        *)
            echo -e "${RED}Неверный ENTRY_MODE: ${mode}${PLAIN}"
            return 1
            ;;
    esac

    mkdir -p "$(dirname "$env_file")"
    if [[ -f "$env_file" ]] && grep -q '^ENTRY_MODE=' "$env_file" 2>/dev/null; then
        sed -i "s|^ENTRY_MODE=.*|ENTRY_MODE='${mode}'|" "$env_file"
    else
        printf "ENTRY_MODE='%s'\n" "$mode" >> "$env_file"
    fi
    chmod 600 "$env_file" 2>/dev/null || true
}

listen_process_from_ss_line() {
    local line="$1"
    local proc
    proc=$(printf '%s\n' "$line" | awk -F'"' '/users:/ {print $2; exit}')
    printf '%s' "${proc:-unknown}"
}

normalize_entry_listener_process() {
    local proc="$1"
    case "$proc" in
        nginx*) echo "nginx" ;;
        xray*|x-ui*|3x-ui*) echo "xray" ;;
        vpso-mux*|tcppeek*|tcp-peek*) echo "tcppeek" ;;
        caddy*) echo "caddy" ;;
        unknown|"") echo "unknown" ;;
        *) echo "unknown:${proc}" ;;
    esac
}

entry_listener_display_name() {
    local listener="$1"
    case "$listener" in
        nginx) echo "Nginx Stream (nginx)" ;;
        xray) echo "Xray Fallback (xray/3x-ui/x-ui)" ;;
        tcppeek) echo "Режим TCP Peek + Splice (разделитель vpso-mux)" ;;
        caddy) echo "Caddy (не должен напрямую занимать порт 443)" ;;
        none) echo "Не слушает" ;;
        multiple) echo "Несколько процессов слушают/совпадают" ;;
        unknown) echo "Слушает, но процесс не виден" ;;
        unknown:*) echo "Неизвестный процесс ${listener#unknown:}" ;;
        *) echo "$listener" ;;
    esac
}

entry_mode_expected_listener() {
    local mode="$1"
    mode=$(normalize_entry_mode_name "$mode" 2>/dev/null || echo "$mode")
    case "$mode" in
        "nginx-stream") echo "nginx" ;;
        "xray-fallback") echo "xray" ;;
        "tcp-peek") echo "tcppeek" ;;
        *) echo "" ;;
    esac
}

listen_line_status() {
    local addr="$1"
    local port="$2"
    local line="$3"
    local proc

    if [[ "$addr" == "not-configured" || "$port" == "not-configured" ]]; then
        echo "Не настроен"
        return 0
    fi
    if [[ -z "$line" || "$line" == "Не слушает" || "$line" == "not-configured" ]]; then
        echo "Не слушает"
        return 0
    fi

    proc=$(listen_process_from_ss_line "$line")
    if [[ "$proc" == "unknown" ]]; then
        echo "Слушает (процесс не виден)"
    else
        echo "Слушает (${proc})"
    fi
}

detect_443_listener() {
    local port="${1:-${NGINX_LISTEN_PORT:-443}}"
    local lines line proc normalized seen procs
    lines=$(ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true)

    if [[ -z "$lines" ]]; then
        echo "none|none"
        return 0
    fi

    seen=" "
    procs=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        proc=$(listen_process_from_ss_line "$line")
        normalized=$(normalize_entry_listener_process "$proc")
        if [[ "$seen" != *" ${normalized} "* ]]; then
            seen+="${normalized} "
            if [[ -z "$procs" ]]; then
                procs="$normalized"
            else
                procs="${procs},${normalized}"
            fi
        fi
    done <<< "$lines"

    if [[ "$procs" == *,* ]]; then
        echo "multiple|${procs}"
    else
        echo "${procs}|${procs}"
    fi
}

listener_info_has_entry() {
    local listener_info="$1"
    local expected="$2"
    local primary labels
    primary="${listener_info%%|*}"
    labels="${listener_info#*|}"
    [[ "$primary" == "$expected" || ",${labels}," == *",${expected},"* ]]
}

detect_current_entry_status() {
    local env_file
    local listener_info expected_listener xui_svc xui_status
    env_file=$(sni_stack_env_path)

    ENTRY_STATUS_MODE=$(get_entry_mode)
    ENTRY_STATUS_CADDY_ADDR="not-configured"
    ENTRY_STATUS_CADDY_PORT="not-configured"
    ENTRY_STATUS_XRAY_ADDR="not-configured"
    ENTRY_STATUS_XRAY_PORT="not-configured"

    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        source "$env_file" 2>/dev/null || true
        ENTRY_STATUS_CADDY_ADDR="${CADDY_LISTEN_ADDR:-not-configured}"
        ENTRY_STATUS_CADDY_PORT="${CADDY_LISTEN_PORT:-not-configured}"
        ENTRY_STATUS_XRAY_ADDR="${XRAY_LISTEN_ADDR:-not-configured}"
        ENTRY_STATUS_XRAY_PORT="${XRAY_LISTEN_PORT:-not-configured}"
    fi

    listener_info=$(detect_443_listener)
    ENTRY_STATUS_LISTENER="${listener_info%%|*}"
    ENTRY_STATUS_LISTENER_PROCESS="${listener_info#*|}"
    ENTRY_STATUS_LISTENER_DISPLAY=$(entry_listener_display_name "$ENTRY_STATUS_LISTENER")
    ENTRY_STATUS_NGINX_SERVICE=$(service_status_compact nginx)
    if listener_info_has_entry "$listener_info" "nginx"; then
        ENTRY_STATUS_NGINX_ROLE="слушает публичный ${NGINX_LISTEN_PORT:-443}"
    else
        ENTRY_STATUS_NGINX_ROLE="не слушает публичный ${NGINX_LISTEN_PORT:-443}; работа службы только означает, что 80/другие сайты или правило сброса по умолчанию доступны"
    fi
    xui_status=$(xui_panel_status_compact)
    if xui_svc=$(xui_panel_service_name 2>/dev/null); then
        xui_status="${xui_svc}.service ${xui_status}"
    fi
    ENTRY_STATUS_XRAY_SERVICE="Панель управляет Xray: ${xui_status} / независимый xray.service: $(service_status_compact xray)"
    ENTRY_STATUS_TCPPEEK_SERVICE=$(service_status_compact vpso-mux)
    ENTRY_STATUS_CADDY_LISTEN_LINE="not-configured"
    ENTRY_STATUS_XRAY_LISTEN_LINE="not-configured"

    if is_valid_port "$ENTRY_STATUS_CADDY_PORT"; then
        ENTRY_STATUS_CADDY_LISTEN_LINE=$(get_listen_line_by_port "$ENTRY_STATUS_CADDY_PORT")
    fi
    if is_valid_port "$ENTRY_STATUS_XRAY_PORT"; then
        ENTRY_STATUS_XRAY_LISTEN_LINE=$(get_listen_line_by_port "$ENTRY_STATUS_XRAY_PORT")
    fi

    expected_listener=$(entry_mode_expected_listener "$ENTRY_STATUS_MODE")

    if [[ -n "$expected_listener" ]] && listener_info_has_entry "$listener_info" "$expected_listener"; then
        ENTRY_STATUS_CONSISTENT="yes"
    else
        ENTRY_STATUS_CONSISTENT="no"
    fi
}

show_current_entry_status() {
    detect_current_entry_status
    local web_engine web_label
    web_engine=$(normalize_web_proxy_engine "${WEB_PROXY_ENGINE:-caddy}" 2>/dev/null || echo "caddy")
    web_label=$(web_proxy_engine_label "$web_engine")
    echo -e "${BOLD}Текущее состояние единого входа 443${PLAIN}"
    echo -e "Режим конфигурации: ${CYAN}${ENTRY_STATUS_MODE}${PLAIN}"
    echo -e "Web-прокси: ${web_label} (${web_engine})"
    print_entry_mode_compat_notice
    echo -e "Публичный 443: ${ENTRY_STATUS_LISTENER_DISPLAY}"
    echo -e "Процесс слушателя: ${ENTRY_STATUS_LISTENER_PROCESS}"
    if [[ "$ENTRY_STATUS_LISTENER" == "xray" ]]; then
        echo -e "Публичный Xray: ${GREEN}публичный 443 сейчас слушается Xray/панельным Xray${PLAIN}"
    else
        echo -e "Публичный Xray: Xray, слушающий публичный 443, не обнаружен"
    fi
    if [[ "$ENTRY_STATUS_CONSISTENT" == "yes" ]]; then
        echo -e "Согласованность: ${GREEN}режим конфигурации и фактический слушатель совпадают${PLAIN}"
    else
        echo -e "Согласованность: ${YELLOW}режим конфигурации и фактический слушатель не совпадают${PLAIN}"
        echo -e "${YELLOW}Несовпадение, рекомендуется повторно применить текущий режим входа.${PLAIN}"
    fi
    echo -e "------------------------------------------------"
    echo -e "${BOLD}Локальные слушатели${PLAIN}"
    echo -e "Web-прокси: ${ENTRY_STATUS_CADDY_ADDR}:${ENTRY_STATUS_CADDY_PORT} - $(listen_line_status "$ENTRY_STATUS_CADDY_ADDR" "$ENTRY_STATUS_CADDY_PORT" "$ENTRY_STATUS_CADDY_LISTEN_LINE")"
    echo -e "Xray: ${ENTRY_STATUS_XRAY_ADDR}:${ENTRY_STATUS_XRAY_PORT} - $(listen_line_status "$ENTRY_STATUS_XRAY_ADDR" "$ENTRY_STATUS_XRAY_PORT" "$ENTRY_STATUS_XRAY_LISTEN_LINE")"
    echo -e "------------------------------------------------"
    echo -e "${BOLD}Состояние служб${PLAIN}"
    echo -e "nginx: ${ENTRY_STATUS_NGINX_SERVICE} (${ENTRY_STATUS_NGINX_ROLE})"
    echo -e "TCP Peek + Splice / разделитель vpso-mux: ${ENTRY_STATUS_TCPPEEK_SERVICE}"
    echo -e "Xray/3x-ui/x-ui: ${ENTRY_STATUS_XRAY_SERVICE}"
}

show_current_entry_summary() {
    detect_current_entry_status
    echo -e "${BOLD}Текущий режим входа: ${CYAN}${ENTRY_STATUS_MODE}${PLAIN}"
    print_entry_mode_compat_notice
    if [[ "$ENTRY_STATUS_CONSISTENT" != "yes" ]]; then
        echo -e "${YELLOW}⚠️ Режим конфигурации и фактическое прослушивание 443 не совпадают, проверьте через [1] и повторно примените текущий режим.${PLAIN}"
    fi
}

load_sni_stack_env() {
    local env_file
    env_file=$(sni_stack_env_path)
    if [[ ! -f "$env_file" ]]; then
        echo -e "${RED}❌ ${env_file} не найден, сначала выполните главное меню [19] -> [2] первичную настройку единого входа 443.${PLAIN}"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$env_file"
    ENTRY_MODE=$(get_entry_mode)
    WEB_PROXY_ENGINE=$(normalize_web_proxy_engine "${WEB_PROXY_ENGINE:-caddy}" 2>/dev/null || echo "caddy")
    PANEL_WEB_PATH=$(normalize_path_prefix "${PANEL_WEB_PATH:-/panel/}")
    SUB_URI_PATH=$(normalize_path_prefix "${SUB_URI_PATH:-/sub/}")
    CLASH_URI_PATH=$(normalize_path_prefix "${CLASH_URI_PATH:-/clash/}")
    normalize_site_stack_arrays
    normalize_tcp_route_arrays
    load_xray_sni_route_arrays
    normalize_sni_ip_whitelist_arrays
}

get_listen_line_by_port() {
    local port="$1"
    local line
    line=$(ss -lntp 2>/dev/null | grep ":${port}[[:space:]]" | head -n1 || true)
    echo "${line:-Не слушает}"
}

print_sni_stack_current_summary() {
    local env_file="/etc/vps-optimize/sni-stack.env"
    local caddy_conf="/etc/caddy/conf.d/${PANEL_DOMAIN}.caddy"
    local nginx_web_conf="/etc/nginx/conf.d/vps_sni_web_${CADDY_LISTEN_PORT}.conf"
    local nginx_conf="/etc/nginx/stream.d/vps_sni_${NGINX_LISTEN_PORT}.conf"
    local web_engine web_label web_backend
    web_engine=$(current_web_proxy_engine)
    web_label=$(web_proxy_engine_label "$web_engine")
    web_backend=$(web_proxy_backend)

    echo -e "${BOLD}Текущая сохранённая конфигурация маршрутизации 443${PLAIN} ${CYAN}(${env_file})${PLAIN}"
    echo -e "Панель: https://${PANEL_DOMAIN}${PANEL_WEB_PATH} -> ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "Обычная подписка: https://${PANEL_DOMAIN}${SUB_URI_PATH} -> ${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT}"
    echo -e "Подписка Clash: https://${PANEL_DOMAIN}${CLASH_URI_PATH} -> ${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT}"
    echo -e "REALITY: ${REALITY_SNI} -> ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            echo -e "TCP/SNI: ${TCP_ROUTE_SNIS[$tcp_i]} -> ${TCP_ROUTE_ADDRS[$tcp_i]}:${TCP_ROUTE_PORTS[$tcp_i]}"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            echo -e "Xray входящий: ${XRAY_SNI_ROUTE_SNIS[$xray_route_i]} -> ${XRAY_SNI_ROUTE_ADDRS[$xray_route_i]}:${XRAY_SNI_ROUTE_PORTS[$xray_route_i]}"
        done
    fi
    echo -e "Web-прокси: ${web_label} (${web_backend})"
    echo -e "Публичный вход: ${NGINX_LISTEN_ADDR}:${NGINX_LISTEN_PORT} -> ${web_label} ${web_backend}"
    echo -e "Файлы конфигурации: Nginx ${nginx_conf}"
    if [[ "$web_engine" == "nginx" ]]; then
        echo -e "           Nginx Web ${nginx_web_conf}"
    else
        echo -e "           Caddy ${caddy_conf}"
    fi
    print_sni_ip_whitelist_summary
    echo -e "------------------------------------------------"
    echo -e "${BOLD}Текущее состояние фактического прослушивания${PLAIN}"
    echo -e "Nginx вход: $(get_listen_line_by_port "$NGINX_LISTEN_PORT")"
    echo -e "${web_label}: $(get_listen_line_by_port "$CADDY_LISTEN_PORT")"
    echo -e "Бэкенд панели: $(get_listen_line_by_port "$PANEL_LISTEN_PORT")"
    echo -e "Бэкенд подписки: $(get_listen_line_by_port "$SUB_LISTEN_PORT")"
    echo -e "Бэкенд REALITY: $(get_listen_line_by_port "$XRAY_LISTEN_PORT")"
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            echo -e "Бэкенд TCP/SNI ${TCP_ROUTE_SNIS[$tcp_i]}: $(get_listen_line_by_port "${TCP_ROUTE_PORTS[$tcp_i]}")"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            echo -e "Бэкенд Xray входящего ${XRAY_SNI_ROUTE_SNIS[$xray_route_i]}: $(get_listen_line_by_port "${XRAY_SNI_ROUTE_PORTS[$xray_route_i]}")"
        done
    fi
}

normalize_site_stack_arrays() {
    SITE_DOMAINS=()
    SITE_BACKEND_ADDRS=()
    SITE_BACKEND_PORTS=()

    if [[ -n "${SITE_DOMAINS_CSV:-}" ]]; then
        split_csv_to_array "$SITE_DOMAINS_CSV" SITE_DOMAINS
        split_csv_to_array "${SITE_BACKEND_ADDRS_CSV:-}" SITE_BACKEND_ADDRS
        split_csv_to_array "${SITE_BACKEND_PORTS_CSV:-}" SITE_BACKEND_PORTS
    elif [[ -n "${SITE_DOMAIN:-}" ]]; then
        SITE_DOMAINS=("$SITE_DOMAIN")
        SITE_BACKEND_ADDRS=("${SITE_BACKEND_ADDR:-127.0.0.1}")
        SITE_BACKEND_PORTS=("${SITE_BACKEND_PORT:-3000}")
    fi

    local i default_port
    default_port=3000
    for i in "${!SITE_DOMAINS[@]}"; do
        SITE_DOMAINS[$i]=$(normalize_domain_input "${SITE_DOMAINS[$i]}")
        SITE_BACKEND_ADDRS[$i]="${SITE_BACKEND_ADDRS[$i]:-127.0.0.1}"
        if [[ -z "${SITE_BACKEND_PORTS[$i]:-}" ]]; then
            if [[ "$i" -eq 0 && -n "${SITE_BACKEND_PORT:-}" ]]; then
                SITE_BACKEND_PORTS[$i]="$SITE_BACKEND_PORT"
            else
                SITE_BACKEND_PORTS[$i]="$default_port"
            fi
        fi
        SITE_BACKEND_ADDRS[$i]=$(normalize_backend_addr_input "${SITE_BACKEND_ADDRS[$i]}")
        SITE_BACKEND_PORTS[$i]=$(normalize_port_input "${SITE_BACKEND_PORTS[$i]}")
        default_port=$((default_port + 1))
    done

    SITE_DOMAIN="${SITE_DOMAINS[0]:-}"
    SITE_BACKEND_ADDR="${SITE_BACKEND_ADDRS[0]:-127.0.0.1}"
    SITE_BACKEND_PORT="${SITE_BACKEND_PORTS[0]:-3000}"
}

normalize_tcp_route_arrays() {
    local -a raw_snis=()
    local -a raw_addrs=()
    local -a raw_ports=()
    local -a clean_snis=()
    local -a clean_addrs=()
    local -a clean_ports=()
    local i sni addr port

    if [[ -n "${TCP_ROUTE_SNIS_CSV:-}" ]]; then
        split_csv_to_array "$TCP_ROUTE_SNIS_CSV" raw_snis
        split_csv_to_array "${TCP_ROUTE_ADDRS_CSV:-}" raw_addrs
        split_csv_to_array "${TCP_ROUTE_PORTS_CSV:-}" raw_ports
    fi

    for i in "${!raw_snis[@]}"; do
        sni=$(normalize_domain_input "${raw_snis[$i]}")
        addr=$(normalize_loopback_addr "$(normalize_ip_input "${raw_addrs[$i]:-127.0.0.1}")")
        port=$(normalize_port_input "${raw_ports[$i]:-8443}")
        if is_valid_domain "$sni" && is_loopback_listen_addr "$addr" && is_valid_port "$port"; then
            clean_snis+=("$sni")
            clean_addrs+=("$addr")
            clean_ports+=("$port")
        fi
    done

    TCP_ROUTE_SNIS=("${clean_snis[@]}")
    TCP_ROUTE_ADDRS=("${clean_addrs[@]}")
    TCP_ROUTE_PORTS=("${clean_ports[@]}")
}

xray_sni_routes_path() {
    echo "/etc/vps-optimize/xray-sni-routes.conf"
}

load_xray_sni_route_arrays() {
    local route_file line sni addr port
    route_file=$(xray_sni_routes_path)
    XRAY_SNI_ROUTE_SNIS=()
    XRAY_SNI_ROUTE_ADDRS=()
    XRAY_SNI_ROUTE_PORTS=()

    [[ -f "$route_file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ -n "$(trim_input "$line")" ]] || continue
        IFS='|' read -r sni addr port _ <<< "$line"
        sni=$(normalize_domain_input "$sni")
        addr=$(normalize_loopback_addr "${addr:-127.0.0.1}")
        port="$(trim_input "${port:-}")"
        if is_valid_domain "$sni" && is_loopback_listen_addr "$addr" && is_valid_port "$port"; then
            XRAY_SNI_ROUTE_SNIS+=("$sni")
            XRAY_SNI_ROUTE_ADDRS+=("$addr")
            XRAY_SNI_ROUTE_PORTS+=("$port")
        fi
    done < "$route_file"
}

save_xray_sni_route_arrays() {
    local route_file i
    route_file=$(xray_sni_routes_path)
    mkdir -p "$(dirname "$route_file")"
    : > "$route_file"
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ -n "${XRAY_SNI_ROUTE_SNIS[$i]:-}" ]] || continue
        printf '%s|%s|%s\n' "${XRAY_SNI_ROUTE_SNIS[$i]}" "${XRAY_SNI_ROUTE_ADDRS[$i]}" "${XRAY_SNI_ROUTE_PORTS[$i]}" >> "$route_file"
    done
    chmod 600 "$route_file" 2>/dev/null || true
}

xray_sni_route_index() {
    local sni="$1"
    local i
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ "$sni" == "${XRAY_SNI_ROUTE_SNIS[$i]}" ]] && { echo "$i"; return 0; }
    done
    return 1
}

xray_fallback_main_route_index() {
    local i
    if [[ -n "${XRAY_FALLBACK_MAIN_SNI:-}" ]]; then
        for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            [[ "$XRAY_FALLBACK_MAIN_SNI" == "${XRAY_SNI_ROUTE_SNIS[$i]}" ]] && { echo "$i"; return 0; }
        done
    fi
    if [[ -n "${XRAY_FALLBACK_MAIN_ADDR:-}" && -n "${XRAY_FALLBACK_MAIN_PORT:-}" ]]; then
        for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            if [[ "$XRAY_FALLBACK_MAIN_ADDR" == "${XRAY_SNI_ROUTE_ADDRS[$i]}" && "$XRAY_FALLBACK_MAIN_PORT" == "${XRAY_SNI_ROUTE_PORTS[$i]}" ]]; then
                echo "$i"
                return 0
            fi
        done
    fi
    if [[ "$(get_entry_mode)" == "xray-fallback" && -n "${XRAY_LISTEN_ADDR:-}" && -n "${XRAY_LISTEN_PORT:-}" ]]; then
        for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            if [[ "$XRAY_LISTEN_ADDR" == "${XRAY_SNI_ROUTE_ADDRS[$i]}" && "$XRAY_LISTEN_PORT" == "${XRAY_SNI_ROUTE_PORTS[$i]}" ]]; then
                echo "$i"
                return 0
            fi
        done
    fi
    return 1
}

set_xray_fallback_main_route_from_index() {
    local idx="$1"
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    (( idx >= 0 && idx < ${#XRAY_SNI_ROUTE_SNIS[@]} )) || return 1
    XRAY_FALLBACK_MAIN_SNI="${XRAY_SNI_ROUTE_SNIS[$idx]}"
    XRAY_FALLBACK_MAIN_ADDR="${XRAY_SNI_ROUTE_ADDRS[$idx]}"
    XRAY_FALLBACK_MAIN_PORT="${XRAY_SNI_ROUTE_PORTS[$idx]}"
}

print_xray_fallback_mode_explanation() {
    echo -e "${YELLOW}Xray может иметь несколько входящих. Но в режиме xray-fallback публичный 443 по умолчанию принимается одним основным входящим Xray. Скрипт в этом режиме не поддерживает маршрутизацию по нескольким SNI на несколько локальных Xray-входящих.${PLAIN}"
    echo -e "${YELLOW}Этот режим только обеспечивает, чтобы основной входящий Xray слушал публичный 443 и делал fallback обычного HTTPS на выбранный Web-прокси.${PLAIN}"
    echo -e "${YELLOW}Если нужна маршрутизация по SNI на несколько локальных Xray-входящих через 443, используйте режимы Nginx Stream или TCP Peek + Splice.${PLAIN}"
    echo -e "${YELLOW}Если веб-домен использует CDN/WAF/защиту источника/ограничения Cloudflare/веб-белые списки, код 403 или отказ в доступе — это обычно блокировка на уровне Web/CDN/белого списка/SNI, а не ошибка сертификата или прокси.${PLAIN}"
}

print_xray_fallback_main_route_summary() {
    local idx
    idx=$(xray_fallback_main_route_index 2>/dev/null || true)
    if [[ -n "$idx" ]]; then
        echo -e "${GREEN}Текущий основной входящий xray-fallback: ${XRAY_SNI_ROUTE_SNIS[$idx]} -> ${XRAY_SNI_ROUTE_ADDRS[$idx]}:${XRAY_SNI_ROUTE_PORTS[$idx]}${PLAIN}"
    elif [[ -n "${XRAY_FALLBACK_MAIN_SNI:-}" ]]; then
        echo -e "${YELLOW}Запись основного входящего xray-fallback: ${XRAY_FALLBACK_MAIN_SNI} -> ${XRAY_FALLBACK_MAIN_ADDR:-?}:${XRAY_FALLBACK_MAIN_PORT:-?}, но не совпадает с существующими правилами.${PLAIN}"
    elif [[ "$(get_entry_mode)" == "xray-fallback" ]]; then
        echo -e "${YELLOW}Основной входящий xray-fallback не записан; убедитесь, что основной входящий Xray слушает публичный 443 в соответствии с текущим режимом.${PLAIN}"
    fi
}

select_xray_fallback_main_route_for_switch() {
    load_sni_stack_env || return 1
    local count choice idx
    count=${#XRAY_SNI_ROUTE_SNIS[@]}

    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}Не найдены правила маршрутизации Xray-входящих в $(xray_sni_routes_path).${PLAIN}"
        echo -e "${YELLOW}При переключении на xray-fallback публичный 443 будет приниматься основным входящим Xray, настроенным пользователем; скрипт не изменяет внутреннюю конфигурацию входящих 3x-ui/Xray.${PLAIN}"
        confirm_risk_action "Продолжить переключение на xray-fallback" \
            "Публичный 443 будет приниматься основным входящим Xray, обычный HTTPS fallback на выбранный Web-прокси" \
            "Отменить переключение, сначала записать основной входящий кандидат в управлении Xray-входящими" \
            "Убедитесь, что вы уже подготовили основной входящий в 3x-ui/Xray." || return 1
        XRAY_FALLBACK_MAIN_SNI=""
        XRAY_FALLBACK_MAIN_ADDR=""
        XRAY_FALLBACK_MAIN_PORT=""
        return 0
    fi

    print_xray_fallback_mode_explanation
    echo -e "------------------------------------------------"
    if [[ "$count" -eq 1 ]]; then
        echo -e "${CYAN}Обнаружено 1 правило маршрутизации Xray-входящего, может использоваться как кандидат основного входящего xray-fallback:${PLAIN}"
        echo -e "1. ${XRAY_SNI_ROUTE_SNIS[0]} -> ${XRAY_SNI_ROUTE_ADDRS[0]}:${XRAY_SNI_ROUTE_PORTS[0]}"
        confirm_risk_action "Использовать это правило как кандидат основного входящего xray-fallback" \
            "Это правило будет записано как основной входящий xray-fallback; в других режимах оно будет работать как обычная маршрутизация" \
            "Отменить переключение, сначала проверьте конфигурацию основного входящего 3x-ui/Xray" \
            "Убедитесь, что этот локальный входящий — тот, который должен принимать публичный 443 в режиме xray-fallback." || return 1
        set_xray_fallback_main_route_from_index 0
        return 0
    fi

    echo -e "${CYAN}Обнаружено несколько правил маршрутизации Xray-входящих, выберите одно как основной входящий xray-fallback:${PLAIN}"
    for idx in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        echo -e "${GREEN}$((idx + 1)).${PLAIN} ${XRAY_SNI_ROUTE_SNIS[$idx]} -> ${XRAY_SNI_ROUTE_ADDRS[$idx]}:${XRAY_SNI_ROUTE_PORTS[$idx]}"
    done
    echo -e "${RED}0. Отменить переключение${PLAIN}"
    read_trimmed choice "Выберите кандидат основного входящего xray-fallback: "
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo -e "${BLUE}Переключение на xray-fallback отменено.${PLAIN}"
        return 1
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then
        echo -e "${RED}❌ Неверный номер, переключение отменено.${PLAIN}"
        return 1
    fi
    set_xray_fallback_main_route_from_index "$((choice - 1))" || return 1
    echo -e "${GREEN}✅ Выбран кандидат основного входящего xray-fallback: ${XRAY_FALLBACK_MAIN_SNI} -> ${XRAY_FALLBACK_MAIN_ADDR}:${XRAY_FALLBACK_MAIN_PORT}${PLAIN}"
}

xray_sni_route_port_conflict() {
    local addr="$1"
    local port="$2"
    local skip_idx="${3:-}"
    local i
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ -n "$skip_idx" && "$i" == "$skip_idx" ]] && continue
        if [[ "$addr" == "${XRAY_SNI_ROUTE_ADDRS[$i]}" && "$port" == "${XRAY_SNI_ROUTE_PORTS[$i]}" ]]; then
            echo "${XRAY_SNI_ROUTE_SNIS[$i]}"
            return 0
        fi
    done
    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        if [[ "$addr" == "${TCP_ROUTE_ADDRS[$i]}" && "$port" == "${TCP_ROUTE_PORTS[$i]}" ]]; then
            echo "старый TCP/SNI:${TCP_ROUTE_SNIS[$i]}"
            return 0
        fi
    done
    return 1
}

xray_route_listen_line_by_addr_port() {
    local addr="$1"
    local port="$2"
    local host_regex
    case "$addr" in
        "127.0.0.1") host_regex='(127\.0\.0\.1|0\.0\.0\.0|\*)' ;;
        "::1") host_regex='(\[::1\]|\[::\]|\*)' ;;
        "localhost") host_regex='(127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\[::\]|\*)' ;;
        *) host_regex=$(printf '%s' "$addr" | sed 's/[.[\*^$()+?{}|\\]/\\&/g') ;;
    esac
    ss -lntp 2>/dev/null | grep -E "${host_regex}:${port}[[:space:]]" | head -n1 || true
}

print_xray_route_port_status() {
    local sni="$1"
    local addr="$2"
    local port="$3"
    local line conflict

    echo -e "${CYAN}${sni}${PLAIN} -> ${addr}:${port}"
    if [[ "${CADDY_LISTEN_PORT:-}" == "$port" ]]; then
        echo -e "${RED}  ❌ Конфликт с локальным портом Web-прокси ${CADDY_LISTEN_PORT}, выберите другой порт.${PLAIN}"
    fi

    conflict=$(xray_sni_route_port_conflict "$addr" "$port" "$(xray_sni_route_index "$sni" 2>/dev/null || true)" || true)
    [[ -n "$conflict" ]] && echo -e "${YELLOW}  ⚠️ Конфликт с правилом ${conflict}, использующим тот же ${addr}:${port}, проверьте, не намеренно ли это.${PLAIN}"

    line=$(xray_route_listen_line_by_addr_port "$addr" "$port")
    if [[ -n "$line" ]]; then
        echo -e "${GREEN}  ✅ Порт слушается: ${line}${PLAIN}"
        if echo "$line" | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):'"${port}"'[[:space:]]'; then
            echo -e "${YELLOW}  ⚠️ Обнаружено прослушивание на 0.0.0.0/[::], есть риск публичного доступа, рекомендуется изменить на 127.0.0.1.${PLAIN}"
        fi
    else
        echo -e "${YELLOW}  ⚠️ ${addr}:${port} не слушается, сначала создайте и включите соответствующий входящий в 3x-ui.${PLAIN}"
    fi
}

is_sni_stack_managed_domain() {
    local domain="$1"
    local site_domain
    [[ "$domain" == "$PANEL_DOMAIN" ]] && return 0
    for site_domain in "${SITE_DOMAINS[@]}"; do
        [[ "$domain" == "$site_domain" ]] && return 0
    done
    for site_domain in "${TCP_ROUTE_SNIS[@]}"; do
        [[ "$domain" == "$site_domain" ]] && return 0
    done
    for site_domain in "${XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ "$domain" == "$site_domain" ]] && return 0
    done
    return 1
}

is_sni_stack_web_domain() {
    local domain="$1"
    local site_domain
    [[ "$domain" == "$PANEL_DOMAIN" ]] && return 0
    for site_domain in "${SITE_DOMAINS[@]}"; do
        [[ "$domain" == "$site_domain" ]] && return 0
    done
    return 1
}

nginx_var_suffix_for_domain() {
    local domain="$1"
    domain=$(echo "$domain" | tr '.-' '__' | tr -cd 'a-zA-Z0-9_')
    printf '%s' "$domain"
}

normalize_sni_ip_whitelist_arrays() {
    local domains_input="${SNI_IP_WHITELIST_DOMAINS_CSV:-}"
    local ranges_input="${SNI_IP_WHITELIST_RANGES_PIPE:-}"
    local -a raw_domains=()
    local -a raw_ranges=()
    local -a clean_domains=()
    local -a clean_ranges=()
    local -a range_array=()
    local i domain ranges

    SNI_IP_WHITELIST_DOMAINS=()
    SNI_IP_WHITELIST_RANGES=()

    [[ -n "$domains_input" ]] && split_csv_to_array "$domains_input" raw_domains
    [[ -n "$ranges_input" ]] && split_pipe_to_array "$ranges_input" raw_ranges

    for i in "${!raw_domains[@]}"; do
        domain=$(normalize_domain_input "${raw_domains[$i]}")
        ranges="${raw_ranges[$i]:-}"
        [[ -n "$domain" && -n "$ranges" ]] || continue
        is_valid_domain "$domain" || continue
        is_sni_stack_web_domain "$domain" || continue
        if normalize_ip_whitelist_input "$ranges" range_array; then
            clean_domains+=("$domain")
            clean_ranges+=("$(join_array_by_space "${range_array[@]}")")
        fi
    done

    SNI_IP_WHITELIST_DOMAINS=("${clean_domains[@]}")
    SNI_IP_WHITELIST_RANGES=("${clean_ranges[@]}")
}

sni_ip_whitelist_index() {
    local domain="$1"
    local i
    for i in "${!SNI_IP_WHITELIST_DOMAINS[@]}"; do
        [[ "$domain" == "${SNI_IP_WHITELIST_DOMAINS[$i]}" ]] && { echo "$i"; return 0; }
    done
    return 1
}

sni_ip_whitelist_ranges_for_domain() {
    local domain="$1"
    local idx
    idx=$(sni_ip_whitelist_index "$domain" 2>/dev/null) || return 0
    echo "${SNI_IP_WHITELIST_RANGES[$idx]:-}"
}

set_sni_ip_whitelist_for_domain() {
    local domain="$1"
    local ranges="$2"
    local idx
    idx=$(sni_ip_whitelist_index "$domain" 2>/dev/null) || idx=""
    if [[ -n "$idx" ]]; then
        SNI_IP_WHITELIST_RANGES[$idx]="$ranges"
    else
        SNI_IP_WHITELIST_DOMAINS+=("$domain")
        SNI_IP_WHITELIST_RANGES+=("$ranges")
    fi
}

remove_sni_ip_whitelist_for_domain() {
    local domain="$1"
    local i
    local -a new_domains=()
    local -a new_ranges=()
    for i in "${!SNI_IP_WHITELIST_DOMAINS[@]}"; do
        [[ "$domain" == "${SNI_IP_WHITELIST_DOMAINS[$i]}" ]] && continue
        new_domains+=("${SNI_IP_WHITELIST_DOMAINS[$i]}")
        new_ranges+=("${SNI_IP_WHITELIST_RANGES[$i]}")
    done
    SNI_IP_WHITELIST_DOMAINS=("${new_domains[@]}")
    SNI_IP_WHITELIST_RANGES=("${new_ranges[@]}")
}

rename_sni_ip_whitelist_domain() {
    local old_domain="$1"
    local new_domain="$2"
    local idx
    idx=$(sni_ip_whitelist_index "$old_domain" 2>/dev/null) || return 0
    SNI_IP_WHITELIST_DOMAINS[$idx]="$new_domain"
}

print_sni_ip_whitelist_summary() {
    if [[ ${#SNI_IP_WHITELIST_DOMAINS[@]} -eq 0 ]]; then
        echo -e "IP-белый список: не включён"
        return 0
    fi

    local i
    echo -e "IP-белый список:"
    for i in "${!SNI_IP_WHITELIST_DOMAINS[@]}"; do
        echo -e "  - ${SNI_IP_WHITELIST_DOMAINS[$i]} разрешено: ${SNI_IP_WHITELIST_RANGES[$i]}"
    done
}

sni_stack_health_check() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧪 Проверка цепочки единого входа 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1

    local current_mode
    current_mode=$(get_entry_mode)
    if [[ "$current_mode" != "nginx-stream" ]]; then
        sni_stack_health_check_enhanced
        return $?
    fi

    local ok=0 warn=0 fail=0
    check_listen() {
        local name="$1"
        local port="$2"
        local expect_addr="$3"
        if ss -lntp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
            local line
            line=$(ss -lntp 2>/dev/null | grep ":${port}[[:space:]]" | head -n1)
            echo -e "${GREEN}✅ ${name} порт ${port} слушается: ${line}${PLAIN}"
            if [[ -n "$expect_addr" ]] && ! echo "$line" | grep -q "$expect_addr"; then
                echo -e "${YELLOW}⚠️ ${name} ожидается слушать ${expect_addr}:${port}, проверьте, не изменён ли адрес на публичный.${PLAIN}"
                ((warn++))
            else
                ((ok++))
            fi
        else
            echo -e "${RED}❌ ${name} порт ${port} не слушается.${PLAIN}"
            ((fail++))
        fi
    }
    check_backend() {
        local name="$1"
        local addr="$2"
        local port="$3"
        local probe_rc

        if probe_backend_target "$name" "$addr" "$port"; then
            ((ok++))
            return 0
        fi
        probe_rc=$?
        if [[ "$probe_rc" -eq 2 ]]; then
            ((warn++))
        else
            ((fail++))
        fi
    }

    check_listen "Nginx публичный вход" "$NGINX_LISTEN_PORT" ""
    check_listen "$(web_proxy_engine_label) локальный TLS" "$CADDY_LISTEN_PORT" "$CADDY_LISTEN_ADDR"
    check_listen "Xray/3x-ui REALITY" "$XRAY_LISTEN_PORT" "$XRAY_LISTEN_ADDR"
    check_listen "Панель 3x-ui" "$PANEL_LISTEN_PORT" "$PANEL_LISTEN_ADDR"
    check_listen "Подписка 3x-ui" "$SUB_LISTEN_PORT" "$SUB_LISTEN_ADDR"
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local i
        for i in "${!SITE_DOMAINS[@]}"; do
            check_backend "Бэкенд сайта ${SITE_DOMAINS[$i]}" "${SITE_BACKEND_ADDRS[$i]}" "${SITE_BACKEND_PORTS[$i]}"
        done
    fi
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            check_listen "TCP/SNI входящий ${TCP_ROUTE_SNIS[$tcp_i]}" "${TCP_ROUTE_PORTS[$tcp_i]}" "${TCP_ROUTE_ADDRS[$tcp_i]}"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            check_listen "Xray входящий ${XRAY_SNI_ROUTE_SNIS[$xray_route_i]}" "${XRAY_SNI_ROUTE_PORTS[$xray_route_i]}" "${XRAY_SNI_ROUTE_ADDRS[$xray_route_i]}"
        done
    fi

    echo -e "------------------------------------------------"
    if check_xui_cert_settings_for_single_443; then
        ((ok++))
    else
        ((warn++))
    fi

    echo -e "------------------------------------------------"
    if check_domain_dns_sanity "$PANEL_DOMAIN" "Домен панели" "warn"; then
        ((ok++))
    else
        ((warn++))
    fi
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local dns_site
        for dns_site in "${SITE_DOMAINS[@]}"; do
            [[ -z "$dns_site" ]] && continue
            if check_domain_dns_sanity "$dns_site" "Домен сайта/прокси" "warn"; then
                ((ok++))
            else
                ((warn++))
            fi
        done
    fi
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_sni
        for tcp_sni in "${TCP_ROUTE_SNIS[@]}"; do
            [[ -z "$tcp_sni" ]] && continue
            if check_domain_dns_sanity "$tcp_sni" "Домен TCP/SNI входящего" "warn"; then
                ((ok++))
            else
                echo -e "${YELLOW}⚠️ Если клиент подключается по IP и вручную указывает SNI, это предупреждение можно игнорировать.${PLAIN}"
                ((warn++))
            fi
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_sni
        for xray_route_sni in "${XRAY_SNI_ROUTE_SNIS[@]}"; do
            [[ -z "$xray_route_sni" ]] && continue
            if check_domain_dns_sanity "$xray_route_sni" "Домен Xray входящего" "warn"; then
                ((ok++))
            else
                echo -e "${YELLOW}⚠️ Если клиент подключается по IP и вручную указывает SNI, это предупреждение можно игнорировать.${PLAIN}"
                ((warn++))
            fi
        done
    fi

    echo -e "------------------------------------------------"
    nginx -t >/dev/null 2>&1 && echo -e "${GREEN}✅ nginx -t пройден${PLAIN}" && ((ok++)) || { echo -e "${RED}❌ nginx -t не пройден${PLAIN}"; ((fail++)); }
    if [[ "$(current_web_proxy_engine)" == "caddy" ]]; then
        caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && echo -e "${GREEN}✅ Проверка конфигурации Caddy пройдена${PLAIN}" && ((ok++)) || { echo -e "${RED}❌ Проверка конфигурации Caddy не пройдена${PLAIN}"; ((fail++)); }
    fi
    if grep -Eq '^[[:space:]]*server_tokens[[:space:]]+off;' /etc/nginx/nginx.conf 2>/dev/null; then
        echo -e "${GREEN}✅ Nginx отключил отображение версии server_tokens off${PLAIN}"
        ((ok++))
    else
        echo -e "${YELLOW}⚠️ Nginx server_tokens off не подтверждён, на страницах ошибок может отображаться версия.${PLAIN}"
        ((warn++))
    fi
    if [[ -f /etc/nginx/conf.d/00-vps-default-drop.conf ]]; then
        echo -e "${GREEN}✅ Nginx стандартный сайт на 80 настроен на сброс соединения${PLAIN}"
        ((ok++))
    else
        echo -e "${YELLOW}⚠️ Не найден конфиг сброса на 80, неверные домены могут попадать на стандартную страницу.${PLAIN}"
        ((warn++))
    fi

    if command -v openssl >/dev/null 2>&1; then
        if timeout 10 openssl s_client -connect "127.0.0.1:${NGINX_LISTEN_PORT}" -servername "$PANEL_DOMAIN" </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
            echo -e "${GREEN}✅ SNI панели проходит через вход и достигает цепочки сертификатов Web-прокси${PLAIN}"
            ((ok++))
        else
            echo -e "${YELLOW}⚠️ Проверка SNI панели не получила сертификат, проверьте режим входа и Web-прокси.${PLAIN}"
            ((warn++))
        fi
    fi

    echo -e "------------------------------------------------"
    echo -e "Результат проверки: ${GREEN}OK ${ok}${PLAIN} / ${YELLOW}Предупреждения ${warn}${PLAIN} / ${RED}Ошибки ${fail}${PLAIN}"
}

# ---------------------------------------------------------
# Module: vpso_mux_state.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Пути vpso-mux, состояние движка, сводки маршрутов и вывод статуса выполнения.

vpso_mux_config_path() {
    echo "/etc/vps-optimize/vpso-mux.yaml"
}

vpso_mux_service_name() {
    echo "vpso-mux.service"
}

vpso_mux_status_json_path() {
    echo "/var/lib/vps-optimize/vpso-mux/status.json"
}

single_443_engine_state_path() {
    echo "/etc/vps-optimize/443-engine.conf"
}

yaml_quote() {
    local value="$1"
    value=$(printf '%s' "$value" | sed "s/'/''/g")
    printf "'%s'" "$value"
}

single_443_current_engine() {
    local state_file raw_engine env_mode normalized
    state_file=$(single_443_engine_state_path)
    if [[ -f "$state_file" ]]; then
        raw_engine=$(
            # shellcheck disable=SC1090
            unset engine
            source "$state_file" 2>/dev/null || true
            printf '%s' "${engine:-}"
        )
        if [[ -n "$raw_engine" ]]; then
            normalized=$(normalize_entry_mode_name "$raw_engine" 2>/dev/null || true)
            if [[ -n "$normalized" ]]; then
                if declare -F rewrite_legacy_entry_mode_assignment >/dev/null 2>&1; then
                    rewrite_legacy_entry_mode_assignment "$state_file" "engine" "$raw_engine" 2>/dev/null || true
                fi
                printf '%s' "$normalized"
            else
                printf 'invalid:%s' "$raw_engine"
            fi
            return 0
        fi
    fi
    env_mode=$(get_entry_mode)
    case "$env_mode" in
        "nginx-stream"|"xray-fallback"|"tcp-peek") printf '%s' "$env_mode" ;;
        *) printf 'nginx-stream' ;;
    esac
}

sni_stack_route_name() {
    local prefix="$1"
    local sni="$2"
    sni=$(echo "$sni" | tr '.-' '__' | tr -cd 'a-zA-Z0-9_')
    printf '%s_%s' "$prefix" "$sni"
}

sni_stack_route_summary_for_state() {
    local web_backend xray_backend summary i domain
    web_backend=$(web_proxy_backend)
    xray_backend=$(format_hostport "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT")
    summary="panel:${PANEL_DOMAIN}->${web_backend},reality:${REALITY_SNI}->${xray_backend},default->${xray_backend}"
    for i in "${!SITE_DOMAINS[@]}"; do
        domain="${SITE_DOMAINS[$i]}"
        [[ -n "$domain" ]] && summary+=",site:${domain}->${web_backend}"
    done
    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        domain="${TCP_ROUTE_SNIS[$i]}"
        [[ -n "$domain" ]] && summary+=",tcp:${domain}->$(format_hostport "${TCP_ROUTE_ADDRS[$i]}" "${TCP_ROUTE_PORTS[$i]}")"
    done
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        domain="${XRAY_SNI_ROUTE_SNIS[$i]}"
        [[ -n "$domain" ]] && summary+=",xray:${domain}->$(format_hostport "${XRAY_SNI_ROUTE_ADDRS[$i]}" "${XRAY_SNI_ROUTE_PORTS[$i]}")"
    done
    printf '%s' "$summary"
}

sni_stack_whitelist_summary_for_state() {
    local summary="" i
    for i in "${!SNI_IP_WHITELIST_DOMAINS[@]}"; do
        [[ -n "${SNI_IP_WHITELIST_DOMAINS[$i]}" && -n "${SNI_IP_WHITELIST_RANGES[$i]}" ]] || continue
        [[ -n "$summary" ]] && summary+="|"
        summary+="${SNI_IP_WHITELIST_DOMAINS[$i]}:${SNI_IP_WHITELIST_RANGES[$i]}"
    done
    printf '%s' "$summary"
}

write_single_443_engine_state() {
    local selected_engine="$1"
    local selected_engine_raw="$1"
    local backup_id="${2:-}"
    local state_file mux_config mux_service web_backend xray_backend routes whitelist_rules web_engine
    selected_engine=$(normalize_entry_mode_name "$selected_engine_raw") || { echo -e "${RED}Неверный движок: ${selected_engine_raw}${PLAIN}"; return 1; }
    state_file=$(single_443_engine_state_path)
    mux_config=$(vpso_mux_config_path)
    mux_service=$(vpso_mux_service_name)
    web_engine=$(current_web_proxy_engine)
    web_backend=$(web_proxy_backend)
    xray_backend=$(format_hostport "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT")
    routes=$(sni_stack_route_summary_for_state)
    whitelist_rules=$(sni_stack_whitelist_summary_for_state)
    [[ -z "$backup_id" ]] && backup_id=$(cat /etc/vps-optimize/sni-stack.last-backup 2>/dev/null || true)

    mkdir -p /etc/vps-optimize
    cat <<EOF > "$state_file"
engine='${selected_engine}'
listen_addr='${NGINX_LISTEN_ADDR}'
listen_port='${NGINX_LISTEN_PORT}'
web_proxy_engine='${web_engine}'
web_proxy_backend='${web_backend}'
caddy_backend='${web_backend}'
xray_backend='${xray_backend}'
default_backend='${xray_backend}'
routes='${routes}'
whitelist_rules='${whitelist_rules}'
last_backup_id='${backup_id}'
mux_config_path='${mux_config}'
mux_systemd_service_name='${mux_service}'
EOF
    chmod 600 "$state_file" 2>/dev/null || true
}

show_single_443_engine_status() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔎 Текущее состояние единого входа 443 / движок${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    local engine state_file mux_config
    engine=$(single_443_current_engine)
    state_file=$(single_443_engine_state_path)
    mux_config=$(vpso_mux_config_path)
    show_current_entry_status
    echo -e "------------------------------------------------"
    echo -e "Текущий движок: ${GREEN}${engine}${PLAIN}"
    echo -e "Файл состояния: ${state_file}"
    echo -e "Конфиг mux: ${mux_config}"
    echo -e "------------------------------------------------"
    echo -e "${GREEN}Режим Nginx Stream — стабильный по умолчанию.${PLAIN}"
    echo -e "${YELLOW}Режим TCP Peek + Splice подходит для продвинутых пользователей, которым нужна маршрутизация по SNI на 4-м уровне и оптимизация splice.${PLAIN}"
    echo -e "${YELLOW}Для первого раза сначала протестируйте на 8444, не берите 443 напрямую.${PLAIN}"
    echo -e "${YELLOW}При переключении автоматически создаётся резервная копия, доступен откат.${PLAIN}"
    echo -e "------------------------------------------------"
    if [[ -f /etc/vps-optimize/sni-stack.env ]]; then
        load_sni_stack_env >/dev/null 2>&1 && print_sni_stack_current_summary
    else
        echo -e "${YELLOW}Не обнаружен sni-stack.env, единый вход 443 ещё не инициализирован.${PLAIN}"
    fi
    echo -e "------------------------------------------------"
    echo -e "Публичный 443 слушается:"
    ss -lntup 2>/dev/null | grep -E '(:443[[:space:]]|:443$)' || echo "Не слушается или недостаточно прав для просмотра процессов"
}

show_tcp_peek_splice_info() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Режим TCP Peek + Splice${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Режим TCP Peek + Splice: использует MSG_PEEK для чтения SNI из TLS ClientHello, не потребляя первый пакет, и маршрутизирует соединение на Caddy или Xray в зависимости от SNI; при передаче предпочтение отдаётся splice с нулевым копированием, при ошибке — обычный copy. Фактический разделитель — vpso-mux.${PLAIN}"
    echo -e "Он читает SNI на уровне TCP, не завершает TLS, не управляет сертификатами, не заменяет Caddy и не является прямым занятием 443 Xray."
    echo -e "Рекомендуемый порядок:"
    echo -e "  1. Сгенерировать правила маршрутизации TCP Peek + Splice: /etc/vps-optimize/vpso-mux.yaml"
    echo -e "  2. Проверить конфигурацию и бэкенд-порты"
    echo -e "  3. Запустить тестовый вход TCP Peek + Splice на 8444"
    echo -e "  4. После подтверждения транзакционно переключить публичный 443"
    echo -e "  5. При проблемах откатиться на Nginx Stream из меню"
}

print_vpso_mux_systemd_fallback_status() {
    local listen_port="${1:-${NGINX_LISTEN_PORT:-443}}"
    local public_lines preflight_lines
    echo -e "${YELLOW}status.json не существует или не удалось разобрать, переключено на проверку systemd / состояния прослушивания.${PLAIN}"
    echo -e "vpso-mux: $(service_status_compact vpso-mux)"
    echo -e "vpso-mux-preflight: $(service_status_compact vpso-mux-preflight)"
    echo -e "Публичный ${listen_port} слушается:"
    public_lines=$(ss -lntp 2>/dev/null | awk -v p=":${listen_port}" '$4 ~ p"$" {print}' || true)
    echo "${public_lines:-Не слушается или недостаточно прав}"
    echo -e "Предпроверка на 8444 слушается:"
    preflight_lines=$(ss -lntp 2>/dev/null | awk '$4 ~ ":8444$" {print}' || true)
    echo "${preflight_lines:-Не слушается или недостаточно прав}"
}

print_vpso_mux_status_json() {
    local status_file py_bin
    status_file=$(vpso_mux_status_json_path)
    [[ -s "$status_file" ]] || return 1

    if command -v python3 >/dev/null 2>&1; then
        py_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        py_bin="python"
    else
        return 1
    fi

    "$py_bin" - "$status_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

def value(name, default=0):
    return data.get(name, default)

print(f"status.json: {path}")
print(f"Время запуска: {value('start_time', 'unknown')}")
print(f"Время обновления: {value('updated_at', 'unknown')}")
listen = data.get("listen_addresses") or []
print("Адреса прослушивания: " + (", ".join(listen) if listen else "unknown"))
max_connections = value('max_connections', 'unlimited')
if max_connections == 0:
    max_connections = 'unlimited'
print(f"Лимит соединений: {max_connections}")
print(f"Текущие соединения: {value('active_connections')}")
print(f"Всего соединений: {value('total_connections')}")
print(f"Отклонено соединений: {value('rejected_connections')}")
print(f"Ошибок подключения к бэкенду: {value('backend_dial_errors')}")
print(f"Попыток повторного подключения: {value('backend_retry_attempts')}")
print(f"Успешных повторных подключений: {value('backend_retry_success')}")
print(f"Неудачных повторных подключений: {value('backend_retry_failed')}")
print(f"Успешных splice: {value('splice_success')}")
print(f"Падбек на copy: {value('copy_fallback')}")
print(f"Заблокировано белым списком: {value('whitelist_blocked')}")
print(f"no_sni: {value('no_sni')}")
print(f"Ошибок peek: {value('peek_errors')}")
print(f"Таймаутов peek: {value('peek_timeouts')}")
print(f"Байт клиент->бэкенд: {value('bytes_client_to_backend')}")
print(f"Байт бэкенд->клиент: {value('bytes_backend_to_client')}")

route_hits = data.get("route_hits") or {}
print("Топ 10 по попаданиям в маршруты:")
if route_hits:
    for name, count in sorted(route_hits.items(), key=lambda item: (-int(item[1]), item[0]))[:10]:
        print(f"  - {name}: {count}")
else:
    print("  - нет")

recent_errors = data.get("recent_errors") or []
print("Последние ошибки:")
if recent_errors:
    for item in recent_errors[-10:]:
        at = item.get("time", "unknown")
        msg = item.get("message", "")
        route = item.get("route_name", "")
        sni = item.get("sni", "")
        suffix = ""
        if route:
            suffix += f" route={route}"
        if sni:
            suffix += f" sni={sni}"
        print(f"  - {at} {msg}{suffix}")
else:
    print("  - нет")
PY
}

show_vpso_mux_runtime_status() {
    local status_file
    status_file=$(vpso_mux_status_json_path)
    echo -e "${BOLD}Статистика выполнения TCP Peek + Splice${PLAIN}"
    if ! print_vpso_mux_status_json; then
        print_vpso_mux_systemd_fallback_status "${NGINX_LISTEN_PORT:-443}"
    fi
    echo -e "------------------------------------------------"
    echo -e "Файл конфигурации: $(vpso_mux_config_path)"
    echo -e "systemd: /etc/systemd/system/$(vpso_mux_service_name)"
    echo -e "Файл состояния: ${status_file}"
}

# ---------------------------------------------------------
# Module: vpso_mux_config.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Генерация YAML vpso-mux и конфигурация TCP Peek.

append_vpso_mux_route_yaml() {
    local file="$1"
    local name="$2"
    local sni="$3"
    local backend="$4"
    local whitelist="$5"
    {
        echo "  - name: $(yaml_quote "$name")"
        echo "    sni:"
        echo "      - $(yaml_quote "$sni")"
        echo "    backend: $(yaml_quote "$backend")"
        if [[ -n "$whitelist" ]]; then
            echo "    whitelist:"
            local range
            for range in $whitelist; do
                echo "      - $(yaml_quote "$range")"
            done
        fi
    } >> "$file"
}

write_vpso_mux_config_from_sni_stack() {
    local listen_port="${1:-$NGINX_LISTEN_PORT}"
    local output_file="${2:-$(vpso_mux_config_path)}"
    local web_backend xray_backend listen_addr route_name ranges i domain backend
    web_backend=$(web_proxy_backend)
    xray_backend=$(format_hostport "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT")
    mkdir -p "$(dirname "$output_file")"

    {
        echo "listen:"
        echo "  tcp:"
        if [[ "$NGINX_LISTEN_ADDR" == "0.0.0.0" ]]; then
            echo "    - $(yaml_quote "0.0.0.0:${listen_port}")"
        elif [[ "$NGINX_LISTEN_ADDR" == "::" ]]; then
            echo "    - $(yaml_quote "[::]:${listen_port}")"
        else
            listen_addr=$(format_hostport "$NGINX_LISTEN_ADDR" "$listen_port")
            echo "    - $(yaml_quote "$listen_addr")"
        fi
        echo ""
        echo "timeouts:"
        echo "  peek: $(yaml_quote "3s")"
        echo "  dial: $(yaml_quote "5s")"
        echo "  idle: $(yaml_quote "300s")"
        echo "  shutdown: $(yaml_quote "10s")"
        echo ""
        echo "backend_retry:"
        echo "  count: 0"
        echo "  delay: $(yaml_quote "200ms")"
        echo ""
        echo "splice:"
        echo "  enabled: true"
        echo "  pipe_size: 1048576"
        echo "  fallback_to_copy: true"
        echo ""
        echo "limits:"
        echo "  max_connections: 4096"
        echo ""
        echo "default_backend: $(yaml_quote "$xray_backend")"
        echo ""
        echo "routes:"
    } > "$output_file"

    ranges=$(sni_ip_whitelist_ranges_for_domain "$PANEL_DOMAIN")
    append_vpso_mux_route_yaml "$output_file" "panel" "$PANEL_DOMAIN" "$web_backend" "$ranges"
    if [[ -z "$ranges" ]]; then
        echo -e "${YELLOW}⚠️ Домен панели ${PANEL_DOMAIN} в данный момент не имеет IP-белого списка; перед переключением убедитесь, что это желаемое поведение.${PLAIN}"
    fi

    for i in "${!SITE_DOMAINS[@]}"; do
        domain="${SITE_DOMAINS[$i]}"
        [[ -n "$domain" ]] || continue
        route_name=$(sni_stack_route_name "site" "$domain")
        ranges=$(sni_ip_whitelist_ranges_for_domain "$domain")
        append_vpso_mux_route_yaml "$output_file" "$route_name" "$domain" "$web_backend" "$ranges"
    done

    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        domain="${TCP_ROUTE_SNIS[$i]}"
        [[ -n "$domain" ]] || continue
        route_name=$(sni_stack_route_name "tcp" "$domain")
        backend=$(format_hostport "${TCP_ROUTE_ADDRS[$i]}" "${TCP_ROUTE_PORTS[$i]}")
        append_vpso_mux_route_yaml "$output_file" "$route_name" "$domain" "$backend" ""
    done

    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        domain="${XRAY_SNI_ROUTE_SNIS[$i]}"
        [[ -n "$domain" ]] || continue
        route_name=$(sni_stack_route_name "xray" "$domain")
        backend=$(format_hostport "${XRAY_SNI_ROUTE_ADDRS[$i]}" "${XRAY_SNI_ROUTE_PORTS[$i]}")
        append_vpso_mux_route_yaml "$output_file" "$route_name" "$domain" "$backend" ""
    done

    append_vpso_mux_route_yaml "$output_file" "reality" "$REALITY_SNI" "$xray_backend" ""

    cat <<EOF >> "$output_file"

logging:
  level: $(yaml_quote "info")
  format: $(yaml_quote "json")
  max_size_bytes: 5242880
  max_backups: 3
EOF
    chmod 600 "$output_file" 2>/dev/null || true
}

generate_tcp_peek_config() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Повторное применение конфигурации TCP Peek + Splice${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    echo -e "${YELLOW}Генерируются только правила маршрутизации TCP Peek + Splice, служба, порт и занятие 443 не изменяются.${PLAIN}"
    write_vpso_mux_config_from_sni_stack "$NGINX_LISTEN_PORT" "$(vpso_mux_config_path)" || return 1
    echo -e "${GREEN}✅ Сгенерировано: $(vpso_mux_config_path)${PLAIN}"
    echo -e "Бэкенд по умолчанию: $(format_hostport "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT")"
    echo -e "Web-бэкенд: $(web_proxy_engine_label) $(web_proxy_backend)"
    echo -e "${YELLOW}Следующий шаг: проверьте конфигурацию, затем используйте тестовый вход TCP Peek + Splice на 8444.${PLAIN}"
}

# ---------------------------------------------------------
# Module: vpso_mux_install.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Сборка, установка, systemd и вспомогательные функции для vpso-mux.

go_install_vpso_mux_latest() {
    local module_version tmp_dir
    echo -e "${CYAN}▶ Сборка vpso-mux с использованием локального Go в совместимом режиме...${PLAIN}"
    if ! go version 2>/dev/null | grep -Eq 'go1\.(2[2-9]|[3-9][0-9])'; then
        echo -e "${RED}❌ Текущая версия Go ниже 1.22, автоматическая загрузка временного Go-тулчейна на рабочем сервере запрещена.${PLAIN}"
        echo -e "${YELLOW}Установите Go 1.22+ через системный менеджер пакетов, или соберите /usr/local/bin/vpso-mux в безопасной среде перед переключением на TCP Peek.${PLAIN}"
        return 1
    fi
    vpso_mux_build_resource_check || return 1
    module_version=$(GOTOOLCHAIN=local go list -m -f '{{.Version}}' github.com/sacredx72/VPS-Optimize@latest 2>/dev/null) || return 1
    tmp_dir=$(mktemp -d /tmp/vpso-mux-build.XXXXXX) || return 1
    cat <<EOF > "${tmp_dir}/go.mod"
module vpso-mux-build

go 1.22

require github.com/sacredx72/VPS-Optimize ${module_version}

replace golang.org/x/sys => golang.org/x/sys v0.30.0
EOF
    (
        local mod_dir patched_dir patch_file
        cd "$tmp_dir" || exit 1
        GOMAXPROCS=1 GOTOOLCHAIN=local go mod download github.com/sacredx72/VPS-Optimize || exit 1
        mod_dir=$(GOTOOLCHAIN=local go list -m -f '{{.Dir}}' github.com/sacredx72/VPS-Optimize) || exit 1
        patched_dir="${tmp_dir}/VPS-Optimize-src"
        cp -a "$mod_dir" "$patched_dir" || exit 1
        chmod -R u+w "$patched_dir" 2>/dev/null || true
        patch_file="${patched_dir}/cmd/vpso-mux/main.go"
        if grep -q 'unix\.Splice(pipeFD\[0\], nil, dstFD, nil, remaining,' "$patch_file" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Обнаружен старый исходный код vpso-mux, применяется совместимый патч для Go...${PLAIN}"
            sed -i 's/unix\.Splice(pipeFD\[0\], nil, dstFD, nil, remaining,/unix.Splice(pipeFD[0], nil, dstFD, nil, int(remaining),/' "$patch_file" || exit 1
        fi
        cat <<EOF >> "${tmp_dir}/go.mod"

replace github.com/sacredx72/VPS-Optimize => ./VPS-Optimize-src
EOF
        GOMAXPROCS=1 GOTOOLCHAIN=local go get "github.com/sacredx72/VPS-Optimize/cmd/vpso-mux@${module_version}" || exit 1
        GOMAXPROCS=1 GOTOOLCHAIN=local go build -p 1 -o /usr/local/bin/vpso-mux github.com/sacredx72/VPS-Optimize/cmd/vpso-mux
    )
}

vpso_mux_build_resource_check() {
    local mem_kb swap_kb available_kb tmp_kb
    if [[ -r /proc/meminfo ]]; then
        mem_kb=$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
        swap_kb=$(awk '/SwapFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
        mem_kb=${mem_kb:-0}
        swap_kb=${swap_kb:-0}
        available_kb=$((mem_kb + swap_kb))
        if (( available_kb > 0 && available_kb < 262144 )); then
            echo -e "${RED}❌ Доступная память+Swap менее 256 МБ, сборка vpso-mux на этом сервере отклонена во избежание потери связи.${PLAIN}"
            return 1
        fi
    fi
    tmp_kb=$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    tmp_kb=${tmp_kb:-0}
    if (( tmp_kb > 0 && tmp_kb < 524288 )); then
        echo -e "${RED}❌ Свободное место в /tmp менее 512 МБ, сборка vpso-mux отклонена.${PLAIN}"
        return 1
    fi
}

require_vpso_mux_binary_for_cutover() {
    if [[ -x /usr/local/bin/vpso-mux ]]; then
        return 0
    fi
    echo -e "${RED}❌ Отсутствует /usr/local/bin/vpso-mux, переключение на режим TCP Peek + Splice отклонено.${PLAIN}"
    echo -e "${YELLOW}Во избежание автоматической загрузки Go-тулчейна или удалённой сборки на продакшене при переключении 443, процесс переключения не выполняет автоматическую сборку vpso-mux.${PLAIN}"
    echo -e "${YELLOW}Сначала выполните предпроверку TCP Peek 8444 в центре управления 443, убедитесь, что vpso-mux установлен и тестовый порт работает, затем переключайте публичный 443.${PLAIN}"
    return 1
}

install_vpso_mux_binary() {
    if [[ -x /usr/local/bin/vpso-mux ]]; then
        return 0
    fi

    if ! command -v go >/dev/null 2>&1; then
        echo -e "${CYAN}▶ Go не обнаружен, установка инструментария сборки vpso-mux...${PLAIN}"
        if is_debian; then
            install_pkg golang-go || install_pkg golang || return 1
        elif is_redhat; then
            install_pkg golang || return 1
        else
            echo -e "${RED}❌ Автоматическая установка Go не поддерживается на текущей системе, установите Go 1.22+ вручную.${PLAIN}"
            return 1
        fi
    fi

    command -v go >/dev/null 2>&1 || { echo -e "${RED}❌ Go не доступен после установки, невозможно собрать vpso-mux.${PLAIN}"; return 1; }

    local source_dir="${SCRIPT_DIR:-$(pwd)}"
    if [[ -d "$source_dir/cmd/vpso-mux" ]]; then
        echo -e "${CYAN}▶ Сборка vpso-mux из текущего исходного кода...${PLAIN}"
        (cd "$source_dir" && go build -o /usr/local/bin/vpso-mux ./cmd/vpso-mux) || return 1
        chmod 755 /usr/local/bin/vpso-mux
        return 0
    fi

    go_install_vpso_mux_latest || return 1
    chmod 755 /usr/local/bin/vpso-mux 2>/dev/null || true
    [[ -x /usr/local/bin/vpso-mux ]] || { echo -e "${RED}❌ vpso-mux не исполняем после установки: /usr/local/bin/vpso-mux${PLAIN}"; return 1; }
    return 0
}

write_vpso_mux_systemd_service() {
    local service_file="${1:-/etc/systemd/system/vpso-mux.service}"
    cat <<'EOF' > "$service_file"
[Unit]
Description=VPS-Optimize TCP Peek + Splice vpso-mux router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vpso-mux -config /etc/vps-optimize/vpso-mux.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$service_file"
    if [[ "$service_file" == "/etc/systemd/system/vpso-mux.service" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

run_vpso_mux_config_check() {
    local config_file="${1:-$(vpso_mux_config_path)}"
    if [[ -x /usr/local/bin/vpso-mux ]]; then
        /usr/local/bin/vpso-mux -config "$config_file" -check
        return $?
    fi
    local source_dir="${SCRIPT_DIR:-$(pwd)}"
    if command -v go >/dev/null 2>&1 && [[ -d "$source_dir/cmd/vpso-mux" ]]; then
        (cd "$source_dir" && go run ./cmd/vpso-mux -config "$config_file" -check)
        return $?
    fi
    echo -e "${RED}❌ Отсутствует бинарный файл vpso-mux или Go-тулчейн, невозможно выполнить полную проверку конфигурации.${PLAIN}"
    return 1
}

print_vpso_mux_failure_context() {
    local port="${1:-$NGINX_LISTEN_PORT}"
    echo -e "${YELLOW}▶ vpso-mux не смог стабильно слушать ${port}, вот последнее состояние и логи:${PLAIN}"
    systemctl status vpso-mux --no-pager -l 2>/dev/null || true
    echo -e "${YELLOW}▶ Последние 40 строк лога vpso-mux:${PLAIN}"
    journalctl -u vpso-mux -n 40 --no-pager 2>/dev/null || true
    echo -e "${YELLOW}▶ Текущее состояние прослушивания ${port}:${PLAIN}"
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true
    else
        netstat -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true
    fi
}

# ---------------------------------------------------------
# Module: tcp_peek_engine.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Предпроверка TCP Peek, переключение режима и действия во время выполнения.

vpso_mux_preflight_config_path() {
    echo "/etc/vps-optimize/vpso-mux.preflight.yaml"
}

write_vpso_mux_preflight_service() {
    cat <<'EOF' > /etc/systemd/system/vpso-mux-preflight.service
[Unit]
Description=VPS-Optimize TCP Peek preflight router on 8444
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vpso-mux -config /etc/vps-optimize/vpso-mux.preflight.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/vpso-mux-preflight.service
    systemctl daemon-reload >/dev/null 2>&1 || true
}

port_listener_has_process() {
    local port="$1"
    local proc_pattern="$2"
    ss -lntp 2>/dev/null | grep -E "(:${port}[[:space:]]|:${port}$)" | grep -q "$proc_pattern"
}

tcppeek_preflight_probe_route_matrix() {
    local test_port="$1"
    local connect_host domain i route_addr route_port failures=0
    connect_host=$(probe_host_for_listen_addr "$NGINX_LISTEN_ADDR")

    echo -e "${CYAN}▶ Проверка маршрутной матрицы TCP Peek 8444...${PLAIN}"
    probe_tls_sni_certificate "Предпроверка SNI панели TCP Peek 8444" "$connect_host" "$test_port" "$PANEL_DOMAIN" || failures=1

    for domain in "${SITE_DOMAINS[@]}"; do
        [[ -n "$domain" ]] || continue
        probe_tls_sni_certificate "Предпроверка веб-SNI TCP Peek 8444 ${domain}" "$connect_host" "$test_port" "$domain" || failures=1
    done

    tcp_probe_host "Бэкенд Xray/REALITY по умолчанию для TCP Peek" "$(probe_host_for_listen_addr "$XRAY_LISTEN_ADDR")" "$XRAY_LISTEN_PORT" 3 1 || failures=1

    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        domain="${TCP_ROUTE_SNIS[$i]}"
        route_addr="${TCP_ROUTE_ADDRS[$i]}"
        route_port="${TCP_ROUTE_PORTS[$i]}"
        [[ -n "$domain" && -n "$route_addr" && -n "$route_port" ]] || continue
        tcp_probe_host "Локальный TCP/SNI бэкенд TCP Peek ${domain}" "$(probe_host_for_listen_addr "$route_addr")" "$route_port" 3 1 || failures=1
    done

    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        domain="${XRAY_SNI_ROUTE_SNIS[$i]}"
        route_addr="${XRAY_SNI_ROUTE_ADDRS[$i]}"
        route_port="${XRAY_SNI_ROUTE_PORTS[$i]}"
        [[ -n "$domain" && -n "$route_addr" && -n "$route_port" ]] || continue
        tcp_probe_host "Бэкенд Xray SNI TCP Peek ${domain}" "$(probe_host_for_listen_addr "$route_addr")" "$route_port" 3 1 || failures=1
    done

    if [[ "$failures" -ne 0 ]]; then
        echo -e "${RED}❌ Предпроверка маршрутной матрицы TCP Peek 8444 не удалась, публичный 443 не изменён.${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}✅ Предпроверка маршрутной матрицы TCP Peek 8444 пройдена.${PLAIN}"
    return 0
}

run_tcppeek_preflight_service() {
    local keep_running="${1:-0}"
    local test_port="${2:-8444}"
    local config_file tmp_config
    config_file=$(vpso_mux_preflight_config_path)

    require_vpso_mux_binary_for_cutover || return 1
    tmp_config="${config_file}.tmp.$$"
    write_vpso_mux_config_from_sni_stack "$test_port" "$tmp_config" || return 1
    if ! run_vpso_mux_config_check "$tmp_config"; then
        quarantine_path "$tmp_config" "/etc/vps-optimize/quarantine/vpso-mux" >/dev/null 2>&1 || true
        return 1
    fi
    mv "$tmp_config" "$config_file" || return 1
    write_vpso_mux_preflight_service
    systemctl stop vpso-mux-preflight >/dev/null 2>&1 || true
    if ! systemctl start vpso-mux-preflight; then
        echo -e "${RED}❌ Не удалось запустить предпроверочную службу TCP Peek 8444, публичный 443 не изменён.${PLAIN}"
        return 1
    fi
    sleep 1
    if ! port_listener_has_process "$test_port" 'vpso-mux'; then
        systemctl stop vpso-mux-preflight >/dev/null 2>&1 || true
        echo -e "${RED}❌ Предпроверка TCP Peek 8444 не обнаружила vpso-mux, переключение публичного 443 отклонено.${PLAIN}"
        return 1
    fi
    tcppeek_preflight_probe_route_matrix "$test_port" || {
        systemctl stop vpso-mux-preflight >/dev/null 2>&1 || true
        return 1
    }
    if [[ "$keep_running" != "1" ]]; then
        systemctl stop vpso-mux-preflight >/dev/null 2>&1 || true
    fi
    return 0
}

tcp_peek_dry_run_config() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Проверка правил маршрутизации TCP Peek + Splice${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    local config_file
    config_file=$(vpso_mux_config_path)
    [[ -f "$config_file" ]] || { echo -e "${YELLOW}${config_file} не найден, сначала генерируем конфигурацию.${PLAIN}"; write_vpso_mux_config_from_sni_stack "$NGINX_LISTEN_PORT" "$config_file" || return 1; }
    echo -e "${CYAN}▶ Проверка YAML, SNI, бэкендов, белых списков и дублирующих SNI...${PLAIN}"
    run_vpso_mux_config_check "$config_file" || return 1
    echo -e "${CYAN}▶ Проверка локальных бэкенд-портов...${PLAIN}"
    tcp_probe_host "Caddy 127.0.0.1:${CADDY_LISTEN_PORT}" "$(probe_host_for_listen_addr "$CADDY_LISTEN_ADDR")" "$CADDY_LISTEN_PORT" || true
    tcp_probe_host "Xray/REALITY 127.0.0.1:${XRAY_LISTEN_PORT}" "$(probe_host_for_listen_addr "$XRAY_LISTEN_ADDR")" "$XRAY_LISTEN_PORT" || true
    print_sni_ip_whitelist_summary
    echo -e "${GREEN}✅ Проверка конфигурации завершена. Сначала протестируйте через TCP Peek + Splice, не берите 443 напрямую.${PLAIN}"
}

start_tcp_peek_test_port() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Состояние TCP Peek + Splice / тестовый вход${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    if ! load_sni_stack_env; then
        NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-443}"
        show_vpso_mux_runtime_status
        return 1
    fi
    show_vpso_mux_runtime_status
    echo -e "------------------------------------------------"
    if [[ "$(single_443_current_engine)" == "tcp-peek" ]]; then
        echo -e "${YELLOW}Текущий вход уже в режиме TCP Peek + Splice. Чтобы случайно не остановить публичный 443, этот пункт не перезаписывает работающую конфигурацию 443.${PLAIN}"
        return 0
    fi
    echo -e "${YELLOW}Предпроверочная служба vpso-mux слушает только 8444, текущий публичный 443 не будет остановлен или заменён.${PLAIN}"
    confirm_risk_action "Установить/собрать vpso-mux и запустить предпроверку на 8444" \
        "Может установить Go-тулчейн, собрать /usr/local/bin/vpso-mux и запустить отдельную службу vpso-mux-preflight.service на 8444" \
        "Остановите vpso-mux-preflight.service или оставайтесь в Nginx Stream/Xray Fallback, публичный 443 не меняется" \
        "Низкая память/диск будут перехвачены проверкой ресурсов; публичный 443 на этом шаге не заменяется." || return 1
    install_vpso_mux_binary || return 1
    apply_web_proxy_configs_for_single_443 || return 1
    restart_web_proxy_for_single_443 || return 1
    tcp_probe_host "$(web_proxy_engine_label) локальный TLS" "$(probe_host_for_listen_addr "$CADDY_LISTEN_ADDR")" "$CADDY_LISTEN_PORT" || return 1
    tcp_probe_host "Локальный Xray/REALITY входящий" "$(probe_host_for_listen_addr "$XRAY_LISTEN_ADDR")" "$XRAY_LISTEN_PORT" 6 1 || return 1
    run_tcppeek_preflight_service 1 "8444" || return 1
    echo -e "${GREEN}✅ Предпроверочная служба vpso-mux запущена на тестовом порту 8444, публичный 443 не изменён.${PLAIN}"
    echo -e "Тестовые команды:"
    echo -e "  openssl s_client -connect SERVER_IP:8444 -servername ${PANEL_DOMAIN}"
    [[ ${#SITE_DOMAINS[@]} -gt 0 ]] && echo -e "  openssl s_client -connect SERVER_IP:8444 -servername ${SITE_DOMAINS[0]}"
    echo -e "  openssl s_client -connect SERVER_IP:8444 -servername random.example.com"
    [[ ${#SITE_DOMAINS[@]} -gt 0 ]] && echo -e "  curl -vk --resolve ${SITE_DOMAINS[0]}:8444:SERVER_IP https://${SITE_DOMAINS[0]}:8444/"
}

preflight_tcppeek_before_cutover() {
    echo -e "${CYAN}▶ Выполнение безопасной предпроверки TCP Peek 8444, публичный 443 пока не изменяется...${PLAIN}"
    require_vpso_mux_binary_for_cutover || return 1
    warn_if_public_bind "$(web_proxy_engine_label)" "$CADDY_LISTEN_ADDR" "$CADDY_LISTEN_PORT" || return 1
    warn_if_public_bind "Xray REALITY" "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT" || return 1
    apply_web_proxy_configs_for_single_443 || return 1
    restart_web_proxy_for_single_443 || return 1
    tcp_probe_host "$(web_proxy_engine_label) локальный TLS" "$(probe_host_for_listen_addr "$CADDY_LISTEN_ADDR")" "$CADDY_LISTEN_PORT" || return 1
    tcp_probe_host "Локальный Xray/REALITY входящий" "$(probe_host_for_listen_addr "$XRAY_LISTEN_ADDR")" "$XRAY_LISTEN_PORT" 6 1 || {
        echo -e "${RED}❌ Локальный Xray-входящий недоступен, переключение на TCP Peek отклонено. Сначала настройте локальный входящий в 3x-ui/Xray.${PLAIN}"
        return 1
    }
    run_tcppeek_preflight_service 0 "8444" || return 1
    echo -e "${GREEN}✅ Предпроверка TCP Peek 8444 пройдена, теперь можно переключать публичный 443.${PLAIN}"
}

preflight_entry_mode_before_cutover() {
    local target_mode="$1"
    target_mode=$(normalize_entry_mode_name "$target_mode") || return 1
    case "$target_mode" in
        "tcp-peek") preflight_tcppeek_before_cutover ;;
        *) return 0 ;;
    esac
}

normalize_entry_mode_name() {
    local mode="$1"
    case "$mode" in
        "nginx_stream"|"nginx-stream") echo "nginx-stream" ;;
        "xray_fallback"|"xray-fallback") echo "xray-fallback" ;;
        "tcp_peek"|"tcp-peek") echo "tcp-peek" ;;
        *) return 1 ;;
    esac
}

entry_mode_engine_name() {
    local mode="$1"
    mode=$(normalize_entry_mode_name "$mode") || return 1
    echo "$mode"
}

print_entry_mode_cutover_paths() {
    local target_mode="$1"
    echo -e "${BOLD}Задействованные пути конфигурации${PLAIN}"
    echo -e "Nginx: /etc/nginx/nginx.conf"
    echo -e "Nginx: /etc/nginx/stream.d/vps_sni_${NGINX_LISTEN_PORT}.conf"
    echo -e "Nginx: /etc/nginx/conf.d/00-vps-default-drop.conf"
    echo -e "Caddy: /etc/caddy/Caddyfile"
    echo -e "Caddy: /etc/caddy/conf.d/${PANEL_DOMAIN}.caddy"
    local site_domain
    for site_domain in "${SITE_DOMAINS[@]}"; do
        [[ -n "$site_domain" ]] && echo -e "Caddy: /etc/caddy/conf.d/${site_domain}.caddy"
    done
    echo -e "systemd: /etc/systemd/system/vpso-mux.service"
    echo -e "vpso-mux: $(vpso_mux_config_path)"
    echo -e "Состояние: $(single_443_engine_state_path)"
    echo -e "Общие параметры: /etc/vps-optimize/sni-stack.env"
    if [[ "$target_mode" == "tcp-peek" ]]; then
        echo -e "Состояние vpso-mux: $(vpso_mux_status_json_path)"
    fi
}

print_preview_file_diff() {
    local actual_path="$1"
    local planned_path="$2"
    local title="$3"

    echo -e "${CYAN}--- ${title}${PLAIN}"
    if ! command -v diff >/dev/null 2>&1; then
        echo -e "${YELLOW}Команда diff не обнаружена, показать различия невозможно.${PLAIN}"
        return 0
    fi

    if [[ -f "$actual_path" && -f "$planned_path" ]]; then
        diff -u --label "${actual_path} (текущий)" --label "${actual_path} (ожидаемый)" "$actual_path" "$planned_path" || true
    elif [[ -f "$actual_path" && ! -f "$planned_path" ]]; then
        diff -u --label "${actual_path} (текущий)" --label "${actual_path} (будет отключён)" "$actual_path" /dev/null || true
    elif [[ ! -f "$actual_path" && -f "$planned_path" ]]; then
        diff -u --label "${actual_path} (сейчас отсутствует)" --label "${actual_path} (будет добавлен)" /dev/null "$planned_path" || true
    else
        echo "Файл отсутствует как в текущей, так и в ожидаемой конфигурации."
    fi
    echo ""
}

write_entry_preview_caddyfile() {
    local output_file="$1"
    cat <<'EOF' > "$output_file"
{
    auto_https off
}

import conf.d/*
EOF
}

show_entry_mode_cutover_diff() {
    local target_mode="$1"
    local tmp_dir target_root target_caddy_dir target_nginx target_mux target_service target_caddyfile
    target_mode=$(normalize_entry_mode_name "$target_mode") || return 1
    tmp_dir=$(mktemp -d /tmp/vpso-entry-preview.XXXXXX) || return 1
    chmod 700 "$tmp_dir" 2>/dev/null || true
    target_root="${tmp_dir}/target"
    target_caddy_dir="${target_root}/etc/caddy/conf.d"
    mkdir -p "$target_caddy_dir" "${target_root}/etc/nginx/stream.d" "${target_root}/etc/vps-optimize" "${target_root}/etc/systemd/system"

    target_caddyfile="${target_root}/etc/caddy/Caddyfile"
    target_nginx="${target_root}/etc/nginx/stream.d/vps_sni_${NGINX_LISTEN_PORT}.conf"
    target_mux="${target_root}/etc/vps-optimize/vpso-mux.yaml"
    target_service="${target_root}/etc/systemd/system/vpso-mux.service"

    write_entry_preview_caddyfile "$target_caddyfile"
    write_caddy_panel_config "${target_caddy_dir}/${PANEL_DOMAIN}.caddy"
    write_caddy_site_config "$target_caddy_dir"

    if [[ "$target_mode" == "nginx-stream" ]]; then
        write_nginx_sni_stream_config "$target_nginx" "no"
    fi
    if [[ "$target_mode" == "tcp-peek" ]]; then
        write_vpso_mux_config_from_sni_stack "$NGINX_LISTEN_PORT" "$target_mux"
        write_vpso_mux_systemd_service "$target_service"
    else
        [[ -f "$(vpso_mux_config_path)" ]] && cp -a "$(vpso_mux_config_path)" "$target_mux" 2>/dev/null || true
        [[ -f /etc/systemd/system/vpso-mux.service ]] && cp -a /etc/systemd/system/vpso-mux.service "$target_service" 2>/dev/null || true
    fi

    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Предпросмотр diff переключения единого входа 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    print_preview_file_diff "/etc/caddy/Caddyfile" "$target_caddyfile" "Caddyfile"
    print_preview_file_diff "/etc/caddy/conf.d/${PANEL_DOMAIN}.caddy" "${target_caddy_dir}/${PANEL_DOMAIN}.caddy" "Caddy домен панели"
    local site_domain
    for site_domain in "${SITE_DOMAINS[@]}"; do
        [[ -n "$site_domain" ]] || continue
        print_preview_file_diff "/etc/caddy/conf.d/${site_domain}.caddy" "${target_caddy_dir}/${site_domain}.caddy" "Caddy сайт/прокси ${site_domain}"
    done
    print_preview_file_diff "/etc/nginx/stream.d/vps_sni_${NGINX_LISTEN_PORT}.conf" "$target_nginx" "Nginx Stream вход"
    print_preview_file_diff "$(vpso_mux_config_path)" "$target_mux" "vpso-mux конфиг маршрутизации"
    print_preview_file_diff "/etc/systemd/system/vpso-mux.service" "$target_service" "vpso-mux systemd"
    echo -e "${YELLOW}Предпросмотр diff создаёт целевые файлы во временном каталоге, ничего не записывает в /etc. Временный каталог: ${tmp_dir}${PLAIN}"
}

preview_entry_mode_cutover() {
    local current_mode="$1"
    local target_mode="$2"
    local backup_dir="$3"
    local listener_info current_listener current_display expected_listener expected_display choice

    current_mode=$(normalize_entry_mode_name "$current_mode" 2>/dev/null || echo "$current_mode")
    target_mode=$(normalize_entry_mode_name "$target_mode") || return 1
    listener_info=$(detect_443_listener "$NGINX_LISTEN_PORT")
    current_listener="${listener_info%%|*}"
    current_display=$(entry_listener_display_name "$current_listener")
    expected_listener=$(entry_mode_expected_listener "$target_mode") || return 1
    expected_display=$(entry_listener_display_name "$expected_listener")

    while true; do
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}Предпросмотр изменений при переключении единого входа 443${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "Текущий ENTRY_MODE: ${current_mode}"
        echo -e "Целевой ENTRY_MODE: ${target_mode}"
        echo -e "Текущий слушатель 443: ${current_display} (${listener_info#*|})"
        echo -e "Ожидаемый слушатель после переключения: ${expected_display}"
        echo -e "Точка отката: ${backup_dir}"
        echo -e "------------------------------------------------"
        print_entry_mode_cutover_paths "$target_mode"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Посмотреть diff${PLAIN}"
        echo -e "${GREEN}  2. Продолжить переключение${PLAIN}"
        echo -e "${RED}  0. Отмена, без изменений${PLAIN}"
        read_trimmed choice "Выберите действие (по умолчанию 0 отмена): "
        case "$(echo "${choice:-0}" | tr '[:upper:]' '[:lower:]')" in
            1|d|D|diff)
                show_entry_mode_cutover_diff "$target_mode"
                ;;
            2|y|yes)
                return 0
                ;;
            0|n|no|q)
                echo -e "${BLUE}Переключение входа 443 отменено, изменения не внесены.${PLAIN}"
                return 1
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор.${PLAIN}"
                ;;
        esac
    done
}

systemd_unit_exists() {
    local unit="$1"
    systemctl list-unit-files "$unit" >/dev/null 2>&1 || systemctl status "$unit" >/dev/null 2>&1
}

xray_entry_service_name() {
    local svc
    for svc in xray.service x-ui.service 3x-ui.service; do
        if systemd_unit_exists "$svc"; then
            echo "${svc%.service}"
            return 0
        fi
    done
    return 1
}

restart_xray_entry_service() {
    local svc
    svc=$(xray_entry_service_name) || { echo -e "${RED}❌ Не обнаружен systemd-сервис xray/x-ui/3x-ui.${PLAIN}"; return 1; }
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" || { echo -e "${RED}❌ Не удалось перезапустить ${svc}.${PLAIN}"; return 1; }
}

stop_xray_entry_service_if_public_443() {
    local listener svc
    listener=$(detect_443_listener)
    listener_info_has_entry "$listener" "xray" || return 0
    svc=$(xray_entry_service_name) || return 0
    if ! systemctl stop "$svc"; then
        echo -e "${RED}❌ Не удалось остановить ${svc}, публичный 443 всё ещё может быть занят Xray.${PLAIN}"
        return 1
    fi
    sleep 1
    listener=$(detect_443_listener)
    if listener_info_has_entry "$listener" "xray"; then
        echo -e "${RED}❌ ${svc} остановлен, но Xray всё ещё слушает публичный 443, переключение входа отклонено.${PLAIN}"
        return 1
    fi
}

stop_vpso_mux_service_if_public_443() {
    local listener
    listener=$(detect_443_listener)
    listener_info_has_entry "$listener" "tcppeek" || return 0
    if ! systemctl stop vpso-mux; then
        echo -e "${RED}❌ Не удалось остановить vpso-mux, публичный 443 всё ещё может быть занят TCP Peek.${PLAIN}"
        print_vpso_mux_failure_context "$NGINX_LISTEN_PORT"
        return 1
    fi
    sleep 1
    listener=$(detect_443_listener)
    if listener_info_has_entry "$listener" "tcppeek"; then
        echo -e "${RED}❌ vpso-mux остановлен, но TCP Peek всё ещё слушает публичный 443, переключение входа отклонено.${PLAIN}"
        print_vpso_mux_failure_context "$NGINX_LISTEN_PORT"
        return 1
    fi
}

stop_caddy_service_if_public_443() {
    local listener
    listener=$(detect_443_listener)
    listener_info_has_entry "$listener" "caddy" || return 0
    if ! systemctl stop caddy; then
        echo -e "${RED}❌ Не удалось остановить caddy, публичный 443 всё ещё может быть занят Caddy.${PLAIN}"
        return 1
    fi
    sleep 1
    listener=$(detect_443_listener)
    if listener_info_has_entry "$listener" "caddy"; then
        echo -e "${RED}❌ caddy остановлен, но всё ещё слушает публичный 443, переключение входа отклонено.${PLAIN}"
        return 1
    fi
}

disable_nginx_stream_public_443() {
    local nginx_conf="/etc/nginx/stream.d/vps_sni_${NGINX_LISTEN_PORT}.conf"
    local listener
    [[ -e "$nginx_conf" ]] && quarantine_path "$nginx_conf" "/etc/vps-optimize/quarantine/nginx-sni" >/dev/null 2>&1 || true
    if command -v nginx >/dev/null 2>&1; then
        if ! nginx -t; then
            print_nginx_stream_failure_context "$NGINX_LISTEN_PORT"
            return 1
        fi
        if ! restart_service_if_available nginx; then
            print_nginx_stream_failure_context "$NGINX_LISTEN_PORT"
            return 1
        fi
        sleep 1
        listener=$(detect_443_listener)
        if listener_info_has_entry "$listener" "nginx"; then
            echo -e "${RED}❌ Конфиг Nginx Stream 443 удалён, но nginx всё ещё слушает публичный 443, переключение входа отклонено.${PLAIN}"
            print_nginx_stream_failure_context "$NGINX_LISTEN_PORT"
            return 1
        fi
        if systemctl is-active --quiet nginx; then
            echo -e "${YELLOW}ℹ️ nginx всё ещё работает, но уже не слушает публичный ${NGINX_LISTEN_PORT}; это допустимо, единый вход требует только монопольного занятия 443 целевым входом.${PLAIN}"
        fi
    fi
}

stop_public_443_entry_services_for_target() {
    local target_mode="$1"
    target_mode=$(normalize_entry_mode_name "$target_mode") || return 1
    quarantine_legacy_nginx_https_proxy_configs
    stop_caddy_service_if_public_443 || return 1

    if [[ "$target_mode" != "nginx-stream" ]]; then
        disable_nginx_stream_public_443 || return 1
    fi
    if [[ "$target_mode" != "tcp-peek" ]]; then
        stop_vpso_mux_service_if_public_443 || return 1
    fi
    if [[ "$target_mode" != "xray-fallback" ]]; then
        stop_xray_entry_service_if_public_443 || return 1
    fi
}

guard_current_ssh_not_on_entry_port() {
    local action_name="${1:-Переключение режима входа}"
    local ssh_server_port
    if [[ -z "${SSH_CONNECTION:-}" ]]; then
        return 0
    fi
    ssh_server_port=$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}')
    if [[ -n "$ssh_server_port" && "$ssh_server_port" == "${NGINX_LISTEN_PORT:-443}" ]]; then
        echo -e "${RED}❌ Обнаружено, что текущая SSH-сессия подключена через порт входа ${ssh_server_port}.${PLAIN}"
        echo -e "${YELLOW}${action_name} приведёт к перезапуску или замене службы на этом порту, что разорвёт текущее SSH-соединение.${PLAIN}"
        echo -e "${YELLOW}Войдите через VNC/Serial Console провайдера или через другой SSH-порт, не равный ${ssh_server_port}.${PLAIN}"
        return 1
    fi
}

verify_public_443_listener_for_mode() {
    local mode="$1"
    local expected listener i
    local tries="${2:-10}"
    local delay="${3:-0.5}"
    mode=$(normalize_entry_mode_name "$mode") || return 1
    expected=$(entry_mode_expected_listener "$mode") || return 1

    for ((i = 1; i <= tries; i++)); do
        listener=$(detect_443_listener "$NGINX_LISTEN_PORT")
        if listener_info_has_entry "$listener" "$expected"; then
            return 0
        fi
        [[ "$i" -lt "$tries" ]] && sleep "$delay"
    done

    echo -e "${RED}❌ Публичный 443 не соответствует режиму ${mode}: ожидается ${expected}, фактически ${listener#*|}${PLAIN}"
    return 1
}

print_nginx_stream_failure_context() {
    local port="${1:-$NGINX_LISTEN_PORT}"
    local conf_file="/etc/nginx/stream.d/vps_sni_${port}.conf"
    echo -e "${YELLOW}▶ Nginx Stream не смог стабильно слушать ${port}, вот последнее состояние и подсказки:${PLAIN}"
    echo -e "${YELLOW}▶ Ожидаемый файл конфигурации: ${conf_file}${PLAIN}"
    if [[ -s "$conf_file" ]]; then
        sed -n '1,180p' "$conf_file" 2>/dev/null || true
    else
        echo -e "${RED}❌ ${conf_file} не существует или пуст.${PLAIN}"
    fi
    echo -e "${YELLOW}▶ Строки stream/include в nginx.conf:${PLAIN}"
    grep -nE '^[[:space:]]*(stream[[:space:]]*\{|include[[:space:]]+/etc/nginx/stream\.d/\*\.conf;|include[[:space:]]+/etc/nginx/modules-enabled/\*\.conf;)' /etc/nginx/nginx.conf 2>/dev/null || true
    echo -e "${YELLOW}▶ Загружает ли nginx -T этот stream-файл:${PLAIN}"
    if nginx -T 2>&1 | grep -Fq "$conf_file"; then
        echo -e "${GREEN}✅ nginx -T загрузил ${conf_file}${PLAIN}"
    else
        echo -e "${RED}❌ nginx -T не загрузил ${conf_file}${PLAIN}"
    fi
    echo -e "${YELLOW}▶ Состояние nginx:${PLAIN}"
    systemctl status nginx --no-pager -l 2>/dev/null || true
    echo -e "${YELLOW}▶ Последние 40 строк лога nginx:${PLAIN}"
    journalctl -u nginx -n 40 --no-pager 2>/dev/null || true
    echo -e "${YELLOW}▶ Текущее состояние прослушивания ${port}:${PLAIN}"
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true
    else
        netstat -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true
    fi
}

assert_nginx_stream_config_loaded() {
    local port="${1:-$NGINX_LISTEN_PORT}"
    local conf_file="/etc/nginx/stream.d/vps_sni_${port}.conf"

    if [[ ! -s "$conf_file" ]]; then
        echo -e "${RED}❌ Конфигурация Nginx Stream не сгенерирована или пуста: ${conf_file}${PLAIN}"
        print_nginx_stream_failure_context "$port"
        return 1
    fi
    if ! nginx -T 2>&1 | grep -Fq "$conf_file"; then
        echo -e "${RED}❌ Основная конфигурация Nginx не загружает ${conf_file}, продолжение отклонено.${PLAIN}"
        print_nginx_stream_failure_context "$port"
        return 1
    fi
}

check_entry_mode_dependencies() {
    local mode="$1"
    mode=$(normalize_entry_mode_name "$mode") || { echo -e "${RED}❌ Неверный целевой режим входа: ${mode}${PLAIN}"; return 1; }
    assert_web_proxy_whitelist_supported "$mode" "${WEB_PROXY_ENGINE:-caddy}" || return 1

    case "$mode" in
        "nginx-stream")
            command -v nginx >/dev/null 2>&1 || echo -e "${YELLOW}Nginx не обнаружен, при переключении будет использована существующая логика установки Nginx stream.${PLAIN}"
            if [[ "$(current_web_proxy_engine)" == "caddy" ]]; then
                command -v caddy >/dev/null 2>&1 || echo -e "${YELLOW}Caddy не обнаружен, при переключении будет использована существующая логика установки Caddy.${PLAIN}"
            fi
            ;;
        "tcp-peek")
            require_vpso_mux_binary_for_cutover || return 1
            if [[ "$(current_web_proxy_engine)" == "caddy" ]]; then
                command -v caddy >/dev/null 2>&1 || echo -e "${YELLOW}Caddy не обнаружен, при переключении будет использована существующая логика установки Caddy.${PLAIN}"
            fi
            ;;
        "xray-fallback")
            xray_entry_service_name >/dev/null 2>&1 || { echo -e "${RED}❌ Не обнаружен systemd-сервис xray/x-ui/3x-ui, переключение отклонено.${PLAIN}"; return 1; }
            if [[ "$(current_web_proxy_engine)" == "caddy" ]]; then
                command -v caddy >/dev/null 2>&1 || echo -e "${YELLOW}Caddy не обнаружен, при переключении будет использована существующая логика установки Caddy.${PLAIN}"
            fi
            ;;
    esac
}

backup_entry_mode_config() {
    local backup_dir="${1:-}" service_path svc listener_info
    create_sni_stack_backup "$backup_dir" >/dev/null
    backup_dir=$(cat /etc/vps-optimize/sni-stack.last-backup 2>/dev/null)
    [[ -n "$backup_dir" && -d "$backup_dir" ]] || { echo -e "${RED}❌ Не удалось создать резервную копию конфигурации режима входа.${PLAIN}"; return 1; }

    mkdir -p "$backup_dir/systemd" "$backup_dir/xray" "$backup_dir/vps-optimize"
    for svc in nginx.service caddy.service xray.service x-ui.service 3x-ui.service vpso-mux.service; do
        for service_path in "/etc/systemd/system/$svc" "/lib/systemd/system/$svc" "/usr/lib/systemd/system/$svc"; do
            [[ -f "$service_path" ]] && cp -a "$service_path" "$backup_dir/systemd/${service_path//\//_}" 2>/dev/null || true
        done
    done
    [[ -f /etc/xray/config.json ]] && cp -a /etc/xray/config.json "$backup_dir/xray/etc-xray-config.json" 2>/dev/null || true
    [[ -f /usr/local/etc/xray/config.json ]] && cp -a /usr/local/etc/xray/config.json "$backup_dir/xray/usr-local-etc-xray-config.json" 2>/dev/null || true
    [[ -f /etc/vps-optimize/xray-sni-routes.conf ]] && cp -a /etc/vps-optimize/xray-sni-routes.conf "$backup_dir/vps-optimize/xray-sni-routes.conf" 2>/dev/null || true
    listener_info=$(detect_443_listener)
    {
        echo "created_at=$(date -Is 2>/dev/null || date)"
        echo "entry_mode=$(get_entry_mode)"
        echo "listener=${listener_info}"
        echo "ss_443:"
        ss -lntp 2>/dev/null | grep -E '(:443[[:space:]]|:443$)' || echo "none"
    } > "$backup_dir/vps-optimize/443-listener-state.txt"
    echo "$backup_dir"
}

stop_vpso_mux_services_for_restore() {
    echo -e "${YELLOW}▶ Остановка служб, связанных с vpso-mux, во избежание перезаписи работающего разделителя...${PLAIN}"
    systemctl stop vpso-mux-preflight >/dev/null 2>&1 || true
    systemctl stop vpso-mux >/dev/null 2>&1 || true
    sleep 1
}

rollback_last_entry_mode() {
    local backup_dir="${1:-}"
    local manual=0
    local old_mode=""
    if [[ -z "$backup_dir" ]]; then
        manual=1
        backup_dir=$(cat /etc/vps-optimize/sni-stack.last-backup 2>/dev/null)
    fi
    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        echo -e "${RED}❌ Не найдена резервная копия для отката режима входа.${PLAIN}"
        return 1
    fi
    if [[ -f "$backup_dir/vps-optimize/sni-stack.env" ]]; then
        old_mode=$(
            # shellcheck disable=SC1090
            unset ENTRY_MODE
            source "$backup_dir/vps-optimize/sni-stack.env" 2>/dev/null || true
            printf '%s' "${ENTRY_MODE:-nginx-stream}"
        )
        old_mode=$(normalize_entry_mode_name "$old_mode" 2>/dev/null || echo "nginx-stream")
    fi

    if [[ "$manual" -eq 1 ]]; then
        confirm_risk_action "Откатить последнее переключение режима входа 443" \
            "Конфигурации Nginx/Caddy/Xray/vpso-mux и состояние служб" \
            "Снова переключите режим входа или восстановите вручную из каталога резервной копии" \
            "Будет использована резервная копия ${backup_dir} для перезаписи текущей конфигурации входа." || return 1
    fi

    echo -e "${YELLOW}▶ Выполняется откат последнего переключения режима входа: ${backup_dir}${PLAIN}"
    stop_vpso_mux_services_for_restore
    restore_sni_stack_backup_files "$backup_dir" || { echo -e "${RED}❌ Не удалось восстановить файлы отката.${PLAIN}"; return 1; }
    systemctl daemon-reload >/dev/null 2>&1 || true
    load_sni_stack_env >/dev/null 2>&1 || true
    old_mode=${old_mode:-$(get_entry_mode)}

    if ! stop_public_443_entry_services_for_target "$old_mode"; then
        echo -e "${RED}❌ При откате не удалось остановить конфликтующие службы публичного 443, проверьте диагностику выше.${PLAIN}"
        return 1
    fi
    if ! apply_entry_mode_by_name "$old_mode" "$backup_dir"; then
        echo -e "${RED}❌ При откате на ${old_mode} не удалось восстановить публичный 443, проверьте диагностику выше.${PLAIN}"
        return 1
    fi
    set_entry_mode "$old_mode" >/dev/null 2>&1 || true
    write_single_443_engine_state "$(entry_mode_engine_name "$old_mode" 2>/dev/null || echo nginx-stream)" "$backup_dir"
    echo -e "${GREEN}✅ Откат выполнен к предыдущему режиму входа: ${old_mode}${PLAIN}"
}

apply_nginx_stream_mode() {
    local backup_dir="${1:-}"
    install_nginx_stream_stack || return 1
    harden_nginx_public_errors
    apply_web_proxy_configs_for_single_443 || return 1
    cleanup_old_nginx_sni_stream_configs
    write_nginx_sni_stream_config || return 1
    assert_nginx_stream_config_loaded "$NGINX_LISTEN_PORT" || return 1
    if [[ "$(current_web_proxy_engine)" == "caddy" ]]; then
        restart_web_proxy_for_single_443 || return 1
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    if ! systemctl restart nginx; then
        print_nginx_stream_failure_context "$NGINX_LISTEN_PORT"
        return 1
    fi
    if ! verify_public_443_listener_for_mode "nginx-stream"; then
        print_nginx_stream_failure_context "$NGINX_LISTEN_PORT"
        return 1
    fi
    probe_tls_sni_certificate "Nginx Stream SNI панели" "$(probe_host_for_listen_addr "$NGINX_LISTEN_ADDR")" "$NGINX_LISTEN_PORT" "$PANEL_DOMAIN" || return 1
    tcp_probe_host "$(web_proxy_engine_label) локальный TLS" "$(probe_host_for_listen_addr "$CADDY_LISTEN_ADDR")" "$CADDY_LISTEN_PORT" || return 1
    if xray_entry_service_name >/dev/null 2>&1; then
        restart_xray_entry_service || echo -e "${YELLOW}⚠️ Перезапуск Xray/3x-ui не удался; вход Nginx Stream/Web восстановлен, проверьте Xray-входящие отдельно.${PLAIN}"
    fi
    if ! tcp_probe_host "Локальный Xray/REALITY входящий" "$(probe_host_for_listen_addr "$XRAY_LISTEN_ADDR")" "$XRAY_LISTEN_PORT" 6 1; then
        echo -e "${YELLOW}⚠️ Вход Nginx Stream/Web восстановлен, но локальный Xray/REALITY входящий не отвечает.${PLAIN}"
        echo -e "${YELLOW}Проверьте в 3x-ui/Xray, что локальный входящий слушает ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}, или измените локальный порт Xray в скрипте.${PLAIN}"
    fi
    write_single_443_engine_state "nginx-stream" "$backup_dir"
}

apply_tcppeek_mode() {
    local backup_dir="${1:-}"
    local tmp_config
    require_vpso_mux_binary_for_cutover || return 1
    warn_if_public_bind "$(web_proxy_engine_label)" "$CADDY_LISTEN_ADDR" "$CADDY_LISTEN_PORT" || return 1
    warn_if_public_bind "Xray REALITY" "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT" || return 1
    apply_web_proxy_configs_for_single_443 || return 1
    restart_web_proxy_for_single_443 || return 1
    tmp_config="/etc/vps-optimize/vpso-mux.yaml.tmp.$$"
    write_vpso_mux_config_from_sni_stack "$NGINX_LISTEN_PORT" "$tmp_config" || return 1
    run_vpso_mux_config_check "$tmp_config" || { quarantine_path "$tmp_config" "/etc/vps-optimize/quarantine/vpso-mux" >/dev/null 2>&1 || true; return 1; }
    write_vpso_mux_systemd_service
    mv "$tmp_config" "$(vpso_mux_config_path)" || return 1
    systemctl enable vpso-mux >/dev/null 2>&1 || true
    if ! systemctl restart vpso-mux; then
        print_vpso_mux_failure_context "$NGINX_LISTEN_PORT"
        return 1
    fi
    if ! verify_public_443_listener_for_mode "tcp-peek"; then
        print_vpso_mux_failure_context "$NGINX_LISTEN_PORT"
        return 1
    fi
    probe_tls_sni_certificate "TCP Peek SNI панели" "$(probe_host_for_listen_addr "$NGINX_LISTEN_ADDR")" "$NGINX_LISTEN_PORT" "$PANEL_DOMAIN" || return 1
    tcp_probe_host "$(web_proxy_engine_label) локальный TLS" "$(probe_host_for_listen_addr "$CADDY_LISTEN_ADDR")" "$CADDY_LISTEN_PORT" || return 1
    if xray_entry_service_name >/dev/null 2>&1; then
        restart_xray_entry_service || return 1
    fi
    tcp_probe_host "Локальный Xray/REALITY входящий" "$(probe_host_for_listen_addr "$XRAY_LISTEN_ADDR")" "$XRAY_LISTEN_PORT" 6 1 || return 1
    write_single_443_engine_state "tcp-peek" "$backup_dir"
}

apply_xray_fallback_mode() {
    local backup_dir="${1:-}"
    apply_web_proxy_configs_for_single_443 || return 1
    restart_web_proxy_for_single_443 || return 1
    restart_xray_entry_service || return 1
    verify_public_443_listener_for_mode "xray-fallback" || return 1
    tcp_probe_host "$(web_proxy_engine_label) fallback бэкенд" "$(probe_host_for_listen_addr "$CADDY_LISTEN_ADDR")" "$CADDY_LISTEN_PORT" || return 1
    probe_tls_sni_certificate "Xray Fallback SNI панели" "$(probe_host_for_listen_addr "$NGINX_LISTEN_ADDR")" "$NGINX_LISTEN_PORT" "$PANEL_DOMAIN" || return 1
    write_single_443_engine_state "xray-fallback" "$backup_dir"
}

apply_entry_mode_by_name() {
    local target_mode="$1"
    local backup_dir="${2:-}"
    target_mode=$(normalize_entry_mode_name "$target_mode") || return 1
    case "$target_mode" in
        "nginx-stream") apply_nginx_stream_mode "$backup_dir" ;;
        "xray-fallback") apply_xray_fallback_mode "$backup_dir" ;;
        "tcp-peek") apply_tcppeek_mode "$backup_dir" ;;
    esac
}

select_initial_entry_mode() {
    local choice tcppeek_bootstrap
    ENTRY_MODE="nginx-stream"

    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Выберите режим входа 443 для первичной настройки${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${GREEN}  1. Режим Nginx Stream${PLAIN}       ${YELLOW}(по умолчанию стабильный, подходит для большинства)${PLAIN}"
    echo -e "${GREEN}  2. Режим Xray Fallback${PLAIN}      ${YELLOW}(требуется, чтобы вы уже подготовили публичный 443 основной входящий в Xray/3x-ui)${PLAIN}"
    echo -e "${GREEN}  3. Режим TCP Peek + Splice${PLAIN}  ${YELLOW}(при первой установке сначала предложит установить/использовать Nginx Stream, затем после предпроверки 8444 переключит)${PLAIN}"
    echo -e "${RED}  0. Отмена${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    read_trimmed choice "Выберите режим входа (по умолчанию 1): "
    case "${choice:-1}" in
        1) ENTRY_MODE="nginx-stream" ;;
        2) ENTRY_MODE="xray-fallback" ;;
        3)
            echo -e "${YELLOW}Для первого занятия 443 через TCP Peek необходимо сначала установить/использовать Nginx Stream для создания рабочей общей конфигурации и базовых Nginx/Caddy.${PLAIN}"
            echo -e "${YELLOW}Рекомендуемый порядок: сначала установите/используйте Nginx Stream для первичной установки, затем выполните предпроверку 8444 через [19] -> [16], и наконец переключитесь на TCP Peek через [5].${PLAIN}"
            read_trimmed tcppeek_bootstrap "Установить/использовать Nginx Stream для этой первичной установки? (Y/n, по умолчанию yes): "
            tcppeek_bootstrap="${tcppeek_bootstrap:-yes}"
            if is_yes "$tcppeek_bootstrap"; then
                ENTRY_MODE="nginx-stream"
            else
                echo -e "${BLUE}Первичная настройка отменена.${PLAIN}"
                return 1
            fi
            ;;
        0|q|Q) echo -e "${BLUE}Первичная настройка отменена.${PLAIN}"; return 1 ;;
        *) echo -e "${RED}❌ Неверный выбор.${PLAIN}"; return 1 ;;
    esac
    echo -e "${GREEN}✅ Выбран режим входа 443: ${ENTRY_MODE}${PLAIN}"
}

prepare_initial_entry_mode_dependencies() {
    local target_mode="$1"
    target_mode=$(normalize_entry_mode_name "$target_mode") || return 1
    case "$target_mode" in
        "tcp-peek")
            require_vpso_mux_binary_for_cutover || {
                echo -e "${YELLOW}На этапе первичной настройки ещё нет общей конфигурации для предпроверки 8444; сначала выберите Nginx Stream для первичной настройки, затем выполните [19] -> [16] предпроверку, и наконец переключитесь на TCP Peek через [5].${PLAIN}"
                return 1
            }
            ;;
        "xray-fallback")
            xray_entry_service_name >/dev/null 2>&1 || {
                echo -e "${RED}❌ Не обнаружен systemd-сервис xray/x-ui/3x-ui, невозможно выполнить первичную настройку в режиме xray-fallback.${PLAIN}"
                echo -e "${YELLOW}Сначала установите и настройте Xray/3x-ui основной входящий через [5 Панели, узлы и подписки], или выберите режим Nginx Stream / TCP Peek + Splice.${PLAIN}"
                return 1
            }
            print_xray_fallback_mode_explanation
            confirm_risk_action "Первичная настройка с использованием режима Xray Fallback" \
                "Публичный 443 будет приниматься существующим основным входящим Xray, обычный HTTPS fallback на выбранный Web-прокси" \
                "Вернитесь к первичной настройке и выберите режим Nginx Stream или TCP Peek + Splice" \
                "Убедитесь, что вы уже подготовили основной входящий Xray/3x-ui на публичный 443; скрипт не создаёт и не изменяет внутреннюю конфигурацию входящих 3x-ui/Xray." || return 1
            ;;
    esac
}

switch_entry_mode() {
    local target_mode="$1"
    local current_mode backup_dir planned_backup_dir yn
    load_sni_stack_env || return 1
    target_mode=$(normalize_entry_mode_name "$target_mode") || { echo -e "${RED}❌ Неверный целевой режим входа: ${target_mode}${PLAIN}"; return 1; }
    current_mode=$(get_entry_mode)

    if [[ "$target_mode" == "$current_mode" ]]; then
        read_trimmed yn "Текущий режим уже ${target_mode}, повторно применить? (y/n, по умолчанию n): "
        is_yes "$yn" && reapply_current_entry_mode
        return $?
    fi

    echo -e "${CYAN}Подготовка переключения режима входа 443: ${current_mode} -> ${target_mode}${PLAIN}"
    check_entry_mode_dependencies "$target_mode" || return 1
    if [[ "$target_mode" == "xray-fallback" ]]; then
        select_xray_fallback_main_route_for_switch || return 1
    fi
    planned_backup_dir=$(sni_stack_backup_dir)
    preview_entry_mode_cutover "$current_mode" "$target_mode" "$planned_backup_dir" || return 1
    guard_current_ssh_not_on_entry_port "Переключение режима входа 443" || return 1
    backup_dir=$(backup_entry_mode_config "$planned_backup_dir") || return 1
    if ! preflight_entry_mode_before_cutover "$target_mode"; then
        echo -e "${RED}❌ Предпроверка режима ${target_mode} не удалась, публичный 443 не переключён.${PLAIN}"
        return 1
    fi

    if ! stop_public_443_entry_services_for_target "$target_mode"; then
        echo -e "${RED}❌ Не удалось остановить текущие службы публичного 443, выполняется откат.${PLAIN}"
        rollback_last_entry_mode "$backup_dir"
        return 1
    fi

    if ! apply_entry_mode_by_name "$target_mode" "$backup_dir"; then
        echo -e "${RED}❌ Применение режима ${target_mode} не удалось, автоматический откат.${PLAIN}"
        rollback_last_entry_mode "$backup_dir"
        return 1
    fi

    ENTRY_MODE="$target_mode"
    save_sni_stack_env
    write_single_443_engine_state "$(entry_mode_engine_name "$target_mode")" "$backup_dir"
    echo -e "${GREEN}✅ Режим входа 443 переключён на: ${target_mode}${PLAIN}"
    show_current_entry_status
}

reapply_current_entry_mode() {
    local current_mode backup_dir planned_backup_dir assume_yes
    assume_yes="${1:-}"
    load_sni_stack_env || return 1
    current_mode=$(get_entry_mode)
    current_mode=$(normalize_entry_mode_name "$current_mode") || { echo -e "${RED}❌ Текущий ENTRY_MODE неверен: ${current_mode}${PLAIN}"; return 1; }
    echo -e "${CYAN}Повторное применение текущего режима входа 443: ${current_mode}${PLAIN}"
    guard_current_ssh_not_on_entry_port "Повторное применение режима входа 443" || return 1
    if [[ "$assume_yes" != "--yes" ]]; then
        planned_backup_dir=$(sni_stack_backup_dir)
        preview_entry_mode_cutover "$current_mode" "$current_mode" "$planned_backup_dir" || return 1
    fi
    check_entry_mode_dependencies "$current_mode" || return 1
    planned_backup_dir="${planned_backup_dir:-$(sni_stack_backup_dir)}"
    backup_dir=$(backup_entry_mode_config "$planned_backup_dir") || return 1
    if [[ "$current_mode" == "xray-fallback" ]]; then
        select_xray_fallback_main_route_for_switch || return 1
    fi
    if ! preflight_entry_mode_before_cutover "$current_mode"; then
        echo -e "${RED}❌ Предпроверка текущего режима ${current_mode} не удалась, публичный 443 не переприменён.${PLAIN}"
        return 1
    fi
    if ! stop_public_443_entry_services_for_target "$current_mode"; then
        echo -e "${RED}❌ Не удалось остановить текущие службы публичного 443, выполняется откат.${PLAIN}"
        rollback_last_entry_mode "$backup_dir"
        return 1
    fi
    if ! apply_entry_mode_by_name "$current_mode" "$backup_dir"; then
        echo -e "${RED}❌ Повторное применение текущего режима не удалось, автоматический откат.${PLAIN}"
        rollback_last_entry_mode "$backup_dir"
        return 1
    fi
    ENTRY_MODE="$current_mode"
    save_sni_stack_env
    write_single_443_engine_state "$(entry_mode_engine_name "$current_mode")" "$backup_dir"
    echo -e "${GREEN}✅ Текущий режим входа переприменён: ${current_mode}${PLAIN}"
    show_current_entry_status
}

view_vpso_mux_logs() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}📜 Логи vpso-mux${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    journalctl -u vpso-mux -n 120 --no-pager 2>/dev/null || echo "Не удалось прочитать логи vpso-mux."
}

entry_mode_supports_xray_sni_routes() {
    local mode="$1"
    mode=$(normalize_entry_mode_name "$mode" 2>/dev/null) || return 1
    [[ "$mode" == "nginx-stream" || "$mode" == "tcp-peek" ]]
}

# ---------------------------------------------------------
# Module: sni_stack_health.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Проверки состояния единого входа 443, HTTP/TLS пробы и подсказки по подпискам.

print_443_health_status_code_hints() {
    echo -e "${BOLD}Подсказки по кодам состояния${PLAIN}"
    echo -e "  - 403/401: возможно, веб-белый список, CDN/WAF, защита источника, политика Host/SNI или аутентификация бэкенда."
    echo -e "  - 502: возможно, Caddy не может подключиться к порту бэкенда."
    echo -e "  - 525/526: возможно, ошибка TLS или проверки сертификата между CDN и источником."
    echo -e "  - Таймаут: возможно, проблемы с прослушиванием 443, брандмауэром, безопасной группой, службой входа."
}

print_443_health_reality_notes() {
    echo -e "${BOLD}Примечания по проверке REALITY${PLAIN}"
    echo -e "  - Не требуйте, чтобы REALITY serverName/dest попадал в Web-прокси."
    echo -e "  - Не требуйте, чтобы сертификат хоста перекрывал REALITY serverName."
    echo -e "  - REALITY должен проверять, что внешний целевой сайт действительно доступен и TLS-характеристики стабильны."
    echo -e "  - Проверка SNI/serverName для обычных TLS-узлов и REALITY-узлов должна различаться."
}

print_web_domain_http_status() {
    local label="$1"
    local domain="$2"
    local path="${3:-/}"
    local url code

    [[ -n "$domain" ]] || return 0
    path=$(normalize_path_prefix "$path")
    url="https://${domain}${path}"

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${label}: ${url} -> ${YELLOW}Не проверено, curl не установлен${PLAIN}"
        return 0
    fi

    code=$(curl -k -L -o /dev/null -sS --connect-timeout 6 --max-time 12 -w '%{http_code}' "$url" 2>/dev/null) || code="timeout"
    [[ -z "$code" || "$code" == "000" ]] && code="timeout"
    echo -e "${label}: ${url} -> ${code}"
}

print_domain_cert_file_status() {
    local domain="$1"
    local cert key root_cert root_key

    [[ -n "$domain" ]] || return 0
    cert="/etc/caddy/certs/${domain}.crt"
    key="/etc/caddy/certs/${domain}.key"
    root_cert="/root/cert/${domain}.crt"
    root_key="/root/cert/${domain}.key"

    echo -e "${CYAN}${domain}${PLAIN}"
    [[ -s "$cert" ]] && echo -e "  ${GREEN}✅ Сертификат существует: ${cert}${PLAIN}" || echo -e "  ${YELLOW}⚠️ Сертификат отсутствует или пуст: ${cert}${PLAIN}"
    [[ -s "$key" ]] && echo -e "  ${GREEN}✅ Закрытый ключ существует: ${key}${PLAIN}" || echo -e "  ${YELLOW}⚠️ Закрытый ключ отсутствует или пуст: ${key}${PLAIN}"

    if [[ -L "$root_cert" && "$(readlink "$root_cert" 2>/dev/null)" == "$cert" && -e "$root_cert" ]]; then
        echo -e "  ${GREEN}✅ Символическая ссылка сертификата /root/cert нормальна: ${root_cert} -> ${cert}${PLAIN}"
    else
        echo -e "  ${YELLOW}⚠️ Символическая ссылка сертификата /root/cert отсутствует или неверна: ${root_cert}${PLAIN}"
    fi

    if [[ -L "$root_key" && "$(readlink "$root_key" 2>/dev/null)" == "$key" && -e "$root_key" ]]; then
        echo -e "  ${GREEN}✅ Символическая ссылка закрытого ключа /root/cert нормальна: ${root_key} -> ${key}${PLAIN}"
    else
        echo -e "  ${YELLOW}⚠️ Символическая ссылка закрытого ключа /root/cert отсутствует или неверна: ${root_key}${PLAIN}"
    fi
}

print_xray_route_health_list() {
    local mode="$1"
    local i sni addr port line main_idx status

    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Не настроены правила маршрутизации Xray-входящих: $(xray_sni_routes_path)${PLAIN}"
        return 0
    fi

    main_idx=$(xray_fallback_main_route_index 2>/dev/null || true)
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        sni="${XRAY_SNI_ROUTE_SNIS[$i]}"
        addr="${XRAY_SNI_ROUTE_ADDRS[$i]}"
        port="${XRAY_SNI_ROUTE_PORTS[$i]}"
        [[ -n "$sni" ]] || continue

        if [[ "$mode" == "xray-fallback" ]]; then
            if [[ -n "$main_idx" && "$i" == "$main_idx" ]]; then
                status="основной входящий xray-fallback, действует в текущем режиме"
            else
                status="сохранён, в текущем режиме xray-fallback не действует"
            fi
        else
            status="текущий режим поддерживает маршрутизацию по SNI"
        fi

        echo -e "${CYAN}${sni}${PLAIN} -> ${addr}:${port} (${status})"
        if [[ "${CADDY_LISTEN_PORT:-}" == "$port" ]]; then
            echo -e "${RED}  ❌ Конфликт с локальным портом Web-прокси ${CADDY_LISTEN_PORT}.${PLAIN}"
        fi
        line=$(xray_route_listen_line_by_addr_port "$addr" "$port")
        if [[ -n "$line" ]]; then
            echo -e "${GREEN}  ✅ Порт слушается: ${line}${PLAIN}"
            if echo "$line" | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):'"${port}"'[[:space:]]'; then
                echo -e "${YELLOW}  ⚠️ Обнаружено прослушивание на 0.0.0.0/[::], есть риск публичного доступа, рекомендуется изменить на 127.0.0.1.${PLAIN}"
            fi
        else
            echo -e "${YELLOW}  ⚠️ ${addr}:${port} не слушается, сначала создайте и включите соответствующий входящий в 3x-ui.${PLAIN}"
        fi
    done
}

print_443_health_connlimit_scope_notice() {
    local marker runtime_rules saved_rules rules locations source_count

    echo -e "------------------------------------------------"
    echo -e "${BOLD}Ограничение параллельных соединений на порт${PLAIN}"

    if ! declare -F port_connlimit_comment >/dev/null || ! declare -F port_connlimit_runtime_rule_fingerprints >/dev/null || ! declare -F port_connlimit_known_saved_rule_fingerprints >/dev/null; then
        echo -e "${BLUE}Вспомогательные функции connlimit не подключены, проверка ограничений пропущена.${PLAIN}"
        return 0
    fi

    marker=$(port_connlimit_comment 443)
    runtime_rules=$(port_connlimit_runtime_rule_fingerprints | grep -F "$marker" || true)
    saved_rules=$(port_connlimit_known_saved_rule_fingerprints | grep -F "$marker" || true)
    rules=$(printf '%s\n%s\n' "$runtime_rules" "$saved_rules" | grep -F "$marker" || true)

    if [[ -z "$rules" ]]; then
        echo -e "${BLUE}Не обнаружены правила connlimit для публичного 443, добавленные скриптом.${PLAIN}"
        return 0
    fi

    locations=""
    [[ -n "$runtime_rules" ]] && locations="в памяти"
    [[ -n "$saved_rules" ]] && locations="${locations:+${locations},}в сохранённых файлах"
    source_count=$(printf '%s\n' "$rules" | grep -c . || true)

    echo -e "${YELLOW}Обнаружены правила connlimit для публичного 443, добавленные скриптом: ${marker}${PLAIN}"
    echo -e "Обнаружены в: ${locations:-неизвестно}; количество совпадений: ${source_count}"
    echo -e "${RED}Область действия: это ограничение действует на весь публичный вход 443 и не может быть точным для конкретного SNI, Xray/3x-ui входящего, UUID или пользователя.${PLAIN}"
    echo -e "${YELLOW}Если какой-то узел, подписка или сайт затронуты, проверьте/удалите правила connlimit для публичного 443 в [8 Управление брандмауэром] -> [5 Ограничение параллельных соединений на порт].${PLAIN}"
}

sni_stack_health_check_enhanced() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧪 Расширенная проверка цепочки 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    detect_current_entry_status

    local mode web_backend web_label xray_backend panel_backend sub_backend site_backend route_count ranges i domain public_443_lines mux_config mux_service
    mode="$ENTRY_STATUS_MODE"
    web_backend=$(web_proxy_backend)
    web_label=$(web_proxy_engine_label)
    xray_backend=$(format_hostport "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT")
    panel_backend=$(format_hostport "$PANEL_LISTEN_ADDR" "$PANEL_LISTEN_PORT")
    sub_backend=$(format_hostport "$SUB_LISTEN_ADDR" "$SUB_LISTEN_PORT")
    mux_config=$(vpso_mux_config_path)
    mux_service="/etc/systemd/system/$(vpso_mux_service_name)"
    route_count=$((2 + ${#SITE_DOMAINS[@]} + ${#TCP_ROUTE_SNIS[@]} + ${#XRAY_SNI_ROUTE_SNIS[@]}))

    echo -e "${BOLD}Состояние входа${PLAIN}"
    echo -e "Текущий ENTRY_MODE: ${GREEN}${mode}${PLAIN}"
    print_entry_mode_compat_notice
    echo -e "Фактическая служба, слушающая публичный 443: ${ENTRY_STATUS_LISTENER_PROCESS}"
    public_443_lines=$(ss -lntp 2>/dev/null | grep -E '(:443[[:space:]]|:443$)' || true)
    echo -e "${public_443_lines:-Не слушается или недостаточно прав}"
    if [[ "$ENTRY_STATUS_CONSISTENT" == "yes" ]]; then
        echo -e "Режим конфигурации и фактическое прослушивание: ${GREEN}согласовано${PLAIN}"
    else
        echo -e "Режим конфигурации и фактическое прослушивание: ${YELLOW}не согласовано${PLAIN}"
        echo -e "${YELLOW}Рекомендуется повторно применить текущий режим входа.${PLAIN}"
    fi
    echo -e "Состояние nginx: ${ENTRY_STATUS_NGINX_SERVICE}"
    echo -e "Состояние Xray/3x-ui: ${ENTRY_STATUS_XRAY_SERVICE}"
    echo -e "Состояние TCP Peek + Splice: ${ENTRY_STATUS_TCPPEEK_SERVICE}"
    if [[ "$(current_web_proxy_engine)" == "caddy" ]]; then
        echo -e "Состояние caddy: $(service_status_compact caddy)"
    fi
    if [[ -f "$mux_config" ]]; then
        echo -e "Правила маршрутизации TCP Peek + Splice: ${GREEN}существуют ${mux_config}${PLAIN}"
    else
        echo -e "Правила маршрутизации TCP Peek + Splice: ${YELLOW}не найдены ${mux_config}${PLAIN}"
    fi
    if [[ -f "$mux_service" ]]; then
        echo -e "systemd разделителя vpso-mux: ${GREEN}существует ${mux_service}${PLAIN}"
    else
        echo -e "systemd разделителя vpso-mux: ${YELLOW}не найден ${mux_service}${PLAIN}"
    fi
    print_443_health_connlimit_scope_notice

    echo -e "------------------------------------------------"
    echo -e "${BOLD}Локальные слушатели${PLAIN}"
    echo -e "Локальный порт Web-прокси: ${web_backend} (${web_label})"
    get_listen_line_by_port "$CADDY_LISTEN_PORT" | grep -q "$CADDY_LISTEN_ADDR" && echo -e "${GREEN}✅ ${web_label} ожидается слушать ${CADDY_LISTEN_ADDR}:${CADDY_LISTEN_PORT}${PLAIN}" || echo -e "${YELLOW}⚠️ ${web_label} адрес прослушивания требует проверки: $(get_listen_line_by_port "$CADDY_LISTEN_PORT")${PLAIN}"
    echo -e "Локальный порт Xray: ${xray_backend}"
    get_listen_line_by_port "$XRAY_LISTEN_PORT" | grep -q "$XRAY_LISTEN_ADDR" && echo -e "${GREEN}✅ Xray ожидается слушать ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}${PLAIN}" || echo -e "${YELLOW}⚠️ Xray адрес прослушивания требует проверки: $(get_listen_line_by_port "$XRAY_LISTEN_PORT")${PLAIN}"
    if [[ "$ENTRY_STATUS_LISTENER" == "xray" ]]; then
        echo -e "Публичный порт Xray: ${GREEN}публичный 443 сейчас слушается Xray${PLAIN}"
    else
        echo -e "Публичный порт Xray: Xray, слушающий публичный 443, не обнаружен"
    fi

    echo -e "------------------------------------------------"
    echo -e "${BOLD}Доступность бэкендов сайтов${PLAIN}"
    if [[ ${#SITE_DOMAINS[@]} -eq 0 ]]; then
        echo "Пользовательские сайты/прокси бэкенды не настроены."
    else
        for i in "${!SITE_DOMAINS[@]}"; do
            domain="${SITE_DOMAINS[$i]}"
            [[ -n "$domain" ]] || continue
            probe_backend_target "Бэкенд сайта ${domain}" "${SITE_BACKEND_ADDRS[$i]}" "${SITE_BACKEND_PORTS[$i]}" || true
        done
    fi

    echo -e "------------------------------------------------"
    echo -e "${BOLD}Правила маршрутизации Xray-входящих${PLAIN}"
    if entry_mode_supports_xray_sni_routes "$mode"; then
        echo -e "Текущий режим входа поддерживает правила маршрутизации Xray-входящих: ${GREEN}поддерживает${PLAIN}"
    else
        echo -e "Текущий режим входа поддерживает правила маршрутизации Xray-входящих: ${YELLOW}не поддерживает/не действует${PLAIN}"
    fi
    if [[ "$mode" == "xray-fallback" ]]; then
        echo -e "${YELLOW}Сейчас режим Xray Fallback, правила маршрутизации нескольких SNI из управления Xray-входящими не действуют.${PLAIN}"
        echo -e "${YELLOW}Если нужна маршрутизация на несколько локальных Xray-входящих, переключитесь на режим Nginx Stream или TCP Peek + Splice.${PLAIN}"
        echo -e "${YELLOW}Обычный HTTPS-трафик сначала попадает в Xray, затем fallback на выбранный Web-прокси; код 403/отказ в доступе следует в первую очередь проверять на веб-белых списках, CDN/WAF, защите источника, ограничениях Cloudflare или политиках Host/SNI.${PLAIN}"
        print_xray_fallback_main_route_summary
    fi
    print_xray_route_health_list "$mode"

    echo -e "------------------------------------------------"
    echo -e "${BOLD}Состояние веб-белых списков${PLAIN}"
    print_sni_ip_whitelist_summary
    echo -e "Белые списки для Xray-узлов: не поддерживаются/не включены"

    echo -e "------------------------------------------------"
    echo -e "${BOLD}Файлы сертификатов и символические ссылки /root/cert${PLAIN}"
    print_domain_cert_file_status "$PANEL_DOMAIN"
    for i in "${!SITE_DOMAINS[@]}"; do
        domain="${SITE_DOMAINS[$i]}"
        [[ -n "$domain" ]] || continue
        print_domain_cert_file_status "$domain"
    done

    echo -e "------------------------------------------------"
    echo -e "${BOLD}HTTP-статус веб-доменов${PLAIN}"
    print_web_domain_http_status "Путь панели" "$PANEL_DOMAIN" "$PANEL_WEB_PATH"
    print_web_domain_http_status "Путь обычной подписки" "$PANEL_DOMAIN" "$SUB_URI_PATH"
    print_web_domain_http_status "Путь Clash/Mihomo" "$PANEL_DOMAIN" "$CLASH_URI_PATH"
    for i in "${!SITE_DOMAINS[@]}"; do
        domain="${SITE_DOMAINS[$i]}"
        [[ -n "$domain" ]] || continue
        print_web_domain_http_status "Домен сайта" "$domain" "/"
    done
    print_443_health_status_code_hints

    echo -e "------------------------------------------------"
    echo -e "${BOLD}Сводка маршрутов${PLAIN}"
    echo -e "default_backend в настоящее время указывает на: ${xray_backend}"
    echo -e "Количество маршрутов: ${route_count}"
    echo -e "Политика для неизвестного SNI: default_backend -> ${xray_backend}"
    ranges=$(sni_ip_whitelist_ranges_for_domain "$PANEL_DOMAIN")
    echo -e "web panel: ${PANEL_DOMAIN}${PANEL_WEB_PATH} -> ${web_label} ${web_backend} -> бэкенд панели ${panel_backend}"
    echo -e "web subscription: ${PANEL_DOMAIN}${SUB_URI_PATH} -> ${web_label} ${web_backend} -> бэкенд подписки ${sub_backend}"
    echo -e "web clash/mihomo: ${PANEL_DOMAIN}${CLASH_URI_PATH} -> ${web_label} ${web_backend} -> бэкенд подписки ${sub_backend}"
    echo -e "route panel: ${PANEL_DOMAIN} -> ${web_backend} белый список=$([[ -n "$ranges" ]] && echo да || echo нет)"
    for i in "${!SITE_DOMAINS[@]}"; do
        domain="${SITE_DOMAINS[$i]}"
        [[ -n "$domain" ]] || continue
        ranges=$(sni_ip_whitelist_ranges_for_domain "$domain")
        site_backend=$(format_hostport "${SITE_BACKEND_ADDRS[$i]}" "${SITE_BACKEND_PORTS[$i]}")
        echo -e "web site: ${domain}/ -> ${web_label} ${web_backend} -> бэкенд сайта ${site_backend}"
        echo -e "route site: ${domain} -> ${web_backend} белый список=$([[ -n "$ranges" ]] && echo да || echo нет)"
    done
    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        domain="${TCP_ROUTE_SNIS[$i]}"
        [[ -n "$domain" ]] || continue
        echo -e "route tcp: ${domain} -> $(format_hostport "${TCP_ROUTE_ADDRS[$i]}" "${TCP_ROUTE_PORTS[$i]}") белый список=нет (не веб-домен)"
    done
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        domain="${XRAY_SNI_ROUTE_SNIS[$i]}"
        [[ -n "$domain" ]] || continue
        echo -e "route xray: ${domain} -> $(format_hostport "${XRAY_SNI_ROUTE_ADDRS[$i]}" "${XRAY_SNI_ROUTE_PORTS[$i]}") белый список=нет"
    done
    echo -e "route reality: ${REALITY_SNI} -> ${xray_backend} белый список=нет"
    print_443_health_reality_notes

    echo -e "------------------------------------------------"
    echo -e "Последние 20 строк лога vpso-mux:"
    journalctl -u vpso-mux -n 20 --no-pager 2>/dev/null || echo "Не удалось прочитать логи vpso-mux."
    echo -e "------------------------------------------------"
    echo -e "Тестовые команды:"
    echo -e "  openssl s_client -connect SERVER_IP:${NGINX_LISTEN_PORT} -servername ${PANEL_DOMAIN}"
    [[ ${#SITE_DOMAINS[@]} -gt 0 ]] && echo -e "  openssl s_client -connect SERVER_IP:${NGINX_LISTEN_PORT} -servername ${SITE_DOMAINS[0]}"
    echo -e "  openssl s_client -connect SERVER_IP:${NGINX_LISTEN_PORT} -servername random.example.com"
}

check_sni_stack_subscription_hint() {
    local web_label

    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔎 Проверка ссылок подписок и External Proxy${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    web_label=$(web_proxy_engine_label)
    echo -e "3x-ui v3.4.0 и новее: боковое меню слева -> Hosts / Хосты -> Добавить Host:"
    echo -e "  Входящий: выберите соответствующий REALITY или локальный Xray-входящий"
    echo -e "  Адрес: ваш домен узла или IP сервера"
    echo -e "  Порт: ${NGINX_LISTEN_PORT}"
    echo -e "  Security/SNI/Fingerprint/ALPN: в соответствии с фактическими значениями этого входящего и клиента"
    echo -e ""
    echo -e "3x-ui v3.3.1 и старше: включите External Proxy в REALITY-входящем и убедитесь:"
    echo -e "  Тип: такой же"
    echo -e "  Адрес: ваш домен узла или IP сервера"
    echo -e "  Порт: ${NGINX_LISTEN_PORT}"
    echo -e "${YELLOW}Подсказка: этот туториал рекомендует Cloudflare — серая туча / DNS only. Адрес REALITY-узла должен напрямую указывать на VPS, можно использовать домен с серой тучей или публичный IP сервера.${PLAIN}"
    echo -e ""
    echo -e "После копирования ссылки узла вы должны увидеть:"
    echo -e "  vless://...@адрес_узла:${NGINX_LISTEN_PORT}?security=reality&sni=${REALITY_SNI}&..."
    echo -e ""
    echo -e "Публичный вход для подписок должен быть:"
    echo -e "  Обычная подписка:      https://${PANEL_DOMAIN}${SUB_URI_PATH}"
    echo -e "  Clash/Mihomo:  https://${PANEL_DOMAIN}${CLASH_URI_PATH}"
    echo -e "${YELLOW}Не указывайте публичный адрес подписки как :${SUB_LISTEN_PORT}; этот порт предназначен только для локального Web-прокси (${web_label}), не является публичным входом.${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}Если в ссылке всё ещё указан :${XRAY_LISTEN_PORT}, для 3x-ui v3.4.0+ проверьте Hosts/Хосты; для старых версий — External Proxy в входящем.${PLAIN}"
}

# ---------------------------------------------------------
# Module: sni_stack_profiles.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Редактирование профилей единого входа 443 и вспомогательные функции повторного применения.

save_and_offer_reapply_sni_stack() {
    local yn env_file env_backup
    env_file="/etc/vps-optimize/sni-stack.env"
    env_backup=""
    if [[ -f "$env_file" ]]; then
        env_backup="${env_file}.pre_reapply_$(date +%Y%m%d_%H%M%S)"
        cp -p "$env_file" "$env_backup" 2>/dev/null || env_backup=""
    fi
    save_sni_stack_env
    echo -e "${GREEN}✅ Новые параметры единого входа 443 сохранены.${PLAIN}"
    echo -e "${YELLOW}Примечание: после сохранения необходимо повторно применить, чтобы Nginx/Caddy использовали новые домены, порты или пути.${PLAIN}"
    read_trimmed yn "Повторно применить и перезапустить Nginx/Caddy сейчас? введите yes для продолжения, Enter для отмены (регистр не важен): "
    if is_yes "$yn"; then
        if ! reapply_sni_stack_from_env --yes; then
            if [[ -n "$env_backup" && -f "$env_backup" ]]; then
                cp -p "$env_backup" "$env_file" 2>/dev/null || true
                echo -e "${YELLOW}⚠️ Восстановлен файл параметров до повторного применения: ${env_backup}${PLAIN}"
            fi
            return 1
        fi
    else
        echo -e "${YELLOW}Позже вы можете выполнить [19] -> [6] для повторного применения последней конфигурации.${PLAIN}"
        [[ -n "$env_backup" ]] && echo -e "${CYAN}Резервная копия параметров до изменения сохранена: ${env_backup}${PLAIN}"
    fi
}

restart_xui_panel_services_after_setting_update() {
    local service_name restarted=0
    for service_name in x-ui 3x-ui x-panel; do
        if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q . || systemctl status "$service_name" >/dev/null 2>&1; then
            if systemctl restart "$service_name" >/dev/null 2>&1; then
                restarted=1
            else
                echo -e "${YELLOW}⚠️ Не удалось перезапустить ${service_name}, перезапустите панель вручную позже.${PLAIN}"
            fi
        fi
    done
    [[ "$restarted" -eq 1 ]] && echo -e "${GREEN}✅ Панель 3x-ui/x-ui перезапущена, настройки домена вступили в силу.${PLAIN}"
}

update_xui_panel_domain_settings_for_single_443() {
    local old_domain="$1"
    local new_domain="$2"
    local db_path table_name backup_dir backup_file sql
    local checked=0 updated=0 failed=0 timestamp

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${CYAN}▶ Установка sqlite3 для синхронизации настроек домена панели 3x-ui...${PLAIN}"
        install_pkg sqlite3 sqlite >/dev/null 2>&1 || true
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ sqlite3 не обнаружен, автоматическая синхронизация настроек домена панели 3x-ui пропущена.${PLAIN}"
        return 0
    fi

    timestamp=$(date +%Y%m%d_%H%M%S)
    while IFS= read -r db_path; do
        [[ -f "$db_path" ]] || continue
        table_name=$(sqlite3 "$db_path" "select name from sqlite_master where type='table' and name in ('settings','setting') order by case name when 'settings' then 0 else 1 end limit 1;" 2>/dev/null || true)
        [[ "$table_name" == "settings" || "$table_name" == "setting" ]] || continue
        checked=1

        backup_dir="/root/x-ui-backups"
        mkdir -p "$backup_dir"
        backup_file="${backup_dir}/x-ui.db.panel_domain_${timestamp}.bak"
        if ! sqlite3 "$db_path" ".backup '${backup_file}'" >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠️ Не удалось создать резервную копию базы данных 3x-ui, синхронизация пропущена: ${db_path}${PLAIN}"
            failed=1
            continue
        fi

        sql="
update ${table_name} set value='' where lower(key)='webdomain';
update ${table_name} set value='${new_domain}' where lower(key)='subdomain';
update ${table_name} set value='https://${new_domain}${SUB_URI_PATH}' where lower(key)='suburi';
update ${table_name} set value='https://${new_domain}${CLASH_URI_PATH}' where lower(key)='subclashuri';
update ${table_name} set value=replace(replace(value,'https://${old_domain}','https://${new_domain}'),'http://${old_domain}','https://${new_domain}') where lower(key)='subjsonuri' and value like '%${old_domain}%';
"
        if sqlite3 "$db_path" "$sql" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Настройки домена панели/подписки 3x-ui синхронизированы: ${db_path}${PLAIN}"
            echo -e "${CYAN}Резервная копия базы данных: ${backup_file}${PLAIN}"
            updated=1
        else
            echo -e "${YELLOW}⚠️ Синхронизация настроек домена панели 3x-ui не удалась: ${db_path}${PLAIN}"
            failed=1
        fi
    done < <(find_xui_database_candidates)

    [[ "$updated" -eq 1 ]] && restart_xui_panel_services_after_setting_update
    if [[ "$failed" -eq 1 ]]; then
        echo -e "${RED}❌ Настройки домена панели 3x-ui не полностью синхронизированы, изменение домена панели 443 остановлено.${PLAIN}"
        return 1
    fi
    if [[ "$checked" -eq 0 ]]; then
        echo -e "${YELLOW}⚠️ База данных 3x-ui не найдена, внутренняя синхронизация домена панели 3x-ui пропущена.${PLAIN}"
    fi
    return 0
}

edit_sni_stack_panel_subscription_profile() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Изменение портов и путей панели 3x-ui / подписки${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    echo -e "${YELLOW}Применяется, если вы изменили порт панели, порт подписки, путь обычной подписки или путь Clash/Mihomo в 3x-ui.${PLAIN}"
    echo -e "${YELLOW}Примечание: для новых установок 3x-ui 3.x выбирайте Skip SSL / не запрашивать SSL; для 2.x или старых конфигураций по-прежнему нужно очищать пути сертификатов панели и подписки, чтобы Caddy мог работать по HTTP.${PLAIN}"
    echo -e "${YELLOW}Перед изменением сначала сохраните соответствующие настройки в панели 3x-ui, затем синхронизируйте скрипт.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "Текущий бэкенд панели: ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "Текущий публичный путь панели: ${PANEL_WEB_PATH}"
    echo -e "Текущий бэкенд подписки: ${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT}"
    echo -e "Текущий путь обычной подписки: ${SUB_URI_PATH}"
    echo -e "Текущий путь Clash/Mihomo: ${CLASH_URI_PATH}"
    echo -e "------------------------------------------------"

    PANEL_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания панели 3x-ui" "$PANEL_LISTEN_ADDR")
    PANEL_LISTEN_PORT=$(ask_with_default "Порт панели 3x-ui" "$PANEL_LISTEN_PORT")
    PANEL_WEB_PATH=$(normalize_path_prefix "$(ask_with_default "Публичный путь панели 3x-ui / webBasePath" "$PANEL_WEB_PATH")")
    SUB_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания службы подписки 3x-ui" "$SUB_LISTEN_ADDR")
    SUB_LISTEN_PORT=$(ask_with_default "Порт службы подписки 3x-ui" "$SUB_LISTEN_PORT")
    SUB_URI_PATH=$(normalize_path_prefix "$(ask_with_default "Префикс пути обычной подписки (без Subscription клиента, рекомендуется /sub/)" "$SUB_URI_PATH")")
    CLASH_URI_PATH=$(normalize_path_prefix "$(ask_with_default "Префикс пути подписки Clash/Mihomo (без Subscription клиента, рекомендуется /clash/)" "$CLASH_URI_PATH")")

    is_valid_listen_addr "$PANEL_LISTEN_ADDR" || { echo -e "${RED}❌ Неверный адрес панели: ${PANEL_LISTEN_ADDR}${PLAIN}"; return 1; }
    is_valid_listen_addr "$SUB_LISTEN_ADDR" || { echo -e "${RED}❌ Неверный адрес подписки: ${SUB_LISTEN_ADDR}${PLAIN}"; return 1; }
    is_valid_port "$PANEL_LISTEN_PORT" || { echo -e "${RED}❌ Неверный порт панели: ${PANEL_LISTEN_PORT}${PLAIN}"; return 1; }
    is_valid_port "$SUB_LISTEN_PORT" || { echo -e "${RED}❌ Неверный порт подписки: ${SUB_LISTEN_PORT}${PLAIN}"; return 1; }
    is_valid_path_prefix "$PANEL_WEB_PATH" || { echo -e "${RED}❌ Неверный публичный путь панели: ${PANEL_WEB_PATH}${PLAIN}"; return 1; }
    is_valid_path_prefix "$SUB_URI_PATH" || { echo -e "${RED}❌ Неверный путь обычной подписки: ${SUB_URI_PATH}${PLAIN}"; return 1; }
    is_valid_path_prefix "$CLASH_URI_PATH" || { echo -e "${RED}❌ Неверный путь Clash/Mihomo: ${CLASH_URI_PATH}${PLAIN}"; return 1; }
    if [[ "$PANEL_WEB_PATH" == "$SUB_URI_PATH" || "$PANEL_WEB_PATH" == "$CLASH_URI_PATH" || "$SUB_URI_PATH" == "$CLASH_URI_PATH" ]]; then
        echo -e "${RED}❌ Пути панели, обычной подписки и Clash/Mihomo не могут совпадать.${PLAIN}"
        return 1
    fi
    warn_if_public_bind "Панель 3x-ui" "$PANEL_LISTEN_ADDR" "$PANEL_LISTEN_PORT" || return 1
    warn_if_public_bind "Служба подписки 3x-ui" "$SUB_LISTEN_ADDR" "$SUB_LISTEN_PORT" || return 1

    save_and_offer_reapply_sni_stack
}

edit_sni_stack_reality_profile() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Изменение локального прослушивания REALITY и поддельного SNI${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    echo -e "${YELLOW}Применяется, если вы изменили порт прослушивания, адрес прослушивания или поддельный SNI в REALITY-входящем 3x-ui.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "Текущий REALITY: ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
    echo -e "Текущий REALITY SNI: ${REALITY_SNI}"
    echo -e "------------------------------------------------"

    local reality_sni_input
    XRAY_LISTEN_ADDR=$(ask_with_default "Локальный адрес прослушивания Xray/3x-ui REALITY" "$XRAY_LISTEN_ADDR")
    XRAY_LISTEN_PORT=$(ask_with_default "Локальный порт прослушивания Xray/3x-ui REALITY" "$XRAY_LISTEN_PORT")
    reality_sni_input=$(ask_with_default "Поддельный REALITY SNI" "$REALITY_SNI")
    REALITY_SNI=$(normalize_domain_input "$reality_sni_input")

    is_valid_listen_addr "$XRAY_LISTEN_ADDR" || { echo -e "${RED}❌ Неверный адрес REALITY: ${XRAY_LISTEN_ADDR}${PLAIN}"; return 1; }
    is_valid_port "$XRAY_LISTEN_PORT" || { echo -e "${RED}❌ Неверный порт REALITY: ${XRAY_LISTEN_PORT}${PLAIN}"; return 1; }
    is_valid_domain "$REALITY_SNI" || { print_domain_validation_error "REALITY SNI" "$reality_sni_input" "$REALITY_SNI"; return 1; }
    [[ "$REALITY_SNI" == "$PANEL_DOMAIN" ]] && { echo -e "${RED}❌ REALITY SNI не может быть доменом панели.${PLAIN}"; return 1; }
    local existing
    for existing in "${SITE_DOMAINS[@]}" "${TCP_ROUTE_SNIS[@]}" "${XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ "$REALITY_SNI" == "$existing" ]] && { echo -e "${RED}❌ REALITY SNI не может совпадать с другими доменами маршрутизации 443: ${existing}${PLAIN}"; return 1; }
    done
    warn_if_public_bind "Xray REALITY" "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT" || return 1
    probe_reality_sni "$REALITY_SNI" || return 1

    save_and_offer_reapply_sni_stack
}

edit_sni_stack_entry_profile() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Изменение публичного входа 443 / локального TLS Web-прокси${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    local web_label
    web_label=$(web_proxy_engine_label)
    echo -e "${YELLOW}Применяется для изменения публичного порта входа, локального TLS-порта Web-прокси или исправления адреса прослушивания. Обычным пользователям рекомендуется оставить по умолчанию.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "Текущий публичный вход: ${NGINX_LISTEN_ADDR}:${NGINX_LISTEN_PORT}"
    echo -e "Текущий локальный TLS ${web_label}: ${CADDY_LISTEN_ADDR}:${CADDY_LISTEN_PORT}"
    echo -e "------------------------------------------------"

    NGINX_LISTEN_ADDR=$(ask_with_default "Публичный адрес прослушивания Nginx" "$NGINX_LISTEN_ADDR")
    NGINX_LISTEN_PORT=$(ask_with_default "Публичный порт прослушивания Nginx" "$NGINX_LISTEN_PORT")
    CADDY_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания ${web_label}" "$CADDY_LISTEN_ADDR")
    CADDY_LISTEN_PORT=$(ask_with_default "Порт прослушивания ${web_label}" "$CADDY_LISTEN_PORT")

    is_valid_listen_addr "$NGINX_LISTEN_ADDR" || { echo -e "${RED}❌ Неверный адрес Nginx: ${NGINX_LISTEN_ADDR}${PLAIN}"; return 1; }
    is_valid_listen_addr "$CADDY_LISTEN_ADDR" || { echo -e "${RED}❌ Неверный адрес Web-прокси: ${CADDY_LISTEN_ADDR}${PLAIN}"; return 1; }
    is_valid_port "$NGINX_LISTEN_PORT" || { echo -e "${RED}❌ Неверный порт Nginx: ${NGINX_LISTEN_PORT}${PLAIN}"; return 1; }
    is_valid_port "$CADDY_LISTEN_PORT" || { echo -e "${RED}❌ Неверный порт Web-прокси: ${CADDY_LISTEN_PORT}${PLAIN}"; return 1; }
    warn_if_public_bind "$web_label" "$CADDY_LISTEN_ADDR" "$CADDY_LISTEN_PORT" || return 1
    if [[ "$NGINX_LISTEN_PORT" != "443" ]]; then
        echo -e "${YELLOW}⚠️ Публичный вход Nginx не 443. Убедитесь, что безопасная группа облака, брандмауэр и адреса клиентов синхронизированы.${PLAIN}"
    fi

    save_and_offer_reapply_sni_stack
}

edit_sni_stack_panel_domain_profile() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Изменение домена панели${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1

    local cf_env_file="/root/.config/vps-panel/cloudflare.env"
    if [[ ! -f "$cf_env_file" ]]; then
        echo -e "${RED}❌ Cloudflare Token не найден, сначала обновите Token в меню обслуживания сертификатов.${PLAIN}"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$cf_env_file"
    if [[ -z "${CF_Token:-}" ]]; then
        echo -e "${RED}❌ Cloudflare Token пуст, сначала обновите в меню обслуживания сертификатов.${PLAIN}"
        return 1
    fi

    local old_domain new_domain new_domain_input existing confirm old_conf
    old_domain="$PANEL_DOMAIN"
    echo -e "Текущий домен панели: ${old_domain}"
    echo -e "${YELLOW}Перед изменением убедитесь, что новый домен разрешается на текущий VPS и Cloudflare Token имеет права на эту зону.${PLAIN}"
    new_domain_input=$(ask_with_default "Новый домен панели" "$PANEL_DOMAIN")
    new_domain=$(normalize_domain_input "$new_domain_input")
    [[ "$new_domain" == "$old_domain" ]] && { echo -e "${BLUE}Домен панели не изменился.${PLAIN}"; return 0; }
    is_valid_domain "$new_domain" || { print_domain_validation_error "Домен панели" "$new_domain_input" "$new_domain"; return 1; }
    [[ "$new_domain" == "$REALITY_SNI" ]] && { echo -e "${RED}❌ Домен панели не может совпадать с REALITY SNI.${PLAIN}"; return 1; }
    for existing in "${SITE_DOMAINS[@]}"; do
        [[ "$new_domain" == "$existing" ]] && { echo -e "${RED}❌ Домен панели не может совпадать с доменом сайта/прокси.${PLAIN}"; return 1; }
    done
    for existing in "${TCP_ROUTE_SNIS[@]}"; do
        [[ "$new_domain" == "$existing" ]] && { echo -e "${RED}❌ Домен панели не может совпадать с TCP/SNI входящим.${PLAIN}"; return 1; }
    done
    for existing in "${XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ "$new_domain" == "$existing" ]] && { echo -e "${RED}❌ Домен панели не может совпадать с Xray-входящим.${PLAIN}"; return 1; }
    done
    check_domain_dns_sanity "$new_domain" "Новый домен панели" "prompt" || return 1
    confirm_risk_action "Заменить домен панели 443 на ${new_domain}" \
        "Домен панели, сертификаты и конфигурации Caddy/Nginx" \
        "Восстановите старую конфигурацию домена из резервной копии единого входа 443" \
        "Убедитесь, что DNS нового домена разрешается на текущий VPS, и Token имеет права на эту зону." || return 1

    issue_and_install_cert_for_domain "$new_domain" "$CF_Token" || return 1
    update_xui_panel_domain_settings_for_single_443 "$old_domain" "$new_domain" || return 1
    old_conf="/etc/caddy/conf.d/${old_domain}.caddy"
    [[ -f "$old_conf" ]] && quarantine_path "$old_conf" "/etc/caddy/conf.d_quarantine" >/dev/null 2>&1 || true
    PANEL_DOMAIN="$new_domain"
    rename_sni_ip_whitelist_domain "$old_domain" "$new_domain"
    save_and_offer_reapply_sni_stack
}

edit_sni_stack_runtime_profile() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🧭 Изменение параметров маршрутизации 443${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: последующие изменения портов/путей панели, портов/путей подписки, REALITY SNI, портов входа.${PLAIN}"
        echo -e "${YELLOW}Изменение домена панели выполняйте через главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси] -> [9 Изменить домен панели].${PLAIN}"
        echo -e "${YELLOW}Добавление нового сайта выполняйте через [19] -> [8], не нужно повторять первичную настройку.${PLAIN}"
        echo -e "------------------------------------------------"
        if load_sni_stack_env >/dev/null 2>&1; then
            print_sni_stack_current_summary
        else
            echo -e "${RED}Конфигурация 443 не найдена, сначала выполните [19] -> [2].${PLAIN}"
            return 1
        fi
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Изменить порты и пути панели/подписки${PLAIN}"
        echo -e "${GREEN}  2. Изменить локальное прослушивание REALITY / поддельный SNI${PLAIN}"
        echo -e "${GREEN}  3. Изменить публичный вход Nginx / локальный TLS Web-прокси${PLAIN}"
        echo -e "${YELLOW}  4. Изменить домен панели: выполните через [8] -> [9]${PLAIN}"
        echo -e "${GREEN}  5. Повторно применить сохранённую конфигурацию${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться на уровень выше / q/back/return${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice
        read_trimmed choice "👉 Введите номер меню или ?: "
        case "$choice" in
            1) edit_sni_stack_panel_subscription_profile ;;
            2) edit_sni_stack_reality_profile ;;
            3) edit_sni_stack_entry_profile ;;
            4) echo -e "${YELLOW}Используйте: главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси] -> [9 Изменить домен панели].${PLAIN}" ;;
            5) reapply_sni_stack_from_env ;;
            "?"|help) show_sni_help; pause_return; continue ;;
            0) break ;;
            *) echo -e "${RED}❌ Неверный выбор, введите номер меню или ?.${PLAIN}"; sleep 1 ;;
        esac
        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}

reapply_sni_stack_from_env() {
    load_sni_stack_env || return 1
    if [[ "${1:-}" != "--yes" ]]; then
        print_sni_stack_preview || return 1
    fi
    reapply_current_entry_mode --yes
}

# ---------------------------------------------------------
# Module: sni_stack_install.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Сбор конфигурации единого входа 443, установка, рендеринг, сертификаты и применение во время выполнения.

collect_sni_stack_config() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Общая конфигурация единого входа 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Публичный 443 будет слушаться выбранным режимом входа; веб-домены, прокси-движок, сертификаты и белые списки общие для всех трёх режимов.${PLAIN}"
    echo -e "${YELLOW}Web-прокси и локальные бэкенды Xray/3x-ui по умолчанию привязаны к 127.0.0.1.${PLAIN}"
    echo -e "------------------------------------------------"

    local default_panel_addr="127.0.0.1"
    local default_panel_port="40000"
    local default_panel_path="/panel/"
    local default_sub_addr="127.0.0.1"
    local default_sub_port="2096"
    local default_sub_path="/sub/"
    local default_clash_path="/clash/"
    detect_xui_single_443_defaults
    if [[ -n "${XUI_DETECTED_BIN:-}" || -n "${XUI_DETECTED_DB:-}" ]]; then
        default_panel_addr="${XUI_DETECTED_PANEL_ADDR:-127.0.0.1}"
        default_panel_port="${XUI_DETECTED_WEB_PORT:-40000}"
        default_panel_path="${XUI_DETECTED_WEB_BASE_PATH:-/panel/}"
        default_sub_addr="${XUI_DETECTED_SUB_ADDR:-127.0.0.1}"
        default_sub_port="${XUI_DETECTED_SUB_PORT:-2096}"
        default_sub_path="${XUI_DETECTED_SUB_PATH:-/sub/}"
        default_clash_path="${XUI_DETECTED_SUB_CLASH_PATH:-/clash/}"
    fi
    print_xui_single_443_detected_defaults
    echo -e "------------------------------------------------"

    local panel_domain_input reality_sni_input
    read_trimmed panel_domain_input "Домен панели (обязательно, например panel.example.com): "
    PANEL_DOMAIN="$panel_domain_input"
    local web_engine_choice
    WEB_PROXY_ENGINE="caddy"
    echo -e "${CYAN}Выберите Web-прокси для единого входа 443:${PLAIN}"
    echo -e "${GREEN}  1. Caddy локальный HTTPS прокси${PLAIN} ${YELLOW}(по умолчанию, совместим с существующими конфигурациями единого входа 443)${PLAIN}"
    echo -e "${GREEN}  2. Nginx локальный HTTPS прокси${PLAIN} ${YELLOW}(слушает только локальный порт, не занимает публичный 443)${PLAIN}"
    read_trimmed web_engine_choice "Выберите Web-прокси (по умолчанию 1): "
    case "${web_engine_choice:-1}" in
        1) WEB_PROXY_ENGINE="caddy" ;;
        2) WEB_PROXY_ENGINE="nginx" ;;
        *) echo -e "${RED}❌ Неверный выбор Web-прокси.${PLAIN}"; return 1 ;;
    esac
    SITE_DOMAINS=()
    SITE_BACKEND_ADDRS=()
    SITE_BACKEND_PORTS=()
    TCP_ROUTE_SNIS=()
    TCP_ROUTE_ADDRS=()
    TCP_ROUTE_PORTS=()
    SNI_IP_WHITELIST_DOMAINS=()
    SNI_IP_WHITELIST_RANGES=()
    local site_domains_input
    local -a site_domain_raw_inputs=()
    site_domains_input=$(ask_with_default "Домены сайтов/прокси (необязательно, несколько через запятую, например site1.example.com,site2.example.com)" "")
    split_csv_to_array "$site_domains_input" SITE_DOMAINS
    site_domain_raw_inputs=("${SITE_DOMAINS[@]}")
    echo -e "${YELLOW}REALITY поддельный SNI должен быть внешним реальным HTTPS-доменом, не доменом панели или узла.${PLAIN}"
    echo -e "${YELLOW}Пример: your-reality-sni.example.com (замените на реальный сайт по вашему выбору)${PLAIN}"
    read_trimmed reality_sni_input "REALITY поддельный SNI (обязательно): "
    REALITY_SNI="$reality_sni_input"
    NGINX_LISTEN_ADDR=$(ask_with_default "Публичный адрес прослушивания Nginx" "0.0.0.0")
    NGINX_LISTEN_PORT=$(ask_with_default "Публичный порт прослушивания Nginx" "443")

    local advanced_mode
    read_trimmed advanced_mode "Войти в расширенный режим для изменения локальных адресов прослушивания? (y/n, по умолчанию n): "
    if is_yes "$advanced_mode"; then
        CADDY_LISTEN_ADDR=$(ask_with_default "$(web_proxy_engine_label "$WEB_PROXY_ENGINE") адрес прослушивания" "127.0.0.1")
        XRAY_LISTEN_ADDR=$(ask_with_default "Локальный адрес прослушивания Xray REALITY" "127.0.0.1")
        PANEL_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания панели 3x-ui" "$default_panel_addr")
        SUB_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания службы подписки 3x-ui" "$default_sub_addr")
    else
        CADDY_LISTEN_ADDR="127.0.0.1"
        XRAY_LISTEN_ADDR="127.0.0.1"
        PANEL_LISTEN_ADDR="$default_panel_addr"
        SUB_LISTEN_ADDR="$default_sub_addr"
        echo -e "${GREEN}Обычный режим: Web-прокси/Xray/3x-ui/подписка/сайты используют 127.0.0.1.${PLAIN}"
    fi

    CADDY_LISTEN_PORT=$(ask_with_default "$(web_proxy_engine_label "$WEB_PROXY_ENGINE") порт прослушивания" "8443")
    XRAY_LISTEN_PORT=$(ask_with_default "Локальный порт прослушивания Xray REALITY" "1443")
    PANEL_LISTEN_PORT=$(ask_with_default "Порт панели 3x-ui" "$default_panel_port")
    PANEL_WEB_PATH=$(normalize_path_prefix "$(ask_with_default "Публичный путь панели 3x-ui / webBasePath (должен совпадать с корневым путём url панели)" "$default_panel_path")")
    SUB_LISTEN_PORT=$(ask_with_default "Порт службы подписки 3x-ui (можно изменить)" "$default_sub_port")
    SUB_URI_PATH=$(normalize_path_prefix "$(ask_with_default "Префикс пути обычной подписки 3x-ui (без порта и Subscription клиента, рекомендуется /sub/)" "$default_sub_path")")
    CLASH_URI_PATH=$(normalize_path_prefix "$(ask_with_default "Префикс пути подписки Clash/Mihomo 3x-ui (без Subscription клиента, рекомендуется /clash/)" "$default_clash_path")")
    local panel_whitelist_enabled panel_whitelist_input panel_whitelist_ranges current_client_ip
    local -a panel_whitelist_array=()
    read_trimmed panel_whitelist_enabled "Включить IP-белый список для домена панели? (y/n, по умолчанию n): "
    if is_yes "$panel_whitelist_enabled"; then
        if ! web_proxy_engine_supports_web_whitelist "${ENTRY_MODE:-nginx-stream}" "$WEB_PROXY_ENGINE"; then
            echo -e "${RED}❌ Режим xray-fallback не поддерживает веб-белые списки.${PLAIN}"
            echo -e "${YELLOW}Используйте режимы Nginx Stream/TCP Peek.${PLAIN}"
            return 1
        fi
        current_client_ip=$(detect_ssh_client_ip)
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен в белый список.${PLAIN}"
        read_trimmed panel_whitelist_input "Введите IP/CIDR, разрешённые для домена панели (несколько через пробел или запятую): "
        normalize_ip_whitelist_input "$panel_whitelist_input" panel_whitelist_array || return 1
        append_vps_public_ips_to_whitelist panel_whitelist_array
        panel_whitelist_ranges=$(join_array_by_space "${panel_whitelist_array[@]}")
    fi
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local i default_site_port
        default_site_port=3000
        for i in "${!SITE_DOMAINS[@]}"; do
            if [[ -z "${SITE_DOMAINS[$i]}" ]]; then
                continue
            fi
            if is_yes "$advanced_mode"; then
                SITE_BACKEND_ADDRS[$i]=$(ask_with_default "Адрес бэкенда сайта ${SITE_DOMAINS[$i]}" "127.0.0.1")
            else
                SITE_BACKEND_ADDRS[$i]="127.0.0.1"
            fi
            SITE_BACKEND_PORTS[$i]=$(ask_with_default "Порт бэкенда сайта ${SITE_DOMAINS[$i]}" "$default_site_port")
            default_site_port=$((default_site_port + 1))
        done
    fi

    echo -e "${YELLOW}Единый вход 443 требует, чтобы бэкенды панели/подписки 3x-ui использовали HTTP, а $(web_proxy_engine_label "$WEB_PROXY_ENGINE") обслуживал публичные сертификаты.${PLAIN}"
    echo -e "${YELLOW}Этот мастер настроит $(web_proxy_engine_label "$WEB_PROXY_ENGINE") на подключение по HTTP к ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT} и ${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT}.${PLAIN}"
    echo -e "${CYAN}Обработка сертификатов делится на два случая:${PLAIN}"
    echo -e "  3x-ui 3.x новая установка: в установщике выберите Skip SSL / не запрашивать SSL, этот шаг только дополнительная проверка."
    echo -e "  3x-ui 2.x, обновлённые старые конфигурации или если когда-либо включали SSL 3x-ui: продолжайте очистку путей сертификатов панели/подписки."
    local cert_clear_confirm
    read_trimmed cert_clear_confirm "Выполнить автоматическую очистку путей сертификатов панели/подписки 3x-ui для старых конфигураций? (Y/n, по умолчанию yes): "
    cert_clear_confirm="${cert_clear_confirm:-yes}"
    if is_yes "$cert_clear_confirm"; then
        if ! clear_xui_cert_settings_for_single_443; then
            read_trimmed cert_clear_confirm "Не удалось автоматически подтвердить очистку, вы уже очистили пути сертификатов панели и подписки вручную? (y/n, по умолчанию n): "
            is_yes "$cert_clear_confirm" || { echo -e "${YELLOW}Сначала очистите пути сертификатов в 3x-ui, сохраните и перезапустите, затем запустите мастер.${PLAIN}"; return 1; }
        fi
    else
        read_trimmed cert_clear_confirm "Подтверждаете, что пути сертификатов панели и подписки уже очищены вручную? (y/n, по умолчанию n): "
        is_yes "$cert_clear_confirm" || { echo -e "${YELLOW}Сначала очистите пути сертификатов в 3x-ui, сохраните и перезапустите, затем запустите мастер.${PLAIN}"; return 1; }
    fi

    echo -e "${CYAN}Введите Cloudflare API Token (требуются права Zone.DNS.Edit + Zone.Zone.Read)${PLAIN}"
    read_secret_trimmed CF_TOKEN "CF Token: "

    PANEL_DOMAIN=$(normalize_domain_input "$panel_domain_input")
    REALITY_SNI=$(normalize_domain_input "$reality_sni_input")
    local site_idx
    for site_idx in "${!SITE_DOMAINS[@]}"; do
        SITE_DOMAINS[$site_idx]=$(normalize_domain_input "${SITE_DOMAINS[$site_idx]}")
        SITE_BACKEND_ADDRS[$site_idx]=$(normalize_backend_addr_input "${SITE_BACKEND_ADDRS[$site_idx]:-127.0.0.1}")
    done

    if ! is_valid_domain "$PANEL_DOMAIN"; then print_domain_validation_error "Домен панели" "$panel_domain_input" "$PANEL_DOMAIN"; return 1; fi
    if ! is_valid_domain "$REALITY_SNI"; then print_domain_validation_error "REALITY SNI" "$reality_sni_input" "$REALITY_SNI"; return 1; fi
    check_domain_dns_sanity "$PANEL_DOMAIN" "Домен панели" "prompt" || return 1
    check_domain_dns_sanity "$REALITY_SNI" "REALITY SNI" "prompt" || return 1
    local site_domain seen_domains
    seen_domains=" ${PANEL_DOMAIN} ${REALITY_SNI} "
    for site_idx in "${!SITE_DOMAINS[@]}"; do
        site_domain="${SITE_DOMAINS[$site_idx]}"
        [[ -z "$site_domain" ]] && continue
        if ! is_valid_domain "$site_domain"; then print_domain_validation_error "Домен сайта/прокси" "${site_domain_raw_inputs[$site_idx]:-$site_domain}" "$site_domain"; return 1; fi
        if [[ "$site_domain" == "$PANEL_DOMAIN" || "$site_domain" == "$REALITY_SNI" || "$seen_domains" == *" ${site_domain} "* ]]; then
            echo -e "${RED}❌ Домен панели, домены сайтов/прокси и REALITY SNI не могут совпадать: ${site_domain}${PLAIN}"
            return 1
        fi
        check_domain_dns_sanity "$site_domain" "Домен сайта/прокси" "prompt" || return 1
        seen_domains+=" ${site_domain} "
    done

    local p a
    for p in "$NGINX_LISTEN_PORT" "$CADDY_LISTEN_PORT" "$XRAY_LISTEN_PORT" "$PANEL_LISTEN_PORT" "$SUB_LISTEN_PORT" "${SITE_BACKEND_PORTS[@]}"; do
        is_valid_port "$p" || { echo -e "${RED}❌ Неверный порт: ${p}${PLAIN}"; return 1; }
    done
    for a in "$NGINX_LISTEN_ADDR" "$CADDY_LISTEN_ADDR" "$XRAY_LISTEN_ADDR" "$PANEL_LISTEN_ADDR" "$SUB_LISTEN_ADDR"; do
        is_valid_listen_addr "$a" || { echo -e "${RED}❌ Неверный адрес прослушивания: ${a}${PLAIN}"; return 1; }
    done
    for a in "${SITE_BACKEND_ADDRS[@]}"; do
        is_valid_backend_addr "$a" || { echo -e "${RED}❌ Неверный адрес бэкенда: ${a}${PLAIN}"; return 1; }
    done
    is_valid_path_prefix "$PANEL_WEB_PATH" || { echo -e "${RED}❌ Неверный публичный путь панели: ${PANEL_WEB_PATH}${PLAIN}"; return 1; }
    is_valid_path_prefix "$SUB_URI_PATH" || { echo -e "${RED}❌ Неверный префикс пути обычной подписки: ${SUB_URI_PATH}${PLAIN}"; return 1; }
    is_valid_path_prefix "$CLASH_URI_PATH" || { echo -e "${RED}❌ Неверный префикс пути Clash/Mihomo: ${CLASH_URI_PATH}${PLAIN}"; return 1; }
    if [[ "$PANEL_WEB_PATH" == "$SUB_URI_PATH" || "$PANEL_WEB_PATH" == "$CLASH_URI_PATH" || "$SUB_URI_PATH" == "$CLASH_URI_PATH" ]]; then
        echo -e "${RED}❌ Пути панели, обычной подписки и Clash/Mihomo не могут совпадать.${PLAIN}"
        return 1
    fi
    SITE_DOMAIN="${SITE_DOMAINS[0]:-}"
    SITE_BACKEND_ADDR="${SITE_BACKEND_ADDRS[0]:-127.0.0.1}"
    SITE_BACKEND_PORT="${SITE_BACKEND_PORTS[0]:-3000}"
    if [[ -n "${panel_whitelist_ranges:-}" ]]; then
        set_sni_ip_whitelist_for_domain "$PANEL_DOMAIN" "$panel_whitelist_ranges"
    fi
    [[ "$NGINX_LISTEN_PORT" != "443" ]] && echo -e "${YELLOW}⚠️ Публичный порт Nginx не 443, не рекомендуется.${PLAIN}"

    warn_if_public_bind "$(web_proxy_engine_label "$WEB_PROXY_ENGINE")" "$CADDY_LISTEN_ADDR" "$CADDY_LISTEN_PORT" || return 1
    warn_if_public_bind "Xray REALITY" "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT" || return 1
    warn_if_public_bind "Панель 3x-ui" "$PANEL_LISTEN_ADDR" "$PANEL_LISTEN_PORT" || return 1
    warn_if_public_bind "Служба подписки 3x-ui" "$SUB_LISTEN_ADDR" "$SUB_LISTEN_PORT" || return 1
    for site_idx in "${!SITE_DOMAINS[@]}"; do
        [[ -n "${SITE_DOMAINS[$site_idx]}" ]] || continue
        confirm_backend_target_or_continue "Бэкенд сайта/прокси ${SITE_DOMAINS[$site_idx]}" "${SITE_BACKEND_ADDRS[$site_idx]}" "${SITE_BACKEND_PORTS[$site_idx]}" || return 1
    done

    if [[ -z "$CF_TOKEN" || ${#CF_TOKEN} -lt 20 ]]; then echo -e "${RED}❌ Неверная длина Cloudflare Token.${PLAIN}"; return 1; fi
    echo -e "${CYAN}▶ Онлайн-проверка Cloudflare Token...${PLAIN}"
    verify_cf_token_online "$CF_TOKEN"
    local verify_rc=$?
    if [[ "$verify_rc" -eq 0 ]]; then
        echo -e "${GREEN}✅ Проверка Cloudflare Token пройдена.${PLAIN}"
    elif [[ "$verify_rc" -eq 2 ]]; then
        echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку.${PLAIN}"
    else
        echo -e "${RED}❌ Ошибка проверки Cloudflare Token.${PLAIN}"
        return 1
    fi
}

install_caddy_if_needed() {
    command -v caddy >/dev/null 2>&1 && return 0
    echo -e "${CYAN}▶ Caddy не обнаружен, установка...${PLAIN}"
    if is_debian; then
        local key_tmp repo_tmp
        install_pkg debian-keyring debian-archive-keyring apt-transport-https curl gpg || return 1
        command -v curl >/dev/null 2>&1 || { echo -e "${RED}❌ Отсутствует curl, невозможно добавить репозиторий Caddy.${PLAIN}"; return 1; }
        command -v gpg >/dev/null 2>&1 || { echo -e "${RED}❌ Отсутствует gpg, невозможно проверить репозиторий Caddy.${PLAIN}"; return 1; }
        key_tmp=$(mktemp /tmp/caddy-key.XXXXXX) || return 1
        repo_tmp=$(mktemp /tmp/caddy-repo.XXXXXX) || { rm -f "$key_tmp"; return 1; }
        if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$key_tmp"; then
            rm -f "$key_tmp"
            rm -f "$repo_tmp"
            echo -e "${RED}❌ Не удалось загрузить GPG key Caddy.${PLAIN}"
            return 1
        fi
        if ! gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$key_tmp"; then
            rm -f "$key_tmp"
            rm -f "$repo_tmp"
            echo -e "${RED}❌ Не удалось записать GPG key Caddy.${PLAIN}"
            return 1
        fi
        if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$repo_tmp"; then
            rm -f "$key_tmp"
            rm -f "$repo_tmp"
            echo -e "${RED}❌ Не удалось загрузить конфигурацию репозитория Caddy APT.${PLAIN}"
            return 1
        fi
        if ! mv "$repo_tmp" /etc/apt/sources.list.d/caddy-stable.list; then
            rm -f "$key_tmp"
            rm -f "$repo_tmp"
            echo -e "${RED}❌ Не удалось записать конфигурацию репозитория Caddy APT.${PLAIN}"
            return 1
        fi
        rm -f "$key_tmp"
        install_pkg caddy || return 1
    elif is_redhat; then
        install_pkg yum-utils || true
        if command -v yum-config-manager >/dev/null 2>&1; then
            yum-config-manager --add-repo https://openrepo.io/repo/caddy/caddy.repo >/dev/null 2>&1 || return 1
        else
            echo -e "${YELLOW}⚠️ yum-config-manager не обнаружен, попытка установить Caddy из системного репозитория.${PLAIN}"
        fi
        install_pkg caddy || return 1
    else
        echo -e "${RED}❌ Автоматическая установка Caddy не поддерживается на текущей системе.${PLAIN}"
        return 1
    fi
    command -v caddy >/dev/null 2>&1
}

ensure_caddy_module_layout() {
    mkdir -p /etc/caddy/conf.d || return 1
    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        cat <<'EOF' > /etc/caddy/Caddyfile
import conf.d/*
EOF
        return 0
    fi
    if ! grep -q "import conf.d/\*" /etc/caddy/Caddyfile; then
        cp -p /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak_$(date +%s)" 2>/dev/null || true
        printf '\nimport conf.d/*\n' >> /etc/caddy/Caddyfile
    fi
}

install_nginx_stream_stack() {
    echo -e "${CYAN}▶ Проверка компонентов Nginx stream...${PLAIN}"
    local need_install=0
    local nginx_build
    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Nginx не обнаружен, установка базовых компонентов...${PLAIN}"
        need_install=1
    else
        nginx_build=$(nginx -V 2>&1 || true)
    fi

    if [[ "$need_install" -eq 0 ]]; then
        if [[ "$nginx_build" == *"--with-stream=dynamic"* ]]; then
            if grep -Rqs 'load_module .*ngx_stream_module\.so' /etc/nginx/nginx.conf /etc/nginx/modules-enabled 2>/dev/null; then
                echo -e "${GREEN}✅ Обнаружена загрузка динамического модуля Nginx stream, установка пропущена.${PLAIN}"
            else
                echo -e "${YELLOW}⚠️ Nginx поддерживает динамический stream-модуль, но загрузка не подтверждена, попытка установки модуля...${PLAIN}"
                need_install=1
            fi
        elif [[ "$nginx_build" == *"--with-stream"* || "$nginx_build" == *"--with-stream_ssl_preread_module"* ]]; then
            echo -e "${GREEN}✅ Обнаружена статическая поддержка Nginx stream, установка пропущена.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Поддержка Nginx stream не подтверждена, попытка установки модуля...${PLAIN}"
            need_install=1
        fi
    fi

    if [[ "$need_install" -eq 1 ]]; then
        if is_debian; then
            install_pkg nginx libnginx-mod-stream
        elif is_redhat; then
            install_pkg nginx
            install_pkg nginx-mod-stream || echo -e "${YELLOW}⚠️ nginx-mod-stream не установлен или репозиторий не предоставляет, продолжение с проверкой поддержки stream.${PLAIN}"
        fi
    fi
    command -v nginx >/dev/null 2>&1 || { echo -e "${RED}❌ Не удалось установить Nginx.${PLAIN}"; return 1; }
    mkdir -p /etc/nginx/stream.d
    if ! grep -Eq '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf 2>/dev/null; then
        cp -f /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak_$(date +%s)" 2>/dev/null || true
        cat <<'EOF' >> /etc/nginx/nginx.conf

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
    elif ! grep -q '/etc/nginx/stream.d/\*.conf' /etc/nginx/nginx.conf 2>/dev/null; then
        cp -f /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak_$(date +%s)" 2>/dev/null || true
        sed -i '/^[[:space:]]*stream[[:space:]]*{/a\    include /etc/nginx/stream.d/*.conf;' /etc/nginx/nginx.conf
    fi
}

harden_nginx_public_errors() {
    local nginx_conf="/etc/nginx/nginx.conf"
    local drop_conf="/etc/nginx/conf.d/00-vps-default-drop.conf"
    local quarantine_dir="/etc/vps-optimize/nginx-default-sites-disabled_$(date +%s)"
    local moved=0
    local default_file

    command -v nginx >/dev/null 2>&1 || return 0
    mkdir -p /etc/nginx/conf.d /etc/vps-optimize

    if [[ -f "$nginx_conf" ]]; then
        if grep -Eq '^[#[:space:]]*server_tokens[[:space:]]+' "$nginx_conf"; then
            sed -i 's/^[#[:space:]]*server_tokens[[:space:]].*;/    server_tokens off;/' "$nginx_conf"
        elif grep -Eq '^[[:space:]]*http[[:space:]]*\{' "$nginx_conf"; then
            sed -i '/^[[:space:]]*http[[:space:]]*{/a\    server_tokens off;' "$nginx_conf"
        fi
    fi

    for default_file in \
        /etc/nginx/sites-enabled/default \
        /etc/nginx/sites-available/default \
        /etc/nginx/conf.d/default.conf; do
        if [[ -e "$default_file" ]]; then
            mkdir -p "$quarantine_dir"
            mv "$default_file" "$quarantine_dir/" >/dev/null 2>&1 && ((moved++))
        fi
    done

    cat <<'EOF' > "$drop_conf"
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
EOF

    if [[ "$moved" -gt 0 ]]; then
        echo -e "${YELLOW}⚠️ Изолированы ${moved} стандартных конфигураций сайтов Nginx в: ${quarantine_dir}${PLAIN}"
    fi
    echo -e "${GREEN}✅ Отключено отображение версии Nginx, добавлено правило сброса на 80 порту.${PLAIN}"
}

write_nginx_sni_stream_config() {
    local conf_file="${1:-/etc/nginx/stream.d/vps_sni_${NGINX_LISTEN_PORT}.conf}"
    local validate="${2:-yes}"
    local listen_directives
    local web_backend
    local xray_backend
    local guarded_backend_var="\$vps_sni_backend"
    local -a whitelist_block_vars=()
    listen_directives=$(nginx_stream_listen_directives "$NGINX_LISTEN_ADDR" "$NGINX_LISTEN_PORT")
    web_backend=$(web_proxy_backend)
    xray_backend=$(format_hostport "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT")

    : > "$conf_file"
    if [[ ${#SNI_IP_WHITELIST_DOMAINS[@]} -gt 0 ]]; then
        local i domain ranges suffix allow_var block_var range
        for i in "${!SNI_IP_WHITELIST_DOMAINS[@]}"; do
            domain="${SNI_IP_WHITELIST_DOMAINS[$i]}"
            ranges="${SNI_IP_WHITELIST_RANGES[$i]}"
            [[ -n "$domain" && -n "$ranges" ]] || continue
            is_sni_stack_web_domain "$domain" || continue
            suffix=$(nginx_var_suffix_for_domain "$domain")
            allow_var="vps_ip_allow_${suffix}"
            block_var="vps_ip_block_${suffix}"
            whitelist_block_vars+=("\$${block_var}")
            cat <<EOF >> "$conf_file"
geo \$${allow_var} {
    default 0;
EOF
            for range in $ranges; do
                echo "    ${range} 1;" >> "$conf_file"
            done
            cat <<EOF >> "$conf_file"
}

map "\$ssl_preread_server_name:\$${allow_var}" \$${block_var} {
    default 0;
    "${domain}:0" 1;
}

EOF
        done
    fi

    cat <<EOF >> "$conf_file"
map \$ssl_preread_server_name \$vps_sni_backend {
    ${PANEL_DOMAIN} web_proxy_backend;
EOF
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local site_domain
        for site_domain in "${SITE_DOMAINS[@]}"; do
            [[ -n "$site_domain" ]] && echo "    ${site_domain} web_proxy_backend;" >> "$conf_file"
        done
    fi
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i tcp_sni
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            tcp_sni="${TCP_ROUTE_SNIS[$tcp_i]}"
            [[ -n "$tcp_sni" ]] && echo "    ${tcp_sni} vps_tcp_route_${tcp_i}_backend;" >> "$conf_file"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i xray_route_sni
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            xray_route_sni="${XRAY_SNI_ROUTE_SNIS[$xray_route_i]}"
            [[ -n "$xray_route_sni" ]] && echo "    ${xray_route_sni} vps_xray_route_${xray_route_i}_backend;" >> "$conf_file"
        done
    fi
    cat <<EOF >> "$conf_file"
    ${REALITY_SNI} xray_backend;
    default xray_backend;
}

EOF
    if [[ ${#whitelist_block_vars[@]} -gt 0 ]]; then
        local whitelist_key
        whitelist_key=$(printf '%s' "${whitelist_block_vars[@]}")
        guarded_backend_var="\$vps_sni_guarded_backend"
        cat <<EOF >> "$conf_file"
map "${whitelist_key}" \$vps_sni_ip_blocked {
    default 0;
    ~1 1;
}

map \$vps_sni_ip_blocked \$vps_sni_guarded_backend {
    1 vps_ip_reject_backend;
    default \$vps_sni_backend;
}

EOF
    fi

    cat <<EOF >> "$conf_file"

upstream web_proxy_backend {
    server ${web_backend};
}

upstream xray_backend {
    server ${xray_backend};
}

EOF
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i tcp_sni tcp_backend
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            tcp_sni="${TCP_ROUTE_SNIS[$tcp_i]}"
            [[ -n "$tcp_sni" ]] || continue
            tcp_backend=$(format_hostport "${TCP_ROUTE_ADDRS[$tcp_i]}" "${TCP_ROUTE_PORTS[$tcp_i]}")
            cat <<EOF >> "$conf_file"
upstream vps_tcp_route_${tcp_i}_backend {
    server ${tcp_backend};
}

EOF
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i xray_route_sni xray_route_backend
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            xray_route_sni="${XRAY_SNI_ROUTE_SNIS[$xray_route_i]}"
            [[ -n "$xray_route_sni" ]] || continue
            xray_route_backend=$(format_hostport "${XRAY_SNI_ROUTE_ADDRS[$xray_route_i]}" "${XRAY_SNI_ROUTE_PORTS[$xray_route_i]}")
            cat <<EOF >> "$conf_file"
upstream vps_xray_route_${xray_route_i}_backend {
    server ${xray_route_backend};
}

EOF
        done
    fi
    if [[ ${#whitelist_block_vars[@]} -gt 0 ]]; then
        cat <<'EOF' >> "$conf_file"
upstream vps_ip_reject_backend {
    server 127.0.0.1:9;
}

EOF
    fi

    cat <<EOF >> "$conf_file"
server {
${listen_directives}
    ssl_preread on;
    proxy_pass ${guarded_backend_var};
    proxy_connect_timeout 10s;
    proxy_timeout 24h;
}
EOF
    if [[ "$validate" == "yes" ]]; then
        nginx -t
    fi
}

ensure_caddy_local_base_config() {
    install_caddy_if_needed || return 1
    mkdir -p /etc/caddy/conf.d /etc/caddy/certs
    cp -f /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak_$(date +%s)" 2>/dev/null || true
    cat <<'EOF' > /etc/caddy/Caddyfile
{
    auto_https off
}

import conf.d/*
EOF
}

write_caddy_panel_config() {
    local output_file="${1:-/etc/caddy/conf.d/${PANEL_DOMAIN}.caddy}"
    local panel_backend
    local sub_backend
    local sub_match_paths
    panel_backend=$(format_hostport "$PANEL_LISTEN_ADDR" "$PANEL_LISTEN_PORT")
    sub_backend=$(format_hostport "$SUB_LISTEN_ADDR" "$SUB_LISTEN_PORT")
    SUB_URI_PATH=$(normalize_path_prefix "${SUB_URI_PATH:-/sub/}")
    CLASH_URI_PATH=$(normalize_path_prefix "${CLASH_URI_PATH:-/clash/}")
    sub_match_paths=$(caddy_path_match_tokens "$SUB_URI_PATH" "$CLASH_URI_PATH")
    cat <<EOF > "$output_file"
https://${PANEL_DOMAIN}:${CADDY_LISTEN_PORT} {
    bind ${CADDY_LISTEN_ADDR}
    tls /etc/caddy/certs/${PANEL_DOMAIN}.crt /etc/caddy/certs/${PANEL_DOMAIN}.key
    encode gzip

    @sub path ${sub_match_paths}
    handle @sub {
        reverse_proxy ${sub_backend} {
            header_up Host {http.request.host}
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Port ${NGINX_LISTEN_PORT}
            header_up X-Real-IP {remote_host}
            header_up Range {http.request.header.Range}
            header_up If-Range {http.request.header.If-Range}
        }
    }

    handle {
        reverse_proxy ${panel_backend} {
            header_up Host {http.request.host}
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Port ${NGINX_LISTEN_PORT}
            header_up X-Real-IP {remote_host}
            header_up Range {http.request.header.Range}
            header_up If-Range {http.request.header.If-Range}
        }
    }
}
EOF
}

write_caddy_site_config() {
    [[ ${#SITE_DOMAINS[@]} -eq 0 ]] && return 0
    local output_dir="${1:-/etc/caddy/conf.d}"
    local i site_domain site_backend
    for i in "${!SITE_DOMAINS[@]}"; do
        site_domain="${SITE_DOMAINS[$i]}"
        [[ -z "$site_domain" ]] && continue
        site_backend=$(format_hostport "${SITE_BACKEND_ADDRS[$i]}" "${SITE_BACKEND_PORTS[$i]}")
        cat <<EOF > "${output_dir}/${site_domain}.caddy"
https://${site_domain}:${CADDY_LISTEN_PORT} {
    bind ${CADDY_LISTEN_ADDR}
    tls /etc/caddy/certs/${site_domain}.crt /etc/caddy/certs/${site_domain}.key
    encode gzip

    reverse_proxy ${site_backend} {
        header_up Host {http.request.host}
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Port ${NGINX_LISTEN_PORT}
        header_up X-Real-IP {remote_host}
    }
}
EOF
    done
}

nginx_single_443_web_conf_path() {
    echo "/etc/nginx/conf.d/vps_sni_web_${CADDY_LISTEN_PORT}.conf"
}

nginx_http_listen_directive() {
    local addr="$1"
    local port="$2"
    if [[ "$addr" == *:* && "$addr" != \[*\] ]]; then
        printf '    listen [%s]:%s ssl http2;\n' "$addr" "$port"
    else
        printf '    listen %s:%s ssl http2;\n' "$addr" "$port"
    fi
}

write_nginx_single_443_proxy_headers() {
    cat <<EOF
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port ${NGINX_LISTEN_PORT};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$vps_proxy_connection_upgrade;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
EOF
}

append_nginx_single_443_path_proxy() {
    local output_file="$1"
    local path_prefix="$2"
    local backend="$3"
    local exact_path
    path_prefix=$(normalize_path_prefix "$path_prefix")
    exact_path="${path_prefix%/}"
    cat <<EOF >> "$output_file"

    location = ${exact_path} {
        return 308 ${path_prefix};
    }

    location ^~ ${path_prefix} {
EOF
    write_nginx_single_443_proxy_headers >> "$output_file"
    cat <<EOF >> "$output_file"
        proxy_pass http://${backend};
    }
EOF
}

write_nginx_single_443_web_config() {
    local conf_file="${1:-$(nginx_single_443_web_conf_path)}"
    local panel_backend sub_backend site_backend i site_domain
    panel_backend=$(format_hostport "$PANEL_LISTEN_ADDR" "$PANEL_LISTEN_PORT")
    sub_backend=$(format_hostport "$SUB_LISTEN_ADDR" "$SUB_LISTEN_PORT")
    SUB_URI_PATH=$(normalize_path_prefix "${SUB_URI_PATH:-/sub/}")
    CLASH_URI_PATH=$(normalize_path_prefix "${CLASH_URI_PATH:-/clash/}")
    mkdir -p "$(dirname "$conf_file")" || return 1

    cat <<EOF > "$conf_file"
# Управляется VPS-Optimize единый вход 443. Локальный HTTPS Web-прокси.
server {
$(nginx_http_listen_directive "$CADDY_LISTEN_ADDR" "$CADDY_LISTEN_PORT")
    server_name ${PANEL_DOMAIN};

    ssl_certificate /etc/caddy/certs/${PANEL_DOMAIN}.crt;
    ssl_certificate_key /etc/caddy/certs/${PANEL_DOMAIN}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    gzip on;
EOF
    append_nginx_single_443_path_proxy "$conf_file" "$SUB_URI_PATH" "$sub_backend"
    append_nginx_single_443_path_proxy "$conf_file" "$CLASH_URI_PATH" "$sub_backend"
    cat <<EOF >> "$conf_file"

    location / {
EOF
    write_nginx_single_443_proxy_headers >> "$conf_file"
    cat <<EOF >> "$conf_file"
        proxy_pass http://${panel_backend};
    }
}
EOF

    for i in "${!SITE_DOMAINS[@]}"; do
        site_domain="${SITE_DOMAINS[$i]}"
        [[ -n "$site_domain" ]] || continue
        site_backend=$(format_hostport "${SITE_BACKEND_ADDRS[$i]}" "${SITE_BACKEND_PORTS[$i]}")
        cat <<EOF >> "$conf_file"

server {
$(nginx_http_listen_directive "$CADDY_LISTEN_ADDR" "$CADDY_LISTEN_PORT")
    server_name ${site_domain};

    ssl_certificate /etc/caddy/certs/${site_domain}.crt;
    ssl_certificate_key /etc/caddy/certs/${site_domain}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    gzip on;

    location / {
EOF
        write_nginx_single_443_proxy_headers >> "$conf_file"
        cat <<EOF >> "$conf_file"
        proxy_pass http://${site_backend};
    }
}
EOF
    done
}

reload_nginx_after_config_quarantine() {
    command -v nginx >/dev/null 2>&1 || return 0
    nginx -t >/dev/null 2>&1 || return 1
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
}

quarantine_nginx_single_443_web_configs() {
    local keep_file="${1:-}"
    local conf_file moved=0
    for conf_file in /etc/nginx/conf.d/vps_sni_web_*.conf; do
        [[ -e "$conf_file" ]] || continue
        [[ -n "$keep_file" && "$conf_file" == "$keep_file" ]] && continue
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/nginx-sni-web" >/dev/null 2>&1 || true
        moved=$((moved + 1))
    done
    if [[ "$moved" -gt 0 ]]; then
        echo -e "${YELLOW}⚠️ Изолированы ${moved} старых конфигураций Nginx 443 локального Web-прокси.${PLAIN}"
        reload_nginx_after_config_quarantine || echo -e "${YELLOW}⚠️ Не удалось перезагрузить Nginx после изоляции, будет повторная проверка на этапе применения.${PLAIN}"
    fi
}

quarantine_caddy_single_443_web_configs() {
    local domain conf_file moved=0
    for domain in "$PANEL_DOMAIN" "${SITE_DOMAINS[@]}"; do
        [[ -n "$domain" ]] || continue
        conf_file="/etc/caddy/conf.d/${domain}.caddy"
        [[ -e "$conf_file" ]] || continue
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/caddy-sni-web" >/dev/null 2>&1 || true
        moved=$((moved + 1))
    done
    if [[ "$moved" -gt 0 ]]; then
        echo -e "${YELLOW}⚠️ Изолированы ${moved} старых конфигураций Caddy 443 локального Web-прокси.${PLAIN}"
        if command -v caddy >/dev/null 2>&1 && [[ -f /etc/caddy/Caddyfile ]]; then
            caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && \
                { systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true; }
        fi
    fi
}

apply_nginx_web_configs_for_single_443() {
    local conf_file
    conf_file=$(nginx_single_443_web_conf_path)
    install_nginx_http_if_needed || return 1
    ensure_nginx_http_conf_d || return 1
    harden_nginx_public_errors
    write_nginx_proxy_map_conf || return 1
    quarantine_legacy_nginx_https_proxy_configs
    quarantine_legacy_caddy_443_configs
    quarantine_caddy_single_443_web_configs
    quarantine_nginx_single_443_web_configs "$conf_file"
    write_nginx_single_443_web_config "$conf_file" || return 1
    if ! nginx -t; then
        echo -e "${RED}❌ Проверка конфигурации Nginx локального Web-прокси не удалась, новая конфигурация изолирована.${PLAIN}"
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/nginx-sni-web" >/dev/null 2>&1 || true
        return 1
    fi
}

stage_and_validate_caddy_configs_for_single_443() {
    local plan_dir plan_conf_dir validate_log
    install_caddy_if_needed || return 1
    plan_dir=$(mktemp -d /tmp/vpso-caddy-plan.XXXXXX) || return 1
    chmod 700 "$plan_dir" 2>/dev/null || true
    plan_conf_dir="${plan_dir}/conf.d"
    validate_log="${plan_dir}/caddy-validate.log"
    mkdir -p "$plan_conf_dir" || return 1

    cat <<EOF > "${plan_dir}/Caddyfile"
{
    auto_https off
}

import ${plan_conf_dir}/*
EOF
    write_caddy_panel_config "${plan_conf_dir}/${PANEL_DOMAIN}.caddy"
    write_caddy_site_config "$plan_conf_dir"

    echo -e "${CYAN}▶ Предварительная проверка плановой конфигурации Caddy, /etc/caddy не изменяется...${PLAIN}"
    if caddy validate --config "${plan_dir}/Caddyfile" >"$validate_log" 2>&1; then
        echo -e "${GREEN}✅ Плановая конфигурация Caddy проверена.${PLAIN}"
        return 0
    fi

    echo -e "${RED}❌ Проверка плановой конфигурации Caddy не удалась, запись и переключение остановлены.${PLAIN}"
    echo -e "${YELLOW}Каталог предпроверки: ${plan_dir}${PLAIN}"
    echo -e "${YELLOW}Последний вывод проверки:${PLAIN}"
    tail -n 80 "$validate_log" 2>/dev/null || true
    return 1
}

apply_caddy_configs_for_single_443() {
    quarantine_legacy_nginx_https_proxy_configs
    quarantine_nginx_single_443_web_configs
    stage_and_validate_caddy_configs_for_single_443 || return 1
    ensure_caddy_local_base_config || return 1
    write_caddy_panel_config
    write_caddy_site_config
    caddy_format_configs
    if ! caddy validate --config /etc/caddy/Caddyfile; then
        echo -e "${RED}❌ Проверка фактической конфигурации Caddy не удалась, продолжение отклонено.${PLAIN}"
        return 1
    fi
}

apply_web_proxy_configs_for_single_443() {
    WEB_PROXY_ENGINE=$(current_web_proxy_engine)
    assert_web_proxy_whitelist_supported "${ENTRY_MODE:-$(get_entry_mode)}" "$WEB_PROXY_ENGINE" || return 1
    case "$WEB_PROXY_ENGINE" in
        nginx) apply_nginx_web_configs_for_single_443 ;;
        *) apply_caddy_configs_for_single_443 ;;
    esac
}

restart_web_proxy_for_single_443() {
    WEB_PROXY_ENGINE=$(current_web_proxy_engine)
    case "$WEB_PROXY_ENGINE" in
        nginx)
            systemctl enable nginx >/dev/null 2>&1 || true
            systemctl restart nginx || return 1
            ;;
        *)
            systemctl enable caddy >/dev/null 2>&1 || true
            systemctl restart caddy || return 1
            ;;
    esac
}

issue_and_install_cert_for_domain() {
    local domain="$1"
    local cf_token="$2"
    local acme_bin="/root/.acme.sh/acme.sh"
    local acme_email
    acme_email=$(get_acme_account_email)
    if [[ ! -x "$acme_bin" ]]; then
        install_acme_sh "$acme_email" || return 1
    fi
    prepare_acme_account "$acme_bin" "$acme_email" || return 1
    mkdir -p /etc/caddy/certs /root/cert
    echo -e "${CYAN}▶ Запрос сертификата Cloudflare DNS для ${domain}...${PLAIN}"
    issue_cf_dns_cert_with_retry "$domain" "$cf_token" "$acme_bin" || return 1
    "$acme_bin" --install-cert -d "$domain" --ecc \
        --fullchain-file "/etc/caddy/certs/${domain}.crt" \
        --key-file "/etc/caddy/certs/${domain}.key" \
        --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true; systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true" >/dev/null 2>&1 || return 1
    if id caddy >/dev/null 2>&1; then
        chown root:caddy "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key" >/dev/null 2>&1
        chmod 640 "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key"
    else
        chmod 600 "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key"
    fi
    ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
    ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
}

save_sni_stack_env() {
    mkdir -p /etc/vps-optimize
    local entry_mode web_proxy_engine site_domains_csv site_backend_addrs_csv site_backend_ports_csv
    local tcp_route_snis_csv tcp_route_addrs_csv tcp_route_ports_csv
    local sni_ip_whitelist_domains_csv sni_ip_whitelist_ranges_pipe
    entry_mode="${ENTRY_MODE:-$(get_entry_mode)}"
    case "$entry_mode" in
        "nginx_stream") entry_mode="nginx-stream" ;;
        "xray_fallback") entry_mode="xray-fallback" ;;
        "tcp_peek") entry_mode="tcp-peek" ;;
    esac
    case "$entry_mode" in
        "nginx-stream"|"xray-fallback"|"tcp-peek") ;;
        *) entry_mode="nginx-stream" ;;
    esac
    web_proxy_engine=$(normalize_web_proxy_engine "${WEB_PROXY_ENGINE:-caddy}" 2>/dev/null || echo "caddy")
    site_domains_csv=$(IFS=','; echo "${SITE_DOMAINS[*]}")
    site_backend_addrs_csv=$(IFS=','; echo "${SITE_BACKEND_ADDRS[*]}")
    site_backend_ports_csv=$(IFS=','; echo "${SITE_BACKEND_PORTS[*]}")
    tcp_route_snis_csv=$(IFS=','; echo "${TCP_ROUTE_SNIS[*]}")
    tcp_route_addrs_csv=$(IFS=','; echo "${TCP_ROUTE_ADDRS[*]}")
    tcp_route_ports_csv=$(IFS=','; echo "${TCP_ROUTE_PORTS[*]}")
    sni_ip_whitelist_domains_csv=$(IFS=','; echo "${SNI_IP_WHITELIST_DOMAINS[*]}")
    sni_ip_whitelist_ranges_pipe=$(IFS='|'; echo "${SNI_IP_WHITELIST_RANGES[*]}")
    cat <<EOF > /etc/vps-optimize/sni-stack.env
ENTRY_MODE='${entry_mode}'
WEB_PROXY_ENGINE='${web_proxy_engine}'
PANEL_DOMAIN='${PANEL_DOMAIN}'
SITE_DOMAIN='${SITE_DOMAINS[0]:-}'
SITE_DOMAINS_CSV='${site_domains_csv}'
REALITY_SNI='${REALITY_SNI}'
NGINX_LISTEN_ADDR='${NGINX_LISTEN_ADDR}'
NGINX_LISTEN_PORT='${NGINX_LISTEN_PORT}'
CADDY_LISTEN_ADDR='${CADDY_LISTEN_ADDR}'
CADDY_LISTEN_PORT='${CADDY_LISTEN_PORT}'
XRAY_LISTEN_ADDR='${XRAY_LISTEN_ADDR}'
XRAY_LISTEN_PORT='${XRAY_LISTEN_PORT}'
XRAY_FALLBACK_MAIN_SNI='${XRAY_FALLBACK_MAIN_SNI:-}'
XRAY_FALLBACK_MAIN_ADDR='${XRAY_FALLBACK_MAIN_ADDR:-}'
XRAY_FALLBACK_MAIN_PORT='${XRAY_FALLBACK_MAIN_PORT:-}'
PANEL_LISTEN_ADDR='${PANEL_LISTEN_ADDR}'
PANEL_LISTEN_PORT='${PANEL_LISTEN_PORT}'
PANEL_WEB_PATH='${PANEL_WEB_PATH}'
SUB_LISTEN_ADDR='${SUB_LISTEN_ADDR}'
SUB_LISTEN_PORT='${SUB_LISTEN_PORT}'
SUB_URI_PATH='${SUB_URI_PATH}'
CLASH_URI_PATH='${CLASH_URI_PATH}'
SITE_BACKEND_ADDR='${SITE_BACKEND_ADDRS[0]:-127.0.0.1}'
SITE_BACKEND_PORT='${SITE_BACKEND_PORTS[0]:-3000}'
SITE_BACKEND_ADDRS_CSV='${site_backend_addrs_csv}'
SITE_BACKEND_PORTS_CSV='${site_backend_ports_csv}'
TCP_ROUTE_SNIS_CSV='${tcp_route_snis_csv}'
TCP_ROUTE_ADDRS_CSV='${tcp_route_addrs_csv}'
TCP_ROUTE_PORTS_CSV='${tcp_route_ports_csv}'
SNI_IP_WHITELIST_DOMAINS_CSV='${sni_ip_whitelist_domains_csv}'
SNI_IP_WHITELIST_RANGES_PIPE='${sni_ip_whitelist_ranges_pipe}'
EOF
    chmod 600 /etc/vps-optimize/sni-stack.env
}

harden_single_443_firewall() {
    local yn ssh_port remove_ports port
    echo -e "${YELLOW}Опционально: брандмауэр оставляет только SSH и публичный порт Nginx.${PLAIN}"
    echo -e "${YELLOW}Предупреждение: если 3x-ui всё ещё слушает 0.0.0.0:${PANEL_LISTEN_PORT}, функция "автоматического добавления активных портов" может снова его разрешить.${PLAIN}"
    read_trimmed yn "Ужесточить брандмауэр сейчас? (y/n, по умолчанию n): "
    is_yes "$yn" || return 0
    ssh_port=$(ss -lntp 2>/dev/null | awk '/sshd/ {print $4}' | awk -F: '{print $NF}' | grep -E '^[0-9]+$' | head -n1)
    ssh_port=${ssh_port:-22}
    remove_ports=("$CADDY_LISTEN_PORT" "$XRAY_LISTEN_PORT" "$PANEL_LISTEN_PORT" "$SUB_LISTEN_PORT" "${SITE_BACKEND_PORTS[@]}" "${TCP_ROUTE_PORTS[@]}" "${XRAY_SNI_ROUTE_PORTS[@]}" "40000" "8443" "1443" "2096" "3000")
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || true
        ufw allow "${NGINX_LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
        for port in "${remove_ports[@]}"; do
            [[ "$port" == "$ssh_port" || "$port" == "$NGINX_LISTEN_PORT" ]] && continue
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
            ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
        done
    elif command -v firewall-cmd >/dev/null 2>&1; then
        systemctl enable --now firewalld >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${ssh_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${NGINX_LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
        for port in "${remove_ports[@]}"; do
            [[ "$port" == "$ssh_port" || "$port" == "$NGINX_LISTEN_PORT" ]] && continue
            firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --remove-port="${port}/udp" >/dev/null 2>&1 || true
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
    else
        echo -e "${YELLOW}⚠️ ufw/firewalld не обнаружены, ужесточение брандмауэра пропущено.${PLAIN}"
    fi
}

print_sni_stack_result() {
    local check_ports=()
    local check_regex=""
    local p entry_mode entry_label entry_listener web_engine web_label
    entry_mode="${ENTRY_MODE:-nginx-stream}"
    entry_mode=$(normalize_entry_mode_name "$entry_mode" 2>/dev/null || echo "nginx-stream")
    web_engine=$(current_web_proxy_engine)
    web_label=$(web_proxy_engine_label "$web_engine")
    case "$entry_mode" in
        "nginx-stream") entry_label="Режим Nginx Stream"; entry_listener="nginx" ;;
        "xray-fallback") entry_label="Режим Xray Fallback"; entry_listener="основной входящий xray/3x-ui" ;;
        "tcp-peek") entry_label="Режим TCP Peek + Splice"; entry_listener="разделитель vpso-mux" ;;
        *) entry_label="$entry_mode"; entry_listener="$entry_mode" ;;
    esac
    check_ports=("$NGINX_LISTEN_PORT" "$CADDY_LISTEN_PORT" "$XRAY_LISTEN_PORT" "$PANEL_LISTEN_PORT" "$SUB_LISTEN_PORT" "${SITE_BACKEND_PORTS[@]}" "${TCP_ROUTE_PORTS[@]}" "${XRAY_SNI_ROUTE_PORTS[@]}")
    mapfile -t check_ports < <(printf '%s\n' "${check_ports[@]}" | grep -E '^[0-9]+$' | awk '!seen[$0]++')
    for p in "${check_ports[@]}"; do
        if [[ -z "$check_regex" ]]; then
            check_regex=":${p}([[:space:]]|$)"
        else
            check_regex="${check_regex}|:${p}([[:space:]]|$)"
        fi
    done

    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${GREEN}✅ Конфигурация единого входа 443 завершена${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "Текущий режим входа: ${entry_label} (${entry_mode})"
    echo -e "Текущий Web-прокси: ${web_label} (${web_engine})"
    echo -e "${BOLD}1. Снаружи обращайтесь только по этим адресам${PLAIN}"
    echo -e "  Вход панели:      https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "  Вход обычной подписки: https://${PANEL_DOMAIN}${SUB_URI_PATH}"
    echo -e "  Clash/Mihomo:  https://${PANEL_DOMAIN}${CLASH_URI_PATH}"
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local i
        for i in "${!SITE_DOMAINS[@]}"; do
            echo -e "  Вход сайта/прокси: https://${SITE_DOMAINS[$i]}/"
        done
    fi
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            echo -e "  TCP/SNI входящий:  ${TCP_ROUTE_SNIS[$tcp_i]}:${NGINX_LISTEN_PORT} -> ${TCP_ROUTE_ADDRS[$tcp_i]}:${TCP_ROUTE_PORTS[$tcp_i]}"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            echo -e "  Xray входящий:     ${XRAY_SNI_ROUTE_SNIS[$xray_route_i]}:${NGINX_LISTEN_PORT} -> ${XRAY_SNI_ROUTE_ADDRS[$xray_route_i]}:${XRAY_SNI_ROUTE_PORTS[$xray_route_i]}"
        done
    fi
    echo -e "  REALITY порт:  ${NGINX_LISTEN_PORT}"
    echo -e ""
    echo -e "${YELLOW}Не обращайтесь из интернета к этим внутренним портам: ${CADDY_LISTEN_PORT}/${XRAY_LISTEN_PORT}/${PANEL_LISTEN_PORT}/${SUB_LISTEN_PORT}/${SITE_BACKEND_PORTS[*]} ${TCP_ROUTE_PORTS[*]} ${XRAY_SNI_ROUTE_PORTS[*]}${PLAIN}"
    echo -e "${YELLOW}Они предназначены только для внутреннего соединения служб между собой, а не для браузера.${PLAIN}"
    echo -e ""
    echo -e "${BOLD}2. Рекомендации по настройке панели 3x-ui${PLAIN}"
    echo -e "  Адрес прослушивания панели: ${PANEL_LISTEN_ADDR}"
    echo -e "  Порт панели:    ${PANEL_LISTEN_PORT}"
    echo -e "  webBasePath: ${PANEL_WEB_PATH}"
    echo -e "  Для 3.x новых установок SSL: Skip SSL / не запрашивать SSL"
    echo -e "  Для 2.x/старых конфигураций: очистить пути сертификатов/приватных ключей панели"
    echo -e "  Web-прокси подключается по: http://${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "  Panel URL / Public URL / External URL: https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "  Subscription URI Path: ${SUB_URI_PATH}"
    echo -e "  Subscription External URL: https://${PANEL_DOMAIN}${SUB_URI_PATH}"
    echo -e "  Clash/Mihomo URI Path: ${CLASH_URI_PATH}"
    echo -e "  Clash/Mihomo External URL: https://${PANEL_DOMAIN}${CLASH_URI_PATH}"
    echo -e "${YELLOW}  Не рекомендуется использовать webBasePath=/, случайный путь снижает риск сканирования.${PLAIN}"
    echo -e "  Для 2.x/старых конфигураций: очистить пути сертификатов/приватных ключей подписки"
    echo -e ""
    echo -e "${BOLD}3. Заполнение Xray / 3x-ui REALITY входящего${PLAIN}"
    echo -e "  Адрес прослушивания listen: ${XRAY_LISTEN_ADDR}"
    echo -e "  Порт прослушивания port:  ${XRAY_LISTEN_PORT}"
    echo -e "  Протокол protocol:      VLESS"
    echo -e "  Транспорт network:       tcp"
    echo -e "  Безопасность security:      reality"
    echo -e "  REALITY dest:       ${REALITY_SNI}:443"
    echo -e "  serverNames:        ${REALITY_SNI}"
    echo -e "  SpiderX:            /"
    echo -e "  Адрес подключения клиента:     ваш IP сервера или домен, разрешённый на сервер"
    echo -e "  Порт подключения клиента:     ${NGINX_LISTEN_PORT}"
    echo -e "  SNI/serverName клиента: ${REALITY_SNI}"
    echo -e "${YELLOW}  Важно: dest/serverNames REALITY должны быть внешним реальным сайтом, не доменом панели.${PLAIN}"
    echo -e ""
    echo -e "${BOLD}4. Как определить типичные ошибки${PLAIN}"
    echo -e "  ERR_SSL_PROTOCOL_ERROR: обычно обращение к внутреннему порту, снаружи только https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "  ERR_TOO_MANY_REDIRECTS: обычно включён SSL 3x-ui в 3.x, либо пути сертификатов не очищены в 2.x/старых конфигурациях, или несовпадение внешнего адреса/пути"
    echo -e "  HTTP 404: сначала проверьте, совпадает ли путь с webBasePath 3x-ui, затем проверьте, проксирует ли Web-прокси на ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "  502 Bad Gateway: обычно 3x-ui не запущен, порт не тот, или бэкенд 3x-ui всё ещё HTTPS"
    echo -e ""
    echo -e "${BOLD}5. Вход и конфигурация бэкендов${PLAIN}"
    echo -e "  ${NGINX_LISTEN_ADDR}:${NGINX_LISTEN_PORT} -> ${entry_listener}"
    echo -e "  ${CADDY_LISTEN_ADDR}:${CADDY_LISTEN_PORT} -> ${web_label}"
    echo -e "  ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT} -> xray"
    echo -e "  ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT} -> 3x-ui"
    echo -e "  ${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT} -> 3x-ui subscription"
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local i
        for i in "${!SITE_DOMAINS[@]}"; do
            echo -e "  ${SITE_BACKEND_ADDRS[$i]}:${SITE_BACKEND_PORTS[$i]} -> ${SITE_DOMAINS[$i]} бэкенд сайта"
        done
    fi
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            echo -e "  ${TCP_ROUTE_ADDRS[$tcp_i]}:${TCP_ROUTE_PORTS[$tcp_i]} -> ${TCP_ROUTE_SNIS[$tcp_i]} TCP/SNI входящий"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            echo -e "  ${XRAY_SNI_ROUTE_ADDRS[$xray_route_i]}:${XRAY_SNI_ROUTE_PORTS[$xray_route_i]} -> ${XRAY_SNI_ROUTE_SNIS[$xray_route_i]} Xray входящий"
        done
    fi
    echo -e ""
    echo -e "${BOLD}6. Команды проверки${PLAIN}"
    if [[ -n "$check_regex" ]]; then
        echo -e "  ss -lntp | grep -E '${check_regex}'"
    else
        echo -e "  ss -lntp"
    fi
    echo -e "  nginx -t"
    if [[ "$web_engine" == "caddy" ]]; then
        echo -e "  caddy validate --config /etc/caddy/Caddyfile"
        echo -e "  journalctl -u caddy -n 80 --no-pager"
    fi
    echo -e "  curl -I http://${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}/"
    echo -e "  openssl s_client -connect SERVER_IP:${NGINX_LISTEN_PORT} -servername ${PANEL_DOMAIN}"
    echo -e "  openssl s_client -connect SERVER_IP:${NGINX_LISTEN_PORT} -servername ${REALITY_SNI}"
    [[ "$web_engine" == "nginx" ]] && echo -e "  journalctl -u nginx -n 80 --no-pager"
    echo -e "  journalctl -u x-ui -u 3x-ui -n 80 --no-pager"
    echo -e ""
    case "$entry_mode" in
        "xray-fallback")
            echo -e "${RED}Абсолютно не делать: Web-прокси напрямую слушает публичный 443; панель 3x-ui, подписка или дополнительные локальные входящие выставлять наружу; в 3.x устанавливать с включённым SSL 3x-ui или не очищать пути сертификатов в 2.x/старых конфигурациях; указывать REALITY dest/serverNames как домен панели.${PLAIN}"
            ;;
        *)
            echo -e "${RED}Абсолютно не делать: Web-прокси напрямую слушает публичный 443; основной входящий Xray/3x-ui напрямую занимает публичный 443; панель 3x-ui или новые локальные входящие выставлять наружу; в 3.x устанавливать с включённым SSL 3x-ui или не очищать пути сертификатов в 2.x/старых конфигурациях; указывать REALITY dest/serverNames как домен панели.${PLAIN}"
            ;;
    esac
}

apply_sni_stack_runtime_config() {
    local backup_dir current_mode
    current_mode="${ENTRY_MODE:-$(get_entry_mode)}"
    current_mode=$(normalize_entry_mode_name "$current_mode" 2>/dev/null || echo "nginx-stream")

    create_sni_stack_backup
    backup_dir=$(cat /etc/vps-optimize/sni-stack.last-backup 2>/dev/null)
    guard_current_ssh_not_on_entry_port "Повторное применение параметров единого входа 443" || return 1
    check_entry_mode_dependencies "$current_mode" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка проверки зависимостей режима входа"; return 1; }
    preflight_entry_mode_before_cutover "$current_mode" || { echo -e "${RED}❌ Предпроверка режима ${current_mode} не удалась, публичный 443 не переприменён.${PLAIN}"; return 1; }
    stop_public_443_entry_services_for_target "$current_mode" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка остановки старых служб публичного 443"; return 1; }
    apply_entry_mode_by_name "$current_mode" "$backup_dir" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка применения режима ${current_mode}"; return 1; }
    ENTRY_MODE="$current_mode"
    save_sni_stack_env
    write_single_443_engine_state "$(entry_mode_engine_name "$current_mode")" "$backup_dir"
    generate_caddy_cf_manifest
}

# ---------------------------------------------------------
# Module: sni_stack_sites.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Операции CRUD для веб-доменов и пользовательских TCP-маршрутов в едином входе 443.

list_sni_stack_sites() {
    load_sni_stack_env || return 1
    local web_engine web_label
    web_engine=$(current_web_proxy_engine)
    web_label=$(web_proxy_engine_label "$web_engine")
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Текущие веб-домены/прокси в едином входе 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "Web-прокси: ${web_label} (${web_engine}) -> $(web_proxy_backend)"
    echo -e "Домен панели: ${PANEL_DOMAIN} -> ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    local panel_ranges
    panel_ranges=$(sni_ip_whitelist_ranges_for_domain "$PANEL_DOMAIN")
    [[ -n "$panel_ranges" ]] && echo -e "${YELLOW}IP-белый список домена панели: ${panel_ranges}${PLAIN}"
    echo -e "REALITY SNI: ${REALITY_SNI} -> ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
    [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]] && echo -e "${CYAN}Также есть ${#TCP_ROUTE_SNIS[@]} старых TCP/SNI входящих.${PLAIN}"
        [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]] && echo -e "${CYAN}Также есть ${#XRAY_SNI_ROUTE_SNIS[@]} Xray-входящих, посмотрите в [19] -> [15].${PLAIN}"
    echo -e "------------------------------------------------"
    if [[ ${#SITE_DOMAINS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет дополнительных доменов сайтов/прокси.${PLAIN}"
        return 0
    fi

    local i num
    for i in "${!SITE_DOMAINS[@]}"; do
        num=$((i + 1))
        echo -e "${GREEN}${num}.${PLAIN} https://${SITE_DOMAINS[$i]}/ -> ${SITE_BACKEND_ADDRS[$i]}:${SITE_BACKEND_PORTS[$i]}"
        local site_ranges
        site_ranges=$(sni_ip_whitelist_ranges_for_domain "${SITE_DOMAINS[$i]}")
        [[ -n "$site_ranges" ]] && echo -e "   ${YELLOW}IP-белый список: ${site_ranges}${PLAIN}"
    done
}

add_sni_stack_site() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Добавление веб-домена/прокси в 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1

    local cf_env_file="/root/.config/vps-panel/cloudflare.env"
    if [[ ! -f "$cf_env_file" ]]; then
        echo -e "${RED}❌ Cloudflare Token не найден, сначала запишите Token в меню обслуживания [2].${PLAIN}"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$cf_env_file"
    if [[ -z "${CF_Token:-}" ]]; then
        echo -e "${RED}❌ Cloudflare Token пуст, сначала обновите в меню обслуживания [2].${PLAIN}"
        return 1
    fi

    echo -e "Этот пункт подходит для последующего добавления сайтов, например SublinkPro, Dockge, блогов, инструментов управления подписками и т.д."
    local web_engine web_label
    web_engine=$(current_web_proxy_engine)
    web_label=$(web_proxy_engine_label "$web_engine")
    echo -e "${YELLOW}Новый домен будет проходить через: публичный ${NGINX_LISTEN_PORT} -> вход 443 -> ${web_label} -> локальный бэкенд.${PLAIN}"
    echo -e ""

    local site_domain site_domain_input site_addr site_port advanced_mode existing idx confirm
    local enable_ip_whitelist whitelist_input whitelist_ranges current_client_ip
    local -a whitelist_array=()
    read_trimmed site_domain_input "Введите новый домен сайта/прокси (например sub.example.com): "
    site_domain=$(normalize_domain_input "$site_domain_input")
    if [[ -z "$site_domain" || "$site_domain" == "0" ]]; then
        echo -e "${BLUE}Добавление домена сайта/прокси отменено.${PLAIN}"
        return 0
    fi

    if ! is_valid_domain "$site_domain"; then
        print_domain_validation_error "домен" "$site_domain_input" "$site_domain"
        return 1
    fi
    if [[ "$site_domain" == "$PANEL_DOMAIN" || "$site_domain" == "$REALITY_SNI" ]]; then
        echo -e "${RED}❌ Новый домен не может совпадать с доменом панели или REALITY SNI.${PLAIN}"
        return 1
    fi
    for existing in "${SITE_DOMAINS[@]}"; do
        if [[ "$site_domain" == "$existing" ]]; then
            echo -e "${RED}❌ Этот домен уже есть в списке маршрутизации 443.${PLAIN}"
            return 1
        fi
    done
    for existing in "${TCP_ROUTE_SNIS[@]}"; do
        if [[ "$site_domain" == "$existing" ]]; then
            echo -e "${RED}❌ Этот домен уже используется как TCP/SNI входящий.${PLAIN}"
            return 1
        fi
    done
    for existing in "${XRAY_SNI_ROUTE_SNIS[@]}"; do
        if [[ "$site_domain" == "$existing" ]]; then
            echo -e "${RED}❌ Этот домен уже используется как Xray-входящий.${PLAIN}"
            return 1
        fi
    done

    read_trimmed advanced_mode "Использовать пользовательский адрес бэкенда? (y/n, по умолчанию n): "
    if is_yes "$advanced_mode"; then
        site_addr=$(ask_with_default "Адрес бэкенда" "127.0.0.1")
    else
        site_addr="127.0.0.1"
        echo -e "${GREEN}Адрес бэкенда 127.0.0.1.${PLAIN}"
    fi
    site_addr=$(normalize_backend_addr_input "$site_addr")
    site_port=$(ask_with_default "Порт бэкенда" "$((3000 + ${#SITE_DOMAINS[@]}))")

    is_valid_backend_addr "$site_addr" || { echo -e "${RED}❌ Неверный адрес бэкенда: ${site_addr}${PLAIN}"; return 1; }
    is_valid_port "$site_port" || { echo -e "${RED}❌ Неверный порт бэкенда: ${site_port}${PLAIN}"; return 1; }
    warn_if_public_bind "Бэкенд сайта/прокси ${site_domain}" "$site_addr" "$site_port" || return 1
    confirm_backend_target_or_continue "Бэкенд сайта/прокси ${site_domain}" "$site_addr" "$site_port" || return 1

    if web_proxy_engine_supports_web_whitelist "${ENTRY_MODE:-$(get_entry_mode)}" "$web_engine"; then
        read_trimmed enable_ip_whitelist "Включить IP-белый список для ${site_domain}? (y/n, по умолчанию n): "
    else
        echo -e "${YELLOW}Режим xray-fallback не позволяет локальному Web-прокси надёжно получать реальный IP клиента, поэтому для нового домена запрещено включать веб-белый список.${PLAIN}"
        echo -e "${YELLOW}Если нужен веб-белый список, переключитесь на режимы Nginx Stream/TCP Peek.${PLAIN}"
        enable_ip_whitelist="n"
    fi
    if is_yes "$enable_ip_whitelist"; then
        current_client_ip=$(detect_ssh_client_ip)
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен.${PLAIN}"
        read_trimmed whitelist_input "Введите IP/CIDR, разрешённые для ${site_domain} (несколько через пробел или запятую): "
        normalize_ip_whitelist_input "$whitelist_input" whitelist_array || return 1
        append_vps_public_ips_to_whitelist whitelist_array
        whitelist_ranges=$(join_array_by_space "${whitelist_array[@]}")
    fi

    echo -e ""
    echo -e "${CYAN}Будет добавлено: ${site_domain} -> ${site_addr}:${site_port}${PLAIN}"
    [[ -n "${whitelist_ranges:-}" ]] && echo -e "${YELLOW}IP-белый список: ${whitelist_ranges}${PLAIN}"
    confirm_risk_action "Добавление веб-домена/прокси ${site_domain} в 443" \
        "Сертификат, конфигурация Web-прокси и правила маршрутизации входа 443" \
        "Восстановите из резервной копии единого входа 443 или удалите домен из меню управления сайтами" \
        "Убедитесь, что домен разрешается на текущий VPS, а порт бэкенда доступен с этого VPS." || return 1

    idx=${#SITE_DOMAINS[@]}
    SITE_DOMAINS[$idx]="$site_domain"
    SITE_BACKEND_ADDRS[$idx]="$site_addr"
    SITE_BACKEND_PORTS[$idx]="$site_port"
    [[ -n "${whitelist_ranges:-}" ]] && set_sni_ip_whitelist_for_domain "$site_domain" "$whitelist_ranges"

    issue_and_install_cert_for_domain "$site_domain" "$CF_Token" || return 1
    apply_sni_stack_runtime_config || return 1
    echo -e "${GREEN}✅ Добавлен вход сайта: https://${site_domain}/${PLAIN}"
    echo -e "${YELLOW}Внимание: текущий VPS должен иметь доступ к ${site_addr}:${site_port}, браузер обращается только по https://${site_domain}/.${PLAIN}"
    echo -e "${CYAN}Текущий Web-прокси: ${web_label} -> ${site_addr}:${site_port}${PLAIN}"
}

edit_sni_stack_site_backend() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Изменение бэкенда веб-домена/прокси 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1

    if [[ ${#SITE_DOMAINS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет доменов сайтов/прокси для изменения.${PLAIN}"
        return 0
    fi

    local i num choice idx domain new_addr new_port confirm
    for i in "${!SITE_DOMAINS[@]}"; do
        num=$((i + 1))
        echo -e "${GREEN}${num}.${PLAIN} ${SITE_DOMAINS[$i]} -> ${SITE_BACKEND_ADDRS[$i]}:${SITE_BACKEND_PORTS[$i]}"
    done
    echo -e "------------------------------------------------"
    read_trimmed choice "Введите номер для изменения: "
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo -e "${BLUE}Изменение отменено.${PLAIN}"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SITE_DOMAINS[@]} )); then
        echo -e "${RED}❌ Неверный номер.${PLAIN}"
        return 1
    fi

    idx=$((choice - 1))
    domain="${SITE_DOMAINS[$idx]}"
    new_addr=$(ask_with_default "Адрес бэкенда" "${SITE_BACKEND_ADDRS[$idx]}")
    new_addr=$(normalize_backend_addr_input "$new_addr")
    new_port=$(ask_with_default "Порт бэкенда" "${SITE_BACKEND_PORTS[$idx]}")

    is_valid_backend_addr "$new_addr" || { echo -e "${RED}❌ Неверный адрес бэкенда: ${new_addr}${PLAIN}"; return 1; }
    is_valid_port "$new_port" || { echo -e "${RED}❌ Неверный порт бэкенда: ${new_port}${PLAIN}"; return 1; }
    warn_if_public_bind "Бэкенд сайта/прокси ${domain}" "$new_addr" "$new_port" || return 1
    confirm_backend_target_or_continue "Бэкенд сайта/прокси ${domain}" "$new_addr" "$new_port" || return 1

    echo -e ""
    echo -e "${CYAN}Будет изменено: ${domain} -> ${new_addr}:${new_port}${PLAIN}"
    confirm_risk_action "Изменение бэкенда веб-домена/прокси 443" \
        "Бэкенд Web-прокси и правила маршрутизации входа 443" \
        "Восстановите из резервной копии единого входа 443 до изменения" \
        "Убедитесь, что текущий VPS имеет доступ к новому адресу и порту бэкенда." || return 1

    SITE_BACKEND_ADDRS[$idx]="$new_addr"
    SITE_BACKEND_PORTS[$idx]="$new_port"
    apply_sni_stack_runtime_config || return 1
    echo -e "${GREEN}✅ Бэкенд сайта обновлён: https://${domain}/ -> ${new_addr}:${new_port}${PLAIN}"
    echo -e "${CYAN}Текущий Web-прокси: $(web_proxy_engine_label) -> ${new_addr}:${new_port}${PLAIN}"
}

remove_sni_stack_site() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Удаление веб-домена/прокси 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1

    if [[ ${#SITE_DOMAINS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет доменов сайтов/прокси для удаления.${PLAIN}"
        return 0
    fi

    local i num choice idx domain confirm delete_cert new_domains new_addrs new_ports
    for i in "${!SITE_DOMAINS[@]}"; do
        num=$((i + 1))
        echo -e "${GREEN}${num}.${PLAIN} ${SITE_DOMAINS[$i]} -> ${SITE_BACKEND_ADDRS[$i]}:${SITE_BACKEND_PORTS[$i]}"
    done
    echo -e "------------------------------------------------"
    read_trimmed choice "Введите номер для удаления: "
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo -e "${BLUE}Удаление отменено.${PLAIN}"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SITE_DOMAINS[@]} )); then
        echo -e "${RED}❌ Неверный номер.${PLAIN}"
        return 1
    fi

    idx=$((choice - 1))
    domain="${SITE_DOMAINS[$idx]}"
    confirm_risk_action "Удалить ${domain} из маршрутизации 443" \
        "Конфигурация Web-прокси и правила маршрутизации входа 443 для этого домена" \
        "Восстановите из резервной копии единого входа 443 или заново добавьте домен" \
        "Убедитесь, что этот домен больше не обслуживает работающие панели, подписки или сайты." || return 1

    new_domains=()
    new_addrs=()
    new_ports=()
    for i in "${!SITE_DOMAINS[@]}"; do
        [[ "$i" -eq "$idx" ]] && continue
        new_domains+=("${SITE_DOMAINS[$i]}")
        new_addrs+=("${SITE_BACKEND_ADDRS[$i]}")
        new_ports+=("${SITE_BACKEND_PORTS[$i]}")
    done
    SITE_DOMAINS=("${new_domains[@]}")
    SITE_BACKEND_ADDRS=("${new_addrs[@]}")
    SITE_BACKEND_PORTS=("${new_ports[@]}")
    remove_sni_ip_whitelist_for_domain "$domain"
    quarantine_path "/etc/caddy/conf.d/${domain}.caddy" "/etc/vps-optimize/quarantine/caddy-sni" >/dev/null 2>&1 || true

    apply_sni_stack_runtime_config || return 1

    read_trimmed delete_cert "Также изолировать файлы сертификатов ${domain}? (y/n, по умолчанию n): "
    if is_yes "$delete_cert"; then
        quarantine_path "/etc/caddy/certs/${domain}.crt" "/etc/vps-optimize/quarantine/caddy-certs" >/dev/null 2>&1 || true
        quarantine_path "/etc/caddy/certs/${domain}.key" "/etc/vps-optimize/quarantine/caddy-certs" >/dev/null 2>&1 || true
        quarantine_path "/root/cert/${domain}.crt" "/etc/vps-optimize/quarantine/caddy-certs" >/dev/null 2>&1 || true
        quarantine_path "/root/cert/${domain}.key" "/etc/vps-optimize/quarantine/caddy-certs" >/dev/null 2>&1 || true
        generate_caddy_cf_manifest
        echo -e "${GREEN}✅ Конфигурация ${domain} удалена, локальные сертификаты изолированы.${PLAIN}"
    else
        echo -e "${GREEN}✅ Конфигурация маршрутизации ${domain} удалена, сертификаты сохранены.${PLAIN}"
    fi
}

switch_sni_stack_web_proxy_engine() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Переключение Web-прокси для 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1

    local current_engine current_label choice new_engine new_label entry_mode
    current_engine=$(current_web_proxy_engine)
    current_label=$(web_proxy_engine_label "$current_engine")
    entry_mode="${ENTRY_MODE:-$(get_entry_mode)}"

    echo -e "Текущий режим входа: ${entry_mode}"
    echo -e "Текущий Web-прокси: ${current_label} (${current_engine})"
    echo -e "Локальный TLS-бэкенд: $(web_proxy_backend)"
    echo -e "Источник: /etc/vps-optimize/sni-stack.env (сохранённая общая конфигурация 443)"
    echo -e "${YELLOW}При переключении будет заново сгенерирована конфигурация выбранного движка на основе текущих доменов, сертификатов, бэкендов и белых списков, а другая конфигурация 443 локального Web-прокси будет изолирована.${PLAIN}"
    echo -e "${YELLOW}Если вы вручную меняли файлы Caddy/Nginx без сохранения через это меню, сначала синхронизируйте значения через [8]/[10], затем переключайте.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${GREEN}  1. Caddy локальный HTTPS прокси${PLAIN}"
    echo -e "${GREEN}  2. Nginx локальный HTTPS прокси${PLAIN}"
    echo -e "${RED}  0. Отмена${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    read_trimmed choice "Выберите Web-прокси (по умолчанию оставить текущий): "
    case "$choice" in
        ""|0|q|Q)
            echo -e "${BLUE}Переключение Web-прокси отменено.${PLAIN}"
            return 0
            ;;
        1) new_engine="caddy" ;;
        2) new_engine="nginx" ;;
        *)
            echo -e "${RED}❌ Неверный выбор Web-прокси.${PLAIN}"
            return 1
            ;;
    esac

    new_label=$(web_proxy_engine_label "$new_engine")
    if [[ "$new_engine" == "$current_engine" ]]; then
        echo -e "${BLUE}Web-прокси не изменился, остаётся ${current_label}.${PLAIN}"
        return 0
    fi

    if [[ ${#SNI_IP_WHITELIST_DOMAINS[@]} -gt 0 ]] && ! web_proxy_engine_supports_web_whitelist "$entry_mode" "$new_engine"; then
        echo -e "${RED}❌ Невозможно переключиться на ${new_label}: текущий режим xray-fallback и уже есть веб-белые списки, локальный Web-прокси не может надёжно получить реальный IP клиента.${PLAIN}"
        echo -e "${YELLOW}Сначала очистите веб-белые списки или переключитесь на Nginx Stream/TCP Peek перед сменой движка.${PLAIN}"
        return 1
    fi
    if ! web_proxy_engine_supports_web_whitelist "$entry_mode" "$new_engine"; then
        echo -e "${YELLOW}⚠️ Текущий режим xray-fallback, после смены Web-прокси всё равно запрещено добавлять новые веб-белые списки.${PLAIN}"
    fi

    confirm_risk_action "Переключить Web-прокси 443 на ${new_label}" \
        "Заново сгенерировать конфигурацию ${new_label} и изолировать старые конфигурации 443 локального Web-прокси; публичный вход 443 остаётся в режиме ${entry_mode}" \
        "Восстановите из резервной копии единого входа 443 или вернитесь на ${current_label} и повторно примените" \
        "Убедитесь, что ${CADDY_LISTEN_ADDR}:${CADDY_LISTEN_PORT} не занят другой службой, и файлы сертификатов всё ещё в /etc/caddy/certs/." || return 1

    WEB_PROXY_ENGINE="$new_engine"
    save_and_offer_reapply_sni_stack
}

list_sni_stack_tcp_routes() {
    load_sni_stack_env || return 1
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Текущие TCP/SNI локальные входящие в 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "Публичный вход: ${NGINX_LISTEN_ADDR}:${NGINX_LISTEN_PORT}"
    echo -e "Бэкенд REALITY по умолчанию: ${REALITY_SNI} -> ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
    echo -e "------------------------------------------------"
    if [[ ${#TCP_ROUTE_SNIS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет дополнительных TCP/SNI входящих.${PLAIN}"
        return 0
    fi

    local i num
    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        num=$((i + 1))
        echo -e "${GREEN}${num}.${PLAIN} ${TCP_ROUTE_SNIS[$i]}:${NGINX_LISTEN_PORT} -> ${TCP_ROUTE_ADDRS[$i]}:${TCP_ROUTE_PORTS[$i]}"
    done
}

add_sni_stack_tcp_route() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Добавление TCP/SNI локального входящего в 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    echo -e "${YELLOW}Назначение: вы добавили новый локальный входящий в 3x-ui, этот пункт направляет определённый SNI через публичный ${NGINX_LISTEN_PORT} на этот локальный порт.${PLAIN}"
    echo -e "${YELLOW}Требование: протокол должен быть TCP, и клиент должен поддерживать SNI; UDP/QUIC/Hysteria2/TUIC или протоколы без SNI не подходят.${PLAIN}"
    echo -e "${YELLOW}Граница безопасности: бэкенд разрешён только 127.0.0.1/localhost/::1, новые публичные порты не открываются.${PLAIN}"
    echo -e "------------------------------------------------"

    local route_sni route_sni_input route_addr route_port existing idx
    read_trimmed route_sni_input "Введите новый SNI/домен для маршрутизации (например relay.example.com): "
    route_sni=$(normalize_domain_input "$route_sni_input")
    if [[ -z "$route_sni" || "$route_sni" == "0" ]]; then
        echo -e "${BLUE}Добавление TCP/SNI входящего отменено.${PLAIN}"
        return 0
    fi
    is_valid_domain "$route_sni" || { print_domain_validation_error "SNI/домен" "$route_sni_input" "$route_sni"; return 1; }
    if [[ "$route_sni" == "$PANEL_DOMAIN" || "$route_sni" == "$REALITY_SNI" ]]; then
        echo -e "${RED}❌ TCP/SNI входящий не может совпадать с доменом панели или REALITY SNI.${PLAIN}"
        return 1
    fi
    for existing in "${SITE_DOMAINS[@]}"; do
        [[ "$route_sni" == "$existing" ]] && { echo -e "${RED}❌ Этот домен уже используется как веб-домен/прокси.${PLAIN}"; return 1; }
    done
    for existing in "${TCP_ROUTE_SNIS[@]}"; do
        [[ "$route_sni" == "$existing" ]] && { echo -e "${RED}❌ Этот TCP/SNI входящий уже существует.${PLAIN}"; return 1; }
    done
    for existing in "${XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ "$route_sni" == "$existing" ]] && { echo -e "${RED}❌ Этот домен уже используется как Xray-входящий.${PLAIN}"; return 1; }
    done

    check_domain_dns_sanity "$route_sni" "Домен TCP/SNI входящего" "warn" || echo -e "${YELLOW}⚠️ Если клиент подключается по IP и вручную указывает SNI, это предупреждение можно игнорировать.${PLAIN}"
    route_addr=$(ask_with_default "Локальный адрес прослушивания нового входящего 3x-ui (только локальный)" "127.0.0.1")
    route_addr=$(normalize_loopback_addr "$route_addr")
    route_port=$(ask_with_default "Локальный порт прослушивания нового входящего 3x-ui" "8443")
    is_loopback_listen_addr "$route_addr" || { echo -e "${RED}❌ Для безопасности TCP/SNI входящий бэкенд разрешён только 127.0.0.1, localhost или ::1.${PLAIN}"; return 1; }
    is_valid_port "$route_port" || { echo -e "${RED}❌ Неверный порт входящего: ${route_port}${PLAIN}"; return 1; }
    if [[ "$route_port" == "$NGINX_LISTEN_PORT" || "$route_port" == "$CADDY_LISTEN_PORT" || "$route_port" == "$PANEL_LISTEN_PORT" || "$route_port" == "$SUB_LISTEN_PORT" ]]; then
        echo -e "${RED}❌ Порт входящего не может совпадать с публичным входом, Web-прокси, панелью или подпиской.${PLAIN}"
        return 1
    fi

    echo -e ""
    echo -e "${CYAN}Будет добавлен TCP/SNI маршрут: ${route_sni}:${NGINX_LISTEN_PORT} -> ${route_addr}:${route_port}${PLAIN}"
    echo -e "${YELLOW}Убедитесь, что входящий 3x-ui слушает ${route_addr}:${route_port}, и клиент подключается на порт ${NGINX_LISTEN_PORT}.${PLAIN}"
    echo -e "${YELLOW}Пояснение: веб-белые списки защищают только веб-домены, не применяются к TCP/SNI или Xray-узлам.${PLAIN}"
    confirm_risk_action "Добавить TCP/SNI входящий ${route_sni} в 443" \
        "Правило маршрутизации SNI в Nginx stream направляет этот SNI напрямую в локальный входящий 3x-ui" \
        "Восстановите из резервной копии единого входа 443 или удалите этот маршрут из меню TCP/SNI входящих" \
        "Убедитесь, что бэкенд слушает только локальный адрес и не открывает ${route_port} в брандмауэре/безопасной группе." || return 1

    idx=${#TCP_ROUTE_SNIS[@]}
    TCP_ROUTE_SNIS[$idx]="$route_sni"
    TCP_ROUTE_ADDRS[$idx]="$route_addr"
    TCP_ROUTE_PORTS[$idx]="$route_port"
    save_and_offer_reapply_sni_stack
}

edit_sni_stack_tcp_route() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Изменение TCP/SNI локального входящего в 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    if [[ ${#TCP_ROUTE_SNIS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет TCP/SNI входящих для изменения.${PLAIN}"
        return 0
    fi

    local i num choice idx old_sni new_sni new_sni_input new_addr new_port existing
    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        num=$((i + 1))
        echo -e "${GREEN}${num}.${PLAIN} ${TCP_ROUTE_SNIS[$i]}:${NGINX_LISTEN_PORT} -> ${TCP_ROUTE_ADDRS[$i]}:${TCP_ROUTE_PORTS[$i]}"
    done
    echo -e "------------------------------------------------"
    read_trimmed choice "Введите номер для изменения: "
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo -e "${BLUE}Изменение отменено.${PLAIN}"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#TCP_ROUTE_SNIS[@]} )); then
        echo -e "${RED}❌ Неверный номер.${PLAIN}"
        return 1
    fi

    idx=$((choice - 1))
    old_sni="${TCP_ROUTE_SNIS[$idx]}"
    new_sni_input=$(ask_with_default "SNI/домен" "$old_sni")
    new_sni=$(normalize_domain_input "$new_sni_input")
    new_addr=$(ask_with_default "Локальный адрес прослушивания (только локальный)" "${TCP_ROUTE_ADDRS[$idx]}")
    new_addr=$(normalize_loopback_addr "$new_addr")
    new_port=$(ask_with_default "Локальный порт прослушивания" "${TCP_ROUTE_PORTS[$idx]}")

    is_valid_domain "$new_sni" || { print_domain_validation_error "SNI/домен" "$new_sni_input" "$new_sni"; return 1; }
    if [[ "$new_sni" == "$PANEL_DOMAIN" || "$new_sni" == "$REALITY_SNI" ]]; then
        echo -e "${RED}❌ TCP/SNI входящий не может совпадать с доменом панели или REALITY SNI.${PLAIN}"
        return 1
    fi
    for existing in "${SITE_DOMAINS[@]}"; do
        [[ "$new_sni" == "$existing" ]] && { echo -e "${RED}❌ Этот домен уже используется как веб-домен/прокси.${PLAIN}"; return 1; }
    done
    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        [[ "$i" -eq "$idx" ]] && continue
        [[ "$new_sni" == "${TCP_ROUTE_SNIS[$i]}" ]] && { echo -e "${RED}❌ Этот TCP/SNI входящий уже существует.${PLAIN}"; return 1; }
    done
    for existing in "${XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ "$new_sni" == "$existing" ]] && { echo -e "${RED}❌ Этот домен уже используется как Xray-входящий.${PLAIN}"; return 1; }
    done
    is_loopback_listen_addr "$new_addr" || { echo -e "${RED}❌ Для безопасности TCP/SNI входящий бэкенд разрешён только 127.0.0.1, localhost или ::1.${PLAIN}"; return 1; }
    is_valid_port "$new_port" || { echo -e "${RED}❌ Неверный порт входящего: ${new_port}${PLAIN}"; return 1; }
    if [[ "$new_port" == "$NGINX_LISTEN_PORT" || "$new_port" == "$CADDY_LISTEN_PORT" || "$new_port" == "$PANEL_LISTEN_PORT" || "$new_port" == "$SUB_LISTEN_PORT" ]]; then
        echo -e "${RED}❌ Порт входящего не может совпадать с публичным входом, Caddy, панелью или подпиской.${PLAIN}"
        return 1
    fi

    echo -e ""
    echo -e "${CYAN}Будет изменено: ${old_sni}:${NGINX_LISTEN_PORT} -> ${new_sni}:${NGINX_LISTEN_PORT} -> ${new_addr}:${new_port}${PLAIN}"
    confirm_risk_action "Изменение TCP/SNI входящего ${old_sni}" \
        "Правило маршрутизации SNI в Nginx stream и локальный порт бэкенда" \
        "Восстановите из резервной копии единого входа 443 до изменения" \
        "Убедитесь, что входящий 3x-ui слушает по новому адресу и порту и внутренний порт не открыт." || return 1

    TCP_ROUTE_SNIS[$idx]="$new_sni"
    TCP_ROUTE_ADDRS[$idx]="$new_addr"
    TCP_ROUTE_PORTS[$idx]="$new_port"
    if [[ "$old_sni" != "$new_sni" ]]; then
        rename_sni_ip_whitelist_domain "$old_sni" "$new_sni"
    fi
    save_and_offer_reapply_sni_stack
}

remove_sni_stack_tcp_route() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Удаление TCP/SNI локального входящего из 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    if [[ ${#TCP_ROUTE_SNIS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет TCP/SNI входящих для удаления.${PLAIN}"
        return 0
    fi

    local i num choice idx route_sni
    local -a new_snis=()
    local -a new_addrs=()
    local -a new_ports=()
    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        num=$((i + 1))
        echo -e "${GREEN}${num}.${PLAIN} ${TCP_ROUTE_SNIS[$i]}:${NGINX_LISTEN_PORT} -> ${TCP_ROUTE_ADDRS[$i]}:${TCP_ROUTE_PORTS[$i]}"
    done
    echo -e "------------------------------------------------"
    read_trimmed choice "Введите номер для удаления: "
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo -e "${BLUE}Удаление отменено.${PLAIN}"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#TCP_ROUTE_SNIS[@]} )); then
        echo -e "${RED}❌ Неверный номер.${PLAIN}"
        return 1
    fi

    idx=$((choice - 1))
    route_sni="${TCP_ROUTE_SNIS[$idx]}"
    confirm_risk_action "Удалить TCP/SNI входящий ${route_sni} из маршрутизации 443" \
        "Правило прямого прохождения SNI в Nginx stream" \
        "Восстановите из резервной копии единого входа 443 или заново добавьте TCP/SNI входящий" \
        "Убедитесь, что ни один клиент больше не использует этот SNI для подключения." || return 1

    for i in "${!TCP_ROUTE_SNIS[@]}"; do
        [[ "$i" -eq "$idx" ]] && continue
        new_snis+=("${TCP_ROUTE_SNIS[$i]}")
        new_addrs+=("${TCP_ROUTE_ADDRS[$i]}")
        new_ports+=("${TCP_ROUTE_PORTS[$i]}")
    done
    TCP_ROUTE_SNIS=("${new_snis[@]}")
    TCP_ROUTE_ADDRS=("${new_addrs[@]}")
    TCP_ROUTE_PORTS=("${new_ports[@]}")
    remove_sni_ip_whitelist_for_domain "$route_sni"
    save_and_offer_reapply_sni_stack
}

# ---------------------------------------------------------
# Module: xray_sni_routes.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Записи маршрутов Xray SNI и синхронизация для режимов nginx-stream/tcp-peek.

xray_sni_routes_fallback_notice() {
    echo -e "${YELLOW}Текущий режим: Xray Fallback.${PLAIN}"
    print_xray_fallback_mode_explanation
}

list_xray_sni_routes() {
    load_sni_stack_env || return 1
    local mode fallback_idx
    mode=$(get_entry_mode)
    fallback_idx=$(xray_fallback_main_route_index 2>/dev/null || true)
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Правила маршрутизации Xray-входящих${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "Файл конфигурации: $(xray_sni_routes_path)"
    echo -e "Формат правил: SNI|ADDR|PORT"
    if [[ "$mode" == "xray-fallback" ]]; then
        echo -e "------------------------------------------------"
        xray_sni_routes_fallback_notice
        print_xray_fallback_main_route_summary
    fi
    echo -e "------------------------------------------------"
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет правил маршрутизации Xray-входящих.${PLAIN}"
        if [[ -n "${XRAY_LISTEN_PORT:-}" ]]; then
            echo -e "${CYAN}Старый бэкенд Xray/REALITY по умолчанию: ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}${PLAIN}"
            echo -e "${CYAN}Если нужно несколько локальных Xray-входящих, добавьте новые записи по SNI.${PLAIN}"
        fi
        return 0
    fi

    local i num
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        num=$((i + 1))
        if [[ "$mode" == "xray-fallback" && -n "$fallback_idx" && "$i" == "$fallback_idx" ]]; then
            echo -e "${GREEN}${num}.${PLAIN} ${XRAY_SNI_ROUTE_SNIS[$i]} -> ${XRAY_SNI_ROUTE_ADDRS[$i]}:${XRAY_SNI_ROUTE_PORTS[$i]} ${GREEN}[основной входящий xray-fallback, действует в текущем режиме]${PLAIN}"
        elif [[ "$mode" == "xray-fallback" ]]; then
            echo -e "${GREEN}${num}.${PLAIN} ${XRAY_SNI_ROUTE_SNIS[$i]} -> ${XRAY_SNI_ROUTE_ADDRS[$i]}:${XRAY_SNI_ROUTE_PORTS[$i]} ${YELLOW}[сохранён, в текущем режиме xray-fallback не действует]${PLAIN}"
        else
            echo -e "${GREEN}${num}.${PLAIN} ${XRAY_SNI_ROUTE_SNIS[$i]} -> ${XRAY_SNI_ROUTE_ADDRS[$i]}:${XRAY_SNI_ROUTE_PORTS[$i]}"
        fi
    done
}

add_xray_sni_route() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Добавление правила маршрутизации Xray-входящего${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    echo -e "${YELLOW}Этот пункт только записывает SNI -> локальный адрес:порт; используется для генерации правил маршрутизации в поддерживаемых режимах, не создаёт, не удаляет и не изменяет внутреннюю конфигурацию 3x-ui/Xray-входящих.${PLAIN}"
    echo -e "------------------------------------------------"

    local route_sni route_sni_input route_addr route_port existing idx
    read_trimmed route_sni_input "SNI/домен: "
    route_sni=$(normalize_domain_input "$route_sni_input")
    if [[ -z "$route_sni" || "$route_sni" == "0" ]]; then
        echo -e "${BLUE}Добавление отменено.${PLAIN}"
        return 0
    fi
    is_valid_domain "$route_sni" || { print_domain_validation_error "SNI/домен" "$route_sni_input" "$route_sni"; return 1; }
    if [[ "$route_sni" == "$PANEL_DOMAIN" || "$route_sni" == "$REALITY_SNI" ]]; then
        echo -e "${RED}❌ Xray-входящий не может совпадать с доменом панели или REALITY SNI.${PLAIN}"
        return 1
    fi
    for existing in "${SITE_DOMAINS[@]}"; do
        [[ "$route_sni" == "$existing" ]] && { echo -e "${RED}❌ Этот домен уже используется как веб-домен, Xray-входящий должен быть отдельным.${PLAIN}"; return 1; }
    done
    for existing in "${TCP_ROUTE_SNIS[@]}"; do
        [[ "$route_sni" == "$existing" ]] && { echo -e "${RED}❌ Этот домен уже существует в старых правилах TCP/SNI локальных входящих.${PLAIN}"; return 1; }
    done
    for existing in "${XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ "$route_sni" == "$existing" ]] && { echo -e "${RED}❌ Это правило Xray-входящего уже существует.${PLAIN}"; return 1; }
    done

    route_addr=$(ask_with_default "Локальный адрес прослушивания" "127.0.0.1")
    route_addr=$(normalize_loopback_addr "$route_addr")
    route_port=$(ask_with_default "Локальный порт прослушивания" "${XRAY_LISTEN_PORT:-1443}")
    is_loopback_listen_addr "$route_addr" || { echo -e "${RED}❌ Во избежание публичного доступа локальный адрес прослушивания разрешён только 127.0.0.1, localhost или ::1.${PLAIN}"; return 1; }
    is_valid_port "$route_port" || { echo -e "${RED}❌ Неверный локальный порт: ${route_port}${PLAIN}"; return 1; }
    if [[ "$route_port" == "$CADDY_LISTEN_PORT" ]]; then
        echo -e "${RED}❌ Этот порт конфликтует с локальным портом Web-прокси ${CADDY_LISTEN_PORT}.${PLAIN}"
        return 1
    fi
    if [[ "$route_port" == "$NGINX_LISTEN_PORT" || "$route_port" == "$PANEL_LISTEN_PORT" || "$route_port" == "$SUB_LISTEN_PORT" ]]; then
        echo -e "${RED}❌ Порт входящего не может совпадать с публичным входом, панелью или подпиской.${PLAIN}"
        return 1
    fi
    existing=$(xray_sni_route_port_conflict "$route_addr" "$route_port" || true)
    if [[ -n "$existing" ]]; then
        echo -e "${RED}❌ ${route_addr}:${route_port} уже используется правилом ${existing}.${PLAIN}"
        return 1
    fi

    print_xray_route_port_status "$route_sni" "$route_addr" "$route_port"
    if [[ -z "$(xray_route_listen_line_by_addr_port "$route_addr" "$route_port")" ]]; then
        echo -e "${RED}❌ Порт не слушается, сначала создайте и включите соответствующий входящий в 3x-ui.${PLAIN}"
        return 1
    fi

    idx=${#XRAY_SNI_ROUTE_SNIS[@]}
    XRAY_SNI_ROUTE_SNIS[$idx]="$route_sni"
    XRAY_SNI_ROUTE_ADDRS[$idx]="$route_addr"
    XRAY_SNI_ROUTE_PORTS[$idx]="$route_port"
    save_xray_sni_route_arrays
    echo -e "${GREEN}✅ Сохранено правило маршрутизации Xray-входящего: ${route_sni} -> ${route_addr}:${route_port}${PLAIN}"
    echo -e "${YELLOW}Примечание: после сохранения необходимо выполнить "синхронизацию с текущим режимом" или повторно применить текущий режим входа, чтобы публичный 443 использовал новое правило.${PLAIN}"
}

remove_xray_sni_route() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Удаление правила маршрутизации Xray-входящего${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    load_sni_stack_env || return 1
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет правил маршрутизации Xray-входящих для удаления.${PLAIN}"
        return 0
    fi

    local i num choice idx route_sni
    local -a new_snis=() new_addrs=() new_ports=()
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        num=$((i + 1))
        echo -e "${GREEN}${num}.${PLAIN} ${XRAY_SNI_ROUTE_SNIS[$i]} -> ${XRAY_SNI_ROUTE_ADDRS[$i]}:${XRAY_SNI_ROUTE_PORTS[$i]}"
    done
    echo -e "------------------------------------------------"
    read_trimmed choice "Введите номер для удаления: "
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo -e "${BLUE}Удаление отменено.${PLAIN}"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#XRAY_SNI_ROUTE_SNIS[@]} )); then
        echo -e "${RED}❌ Неверный номер.${PLAIN}"
        return 1
    fi

    idx=$((choice - 1))
    route_sni="${XRAY_SNI_ROUTE_SNIS[$idx]}"
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        [[ "$i" -eq "$idx" ]] && continue
        new_snis+=("${XRAY_SNI_ROUTE_SNIS[$i]}")
        new_addrs+=("${XRAY_SNI_ROUTE_ADDRS[$i]}")
        new_ports+=("${XRAY_SNI_ROUTE_PORTS[$i]}")
    done
    XRAY_SNI_ROUTE_SNIS=("${new_snis[@]}")
    XRAY_SNI_ROUTE_ADDRS=("${new_addrs[@]}")
    XRAY_SNI_ROUTE_PORTS=("${new_ports[@]}")
    save_xray_sni_route_arrays
    echo -e "${GREEN}✅ Удалено правило маршрутизации Xray-входящего: ${route_sni}${PLAIN}"
    echo -e "${YELLOW}Примечание: после удаления выполните синхронизацию с текущим режимом или повторно примените текущий режим входа.${PLAIN}"
}

check_xray_sni_route_ports() {
    load_sni_stack_env || return 1
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Проверка состояния портов Xray-входящих${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}В данный момент нет правил маршрутизации Xray-входящих.${PLAIN}"
        return 0
    fi

    local i
    for i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
        print_xray_route_port_status "${XRAY_SNI_ROUTE_SNIS[$i]}" "${XRAY_SNI_ROUTE_ADDRS[$i]}" "${XRAY_SNI_ROUTE_PORTS[$i]}"
        echo -e "------------------------------------------------"
    done
}

sync_xray_sni_routes_to_entry_mode() {
    load_sni_stack_env || return 1
    local mode
    mode=$(get_entry_mode)
    case "$mode" in
        "nginx-stream")
            echo -e "${CYAN}Синхронизация правил маршрутизации Xray-входящих с конфигурацией Nginx Stream...${PLAIN}"
            reapply_sni_stack_from_env --yes
            ;;
        "tcp-peek")
            local tmp_config target_config
            echo -e "${CYAN}Синхронизация правил маршрутизации Xray-входящих с конфигурацией TCP Peek + Splice...${PLAIN}"
            target_config=$(vpso_mux_config_path)
            tmp_config="${target_config}.tmp.$$"
            write_vpso_mux_config_from_sni_stack "$NGINX_LISTEN_PORT" "$tmp_config" || return 1
            if ! run_vpso_mux_config_check "$tmp_config"; then
                quarantine_path "$tmp_config" "/etc/vps-optimize/quarantine/vpso-mux" >/dev/null 2>&1 || true
                return 1
            fi
            mv "$tmp_config" "$target_config" || { echo -e "${RED}❌ Не удалось заменить конфигурацию TCP Peek + Splice: ${target_config}${PLAIN}"; return 1; }
            if systemctl is-active --quiet vpso-mux 2>/dev/null; then
                systemctl restart vpso-mux || { print_vpso_mux_failure_context "$NGINX_LISTEN_PORT"; echo -e "${RED}❌ Не удалось перезапустить vpso-mux, проверьте логи выше.${PLAIN}"; return 1; }
            else
                echo -e "${YELLOW}Разделитель vpso-mux в данный момент не запущен, только сгенерирована и проверена конфигурация.${PLAIN}"
            fi
            echo -e "${GREEN}✅ Синхронизировано с конфигурацией TCP Peek + Splice: ${target_config}${PLAIN}"
            ;;
        "xray-fallback")
            xray_sni_routes_fallback_notice
            return 1
            ;;
        *)
            echo -e "${RED}❌ Текущий ENTRY_MODE недействителен или не настроен: ${mode}${PLAIN}"
            return 1
            ;;
    esac
}

manage_xray_inbound_routes() {
    load_sni_stack_env || return 1
    if [[ "$(get_entry_mode)" == "xray-fallback" ]]; then
        while true; do
            clear
            echo -e "${CYAN}================================================${PLAIN}"
            echo -e "${BOLD}Управление Xray-входящими${PLAIN}"
            echo -e "${CYAN}================================================${PLAIN}"
            xray_sni_routes_fallback_notice
            print_xray_fallback_main_route_summary
            echo -e "------------------------------------------------"
            echo -e "${GREEN}  1. Просмотр правил маршрутизации${PLAIN}"
            echo -e "${YELLOW}  2. Добавить правило (недоступно в текущем режиме)${PLAIN}"
            echo -e "${YELLOW}  3. Удалить правило (недоступно в текущем режиме)${PLAIN}"
            echo -e "${YELLOW}  4. Синхронизировать с текущим режимом (недоступно)${PLAIN}"
            echo -e "------------------------------------------------"
            echo -e "${RED}  0. Вернуться / q${PLAIN}"
            echo -e "${CYAN}================================================${PLAIN}"

            local fallback_choice
            read_trimmed fallback_choice "Выберите действие: "
            case "$fallback_choice" in
                1) list_xray_sni_routes ;;
                2|3|4)
                    echo -e "${YELLOW}В режиме xray-fallback управление Xray-входящими по умолчанию не позволяет добавлять, удалять или синхронизировать правила.${PLAIN}"
                    echo -e "${YELLOW}Если нужна маршрутизация по SNI на несколько локальных Xray-входящих через 443, переключитесь на nginx-stream или tcp-peek.${PLAIN}"
                    ;;
                0|q|Q) break ;;
                *) echo -e "${RED}❌ Неверный выбор.${PLAIN}" ;;
            esac
            echo ""
            read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        done
        return 0
    fi

    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}Управление Xray-входящими${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Управляет только записями SNI -> локальный адрес:порт для маршрутизации, используется для генерации правил в поддерживаемых режимах; не редактирует внутреннюю конфигурацию 3x-ui/Xray-входящих.${PLAIN}"
        echo -e "Файл конфигурации: $(xray_sni_routes_path)"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Просмотр правил маршрутизации${PLAIN}"
        echo -e "${GREEN}  2. Добавить правило${PLAIN}"
        echo -e "${GREEN}  3. Удалить правило${PLAIN}"
        echo -e "${GREEN}  4. Проверить состояние портов${PLAIN}"
        echo -e "${GREEN}  5. Синхронизировать с текущим режимом${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice
        read_trimmed choice "Выберите действие: "
        case "$choice" in
            1) list_xray_sni_routes ;;
            2) add_xray_sni_route ;;
            3) remove_xray_sni_route ;;
            4) check_xray_sni_route_ports ;;
            5) sync_xray_sni_routes_to_entry_mode ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор.${PLAIN}" ;;
        esac
        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}

manage_sni_stack_tcp_routes() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}Управление Xray-входящими${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: записывает уже настроенные вами локальные входящие в 3x-ui/Xray: SNI -> локальный адрес:порт.${PLAIN}"
        echo -e "${YELLOW}Эти записи используются для генерации правил маршрутизации в поддерживаемых режимах; скрипт не открывает новые порты и не изменяет внутреннюю конфигурацию 3x-ui/Xray-входящих.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Просмотр текущих TCP/SNI входящих${PLAIN}"
        echo -e "${GREEN}  2. Добавить TCP/SNI входящий${PLAIN}"
        echo -e "${GREEN}  3. Изменить TCP/SNI входящий${PLAIN}"
        echo -e "${GREEN}  4. Удалить TCP/SNI входящий${PLAIN}"
        echo -e "${BLUE}  5. Просмотр области применения веб-белых списков${PLAIN}"
        echo -e "${GREEN}  6. Повторно применить и перезапустить Nginx/Caddy${PLAIN}"
        echo -e "${GREEN}  7. Проверка цепочки единого входа 443${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1) list_sni_stack_tcp_routes ;;
            2) add_sni_stack_tcp_route ;;
            3) edit_sni_stack_tcp_route ;;
            4) remove_sni_stack_tcp_route ;;
            5)
                echo -e "${YELLOW}Веб-белые списки применяются только к веб-доменам: панели, подписке, обычным сайтам, панельному домену и пользовательским прокси-доменам.${PLAIN}"
                echo -e "${YELLOW}TCP/SNI входящие и Xray-узлы не используют IP-белые списки; если нужно ограничить источники, делайте это на стороне бэкенда или брандмауэра.${PLAIN}"
                ;;
            6) reapply_sni_stack_from_env ;;
            7) sni_stack_health_check ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}" ;;
        esac
        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}

manage_sni_stack_ip_whitelist() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🔐 IP-белые списки доменов 443${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        load_sni_stack_env || return 1
        local whitelist_supported="yes"
        if ! web_proxy_engine_supports_web_whitelist "${ENTRY_MODE:-$(get_entry_mode)}" "${WEB_PROXY_ENGINE:-caddy}"; then
            whitelist_supported="no"
        fi
        echo -e "${YELLOW}Ограничивает только выбранные веб-домены; поддерживает панель, подписку, сайты/прокси; Xray-входящие, REALITY SNI и неизвестный SNI не затрагиваются веб-белыми списками.${PLAIN}"
        echo -e "${YELLOW}В режиме Nginx Stream/TCP Peek перехват происходит на уровне входа по SNI + IP, не влияя на другие службы того же входа.${PLAIN}"
        if [[ "$whitelist_supported" != "yes" ]]; then
            echo -e "${RED}Текущий режим xray-fallback, локальный Web-прокси не может надёжно получить реальный IP клиента, добавление или перезапись веб-белых списков запрещена.${PLAIN}"
            echo -e "${YELLOW}Вы всё ещё можете очистить существующие белые списки; если нужен белый список, переключитесь на Nginx Stream/TCP Peek.${PLAIN}"
        fi
        echo -e "------------------------------------------------"

        local -a domains=("$PANEL_DOMAIN")
        local -a labels=("Панель/подписка")
        local site_domain i num domain current_ranges
        for site_domain in "${SITE_DOMAINS[@]}"; do
            [[ -z "$site_domain" ]] && continue
            domains+=("$site_domain")
            labels+=("Сайт/прокси")
        done
        for i in "${!domains[@]}"; do
            num=$((i + 1))
            current_ranges=$(sni_ip_whitelist_ranges_for_domain "${domains[$i]}")
            if [[ -n "$current_ranges" ]]; then
                echo -e "${GREEN}${num}.${PLAIN} [${labels[$i]}] ${domains[$i]}  ${YELLOW}разрешено: ${current_ranges}${PLAIN}"
            else
                echo -e "${GREEN}${num}.${PLAIN} [${labels[$i]}] ${domains[$i]}  ${BLUE}не включён${PLAIN}"
            fi
        done
        echo -e "------------------------------------------------"
        echo -e "${RED}0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice idx action whitelist_input whitelist_ranges current_client_ip
        local -a whitelist_array=()
        read_trimmed choice "Введите номер домена для управления: "
        [[ "$choice" == "0" || -z "$choice" ]] && break
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#domains[@]} )); then
            echo -e "${RED}❌ Неверный номер.${PLAIN}"
            pause_return
            continue
        fi

        idx=$((choice - 1))
        domain="${domains[$idx]}"
        current_ranges=$(sni_ip_whitelist_ranges_for_domain "$domain")
        echo -e "Текущий домен: ${domain}"
        echo -e "Текущий белый список: ${current_ranges:-не включён}"
        echo -e "1. Установить/перезаписать белый список"
        echo -e "2. Очистить белый список"
        echo -e "0/q. Отмена"
        read_trimmed action "Выберите действие: "
        case "$action" in
            1)
                if [[ "$whitelist_supported" != "yes" ]]; then
                    echo -e "${RED}❌ Текущая комбинация запрещает установку веб-белого списка. Сначала переключите режим входа или Web-прокси.${PLAIN}"
                    pause_return
                    continue
                fi
                current_client_ip=$(detect_ssh_client_ip)
                [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен.${PLAIN}"
                read_trimmed whitelist_input "Введите IP/CIDR, разрешённые для ${domain} (несколько через пробел или запятую): "
                if ! normalize_ip_whitelist_input "$whitelist_input" whitelist_array; then
                    echo -e "${RED}❌ Белый список пуст или неверный формат, отмена.${PLAIN}"
                    pause_return
                    continue
                fi
                append_vps_public_ips_to_whitelist whitelist_array
                whitelist_ranges=$(join_array_by_space "${whitelist_array[@]}")
                confirm_risk_action "Включить IP-белый список для ${domain}" \
                    "На уровне входа 443 будет ограничен доступ по IP для этого SNI" \
                    "Используйте автоматическую резервную копию единого входа 443 для отката или очистите белый список для этого домена и повторно примените" \
                    "Убедитесь, что ваш управляющий IP включён в белый список, и этот домен не использует оранжевое облако Cloudflare." || continue
                set_sni_ip_whitelist_for_domain "$domain" "$whitelist_ranges"
                save_and_offer_reapply_sni_stack
                ;;
            2)
                if [[ -z "$current_ranges" ]]; then
                    echo -e "${BLUE}Для этого домена белый список не включён.${PLAIN}"
                    pause_return
                    continue
                fi
                confirm_risk_action "Очистить IP-белый список для ${domain}" \
                    "Этот домен вернётся к обычному доступу через 443" \
                    "Заново установите белый список для этого домена" \
                    "Убедитесь, что это желаемая политика доступа." || continue
                remove_sni_ip_whitelist_for_domain "$domain"
                save_and_offer_reapply_sni_stack
                ;;
            0|q|Q|"")
                ;;
            *)
                echo -e "${RED}❌ Неверное действие.${PLAIN}"
                pause_return
                ;;
        esac
    done
}

# ---------------------------------------------------------
# Module: sni_stack_menus.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Вторичные меню единого входа 443 для сайтов, маршрутов и управления веб-белыми списками.

manage_sni_stack_sites() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🌐 Управление веб-доменами/прокси 443${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: для уже настроенного единого входа 443 — добавлять, удалять или просматривать веб-домены/прокси.${PLAIN}"
        echo -e "${YELLOW}Последующие добавления сайтов не требуют повторной первичной настройки, достаточно указать домен и локальный порт бэкенда.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Просмотр текущих веб-доменов/прокси${PLAIN}"
        echo -e "${GREEN}  2. Добавить веб-домен/прокси${PLAIN}"
        echo -e "${GREEN}  3. Изменить бэкенд веб-домена/прокси${PLAIN}"
        echo -e "${GREEN}  4. Удалить веб-домен/прокси${PLAIN}"
        echo -e "${GREEN}  5. Управление IP-белыми списками доменов${PLAIN}       ${YELLOW}(ограничивает только выбранные домены)${PLAIN}"
        echo -e "${GREEN}  6. Повторно применить и перезапустить Nginx/Caddy${PLAIN}"
        echo -e "${GREEN}  7. Проверка цепочки единого входа 443${PLAIN}"
        echo -e "${GREEN}  8. Переключить Web-прокси${PLAIN}       ${YELLOW}(Caddy / Nginx локальный прокси)${PLAIN}"
        echo -e "${GREEN}  9. Изменить домен панели${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться на уровень выше / q/back/return${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice
        read_trimmed choice "👉 Введите номер меню или ?: "
        case "$choice" in
            1) list_sni_stack_sites ;;
            2) add_sni_stack_site ;;
            3) edit_sni_stack_site_backend ;;
            4) remove_sni_stack_site ;;
            5) manage_sni_stack_ip_whitelist ;;
            6) reapply_sni_stack_from_env ;;
            7) sni_stack_health_check ;;
            8) switch_sni_stack_web_proxy_engine ;;
            9) edit_sni_stack_panel_domain_profile ;;
            "?"|help) show_sni_help; pause_return; continue ;;
            0) break ;;
            *) echo -e "${RED}❌ Неверный выбор, введите номер меню или ?.${PLAIN}" ;;
        esac
        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}

# ---------------------------------------------------------
# Module: caddy_maintenance.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Обслуживание сертификатов Cloudflare/Caddy, восстановление конфигурации Caddy, белые списки и инструменты очистки.

func_caddy_cf_reality_wizard() {
    if [[ -f /etc/vps-optimize/sni-stack.env ]]; then
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}Обнаружена существующая конфигурация единого входа 443${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Если вы просто хотите добавить новый сайт или прокси-домен, вернитесь и выберите [8] Управление веб-доменами/прокси.${PLAIN}"
        echo -e "${YELLOW}Продолжение первичной настройки перезапишет основные конфигурации входа 443, Web-прокси и маршрутизации Xray.${PLAIN}"
        echo -e "------------------------------------------------"
        grep -E '^(PANEL_DOMAIN|PANEL_WEB_PATH|REALITY_SNI|NGINX_LISTEN_ADDR|NGINX_LISTEN_PORT|CADDY_LISTEN_PORT|XRAY_LISTEN_PORT|SUB_URI_PATH|CLASH_URI_PATH)=' /etc/vps-optimize/sni-stack.env 2>/dev/null || true
        echo -e "------------------------------------------------"
        confirm_danger "Повторное выполнение первичной настройки 443" "Будет перезаписана основная конфигурация единого входа 443 на основе новых данных, и перезапущены службы входа/Caddy." "Скрипт сначала создаст резервную копию; можно откатить из меню обслуживания 443 или из каталога резервных копий." || return 1
    fi
    select_initial_entry_mode || return 1
    collect_sni_stack_config || return 1
    probe_reality_sni "$REALITY_SNI" || return 1
    print_sni_stack_preview || return 1
    guard_current_ssh_not_on_entry_port "Первичная настройка единого входа 443" || return 1
    local cf_env_dir="/root/.config/vps-panel"
    local cf_env_file="${cf_env_dir}/cloudflare.env"
    local escaped_token
    mkdir -p "$cf_env_dir"
    chmod 700 "$cf_env_dir"
    escaped_token=${CF_TOKEN//\'/\'"\'"\'}
    printf "CF_Token='%s'\n" "$escaped_token" > "$cf_env_file"
    chmod 600 "$cf_env_file"

    local backup_dir
    backup_dir=$(backup_entry_mode_config) || return 1
    prepare_initial_entry_mode_dependencies "$ENTRY_MODE" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка проверки зависимостей режима входа"; return 1; }
    quarantine_legacy_caddy_443_configs
    quarantine_legacy_nginx_https_proxy_configs
    issue_and_install_cert_for_domain "$PANEL_DOMAIN" "$CF_TOKEN" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка выдачи/установки сертификата для домена панели"; return 1; }
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local site_domain
        for site_domain in "${SITE_DOMAINS[@]}"; do
            [[ -z "$site_domain" ]] && continue
            issue_and_install_cert_for_domain "$site_domain" "$CF_TOKEN" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка выдачи/установки сертификата для домена ${site_domain}"; return 1; }
        done
    fi
    preflight_entry_mode_before_cutover "$ENTRY_MODE" || { rollback_sni_stack_after_failure "$backup_dir" "Предпроверка режима ${ENTRY_MODE} не удалась, публичный 443 не переключён"; return 1; }
    stop_public_443_entry_services_for_target "$ENTRY_MODE" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка остановки старых служб публичного 443"; return 1; }
    apply_entry_mode_by_name "$ENTRY_MODE" "$backup_dir" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка применения режима ${ENTRY_MODE}"; return 1; }
    save_sni_stack_env
    harden_single_443_firewall
    generate_caddy_cf_manifest
    print_sni_stack_result
}

func_caddy_cf_health_check() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🩺 Быстрая проверка CF DNS${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local ok_count=0
    local warn_count=0
    local err_count=0
    local cf_env_file="/root/.config/vps-panel/cloudflare.env"

    echo -e "${YELLOW}▶ [1/5] Проверка Cloudflare Token ...${PLAIN}"
    if [[ -f "$cf_env_file" ]]; then
        # shellcheck disable=SC1090
        source "$cf_env_file"
        if [[ -n "$CF_Token" ]]; then
            if command -v curl >/dev/null 2>&1; then
                local verify_resp
                verify_resp=$(curl -s --max-time 8 -H "Authorization: Bearer ${CF_Token}" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)
                if echo "$verify_resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
                    echo -e "${GREEN}✅ Проверка Cloudflare Token пройдена${PLAIN}"
                    ((ok_count++))
                else
                    echo -e "${YELLOW}⚠️ Файл Token существует, но онлайн-проверка не удалась (возможно, недостаточно прав/сетевые проблемы)${PLAIN}"
                    ((warn_count++))
                fi
            else
                echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку.${PLAIN}"
                ((warn_count++))
            fi
        else
            echo -e "${RED}❌ Файл Token пуст, перезапишите в меню обслуживания [2].${PLAIN}"
            ((err_count++))
        fi
    else
        echo -e "${RED}❌ Файл Token не найден: ${cf_env_file}${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [2/5] Проверка состояния службы Caddy...${PLAIN}"
    if command -v caddy >/dev/null 2>&1; then
        if systemctl is-active --quiet caddy; then
            echo -e "${GREEN}✅ Caddy работает${PLAIN}"
            ((ok_count++))
        else
            echo -e "${YELLOW}⚠️ Caddy установлен, но не запущен${PLAIN}"
            ((warn_count++))
        fi
    else
        echo -e "${RED}❌ Caddy не установлен${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [3/5] Проверка конфигураций доменов, сертификатов и символических ссылок...${PLAIN}"
    local domain_count=0
    if [[ -d /etc/caddy/conf.d ]]; then
        while IFS= read -r conf_file; do
            local domain
            local listen_addr
            local listen_port
            local listen_target
            local backend
            local backend_addr
            local backend_port
            local cert_file
            local key_file
            local cert_end
            local cert_ts
            local now_ts
            local days_left

            domain=$(basename "$conf_file" .caddy)
            cert_file="/etc/caddy/certs/${domain}.crt"
            key_file="/etc/caddy/certs/${domain}.key"

            if ! head -n1 "$conf_file" | grep -q '^https://'; then
                continue
            fi
            ((domain_count++))

            listen_addr=$(caddy_conf_site_bind_addr "$conf_file")
            listen_port=$(caddy_conf_site_listen_port "$conf_file")
            listen_target=$(caddy_conf_site_listen_target "$conf_file")
            backend=$(caddy_conf_first_reverse_proxy_target "$conf_file")
            backend_addr=$(caddy_reverse_proxy_target_host "$backend")
            backend_port=$(caddy_reverse_proxy_target_port "$backend")

            echo -e "${CYAN}  - Домен: ${domain}${PLAIN}"

            if [[ -f "$cert_file" && -f "$key_file" ]]; then
                cert_end=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2-)
                cert_ts=$(date -d "$cert_end" +%s 2>/dev/null)
                now_ts=$(date +%s)
                days_left=$(( (cert_ts - now_ts) / 86400 ))

                if [[ -n "$cert_end" && "$days_left" -gt 15 ]]; then
                    echo -e "    ${GREEN}Сертификат: норма (осталось ${days_left} дн.)${PLAIN}"
                    ((ok_count++))
                elif [[ -n "$cert_end" ]]; then
                    echo -e "    ${YELLOW}Сертификат: скоро истекает (осталось ${days_left} дн.)${PLAIN}"
                    ((warn_count++))
                else
                    echo -e "    ${RED}Сертификат: не удалось прочитать срок действия${PLAIN}"
                    ((err_count++))
                fi
            else
                echo -e "    ${RED}Сертификат отсутствует: /etc/caddy/certs/${domain}.crt|.key${PLAIN}"
                ((err_count++))
            fi

            if [[ -L "/root/cert/${domain}.crt" && -e "/root/cert/${domain}.crt" && -L "/root/cert/${domain}.key" && -e "/root/cert/${domain}.key" ]]; then
                echo -e "    ${GREEN}Символические ссылки: /root/cert правильно${PLAIN}"
                ((ok_count++))
            else
                echo -e "    ${YELLOW}Символические ссылки: отсутствуют или повреждены, выполните обслуживание [10] для восстановления${PLAIN}"
                ((warn_count++))
            fi

            [[ -z "$listen_target" ]] && listen_target="неизвестно"
            if [[ -n "$listen_port" ]] && caddy_listen_addr_port_is_visible "$listen_addr" "$listen_port"; then
                echo -e "    ${GREEN}Прослушивание: локальный порт ${listen_target} виден${PLAIN}"
                ((ok_count++))
            else
                echo -e "    ${YELLOW}Прослушивание: не обнаружено ${listen_target}${PLAIN}"
                ((warn_count++))
            fi

            [[ -z "$backend" ]] && backend="неизвестно"
            if [[ -z "$backend_addr" || -z "$backend_port" ]]; then
                echo -e "    ${YELLOW}⚠️ Бэкенд: не удалось прочитать адрес бэкенда из конфигурации${PLAIN}"
                ((warn_count++))
            elif probe_backend_target "    Бэкенд" "$backend_addr" "$backend_port"; then
                ((ok_count++))
            else
                ((warn_count++))
            fi
        done < <(find /etc/caddy/conf.d -maxdepth 1 -type f -name "*.caddy" 2>/dev/null | sort)
    fi

    if [[ "$domain_count" -eq 0 ]]; then
        echo -e "${YELLOW}⚠️ Не обнаружено конфигураций доменов, управляемых этой функцией (https://домен:порт).${PLAIN}"
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [4/5] Проверка файла манифеста...${PLAIN}"
    if [[ -f /root/cert/caddy_cf_manifest.txt ]]; then
        echo -e "${GREEN}✅ Файл манифеста существует: /root/cert/caddy_cf_manifest.txt${PLAIN}"
        ((ok_count++))
    else
        echo -e "${YELLOW}⚠️ Файл манифеста отсутствует, выполните обслуживание [11] для восстановления.${PLAIN}"
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [5/5] Итог...${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${CYAN}Результат проверки: ${GREEN}${ok_count} OK${PLAIN} / ${YELLOW}${warn_count} предупреждений${PLAIN} / ${RED}${err_count} ошибок${PLAIN}"
    if [[ "$err_count" -gt 0 ]]; then
        echo -e "${RED}Рекомендуется сначала исправить ошибки перед переключением трафика.${PLAIN}"
    elif [[ "$warn_count" -gt 0 ]]; then
        echo -e "${YELLOW}Можно продолжать, но рекомендуется обработать предупреждения для повышения стабильности.${PLAIN}"
    else
        echo -e "${GREEN}Проверка не выявила проблем.${PLAIN}"
    fi
}

func_caddy_cf_auto_fix() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧰 Автоматическое исправление CF DNS${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local fixed_count=0
    local warn_count=0
    local fail_count=0
    local cf_env_file="/root/.config/vps-panel/cloudflare.env"
    local acme_bin="/root/.acme.sh/acme.sh"

    echo -e "${YELLOW}▶ [1/7] Восстановление базовых каталогов и основной конфигурации...${PLAIN}"
    mkdir -p /root/cert /etc/caddy/certs /etc/caddy/conf.d /root/.config/vps-panel
    chmod 700 /root/.config/vps-panel >/dev/null 2>&1

    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        cat <<EOF > /etc/caddy/Caddyfile
# Управляется VPS-Optimize
import conf.d/*
EOF
        ((fixed_count++))
    elif ! grep -q "import conf.d/\*" /etc/caddy/Caddyfile; then
        echo -e "\nimport conf.d/*" >> /etc/caddy/Caddyfile
        ((fixed_count++))
    fi

    echo -e "${YELLOW}▶ [1.5/7] Изоляция старых конфигураций сайтов (во избежание захвата 443)...${PLAIN}"
    quarantine_legacy_caddy_443_configs

    echo -e "${YELLOW}▶ [2/7] Восстановление прав на сертификаты...${PLAIN}"
    if [[ -d /etc/caddy/certs ]]; then
        if id caddy >/dev/null 2>&1; then
            chown root:caddy /etc/caddy/certs/* 2>/dev/null
            chmod 640 /etc/caddy/certs/* 2>/dev/null
        else
            chmod 600 /etc/caddy/certs/* 2>/dev/null
        fi
        ((fixed_count++))
    else
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [3/7] Полное восстановление символических ссылок /root/cert...${PLAIN}"
    local relink_count=0
    if [[ -d /etc/caddy/certs ]]; then
        while IFS= read -r cert_path; do
            local domain
            domain=$(basename "$cert_path" .crt)
            if [[ -f "/etc/caddy/certs/${domain}.key" ]]; then
                ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
                ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
                ((relink_count++))
            fi
        done < <(find /etc/caddy/certs -maxdepth 1 -type f -name "*.crt" 2>/dev/null | sort)
    fi
    echo -e "${GREEN}✅ Восстановлено ${relink_count} групп символических ссылок.${PLAIN}"
    ((fixed_count++))

    echo -e "${YELLOW}▶ [4/7] Автоматическое продление сертификатов с истекающим сроком...${PLAIN}"
    local renew_count=0
    local renew_fail=0
    if [[ -x "$acme_bin" && -f "$cf_env_file" ]]; then
        # shellcheck disable=SC1090
        source "$cf_env_file"
        if [[ -n "$CF_Token" ]]; then
            while IFS= read -r conf_file; do
                local domain
                local cert_file
                local cert_end
                local cert_ts
                local now_ts
                local days_left

                domain=$(basename "$conf_file" .caddy)
                cert_file="/etc/caddy/certs/${domain}.crt"

                if ! head -n1 "$conf_file" | grep -q '^https://'; then
                    continue
                fi
                if [[ ! -f "$cert_file" ]]; then
                    continue
                fi

                cert_end=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2-)
                cert_ts=$(date -d "$cert_end" +%s 2>/dev/null)
                now_ts=$(date +%s)
                days_left=$(( (cert_ts - now_ts) / 86400 ))

                if [[ -z "$cert_end" || "$days_left" -le 15 ]]; then
                    if issue_cf_dns_cert_with_retry "$domain" "$CF_Token" "$acme_bin"; then
                        "$acme_bin" --install-cert -d "$domain" --ecc \
                            --fullchain-file "/etc/caddy/certs/${domain}.crt" \
                            --key-file "/etc/caddy/certs/${domain}.key" \
                            --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true" >/dev/null 2>&1
                        ((renew_count++))
                    else
                        ((renew_fail++))
                    fi
                fi
            done < <(find /etc/caddy/conf.d -maxdepth 1 -type f -name "*.caddy" 2>/dev/null | sort)

            if [[ "$renew_fail" -gt 0 ]]; then
                ((warn_count+=renew_fail))
            fi
            echo -e "${GREEN}✅ Автоматическое продление выполнено: успешно ${renew_count}, ошибок ${renew_fail}.${PLAIN}"
            ((fixed_count++))
        else
            echo -e "${YELLOW}⚠️ Token пуст, пропускаем автоматическое продление.${PLAIN}"
            ((warn_count++))
        fi
    else
        echo -e "${YELLOW}⚠️ acme.sh или файл Token не обнаружены, пропускаем автоматическое продление.${PLAIN}"
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [5/7] Проверка и перезагрузка Caddy...${PLAIN}"
    if command -v caddy >/dev/null 2>&1; then
        if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
            systemctl enable caddy >/dev/null 2>&1
            if systemctl restart caddy >/dev/null 2>&1; then
                echo -e "${GREEN}✅ Проверка конфигурации Caddy пройдена, перезапуск успешен.${PLAIN}"
                ((fixed_count++))
            else
                echo -e "${RED}❌ Перезапуск Caddy не удался, проверьте логи вручную.${PLAIN}"
                ((fail_count++))
            fi
        else
            echo -e "${RED}❌ Проверка конфигурации Caddy не удалась, перезапуск не выполнен.${PLAIN}"
            ((fail_count++))
        fi
    else
        echo -e "${RED}❌ Caddy не установлен, невозможно выполнить перезагрузку.${PLAIN}"
        ((fail_count++))
    fi

    echo -e "${YELLOW}▶ [6/7] Восстановление файла манифеста...${PLAIN}"
    generate_caddy_cf_manifest
    ((fixed_count++))
    echo -e "${GREEN}✅ Манифест восстановлен: /root/cert/caddy_cf_manifest.txt${PLAIN}"

    echo -e "${YELLOW}▶ [7/7] Дополнение задачи автоматического продления acme...${PLAIN}"
    if [[ -x "$acme_bin" ]]; then
        if "$acme_bin" --install-cronjob >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Задача автоматического продления acme.sh подтверждена.${PLAIN}"
            ((fixed_count++))
        else
            echo -e "${YELLOW}⚠️ Не удалось подтвердить задачу продления acme.sh, проверьте crontab вручную.${PLAIN}"
            ((warn_count++))
        fi
    else
        echo -e "${YELLOW}⚠️ acme.sh не установлен, пропускаем дополнение задачи.${PLAIN}"
        ((warn_count++))
    fi

    echo -e "------------------------------------------------"
    echo -e "${CYAN}Результат автоматического исправления: ${GREEN}${fixed_count} исправлено${PLAIN} / ${YELLOW}${warn_count} предупреждений${PLAIN} / ${RED}${fail_count} ошибок${PLAIN}"
    if [[ "$fail_count" -gt 0 ]]; then
        echo -e "${RED}Есть ошибки, рекомендуется выполнить проверку [13] в меню обслуживания и просмотреть логи caddy.${PLAIN}"
    else
        echo -e "${GREEN}Автоматическое исправление завершено, выполните проверку [13] для подтверждения.${PLAIN}"
    fi
}

func_caddy_cf_maintenance_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🛠️ Центр обслуживания 443 / Caddy / Cloudflare${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: диагностика цепочки 443, переподпись сертификатов, восстановление символических ссылок, изоляция старых конфигураций и откат.${PLAIN}"
        echo -e "${YELLOW}Рекомендуемый порядок: сначала [1] проверка, затем исправление по результатам.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Часто используемые для единого входа 443${PLAIN}"
        echo -e "${GREEN}  1. Проверка цепочки и безопасности 443${PLAIN}       ${YELLOW}(Nginx/Caddy/REALITY/панель/скрытие версии)${PLAIN}"
        echo -e "${GREEN}  2. Управление веб-доменами/прокси 443${PLAIN}    ${YELLOW}(добавление/удаление/просмотр, самое частое)${PLAIN}"
        echo -e "${GREEN}  3. Изменение параметров маршрутизации 443${PLAIN}         ${YELLOW}(панель/подписка/REALITY/порты/пути)${PLAIN}"
        echo -e "${GREEN}  4. Повторное применение последней конфигурации 443${PLAIN}     ${YELLOW}(чтение sni-stack.env и восстановление конфигурации)${PLAIN}"
        echo -e "${GREEN}  5. Подсказки по ссылкам подписок / External Proxy${PLAIN} ${YELLOW}(проверка, что ссылки узлов используют публичный 443)${PLAIN}"
        echo -e "${RED}  6. Откат конфигурации единого входа 443${PLAIN}       ${YELLOW}(восстановление из последней резервной копии)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Сертификаты и Cloudflare${PLAIN}"
        echo -e "${GREEN}  7. Просмотр управляемых доменов / путей сертификатов${PLAIN}"
        echo -e "${GREEN}  8. Обновление Cloudflare API Token${PLAIN}"
        echo -e "${GREEN}  9. Перевыпуск сертификата для указанного домена${PLAIN}"
        echo -e "${GREEN} 10. Восстановление символических ссылок /root/cert${PLAIN}"
        echo -e "${GREEN} 11. Восстановление файла манифеста сертификатов${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Восстановление и очистка Caddy${PLAIN}"
        echo -e "${GREEN} 12. Проверка и перезагрузка Caddy${PLAIN}"
        echo -e "${GREEN} 13. Быстрая проверка Caddy/сертификатов${PLAIN}       ${YELLOW}(Token/сертификаты/прослушивание/бэкенды)${PLAIN}"
        echo -e "${GREEN} 14. Автоматическое исправление частых проблем${PLAIN}"
        echo -e "${GREEN} 15. Изоляция старых конфигураций Caddy${PLAIN}        ${YELLOW}(во избежание захвата 443)${PLAIN}"
        echo -e "${RED} 16. Изоляция конфигурации и сертификатов для указанного домена${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local m_choice
        read_trimmed m_choice "👉 Выберите действие: "

        case "$m_choice" in
            1) m_choice=11 ;;
            2) m_choice=15 ;;
            3) m_choice=16 ;;
            4) m_choice=12 ;;
            5) m_choice=13 ;;
            6) m_choice=14 ;;
            7) m_choice=1 ;;
            8) m_choice=2 ;;
            9) m_choice=3 ;;
            10) m_choice=4 ;;
            11) m_choice=7 ;;
            12) m_choice=6 ;;
            13) m_choice=8 ;;
            14) m_choice=9 ;;
            15) m_choice=10 ;;
            16) m_choice=5 ;;
        esac

        case $m_choice in
            16)
                edit_sni_stack_runtime_profile
                ;;

            1)
                generate_caddy_cf_manifest
                echo -e "${CYAN}👇 Текущее содержимое манифеста:${PLAIN}"
                cat /root/cert/caddy_cf_manifest.txt 2>/dev/null
                ;;

            2)
                local new_token escaped_token
                mkdir -p /root/.config/vps-panel
                chmod 700 /root/.config/vps-panel
                echo -e "${CYAN}👇 Введите новый Cloudflare API Token${PLAIN}"
                read_secret_trimmed new_token "CF Token: "
                if [[ -z "$new_token" || ${#new_token} -lt 20 ]]; then
                    echo -e "${RED}❌ Неверная длина Token, обновление отменено.${PLAIN}"
                else
                    echo -e "${CYAN}▶ Онлайн-проверка Cloudflare Token...${PLAIN}"
                    verify_cf_token_online "$new_token"
                    local verify_rc=$?
                    if [[ "$verify_rc" -eq 1 ]]; then
                        echo -e "${RED}❌ Онлайн-проверка Token не удалась, запись отменена.${PLAIN}"
                        echo -e "${YELLOW}Требуются права: Zone.DNS.Edit + Zone.Zone.Read${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    elif [[ "$verify_rc" -eq 2 ]]; then
                        echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку, продолжаем запись.${PLAIN}"
                    else
                        echo -e "${GREEN}✅ Проверка Token пройдена.${PLAIN}"
                    fi

                    escaped_token=${new_token//\'/\'"\'"\'}
                    printf "CF_Token='%s'\n" "$escaped_token" > /root/.config/vps-panel/cloudflare.env
                    chmod 600 /root/.config/vps-panel/cloudflare.env
                    echo -e "${GREEN}✅ Cloudflare Token обновлён.${PLAIN}"
                fi
                ;;

            3)
                local domain domain_input
                local acme_bin="/root/.acme.sh/acme.sh"
                local cf_env_file="/root/.config/vps-panel/cloudflare.env"

                read_trimmed domain_input "👉 Введите домен для перевыпуска: "
                domain=$(normalize_domain_input "$domain_input")
                if ! is_valid_domain "$domain"; then
                    print_domain_validation_error "домен" "$domain_input" "$domain"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if [[ ! -x "$acme_bin" ]]; then
                    echo -e "${RED}❌ acme.sh не обнаружен, сначала выполните первичную настройку единого входа 443 через [19] -> [2].${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi
                if [[ ! -f "$cf_env_file" ]]; then
                    echo -e "${RED}❌ Cloudflare Token не найден, сначала выполните [2] в этом меню.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                # shellcheck disable=SC1090
                source "$cf_env_file"
                confirm_risk_action "Перевыпустить и установить сертификат для ${domain}" \
                    "Кеш сертификатов acme.sh, /etc/caddy/certs и символические ссылки /root/cert" \
                    "Восстановите из существующей резервной копии Caddy/сертификатов или повторите выпуск в меню обслуживания" \
                    "Убедитесь, что DNS домена разрешается, и Cloudflare Token имеет правильные права." || {
                    echo -e "${BLUE}Перевыпуск сертификата отменён.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                }
                echo -e "${CYAN}▶ Перевыпуск сертификата: ${domain}${PLAIN}"

                if ! issue_cf_dns_cert_with_retry "$domain" "$CF_Token" "$acme_bin"; then
                    echo -e "${RED}❌ Ошибка выдачи сертификата: ${domain}${PLAIN}"
                    echo -e "${YELLOW}   Подсказка: сначала выполните автоматическое исправление [14] в этом меню.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                mkdir -p /etc/caddy/certs /root/cert
                if ! "$acme_bin" --install-cert -d "$domain" --ecc \
                    --fullchain-file "/etc/caddy/certs/${domain}.crt" \
                    --key-file "/etc/caddy/certs/${domain}.key" \
                    --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true" >/dev/null 2>&1; then
                    echo -e "${RED}❌ Ошибка установки сертификата: ${domain}${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if id caddy >/dev/null 2>&1; then
                    chown root:caddy "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key" >/dev/null 2>&1
                    chmod 640 "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key"
                else
                    chmod 600 "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key"
                fi

                ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
                ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
                generate_caddy_cf_manifest
                echo -e "${GREEN}✅ Перевыпуск выполнен и символические ссылки /root/cert обновлены.${PLAIN}"
                ;;

            4)
                local link_mode domain domain_input
                mkdir -p /root/cert
                read_trimmed link_mode "❓ Восстановить все ссылки или для одного домена? (all/one): "

                if [[ "$link_mode" == "all" ]]; then
                    local relink_count=0
                    if [[ -d /etc/caddy/certs ]]; then
                        while IFS= read -r cert_path; do
                            domain=$(basename "$cert_path" .crt)
                            if [[ -f "/etc/caddy/certs/${domain}.key" ]]; then
                                ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
                                ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
                                ((relink_count++))
                            fi
                        done < <(find /etc/caddy/certs -maxdepth 1 -type f -name "*.crt" 2>/dev/null | sort)
                    fi
                    generate_caddy_cf_manifest
                    echo -e "${GREEN}✅ Восстановлено ${relink_count} групп символических ссылок сертификатов.${PLAIN}"
                else
                    read_trimmed domain_input "👉 Введите домен: "
                    domain=$(normalize_domain_input "$domain_input")
                    if ! is_valid_domain "$domain"; then
                        print_domain_validation_error "домен" "$domain_input" "$domain"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    fi
                    if [[ -f "/etc/caddy/certs/${domain}.crt" && -f "/etc/caddy/certs/${domain}.key" ]]; then
                        ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
                        ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
                        generate_caddy_cf_manifest
                        echo -e "${GREEN}✅ Символические ссылки восстановлены: /root/cert/${domain}.crt и /root/cert/${domain}.key${PLAIN}"
                    else
                        echo -e "${RED}❌ Файлы сертификатов для этого домена не найдены.${PLAIN}"
                    fi
                fi
                ;;

            5)
                local domain domain_input purge_acme
                read_trimmed domain_input "👉 Введите домен для изоляции: "
                domain=$(normalize_domain_input "$domain_input")
                if ! is_valid_domain "$domain"; then
                    print_domain_validation_error "домен" "$domain_input" "$domain"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if ! confirm_risk_action "Изолировать конфигурацию и сертификаты для ${domain}" \
                    "Конфигурация Caddy, файлы сертификатов и опционально историю acme.sh" \
                    "Восстановите вручную из карантинного каталога или перевыпустите сертификат и восстановите конфигурацию Caddy" \
                    "Убедитесь, что этот домен больше не обслуживает работающие службы, или вы готовы перевыпустить сертификат."; then
                    echo -e "${BLUE}Изоляция отменена.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                local domain_quarantine_dir="/etc/vps-optimize/quarantine/caddy-domain-${domain}-$(date +%s)"
                mkdir -p "$domain_quarantine_dir"
                quarantine_path "/etc/caddy/conf.d/${domain}.caddy" "$domain_quarantine_dir" >/dev/null 2>&1 || true
                quarantine_path "/etc/caddy/certs/${domain}.crt" "$domain_quarantine_dir" >/dev/null 2>&1 || true
                quarantine_path "/etc/caddy/certs/${domain}.key" "$domain_quarantine_dir" >/dev/null 2>&1 || true
                quarantine_path "/root/cert/${domain}.crt" "$domain_quarantine_dir" >/dev/null 2>&1 || true
                quarantine_path "/root/cert/${domain}.key" "$domain_quarantine_dir" >/dev/null 2>&1 || true

                read_trimmed purge_acme "❓ Также удалить историю acme.sh? (y/n, по умолчанию n, рекомендуется оставить): "
                if is_yes "$purge_acme"; then
                    /root/.acme.sh/acme.sh --remove -d "$domain" --ecc >/dev/null 2>&1 || true
                    quarantine_path "/root/.acme.sh/${domain}_ecc" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
                    quarantine_path "/root/.acme.sh/${domain}" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
                fi

                if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                    systemctl restart caddy >/dev/null 2>&1
                fi
                generate_caddy_cf_manifest
                echo -e "${GREEN}✅ Конфигурация и сертификаты для ${domain} изолированы в: ${domain_quarantine_dir}${PLAIN}"
                ;;

            6)
                caddy_format_configs
                if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                    systemctl restart caddy >/dev/null 2>&1
                    echo -e "${GREEN}✅ Конфигурация Caddy отформатирована, проверена и перезапущена.${PLAIN}"
                else
                    echo -e "${RED}❌ Проверка конфигурации Caddy не удалась, проверьте /etc/caddy/conf.d/*.caddy${PLAIN}"
                fi
                ;;

            7)
                generate_caddy_cf_manifest
                echo -e "${GREEN}✅ Манифест восстановлен: /root/cert/caddy_cf_manifest.txt${PLAIN}"
                ;;

            8)
                func_caddy_cf_health_check
                ;;

            9)
                func_caddy_cf_auto_fix
                ;;

            10)
                quarantine_legacy_caddy_443_configs
                if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                    systemctl restart caddy >/dev/null 2>&1
                    echo -e "${GREEN}✅ Изоляция выполнена, Caddy перезагружен.${PLAIN}"
                else
                    echo -e "${RED}❌ Текущая конфигурация Caddy не прошла проверку, сначала исправьте синтаксические ошибки.${PLAIN}"
                fi
                ;;

            11)
                sni_stack_health_check
                ;;

            12)
                reapply_sni_stack_from_env
                ;;

            13)
                check_sni_stack_subscription_hint
                ;;

            14)
                rollback_sni_stack_config
                ;;

            15)
                manage_sni_stack_sites
                ;;

            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}" ;;
        esac

        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}

# ---------------------------------------------------------
# Новая функция: просмотр путей сертификатов Caddy
# ---------------------------------------------------------
func_view_caddy_cert() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔑 Просмотр путей выданных сертификатов Caddy${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    
    if [[ ! -f "/etc/caddy/Caddyfile" ]]; then
        echo -e "${RED}❌ /etc/caddy/Caddyfile не найден, сначала настройте прокси!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    
    # Извлечение доменов из Caddyfile и conf.d (игнорируя комментарии)
    local domains
    domains=$(cat /etc/caddy/Caddyfile /etc/caddy/conf.d/*.caddy 2>/dev/null | grep -vE '^[[:space:]]*#' | grep '{' | awk '{print $1}' | tr -d '{')
    
    if [[ -z "$domains" ]]; then
        echo -e "${YELLOW}⚠️ В Caddyfile нет явно настроенных доменов.${PLAIN}"
    else
        # Корневой каталог сертификатов Caddy
        local cert_root="/var/lib/caddy/.local/share/caddy/certificates"
        [[ ! -d "$cert_root" ]] && cert_root="/root/.local/share/caddy/certificates"
        
        for domain in $domains; do
            # Отфильтровываем локальные и незначащие блоки
            if [[ "$domain" == ":80" || "$domain" == "localhost" ]]; then continue; fi
            
            echo -e "${BLUE}🌐 Домен: ${BOLD}${domain}${PLAIN}"
            
            local found=false
            if [[ -d "$cert_root" ]]; then
                # Рекурсивный поиск .crt и .key
                local cert_file
                local key_file
                cert_file=$(find "$cert_root" -name "${domain}.crt" -print -quit 2>/dev/null)
                key_file=$(find "$cert_root" -name "${domain}.key" -print -quit 2>/dev/null)
                
                if [[ -n "$cert_file" && -n "$key_file" ]]; then
                    echo -e "   ${GREEN}📄 Публичный ключ (CRT):${PLAIN} ${cert_file}"
                    echo -e "   ${YELLOW}🔑 Приватный ключ (KEY):${PLAIN} ${key_file}"
                    found=true
                fi
            fi
            
            if ! $found; then
                echo -e "   ${RED}❌ Сертификат не найден, возможно, ещё не выдан или путь неверен.${PLAIN}"
            fi
            echo -e "------------------------------------------------"
        done
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}

# ---------------------------------------------------------
# Новая функция: очистка конфигураций Caddy (модульная версия)
# ---------------------------------------------------------
func_caddy_clear_config() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧹 Очистка конфигураций Caddy (модульная версия)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    
    if [[ -f /etc/caddy/Caddyfile ]] || [[ -d /etc/caddy/conf.d ]]; then
        echo -e "${YELLOW}Будут очищены /etc/caddy/conf.d/*.caddy и сброшен /etc/caddy/Caddyfile в начальное модульное состояние.${PLAIN}"
        if confirm_danger "Очистка конфигураций обратного прокси Caddy" "Все независимые конфигурации Caddy прокси станут неактивны, связанные сайты/панели могут быть временно недоступны." "Скрипт создаст резервную копию Caddyfile и conf.d, можно восстановить вручную."; then
            
            # 1. Резервное копирование существующего модульного каталога
            if [[ -d /etc/caddy/conf.d ]]; then
                local backup_dir="/etc/caddy/conf.d_bak_$(date +%s)"
                cp -r /etc/caddy/conf.d "$backup_dir" 2>/dev/null
                echo -e "${BLUE}Создана резервная копия конфигурационного каталога: $backup_dir${PLAIN}"
                
                # Точная изоляция всех .caddy файлов
                while IFS= read -r caddy_conf; do
                    mv "$caddy_conf" "$backup_dir/" 2>/dev/null || true
                done < <(find /etc/caddy/conf.d -maxdepth 1 -type f -name '*.caddy' 2>/dev/null | sort)
            fi
            
            # 2. Сброс основного файла в модульную архитектуру
            cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak_$(date +%s)" 2>/dev/null
            echo "# Caddyfile очищен и сброшен к модульной архитектуре" > /etc/caddy/Caddyfile
            echo "import conf.d/*" >> /etc/caddy/Caddyfile
            
            # 3. Перезагрузка
            systemctl restart caddy >/dev/null 2>&1
            echo -e "${GREEN}✅ Все конфигурации прокси очищены и успешно перезагружены! Система возвращена к чистому модульному состоянию.${PLAIN}"
        else
            echo -e "${BLUE}Очистка отменена.${PLAIN}"
        fi
    else
        echo -e "${RED}❌ Конфигурационный файл Caddy или модульный каталог не обнаружены!${PLAIN}"
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}

strip_caddy_ip_whitelist_block() {
    local conf_file="$1"
    local tmp_file
    tmp_file=$(mktemp /tmp/caddy-ipwl.XXXXXX) || return 1
    awk '
        /# vps-optimize-ip-whitelist-start/ {skip=1; next}
        /# vps-optimize-ip-whitelist-end/ {skip=0; next}
        !skip {print}
    ' "$conf_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv "$tmp_file" "$conf_file"
}

insert_caddy_ip_whitelist_block() {
    local conf_file="$1"
    local ranges="$2"
    local tmp_file block
    strip_caddy_ip_whitelist_block "$conf_file" || return 1
    tmp_file=$(mktemp /tmp/caddy-ipwl.XXXXXX) || return 1
    block=$(caddy_ip_whitelist_block "$ranges")
    awk -v block="$block" '
        inserted == 0 && /^[[:space:]]*[^#[:space:]].*\{[[:space:]]*$/ {
            print
            printf "%s", block
            inserted=1
            next
        }
        {print}
        END { if (inserted == 0) exit 1 }
    ' "$conf_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv "$tmp_file" "$conf_file"
}

func_caddy_manage_ip_whitelist() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔐 IP-белый список Caddy для доменов${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Применяется для доменов, где не включён единый вход 443 и Caddy обслуживает напрямую.${PLAIN}"
    echo -e "${YELLOW}Если домен уже использует единый вход 443, используйте главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси] -> [5 Управление IP-белым списком домена], не ограничивайте на уровне Caddy.${PLAIN}"
    echo -e "------------------------------------------------"

    if ! command -v caddy >/dev/null 2>&1 || [[ ! -f /etc/caddy/Caddyfile ]]; then
        echo -e "${RED}❌ Caddy или /etc/caddy/Caddyfile не обнаружены, сначала настройте Caddy прокси.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    local domain domain_input conf_file first_site_line action backup_file
    read_trimmed domain_input "Введите домен для управления (например panel.example.com): "
    domain=$(normalize_domain_input "$domain_input")
    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    conf_file="/etc/caddy/conf.d/${domain}.caddy"
    if [[ ! -f "$conf_file" ]]; then
        echo -e "${RED}❌ ${conf_file} не найден. Этот пункт управляет только модульными конфигурациями Caddy, созданными скриптом.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    first_site_line=$(grep -m1 -E '^[[:space:]]*[^#[:space:]].*\{' "$conf_file" 2>/dev/null | sed 's/^[[:space:]]*//')
    if [[ "$first_site_line" != "$domain "* && "$first_site_line" != "$domain{"* && "$first_site_line" != "https://${domain}"* ]]; then
        echo -e "${RED}❌ Первый блок сайта в ${conf_file} не относится к ${domain}, изменение отменено во избежание ошибок.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi
    if [[ "$first_site_line" =~ ^https://[^[:space:]]+:[0-9]+[[:space:]]*\{ ]]; then
        echo -e "${RED}❌ Эта конфигурация похожа на локальный TLS-сайт единого входа 443. Используйте главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси] -> [5 Управление IP-белым списком домена].${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    echo -e "Текущий файл конфигурации: ${conf_file}"
    if grep -q '# vps-optimize-ip-whitelist-start' "$conf_file" 2>/dev/null; then
        echo -e "${YELLOW}Текущее состояние: включён управляемый скриптом IP-белый список.${PLAIN}"
    else
        echo -e "${BLUE}Текущее состояние: управляемый скриптом IP-белый список не включён.${PLAIN}"
    fi
    echo -e "1. Установить/перезаписать белый список"
    echo -e "2. Очистить белый список"
    echo -e "0/q. Отмена"
    read_trimmed action "Выберите действие: "

    backup_file="${conf_file}.bak_$(date +%s)"
    case "$action" in
        1)
            local ip_whitelist_input ip_whitelist_ranges current_client_ip
            local -a ip_whitelist_array=()
            current_client_ip=$(detect_ssh_client_ip)
            [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен.${PLAIN}"
            read_trimmed ip_whitelist_input "Введите IP/CIDR, разрешённые для ${domain} (несколько через пробел или запятую): "
            if ! normalize_ip_whitelist_input "$ip_whitelist_input" ip_whitelist_array; then
                echo -e "${RED}❌ Белый список пуст или неверный формат, отмена.${PLAIN}"
                read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                return
            fi
            append_vps_public_ips_to_whitelist ip_whitelist_array
            ip_whitelist_ranges=$(join_array_by_space "${ip_whitelist_array[@]}")
            cp -p "$conf_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, отмена.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."; return; }
            if insert_caddy_ip_whitelist_block "$conf_file" "$ip_whitelist_ranges" && caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                if systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ Для ${domain} включён IP-белый список: ${ip_whitelist_ranges}${PLAIN}"
                    echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
                else
                    echo -e "${RED}❌ Перезагрузка Caddy не удалась, откат...${PLAIN}"
                    mv "$backup_file" "$conf_file"
                    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
                fi
            else
                echo -e "${RED}❌ Проверка Caddy после записи не удалась, откат...${PLAIN}"
                mv "$backup_file" "$conf_file"
            fi
            ;;
        2)
            if ! grep -q '# vps-optimize-ip-whitelist-start' "$conf_file" 2>/dev/null; then
                echo -e "${BLUE}Для этого домена нет блока белого списка, созданного скриптом.${PLAIN}"
                read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                return
            fi
            cp -p "$conf_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, отмена.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."; return; }
            if strip_caddy_ip_whitelist_block "$conf_file" && caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
                echo -e "${GREEN}✅ IP-белый список Caddy для ${domain} очищен.${PLAIN}"
                echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
            else
                echo -e "${RED}❌ Проверка Caddy после очистки не удалась, откат...${PLAIN}"
                mv "$backup_file" "$conf_file"
            fi
            ;;
        0|q|Q|"")
            echo -e "${BLUE}Отмена.${PLAIN}"
            ;;
        *)
            echo -e "${RED}❌ Неверное действие.${PLAIN}"
            ;;
    esac

    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# Очистка сертификатов домена, конфигураций и занятости портов
# ---------------------------------------------------------
sync_sni_stack_state_after_caddy_domain_delete() {
    local domain="$1"
    local env_file="/etc/vps-optimize/sni-stack.env"
    local i removed=0
    local -a new_domains=()
    local -a new_addrs=()
    local -a new_ports=()

    [[ -f "$env_file" ]] || return 0
    load_sni_stack_env >/dev/null 2>&1 || return 0

    if [[ "$domain" == "${PANEL_DOMAIN:-}" ]]; then
        echo -e "${YELLOW}⚠️ ${domain} — текущий домен панели единого входа 443, сохранённое состояние всё равно будет ссылаться на него; перед повторным применением необходимо перевыпустить сертификат или сменить домен панели.${PLAIN}"
        return 0
    fi

    for i in "${!SITE_DOMAINS[@]}"; do
        if [[ "$domain" == "${SITE_DOMAINS[$i]}" ]]; then
            removed=1
            continue
        fi
        new_domains+=("${SITE_DOMAINS[$i]}")
        new_addrs+=("${SITE_BACKEND_ADDRS[$i]}")
        new_ports+=("${SITE_BACKEND_PORTS[$i]}")
    done

    [[ "$removed" -eq 1 ]] || return 0
    SITE_DOMAINS=("${new_domains[@]}")
    SITE_BACKEND_ADDRS=("${new_addrs[@]}")
    SITE_BACKEND_PORTS=("${new_ports[@]}")
    remove_sni_ip_whitelist_for_domain "$domain"
    save_sni_stack_env
    echo -e "${GREEN}✅ Синхронизировано удаление веб-домена ${domain} из сохранённого состояния единого входа 443.${PLAIN}"
}

func_caddy_delete_cert() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Очистка сертификатов домена и конфигураций${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Будут изолированы сертификаты и конфигурация указанного домена, а также очищены остатки acme.sh.${PLAIN}"
    echo -e "------------------------------------------------"
    
    local domain domain_input
    read_trimmed domain_input "👉 Введите домен для очистки (например panel.site.com): "
    domain=$(normalize_domain_input "$domain_input")
    if [[ -z "$domain" ]]; then
        echo -e "${RED}❌ Домен не может быть пустым!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        echo -e "${RED}❌ Очистка отменена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "\n${CYAN}▶ Очистка сертификатов и конфигураций домена...${PLAIN}"
    echo -e "${YELLOW}Эта операция переместит сертификаты и конфигурацию этого домена, связанные сайты станут временно недоступны.${PLAIN}"
    echo -e "Подтвердите действие...${PLAIN}"
    if confirm_danger "Очистка сертификатов и конфигурации ${domain}" "Будет остановлен Caddy, изолированы конфигурации Caddy/Nginx для этого домена, общие файлы сертификатов и остатки acme.sh, затем службы будут перезапущены." "Убедитесь, что у вас есть системный снимок или резервная копия конфигурации прокси; после очистки сертификаты необходимо перевыпустить."; then
        # 1. Остановка Caddy для освобождения портов
        systemctl stop caddy >/dev/null 2>&1
        echo -e "${GREEN}✅ [1/4] Caddy остановлен для освобождения сетевых портов.${PLAIN}"
        
        # 2. Глубокая очистка кеша сертификатов Caddy
        local caddy_paths=("/var/lib/caddy/.local/share/caddy/certificates" "/root/.local/share/caddy/certificates")
        local caddy_found=false
        for cp in "${caddy_paths[@]}"; do
            if [[ -d "$cp" ]]; then
                local target=$(find "$cp" -type d -name "${domain}" -print -quit 2>/dev/null)
                if [[ -n "$target" ]]; then
                    quarantine_path "$target" "/root/vps-optimize-quarantine/caddy-certs" >/dev/null 2>&1 || true
                    caddy_found=true
                fi
            fi
        done
        if $caddy_found; then
            echo -e "${GREEN}✅ [2/4] Ключи и сертификаты для ${domain} удалены из движка Caddy.${PLAIN}"
        else
            echo -e "${BLUE}ℹ️ [2/4] Сертификаты для этого домена не найдены в движке Caddy.${PLAIN}"
        fi
        
        # 3. Очистка остатков acme.sh
        if [[ -d "/root/.acme.sh" ]]; then
            local acme_target=$(find "/root/.acme.sh" -type d -name "*${domain}*" -print -quit 2>/dev/null)
            if [[ -n "$acme_target" ]]; then
                quarantine_path "$acme_target" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
                echo -e "${GREEN}✅ [3/4] Остатки acme.sh для ${domain} удалены.${PLAIN}"
            else
                echo -e "${BLUE}ℹ️ [3/4] Остатков acme.sh не обнаружено.${PLAIN}"
            fi
        else
            echo -e "${BLUE}ℹ️ [3/4] Независимая среда acme.sh не установлена, пропущено.${PLAIN}"
        fi
        
        # 4. Модульное удаление конфигураций Caddy/Nginx
        local domain_conf="/etc/caddy/conf.d/${domain}.caddy"
        if [[ -f "$domain_conf" ]]; then
            echo -e "${YELLOW}⏳ [4/5] Обнаружен файл конфигурации Caddy, изоляция...${PLAIN}"
            quarantine_path "$domain_conf" "/etc/vps-optimize/quarantine/caddy-conf" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ [4/5] Файл конфигурации Caddy ($domain_conf) изолирован!${PLAIN}"
        else
            echo -e "${GREEN}✅ [4/5] Файл конфигурации Caddy для этого домена не найден.${PLAIN}"
        fi
        local nginx_domain_conf
        nginx_domain_conf=$(nginx_proxy_conf_path "$domain" 2>/dev/null || echo "/etc/nginx/conf.d/vps_proxy_${domain}.conf")
        if [[ -f "$nginx_domain_conf" ]]; then
            quarantine_path "$nginx_domain_conf" "/etc/vps-optimize/quarantine/nginx-proxy" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ Изолирована конфигурация Nginx прокси: ${nginx_domain_conf}${PLAIN}"
        fi

        # 5. Изоляция общих сертификатов
        local shared_cert_file
        echo -e "${YELLOW}⏳ [5/5] Изоляция общих путей сертификатов...${PLAIN}"
        for shared_cert_file in "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.crt" "/root/cert/${domain}.key"; do
            if [[ -e "$shared_cert_file" || -L "$shared_cert_file" ]]; then
                quarantine_path "$shared_cert_file" "/etc/vps-optimize/quarantine/shared-certs" >/dev/null 2>&1 || true
                echo -e "${GREEN}✅ Изолирован общий сертификат: ${shared_cert_file}${PLAIN}"
            fi
        done

        # Перезапуск Caddy с чистой конфигурацией
        systemctl start caddy >/dev/null 2>&1
        if command -v nginx >/dev/null 2>&1; then
            nginx -t >/dev/null 2>&1 && { systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true; }
        fi
        sync_sni_stack_state_after_caddy_domain_delete "$domain" || true
        generate_caddy_cf_manifest 2>/dev/null || true

        echo -e "------------------------------------------------"
        echo -e "${GREEN}✅ Очистка завершена; соответствующие конфигурации и сертификаты перемещены в карантин.${PLAIN}"
    else
        echo -e "${BLUE}Операция отменена.${PLAIN}"
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}

# ---------------------------------------------------------
# Новая функция: добавление независимого прокси Caddy с пропуском проверки сертификата (модульная версия)
# ---------------------------------------------------------
func_caddy_add_insecure() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🛡️ Настройка независимого прокси Caddy с пропуском проверки сертификата${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        echo -e "${RED}❌ Caddyfile не найден, сначала установите Caddy через [13]!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    
    local domain domain_input
    local backend_addr port
    local enable_ip_whitelist ip_whitelist_input ip_whitelist_ranges current_client_ip
    local -a ip_whitelist_array=()
    read_trimmed domain_input "👉 Введите разрешённый домен (например panel.site.com): "
    read_trimmed port "👉 Введите локальный HTTPS-порт бэкенда (например 40000): "
    backend_addr=$(ask_with_default "Адрес бэкенда" "127.0.0.1")
    backend_addr=$(normalize_backend_addr_input "$backend_addr")
    if ! is_valid_backend_addr "$backend_addr"; then
        echo -e "${RED}❌ Неверный адрес бэкенда: ${backend_addr}${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi
    domain=$(normalize_domain_input "$domain_input")
    
    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi
    if ! is_valid_port "$port"; then
        echo -e "${RED}❌ Неверный порт: ${port}, должен быть 1-65535. Отмена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    read_trimmed enable_ip_whitelist "❓ Разрешить доступ к этому домену только с указанных IP/CIDR? (y/n, по умолчанию n): "
    if is_yes "$enable_ip_whitelist"; then
        current_client_ip=$(detect_ssh_client_ip)
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен.${PLAIN}"
        read_trimmed ip_whitelist_input "Введите IP/CIDR, разрешённые для ${domain} (несколько через пробел или запятую): "
        if ! normalize_ip_whitelist_input "$ip_whitelist_input" ip_whitelist_array; then
            echo -e "${RED}❌ Белый список пуст или неверный формат, отмена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
            return
        fi
        append_vps_public_ips_to_whitelist ip_whitelist_array
        ip_whitelist_ranges=$(join_array_by_space "${ip_whitelist_array[@]}")
    else
        ip_whitelist_ranges=""
    fi
    
    # Убедиться, что основной файл содержит импорт модульного каталога
    grep -q "import conf.d/\*" /etc/caddy/Caddyfile || echo -e "\nimport conf.d/*" >> /etc/caddy/Caddyfile
    
    mkdir -p /etc/caddy/conf.d
    local conf_file="/etc/caddy/conf.d/${domain}.caddy"
    local backup_file=""
    if [[ -f "$conf_file" ]]; then
        backup_file="${conf_file}.bak_$(date +%s)"
        if ! cp -p "$conf_file" "$backup_file"; then
            echo -e "${RED}❌ Не удалось создать резервную копию существующей конфигурации, отмена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
            return
        fi
    fi
    
    write_caddy_reverse_proxy_conf "$domain" "$backend_addr" "$port" "y" "$conf_file" "$ip_whitelist_ranges"
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        systemctl reload caddy >/dev/null 2>&1
        echo -e "${GREEN}✅ Независимый прокси с пропуском проверки успешно создан и активен!${PLAIN}"
        [[ -n "$ip_whitelist_ranges" ]] && echo -e "${GREEN}✅ Для ${domain} включён IP-белый список: ${ip_whitelist_ranges}${PLAIN}"
    else
        echo -e "${RED}❌ Синтаксическая ошибка в новой конфигурации, откат...${PLAIN}"
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/caddy-conf" >/dev/null 2>&1 || true
        [[ -n "$backup_file" && -f "$backup_file" ]] && mv "$backup_file" "$conf_file"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# 4. Усиление безопасности SSH (окончательная версия: защита от обрезания, перезаписи, конфликтов сокетов)
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: ssh_security.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Усиление SSH, управление SSH-ключами, режимы аутентификации и управление Fail2ban.

ssh_service_restart() {
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
}

ssh_prepare_runtime_dir() {
    if [[ ! -d /run/sshd ]]; then
        mkdir -p /run/sshd 2>/dev/null || return 1
    fi
    chmod 755 /run/sshd 2>/dev/null || true
}

ssh_socket_unit_exists() {
    local unit="$1"
    local active_state enabled_state
    active_state=$(systemctl is-active "$unit" 2>/dev/null || true)
    enabled_state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    [[ "$active_state" == "active" ]] && return 0
    [[ "$enabled_state" == "enabled" || "$enabled_state" == "enabled-runtime" ]]
}

ssh_socket_units_for_host() {
    local unit
    for unit in ssh.socket sshd.socket; do
        if ssh_socket_unit_exists "$unit"; then
            echo "$unit"
        fi
    done
}

ssh_write_socket_port_dropins() {
    local port="$1"
    local unit dir found=false
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        found=true
        dir="/etc/systemd/system/${unit}.d"
        mkdir -p "$dir" || return 1
        cat > "${dir}/10-vps-optimize-port.conf" <<EOF
[Socket]
ListenStream=
ListenStream=${port}
EOF
    done < <(ssh_socket_units_for_host)
    $found
}

ssh_restart_socket_units() {
    local unit found=false ok=true
    systemctl daemon-reload >/dev/null 2>&1 || true
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        found=true
        systemctl restart "$unit" >/dev/null 2>&1 || ok=false
    done < <(ssh_socket_units_for_host)
    $found && $ok
}

ssh_restart_runtime() {
    local restarted=false
    if ssh_restart_socket_units; then
        restarted=true
    fi
    if ssh_service_restart; then
        restarted=true
    fi
    $restarted
}

ssh_write_sshd_port_dropin() {
    local port="$1"
    mkdir -p /etc/ssh/sshd_config.d 2>/dev/null || return 1
    cat > /etc/ssh/sshd_config.d/00-vps-optimize-port.conf <<EOF
# VPS-Optimize SSH port mirror
Port ${port}
EOF
}

ssh_write_auth_dropin() {
    local mode="$1"
    local interactive_key="$2"
    case "$mode" in
        key_only|key_preferred|password) ;;
        *) return 1 ;;
    esac
    mkdir -p /etc/ssh/sshd_config.d 2>/dev/null || return 1
    {
        echo "# VPS-Optimize SSH auth mode mirror"
        echo "PubkeyAuthentication yes"
        case "$mode" in
            key_only)
                echo "PasswordAuthentication no"
                echo "${interactive_key} no"
                ;;
            key_preferred|password)
                echo "PasswordAuthentication yes"
                echo "${interactive_key} yes"
                ;;
        esac
    } > /etc/ssh/sshd_config.d/00-vps-optimize-auth.conf
}

ssh_restore_auth_dropin() {
    local dropin="$1"
    local backup="$2"
    if [[ -n "$backup" && -f "$backup" ]]; then
        cp -p "$backup" "$dropin" 2>/dev/null || true
    else
        mkdir -p "$(dirname "$dropin")" 2>/dev/null || return 0
        cat > "$dropin" <<EOF
# VPS-Optimize SSH auth mode mirror disabled after rollback
EOF
    fi
}

ssh_reconcile_cloud_auth_dropins() {
    local mode="$1"
    local state_file="$2"
    local timestamp="$3"
    local dir="/etc/ssh/sshd_config.d"
    local conf tmp backup current_auth_dropin

    : > "$state_file" || return 1
    [[ -d "$dir" ]] || return 0
    current_auth_dropin="/etc/ssh/sshd_config.d/00-vps-optimize-auth.conf"

    for conf in "$dir"/*.conf; do
        [[ -f "$conf" ]] || continue
        [[ "$conf" == "$current_auth_dropin" ]] && continue
        tmp=$(mktemp /tmp/vps-sshd-dropin.XXXXXX) || return 1
        if ! awk -v mode="$mode" '
            function desired_for(key, lkey) {
                lkey = tolower(key)
                if (lkey == "pubkeyauthentication") return "yes"
                if (lkey == "passwordauthentication") return mode == "key_only" ? "no" : "yes"
                if (lkey == "kbdinteractiveauthentication") return mode == "key_only" ? "no" : "yes"
                if (lkey == "challengeresponseauthentication") return mode == "key_only" ? "no" : "yes"
                return ""
            }
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
            /^[[:space:]]*Match[[:space:]]+/ { in_match = 1; print; next }
            in_match { print; next }
            {
                desired = desired_for($1)
                if (desired != "") {
                    if (tolower($2) == desired) {
                        print
                    } else {
                        print $1 " " desired " # VPS-Optimize reconciled cloud image setting"
                    }
                    next
                }
                print
            }
        ' "$conf" > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        if ! cmp -s "$conf" "$tmp"; then
            backup="${conf}.bak_auth_${timestamp}"
            if ! cp -p "$conf" "$backup"; then
                rm -f "$tmp"
                return 1
            fi
            if ! cp "$tmp" "$conf"; then
                cp -p "$backup" "$conf" 2>/dev/null || true
                rm -f "$tmp"
                return 1
            fi
            printf '%s\t%s\n' "$conf" "$backup" >> "$state_file"
        fi
        rm -f "$tmp"
    done
}

ssh_restore_cloud_auth_dropins() {
    local state_file="$1"
    local conf backup
    [[ -f "$state_file" ]] || return 0
    while IFS=$'\t' read -r conf backup; do
        [[ -n "$conf" && -n "$backup" && -f "$backup" ]] || continue
        cp -p "$backup" "$conf" 2>/dev/null || true
    done < "$state_file"
}

ssh_assert_auth_mode_effective() {
    local mode="$1"
    local expected effective
    expected="yes"
    [[ "$mode" == "key_only" ]] && expected="no"
    effective=$(ssh_effective_setting PasswordAuthentication)
    [[ -z "$effective" ]] && return 0
    if [[ "$effective" != "$expected" ]]; then
        echo -e "${RED}❌ Итоговое значение PasswordAuthentication осталось ${effective}, возможно, более ранние подконфигурации облачного образа переопределяют.${PLAIN}"
        return 1
    fi
}

ssh_rollback_port_change() {
    local backup_file="$1"
    local current_port="$2"
    local socket_managed="${3:-false}"
    cp -p "$backup_file" /etc/ssh/sshd_config 2>/dev/null || true
    ssh_write_sshd_port_dropin "$current_port" >/dev/null 2>&1 || true
    if $socket_managed; then
        ssh_write_socket_port_dropins "$current_port" >/dev/null 2>&1 || true
        ssh_restart_socket_units >/dev/null 2>&1 || true
    fi
    ssh_service_restart >/dev/null 2>&1 || true
}

ssh_effective_setting() {
    local key="$1"
    local sshd_bin value
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    if [[ -n "$sshd_bin" ]]; then
        ssh_prepare_runtime_dir >/dev/null 2>&1 || true
        value=$("$sshd_bin" -T 2>/dev/null | awk -v k="$(echo "$key" | tr '[:upper:]' '[:lower:]')" '$1 == k {print $2; exit}')
        [[ -n "$value" ]] || return 1
        printf '%s' "$value"
        return 0
    fi
    return 1
}

ssh_public_key_is_valid() {
    local key="$1"
    [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

ssh_user_home() {
    local user="$1"
    getent passwd "$user" 2>/dev/null | awk -F: '{print $6; exit}'
}

ssh_authorized_keys_path() {
    local user="$1"
    local home_dir
    home_dir=$(ssh_user_home "$user")
    [[ -n "$home_dir" ]] || return 1
    printf '%s/.ssh/authorized_keys' "$home_dir"
}

ssh_authorized_key_count() {
    local user="$1"
    local key_file
    key_file=$(ssh_authorized_keys_path "$user" 2>/dev/null) || { echo 0; return 0; }
    [[ -r "$key_file" ]] || { echo 0; return 0; }
    grep -E '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-)' "$key_file" 2>/dev/null | wc -l | awk '{print $1}'
}

ssh_choose_user() {
    local default_user user
    default_user="${SUDO_USER:-root}"
    [[ "$default_user" == "root" || -n "$(getent passwd "$default_user" 2>/dev/null)" ]] || default_user="root"
    user=$(ask_with_default "Целевой пользователь Linux" "$default_user")
    if ! getent passwd "$user" >/dev/null 2>&1; then
        echo -e "${RED}❌ Пользователь ${user} не существует.${PLAIN}" >&2
        return 1
    fi
    printf '%s' "$user"
}

ssh_add_public_key_for_user() {
    local user="$1"
    local ssh_key key_file ssh_dir home_dir
    home_dir=$(ssh_user_home "$user")
    [[ -n "$home_dir" ]] || return 1
    key_file="${home_dir}/.ssh/authorized_keys"
    ssh_dir="${home_dir}/.ssh"
    echo -e "👇 ${CYAN}Вставьте SSH-публичный ключ для ${user}, после вставки нажмите Enter:${PLAIN}"
    read -r ssh_key
    if [[ -z "$ssh_key" ]]; then
        echo -e "${RED}❌ Ввод пуст, отмена.${PLAIN}"
        return 1
    fi
    if ! ssh_public_key_is_valid "$ssh_key"; then
        echo -e "${RED}❌ Неверный формат публичного ключа. Поддерживаются ssh-rsa, ssh-ed25519, ecdsa, FIDO2 sk-*.${PLAIN}"
        return 1
    fi
    mkdir -p "$ssh_dir" || return 1
    touch "$key_file" || return 1
    chmod 700 "$ssh_dir"
    chmod 600 "$key_file"
    if [[ "$user" != "root" ]]; then
        chown -R "$user:$user" "$ssh_dir" 2>/dev/null || true
    fi
    if grep -q -F -x "$ssh_key" "$key_file"; then
        echo -e "${YELLOW}⚠️ Этот публичный ключ уже существует, повторное добавление не требуется.${PLAIN}"
        return 0
    fi
    printf '%s\n' "$ssh_key" >> "$key_file"
    echo -e "${GREEN}✅ Публичный SSH-ключ добавлен для ${user}.${PLAIN}"
}

ssh_apply_auth_mode() {
    local mode="$1"
    local label backup_file tmp_file sshd_bin interactive_key auth_dropin auth_dropin_backup auth_reconcile_state timestamp reconciled_count
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    [[ -n "$sshd_bin" && -f /etc/ssh/sshd_config ]] || {
        echo -e "${RED}❌ sshd или /etc/ssh/sshd_config не найдены, отмена.${PLAIN}"
        return 1
    }
    if ! ssh_prepare_runtime_dir; then
        echo -e "${RED}❌ Не удалось создать /run/sshd, sshd не сможет выполнить синтаксическую проверку. Убедитесь, что вы root.${PLAIN}"
        return 1
    fi
    case "$mode" in
        key_only) label="Только ключи (пароль отключён)" ;;
        key_preferred|password) label="Ключи + пароль (восстановление пароля)" ;;
        *) return 1 ;;
    esac
    confirm_risk_action "Переключить режим входа SSH: ${label}" \
        "/etc/ssh/sshd_config и /etc/ssh/sshd_config.d конфигурации аутентификации" \
        "Используйте этот пункт меню 'Ключи + пароль' для восстановления парольного входа, или восстановите из автоматической резервной копии /etc/ssh/sshd_config и соответствующих подконфигураций" \
        "При переключении на 'Только ключи' сначала убедитесь, что новое SSH-окно может войти по ключу." || return 1

    timestamp=$(date +%s)
    interactive_key="KbdInteractiveAuthentication"
    if ! "$sshd_bin" -T 2>/dev/null | grep -qi '^kbdinteractiveauthentication '; then
        interactive_key="ChallengeResponseAuthentication"
    fi
    auth_dropin="/etc/ssh/sshd_config.d/00-vps-optimize-auth.conf"
    auth_dropin_backup=""
    auth_reconcile_state=$(mktemp /tmp/vps-sshd-reconcile.XXXXXX) || return 1
    backup_file="/etc/ssh/sshd_config.bak_auth_${timestamp}"
    cp -p /etc/ssh/sshd_config "$backup_file" || {
        echo -e "${RED}❌ Не удалось создать резервную копию конфигурации SSH, отмена.${PLAIN}"
        rm -f "$auth_reconcile_state"
        return 1
    }
    if [[ -f "$auth_dropin" ]]; then
        auth_dropin_backup="${auth_dropin}.bak_auth_${timestamp}"
        cp -p "$auth_dropin" "$auth_dropin_backup" || {
            echo -e "${RED}❌ Не удалось создать резервную копию drop-in конфигурации SSH, отмена.${PLAIN}"
            rm -f "$auth_reconcile_state"
            return 1
        }
    fi
    tmp_file=$(mktemp /tmp/vps-sshd.XXXXXX) || { rm -f "$auth_reconcile_state"; return 1; }
    awk '
        /^# VPS-Optimize SSH auth mode begin$/ {skip=1; next}
        /^# VPS-Optimize SSH auth mode end$/ {skip=0; next}
        skip != 1 {print}
    ' /etc/ssh/sshd_config > "$tmp_file" || {
        rm -f "$tmp_file"
        rm -f "$auth_reconcile_state"
        return 1
    }
    {
        echo "# VPS-Optimize SSH auth mode begin"
        echo "PubkeyAuthentication yes"
        case "$mode" in
            key_only)
                echo "PasswordAuthentication no"
                echo "${interactive_key} no"
                ;;
            key_preferred|password)
                echo "PasswordAuthentication yes"
                echo "${interactive_key} yes"
                ;;
        esac
        echo "# VPS-Optimize SSH auth mode end"
        cat "$tmp_file"
    } > /etc/ssh/sshd_config
    rm -f "$tmp_file"

    if ! ssh_write_auth_dropin "$mode" "$interactive_key"; then
        echo -e "${RED}❌ Не удалось записать drop-in конфигурацию SSH, откат.${PLAIN}"
        cp -p "$backup_file" /etc/ssh/sshd_config
        ssh_restore_auth_dropin "$auth_dropin" "$auth_dropin_backup"
        rm -f "$auth_reconcile_state"
        return 1
    fi

    if ! ssh_reconcile_cloud_auth_dropins "$mode" "$auth_reconcile_state" "$timestamp"; then
        echo -e "${RED}❌ Не удалось обработать подконфигурации облачного образа SSH, откат.${PLAIN}"
        cp -p "$backup_file" /etc/ssh/sshd_config
        ssh_restore_auth_dropin "$auth_dropin" "$auth_dropin_backup"
        ssh_restore_cloud_auth_dropins "$auth_reconcile_state"
        rm -f "$auth_reconcile_state"
        return 1
    fi

    if ! "$sshd_bin" -t; then
        echo -e "${RED}❌ Синтаксическая проверка конфигурации SSH не удалась, откат.${PLAIN}"
        cp -p "$backup_file" /etc/ssh/sshd_config
        ssh_restore_auth_dropin "$auth_dropin" "$auth_dropin_backup"
        ssh_restore_cloud_auth_dropins "$auth_reconcile_state"
        rm -f "$auth_reconcile_state"
        return 1
    fi
    if ! ssh_assert_auth_mode_effective "$mode"; then
        echo -e "${RED}❌ Режим входа SSH не применился, откат.${PLAIN}"
        cp -p "$backup_file" /etc/ssh/sshd_config
        ssh_restore_auth_dropin "$auth_dropin" "$auth_dropin_backup"
        ssh_restore_cloud_auth_dropins "$auth_reconcile_state"
        rm -f "$auth_reconcile_state"
        return 1
    fi
    if ! ssh_restart_runtime; then
        echo -e "${RED}❌ Перезапуск службы SSH не удался, откат.${PLAIN}"
        cp -p "$backup_file" /etc/ssh/sshd_config
        ssh_restore_auth_dropin "$auth_dropin" "$auth_dropin_backup"
        ssh_restore_cloud_auth_dropins "$auth_reconcile_state"
        ssh_restart_runtime >/dev/null 2>&1 || true
        rm -f "$auth_reconcile_state"
        return 1
    fi
    echo -e "${GREEN}✅ Режим входа SSH переключён на: ${label}${PLAIN}"
    echo -e "${CYAN}Резервная копия конфигурации сохранена: ${backup_file}${PLAIN}"
    reconciled_count=$(wc -l < "$auth_reconcile_state" 2>/dev/null | awk '{print $1}')
    if [[ "$reconciled_count" =~ ^[0-9]+$ && "$reconciled_count" -gt 0 ]]; then
        echo -e "${CYAN}Синхронизировано ${reconciled_count} подконфигураций облачного образа SSH, например 50-cloud-init.conf.${PLAIN}"
    fi
    rm -f "$auth_reconcile_state"
}

func_ssh_login_mode_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "SSH безопасность > Режим входа по ключам"
        echo -e "${BOLD}🔐 Режим входа по ключам пользователя${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "PubkeyAuthentication      : ${CYAN}$(ssh_effective_setting PubkeyAuthentication || echo неизвестно)${PLAIN}"
        echo -e "PasswordAuthentication    : ${CYAN}$(ssh_effective_setting PasswordAuthentication || echo неизвестно)${PLAIN}"
        echo -e "KbdInteractiveAuthentication: ${CYAN}$(ssh_effective_setting KbdInteractiveAuthentication || echo неизвестно)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Добавить/обновить SSH-публичный ключ пользователя (не меняет режим)${PLAIN}"
        echo -e "${GREEN}  2. Ключи + пароль (восстановление пароля)${PLAIN}"
        echo -e "${RED}  3. Только ключи, отключить пароль${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        local choice user key_count
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1)
                user=$(ssh_choose_user) || { pause_return; continue; }
                ssh_add_public_key_for_user "$user"
                pause_return
                ;;
            2) ssh_apply_auth_mode key_preferred; pause_return ;;
            3)
                user=$(ssh_choose_user) || { pause_return; continue; }
                key_count=$(ssh_authorized_key_count "$user")
                if [[ "$key_count" -eq 0 ]]; then
                    echo -e "${RED}❌ У пользователя ${user} нет authorized_keys, нельзя переключиться на только ключи.${PLAIN}"
                    echo -e "${YELLOW}Сначала добавьте публичный ключ через этот пункт меню [1] и протестируйте новое SSH-окно.${PLAIN}"
                    pause_return
                    continue
                fi
                echo -e "${YELLOW}Обнаружено ${key_count} публичных ключей у ${user}. После переключения парольный вход будет отключён.${PLAIN}"
                ssh_apply_auth_mode key_only
                pause_return
                ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

func_ssh_security_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Центр безопасности SSH"
        echo -e "${BOLD}🛡️ Центр безопасности SSH${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${GREEN}  1. Изменить порт SSH${PLAIN}             ${YELLOW}(проверка и откат)${PLAIN}"
        echo -e "${GREEN}  2. Режим входа по ключам пользователя${PLAIN}         ${YELLOW}(добавление ключа / переключение режима)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        local choice
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1) func_security ;;
            2) func_ssh_login_mode_menu ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

func_security() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🛡️ Усиление безопасности SSH (изменение порта и защита от потери связи)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Этот скрипт изменит порт SSH и настроит механизм защиты от потери связи.${PLAIN}"
    echo -e "------------------------------------------------"
    
    # 1. Точное определение текущего реального порта SSH из памяти и процессов
    local current_p sshd_bin
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    current_p=$(ss -tlnp 2>/dev/null | grep -w 'sshd' | awk '{print $4}' | awk -F: '{print $NF}' | sort -u | head -n1)
    if [[ -z "$current_p" && -n "$sshd_bin" ]]; then
        ssh_prepare_runtime_dir >/dev/null 2>&1 || true
        current_p=$("$sshd_bin" -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n1)
    fi
    current_p=${current_p:-22}

    local final_p
    read_trimmed final_p "👉 Текущий активный порт SSH: $current_p, введите новый порт [10000-65535] (Enter для сохранения): "
    final_p=${final_p:-$current_p}

    if [[ "$final_p" != "$current_p" ]]; then
        if [[ -z "$sshd_bin" ]]; then
            echo -e "${RED}❌ Команда sshd не найдена, невозможно безопасно проверить конфигурацию SSH, отмена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi
        if ! command -v systemctl >/dev/null 2>&1; then
            echo -e "${RED}❌ systemctl не обнаружен, невозможно безопасно перезапустить SSH, отмена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi
        if ! ssh_prepare_runtime_dir; then
            echo -e "${RED}❌ Не удалось создать /run/sshd, sshd не может выполнить синтаксическую проверку. Убедитесь, что вы root.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi
        # [Строгая проверка] допустимость порта
        if ! [[ "$final_p" =~ ^[0-9]+$ ]] || (( 10#$final_p < 10000 || 10#$final_p > 65535 )); then
            echo -e "${RED}❌ Неверный номер порта! Должен быть 10000-65535.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi

        echo -e "${YELLOW}Будет изменено: /etc/ssh/sshd_config, /etc/ssh/sshd_config.d, SSH systemd socket/служба, правила брандмауэра.${PLAIN}"
        echo -e "${YELLOW}Сначала убедитесь, что в безопасной группе облачного провайдера разрешён ${final_p}/tcp, и сохраните текущую SSH-сессию.${PLAIN}"
        confirm_danger "Изменить порт SSH на ${final_p}" "Если новый порт не разрешён, последующее подключение будет невозможно." "Скрипт создаст резервную копию sshd_config, проверит синтаксис и в случае ошибки автоматически откатит." || {
            echo -e "${BLUE}Изменение порта SSH отменено.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        }

        echo -e "${CYAN}▶ Создание резервной копии конфигурации SSH...${PLAIN}"
        local backup_file="/etc/ssh/sshd_config.bak_$(date +%s)"
        if ! cp -p /etc/ssh/sshd_config "$backup_file"; then
            echo -e "${RED}❌ Не удалось создать резервную копию конфигурации SSH, отмена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi

        # 2. Безопасная замена: удаление всех строк с Port, затем вставка новой строки в самое начало
        if ! sed -i '/^[[:space:]]*#\?Port /d' /etc/ssh/sshd_config || ! sed -i "1i Port $final_p" /etc/ssh/sshd_config; then
            echo -e "${RED}❌ Ошибка записи конфигурации SSH, восстановление.${PLAIN}"
            ssh_rollback_port_change "$backup_file" "$current_p" false
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi
        if ! ssh_write_sshd_port_dropin "$final_p"; then
            echo -e "${RED}❌ Ошибка записи drop-in порта SSH, восстановление.${PLAIN}"
            ssh_rollback_port_change "$backup_file" "$current_p" false
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi

        # 3. SELinux для CentOS
        if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
            echo -e "${YELLOW}Обнаружен SELinux, настройка политики порта...${PLAIN}"
            if command -v semanage >/dev/null 2>&1; then
                semanage port -a -t ssh_port_t -p tcp "$final_p" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$final_p" 2>/dev/null
            else
                echo -e "${RED}❌ Критическая ошибка: отсутствует semanage! Выполняется откат.${PLAIN}"
                ssh_rollback_port_change "$backup_file" "$current_p" false
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                return
            fi
        fi

        # 4. Проверка синтаксиса новой конфигурации
        if ! "$sshd_bin" -t; then
            echo -e "${RED}❌ Критическая ошибка: синтаксис SSH неверен! Выполняется полный откат...${PLAIN}"
            ssh_rollback_port_change "$backup_file" "$current_p" false
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi
        
        # 5. Разрешение порта в брандмауэре
        if command -v ufw >/dev/null 2>&1; then ufw allow "$final_p"/tcp >/dev/null 2>&1; fi
        if command -v firewall-cmd >/dev/null 2>&1; then 
            firewall-cmd --permanent --add-port="$final_p"/tcp >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "$final_p" -j ACCEPT 2>/dev/null || true
        fi
        
        # 6. Синхронизация с systemd Socket (для Ubuntu/Debian облачных образов)
        local socket_managed=false socket_units
        socket_units=$(ssh_socket_units_for_host | tr '\n' ' ')
        if [[ -n "$socket_units" ]]; then
            echo -e "${YELLOW}Обнаружены SSH сокеты (${socket_units}), синхронизация порта...${PLAIN}"
            if ssh_write_socket_port_dropins "$final_p"; then
                socket_managed=true
                systemctl daemon-reload >/dev/null 2>&1 || true
            else
                echo -e "${RED}❌ Ошибка записи drop-in сокета SSH, откат.${PLAIN}"
                ssh_rollback_port_change "$backup_file" "$current_p" false
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                return
            fi
        fi
        
        # 7. Перезапуск служб
        echo -e "${CYAN}▶ Перезапуск SSH...${PLAIN}"
        local restart_ok=false
        if $socket_managed; then
            if ssh_restart_socket_units; then
                restart_ok=true
                ssh_service_restart >/dev/null 2>&1 || true
            fi
        else
            ssh_service_restart && restart_ok=true
        fi
        
        if $restart_ok; then
            echo -e "${GREEN}✅ Порт SSH успешно изменён на $final_p и разрешён в брандмауэре!${PLAIN}"
            echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
        else
            echo -e "${RED}❌ Критическая ошибка: не удалось перезапустить SSH! Откат...${PLAIN}"
            ssh_rollback_port_change "$backup_file" "$current_p" "$socket_managed"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi
        echo -e "${RED}${BOLD}======================================================${PLAIN}"
        echo -e "${YELLOW}⚠️ Важное предупреждение:${PLAIN}"
        echo -e "Это окно SSH НИ В КОЕМ СЛУЧАЕ НЕ ЗАКРЫВАЙТЕ!"
        echo -e "Немедленно откройте новое соединение на порт $final_p для проверки."
        echo -e "Если у облачного провайдера есть группа безопасности, убедитесь, что порт $final_p также разрешён!"
        echo -e "${RED}${BOLD}======================================================${PLAIN}"
    else
        echo -e "${BLUE}Порт не изменён.${PLAIN}"
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# Новое: управление Fail2ban (абстрактная версия)
# ---------------------------------------------------------
func_fail2ban() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Управление Fail2ban защитой от взлома${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    
    local current_p
    current_p=$(ss -tlnp 2>/dev/null | grep -w 'sshd' | awk '{print $4}' | awk -F: '{print $NF}' | head -n1)
    if [[ -z "$current_p" ]]; then
        current_p=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    fi
    current_p=${current_p:-22}
    
    echo -e "${YELLOW}👉 Текущий обнаруженный SSH-порт: ${GREEN}$current_p${PLAIN}"
    echo -e "------------------------------------------------"
    
    local f2b_status="${RED}Не установлен${PLAIN}"
    if command -v fail2ban-server >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban; then
            f2b_status="${GREEN}Запущен${PLAIN}"
        else
            f2b_status="${YELLOW}Остановлен${PLAIN}"
        fi
    fi
    
    echo -e "Текущий статус Fail2ban: [ $f2b_status ]"
    echo -e "  ${GREEN}1.${PLAIN} Установить и настроить Fail2ban ${YELLOW}(автоматически привязывается к текущему SSH-порту)${PLAIN}"
    echo -e "  ${BLUE}2.${PLAIN} Обновить защищаемый порт ${YELLOW}(если вы только что изменили SSH-порт)${PLAIN}"
    echo -e "  ${RED}3.${PLAIN} Полное удаление Fail2ban"
    echo -e "  ${RED}0.${PLAIN} Вернуться в главное меню / q"
    echo -e "------------------------------------------------"
    
    local f_choice
    read_trimmed f_choice "👉 Выберите действие: "
    
    case $f_choice in
        1|2)
            if [[ "$f_choice" == "1" ]]; then
                echo -e "${CYAN}Установка Fail2ban...${PLAIN}"
                if is_debian; then
                    install_pkg fail2ban python3-systemd
                else
                    install_pkg fail2ban
                fi
            fi
            
            if command -v fail2ban-server >/dev/null 2>&1; then
                echo -e "${CYAN}Запись конфигурации с привязкой к порту $current_p ...${PLAIN}"
                local f2b_backend="auto"
                if command -v journalctl >/dev/null 2>&1; then
                    f2b_backend="systemd"
                fi
                cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $current_p
backend = $f2b_backend
EOF
                systemctl enable fail2ban >/dev/null 2>&1
                systemctl restart fail2ban >/dev/null 2>&1
                if systemctl is-active --quiet fail2ban; then
                    echo -e "${GREEN}✅ Fail2ban настроен и запущен! (защищённый порт: $current_p, бэкенд: $f2b_backend)${PLAIN}"
                    echo -e "${YELLOW}💡 Правило: 5 ошибок пароля за 10 минут — IP блокируется на 24 часа.${PLAIN}"
                else
                    echo -e "${RED}❌ Не удалось запустить Fail2ban, показываю логи:${PLAIN}"
                    fail2ban-client -t 2>/dev/null || true
                    journalctl -u fail2ban -n 20 --no-pager 2>/dev/null || true
                fi
            else
                echo -e "${RED}❌ Не удалось установить или обнаружить Fail2ban, проверьте источники пакетов.${PLAIN}"
            fi
            ;;
        3)
            echo -e "${CYAN}Удаление Fail2ban...${PLAIN}"
            remove_pkg fail2ban
            quarantine_path /etc/fail2ban "/etc/vps-optimize/quarantine" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ Fail2ban удалён, старые конфигурации изолированы в /etc/vps-optimize/quarantine.${PLAIN}"
            ;;
        0|q|Q) return ;;
        *) echo -e "${RED}❌ Неверный ввод!${PLAIN}"; sleep 1 ;;
    esac
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# Новая функция: добавление SSH-публичного ключа
# ---------------------------------------------------------
func_add_ssh_key() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔑 Добавление SSH-публичного ключа (безопасная аутентификация)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Использование SSH-ключа избавляет от ввода пароля и полностью защищает от перебора паролей!${PLAIN}"
    echo -e "Подготовьте ваш публичный ключ (обычно начинается с ssh-rsa, ssh-ed25519, ecdsa или sk-*)."
    echo -e "------------------------------------------------"
    local user enable_mode
    user=$(ssh_choose_user) || { read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."; return; }
    if ssh_add_public_key_for_user "$user"; then
        echo -e "${GREEN}✅ Публичный ключ добавлен. Немедленно откройте новое SSH-окно для проверки входа по ключу.${PLAIN}"
        read_trimmed enable_mode "Включить режим "ключи + пароль /восстановление пароля/ "? (y/N): "
        if is_yes "$enable_mode"; then
            ssh_apply_auth_mode key_preferred || true
        fi
        echo -e "${YELLOW}После подтверждения 100% работы ключа вы можете войти в [6 Центр безопасности SSH] -> [2 Режим входа по ключам] и отключить пароль.${PLAIN}"
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# 5. Управление Docker (рефакторинг: неразрушающие изменения и откат)
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: docker_manage.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Аудит публичных портов Docker, статус управляемых проектов и безопасность Docker.

docker_port_line_is_public() {
    local line="$1"
    case "$line" in
        *"0.0.0.0:"*|*":::"*|*"[::]:"*|*"[0:0:0:0:0:0:0:0]:"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

print_managed_container_status() {
    local title="$1"
    local container="$2"
    local dir="$3"
    local state health ports compose_file

    if docker inspect "$container" >/dev/null 2>&1; then
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)
        ports=$(docker port "$container" 2>/dev/null | tr '\n' '; ')
        [[ -z "$ports" ]] && ports="Не опубликованы порты Docker или используется host-сеть"
        [[ -z "$health" ]] && health="healthcheck отсутствует"
        echo -e "${GREEN}${title}${PLAIN}: ${state} / ${health}"
        echo -e "  Порты: ${ports}"
    else
        echo -e "${YELLOW}${title}${PLAIN}: контейнер ${container} не обнаружен"
    fi

    compose_file=$(find_compose_file "$dir" 2>/dev/null || true)
    if [[ -n "$compose_file" ]]; then
        echo -e "  Compose: ${CYAN}${compose_file}${PLAIN}"
    else
        echo -e "  Compose: ${BLUE}каталог ${dir} не обнаружен${PLAIN}"
    fi
}

print_subscription_compose_status() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker не установлен, пропускаем состояние контейнеров подписок.${PLAIN}"
        return 0
    fi
    print_managed_container_status "SublinkPro" "sublinkpro" "/opt/sublinkpro"
    print_managed_container_status "妙妙屋订阅管理" "miaomiaowu" "/opt/miaomiaowu"
    print_managed_container_status "Sub-Store" "sub-store" "/opt/sub-store"
    print_managed_container_status "Dockge" "dockge" "/opt/dockge"
    print_managed_container_status "Komari" "komari" "/opt/komari"
}

func_docker_project_status() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Безопасность Docker > Статус контейнеров проектов"
    echo -e "${BOLD}🐳 Статус контейнеров, связанных с 443 / подписками${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Здесь проверяются только контейнеры, относящиеся к этому проекту: SublinkPro, 妙妙屋, Sub-Store, Dockge, Komari.${PLAIN}"
    echo -e "${YELLOW}3x-ui, Caddy, Nginx обычно управляются как systemd-службы, смотрите [15] или проверку [19].${PLAIN}"
    echo -e "------------------------------------------------"
    print_subscription_compose_status
    echo -e "------------------------------------------------"
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_docker_443_exposure_audit() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Безопасность Docker > Аудит публичного доступа 443"
    echo -e "${BOLD}🔎 Аудит публичных портов Docker${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Цель: после включения единого входа 443 инструменты подписки и панели управления должны по возможности слушать только 127.0.0.1, а наружу их выставлять через Caddy/Nginx.${PLAIN}"
    echo -e "------------------------------------------------"

    local found_public=false
    local line name ports
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        ports=$(docker port "$name" 2>/dev/null || true)
        [[ -z "$ports" ]] && continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if docker_port_line_is_public "$line"; then
                found_public=true
                echo -e "${YELLOW}⚠️ ${name}: ${line}${PLAIN}"
            fi
        done <<< "$ports"
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)

    if $found_public; then
        echo -e "------------------------------------------------"
        echo -e "${YELLOW}Рекомендация: подписки, Dockge, Komari следует привязывать к 127.0.0.1, а публичный доступ организовывать через [19] -> [8] добавление прокси-домена 443.${PLAIN}"
        echo -e "${YELLOW}Если действительно нужен прямой доступ, убедитесь, что безопасная группа облака, брандмауэр и доступ защищены.${PLAIN}"
    else
        echo -e "${GREEN}✅ Не обнаружено публичных портов Docker через 0.0.0.0 / ::.${PLAIN}"
    fi

    echo -e "------------------------------------------------"
    print_subscription_compose_status
    echo -e "------------------------------------------------"
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_docker_manage() {
    if declare -F ensure_docker_engine_ready >/dev/null 2>&1; then
        ensure_docker_engine_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
    elif ! command -v docker >/dev/null 2>&1; then
        clear
        echo -e "${RED}❌ Docker не обнаружен, и среда выполнения не поддерживает автоматическую установку.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    
    # Установка зависимостей (используем install_pkg)
    if ! command -v jq >/dev/null 2>&1; then install_pkg jq; fi

    while true; do
        clear
        local docker_ver
        docker_ver=$(docker -v | awk '{print $3}' | tr -d ',')
        
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Безопасность Docker"
        echo -e "${BOLD}🐳 Безопасность Docker (версия: ${GREEN}${docker_ver}${PLAIN}${BOLD})${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${GREEN}  1. Статус контейнеров 443 / подписок${PLAIN}"
        echo -e "${GREEN}  2. Аудит публичных портов Docker${PLAIN} ${YELLOW}(проверка обхода единого входа 443)${PLAIN}"
        echo -e "${GREEN}  3. Включить локальную защиту Docker${PLAIN} ${YELLOW}(ограничить опубликованные порты только 127.0.0.1)${PLAIN}"
        echo -e "${GREEN}  4. Отключить локальную защиту Docker${PLAIN} ${YELLOW}(восстановить доступ извне)${PLAIN}"
        echo -e "${BOLD}${YELLOW}  5. Обновить контейнеры подписок${PLAIN} ${CYAN}(SublinkPro / 妙妙屋 / Sub-Store)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        
        local c
        read_trimmed c "👉 Выберите действие: "
        case $c in
            1) func_docker_project_status ;;
            2) func_docker_443_exposure_audit ;;
            3)
                confirm_risk_action "Включить локальную защиту Docker" \
                    "Docker daemon.json и перезапуск службы Docker" \
                    "Восстановите из автоматически созданной резервной копии daemon.json и перезапустите Docker" \
                    "Убедитесь, что существующие контейнеры не зависят от прямого публичного доступа." || { echo -e "${BLUE}Операция отменена.${PLAIN}"; sleep 1; continue; }
                echo -e "${CYAN}▶ Настройка политики безопасности Docker...${PLAIN}"
                mkdir -p /etc/docker
                local conf_file="/etc/docker/daemon.json"
                local backup_file="${conf_file}.bak_$(date +%s)"
                local tmp_json
                tmp_json=$(mktemp /tmp/docker-daemon.XXXXXX) || { echo -e "${RED}❌ Не удалось создать временный файл, отмена.${PLAIN}"; sleep 1; continue; }
                
                if [[ -f "$conf_file" ]]; then
                    if ! cp -p "$conf_file" "$backup_file"; then
                        echo -e "${RED}❌ Не удалось создать резервную копию конфигурации Docker, отмена.${PLAIN}"
                        rm -f "$tmp_json"
                        sleep 1
                        continue
                    fi
                    echo -e "${YELLOW}⚠️ Создана резервная копия исходной конфигурации: $backup_file${PLAIN}"
                    
                    # Неразрушающее слияние с jq, сохранение всех существующих настроек
                    if ! jq '. + {"ip": "127.0.0.1", "log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}}' "$conf_file" > "$tmp_json" 2>/dev/null; then
                        echo -e "${RED}❌ Исходный daemon.json повреждён, слияние не удалось! Операция прервана.${PLAIN}"
                        rm -f "$tmp_json"
                        echo -e "${YELLOW}Резервная копия сохранена: $backup_file${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    fi
                    mv "$tmp_json" "$conf_file"
                else
                    # Файл отсутствует — создаём новый
                    cat <<EOF > "$conf_file"
{
  "ip": "127.0.0.1",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
                fi
                
                # Безопасный перезапуск с откатом при сбое
                if systemctl restart docker >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ Включена локальная защита, порты контейнеров доступны только для локального прокси!${PLAIN}"
                    [[ -f "$backup_file" ]] && echo -e "${CYAN}Резервная копия конфигурации Docker сохранена: $backup_file${PLAIN}"
                else
                    echo -e "${RED}❌ Критическая ошибка: новая конфигурация не позволяет запустить Docker! Автоматический откат...${PLAIN}"
                    if [[ -f "$backup_file" ]]; then
                        mv "$backup_file" "$conf_file"
                    else
                        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/docker" >/dev/null 2>&1 || true
                    fi
                    systemctl restart docker >/dev/null 2>&1
                fi
                sleep 2
                ;;
            4)
                local conf_file="/etc/docker/daemon.json"
                if [[ -f "$conf_file" ]]; then
                    confirm_risk_action "Отключить локальную защиту Docker" \
                        "Docker daemon.json и перезапуск Docker" \
                        "Восстановите из автоматически созданной резервной копии daemon.json" \
                        "После отключения опубликованные порты контейнеров могут снова стать публично доступными, проверьте брандмауэр и безопасную группу." || { echo -e "${BLUE}Операция отменена.${PLAIN}"; sleep 1; continue; }
                    echo -e "${CYAN}▶ Безопасное удаление ограничений Docker...${PLAIN}"
                    local backup_file="${conf_file}.bak_$(date +%s)"
                    local tmp_json
                    tmp_json=$(mktemp /tmp/docker-daemon.XXXXXX) || { echo -e "${RED}❌ Не удалось создать временный файл, отмена.${PLAIN}"; sleep 1; continue; }
                    if ! cp -p "$conf_file" "$backup_file"; then
                        echo -e "${RED}❌ Не удалось создать резервную копию конфигурации Docker, отмена.${PLAIN}"
                        rm -f "$tmp_json"
                        sleep 1
                        continue
                    fi

                    # Удаляем только поле ip
                    if ! jq 'del(.ip)' "$conf_file" > "$tmp_json" 2>/dev/null; then
                        echo -e "${RED}❌ Ошибка разбора JSON, операция прервана.${PLAIN}"
                        rm -f "$tmp_json"
                        echo -e "${YELLOW}Резервная копия сохранена: $backup_file${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    fi
                    mv "$tmp_json" "$conf_file"

                    if systemctl restart docker >/dev/null 2>&1; then
                        echo -e "${GREEN}✅ Локальная защита отключена, контейнеры снова доступны извне!${PLAIN}"
                        echo -e "${CYAN}Резервная копия сохранена: $backup_file${PLAIN}"
                    else
                        echo -e "${RED}❌ Ошибка: не удалось запустить Docker! Откат...${PLAIN}"
                        mv "$backup_file" "$conf_file"
                        systemctl restart docker >/dev/null 2>&1
                    fi
                else
                    echo -e "${BLUE}Файл ограничений не обнаружен, система уже открыта.${PLAIN}"
                fi
                sleep 2
                ;;
            5) func_update_subscription_tools ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный ввод!${PLAIN}"; sleep 1 ;;
        esac
    done
}
# ---------------------------------------------------------
# 6. Управление BBR
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: kernel_tuning.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Настройка BBR, TCP, ZRAM, установка оптимизированных ядер и очистка старых ядер.

func_bbr_manage() {
    clear
    echo -e "${CYAN}👉 Вызов скрипта сетевой оптимизации ylx2016...${PLAIN}"
    run_remote_script "Запуск скрипта сетевой оптимизации ylx2016" "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

sysctl_tune_split_line() {
    local line="$1"
    line="${line//$'\r'/}"
    printf '%s\n' "$line" | awk '
        {
            gsub(/;/, "\n")
            parts_count = split($0, parts, /\n/)
            for (part_idx = 1; part_idx <= parts_count; part_idx++) {
                rest = parts[part_idx]
                sub(/^[[:space:]]+/, "", rest)
                sub(/[[:space:]]+$/, "", rest)
                sub(/^(sudo[[:space:]]+)?sysctl[[:space:]]+(-w[[:space:]]+)?/, "", rest)
                while (match(rest, /[[:space:]]+((sudo[[:space:]]+)?sysctl[[:space:]]+(-w[[:space:]]+)?[A-Za-z0-9_.-]+[[:space:]]*=|[A-Za-z0-9_.-]+[[:space:]]*=)/)) {
                    before = substr(rest, 1, RSTART - 1)
                    if (before ~ /[^[:space:]]/) print before
                    rest = substr(rest, RSTART + 1)
                    sub(/^(sudo[[:space:]]+)?sysctl[[:space:]]+(-w[[:space:]]+)?/, "", rest)
                }
                if (rest ~ /[^[:space:]]/) print rest
            }
        }
    '
}

sysctl_tune_normalize_record() {
    local candidate="$1" key value
    candidate="$(trim_input "$candidate")"
    [[ -z "$candidate" ]] && return 1

    if [[ "$candidate" =~ ^(sudo[[:space:]]+)?sysctl[[:space:]]+(-w[[:space:]]+)?(.+)$ ]]; then
        candidate="$(trim_input "${BASH_REMATCH[3]}")"
    fi

    if [[ "$candidate" =~ ^([A-Za-z0-9_.-]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="$(trim_input "${BASH_REMATCH[2]}")"
        [[ -z "$value" ]] && return 2
        printf '%s = %s\n' "$key" "$value"
        return 0
    fi

    return 2
}

sysctl_tune_check_supported_file() {
    local conf_file="$1"
    local line key item_no=0 output
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim_input "$line")"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        item_no=$((item_no + 1))
        if [[ "$line" =~ ^([A-Za-z0-9_.-]+)[[:space:]]*= ]]; then
            key="${BASH_REMATCH[1]}"
        else
            echo -e "${RED}❌ Синтаксическая ошибка в строке ${item_no}: $line${PLAIN}"
            return 1
        fi
        if ! output=$(sysctl -n "$key" 2>&1); then
            echo -e "${RED}❌ Строка ${item_no} не поддерживается текущим ядром: $key${PLAIN}"
            [[ -n "$output" ]] && echo -e "${YELLOW}Вывод sysctl: ${output}${PLAIN}"
            return 1
        fi
    done < "$conf_file"
    return 0
}

sysctl_tune_apply_file() {
    local conf_file="$1"
    local line key value item_no=0 output
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim_input "$line")"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        item_no=$((item_no + 1))
        if [[ "$line" =~ ^([A-Za-z0-9_.-]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="$(trim_input "${BASH_REMATCH[2]}")"
        else
            echo -e "${RED}❌ Синтаксическая ошибка в строке ${item_no}: $line${PLAIN}"
            return 1
        fi
        if ! output=$(sysctl -w "$key=$value" 2>&1); then
            echo -e "${RED}❌ Строка ${item_no} не применилась: ${key} = ${value}${PLAIN}"
            if [[ "$output" == *"cannot stat"* || "$output" == *"No such file"* ]]; then
                echo -e "${YELLOW}Причина: ядро не поддерживает этот параметр.${PLAIN}"
            else
                echo -e "${YELLOW}Причина: ядро отклонило значение или синтаксическая ошибка.${PLAIN}"
            fi
            [[ -n "$output" ]] && echo -e "${YELLOW}Вывод sysctl: ${output}${PLAIN}"
            return 1
        fi
    done < "$conf_file"
    return 0
}

sysctl_tune_restore_previous_config() {
    local backup_f="$1"
    local temp_f="$2"
    if [[ -f "$backup_f" ]]; then
        mv "$backup_f" "$temp_f"
        sysctl -p "$temp_f" >/dev/null 2>&1
    else
        rm -f "$temp_f"
    fi
}

# ---------------------------------------------------------
# 7. Динамическая настройка TCP (исправленная версия: поддержка множества значений)
# ---------------------------------------------------------
func_tcp_tune() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🚀 Динамическая оптимизация TCP (Omnitt)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "👉 Рекомендуется открыть в браузере: ${BLUE}https://omnitt.com/${PLAIN} для получения параметров под вашу сеть"
    echo -e "------------------------------------------------"
    
    read_trimmed yn "❓ Готовы вставить параметры? (y продолжение / n отмена): "
    if ! is_yes "$yn"; then return; fi
    
    local temp_f="/etc/sysctl.d/99-omnitt-tune.conf"
    local backup_f="${temp_f}.bak_$(date +%s)"
    
    # Начало транзакции: резервная копия
    if [[ -f "$temp_f" ]]; then
        cp "$temp_f" "$backup_f"
    fi
    
    > "$temp_f"
    echo -e "\n${YELLOW}👇 Вставьте код прямо ниже (правой кнопкой).${PLAIN}"
    echo -e "${YELLOW}💡 После вставки нажмите Enter, затем введите ${RED}EOF${YELLOW} и снова Enter для сохранения:${PLAIN}"
    
    local has_content=false
    local parse_failed=false
    while IFS= read -r line; do
        line="$(trim_input "$line")"
        
        if [[ "${line,,}" == "eof" ]]; then
            break
        fi
        
        if [[ -z "$line" || "$line" =~ ^# ]]; then
            echo "$line" >> "$temp_f"
            continue
        fi

        local candidate record status
        while IFS= read -r candidate; do
            record=$(sysctl_tune_normalize_record "$candidate")
            status=$?
            case "$status" in
                0)
                    echo "$record" >> "$temp_f"
                    has_content=true
                    ;;
                1)
                    ;;
                *)
                    echo -e "${RED}❌ Синтаксическая ошибка в параметре: $candidate${PLAIN}"
                    echo -e "${YELLOW}Формат: net.ipv4.tcp_xxx = value${PLAIN}"
                    parse_failed=true
                    ;;
            esac
        done < <(sysctl_tune_split_line "$line")
    done
    
    if $parse_failed; then
        echo -e "${YELLOW}Выполняется откат...${PLAIN}"
        sysctl_tune_restore_previous_config "$backup_f" "$temp_f"
        echo -e "${BLUE}✅ Восстановлена исходная конфигурация TCP.${PLAIN}"
    elif $has_content; then
        echo -e "${CYAN}▶ Проверка и применение новых параметров TCP...${PLAIN}"
        if sysctl_tune_check_supported_file "$temp_f" && sysctl_tune_apply_file "$temp_f"; then
            echo -e "${GREEN}✅ Динамическая оптимизация TCP применена успешно! Пропускная способность улучшена.${PLAIN}"
            rm -f "$backup_f"
        else
            echo -e "${RED}❌ Ошибка: некоторые параметры не поддерживаются ядром или неверны!${PLAIN}"
            echo -e "${YELLOW}Выполняется откат...${PLAIN}"
            sysctl_tune_restore_previous_config "$backup_f" "$temp_f"
            echo -e "${BLUE}✅ Восстановлена исходная конфигурация TCP.${PLAIN}"
        fi
    else
        echo -e "${YELLOW}⚠️ Действительные параметры TCP не обнаружены, операция отменена.${PLAIN}"
        sysctl_tune_restore_previous_config "$backup_f" "$temp_f"
    fi
    
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}

# ---------------------------------------------------------
# 8. Умная настройка памяти (рефакторинг: безопасное управление и DRY)
# ---------------------------------------------------------
func_zram_swap() {
    clear
    local mem
    mem=$(free -m | awk '/^Mem:/{print $2}')
    echo -e "${CYAN}💡 Автоматическая адаптивная настройка (обнаружено ${mem} МБ физической памяти)${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e " ${GREEN}1. Агрессивный профиль (для малых VPS <1 ГБ)${PLAIN}"
    echo -e "    - ZRAM 100%, Swappiness=100. Максимальная защита от зависаний."
    echo -e " ${GREEN}2. Активный профиль (для 2-4 ГБ)${PLAIN}"
    echo -e "    - ZRAM 70%, Swappiness=60. Баланс производительности и пространства."
    echo -e " ${GREEN}3. Консервативный профиль (для >8 ГБ)${PLAIN}"
    echo -e "    - ZRAM 25%, Swappiness=10. Максимальная отзывчивость."
    echo -e "------------------------------------------------"
    
    local choice
    read_trimmed choice "👉 Выберите профиль [1/2/3] (Enter для автоматического выбора по памяти): "
    
    if [[ -z "$choice" ]]; then
        if [[ "$mem" -lt 1024 ]]; then choice=1
        elif [[ "$mem" -le 4096 ]]; then choice=2
        else choice=3
        fi
        echo -e "${YELLOW}💡 Система автоматически выбрала профиль $choice на основе памяти (${mem} МБ).${PLAIN}"
        sleep 1.5
    fi
    
    # Защита от не-Debian систем
    if ! is_debian; then
        echo -e "${RED}❌ К сожалению, автоматическая настройка ZRAM поддерживается только на Debian/Ubuntu.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "${CYAN}▶ Этап 1: Настройка дискового Swap (резерв 512 МБ)...${PLAIN}"
    
    swapoff -a >/dev/null 2>&1
    local old_swap
    for old_swap in /swapfile /swap.img /var/swap /var/swapfile; do
        quarantine_path "$old_swap" "/root/vps-optimize-quarantine/swap" >/dev/null 2>&1 || true
    done
    
    dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile >/dev/null 2>&1
    
    sed -i -E 's/^([^#].*[[:space:]]swap[[:space:]].*)/#\1/' /etc/fstab
    sed -i '\@^/swapfile@d' /etc/fstab
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo -e "${GREEN}✅ Создан минимальный Swap 512 МБ как последняя защита от зависаний!${PLAIN}"
    
    echo -e "${CYAN}▶ Этап 2: Настройка ZRAM...${PLAIN}"
    
    install_pkg zram-tools
    modprobe zram >/dev/null 2>&1
    
    local zram_conf="/etc/default/zramswap"
    local percent=70
    local swap_val=60
    
    case $choice in
        1) percent=100; swap_val=100 ;;
        2) percent=70; swap_val=60 ;;
        3) percent=25; swap_val=10 ;;
        *) percent=70; swap_val=60 ;;
    esac
    
    cat <<EOF > "$zram_conf"
ALGO=zstd
PERCENT=$percent
PRIORITY=100
EOF
    
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable zramswap >/dev/null 2>&1
    systemctl restart zramswap >/dev/null 2>&1
    
    if ! grep -q zram /proc/swaps; then
        if command -v zramswap >/dev/null 2>&1; then
            zramswap start >/dev/null 2>&1
        elif [[ -x /usr/sbin/zramswap ]]; then
            /usr/sbin/zramswap start >/dev/null 2>&1
        fi
    fi
    
    echo "vm.swappiness = $swap_val" > /etc/sysctl.d/99-zram-swappiness.conf
    sysctl -p /etc/sysctl.d/99-zram-swappiness.conf >/dev/null 2>&1
    
if grep -q zram /proc/swaps; then
        echo -e "${GREEN}✅ Настройка ZRAM завершена! (коэффициент сжатия: ${percent}%, swappiness: ${swap_val})${PLAIN}"
    else
        echo -e "${RED}❌ Внимание: ядро отказалось монтировать ZRAM (часто на LXC/OpenVZ).${PLAIN}"
        echo -e "${CYAN}▶ Запуск запасного варианта: расширение Swap и настройка ядра...${PLAIN}"
        
        # 1. Расширение Swap до 1 ГБ
        swapoff /swapfile >/dev/null 2>&1
        quarantine_path /swapfile "/root/vps-optimize-quarantine/swap" >/dev/null 2>&1 || true
        dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1
        
        # 2. Параметры ядра для запасного варианта
        cat <<EOF > /etc/sysctl.d/99-fallback-mem.conf
vm.swappiness = 30
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
EOF
        sysctl -p /etc/sysctl.d/99-fallback-mem.conf >/dev/null 2>&1
        
        echo -e "${GREEN}✅ Запасной вариант применён: создан Swap 1 ГБ и активирована консервативная политика памяти!${PLAIN}"
    fi
    
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# 9. Установка/переключение оптимизированных ядер (Cloud/KVM — стабильно, XanMod — продвинутый)
# ---------------------------------------------------------
normalize_kernel_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "unknown" ;;
    esac
}

apt_pkg_available() {
    local pkg="$1"
    apt-cache show "$pkg" >/dev/null 2>&1
}

set_grub_default_kernel_by_keyword() {
    local kernel_keyword="$1"
    local target_v menu_1 menu_2

    if ! command -v dpkg >/dev/null 2>&1 || [[ ! -f /etc/default/grub ]]; then
        echo -e "${YELLOW}⚠️ dpkg или /etc/default/grub не обнаружены, автоматическое управление загрузкой пропущено.${PLAIN}"
        return 0
    fi

    target_v=$(dpkg -l | awk '/^ii[[:space:]]+linux-image-[0-9]/ && /'"$kernel_keyword"'/ {print $2}' | sed 's/linux-image-//' | sort -V | tail -n 1)
    if [[ -z "$target_v" ]]; then
        echo -e "${RED}❌ Ошибка: не найдено установленное ядро ${kernel_keyword}, проверьте логи установки.${PLAIN}"
        return 1
    fi

    echo -e "${CYAN}▶ Настройка GRUB для загрузки ядра: $target_v ...${PLAIN}"
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    else
        echo "GRUB_DEFAULT=saved" >> /etc/default/grub
    fi
    grep -q "^GRUB_SAVEDEFAULT=true" /etc/default/grub || echo "GRUB_SAVEDEFAULT=true" >> /etc/default/grub
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null 2>&1
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
    fi

    local grub_cfg="/boot/grub/grub.cfg"
    [[ -f "$grub_cfg" ]] || grub_cfg="/boot/grub2/grub.cfg"
    if [[ ! -f "$grub_cfg" ]]; then
        echo -e "${YELLOW}⚠️ grub.cfg не найден, новое ядро установлено, но проверьте вручную загрузочный пункт после перезагрузки.${PLAIN}"
        return 0
    fi

    menu_1=$(grep -i "submenu 'Advanced options for" "$grub_cfg" | cut -d"'" -f2 | head -n 1)
    menu_2=$(grep -i "menuentry '.*$target_v.*'" "$grub_cfg" | grep -iv "recovery" | cut -d"'" -f2 | head -n 1)

    if [[ -n "$menu_1" && -n "$menu_2" ]]; then
        grub-set-default "$menu_1>$menu_2" 2>/dev/null || grub2-set-default "$menu_1>$menu_2" 2>/dev/null || true
        echo -e "${GREEN}✅ Настройка GRUB выполнена! После перезагрузки загрузится $target_v${PLAIN}"
        return 0
    fi

    echo -e "${YELLOW}⚠️ Предупреждение: не удалось определить пункт меню GRUB. Система может загружать ядро с наибольшим номером версии.${PLAIN}"
    return 1
}

install_cloud_kvm_kernel() {
    local arch kernel_keyword="" pkg
    local candidates=()

    if uname -r | grep -qE "kvm|cloud|virtual"; then
        echo -e "${GREEN}✅ Система уже использует оптимизированное ядро KVM/Cloud/Virtual ($(uname -r)), установка не требуется!${PLAIN}"
        return 0
    fi

    arch=$(normalize_kernel_arch)
    if [[ "$arch" == "unknown" ]]; then
        echo -e "${RED}❌ Текущая архитектура $(uname -m) не поддерживает автоматическую установку лёгкого ядра.${PLAIN}"
        return 1
    fi

    echo -e "${CYAN}▶ Установка официального лёгкого ядра Cloud/KVM/Virtual...${PLAIN}"
    ensure_minimal_system_compat

    if [[ "$OS" == "debian" ]]; then
        if [[ "$arch" == "amd64" ]]; then
            candidates=("linux-image-cloud-amd64" "linux-image-amd64")
        else
            candidates=("linux-image-cloud-arm64" "linux-image-arm64")
        fi
        kernel_keyword="cloud|${arch}"
    elif [[ "$OS" == "ubuntu" ]]; then
        if [[ "$arch" == "amd64" ]]; then
            candidates=("linux-kvm" "linux-virtual" "linux-generic")
        else
            candidates=("linux-virtual" "linux-generic")
        fi
        kernel_keyword="kvm|virtual|generic"
    else
        echo -e "${RED}❌ Установка Cloud/KVM/Virtual ядра поддерживается только на Debian и Ubuntu.${PLAIN}"
        return 1
    fi

    if is_debian; then
        export DEBIAN_FRONTEND=noninteractive
        apt_update_once || true
        unset DEBIAN_FRONTEND
    fi

    for pkg in "${candidates[@]}"; do
        if ! apt_pkg_available "$pkg"; then
            echo -e "${YELLOW}  - Пакет ${pkg} недоступен в репозитории, пробую следующий...${PLAIN}"
            continue
        fi
        echo -e "${CYAN}▶ Попытка установки пакета ядра: ${pkg}${PLAIN}"
        if install_pkg "$pkg"; then
            echo -e "${GREEN}✅ Установлен пакет ядра: ${pkg}${PLAIN}"
            set_grub_default_kernel_by_keyword "$kernel_keyword"
            return $?
        fi
        echo -e "${YELLOW}  - ${pkg} не установился, пробую следующий...${PLAIN}"
    done

    echo -e "${RED}❌ Не удалось установить доступное лёгкое ядро, проверьте версию системы, архитектуру и источники.${PLAIN}"
    return 1
}

xanmod_cpu_level() {
    local flags level="x64v1"
    flags=$(awk -F: '/flags/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
    if [[ "$flags" =~ avx2 ]] && [[ "$flags" =~ bmi2 ]] && [[ "$flags" =~ fma ]] && [[ "$flags" =~ movbe ]]; then
        level="x64v3"
    fi
    if [[ "$flags" =~ avx512f ]] && [[ "$flags" =~ avx512bw ]] && [[ "$flags" =~ avx512vl ]]; then
        level="x64v4"
    fi
    if [[ "$flags" =~ cx16 ]] && [[ "$flags" =~ lahf_lm ]] && [[ "$flags" =~ popcnt ]] && [[ "$flags" =~ sse4_2 ]]; then
        [[ "$level" == "x64v1" ]] && level="x64v2"
    fi
    echo "$level"
}

xanmod_candidate_packages() {
    local level="${1:-x64v1}"
    case "$level" in
        x64v4) printf '%s\n' linux-xanmod-lts-x64v4 linux-xanmod-x64v4 linux-xanmod-lts-x64v3 linux-xanmod-x64v3 linux-xanmod-lts-x64v2 linux-xanmod-x64v2 linux-xanmod-lts-x64v1 linux-xanmod-x64v1 ;;
        x64v3) printf '%s\n' linux-xanmod-lts-x64v3 linux-xanmod-x64v3 linux-xanmod-lts-x64v2 linux-xanmod-x64v2 linux-xanmod-lts-x64v1 linux-xanmod-x64v1 ;;
        x64v2) printf '%s\n' linux-xanmod-lts-x64v2 linux-xanmod-x64v2 linux-xanmod-lts-x64v1 linux-xanmod-x64v1 ;;
        *) printf '%s\n' linux-xanmod-lts-x64v1 linux-xanmod-x64v1 ;;
    esac
}

xanmod_supported_codename() {
    case "$1" in
        bookworm|trixie|forky|sid|jammy|noble|plucky) return 0 ;;
        *) return 1 ;;
    esac
}

add_xanmod_repo() {
    local codename="$1"
    local key_tmp
    mkdir -p /etc/apt/keyrings
    quarantine_path /etc/apt/keyrings/xanmod-archive-keyring.gpg "/etc/vps-optimize/quarantine/apt-keyrings" >/dev/null 2>&1 || true
    key_tmp=$(mktemp /tmp/xanmod-key.XXXXXX) || return 1
    if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 https://dl.xanmod.org/archive.key -o "$key_tmp"; then
        rm -f "$key_tmp"
        echo -e "${RED}❌ Не удалось загрузить GPG key XanMod.${PLAIN}"
        return 1
    fi
    if ! gpg --batch --yes --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg "$key_tmp"; then
        rm -f "$key_tmp"
        echo -e "${RED}❌ Не удалось записать GPG key XanMod.${PLAIN}"
        return 1
    fi
    rm -f "$key_tmp"
    echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${codename} main" > /etc/apt/sources.list.d/xanmod-release.list
    apt-get update -qq && APT_UPDATED=1
}

install_xanmod_kernel_package() {
    local preferred_level="$1"
    local pkg
    while IFS= read -r pkg; do
        apt_pkg_available "$pkg" || continue
        echo -e "${CYAN}▶ Попытка установки пакета XanMod: ${pkg}${PLAIN}"
        if install_pkg "$pkg"; then
            echo -e "${GREEN}✅ Установлен пакет XanMod: ${pkg}${PLAIN}"
            return 0
        fi
        echo -e "${YELLOW}  - ${pkg} не установился, пробую более консервативный...${PLAIN}"
    done < <(xanmod_candidate_packages "$preferred_level")

    return 1
}

install_xanmod_kernel() {
    local codename confirm arch cpu_level

    if uname -r | grep -qi "xanmod"; then
        echo -e "${GREEN}✅ Система уже использует ядро XanMod ($(uname -r)), установка не требуется!${PLAIN}"
        return 0
    fi

    if ! is_debian; then
        echo -e "${RED}❌ Автоматическая установка XanMod поддерживается только на Debian/Ubuntu.${PLAIN}"
        return 1
    fi

    arch=$(normalize_kernel_arch)
    if [[ "$arch" != "amd64" ]]; then
        echo -e "${RED}❌ Официальные ядра XanMod x64v поддерживают только x86_64/amd64, текущая архитектура $(uname -m).${PLAIN}"
        echo -e "${YELLOW}Рекомендуется использовать официальное Cloud/Virtual ядро.${PLAIN}"
        return 1
    fi

    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -sc 2>/dev/null)
    fi
    if [[ -z "$codename" ]]; then
        echo -e "${RED}❌ Не удалось определить кодовое имя системы, невозможно безопасно добавить репозиторий XanMod.${PLAIN}"
        return 1
    fi
    if ! xanmod_supported_codename "$codename"; then
        echo -e "${YELLOW}⚠️ Кодовое имя ${codename} может быть не в списке поддерживаемых XanMod.${PLAIN}"
        echo -e "${YELLOW}Скрипт попытается добавить репозиторий; если apt update не удастся, используйте официальное Cloud/Virtual ядро.${PLAIN}"
    fi

    cpu_level=$(xanmod_cpu_level)

    echo -e "${RED}⚠️ XanMod — стороннее производительное ядро, может повлиять на совместимость с драйверами/DKMS/облачными провайдерами.${PLAIN}"
    echo -e "${YELLOW}Обнаружен уровень CPU: ${cpu_level}, будет попытка установки соответствующего XanMod LTS с автоматическим понижением.${PLAIN}"
    echo -e "${YELLOW}Рекомендуется иметь снимок, консоль восстановления и знать, как вернуться к старому ядру через GRUB.${PLAIN}"
    confirm_risk_action "Установка ядра XanMod" \
        "Пакеты ядра, конфигурация загрузчика и меню GRUB" \
        "Восстановите из текущего загрузочного ядра или режима восстановления" \
        "Рекомендуется создать снимок VPS и убедиться, что это не OpenVZ." || { echo -e "${BLUE}Установка XanMod отменена.${PLAIN}"; return 1; }

    echo -e "${CYAN}▶ Добавление официального APT-репозитория XanMod и установка совместимого ядра...${PLAIN}"
    ensure_minimal_system_compat
    install_pkg ca-certificates curl gpg gnupg || return 1
    add_xanmod_repo "$codename" || return 1

    if ! install_xanmod_kernel_package "$cpu_level"; then
        echo -e "${RED}❌ Не удалось установить ядро XanMod, возможно, кодовое имя/репозиторий/уровень CPU несовместимы.${PLAIN}"
        return 1
    fi

    set_grub_default_kernel_by_keyword "xanmod"
}

func_install_kernel() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}☁️ Установка/переключение оптимизированных ядер${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${GREEN}  1. Официальное Cloud/KVM/Virtual ядро${PLAIN} ${YELLOW}(рекомендуется: стабильное, лёгкое, лучше совместимость)${PLAIN}"
    echo -e "     На Debian/Ubuntu будет автоматически подобрано cloud/kvm/virtual/generic."
    echo -e "${GREEN}  2. XanMod производительное ядро${PLAIN} ${YELLOW}(продвинутый: автоматическое определение x64v1-v4)${PLAIN}"
    echo -e "     Подходит: для тех, кто готов экспериментировать, нужна низкая задержка/новые функции; только amd64, требуется снимок."
    echo -e "------------------------------------------------"
    echo -e "${RED}  0. Вернуться / q${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local kernel_choice virt
    read_trimmed kernel_choice "👉 Выберите тип ядра [рекомендуется 1]: "
    kernel_choice="${kernel_choice:-1}"
    [[ "$kernel_choice" == "0" ]] && return

    virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    if [[ "$virt" =~ lxc|openvz ]]; then
        echo -e "${RED}❌ Обнаружена контейнерная виртуализация $virt!${PLAIN}"
        echo -e "${YELLOW}💡 Контейнеры используют ядро хоста, смена ядра невозможна. Операция безопасно остановлена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    local arch
    arch=$(normalize_kernel_arch)
    if [[ "$arch" == "unknown" ]]; then
        echo -e "${RED}❌ Текущая архитектура $(uname -m) не поддерживает автоматическую смену ядра.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    if [[ "$kernel_choice" == "2" && "$arch" != "amd64" ]]; then
        echo -e "${RED}❌ XanMod x64v поддерживает только x86_64/amd64, текущая $(uname -m).${PLAIN}"
        echo -e "${YELLOW}Рекомендуется выбрать [1] официальное Cloud/KVM/Virtual ядро.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    local install_rc=0
    case "$kernel_choice" in
        1) install_cloud_kvm_kernel ;;
        2) install_xanmod_kernel ;;
        *) echo -e "${RED}❌ Неверный выбор.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return ;;
    esac
    install_rc=$?
    if [[ "$install_rc" -ne 0 ]]; then
        echo -e "------------------------------------------------"
        echo -e "${YELLOW}⚠️ Установка/переключение ядра не завершены, перезагрузка не предлагается.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "------------------------------------------------"
    echo -e "${YELLOW}⚠️ Инструкция по применению:${PLAIN}"
    echo -e "1. Настройка загрузки завершена, сначала выберите ${RED}[17] Перезагрузить сервер${PLAIN}."
    echo -e "2. После перезагрузки выполните ${GREEN}uname -r${PLAIN} для проверки фактического ядра."
    echo -e "3. После подтверждения стабильности войдите в это меню и выберите ${GREEN}[5] Очистка старых ядер${PLAIN}."

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

# ---------------------------------------------------------
# 10. Очистка старых ядер
# ---------------------------------------------------------
func_clean_kernel() {
    clear
    if [[ ! "$OS" =~ debian|ubuntu ]]; then
        echo -e "${RED}❌ Эта функция поддерживается только на Debian/Ubuntu!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    local current_k
    current_k=$(uname -r)
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧹 Очистка старых ядер${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "Текущее работающее ядро: ${GREEN}${current_k}${PLAIN}"
    echo -e "${RED}⚠️ Система автоматически исключает работающее ядро, а также популярные облачные/виртуальные/производительные ядра.${PLAIN}"
    echo -e "------------------------------------------------"
    
    mapfile -t old_kernels < <(dpkg -l | awk '$1 == "ii" && $2 ~ /^linux-image-[0-9]/ {print $2}' | grep -v "$current_k" | grep -Ev "cloud|kvm|virtual|generic|xanmod")

    if [[ ${#old_kernels[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Система чиста, старых ядер для удаления не найдено.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "${YELLOW}Обнаружены следующие старые ядра для очистки:${PLAIN}"
    for i in "${!old_kernels[@]}"; do
        echo -e " [${CYAN}$((i+1))${PLAIN}] ${old_kernels[$i]}"
    done
    echo -e " [${RED}0${PLAIN}] Отмена"
    echo -e "------------------------------------------------"

    local k_choice
    read_trimmed k_choice "👉 Введите номер для удаления: "

    if [[ "$k_choice" == "0" ]]; then
        echo -e "${BLUE}Удаление отменено.${PLAIN}"
    elif [[ "$k_choice" =~ ^[1-9][0-9]*$ ]] && [[ "$k_choice" -le "${#old_kernels[@]}" ]]; then
        local target_k="${old_kernels[$((k_choice-1))]}"
        confirm_danger "Удалить старое ядро ${target_k}" "Будет удалён пакет ядра и обновлён GRUB; ошибка может повлиять на следующую загрузку." "Рекомендуется создать снимок VPS; работающее ядро автоматически исключено, в случае проблем восстановитесь из снимка или режима восстановления." || {
            echo -e "${BLUE}Удаление отменено.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        }
        echo -e "${CYAN}Удаление $target_k и обновление GRUB...${PLAIN}"
        export DEBIAN_FRONTEND=noninteractive
        if apt-get purge -yq "$target_k" && update-grub >/dev/null 2>&1 && apt-get autoremove --purge -yq >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Старое ядро [$target_k] удалено! Освобождено место на диске.${PLAIN}"
        else
            echo -e "${RED}❌ Ошибка удаления! Проверьте зависимости или прерывание.${PLAIN}"
        fi
        unset DEBIAN_FRONTEND
    else
        echo -e "${RED}❌ Неверный выбор!${PLAIN}"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

# ---------------------------------------------------------
# 11. Аппаратный зонд
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: diagnostics_status.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Компактные вспомогательные функции статуса служб и обзор оборудования/среды выполнения.

service_status_compact() {
    local svc="$1"
    if service_unit_exists "$svc"; then
        if systemctl is-active --quiet "$svc"; then
            printf '%b' "${GREEN}Запущен${PLAIN}"
        else
            printf '%b' "${YELLOW}Не запущен${PLAIN}"
        fi
    else
        printf '%b' "${BLUE}Не установлен${PLAIN}"
    fi
}

service_unit_exists() {
    local svc="$1"
    local units
    units=$(systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null || true)
    [[ -n "$units" ]] && return 0
    systemctl status "$svc" >/dev/null 2>&1
}

xui_panel_installed_by_files() {
    command -v 3x-ui >/dev/null 2>&1 && return 0
    command -v x-ui >/dev/null 2>&1 && return 0
    [[ -x /usr/local/x-ui/x-ui ]] && return 0
    [[ -f /etc/x-ui/x-ui.db || -f /usr/local/x-ui/x-ui.db || -f /usr/local/x-ui/bin/x-ui.db ]] && return 0
    return 1
}

xui_panel_service_name() {
    local svc
    for svc in 3x-ui x-ui x-panel; do
        if service_unit_exists "$svc"; then
            printf '%s' "$svc"
            return 0
        fi
    done
    return 1
}

xui_panel_status_compact() {
    local svc
    if svc=$(xui_panel_service_name); then
        if systemctl is-active --quiet "$svc"; then
            printf '%b' "${GREEN}Запущен${PLAIN}"
        else
            printf '%b' "${YELLOW}Не запущен${PLAIN}"
        fi
    elif xui_panel_installed_by_files; then
        printf '%b' "${YELLOW}Установлен/не запущен${PLAIN}"
    else
        printf '%b' "${BLUE}Не установлен${PLAIN}"
    fi
}

xui_panel_state_for_issue() {
    local svc
    if svc=$(xui_panel_service_name); then
        if systemctl is-active --quiet "$svc"; then
            echo "Запущен (${svc}.service)"
        else
            echo "Установлен/не запущен (${svc}.service)"
        fi
    elif xui_panel_installed_by_files; then
        echo "Установлен/не обнаружен systemd-сервис"
    else
        echo "Не обнаружен"
    fi
}

docker_public_binding_count() {
    local count=0
    local name line ports
    command -v docker >/dev/null 2>&1 || { echo "0"; return 0; }
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        ports=$(docker port "$name" 2>/dev/null || true)
        [[ -z "$ports" ]] && continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            docker_port_line_is_public "$line" && count=$((count + 1))
        done <<< "$ports"
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
    echo "$count"
}

print_project_runtime_overview() {
    echo -e "${CYAN}🧩 Обзор сценариев VPS-Optimize${PLAIN}"
    echo -e "Версия скрипта : ${GREEN}${SCRIPT_VERSION}${PLAIN}"
    echo -e "Ключевые службы : nginx[$(service_status_compact nginx)] caddy[$(service_status_compact caddy)] docker[$(service_status_compact docker)] панель 3x-ui[$(xui_panel_status_compact)] ядро Xray[$(service_status_compact xray)]"

    if [[ -f /etc/vps-optimize/sni-stack.env ]]; then
        if load_sni_stack_env >/dev/null 2>&1; then
            echo -e "443 вход : ${NGINX_LISTEN_ADDR}:${NGINX_LISTEN_PORT} -> Caddy ${CADDY_LISTEN_ADDR}:${CADDY_LISTEN_PORT} / REALITY ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
            echo -e "3x-ui   : панель https://${PANEL_DOMAIN}${PANEL_WEB_PATH} -> ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
            echo -e "Пути подписок : обычная ${SUB_URI_PATH} / Clash-Mihomo ${CLASH_URI_PATH} -> ${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT}"
            echo -e "Дополнительная маршрутизация : сайтов/прокси ${#SITE_DOMAINS[@]}, TCP/SNI входящих ${#TCP_ROUTE_SNIS[@]}"
        else
        echo -e "443 вход : ${YELLOW}Обнаружен конфигурационный файл, но не удалось прочитать, выполните [19] -> [13] проверку.${PLAIN}"
        fi
    else
        echo -e "443 вход : ${BLUE}Ещё не настроен; если нужен общий 443 для панели/подписок/REALITY, используйте [19].${PLAIN}"
    fi

    if command -v docker >/dev/null 2>&1; then
        local running_containers public_binds
        running_containers=$(docker ps -q 2>/dev/null | wc -l | tr -d '[:space:]')
        public_binds=$(docker_public_binding_count)
        echo -e "Docker   : запущено контейнеров ${running_containers:-0}, публичных маппингов ${public_binds:-0}"
    fi

    if declare -F print_traffic_guard_diagnostic_summary >/dev/null; then
        print_traffic_guard_diagnostic_summary 3 no
    fi
}

func_system_info() {
    clear
    local os_name
    os_name=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"')
    
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🖥️ Полная информация об оборудовании и сети${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}ОС        :${PLAIN} $os_name ($(uname -m))"
    echo -e "${YELLOW}Ядро      :${PLAIN} $(uname -r)"
    echo -e "${YELLOW}Виртуализация :${PLAIN} $(systemd-detect-virt 2>/dev/null || echo "неизвестно")"
    echo -e "------------------------------------------------"
    echo -e "${YELLOW}Модель CPU :${PLAIN} $(lscpu | grep "Model name:" | sed 's/Model name:\s*//')"
    echo -e "${YELLOW}Ядер CPU   :${PLAIN} $(nproc)"
    echo -e "------------------------------------------------"
    echo -e "${YELLOW}Физическая память :${PLAIN} $(free -h | awk '/^Mem:/ {print $3}') / $(free -h | awk '/^Mem:/ {print $2}')"
    echo -e "${YELLOW}Swap        :${PLAIN} $(free -h | awk '/^Swap:/ {print $3}') / $(free -h | awk '/^Swap:/ {print $2}')"
    echo -e "${YELLOW}Дисковое пространство :${PLAIN} $(df -h / | awk 'NR==2 {print $3}') / $(df -h / | awk 'NR==2 {print $2}')"
    echo -e "------------------------------------------------"
    echo -e "${YELLOW}IPv4 адрес :${PLAIN} $(curl -s4 --max-time 3 icanhazip.com || echo "нет публичного IPv4")"
    echo -e "${YELLOW}IPv6 адрес :${PLAIN} $(curl -s6 --max-time 3 icanhazip.com || echo "нет публичного IPv6")"
    echo -e "${YELLOW}Время работы :${PLAIN} $(uptime -p | sed 's/up //')"
    echo -e "------------------------------------------------"
    print_project_runtime_overview
    echo -e "${CYAN}================================================${PLAIN}"
    
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата в главное меню..."
}

# ---------------------------------------------------------
# 12. Комплексный тестовый набор
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: diagnostics_network.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Сетевые пробы 443, запуск бенчмарк-скриптов и интеграция port-dog.

probe_host_for_listen_addr() {
    local addr="$1"
    case "$addr" in
        ""|"0.0.0.0"|"::"|"[::]") echo "127.0.0.1" ;;
        *:*) echo "localhost" ;;
        *) echo "$addr" ;;
    esac
}

tcp_probe_host() {
    local label="$1"
    local host="$2"
    local port="$3"
    local attempts="${4:-3}"
    local delay="${5:-1}"
    local i

    for ((i = 1; i <= attempts; i++)); do
        if tcp_probe_once "$host" "$port"; then
            echo -e "${GREEN}✅ ${label}: ${host}:${port} доступен${PLAIN}"
            return 0
        fi
        if local_listen_socket_matches_probe "$host" "$port"; then
            echo -e "${GREEN}✅ ${label}: ${host}:${port} обнаружен локальный слушатель${PLAIN}"
            return 0
        fi
        [[ "$i" -lt "$attempts" ]] && sleep "$delay"
    done

    echo -e "${RED}❌ ${label}: ${host}:${port} недоступен${PLAIN}"
    return 1
}

tcp_probe_once() {
    local host="$1"
    local port="$2"

    tcp_target_reachable "$host" "$port"
}

is_loopback_probe_host() {
    case "$1" in
        127.*|localhost|::1|"[::1]") return 0 ;;
        *) return 1 ;;
    esac
}

local_listen_socket_matches_probe() {
    local host="$1"
    local port="$2"
    local endpoint

    is_loopback_probe_host "$host" || return 1
    command -v ss >/dev/null 2>&1 || return 1

    while IFS= read -r endpoint; do
        [[ -n "$endpoint" ]] || continue
        case "$endpoint" in
            127.*:"$port"|0.0.0.0:"$port"|\*:"$port"|"[::1]":"$port"|"[::]":"$port")
                return 0
                ;;
        esac
    done < <(ss -H -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print $4}')

    return 1
}

probe_tls_sni_certificate() {
    local label="$1"
    local host="$2"
    local port="$3"
    local sni="$4"
    local connect_target

    if ! command -v timeout >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ${label}: отсутствует timeout или openssl, проверка TLS/SNI пропущена.${PLAIN}"
        return 0
    fi

    connect_target=$(format_hostport "$host" "$port")
    if timeout 10 openssl s_client -connect "$connect_target" -servername "$sni" </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
        echo -e "${GREEN}✅ ${label}: ${connect_target} / SNI ${sni} вернул цепочку сертификатов${PLAIN}"
        return 0
    fi

    echo -e "${RED}❌ ${label}: ${connect_target} / SNI ${sni} не вернул цепочку сертификатов${PLAIN}"
    return 1
}

https_url_for_port() {
    local host="$1"
    local port="$2"
    local path="$3"
    if [[ "$port" == "443" ]]; then
        printf 'https://%s%s' "$host" "$path"
    else
        printf 'https://%s:%s%s' "$host" "$port" "$path"
    fi
}

curl_sni_path_probe() {
    local label="$1"
    local domain="$2"
    local port="$3"
    local path="$4"
    local url code curl_rc
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ${label}: curl не установлен, проверка HTTPS-пути пропущена.${PLAIN}"
        return 1
    fi
    url=$(https_url_for_port "$domain" "$port" "$path")
    code=$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 --resolve "${domain}:${port}:127.0.0.1" "$url" 2>/dev/null)
    curl_rc=$?
    if [[ "$curl_rc" -ne 0 || ! "$code" =~ ^[0-9]{3}$ || "$code" == "000" ]]; then
        echo -e "${RED}❌ ${label}: ${url} нет ответа или TLS/SNI не работает (curl exit ${curl_rc}, HTTP ${code:-000})${PLAIN}"
        return 1
    fi
    case "$code" in
        404)
            echo -e "${YELLOW}⚠️ ${label}: ${url} HTTP ${code}, 443/SNI достигнут, но путь или бэкенд могут не совпадать.${PLAIN}"
            return 0
            ;;
        *)
            echo -e "${GREEN}✅ ${label}: ${url} HTTP ${code}${PLAIN}"
            return 0
            ;;
    esac
}

tls_sni_probe_local() {
    local label="$1"
    local sni="$2"
    local port="$3"
    if ! command -v openssl >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ${label}: отсутствует openssl/timeout, проверка TLS SNI пропущена.${PLAIN}"
        return 1
    fi
    if timeout 10 openssl s_client -connect "127.0.0.1:${port}" -servername "$sni" </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
        echo -e "${GREEN}✅ ${label}: Nginx вход может попасть по SNI ${sni} на цепочку сертификатов${PLAIN}"
        return 0
    fi
    echo -e "${YELLOW}⚠️ ${label}: цепочка сертификатов не получена, проверьте Nginx stream, сертификаты Caddy или SNI.${PLAIN}"
    return 1
}

func_443_network_test() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Тесты скорости и качества > Проверка единого входа 443"
    echo -e "${BOLD}🧪 Сетевой тест единого входа 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    if [[ ! -f /etc/vps-optimize/sni-stack.env ]]; then
        echo -e "${YELLOW}Конфигурация единого входа 443 не обнаружена. Сначала выполните [19] -> [2] первичную настройку.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    load_sni_stack_env || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    echo -e "Вход панели: https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "Вход подписки: https://${PANEL_DOMAIN}${SUB_URI_PATH}"
    echo -e "Clash/Mihomo: https://${PANEL_DOMAIN}${CLASH_URI_PATH}"
    echo -e "REALITY SNI: ${REALITY_SNI}:${NGINX_LISTEN_PORT} -> ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
    echo -e "------------------------------------------------"

    check_domain_dns_sanity "$PANEL_DOMAIN" "Домен панели" "warn" || true
    [[ "$PANEL_DOMAIN" != "$REALITY_SNI" ]] && check_domain_dns_sanity "$REALITY_SNI" "REALITY SNI" "warn" || true

    echo -e "------------------------------------------------"
    tcp_probe_host "Публичный TCP вход" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" || true
    tcp_probe_host "Локальный Nginx вход" "127.0.0.1" "$NGINX_LISTEN_PORT" || true
    tcp_probe_host "$(web_proxy_engine_label) локальный TLS" "$(probe_host_for_listen_addr "$CADDY_LISTEN_ADDR")" "$CADDY_LISTEN_PORT" || true
    tcp_probe_host "Бэкенд панели 3x-ui" "$(probe_host_for_listen_addr "$PANEL_LISTEN_ADDR")" "$PANEL_LISTEN_PORT" || true
    tcp_probe_host "Бэкенд подписки 3x-ui" "$(probe_host_for_listen_addr "$SUB_LISTEN_ADDR")" "$SUB_LISTEN_PORT" || true
    tcp_probe_host "Локальный Xray/REALITY" "$(probe_host_for_listen_addr "$XRAY_LISTEN_ADDR")" "$XRAY_LISTEN_PORT" || true

    echo -e "------------------------------------------------"
    tls_sni_probe_local "TLS SNI панели" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" || true
    curl_sni_path_probe "Путь панели" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" "$PANEL_WEB_PATH" || true
    curl_sni_path_probe "Путь обычной подписки" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" "$SUB_URI_PATH" || true
    curl_sni_path_probe "Путь Clash/Mihomo" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" "$CLASH_URI_PATH" || true

    echo -e "------------------------------------------------"
    echo -e "${YELLOW}Пояснение: HTTP 401/403/302 обычно означает, что цепочка достигла бэкенда; 404 чаще всего — несовпадение пути или настроек подписки 3x-ui.${PLAIN}"
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_test_scripts() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}📊 Комплексный набор тестов скорости и качества VPS${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${GREEN}  1. YABS тест производительности ${YELLOW}  2. SuperBench комплексный${PLAIN}"
        echo -e "${GREEN}  3. bench.sh базовый тест      ${YELLOW}  4. FusionBench детальный${PLAIN}"
        echo -e "${GREEN}  5. Трассировка обратного пути  ${YELLOW}  6. Качество IP / мошенничество${PLAIN}"
        echo -e "${GREEN}  7. NodeSeek комплексный      ${YELLOW}  8. Проверка разблокировки стриминга${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        
        local t
        local ran_test=false
        read_trimmed t "👉 Введите соответствующий номер: "
        case $t in
            1) ran_test=true; run_remote_script "Запуск YABS теста производительности" "https://yabs.sh" ;;
            2) ran_test=true; run_remote_script "Запуск SuperBench комплексного теста" "https://about.superbench.pro" ;;
            3) ran_test=true; run_remote_script "Запуск bench.sh базового теста" "https://bench.sh" ;;
            4) ran_test=true; run_remote_script "Запуск FusionBench детального теста" "https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh" ;;
            5) ran_test=true; run_remote_script "Запуск трассировки обратного пути" "https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh" ;;
            6) ran_test=true; run_remote_script "Запуск проверки качества IP / мошенничества" "https://IP.Check.Place" ;;
            7) ran_test=true; run_remote_script "Запуск NodeSeek комплексного теста" "https://run.NodeQuality.com" ;;
            8) ran_test=true; run_remote_script "Запуск проверки разблокировки стриминга" "https://check.unlock.media" ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1; continue ;;
        esac
        echo ""
        if [[ "$ran_test" == "true" ]]; then
            pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню тестов..."
        fi
    done
}
# ---------------------------------------------------------
# 13, 14, 15 Быстрое развертывание панелей и dog
# ---------------------------------------------------------
func_port_dog() {
    clear
    echo -e "${CYAN}👉 Загрузка и выполнение инструмента мониторинга реального трафика портов...${PLAIN}"
    run_remote_script "Установка инструмента мониторинга реального трафика портов" "https://raw.githubusercontent.com/sacredx72/VPS-Optimize/main/dog.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

# ---------------------------------------------------------
# Module: panel_installers.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Быстрые установщики панелей, узлов, DNS разблокировки и IP Sentinel.

func_xpanel() {
    clear
    local version_choice install_url install_desc ssl_hint
    local -a install_args=()
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Установка 3x-ui / x-ui панели${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Пояснение по учётным данным: этот пункт запускает официальный установщик 3x-ui.${PLAIN}"
    echo -e "${YELLOW}Имя администратора, пароль и путь к панели обычно задаются интерактивно или выводятся в конце установки.${PLAIN}"
    echo -e "${YELLOW}Обратите внимание на вывод и сохраните данные; позже их можно изменить через официальное меню x-ui / 3x-ui.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${GREEN}  1. Установить последнюю версию${PLAIN}       ${YELLOW}(по умолчанию, master установщик)${PLAIN}"
    echo -e "${GREEN}  2. Установить v2.9.4${PLAIN}      ${YELLOW}(фиксированная версия, для машин, использующих туториалы по 2.9.4)${PLAIN}"
    echo -e "${RED}  0. Отмена${PLAIN}"
    echo -e "------------------------------------------------"
    read_trimmed version_choice "Выберите версию 3x-ui (по умолчанию 1): "
    case "$(echo "${version_choice:-1}" | tr '[:upper:]' '[:lower:]')" in
        1|latest|последняя)
            install_desc="Установка 3x-ui / x-ui панели (последняя)"
            install_url="https://raw.githubusercontent.com/AlexeyLCP/lucx-ui/main/install.sh"
            ssl_hint="Для новых установок 3.x, если установщик спрашивает о методе настройки SSL, выберите Skip SSL / не запрашивать SSL. Единый вход 443 будет обслуживать публичные сертификаты через Caddy + acme.sh."
            ;;
        2|2.9.4|v2.9.4)
            install_desc="Установка 3x-ui / x-ui панели (v2.9.4)"
            install_url="https://raw.githubusercontent.com/mhsanaei/3x-ui/v2.9.4/install.sh"
            install_args=("v2.9.4")
            ssl_hint="v2.9.4 — старый процесс 2.x: если в установщике или панели уже был настроен SSL, последующий мастер единого входа 443 продолжит очистку путей сертификатов панели/подписки по-старому."
            ;;
        0|q|Q)
            echo -e "${BLUE}Установка отменена.${PLAIN}"
            pause_after_external_script "Нажмите Enter для возврата в меню..."
            return
            ;;
        *)
            echo -e "${RED}❌ Неверный выбор, установка отменена.${PLAIN}"
            pause_after_external_script "Нажмите Enter для возврата в меню..."
            return
            ;;
    esac
    echo -e "${YELLOW}${ssl_hint}${PLAIN}"
    echo -e "${CYAN}👉 Загрузка официального установочного скрипта 3x-ui от mhsanaei...${PLAIN}"
    if run_remote_script "$install_desc" "$install_url" "${install_args[@]}"; then
        detect_xui_single_443_defaults
        print_xui_single_443_detected_defaults
    fi
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_xpanel_manage() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Управление / Удаление 3x-ui / x-ui${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: вход в официальное меню управления, просмотр конфигурации, управление учётными записями, обновление или удаление.${PLAIN}"
    echo -e "------------------------------------------------"

    local panel_cmd=""
    if command -v x-ui >/dev/null 2>&1; then
        panel_cmd="x-ui"
    elif command -v 3x-ui >/dev/null 2>&1; then
        panel_cmd="3x-ui"
    fi

    if [[ -z "$panel_cmd" ]]; then
        echo -e "${YELLOW}Команда x-ui / 3x-ui не обнаружена, возможно, панель ещё не установлена.${PLAIN}"
        local yn
        read_trimmed yn "Установить 3x-ui панель сейчас? (y/n): "
        if is_yes "$yn"; then
            func_xpanel
        else
            echo -e "${BLUE}Операция отменена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        fi
        return
    fi

    echo -e "${GREEN}Будет открыто официальное меню управления ${panel_cmd}.${PLAIN}"
    echo -e "${YELLOW}Для удаления выберите соответствующий пункт в официальном меню.${PLAIN}"
    echo -e "------------------------------------------------"
    "$panel_cmd"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_xui_custom_manager() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Расширенный набор x-ui${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: дополняет возможности, отсутствующие в панели 3x-ui, например кастомный сброс трафика, калибровка использованного трафика, бэкап/восстановление и проверка состояния.${PLAIN}"
    echo -e "${YELLOW}Подсказка: также можно ввести xcm в главном меню; внутри скрипта можно нажать ? для просмотра функционала.${PLAIN}"
    echo -e "${YELLOW}Рекомендация: перед изменением базы данных или восстановлением создайте снимок или сделайте бэкап данных x-ui через скрипт.${PLAIN}"
    echo -e "------------------------------------------------"
    run_remote_script "Запуск расширенного набора x-ui" "https://raw.githubusercontent.com/sacredx72/VPS-Optimize/main/xui-custom-manager.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_sui_panel() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Установка S-UI панели${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Пояснение по учётным данным: этот пункт запускает официальный установщик S-UI.${PLAIN}"
    echo -e "${YELLOW}Имя администратора, пароль и параметры доступа к панели задаются установщиком или выводятся в конце.${PLAIN}"
    echo -e "${YELLOW}Обратите внимание на вывод и сохраните данные; позже их можно изменить через официальное меню s-ui.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${CYAN}👉 Загрузка официального установочного скрипта S-UI от alireza0...${PLAIN}"
    run_remote_script "Установка S-UI панели" "https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_sui_manage() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Управление / Удаление S-UI${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: вход в официальное меню управления S-UI, просмотр конфигурации, управление учётными записями, обновление или удаление.${PLAIN}"
    echo -e "------------------------------------------------"

    if ! command -v s-ui >/dev/null 2>&1; then
        echo -e "${YELLOW}Команда s-ui не обнаружена, возможно, S-UI ещё не установлен.${PLAIN}"
        local yn
        read_trimmed yn "Установить S-UI сейчас? (y/n): "
        if is_yes "$yn"; then
            func_sui_panel
        else
            echo -e "${BLUE}Операция отменена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        fi
        return
    fi

    echo -e "${GREEN}Будет открыто официальное меню управления S-UI.${PLAIN}"
    echo -e "${YELLOW}Для удаления выберите соответствующий пункт в официальном меню.${PLAIN}"
    echo -e "------------------------------------------------"
    s-ui
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_singbox_233boy() {
    clear
    echo -e "${CYAN}👉 Загрузка скрипта 233boy для Sing-box...${PLAIN}"
    echo -e "${YELLOW}Источник: https://github.com/233boy/sing-box${PLAIN}"
    echo -e "${YELLOW}Документация: https://233boy.com/sing-box/sing-box-script/${PLAIN}"
    echo -e "${GREEN}После установки обычно можно использовать команду sing-box или sb для входа в меню управления.${PLAIN}"
    run_remote_script "Установка скрипта 233boy для Sing-box" "https://github.com/233boy/sing-box/raw/main/install.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_singbox_manage() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Управление / Удаление Sing-box${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: вход в меню управления установленного скрипта Sing-box.${PLAIN}"
    echo -e "------------------------------------------------"

    local sb_cmd=""
    if command -v sb >/dev/null 2>&1; then
        sb_cmd="sb"
    elif command -v sing-box >/dev/null 2>&1; then
        sb_cmd="sing-box"
    fi

    if [[ -z "$sb_cmd" ]]; then
        echo -e "${YELLOW}Команда sb / sing-box не обнаружена.${PLAIN}"
        echo -e "${BLUE}Если это первая установка, сначала выберите соответствующий пункт установки Sing-box.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "${GREEN}Будет открыто меню управления ${sb_cmd}.${PLAIN}"
    echo -e "${YELLOW}Для удаления выберите соответствующий пункт в меню скрипта.${PLAIN}"
    echo -e "------------------------------------------------"
    "$sb_cmd"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_xray_233boy() {
    clear
    echo -e "${CYAN}👉 Загрузка скрипта 233boy для Xray...${PLAIN}"
    echo -e "${YELLOW}Источник: https://github.com/233boy/Xray${PLAIN}"
    echo -e "${YELLOW}Документация: https://233boy.com/xray/xray-script/${PLAIN}"
    echo -e "${GREEN}После установки обычно можно использовать команду xray для входа в меню управления.${PLAIN}"
    run_remote_script "Установка скрипта 233boy для Xray" "https://github.com/233boy/Xray/raw/main/install.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_xray_manage() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Управление / Удаление Xray${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: вход в официальное меню управления 233boy Xray.${PLAIN}"
    echo -e "------------------------------------------------"

    if ! command -v xray >/dev/null 2>&1; then
        echo -e "${YELLOW}Команда xray не обнаружена, возможно, скрипт 233boy Xray ещё не установлен.${PLAIN}"
        local yn
        read_trimmed yn "Установить Xray сейчас? (y/n): "
        if is_yes "$yn"; then
            func_xray_233boy
        else
            echo -e "${BLUE}Операция отменена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        fi
        return
    fi

    echo -e "${GREEN}Будет открыто меню управления xray.${PLAIN}"
    echo -e "${YELLOW}Для удаления выберите соответствующий пункт в официальном меню.${PLAIN}"
    echo -e "------------------------------------------------"
    xray
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

# ---------------------------------------------------------
# 17. DNS разблокировка стриминга (Alice DNS)
# ---------------------------------------------------------
func_dns_unlock() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔓 DNS разблокировка стриминга (DNS-Alice-Unlock)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Описание и инструкция:${PLAIN}"
    echo -e " 1. Скрипт изменяет локальное DNS-разрешение для разблокировки Netflix, Disney+ и других региональных стримингов."
    echo -e " 2. ${GREEN}Маршрутизирует только домены стримингов${PLAIN}, не влияет на ваш реальный IP и обычную скорость интернета."
    echo -e " 3. Проект: ${BLUE}https://github.com/Jimmyzxk/DNS-Alice-Unlock/${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${RED}⚠️ Предупреждение: этот скрипт изменяет /etc/resolv.conf вашего сервера.${PLAIN}"
    echo -e "    Если вы не знаете, как самостоятельно настраивать DNS для разблокировки, обязательно изучите документацию проекта!"
    echo -e "------------------------------------------------"
    
    local yn
    read_trimmed yn "❓ Запустить скрипт разблокировки Alice DNS сейчас? (y/n): "
    if is_yes "$yn"; then
        run_remote_script "Запуск скрипта разблокировки Alice DNS" "https://raw.githubusercontent.com/Jimmyzxk/DNS-Alice-Unlock/refs/heads/main/dns-unlock.sh"
    else
        echo -e "${BLUE}Операция безопасно отменена.${PLAIN}"
    fi
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}
# ---------------------------------------------------------
# Новая функция: установка IP Sentinel (предотвращение смены локации IP)
# ---------------------------------------------------------
func_ip_sentinel() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🛡️ Установка IP Sentinel (предотвращение смены локации IP)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Этот скрипт будет постоянно контролировать и исправлять маршрутизацию, чтобы IP сервера не был ошибочно определён как китайский.${PLAIN}"
    echo -e "------------------------------------------------"
    
    read_trimmed yn "❓ Установить и настроить IP Sentinel (публичный шлюз)? (y/n): "
    if is_yes "$yn"; then
        run_remote_script "Установка и настройка IP Sentinel" "https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh"
    else
        echo -e "${BLUE}Операция отменена.${PLAIN}"
    fi
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

# ---------------------------------------------------------
# Новая функция: установка SublinkPro (мощная панель управления подписками)
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: compose_runtime.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Вспомогательные функции Docker Compose и управление проектами Compose.

install_docker_compose_standalone() {
    local compose_url tmp_file
    compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
    tmp_file=$(mktemp /tmp/docker-compose.XXXXXX) || { echo -e "${RED}❌ Не удалось создать временный файл.${PLAIN}"; return 1; }

    if ! download_remote_script "$compose_url" "$tmp_file"; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Не удалось загрузить Docker Compose, проверьте сеть или доступ к GitHub.${PLAIN}"
        return 1
    fi

    if [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Загруженный файл Docker Compose пуст, установка отменена.${PLAIN}"
        return 1
    fi

    if ! mv "$tmp_file" /usr/local/bin/docker-compose; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Не удалось записать Docker Compose в /usr/local/bin.${PLAIN}"
        return 1
    fi
    chmod +x /usr/local/bin/docker-compose || return 1
}

ensure_docker_engine_ready() {
    if command -v docker >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        return 0
    fi

    echo -e "${YELLOW}⚠️ Docker не обнаружен, автоматическая установка Docker Engine...${PLAIN}"
    if ! VPSO_REMOTE_SCRIPT_CONFIRM=0 run_remote_script "Установка Docker Engine" "https://get.docker.com"; then
        echo -e "${RED}❌ Автоматическая установка Docker не удалась, проверьте сеть или источники.${PLAIN}"
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker не доступен после установки, проверьте логи.${PLAIN}"
        return 1
    fi

    systemctl enable --now docker >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ Docker Engine установлен.${PLAIN}"
}

ensure_docker_compose_ready() {
    DOCKER_COMPOSE_CMD=""
    ensure_docker_engine_ready || return 1

    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo -e "${YELLOW}⚠️ Docker Compose плагин не обнаружен, установка...${PLAIN}"
        install_docker_compose_standalone || return 1
        DOCKER_COMPOSE_CMD="docker-compose"
        echo -e "${GREEN}✅ Docker Compose установлен.${PLAIN}"
    fi
}

find_compose_file() {
    local dir="$1"
    local file
    for file in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        if [[ -f "${dir}/${file}" ]]; then
            echo "${dir}/${file}"
            return 0
        fi
    done
    return 1
}

is_managed_compose_dir() {
    local dir="${1%/}"
    case "$dir" in
        /opt/sublinkpro|/opt/miaomiaowu|/opt/sub-store|/opt/dockge|/opt/komari)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

manage_compose_project() {
    local project_name="$1"
    local project_dir="${2%/}"
    local data_hint="$3"
    local compose_file choice yn

    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🧭 ${project_name} управление / удаление${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Каталог развёртывания: ${CYAN}${project_dir}${PLAIN}"
        echo -e "${YELLOW}Подсказка по данным: ${CYAN}${data_hint}${PLAIN}"
        echo -e "------------------------------------------------"

        if [[ ! -d "$project_dir" ]] || ! compose_file=$(find_compose_file "$project_dir"); then
            echo -e "${YELLOW}Развёртывание ${project_name} через Compose не обнаружено.${PLAIN}"
            echo -e "${BLUE}Сначала вернитесь в предыдущее меню и выберите соответствующий пункт установки.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi

        echo -e "${GREEN}  1. Просмотр состояния выполнения${PLAIN}"
        echo -e "${CYAN}  2. Просмотр/редактирование конфигурации Compose${PLAIN} ${YELLOW}(резервное копирование, проверка, up -d)${PLAIN}"
        echo -e "${GREEN}  3. Перезапуск службы${PLAIN}"
        echo -e "${GREEN}  4. Обновить образы и пересобрать${PLAIN}"
        echo -e "${YELLOW}  5. Остановить и удалить контейнеры (данные каталога сохраняются)${PLAIN}"
        echo -e "${RED}  6. Архивация каталога развёртывания (остановка контейнеров и изоляция конфигурации/данных)${PLAIN}"
        echo -e "${RED}  0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1)
                ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" ps)
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            2)
                edit_applied_config_file "$compose_file" "compose" "${project_name} конфигурация Compose"
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            3)
                ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" restart)
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            4)
                ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" pull && $DOCKER_COMPOSE_CMD -f "$compose_file" up -d)
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            5)
                if confirm_risk_action "Остановить и удалить контейнеры ${project_name}" \
                    "Состояние выполнения контейнеров Docker Compose" \
                    "Повторно выполните compose up -d в ${project_dir}, или вернитесь в меню управления и пересоберите" \
                    "Данные каталога сохраняются, но служба будет немедленно прервана."; then
                    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                    (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" down)
                    echo -e "${GREEN}✅ Контейнеры остановлены и удалены, каталог развёртывания сохранён: ${project_dir}${PLAIN}"
                else
                    echo -e "${BLUE}Операция отменена.${PLAIN}"
                fi
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            6)
                echo -e "${RED}⚠️ Высокий риск: контейнеры будут остановлены, а ${project_dir} перемещён в карантин — конфигурация, базы данных или локальные данные перестанут быть доступны на месте.${PLAIN}"
                echo -e "${YELLOW}После архивации для окончательной очистки подтвердите и вручную обработайте карантинный каталог.${PLAIN}"
                if confirm_risk_action "Архивация каталога развёртывания ${project_name}" \
                    "Контейнеры Docker Compose, каталог развёртывания, конфигурация и локальные данные" \
                    "Восстановите вручную из /opt/.vps-optimize-quarantine, вернув на исходный путь, затем перезапустите" \
                    "Убедитесь, что база данных и конфигурация зарезервированы, и служба может быть прервана."; then
                    if ! is_managed_compose_dir "$project_dir"; then
                        echo -e "${RED}❌ Проверка безопасности не пройдена, отказ в архивации не управляемого скриптом каталога: ${project_dir}${PLAIN}"
                    else
                        ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                        (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" down -v)
                        if quarantine_path "$project_dir" "/opt/.vps-optimize-quarantine"; then
                            echo -e "${GREEN}✅ Архивация ${project_name} выполнена.${PLAIN}"
                        else
                            echo -e "${RED}❌ Ошибка архивации, проверьте каталог вручную: ${project_dir}${PLAIN}"
                        fi
                    fi
                else
                    echo -e "${BLUE}Архивация отменена.${PLAIN}"
                fi
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            0|q|Q) return ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# Module: subscription_apps.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Установщики приложений подписок и управления.

generate_random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        echo "secret_$(date +%s)_$RANDOM$RANDOM"
    fi
}

print_public_https_reverse_proxy_hint() {
    echo -e "${YELLOW}Для публичного HTTPS-доступа: если единый вход 443 не включён, используйте главное меню [4 Обратный прокси] для Caddy или Nginx HTTPS прокси; если включён — главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси].${PLAIN}"
}

func_sublinkpro() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔗 Установка SublinkPro (панель управления подписками и конвертации)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    
    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    # Инициализация каталога развёртывания
    local install_dir="/opt/sublinkpro"
    local sublink_bind_addr="127.0.0.1"
    local sublink_port="8000"
    sublink_bind_addr=$(ask_with_default "Введите адрес прослушивания SublinkPro" "$sublink_bind_addr")
    is_valid_listen_addr "$sublink_bind_addr" || { echo -e "${RED}❌ Неверный адрес прослушивания.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    while true; do
        sublink_port=$(ask_with_default "Введите публичный порт SublinkPro" "$sublink_port")
        if is_valid_port "$sublink_port"; then
            break
        fi
        echo -e "${RED}❌ Неверный порт, введите 1-65535.${PLAIN}"
    done
    warn_if_public_bind "SublinkPro" "$sublink_bind_addr" "$sublink_port" || return 1

    echo -e "${YELLOW}💡 SublinkPro будет развёрнут в: ${CYAN}$install_dir${PLAIN}"
    echo -e "${YELLOW}💡 Адрес прослушивания SublinkPro: ${CYAN}${sublink_bind_addr}:${sublink_port}${PLAIN}"
    print_public_https_reverse_proxy_hint
    echo -e "${YELLOW}Пояснение по учётным данным: текущий процесс установки не позволяет задать пользовательские учётные данные.${PLAIN}"
    echo -e "${YELLOW}Учётные данные по умолчанию: ${CYAN}admin${PLAIN} / пароль: ${CYAN}123456${PLAIN}"
    echo -e "${YELLOW}После развёртывания обязательно войдите и смените пароль.${PLAIN}"
    echo -e "------------------------------------------------"
    
    read_trimmed yn "❓ Подтвердить установку? (y/n): "
    if is_yes "$yn"; then
        mkdir -p "$install_dir"
        cd "$install_dir" || return

        # Генерация docker-compose.yml
        cat <<EOF > docker-compose.yml
services:
  sublinkpro:
    image: zerodeng/sublink-pro
    container_name: sublinkpro
    ports:
      - "${sublink_bind_addr}:${sublink_port}:8000"
    volumes:
      - "./db:/app/db"
      - "./template:/app/template"
      - "./logs:/app/logs"
    restart: unless-stopped
EOF
        
        echo -e "${CYAN}▶ Загрузка образа и запуск контейнера SublinkPro...${PLAIN}"
        $DOCKER_COMPOSE_CMD up -d
        
        local access_host
        access_host="$sublink_bind_addr"
        [[ "$sublink_bind_addr" == "0.0.0.0" || "$sublink_bind_addr" == "::" ]] && access_host=$(curl -s4 --max-time 3 icanhazip.com 2>/dev/null || echo "IP вашего сервера")
        
        echo -e "------------------------------------------------"
        echo -e "${GREEN}🎉 SublinkPro развёрнут и запущен!${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "🌐 ${BOLD}Локальный адрес:${PLAIN} http://${access_host}:${sublink_port}"
        echo -e "👤 ${BOLD}Учётные данные по умолчанию:${PLAIN} admin"
        echo -e "🔑 ${BOLD}Пароль по умолчанию:${PLAIN} 123456"
        echo -e "${YELLOW}⚠️ Текущий процесс установки не позволяет задать пользовательские учётные данные, войдите и смените пароль.${PLAIN}"
        print_public_https_reverse_proxy_hint
        echo -e "------------------------------------------------"
        echo -e "${YELLOW}⚠️ Важное предупреждение:${PLAIN}"
        echo -e "База данных, шаблоны и логи сохраняются в ${CYAN}$install_dir${PLAIN}."
        echo -e "При обновлении контейнера или переустановке VPS обязательно сделайте резервную копию каталогов ${GREEN}./db${PLAIN} и ${GREEN}./template${PLAIN}!"
        echo -e "------------------------------------------------"
    else
        echo -e "${BLUE}Развёртывание безопасно отменено.${PLAIN}"
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_miaomiaowu() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Установка 妙妙屋 (подписки, Docker Compose)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    local install_dir="/opt/miaomiaowu"
    local mmw_bind_addr="127.0.0.1"
    local mmw_port="8080"
    local jwt_secret

    mmw_bind_addr=$(ask_with_default "Адрес прослушивания 妙妙屋" "$mmw_bind_addr")
    is_valid_listen_addr "$mmw_bind_addr" || { echo -e "${RED}❌ Неверный адрес прослушивания.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    while true; do
        mmw_port=$(ask_with_default "Введите публичный порт 妙妙屋" "$mmw_port")
        if is_valid_port "$mmw_port"; then
            break
        fi
        echo -e "${RED}❌ Неверный порт, введите 1-65535.${PLAIN}"
    done
    warn_if_public_bind "妙妙屋订阅管理" "$mmw_bind_addr" "$mmw_port" || return 1

    jwt_secret=$(ask_with_default "JWT_SECRET (Enter для автоматической генерации)" "")
    if [[ -z "$jwt_secret" ]]; then
        jwt_secret=$(generate_random_secret)
    fi

    echo -e "${YELLOW}Каталог развёртывания: ${CYAN}${install_dir}${PLAIN}"
    echo -e "${YELLOW}Адрес прослушивания: ${CYAN}${mmw_bind_addr}:${mmw_port}${PLAIN}"
    echo -e "${YELLOW}Каталоги данных: ${CYAN}${install_dir}/data, subscribes, rule_templates${PLAIN}"
    print_public_https_reverse_proxy_hint
    echo -e "${YELLOW}Не открывайте порты контейнера напрямую в интернет.${PLAIN}"
    echo -e "${YELLOW}Пояснение по учётным данным: текущий процесс установки не предусматривает предустановленных учётных данных.${PLAIN}"
    echo -e "${YELLOW}При первом открытии панели вы попадёте на страницу инициализации, где создадите учётные данные администратора.${PLAIN}"
    echo -e "------------------------------------------------"

    local yn
    read_trimmed yn "Подтвердить развёртывание 妙妙屋? (y/n): "
    if is_yes "$yn"; then
        mkdir -p "$install_dir"/{data,subscribes,rule_templates}
        cd "$install_dir" || return

        cat <<EOF > docker-compose.yml
version: '3.8'

services:
  miaomiaowu:
    image: ghcr.io/iluobei/miaomiaowu:latest
    container_name: miaomiaowu
    restart: unless-stopped
    user: root
    environment:
      PORT: "${mmw_port}"
      DATABASE_PATH: /app/data/traffic.db
      LOG_LEVEL: info
      JWT_SECRET: "${jwt_secret}"
    ports:
      - "${mmw_bind_addr}:${mmw_port}:${mmw_port}"
    volumes:
      - ./data:/app/data
      - ./subscribes:/app/subscribes
      - ./rule_templates:/app/rule_templates
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:${mmw_port}/"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
EOF

        echo -e "${CYAN}▶ Загрузка образа и запуск контейнера 妙妙屋...${PLAIN}"
        $DOCKER_COMPOSE_CMD up -d

        local access_host
        access_host="$mmw_bind_addr"
        [[ "$mmw_bind_addr" == "0.0.0.0" || "$mmw_bind_addr" == "::" ]] && access_host=$(curl -s4 --max-time 3 icanhazip.com 2>/dev/null || echo "IP вашего сервера")
        echo -e "------------------------------------------------"
        echo -e "${GREEN}✅ Развёртывание 妙妙屋 завершено!${PLAIN}"
        echo -e "Локальный адрес: ${BOLD}http://${access_host}:${mmw_port}${PLAIN}"
        echo -e "Учётные данные: ${YELLOW}нет предустановленных учётных данных, создайте администратора при первом открытии.${PLAIN}"
        echo -e "Файл конфигурации: ${CYAN}${install_dir}/docker-compose.yml${PLAIN}"
        print_public_https_reverse_proxy_hint
        echo -e "${YELLOW}Регулярно делайте резервные копии ${install_dir}/data, subscribes, rule_templates.${PLAIN}"
    else
        echo -e "${BLUE}Развёртывание безопасно отменено.${PLAIN}"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_substore() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Установка Sub-Store (Docker Compose / HTTP-META)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    local install_dir="/opt/sub-store"
    local backend_port="3001"
    local meta_port="9876"
    local backend_path="/$(generate_random_secret | cut -c1-48)"

    while true; do
        backend_port=$(ask_with_default "Порт API бэкенда Sub-Store" "$backend_port")
        if is_valid_port "$backend_port"; then break; fi
        echo -e "${RED}❌ Неверный порт, введите 1-65535.${PLAIN}"
    done

    while true; do
        meta_port=$(ask_with_default "Локальный порт HTTP-META" "$meta_port")
        if is_valid_port "$meta_port"; then break; fi
        echo -e "${RED}❌ Неверный порт, введите 1-65535.${PLAIN}"
    done

    backend_path=$(ask_with_default "Путь к бэкенду для фронтенда (рекомендуется оставить случайный)" "$backend_path")
    if [[ "$backend_path" != /* ]]; then
        backend_path="/${backend_path}"
    fi

    echo -e "${YELLOW}Каталог развёртывания: ${CYAN}${install_dir}${PLAIN}"
    echo -e "${YELLOW}Бэкенд Sub-Store: ${CYAN}127.0.0.1:${backend_port}${PLAIN}"
    echo -e "${YELLOW}HTTP-META: ${CYAN}127.0.0.1:${meta_port}${PLAIN}"
    echo -e "${YELLOW}Путь бэкенда для фронтенда: ${CYAN}${backend_path}${PLAIN}"
    echo -e "${YELLOW}По умолчанию используется host-сеть и привязка к 127.0.0.1.${PLAIN}"
    print_public_https_reverse_proxy_hint
    echo -e "${YELLOW}Пояснение по учётным данным: Sub-Store не использует учётные данные для входа.${PLAIN}"
    echo -e "${YELLOW}Сохраните случайный путь бэкенда; если открываете наружу, добавьте аутентификацию на уровне прокси.${PLAIN}"
    echo -e "------------------------------------------------"

    local yn
    read_trimmed yn "Подтвердить развёртывание Sub-Store? (y/n): "
    if is_yes "$yn"; then
        mkdir -p "$install_dir/data"
        cd "$install_dir" || return

        cat <<EOF > docker-compose.yml
version: '3.8'

services:
  sub-store:
    image: xream/sub-store:http-meta
    container_name: sub-store
    restart: always
    network_mode: host
    environment:
      SUB_STORE_BACKEND_API_HOST: "127.0.0.1"
      SUB_STORE_BACKEND_API_PORT: "${backend_port}"
      SUB_STORE_BACKEND_MERGE: "true"
      SUB_STORE_FRONTEND_BACKEND_PATH: "${backend_path}"
      PORT: "${meta_port}"
      HOST: "127.0.0.1"
    volumes:
      - ./data:/opt/app/data
EOF

        echo -e "${CYAN}▶ Загрузка образа и запуск контейнера Sub-Store...${PLAIN}"
        $DOCKER_COMPOSE_CMD up -d

        echo -e "------------------------------------------------"
        echo -e "${GREEN}✅ Развёртывание Sub-Store завершено!${PLAIN}"
        echo -e "Локальный бэкенд: ${BOLD}http://127.0.0.1:${backend_port}${backend_path}${PLAIN}"
        echo -e "HTTP-META: ${BOLD}http://127.0.0.1:${meta_port}${PLAIN}"
        echo -e "Учётные данные: ${YELLOW}нет учётных данных, сохраните случайный путь бэкенда.${PLAIN}"
        echo -e "Файл конфигурации: ${CYAN}${install_dir}/docker-compose.yml${PLAIN}"
        print_public_https_reverse_proxy_hint
        echo -e "${YELLOW}Регулярно делайте резервные копии ${install_dir}/data.${PLAIN}"
    else
        echo -e "${BLUE}Развёртывание безопасно отменено.${PLAIN}"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_dockge() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Установка Dockge (панель управления Docker Compose)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Dockge используется для управления стеками compose, позволяет создавать, редактировать, запускать, останавливать, перезапускать и обновлять образы.${PLAIN}"
    echo -e "${YELLOW}Внимание: Dockge монтирует Docker-сокет, рекомендуется слушать только локальный адрес и открывать доступ через Caddy/Nginx.${PLAIN}"
    echo -e "------------------------------------------------"

    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    local install_dir="/opt/dockge"
    local stacks_dir="/opt/stacks"
    local dockge_bind_addr="127.0.0.1"
    local dockge_port="5001"

    dockge_bind_addr=$(ask_with_default "Адрес прослушивания Dockge" "$dockge_bind_addr")
    is_valid_listen_addr "$dockge_bind_addr" || { echo -e "${RED}❌ Неверный адрес прослушивания.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    while true; do
        dockge_port=$(ask_with_default "Порт доступа Dockge" "$dockge_port")
        if is_valid_port "$dockge_port"; then break; fi
        echo -e "${RED}❌ Неверный порт, введите 1-65535.${PLAIN}"
    done
    warn_if_public_bind "Панель управления Dockge" "$dockge_bind_addr" "$dockge_port" || return 1
    stacks_dir=$(ask_with_default "Каталог stacks Dockge" "$stacks_dir")

    echo -e "${YELLOW}Каталог Dockge: ${CYAN}${install_dir}${PLAIN}"
    echo -e "${YELLOW}Каталог Stacks: ${CYAN}${stacks_dir}${PLAIN}"
    echo -e "${YELLOW}Адрес прослушивания: ${CYAN}${dockge_bind_addr}:${dockge_port}${PLAIN}"
    echo -e "${YELLOW}Пояснение по учётным данным: Dockge не имеет предустановленных учётных данных.${PLAIN}"
    echo -e "${YELLOW}При первом открытии вы попадёте на страницу инициализации, где создадите учётные данные администратора.${PLAIN}"
    echo -e "------------------------------------------------"

    local yn
    read_trimmed yn "Подтвердить развёртывание Dockge? (y/n): "
    if is_yes "$yn"; then
        mkdir -p "$install_dir" "$stacks_dir"
        cd "$install_dir" || return

        cat <<EOF > compose.yaml
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped
    ports:
      - "${dockge_bind_addr}:${dockge_port}:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/app/data
      - ${stacks_dir}:${stacks_dir}
    environment:
      DOCKGE_STACKS_DIR: "${stacks_dir}"
EOF

        echo -e "${CYAN}▶ Загрузка образа и запуск Dockge...${PLAIN}"
        $DOCKER_COMPOSE_CMD up -d

        echo -e "------------------------------------------------"
        echo -e "${GREEN}✅ Развёртывание Dockge завершено!${PLAIN}"
        echo -e "Адрес доступа: ${BOLD}http://${dockge_bind_addr}:${dockge_port}${PLAIN}"
        echo -e "Каталог Stacks: ${CYAN}${stacks_dir}${PLAIN}"
        echo -e "Учётные данные: ${YELLOW}нет предустановленных учётных данных, создайте администратора при первом открытии.${PLAIN}"
        echo -e "${YELLOW}Существующие проекты Compose можно перенести в Dockge через [10] в меню развёртывания, затем сканировать каталог stacks в Dockge.${PLAIN}"
    else
        echo -e "${BLUE}Развёртывание безопасно отменено.${PLAIN}"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_komari() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Установка панели мониторинга Komari (Docker Compose)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Komari предназначен для мониторинга серверов. По умолчанию слушает только локальный адрес.${PLAIN}"
    print_public_https_reverse_proxy_hint
    echo -e "${YELLOW}Если агентам нужен прямой доступ к порту, измените адрес прослушивания на 0.0.0.0 и убедитесь, что безопасная группа разрешает порт.${PLAIN}"
    echo -e "------------------------------------------------"

    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    local install_dir="/opt/komari"
    local komari_bind_addr="127.0.0.1"
    local komari_port="25774"
    local custom_admin="n"
    local admin_username=""
    local admin_password=""
    local yn

    komari_bind_addr=$(ask_with_default "Адрес прослушивания Komari" "$komari_bind_addr")
    is_valid_listen_addr "$komari_bind_addr" || { echo -e "${RED}❌ Неверный адрес прослушивания.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    while true; do
        komari_port=$(ask_with_default "Порт доступа Komari" "$komari_port")
        if is_valid_port "$komari_port"; then break; fi
        echo -e "${RED}❌ Неверный порт, введите 1-65535.${PLAIN}"
    done
    warn_if_public_bind "Панель мониторинга Komari" "$komari_bind_addr" "$komari_port" || return 1

    read_trimmed custom_admin "Задать собственные учётные данные администратора? (y/n, по умолчанию n): "
    if is_yes "$custom_admin"; then
        while true; do
            read_trimmed admin_username "Имя администратора (по умолчанию admin): "
            admin_username="${admin_username:-admin}"
            if [[ "$admin_username" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then
                break
            fi
            echo -e "${RED}❌ Имя может содержать только буквы, цифры, точки, подчёркивания и дефисы, длина 3-32.${PLAIN}"
        done

        while true; do
            read_secret_trimmed admin_password "Пароль администратора (не менее 8 символов, Enter для автоматической генерации): "
            if [[ -z "$admin_password" ]]; then
                admin_password=$(generate_random_secret | cut -c1-24)
                echo -e "${YELLOW}Сгенерирован автоматический пароль администратора, сохраните его.${PLAIN}"
                break
            fi
            if [[ ${#admin_password} -ge 8 ]]; then
                break
            fi
            echo -e "${RED}❌ Пароль должен быть не менее 8 символов.${PLAIN}"
        done
    fi

    echo -e "${YELLOW}Каталог развёртывания: ${CYAN}${install_dir}${PLAIN}"
    echo -e "${YELLOW}Каталог данных: ${CYAN}${install_dir}/data${PLAIN}"
    echo -e "${YELLOW}Адрес прослушивания: ${CYAN}${komari_bind_addr}:${komari_port}${PLAIN}"
    if [[ -n "$admin_username" ]]; then
        echo -e "${YELLOW}Начальный администратор: ${CYAN}${admin_username}${PLAIN}"
    else
        echo -e "${YELLOW}Пояснение по учётным данным: без кастомизации Komari сгенерирует учётные данные по умолчанию.${PLAIN}"
        echo -e "${YELLOW}Начальный администратор: ${CYAN}используйте учётные данные, сгенерированные Komari; проверьте логи контейнера после установки${PLAIN}"
    fi
    echo -e "------------------------------------------------"
    read_trimmed yn "Подтвердить развёртывание Komari? (y/n): "
    if is_yes "$yn"; then
        mkdir -p "$install_dir/data"
        cd "$install_dir" || return

        cat <<EOF > docker-compose.yml
version: '3.8'
services:
  komari:
    image: ghcr.io/komari-monitor/komari:latest
    container_name: komari
    ports:
      - "${komari_bind_addr}:${komari_port}:25774"
    volumes:
      - ./data:/app/data
    environment:
EOF

        if [[ -n "$admin_username" ]]; then
            cat <<EOF >> docker-compose.yml
      ADMIN_USERNAME: "${admin_username}"
      ADMIN_PASSWORD: "${admin_password}"
EOF
        else
            cat <<'EOF' >> docker-compose.yml
      # Опционально: для задания учётных данных администратора остановите контейнер, раскомментируйте и укажите.
      # ADMIN_USERNAME: admin
      # ADMIN_PASSWORD: yourpassword
EOF
        fi

        cat <<EOF >> docker-compose.yml
    restart: unless-stopped
EOF

        echo -e "${CYAN}▶ Загрузка образа и запуск Komari...${PLAIN}"
        $DOCKER_COMPOSE_CMD up -d

        echo -e "------------------------------------------------"
        echo -e "${GREEN}✅ Развёртывание Komari завершено!${PLAIN}"
        echo -e "Адрес доступа: ${BOLD}http://${komari_bind_addr}:${komari_port}${PLAIN}"
        echo -e "Файл конфигурации: ${CYAN}${install_dir}/docker-compose.yml${PLAIN}"
        if [[ -n "$admin_username" ]]; then
            echo -e "Администратор: ${BOLD}${admin_username}${PLAIN}"
            echo -e "Пароль: ${BOLD}${admin_password}${PLAIN}"
            echo -e "${YELLOW}Сохраните пароль, позже его можно изменить в ${install_dir}/docker-compose.yml.${PLAIN}"
        else
            echo -e "${YELLOW}Учётные данные администратора по умолчанию: ${CYAN}$DOCKER_COMPOSE_CMD logs komari${PLAIN}"
        fi
        print_public_https_reverse_proxy_hint
    else
        echo -e "${BLUE}Развёртывание безопасно отменено.${PLAIN}"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

# ---------------------------------------------------------
# Module: subscription_compose_manage.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Управление обновлением подписочных инструментов.

update_compose_project() {
    local name="$1"
    local dir="$2"

    if [[ ! -d "$dir" || ! -f "$dir/docker-compose.yml" ]]; then
        echo -e "${YELLOW}⚠️ Конфигурация Compose для ${name} не найдена: ${dir}/docker-compose.yml, пропуск.${PLAIN}"
        return 1
    fi

    echo -e "${CYAN}▶ Обновление ${name}...${PLAIN}"
    (
        cd "$dir" || exit 1
        $DOCKER_COMPOSE_CMD pull
        $DOCKER_COMPOSE_CMD up -d
    )
}

func_update_subscription_tools() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}${YELLOW}UPD Обновление инструментов подписок (Docker Compose)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Это меню обновляет только контейнеры инструментов подписок, не обновляет 3x-ui / Sing-box / Xray.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${BOLD}${YELLOW}  1. UPD Обновить SublinkPro${PLAIN}       ${CYAN}(/opt/sublinkpro)${PLAIN}"
    echo -e "${BOLD}${YELLOW}  2. UPD Обновить 妙妙屋${PLAIN}     ${CYAN}(/opt/miaomiaowu)${PLAIN}"
    echo -e "${BOLD}${YELLOW}  3. UPD Обновить Sub-Store${PLAIN}        ${CYAN}(/opt/sub-store)${PLAIN}"
    echo -e "${BOLD}${YELLOW}  4. UPD Обновить всё${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${RED}  0. Вернуться / q${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local choice
    read_trimmed choice "Выберите проект для обновления: "
    [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" ]] && return

    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    case "$choice" in
        1) update_compose_project "SublinkPro" "/opt/sublinkpro" ;;
        2) update_compose_project "妙妙屋" "/opt/miaomiaowu" ;;
        3) update_compose_project "Sub-Store" "/opt/sub-store" ;;
        4)
            update_compose_project "SublinkPro" "/opt/sublinkpro" || true
            update_compose_project "妙妙屋" "/opt/miaomiaowu" || true
            update_compose_project "Sub-Store" "/opt/sub-store" || true
            ;;
        *)
            echo -e "${RED}❌ Неверный выбор!${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
            ;;
    esac

    echo -e "------------------------------------------------"
    echo -e "${GREEN}✅ Процесс обновления выполнен.${PLAIN}"
    local prune_confirm
    read_trimmed prune_confirm "Очистить непомеченные старые образы для освобождения места? (y/n, по умолчанию n): "
    if is_yes "$prune_confirm"; then
        docker image prune -f
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

# ---------------------------------------------------------
# Module: subscription_service_menus.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Меню действий для панелей, узлов, подписок и Compose-сервисов.

func_manage_sublinkpro() {
    manage_compose_project "SublinkPro" "/opt/sublinkpro" "db / template / logs сохраняются в каталоге развёртывания"
}

func_manage_miaomiaowu() {
    manage_compose_project "妙妙屋" "/opt/miaomiaowu" "data / subscribes / rule_templates сохраняются в каталоге развёртывания"
}

func_manage_substore() {
    manage_compose_project "Sub-Store" "/opt/sub-store" "data сохраняется в каталоге развёртывания"
}

func_manage_dockge() {
    manage_compose_project "Dockge" "/opt/dockge" "Данные Dockge в /opt/dockge/data; Stacks по умолчанию в /opt/stacks, не удаляются при удалении Dockge"
}

func_manage_komari() {
    manage_compose_project "Komari" "/opt/komari" "Данные Komari сохраняются в /opt/komari/data"
}

func_service_action_menu() {
    local title="$1"
    local usage="$2"
    local install_label="$3"
    local install_func="$4"
    local manage_label="$5"
    local manage_func="$6"
    local choice

    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Панели, узлы и подписки > ${title}"
        echo -e "${BOLD}🧭 ${title}${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}${usage}${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. ${install_label}${PLAIN}"
        echo -e "${GREEN}  2. ${manage_label}${PLAIN}"
        echo -e "${RED}  0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        read_trimmed choice "👉 Выберите действие: "

        case "$choice" in
            1) "$install_func" ;;
            2) "$manage_func" ;;
            0|q|Q) return ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

func_xpanel_menu() {
    func_service_action_menu "3x-ui / x-ui панель" "Установка или вход в официальное меню для настройки, обновления, сброса, удаления." "Установка 3x-ui панели" func_xpanel "Управление / удаление 3x-ui панели" func_xpanel_manage
}

func_sui_menu() {
    func_service_action_menu "S-UI панель" "Установка или вход в официальное меню S-UI для настройки, обновления, удаления." "Установка S-UI панели" func_sui_panel "Управление / удаление S-UI панели" func_sui_manage
}

func_singbox_menu() {
    local choice

    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🧭 Управление Sing-box${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Можно установить скрипт Sing-box, а также войти в меню управления уже установленного скрипта.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Установка Sing-box (скрипт 233boy)${PLAIN}"
        echo -e "${GREEN}  2. Управление / удаление Sing-box${PLAIN}"
        echo -e "${RED}  0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        read_trimmed choice "👉 Выберите действие: "

        case "$choice" in
            1) func_singbox_233boy ;;
            2) func_singbox_manage ;;
            0|q|Q) return ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

func_xray_menu() {
    func_service_action_menu "Управление Xray" "Установка или вход в официальное меню 233boy Xray для настройки, обновления, удаления." "Установка Xray (скрипт 233boy)" func_xray_233boy "Управление / удаление Xray" func_xray_manage
}

func_sublinkpro_menu() {
    func_service_action_menu "Управление SublinkPro" "Установка или управление Docker Compose развёртыванием SublinkPro." "Установка SublinkPro" func_sublinkpro "Управление / удаление SublinkPro" func_manage_sublinkpro
}

func_miaomiaowu_menu() {
    func_service_action_menu "Управление 妙妙屋" "Установка или управление Docker Compose развёртыванием 妙妙屋." "Установка 妙妙屋" func_miaomiaowu "Управление / удаление 妙妙屋" func_manage_miaomiaowu
}

func_substore_menu() {
    func_service_action_menu "Управление Sub-Store" "Установка или управление Docker Compose развёртыванием Sub-Store." "Установка Sub-Store" func_substore "Управление / удаление Sub-Store" func_manage_substore
}

func_dockge_menu() {
    func_service_action_menu "Управление Dockge" "Установка или управление Docker Compose развёртыванием Dockge." "Установка Dockge" func_dockge "Управление / удаление Dockge" func_manage_dockge
}

func_komari_menu() {
    func_service_action_menu "Управление Komari" "Установка или управление Docker Compose развёртыванием панели мониторинга Komari." "Установка Komari" func_komari "Управление / удаление Komari" func_manage_komari
}

# ---------------------------------------------------------
# Module: dockge_migration.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Обнаружение и миграция проектов в Dockge.

is_dockge_migration_seen() {
    local needle="$1"
    local item
    for item in "${DOCKGE_MIGRATION_DIRS[@]}"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

add_dockge_migration_candidate() {
    local dir="$1"
    local stacks_dir="$2"
    local name

    dir="${dir%/}"
    [[ -d "$dir" ]] || return 0
    [[ "$dir" == "/opt/dockge" ]] && return 0
    [[ "$dir" == "$stacks_dir" || "$dir" == "$stacks_dir"/* ]] && return 0
    find_compose_file "$dir" >/dev/null 2>&1 || return 0
    is_dockge_migration_seen "$dir" && return 0

    name=$(basename "$dir")
    DOCKGE_MIGRATION_NAMES+=("$name")
    DOCKGE_MIGRATION_DIRS+=("$dir")
}

discover_dockge_migration_candidates() {
    local stacks_dir="$1"
    local dir file
    DOCKGE_MIGRATION_NAMES=()
    DOCKGE_MIGRATION_DIRS=()

    for dir in /opt/sublinkpro /opt/miaomiaowu /opt/sub-store; do
        add_dockge_migration_candidate "$dir" "$stacks_dir"
    done

    for file in /opt/*/compose.yaml /opt/*/compose.yml /opt/*/docker-compose.yml /opt/*/docker-compose.yaml; do
        [[ -e "$file" ]] || continue
        add_dockge_migration_candidate "$(dirname "$file")" "$stacks_dir"
    done
}

migrate_compose_project_to_dockge() {
    local source_dir="$1"
    local stacks_dir="$2"
    local source_compose stack_name target_dir compose_name restart_confirm
    local restart_stack="true"

    source_dir="${source_dir%/}"
    source_compose=$(find_compose_file "$source_dir") || {
        echo -e "${RED}❌ Конфигурация Compose не найдена: ${source_dir}${PLAIN}"
        return 1
    }

    stack_name=$(ask_with_default "Имя стека Dockge" "$(basename "$source_dir")")
    if [[ ! "$stack_name" =~ ^[A-Za-z0-9_.-]+$ || "$stack_name" == "." || "$stack_name" == ".." ]]; then
        echo -e "${RED}❌ Неверное имя стека, разрешены только буквы, цифры, точки, подчёркивания и дефисы.${PLAIN}"
        return 1
    fi

    target_dir="${stacks_dir%/}/${stack_name}"
    if [[ "$source_dir" == "$target_dir" ]]; then
        echo -e "${YELLOW}⚠️ ${source_dir} уже находится в каталоге stacks Dockge, пропуск.${PLAIN}"
        return 0
    fi
    if [[ -e "$target_dir" ]]; then
        echo -e "${RED}❌ Целевой каталог уже существует: ${target_dir}${PLAIN}"
        echo -e "${YELLOW}Проверьте, есть ли уже такой стек в Dockge, или выберите другое имя.${PLAIN}"
        return 1
    fi

    echo -e "------------------------------------------------"
    echo -e "${YELLOW}Будет перенесён: ${CYAN}${source_dir}${PLAIN}"
    echo -e "${YELLOW}В: ${CYAN}${target_dir}${PLAIN}"
    echo -e "${YELLOW}Compose: ${CYAN}${source_compose}${PLAIN}"
    echo -e "${YELLOW}Пояснение: весь каталог проекта будет перемещён, относительные смонтированные каталоги данных сохранятся.${PLAIN}"
    echo -e "${YELLOW}Если проект использует именованные тома Docker, рекомендуется оставить имя стека таким же, как исходный каталог.${PLAIN}"
    confirm_risk_action "Миграция Compose-проекта в Dockge" \
        "Каталог Compose-проекта, остановка/запуск контейнеров и путь стека Dockge" \
        "Вручную переместите ${target_dir} обратно в ${source_dir} и перезапустите с исходным compose-файлом" \
        "Убедитесь, что проект не использует абсолютные пути, и важные данные зарезервированы." || { echo -e "${BLUE}Миграция ${source_dir} отменена.${PLAIN}"; return 0; }

    read_trimmed restart_confirm "Сначала остановить старые контейнеры и перезапустить в новом каталоге? (Y/n): "
    if is_no "$restart_confirm"; then
        restart_stack="false"
    fi

    if [[ "$restart_stack" == "true" ]]; then
        echo -e "${CYAN}▶ Остановка Compose-проекта в старом каталоге...${PLAIN}"
        ( cd "$source_dir" && $DOCKER_COMPOSE_CMD down ) || {
            echo -e "${RED}❌ Остановка старого проекта не удалась, миграция прервана.${PLAIN}"
            return 1
        }
    fi

    mkdir -p "$stacks_dir" || return 1
    mv "$source_dir" "$target_dir" || {
        echo -e "${RED}❌ Перемещение каталога не удалось: ${source_dir} -> ${target_dir}${PLAIN}"
        return 1
    }

    compose_name=$(basename "$source_compose")
    if [[ "$compose_name" == docker-compose.y* && ! -f "${target_dir}/compose.yaml" ]]; then
        mv "${target_dir}/${compose_name}" "${target_dir}/compose.yaml" || {
            echo -e "${RED}❌ Переименование файла Compose не удалось, проверьте вручную: ${target_dir}${PLAIN}"
            return 1
        }
    fi

    if [[ "$restart_stack" == "true" ]]; then
        echo -e "${CYAN}▶ Перезапуск Compose-проекта в новом каталоге...${PLAIN}"
        ( cd "$target_dir" && $DOCKER_COMPOSE_CMD up -d ) || {
            echo -e "${RED}❌ Запуск в новом каталоге не удался, проверьте вручную: ${target_dir}${PLAIN}"
            return 1
        }
    fi

    echo -e "${GREEN}✅ Проект перенесён в стеки Dockge: ${target_dir}${PLAIN}"
    echo -e "${YELLOW}Обновите/отсканируйте каталог stacks в интерфейсе Dockge для управления.${PLAIN}"
}

func_migrate_compose_to_dockge() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Перенос существующих Compose-проектов в Dockge${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Подходит для случая, когда Dockge установлен позже: переносит существующие проекты docker-compose.yml / compose.yaml в каталог stacks Dockge.${PLAIN}"
    echo -e "${YELLOW}Рекомендуется убедиться, что службы могут быть ненадолго остановлены, и сделана резервная копия важных данных.${PLAIN}"
    echo -e "------------------------------------------------"

    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    local stacks_dir="/opt/stacks"
    local choice custom_dir i
    stacks_dir=$(ask_with_default "Каталог stacks Dockge" "$stacks_dir")
    mkdir -p "$stacks_dir" || { echo -e "${RED}❌ Не удалось создать каталог stacks: ${stacks_dir}${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    discover_dockge_migration_candidates "$stacks_dir"

    if [[ "${#DOCKGE_MIGRATION_DIRS[@]}" -gt 0 ]]; then
        echo -e "${GREEN}Обнаружены следующие проекты Compose для переноса:${PLAIN}"
        for i in "${!DOCKGE_MIGRATION_DIRS[@]}"; do
            echo -e "${GREEN}  $((i + 1)). ${DOCKGE_MIGRATION_NAMES[$i]}${PLAIN} ${CYAN}(${DOCKGE_MIGRATION_DIRS[$i]})${PLAIN}"
        done
        echo -e "${BOLD}${YELLOW}  a. Перенести все обнаруженные проекты${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ Не обнаружено обычных Compose-проектов в /opt.${PLAIN}"
    fi
    echo -e "${CYAN}  c. Ввести каталог проекта вручную${PLAIN}"
    echo -e "${RED}  0. Вернуться${PLAIN}"
    echo -e "------------------------------------------------"

    read_trimmed choice "Выберите проект для переноса: "
    case "$choice" in
        0) return ;;
        a|A)
            if [[ "${#DOCKGE_MIGRATION_DIRS[@]}" -eq 0 ]]; then
                echo -e "${YELLOW}⚠️ Нет проектов для автоматического переноса.${PLAIN}"
            else
                for i in "${!DOCKGE_MIGRATION_DIRS[@]}"; do
                    migrate_compose_project_to_dockge "${DOCKGE_MIGRATION_DIRS[$i]}" "$stacks_dir" || true
                    echo -e "------------------------------------------------"
                done
            fi
            ;;
        c|C)
            read_trimmed custom_dir "Введите каталог существующего Compose-проекта: "
            migrate_compose_project_to_dockge "$custom_dir" "$stacks_dir"
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DOCKGE_MIGRATION_DIRS[@]} )); then
                migrate_compose_project_to_dockge "${DOCKGE_MIGRATION_DIRS[$((choice - 1))]}" "$stacks_dir"
            else
                echo -e "${RED}❌ Неверный выбор!${PLAIN}"
            fi
            ;;
    esac

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}
# ---------------------------------------------------------
# 18. Восстановление панели / сброс SSL (совместимость с новыми 3x-ui)
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: panel_rescue.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Восстановление панели и сброс SSL.

func_rescue_panel() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🚑 Восстановление SSL панели${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: очистить пути сертификатов 3x-ui, чтобы Caddy мог проксировать панель по HTTP.${PLAIN}"
    echo -e "Рекомендуется вручную в панели 3x-ui: Настройки панели -> Общие -> Сертификаты, очистить пути и перезапустить."
    echo -e "Эта функция предназначена как аварийное решение, если панель не открывается; попытается очистить распространённые поля: webCertFile/webKeyFile/CertFile/KeyFile и т.д."
    echo -e "------------------------------------------------"
    
    local yn
    read_trimmed yn "❓ Очистить пути сертификатов панели и попытаться вернуться к HTTP? (y/n): "
    if is_yes "$yn"; then
        local xui_bin
        xui_bin=$(detect_xui_command 2>/dev/null || true)
        if [[ -n "$xui_bin" ]]; then
            echo -e "${CYAN}Текущее состояние сертификатов 3x-ui:${PLAIN}"
            "$xui_bin" setting -getCert true 2>/dev/null || true
            echo -e "------------------------------------------------"
        fi
        clear_xui_cert_settings_for_single_443 || true
        echo -e "------------------------------------------------"
        if [[ -n "$xui_bin" ]]; then
            echo -e "${CYAN}Состояние сертификатов 3x-ui после очистки:${PLAIN}"
            "$xui_bin" setting -getCert true 2>/dev/null || true
            echo -e "------------------------------------------------"
        fi
        echo -e "${GREEN}✅ Попытка очистки путей сертификатов выполнена.${PLAIN}"
        echo -e "${YELLOW}Проверьте локально: curl -I http://127.0.0.1:порт_панели/путь_панели/${PLAIN}"
        echo -e "${YELLOW}Если HTTP всё ещё не работает, войдите в официальное меню 3x-ui или настройки панели и убедитесь, что пути сертификатов и подписок очищены, затем перезапустите панель.${PLAIN}"
    else
        echo -e "${BLUE}Операция отменена.${PLAIN}"
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}
# ---------------------------------------------------------
# Новая функция: визуальное отображение занятости портов и завершение процессов
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: server_maintenance.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Освобождение портов и перезагрузка сервера.

func_port_kill() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🔍 Проверка занятости портов и освобождение процессов${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Список активных прослушиваемых портов:${PLAIN}"
        echo -e "------------------------------------------------"
        printf "%-10s %-15s %-20s\n" "Протокол" "Порт" "Процесс (PID)"
        
        ss -tulnp | grep -E 'LISTEN|UNCONN' | while read -r line; do
            local proto=$(echo "$line" | awk '{print $1}')
            local port=$(echo "$line" | awk '{print $5}' | awk -F: '{print $NF}')
            local pid=$(echo "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
            local proc=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
            
            local proc_info=""
            if [[ -z "$proc" || -z "$pid" ]]; then
                proc_info="Системный / нет прав"
            else
                proc_info="$proc (PID: $pid)"
            fi
            printf "%-10s %-15s %-20s\n" "$proto" "$port" "$proc_info"
        done | sort -n -k2 | uniq
        
        echo -e "------------------------------------------------"
        echo -e "${GREEN}👉 Найдите конфликтующий порт и введите его для принудительного завершения процесса.${PLAIN}"
        echo -e "${RED}⚠️ Не завершайте процесс sshd (обычно порт 22), иначе потеряете связь!${PLAIN}"
        echo -e "------------------------------------------------"
        
        local p_choice
        read_trimmed p_choice "❓ Введите порт для принудительного завершения (0 для возврата в главное меню): "
        
        if [[ "$p_choice" == "0" ]]; then break; fi
        
        if is_valid_port "$p_choice"; then
            local ssh_match
            ssh_match=$(ss -tulnp 2>/dev/null | awk -v port="$p_choice" '$5 ~ ":" port "$" && $0 ~ /(sshd|ssh)/ {print}')
            if [[ -n "$ssh_match" || "$p_choice" == "22" ]]; then
                echo -e "${RED}❌ Обнаружен SSH-порт, завершение отклонено во избежание потери связи.${PLAIN}"
                sleep 2
                continue
            fi
            confirm_danger "Принудительно завершить процесс, занимающий порт ${p_choice}" "Будет отправлен SIGKILL процессу, использующему TCP/UDP ${p_choice}, служба будет немедленно прервана." "Если процесс завершён ошибочно, потребуется вручную перезапустить соответствующую systemd-службу или контейнер." || {
                echo -e "${BLUE}Завершение отменено.${PLAIN}"
                sleep 1
                continue
            }
            echo -e "${CYAN}▶ Принудительное завершение процесса на порту $p_choice ...${PLAIN}"
            
            # Установка fuser, если отсутствует
            if ! command -v fuser >/dev/null 2>&1; then
                install_pkg psmisc
            fi
            
            # Однострочное завершение всех процессов, использующих TCP/UDP порт
            if fuser -k -9 -n tcp "$p_choice" >/dev/null 2>&1 || fuser -k -9 -n udp "$p_choice" >/dev/null 2>&1; then
                echo -e "${GREEN}✅ Процесс принудительно завершён (SIGKILL). Порт освобождён!${PLAIN}"
            else
                echo -e "${BLUE}ℹ️ Не найдено процессов для завершения на этом порту или недостаточно прав.${PLAIN}"
            fi
            sleep 2
        else
            echo -e "${RED}❌ Неверный ввод! Введите числовой порт.${PLAIN}"
            sleep 1
        fi
    done
}

func_reboot_server() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔁 Перезагрузка сервера${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    confirm_danger "Немедленная перезагрузка сервера" "Текущая SSH-сессия будет разорвана, все работающие службы временно прервутся." "Убедитесь, что консоль облачного провайдера доступна и важные конфигурации сохранены." || {
        echo -e "${BLUE}Перезагрузка отменена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    }
    reboot
}
# ---------------------------------------------------------
# 19. Горячее обновление скрипта
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: updater.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Кеш обновлений, сравнение версий, уведомления и горячее обновление.

fetch_latest_script_version() {
    local line version
    if command -v curl >/dev/null 2>&1; then
        line=$(curl -fsSL --connect-timeout 4 --max-time 10 "$UPDATE_URL" 2>/dev/null | grep -m1 '^SCRIPT_VERSION=' || true)
    elif command -v wget >/dev/null 2>&1; then
        line=$(wget -q --timeout=10 --tries=1 -O - "$UPDATE_URL" 2>/dev/null | grep -m1 '^SCRIPT_VERSION=' || true)
    else
        return 1
    fi
    [[ -n "$line" ]] || return 1
    version="${line#SCRIPT_VERSION=}"
    version="${version%\"}"
    version="${version#\"}"
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

fetch_latest_script_sha256() {
    local checksum
    if command -v curl >/dev/null 2>&1; then
        checksum=$(curl -fsSL --connect-timeout 4 --max-time 10 "$UPDATE_SHA256_URL" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    elif command -v wget >/dev/null 2>&1; then
        checksum=$(wget -q --timeout=10 --tries=1 -O - "$UPDATE_SHA256_URL" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    else
        return 1
    fi
    checksum=$(printf '%s' "$checksum" | tr 'A-F' 'a-f')
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$checksum"
}

current_script_sha256() {
    local current_file
    current_file="${VPSO_CURRENT_SCRIPT_PATH:-$(readlink -f "$0" 2>/dev/null || true)}"
    if [[ ! -f "$current_file" ]] || ! is_vps_optimize_generated_script "$current_file"; then
        current_file="${VPSO_SHORTCUT_PATH:-/usr/local/bin/cy}"
    fi
    [[ -f "$current_file" ]] || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    sha256sum "$current_file" 2>/dev/null | awk 'NR == 1 {print $1}'
}

version_is_newer() {
    local latest="${1#v}"
    local current="${2#v}"
    local l1=0 l2=0 l3=0 c1=0 c2=0 c3=0
    IFS='.' read -r l1 l2 l3 <<< "$latest"
    IFS='.' read -r c1 c2 c3 <<< "$current"
    l1=${l1:-0}; l2=${l2:-0}; l3=${l3:-0}
    c1=${c1:-0}; c2=${c2:-0}; c3=${c3:-0}
    [[ "$l1$l2$l3$c1$c2$c3" =~ ^[0-9]+$ ]] || return 1
    (( 10#$l1 > 10#$c1 )) && return 0
    (( 10#$l1 < 10#$c1 )) && return 1
    (( 10#$l2 > 10#$c2 )) && return 0
    (( 10#$l2 < 10#$c2 )) && return 1
    (( 10#$l3 > 10#$c3 ))
}

script_update_cache_is_fresh() {
    local now mtime
    [[ -f "$SCRIPT_UPDATE_CACHE" ]] || return 1
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$SCRIPT_UPDATE_CACHE" 2>/dev/null || echo 0)
    [[ "$now" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]] || return 1
    (( now > mtime && now - mtime < 43200 ))
}

read_script_update_cache_field() {
    local key="$1"
    grep -m1 "^${key}=" "$SCRIPT_UPDATE_CACHE" 2>/dev/null | cut -d= -f2-
}

write_script_update_cache() {
    local status="$1"
    local latest="$2"
    local latest_sha256="$3"
    local message="$4"
    local cache_dir
    cache_dir=$(dirname "$SCRIPT_UPDATE_CACHE")
    mkdir -p "$cache_dir" 2>/dev/null || return 0
    {
        echo "status=${status}"
        echo "latest=${latest}"
        echo "latest_sha256=${latest_sha256}"
        echo "message=${message}"
        echo "checked_at=$(date -Is 2>/dev/null || date)"
    } > "$SCRIPT_UPDATE_CACHE" 2>/dev/null || true
}

check_script_update_status() {
    local mode="${1:-auto}"
    local status latest latest_sha256 current_sha256 message
    current_sha256=$(current_script_sha256 2>/dev/null || true)
    if [[ "$mode" != "force" ]] && script_update_cache_is_fresh; then
        status=$(read_script_update_cache_field status)
        latest=$(read_script_update_cache_field latest)
        latest_sha256=$(read_script_update_cache_field latest_sha256)
        if [[ "$latest_sha256" =~ ^[0-9a-f]{64}$ && -n "$latest" && "$latest" != "unknown" ]]; then
            if version_is_newer "$latest" "$SCRIPT_VERSION"; then
                status="available"
            elif [[ -n "$current_sha256" && -n "$latest_sha256" && "$current_sha256" != "$latest_sha256" ]]; then
                status="available"
            else
                status="current"
            fi
            printf '%s|%s\n' "${status:-unknown}" "${latest:-unknown}"
            return 0
        fi
    fi

    if latest=$(fetch_latest_script_version) && latest_sha256=$(fetch_latest_script_sha256); then
        if version_is_newer "$latest" "$SCRIPT_VERSION"; then
            status="available"
            message="Доступна новая версия ${latest}"
        elif [[ -n "$current_sha256" && "$current_sha256" != "$latest_sha256" ]]; then
            status="available"
            message="Обнаружено обновление содержимого той же версии"
        else
            status="current"
            message="Скрипт уже актуален"
        fi
        write_script_update_cache "$status" "$latest" "$latest_sha256" "$message"
        printf '%s|%s\n' "$status" "$latest"
        return 0
    fi

    write_script_update_cache "error" "unknown" "unknown" "Не удалось проверить обновления"
    printf 'error|unknown\n'
}

print_auto_update_notice() {
    local result status latest
    result=$(check_script_update_status "auto" 2>/dev/null || true)
    status="${result%%|*}"
    latest="${result#*|}"
    case "$status" in
        available)
            if [[ "$latest" == "$SCRIPT_VERSION" ]]; then
                echo -e " ${BOLD}${YELLOW}Обновление:${PLAIN} обнаружено обновление содержимого ${CYAN}${latest}${PLAIN}, введите ${YELLOW}u${PLAIN} для обновления."
            else
                echo -e " ${BOLD}${YELLOW}Обновление:${PLAIN} обнаружена версия ${CYAN}${latest}${PLAIN}, введите ${YELLOW}u${PLAIN} для обновления."
            fi
            ;;
        current)
            echo -e " ${BLUE}Статус обновления:${PLAIN} текущая ${SCRIPT_VERSION}, скрипт актуален."
            ;;
    esac
}

func_update_script() {
    clear
    local tmp_file
    tmp_file=$(mktemp /tmp/cy_update.XXXXXX.sh) || {
        echo -e "${RED}❌ Не удалось создать временный файл, обновление отменено.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return 1
    }
    echo -e "${CYAN}👉 Загрузка последней версии с GitHub...${PLAIN}"
    if download_verified_update_script "$tmp_file" \
        && grep -q "func_sni_stack_quick_menu" "$tmp_file" 2>/dev/null \
        && grep -q "main_menu" "$tmp_file" 2>/dev/null \
        && ! grep -Eq '^[[:space:]]*(source|\.)[[:space:]]+.*src/' "$tmp_file" 2>/dev/null \
        && copy_shortcut_candidate "$tmp_file" /usr/local/bin/cy "Проверенный обновлённый скрипт"; then
        rm -f "$tmp_file" "$SCRIPT_UPDATE_CACHE"
        echo -e "${GREEN}✅ Обновление загружено и установлено! Перезапуск панели...${PLAIN}"
        sleep 1
        exec bash /usr/local/bin/cy
    else
        rm -f "$tmp_file"
        echo -e "${RED}❌ Ошибка обновления: загрузка, проверка подписи, синтаксис или sha256 не пройдены.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
    fi
}

# ---------------------------------------------------------
# 20. Предварительная проверка перед развёртыванием
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: preflight.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Предварительные проверки перед развёртыванием и генерация диагностических отчётов.

preflight_install_missing_commands() {
    local missing=("$@")
    local pkgs=()
    local cmd

    for cmd in "${missing[@]}"; do
        case "$cmd" in
            curl) pkgs+=("curl") ;;
            wget) pkgs+=("wget") ;;
            sudo) pkgs+=("sudo") ;;
            ss)
                if is_debian; then
                    pkgs+=("iproute2")
                elif is_redhat; then
                    pkgs+=("iproute")
                fi
                ;;
        esac
    done

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        return 0
    fi

    echo -e "${CYAN}▶ Установка недостающих базовых команд: ${missing[*]}${PLAIN}"
    install_pkg "${pkgs[@]}"
}

preflight_missing_minimal_compat_items() {
    local missing=()
    local cmd svc
    local commands=(sudo curl wget ss ip getent tar gzip openssl jq awk sed grep pgrep journalctl timedatectl git nano lsof)
    local services=()

    for cmd in "${commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("cmd:$cmd")
    done

    if is_debian; then
        services=(cron dbus chrony)
    elif is_redhat; then
        services=(crond dbus chronyd)
    fi

    for svc in "${services[@]}"; do
        systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | awk 'NF {found=1} END {exit found ? 0 : 1}' || missing+=("svc:$svc")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        printf '%s\n' "${missing[@]}"
    fi
}

preflight_enable_ntp() {
    local ntp_sync
    echo -e "${CYAN}▶ Попытка включить синхронизацию времени NTP...${PLAIN}"

    if is_debian; then
        install_pkg chrony
    elif is_redhat; then
        install_pkg chrony
    fi

    timedatectl set-ntp true >/dev/null 2>&1 || true
    systemctl enable --now chrony >/dev/null 2>&1 || true
    systemctl enable --now chronyd >/dev/null 2>&1 || true

    if command -v chronyc >/dev/null 2>&1; then
        chronyc -a 'burst 4/4' >/dev/null 2>&1 || true
        chronyc -a makestep >/dev/null 2>&1 || true
    else
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    fi

    sleep 2
    ntp_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [[ "$ntp_sync" == "yes" ]]; then
        echo -e "${GREEN}✅ Синхронизация времени NTP восстановлена.${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ NTP всё ещё не синхронизирован, диагностика:${PLAIN}"
        timedatectl status 2>/dev/null || true
        chronyc tracking 2>/dev/null || true
        chronyc sources -v 2>/dev/null || true
        journalctl -u chrony -u chronyd -u systemd-timesyncd -n 20 --no-pager 2>/dev/null || true
    fi
}

func_preflight_check() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧪 Предварительная проверка (сеть/система/ресурсы/пакеты/совместимость)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local ok_count=0
    local warn_count=0
    local err_count=0

    echo -e "${YELLOW}▶ [1/9] Проверка состояния системы...${PLAIN}"
    local sys_state
    sys_state=$(systemctl is-system-running 2>/dev/null)
    sys_state=${sys_state:-unknown}
    if [[ "$sys_state" == "running" ]]; then
        echo -e "${GREEN}✅ systemd состояние нормальное: $sys_state${PLAIN}"
        ((ok_count++))
    elif [[ "$sys_state" == "degraded" ]]; then
        echo -e "${YELLOW}⚠️ systemd состояние деградировано: $sys_state${PLAIN}"
        systemctl --failed --no-legend --no-pager 2>/dev/null | awk 'NF {print "   - " $1 " (" $2 ")"}' | head -n 8
        ((warn_count++))
    else
        echo -e "${RED}❌ systemd состояние аномальное: $sys_state${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [2/9] Проверка публичной сети...${PLAIN}"
    local ipv4
    ipv4=$(curl -s4 --max-time 3 icanhazip.com 2>/dev/null)
    if [[ -n "$ipv4" ]]; then
        echo -e "${GREEN}✅ IPv4 доступен: ${ipv4}${PLAIN}"
        ((ok_count++))
    else
        echo -e "${YELLOW}⚠️ Публичный IPv4 не обнаружен, возможно, только IPv6 или сеть ограничена${PLAIN}"
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [3/9] Проверка DNS...${PLAIN}"
    if getent ahosts raw.githubusercontent.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ DNS работает (raw.githubusercontent.com)${PLAIN}"
        ((ok_count++))
    else
        echo -e "${RED}❌ DNS не работает, удалённые скрипты могут не загружаться${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [4/9] Проверка синхронизации времени...${PLAIN}"
    local ntp_sync
    local can_fix_ntp=false
    ntp_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [[ "$ntp_sync" == "yes" ]]; then
        echo -e "${GREEN}✅ NTP синхронизирован${PLAIN}"
        ((ok_count++))
    else
        echo -e "${YELLOW}⚠️ NTP не синхронизирован, может повлиять на сертификаты и проверку репозиториев${PLAIN}"
        can_fix_ntp=true
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [5/9] Проверка дискового пространства...${PLAIN}"
    local root_use
    root_use=$(df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}')
    if [[ -n "$root_use" && "$root_use" -lt 80 ]]; then
        echo -e "${GREEN}✅ Использование корневого раздела здоровое: ${root_use}%${PLAIN}"
        ((ok_count++))
    elif [[ -n "$root_use" && "$root_use" -lt 90 ]]; then
        echo -e "${YELLOW}⚠️ Использование корневого раздела высокое: ${root_use}%${PLAIN}"
        ((warn_count++))
    else
        echo -e "${RED}❌ Использование корневого раздела критическое: ${root_use:-неизвестно}%${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [6/9] Проверка доступной памяти...${PLAIN}"
    local mem_avail
    mem_avail=$(free -m | awk '/^Mem:/ {print $7}')
    [[ -z "$mem_avail" ]] && mem_avail=$(free -m | awk '/^Mem:/ {print $4}')
    if [[ -n "$mem_avail" && "$mem_avail" -ge 300 ]]; then
        echo -e "${GREEN}✅ Доступной памяти достаточно: ${mem_avail} МБ${PLAIN}"
        ((ok_count++))
    elif [[ -n "$mem_avail" && "$mem_avail" -ge 150 ]]; then
        echo -e "${YELLOW}⚠️ Доступной памяти мало: ${mem_avail} МБ${PLAIN}"
        ((warn_count++))
    else
        echo -e "${RED}❌ Доступной памяти критически мало: ${mem_avail:-неизвестно} МБ${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [7/9] Проверка занятости менеджера пакетов...${PLAIN}"
    local pkg_busy=false
    if is_debian; then
        pgrep -x apt >/dev/null 2>&1 && pkg_busy=true
        pgrep -x apt-get >/dev/null 2>&1 && pkg_busy=true
        pgrep -x dpkg >/dev/null 2>&1 && pkg_busy=true
    elif is_redhat; then
        pgrep -x yum >/dev/null 2>&1 && pkg_busy=true
        pgrep -x dnf >/dev/null 2>&1 && pkg_busy=true
        pgrep -x rpm >/dev/null 2>&1 && pkg_busy=true
    fi

    if $pkg_busy; then
        echo -e "${YELLOW}⚠️ Менеджер пакетов занят, рекомендуется подождать перед установкой${PLAIN}"
        ((warn_count++))
    else
        echo -e "${GREEN}✅ Менеджер пакетов свободен${PLAIN}"
        ((ok_count++))
    fi

    echo -e "${YELLOW}▶ [8/9] Проверка наличия критических команд...${PLAIN}"
    local cmd_miss=()
    command -v curl >/dev/null 2>&1 || cmd_miss+=("curl")
    command -v wget >/dev/null 2>&1 || cmd_miss+=("wget")
    command -v sudo >/dev/null 2>&1 || cmd_miss+=("sudo")
    command -v ss >/dev/null 2>&1 || cmd_miss+=("ss")
    if [[ ${#cmd_miss[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Критические команды присутствуют${PLAIN}"
        ((ok_count++))
    else
        echo -e "${RED}❌ Отсутствуют команды: ${cmd_miss[*]}${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [9/9] Проверка минимальных совместимых компонентов...${PLAIN}"
    local minimal_miss=()
    mapfile -t minimal_miss < <(preflight_missing_minimal_compat_items)
    if [[ ${#minimal_miss[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Минимальные совместимые компоненты в порядке${PLAIN}"
        ((ok_count++))
    else
        echo -e "${YELLOW}⚠️ Обнаружены отсутствующие компоненты/службы:${PLAIN}"
        printf '  - %s\n' "${minimal_miss[@]}"
        ((warn_count++))
    fi

    echo -e "------------------------------------------------"
    echo -e "${CYAN}📌 Итог предпроверки: ${GREEN}${ok_count} OK${PLAIN} / ${YELLOW}${warn_count} предупреждений${PLAIN} / ${RED}${err_count} ошибок${PLAIN}"
    if [[ "$err_count" -gt 0 ]]; then
        echo -e "${RED}⚠️ Рекомендуется сначала исправить ошибки перед развёртыванием и модификацией системы.${PLAIN}"
    elif [[ "$warn_count" -gt 0 ]]; then
        echo -e "${YELLOW}💡 Можно продолжать, но рекомендуется обработать предупреждения для повышения стабильности.${PLAIN}"
    else
        echo -e "${GREEN}🎉 Среда здорова, можно приступать к развёртыванию.${PLAIN}"
    fi

    if ! $pkg_busy && { $can_fix_ntp || [[ ${#cmd_miss[@]} -gt 0 ]] || [[ ${#minimal_miss[@]} -gt 0 ]]; }; then
        local fix_confirm rerun_confirm
        echo -e "------------------------------------------------"
        echo -e "${CYAN}🛠️ Автоматически исправляемые простые проблемы:${PLAIN}"
        $can_fix_ntp && echo -e "  - Включить синхронизацию NTP"
        [[ ${#cmd_miss[@]} -gt 0 ]] && echo -e "  - Установить недостающие базовые команды: ${cmd_miss[*]}"
        [[ ${#minimal_miss[@]} -gt 0 ]] && echo -e "  - Дополнить минимальные совместимые компоненты"
        read_trimmed fix_confirm "Исправить эти простые проблемы сейчас? (y/N): "
        if is_yes "$fix_confirm"; then
            [[ ${#minimal_miss[@]} -gt 0 ]] && ensure_minimal_system_compat
            $can_fix_ntp && preflight_enable_ntp
            [[ ${#cmd_miss[@]} -gt 0 ]] && preflight_install_missing_commands "${cmd_miss[@]}"
            echo -e "${GREEN}✅ Простые исправления выполнены.${PLAIN}"
            read_trimmed rerun_confirm "Повторить предпроверку сейчас? (y/N): "
            if is_yes "$rerun_confirm"; then
                func_preflight_check
                return $?
            fi
        fi
    elif $pkg_busy; then
        echo -e "${YELLOW}ℹ️ Менеджер пакетов занят, автоматическая установка пропущена.${PLAIN}"
    fi

    if [[ "${VPSO_BEGINNER_FLOW:-0}" != "1" ]]; then
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
    fi
    if [[ "$err_count" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------
# 21. Центр резервного копирования и отката
# ---------------------------------------------------------







# ---------------------------------------------------------
# 22. Общий обзор состояния служб
# ---------------------------------------------------------
service_state_for_issue() {
    local svc="$1"
    if service_unit_exists "$svc"; then
        if systemctl is-active --quiet "$svc"; then
            echo "Запущен"
        else
            echo "Установлен/не запущен"
        fi
    else
        echo "Не обнаружен"
    fi
}

recent_journal_for_issue() {
    local svc="$1"
    if service_unit_exists "$svc"; then
        journalctl -u "$svc" -n 8 --no-pager 2>/dev/null | redact_sensitive_output
    else
        echo "Служба ${svc} не обнаружена"
    fi
}

print_443_issue_connlimit_summary() {
    local marker runtime_rules saved_rules rules locations rule_count

    if ! declare -F port_connlimit_comment >/dev/null || ! declare -F port_connlimit_runtime_rule_fingerprints >/dev/null || ! declare -F port_connlimit_known_saved_rule_fingerprints >/dev/null; then
        echo "- 443 connlimit: вспомогательная функция не подключена"
        return 0
    fi

    marker=$(port_connlimit_comment 443)
    runtime_rules=$(port_connlimit_runtime_rule_fingerprints | grep -F "$marker" || true)
    saved_rules=$(port_connlimit_known_saved_rule_fingerprints | grep -F "$marker" || true)
    rules=$(printf '%s\n%s\n' "$runtime_rules" "$saved_rules" | grep -F "$marker" || true)

    if [[ -z "$rules" ]]; then
        echo "- 443 connlimit: правила для публичного 443, добавленные скриптом, не обнаружены"
        return 0
    fi

    locations=""
    [[ -n "$runtime_rules" ]] && locations="в памяти"
    [[ -n "$saved_rules" ]] && locations="${locations:+${locations},}в сохранённых файлах"
    rule_count=$(printf '%s\n' "$rules" | grep -c . || true)

    echo "- 443 connlimit: обнаружены правила connlimit для публичного 443, добавленные скриптом (${marker})"
    echo "  Расположение: ${locations:-неизвестно}; количество: ${rule_count}"
    echo "  Примечание: это ограничение действует на весь публичный 443, не может быть точным для конкретного SNI, Xray/3x-ui входящего, UUID или пользователя"
}

print_443_single_entry_issue_summary() {
    local env_file="/etc/vps-optimize/sni-stack.env"
    local web_backend web_label xray_backend panel_backend sub_backend listener_consistency

    echo "Сводка единого входа 443:"
    if ! load_sni_stack_env >/dev/null 2>&1; then
        detect_current_entry_status
        echo "- Файл конфигурации: не обнаружен ${env_file}"
        echo "- ENTRY_MODE: ${ENTRY_STATUS_MODE:-not-configured}"
        echo "- Публичный 443 слушается: ${ENTRY_STATUS_LISTENER_DISPLAY:-неизвестно} (${ENTRY_STATUS_LISTENER_PROCESS:-unknown})"
        print_443_issue_connlimit_summary
        return 0
    fi

    detect_current_entry_status
    web_backend=$(web_proxy_backend)
    web_label=$(web_proxy_engine_label)
    xray_backend=$(format_hostport "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT")
    panel_backend=$(format_hostport "$PANEL_LISTEN_ADDR" "$PANEL_LISTEN_PORT")
    sub_backend=$(format_hostport "$SUB_LISTEN_ADDR" "$SUB_LISTEN_PORT")
    if [[ "$ENTRY_STATUS_CONSISTENT" == "yes" ]]; then
        listener_consistency="согласовано"
    else
        listener_consistency="не согласовано"
    fi

    echo "- Файл конфигурации: ${env_file}"
    echo "- ENTRY_MODE: ${ENTRY_STATUS_MODE}"
    echo "- Публичный 443 слушается: ${ENTRY_STATUS_LISTENER_DISPLAY} (${ENTRY_STATUS_LISTENER_PROCESS}); с ENTRY_MODE ${listener_consistency}"
    echo "- Локальный бэкенд Caddy/Web: ${web_label} ${web_backend}"
    echo "- Локальный бэкенд Xray: ${xray_backend}"
    echo "- Путь панели: https://${PANEL_DOMAIN}${PANEL_WEB_PATH} -> ${panel_backend}"
    echo "- Пути подписок: обычная ${SUB_URI_PATH}, Clash/Mihomo ${CLASH_URI_PATH} -> ${sub_backend}"
    echo "- Дополнительная маршрутизация: Web ${#SITE_DOMAINS[@]}, TCP/SNI ${#TCP_ROUTE_SNIS[@]}, Xray-входящих ${#XRAY_SNI_ROUTE_SNIS[@]}"
    print_443_issue_connlimit_summary
}

generate_issue_diagnostics() {
    local os_desc kernel arch now script_path firewall_status latest_backups log_path
    os_desc="неизвестно"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_desc="${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}"
    fi
    kernel=$(uname -r 2>/dev/null || echo "неизвестно")
    arch=$(uname -m 2>/dev/null || echo "неизвестно")
    now=$(date -Is 2>/dev/null || date)
    script_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")

    if command -v ufw >/dev/null 2>&1; then
        firewall_status=$(ufw status 2>/dev/null | head -n 5 | tr '\n' '; ')
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall_status=$(firewall-cmd --state 2>/dev/null || echo "firewalld не запущен")
    else
        firewall_status="ufw/firewalld не обнаружены"
    fi

    latest_backups=$(find /etc/vps-optimize/backups -maxdepth 3 -type f -o -type d 2>/dev/null | sort -r | head -n 10)
    [[ -z "$latest_backups" ]] && latest_backups="не обнаружены"

    log_path=$(find /var/log /tmp /etc/vps-optimize -maxdepth 3 -type f \( -iname '*vps*optimize*.log' -o -iname '*cy*.log' \) 2>/dev/null | sort -r | head -n 5)
    [[ -z "$log_path" ]] && log_path="не обнаружены"

    echo ""
    echo "===== Диагностическая информация VPS-Optimize ====="
    echo "Версия ОС: ${os_desc}"
    echo "Версия ядра: ${kernel}"
    echo "Архитектура CPU: ${arch}"
    echo "Версия скрипта: ${SCRIPT_VERSION}"
    echo "Путь к скрипту: ${script_path}"
    echo "Текущее время: ${now}"
    echo ""
    print_443_single_entry_issue_summary
    echo ""
    if declare -F print_traffic_guard_diagnostic_summary >/dev/null; then
        print_traffic_guard_diagnostic_summary 5 yes
        echo ""
    fi
    echo "Состояние ключевых служб:"
    for svc in nginx caddy docker xray sing-box; do
        echo "- ${svc}: $(service_state_for_issue "$svc")"
    done
    echo "- Панель 3x-ui: $(xui_panel_state_for_issue)"
    echo ""
    echo "Сводка прослушиваемых портов:"
    ss -tulnp 2>/dev/null | sed -E 's/users:\(\("[^"]+",pid=[0-9]+,fd=[0-9]+\)\)/users:(process-redacted)/g' | head -n 30 || echo "ss не дал вывода"
    echo ""
    echo "Занятость порта 443:"
    ss -tulnp 2>/dev/null | grep -E '(:443[[:space:]]|:443$)' || echo "Порт 443 не слушается"
    echo ""
    echo "Состояние брандмауэра:"
    echo "${firewall_status}"
    echo ""
    echo "Последние ошибки Nginx:"
    recent_journal_for_issue nginx
    echo ""
    echo "Последние ошибки Caddy:"
    recent_journal_for_issue caddy
    echo ""
    echo "Последние логи скрипта:"
    echo "${log_path}"
    echo ""
    echo "Последние резервные копии:"
    echo "${latest_backups}"
    echo "===== Конец диагностики, перед отправкой проверьте конфиденциальные данные ====="
}

# ---------------------------------------------------------
# Module: health_dashboard.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Панель состояния служб и сводки проблем выполнения.

print_log_capacity_group() {
    local label="$1"
    local pattern="$2"
    local count=0 total=0 largest_size=0 largest_file="" file size

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        size=$(file_size_bytes "$file")
        count=$((count + 1))
        total=$((total + size))
        if (( size > largest_size )); then
            largest_size="$size"
            largest_file="$file"
        fi
    done < <(compgen -G "$pattern" 2>/dev/null | sort || true)

    if (( count == 0 )); then
        echo "- ${label}: файлы логов не обнаружены"
        return 0
    fi

    echo "- ${label}: ${count} файлов, общий объём $(format_bytes "$total"); наибольший $(format_bytes "$largest_size") ${largest_file}"
}

print_log_capacity_summary() {
    echo -e "${CYAN}🧾 Сводка по объёму логов${PLAIN}"
    print_log_capacity_group "/var/log/vps-optimize/*" "/var/log/vps-optimize/*"
    print_log_capacity_group "/var/log/vpso-mux*" "/var/log/vpso-mux*"
    print_log_capacity_group "/var/log/vps-traffic-guard.log" "/var/log/vps-traffic-guard.log*"
    echo "- Логи Bash по умолчанию ротируются при превышении $(format_bytes "$VPSO_DEFAULT_LOG_MAX_BYTES") с сохранением ${VPSO_DEFAULT_LOG_ROTATE_KEEP} копий; journald всё ещё выводит по системной политике."
    echo "- На этой странице только сводка; ротация не выполняется для уже открытых лог-файлов долго работающих процессов."
    echo "- Для демонов, пишущих напрямую в файлы, используйте systemd/journal, перезагрузку/рестарт службы или код, умеющий переоткрывать файлы."
}

vpso_permission_mode() {
    local file="$1"
    stat -c '%a' "$file" 2>/dev/null || echo "?"
}

vpso_permission_recommendation() {
    local file="$1"
    local lower
    lower=$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')

    if [[ -x "$file" && ! -d "$file" ]]; then
        printf '755|исполняемый файл'
    elif [[ "$lower" == *.json ]]; then
        printf '644/640|обычный JSON состояния'
    elif [[ "$lower" =~ (token|secret|private|key|subscription|subscribe|whitelist|sni-stack|xray|caddy|vpso-mux) ]]; then
        printf '600|может содержать токен, секрет, приватный ключ, источник подписки или белый список'
    elif [[ "$file" == /etc/vps-optimize/*.conf || "$file" == /etc/vps-optimize/*.yaml ]]; then
        printf '600|конфигурационный файл'
    elif [[ "$file" == /var/log/* ]]; then
        printf '640/644|лог-файл'
    else
        printf '644/640|обычный файл состояния'
    fi
}

vpso_permission_matches() {
    local mode="$1"
    local expected="$2"
    case "$expected" in
        600) [[ "$mode" == "600" ]] ;;
        755) [[ "$mode" == "755" ]] ;;
        640/644) [[ "$mode" == "640" || "$mode" == "644" ]] ;;
        644/640) [[ "$mode" == "644" || "$mode" == "640" ]] ;;
        *) return 0 ;;
    esac
}

vpso_permission_fix_mode() {
    local expected="$1"
    case "$expected" in
        600|755) printf '%s' "$expected" ;;
        640/644|644/640) printf '640' ;;
        *) printf '' ;;
    esac
}

collect_vpso_permission_files() {
    local pattern
    for pattern in \
        "/etc/vps-optimize/*.conf" \
        "/etc/vps-optimize/*.yaml" \
        "/var/lib/vps-optimize/*" \
        "/var/log/vps-optimize/*"; do
        compgen -G "$pattern" 2>/dev/null || true
    done | sort -u
}

check_vpso_file_permissions() {
    local action="${1:-check}"
    local checked=0 warnings=0 fixed=0 file mode rec expected reason target_mode

    if [[ "$action" == "fix" ]]; then
        confirm_risk_action "Исправить права на файлы VPS-Optimize" \
            "Файлы в /etc/vps-optimize, /var/lib/vps-optimize, /var/log/vps-optimize, у которых права слишком широкие или не соответствуют рекомендации" \
            "Если какая-то служба не может прочитать файл, можно вручную вернуть права по выводу или восстановить из резервной копии" \
            "Перед исправлением рекомендуется проверить состояние служб; эта операция не удаляет файлы массово." || return 1
    fi

    echo -e "${CYAN}🔒 Проверка прав на конфигурационные и файлы состояния${PLAIN}"
    while IFS= read -r file; do
        [[ -e "$file" && ! -d "$file" ]] || continue
        checked=$((checked + 1))
        mode=$(vpso_permission_mode "$file")
        rec=$(vpso_permission_recommendation "$file")
        expected="${rec%%|*}"
        reason="${rec#*|}"
        if vpso_permission_matches "$mode" "$expected"; then
            echo "- OK   ${file} mode=${mode} (${reason}; рекомендуется ${expected})"
            continue
        fi
        warnings=$((warnings + 1))
        echo "- WARN ${file} mode=${mode} (${reason}; рекомендуется ${expected})"
        if [[ "$action" == "fix" ]]; then
            target_mode=$(vpso_permission_fix_mode "$expected")
            if [[ -n "$target_mode" ]] && chmod "$target_mode" "$file" 2>/dev/null; then
                fixed=$((fixed + 1))
                echo "       исправлено на ${target_mode}"
            else
                echo "       не удалось автоматически исправить, проверьте вручную."
            fi
        fi
    done < <(collect_vpso_permission_files)

    if (( checked == 0 )); then
        echo "- Файлы для проверки не найдены."
    else
        echo "- Проверено ${checked} файлов; обнаружено ${warnings} требующих внимания; исправлено ${fixed}."
    fi
}

HEALTH_RECOVERY_UNITS=(
    "1|Caddy|caddy.service"
    "2|Nginx|nginx.service"
    "3|Docker|docker.service"
    "4|Fail2ban|fail2ban.service"
    "5|3x-ui|3x-ui.service"
    "6|x-ui|x-ui.service"
    "7|x-panel|x-panel.service"
    "8|Xray|xray.service"
    "9|Sing-box|sing-box.service"
    "10|S-UI|s-ui.service"
    "11|TCP Peek разделитель|vpso-mux.service"
    "12|Проверка защиты трафика|vps-traffic-guard.service"
)

health_unit_exists() {
    local unit="$1"
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q . && return 0
    systemctl list-units "$unit" --all --no-legend 2>/dev/null | grep -q . && return 0
    systemctl status "$unit" >/dev/null 2>&1
}

health_unit_status_label() {
    local unit="$1"
    if ! health_unit_exists "$unit"; then
        printf '%b' "${BLUE}Не установлен${PLAIN}"
    elif systemctl is-active --quiet "$unit"; then
        printf '%b' "${GREEN}Запущен${PLAIN}"
    elif systemctl is-failed --quiet "$unit"; then
        printf '%b' "${RED}Ошибка${PLAIN}"
    else
        printf '%b' "${YELLOW}Не запущен${PLAIN}"
    fi
}

health_system_state_label() {
    local state="${1:-unknown}"
    case "$state" in
        running) printf '%b' "${GREEN}running${PLAIN}" ;;
        degraded) printf '%b' "${YELLOW}degraded${PLAIN}" ;;
        starting|stopping|maintenance|initializing) printf '%b' "${YELLOW}${state}${PLAIN}" ;;
        *) printf '%b' "${RED}${state}${PLAIN}" ;;
    esac
}

print_failed_systemd_units() {
    local count=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        count=$((count + 1))
        echo "  - ${line}"
    done < <(systemctl --failed --no-legend --no-pager 2>/dev/null | awk 'NF {print $1 " " $2 " " $3 " " $4}' | head -n 12)
    (( count > 0 )) || echo "  - Не обнаружено ошибочных юнитов"
}

collect_failed_service_units() {
    systemctl --failed --type=service --no-legend --no-pager 2>/dev/null | awk '$1 ~ /\.service$/ {print $1}' | sort -u
}

health_restart_unit() {
    local label="$1"
    local unit="$2"

    if ! health_unit_exists "$unit"; then
        echo -e "${YELLOW}⚠️ ${unit} не обнаружен, пропуск.${PLAIN}"
        return 1
    fi

    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    if systemctl restart "$unit" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ ${label} перезапущен: ${unit}${PLAIN}"
        return 0
    fi

    echo -e "${RED}❌ ${label} не удалось перезапустить: ${unit}${PLAIN}"
    journalctl -u "$unit" -n 20 --no-pager 2>/dev/null || true
    return 1
}

health_restart_selected_unit() {
    local item number label unit selected="$1"

    for item in "${HEALTH_RECOVERY_UNITS[@]}"; do
        IFS='|' read -r number label unit <<< "$item"
        if [[ "$selected" == "$number" ]]; then
            confirm_risk_action "Перезапустить ${label}" \
                "Служба ${unit}" \
                "Проверьте journalctl -u ${unit}, исправьте конфигурацию и перезапустите вручную" \
                "Служба будет временно прервана; не закрывайте текущую SSH-сессию." || return 1
            health_restart_unit "$label" "$unit"
            return
        fi
    done

    echo -e "${RED}❌ Неверный выбор.${PLAIN}"
    return 1
}

health_restart_failed_services() {
    local failed_units=()
    local unit label ok=0 fail=0 skipped=0

    mapfile -t failed_units < <(collect_failed_service_units)
    if [[ ${#failed_units[@]} -eq 0 ]]; then
        echo -e "${GREEN}Ошибочных служб не обнаружено.${PLAIN}"
        return 0
    fi

    echo -e "${CYAN}Будут перезапущены следующие ошибочные службы:${PLAIN}"
    printf '  - %s\n' "${failed_units[@]}"
    confirm_risk_action "Перезапустить ошибочные systemd-службы" \
        "Службы, находящиеся в состоянии ошибки" \
        "Проверьте соответствующий journalctl, исправьте конфигурацию и перезапустите вручную" \
        "ssh/sshd будут пропущены, остальные службы временно прервутся." || return 1

    for unit in "${failed_units[@]}"; do
        case "$unit" in
            ssh.service|sshd.service)
                echo -e "${YELLOW}⚠️ ${unit} пропущен, чтобы не разорвать текущую SSH-сессию.${PLAIN}"
                skipped=$((skipped + 1))
                continue
                ;;
        esac
        label="${unit%.service}"
        if health_restart_unit "$label" "$unit"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done

    systemctl reset-failed >/dev/null 2>&1 || true
    echo -e "${CYAN}Результат: успешно ${ok}, ошибок ${fail}, пропущено ${skipped}.${PLAIN}"
}

health_reset_failed_state() {
    if systemctl reset-failed >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Выполнен systemctl reset-failed.${PLAIN}"
    else
        echo -e "${RED}❌ Не удалось выполнить reset-failed.${PLAIN}"
        return 1
    fi
}

health_enable_auto_restart_for_unit() {
    local item number label unit selected="$1"
    local dropin_dir dropin_file

    for item in "${HEALTH_RECOVERY_UNITS[@]}"; do
        IFS='|' read -r number label unit <<< "$item"
        [[ "$selected" == "$number" ]] || continue

        if [[ "$unit" != *.service ]]; then
            echo -e "${YELLOW}⚠️ ${unit} не является служебным юнитом, настройка автоматического перезапуска пропущена.${PLAIN}"
            return 1
        fi
        if ! health_unit_exists "$unit"; then
            echo -e "${YELLOW}⚠️ ${unit} не обнаружен, пропуск.${PLAIN}"
            return 1
        fi

        confirm_risk_action "Включить автоматический перезапуск для ${label}" \
            "/etc/systemd/system/${unit}.d/10-vps-optimize-restart.conf" \
            "Удалите этот drop-in и выполните systemctl daemon-reload" \
            "При сбое systemd автоматически перезапустит службу; ошибки конфигурации всё равно требуют просмотра логов." || return 1

        dropin_dir="/etc/systemd/system/${unit}.d"
        dropin_file="${dropin_dir}/10-vps-optimize-restart.conf"
        mkdir -p "$dropin_dir" || { echo -e "${RED}❌ Не удалось создать drop-in каталог.${PLAIN}"; return 1; }
        cat > "$dropin_file" <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF
        systemctl daemon-reload >/dev/null 2>&1 || { echo -e "${RED}❌ Не удалось выполнить systemctl daemon-reload.${PLAIN}"; return 1; }
        systemctl enable "$unit" >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ Автоматический перезапуск включён: ${dropin_file}${PLAIN}"
        health_restart_unit "$label" "$unit" || true
        return
    done

    echo -e "${RED}❌ Неверный выбор.${PLAIN}"
    return 1
}

health_show_failed_unit_logs() {
    local unit choice i
    local failed_units=()

    mapfile -t failed_units < <(collect_failed_service_units)
    if [[ ${#failed_units[@]} -gt 0 ]]; then
        echo -e "${CYAN}Ошибочные службы:${PLAIN}"
        for i in "${!failed_units[@]}"; do
            echo -e "${GREEN} $((i + 1)). ${failed_units[$i]}${PLAIN}"
        done
        echo " 0. Ввести другое имя службы"
        read_trimmed choice "Выберите номер или введите имя службы: "
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#failed_units[@]} )); then
            unit="${failed_units[$((choice - 1))]}"
        elif [[ "$choice" == "0" ]]; then
            read_trimmed unit "Введите имя службы (например caddy.service): "
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}❌ Неверный номер.${PLAIN}"
            return 1
        else
            unit="$choice"
        fi
    else
        read_trimmed unit "Введите имя службы (например caddy.service): "
    fi
    [[ -n "$unit" ]] || return 0
    [[ "$unit" == *.service || "$unit" == *.timer || "$unit" == *.socket ]] || unit="${unit}.service"
    if ! health_unit_exists "$unit"; then
        echo -e "${YELLOW}⚠️ ${unit} не обнаружен.${PLAIN}"
        return 1
    fi
    journalctl -u "$unit" -n 80 --no-pager 2>/dev/null || true
}

func_health_service_recovery_menu() {
    local choice

    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Диагностика/здоровье > Восстановление служб"
        echo -e "${BOLD}🧰 Перезапуск служб и автоматический подъём${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${CYAN}Ошибочные юниты:${PLAIN}"
        print_failed_systemd_units
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}Часто используемые службы${PLAIN}"
        local item number label unit
        for item in "${HEALTH_RECOVERY_UNITS[@]}"; do
            IFS='|' read -r number label unit <<< "$item"
            echo -e "${GREEN} ${number}. ${label}${PLAIN} [${unit}] $(health_unit_status_label "$unit")"
        done
        echo -e "------------------------------------------------"
        echo -e "${GREEN} r. Перезапустить одну службу${PLAIN}"
        echo -e "${GREEN} f. Перезапустить ошибочные службы${PLAIN}"
        echo -e "${GREEN} a. Включить автоматический перезапуск для службы${PLAIN}"
        echo -e "${GREEN} x. Сбросить флаги ошибок${PLAIN}"
        echo -e "${GREEN} l. Просмотреть логи службы${PLAIN}"
        echo -e "${RED} 0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            r|R)
                read_trimmed choice "Введите номер службы для перезапуска: "
                health_restart_selected_unit "$choice"
                pause_return
                ;;
            f|F)
                health_restart_failed_services
                pause_return
                ;;
            a|A)
                read_trimmed choice "Введите номер службы для включения автоперезапуска: "
                health_enable_auto_restart_for_unit "$choice"
                pause_return
                ;;
            x|X)
                health_reset_failed_state
                pause_return
                ;;
            l|L)
                health_show_failed_unit_logs
                pause_return
                ;;
            0|q|Q) return ;;
            *) echo -e "${RED}❌ Неверный выбор.${PLAIN}"; sleep 1 ;;
        esac
    done
}

func_health_dashboard() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Диагностика/здоровье"
    echo -e "${BOLD}📈 Общий обзор состояния служб${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local ssh_state="${RED}Не запущен${PLAIN}"
    if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
        ssh_state="${GREEN}Запущен${PLAIN}"
    fi

    local caddy_state="${RED}Не установлен/не запущен${PLAIN}"
    if command -v caddy >/dev/null 2>&1; then
        if systemctl is-active --quiet caddy; then
            caddy_state="${GREEN}Запущен${PLAIN}"
        else
            caddy_state="${YELLOW}Установлен, но не запущен${PLAIN}"
        fi
    fi

    local docker_state="${RED}Не установлен/не запущен${PLAIN}"
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
            docker_state="${GREEN}Запущен${PLAIN}"
        else
            docker_state="${YELLOW}Установлен, но не запущен${PLAIN}"
        fi
    fi

    local f2b_state="${RED}Не установлен${PLAIN}"
    if command -v fail2ban-server >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban; then
            f2b_state="${GREEN}Запущен${PLAIN}"
        else
            f2b_state="${YELLOW}Установлен, но не запущен${PLAIN}"
        fi
    fi

    local fw_state="${RED}Не включён${PLAIN}"
    if is_debian; then
        if ufw status 2>/dev/null | grep -qwi active; then
            fw_state="${GREEN}UFW запущен${PLAIN}"
        else
            fw_state="${YELLOW}UFW не включён${PLAIN}"
        fi
    else
        if systemctl is-active --quiet firewalld; then
            fw_state="${GREEN}Firewalld запущен${PLAIN}"
        else
            fw_state="${YELLOW}Firewalld не включён${PLAIN}"
        fi
    fi

    local current_p
    current_p=$(ss -tlnp 2>/dev/null | grep -w 'sshd' | awk '{print $4}' | awk -F: '{print $NF}' | head -n1)
    [[ -z "$current_p" ]] && current_p=$(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    current_p=${current_p:-22}

    local failed_units
    failed_units=$(systemctl --failed --no-legend 2>/dev/null | grep -c .)
    local system_state
    system_state=$(systemctl is-system-running 2>/dev/null || true)
    [[ -z "$system_state" ]] && system_state="unknown"

    echo -e "SSH служба        : [ $ssh_state ]   порт: ${CYAN}${current_p}${PLAIN}"
    echo -e "Caddy служба      : [ $caddy_state ]"
    echo -e "Docker служба     : [ $docker_state ]"
    echo -e "Fail2ban служба   : [ $f2b_state ]"
    echo -e "Брандмауэр        : [ $fw_state ]"
    echo -e "Общее состояние systemd : [ $(health_system_state_label "$system_state") ]"
    echo -e "Ошибочных юнитов systemd : ${YELLOW}${failed_units}${PLAIN}"
    echo -e "------------------------------------------------"
    print_project_runtime_overview
    echo -e "------------------------------------------------"
    print_log_capacity_summary
    echo -e "------------------------------------------------"
    if declare -F print_port_connlimit_health_summary >/dev/null; then
        print_port_connlimit_health_summary
        echo -e "------------------------------------------------"
    fi

    echo -e "${CYAN}🔌 Топ 12 прослушиваемых портов${PLAIN}"
    ss -tuln 2>/dev/null | grep -E 'LISTEN|UNCONN' | awk '{print $5}' | awk -F: '{print $NF}' | grep -E '^[0-9]+$' | sort -nu | head -n 12 | tr '\n' ' '
    echo ""

    local cert_root="/var/lib/caddy/.local/share/caddy/certificates"
    [[ ! -d "$cert_root" ]] && cert_root="/root/.local/share/caddy/certificates"

    if [[ -d "$cert_root" ]]; then
        local cert_total=0
        local cert_warn=0
        while IFS= read -r crt; do
            local end_date ts_left days_left
            end_date=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2-)
            if [[ -n "$end_date" ]]; then
                ts_left=$(( $(date -d "$end_date" +%s 2>/dev/null) - $(date +%s) ))
                days_left=$(( ts_left / 86400 ))
                cert_total=$((cert_total+1))
                if [[ "$days_left" -le 15 ]]; then
                    cert_warn=$((cert_warn+1))
                fi
            fi
        done < <(find "$cert_root" -type f -name "*.crt" 2>/dev/null)

        echo -e "${CYAN}🔐 Сводка по сертификатам${PLAIN}"
        if [[ "$cert_total" -eq 0 ]]; then
            echo -e "${BLUE}ℹ️ Не найдено файлов сертификатов для анализа.${PLAIN}"
        else
            echo -e "Всего сертификатов: ${GREEN}${cert_total}${PLAIN} | Истекают в течение 15 дней: ${YELLOW}${cert_warn}${PLAIN}"
        fi
    fi

    echo -e "------------------------------------------------"
    echo -e "${YELLOW}💡 Если ошибочных юнитов > 0, можно войти в s для восстановления служб.${PLAIN}"
    echo -e "${CYAN}Введите s для восстановления служб, d для генерации диагностики, p для проверки прав, P для исправления прав, ? для справки, любая другая клавиша для возврата.${PLAIN}"
    local health_choice
    read -n 1 -s -r health_choice
    echo ""
    case "$health_choice" in
        s|S) func_health_service_recovery_menu ;;
        d|D) generate_issue_diagnostics; pause_return ;;
        p) check_vpso_file_permissions; pause_return ;;
        P) check_vpso_file_permissions fix; pause_return ;;
        "?") show_health_help; pause_return ;;
    esac
}

# ---------------------------------------------------------
# Module: dns_optimize.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Оптимизация профилей DNS-резолверов.

dns_write_static_resolv_conf() {
    local v4_servers="$1"
    local v6_servers="$2"
    local server

    if [[ -L /etc/resolv.conf ]]; then
        quarantine_path /etc/resolv.conf "/etc/vps-optimize/quarantine/dns" >/dev/null 2>&1 || return 1
    fi

    {
        echo "# Сгенерировано VPS-Optimize оптимизация DNS"
        echo "# Обновлено: $(date -Is 2>/dev/null || date)"
        for server in $v4_servers; do
            echo "nameserver $server"
        done
        for server in $v6_servers; do
            echo "nameserver $server"
        done
        echo "options timeout:2 attempts:3 rotate"
    } > /etc/resolv.conf
}

dns_apply_profile() {
    local profile_name="$1"
    local v4_servers="$2"
    local v6_servers="$3"
    local backup_dir all_servers resolved_active resolv_target

    confirm_risk_action "Изменить системный DNS на ${profile_name}" \
        "/etc/resolv.conf и конфигурацию systemd-resolved" \
        "Вернитесь в это меню и выберите [5] для восстановления последней DNS-резервной копии, или восстановите вручную из ${DNS_OPTIMIZE_BACKUP_DIR}" \
        "Ошибка в DNS может привести к сбоям разрешения имён; текущая SSH-сессия обычно не прерывается сразу." || return 1

    backup_dir=$(dns_backup_current_config)
    all_servers="${v4_servers} ${v6_servers}"

    resolved_active=0
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        resolved_active=1
    fi

    if [[ "$resolved_active" -eq 1 ]]; then
        mkdir -p /etc/systemd/resolved.conf.d
        {
            echo "[Resolve]"
            echo "DNS=${all_servers}"
            echo "FallbackDNS="
        } > "$DNS_OPTIMIZE_RESOLVED_DROPIN"
        systemctl restart systemd-resolved >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ Не удалось перезапустить systemd-resolved, продолжено с записью статического resolv.conf.${PLAIN}"

        resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
        if [[ "$resolv_target" != /run/systemd/resolve/* ]]; then
            dns_write_static_resolv_conf "$v4_servers" "$v6_servers" || return 1
        fi
    else
        dns_write_static_resolv_conf "$v4_servers" "$v6_servers" || return 1
    fi

    echo -e "${GREEN}✅ DNS переключён на ${profile_name}${PLAIN}"
    echo -e "IPv4 DNS: ${CYAN}${v4_servers}${PLAIN}"
    echo -e "IPv6 DNS: ${CYAN}${v6_servers}${PLAIN}"
    echo -e "${YELLOW}Резервная копия старой конфигурации: ${backup_dir}${PLAIN}"

    if getent hosts raw.githubusercontent.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Проверка DNS пройдена.${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ Проверка DNS не пройдена, проверьте сеть, доступность IPv6 или DNS-серверов.${PLAIN}"
    fi
}


func_dns_optimize() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Сеть/оптимизация ядра > Оптимизация DNS"
        echo -e "${BOLD}Оптимизация DNS${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Китайские по умолчанию: IPv4 223.5.5.5 / 119.29.29.29, IPv6 2400:3200::1 / 2402:4e00::${PLAIN}"
        echo -e "${YELLOW}Международные по умолчанию: IPv4 1.1.1.1 / 8.8.8.8, IPv6 2606:4700:4700::1111 / 2001:4860:4860::8888${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Использовать китайские DNS${PLAIN}       ${YELLOW}(Alibaba DNS + DNSPod)${PLAIN}"
        echo -e "${GREEN}  2. Использовать международные DNS${PLAIN}       ${YELLOW}(Cloudflare + Google)${PLAIN}"
        echo -e "${GREEN}  3. Пользовательские DNS${PLAIN}         ${YELLOW}(ввести IPv4 и IPv6 отдельно)${PLAIN}"
        echo -e "${GREEN}  4. Просмотр текущего DNS${PLAIN}"
        echo -e "${GREEN}  5. Восстановить последнюю DNS-резервную копию${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice v4_servers v6_servers raw_v4 raw_v6
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1)
                dns_apply_profile "Китайские DNS" "223.5.5.5 119.29.29.29" "2400:3200::1 2402:4e00::"
                pause_return
                ;;
            2)
                dns_apply_profile "Международные DNS" "1.1.1.1 8.8.8.8" "2606:4700:4700::1111 2001:4860:4860::8888"
                pause_return
                ;;
            3)
                read_trimmed raw_v4 "Введите IPv4 DNS (через запятую или пробел): "
                read_trimmed raw_v6 "Введите IPv6 DNS (через запятую или пробел): "
                v4_servers=$(dns_normalize_servers 4 "$raw_v4") || {
                    echo -e "${RED}❌ Неверный формат IPv4 DNS.${PLAIN}"
                    pause_return
                    continue
                }
                v6_servers=$(dns_normalize_servers 6 "$raw_v6") || {
                    echo -e "${RED}❌ Неверный формат IPv6 DNS.${PLAIN}"
                    pause_return
                    continue
                }
                dns_apply_profile "Пользовательские DNS" "$v4_servers" "$v6_servers"
                pause_return
                ;;
            4)
                echo -e "${CYAN}--- /etc/resolv.conf ---${PLAIN}"
                sed -n '1,80p' /etc/resolv.conf 2>/dev/null || true
                if command -v resolvectl >/dev/null 2>&1; then
                    echo -e "\n${CYAN}--- resolvectl dns ---${PLAIN}"
                    resolvectl dns 2>/dev/null || true
                fi
                pause_return
                ;;
            5) dns_restore_latest_backup; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# 23. Защита от превышения трафика
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: traffic_guard.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Учёт трафика, установка проверяющего скрипта и меню защиты от превышения.

traffic_guard_human_bytes() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", u, " ");
        i=1;
        while (b >= 1024 && i < 6) { b=b/1024; i++ }
        if (i == 1) printf "%.0f%s", b, u[i]; else printf "%.2f%s", b, u[i]
    }'
}

traffic_guard_gb_to_bytes() {
    local gb="$1"
    gb="${gb//，/.}"
    gb="${gb//,/}"
    awk -v gb="$gb" 'BEGIN {
        if (gb !~ /^[0-9]+([.][0-9]+)?$/ || gb <= 0) exit 1;
        printf "%.0f", gb * 1024 * 1024 * 1024
    }'
}

traffic_guard_gb_to_bytes_zero_ok() {
    local gb="$1"
    gb="${gb//，/.}"
    gb="${gb//,/}"
    awk -v gb="$gb" 'BEGIN {
        if (gb !~ /^[0-9]+([.][0-9]+)?$/) exit 1;
        printf "%.0f", gb * 1024 * 1024 * 1024
    }'
}

traffic_guard_bytes_to_gb() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }'
}

traffic_guard_sys_class_net() {
    printf '%s' "${VPSO_TRAFFIC_GUARD_SYS_CLASS_NET:-${TRAFFIC_GUARD_SYS_CLASS_NET:-/sys/class/net}}"
}

traffic_guard_iface_is_physical_candidate() {
    local iface="$1"
    case "$iface" in
        lo|docker*|br-*|veth*|tailscale*|wg*|tun*|tap*|zt*|virbr*|vmnet*|cni*|flannel*|kube*|dummy*|ifb*)
            return 1
            ;;
    esac
    return 0
}

traffic_guard_best_active_iface() {
    local sys_net path iface oper rx tx score best_iface="" best_score=-1
    sys_net=$(traffic_guard_sys_class_net)
    for path in "${sys_net}"/*; do
        [[ -e "$path" ]] || continue
        iface="${path##*/}"
        traffic_guard_valid_iface "$iface" || continue
        traffic_guard_iface_is_physical_candidate "$iface" || continue
        oper=$(cat "${path}/operstate" 2>/dev/null || echo "unknown")
        [[ "$oper" == "down" ]] && continue
        rx=$(cat "${path}/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx=$(cat "${path}/statistics/tx_bytes" 2>/dev/null || echo 0)
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        score=$(( rx + tx ))
        if (( score > best_score )); then
            best_score="$score"
            best_iface="$iface"
        fi
    done
    printf '%s' "$best_iface"
}

traffic_guard_detect_iface() {
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if traffic_guard_valid_iface "$iface" && traffic_guard_iface_is_physical_candidate "$iface"; then
        printf '%s' "$iface"
        return 0
    fi
    iface=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if traffic_guard_valid_iface "$iface" && traffic_guard_iface_is_physical_candidate "$iface"; then
        printf '%s' "$iface"
        return 0
    fi
    iface=$(ip -o -6 route show default 2>/dev/null | awk '{print $5; exit}')
    if traffic_guard_valid_iface "$iface" && traffic_guard_iface_is_physical_candidate "$iface"; then
        printf '%s' "$iface"
        return 0
    fi
    iface=$(traffic_guard_best_active_iface)
    printf '%s' "$iface"
}

traffic_guard_valid_iface() {
    local iface="$1"
    local sys_net
    [[ -n "$iface" && "$iface" != *"/"* && "$iface" != *".."* ]] || return 1
    sys_net=$(traffic_guard_sys_class_net)
    [[ -r "${sys_net}/${iface}/statistics/rx_bytes" && -r "${sys_net}/${iface}/statistics/tx_bytes" ]]
}

traffic_guard_mode_label() {
    case "$1" in
        tx) echo "Исходящий TX" ;;
        rx) echo "Входящий RX" ;;
        total) echo "Общий RX+TX" ;;
        max) echo "Любое направление" ;;
        *) echo "$1" ;;
    esac
}

traffic_guard_action_label() {
    case "$1" in
        poweroff) echo "Немедленное выключение" ;;
        ssh-only) echo "Оставить только SSH, остальной трафик заблокирован" ;;
        log) echo "Только запись в лог" ;;
        *) echo "$1" ;;
    esac
}

traffic_guard_select_ssh_port() {
    local current_port="${1:-}" candidate
    shift || true
    if [[ "$current_port" =~ ^[0-9]+$ ]] && (( current_port >= 1 && current_port <= 65535 )); then
        for candidate in "$@"; do
            if [[ "$candidate" == "$current_port" ]]; then
                printf '%s' "$current_port"
                return 0
            fi
        done
    fi
    if (( $# == 1 )) && [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); then
        printf '%s' "$1"
        return 0
    fi
    return 1
}

traffic_guard_detect_ssh_port() {
    local _client_addr _client_port _server_addr current_port _extra sshd_bin
    local -a ssh_ports=()
    read -r _client_addr _client_port _server_addr current_port _extra <<< "${SSH_CONNECTION:-}"
    [[ -z "${_extra:-}" ]] || current_port=""

    mapfile -t ssh_ports < <(ss -tlnp 2>/dev/null | awk '/sshd/ {addr=$4; sub(/^.*:/, "", addr); if (addr ~ /^[0-9]+$/) print addr}' | sort -nu)
    if (( ${#ssh_ports[@]} -gt 0 )); then
        traffic_guard_select_ssh_port "$current_port" "${ssh_ports[@]}"
        return $?
    fi

    sshd_bin=$(command -v sshd 2>/dev/null || true)
    if [[ -n "$sshd_bin" ]]; then
        mapfile -t ssh_ports < <("$sshd_bin" -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}' | sort -nu)
    fi
    traffic_guard_select_ssh_port "$current_port" "${ssh_ports[@]}"
}

traffic_guard_ssh_only_firewall_supported() {
    command -v iptables >/dev/null 2>&1 || return 1
    [[ ! -s /proc/net/if_inet6 ]] || command -v ip6tables >/dev/null 2>&1
}

traffic_guard_normalize_cycle_day() {
    local cycle_day="${1:-1}"
    [[ "$cycle_day" =~ ^[0-9]+$ ]] || cycle_day=1
    cycle_day=$((10#$cycle_day))
    (( cycle_day >= 1 && cycle_day <= 31 )) || cycle_day=1
    printf '%s' "$cycle_day"
}

traffic_guard_cycle_date_for_month() {
    local year_month="$1"
    local cycle_day
    local last_day effective_day
    cycle_day=$(traffic_guard_normalize_cycle_day "${2:-1}")
    last_day=$(date -d "${year_month}-01 +1 month -1 day" +%d 2>/dev/null || echo 31)
    last_day=$((10#$last_day))
    effective_day="$cycle_day"
    (( effective_day > last_day )) && effective_day="$last_day"
    printf '%s-%02d' "$year_month" "$effective_day"
}

traffic_guard_current_cycle_key() {
    local cycle_day="${1:-1}"
    local current_month previous_month current_day reset_date reset_day
    cycle_day=$(traffic_guard_normalize_cycle_day "$cycle_day")
    current_month=$(date +%Y-%m)
    reset_date=$(traffic_guard_cycle_date_for_month "$current_month" "$cycle_day")
    reset_day="${reset_date##*-}"
    current_day=$(date +%d)
    if (( 10#$current_day >= 10#$reset_day )); then
        printf '%s' "$reset_date"
    else
        previous_month=$(date -d "${current_month}-01 -1 month" +%Y-%m)
        traffic_guard_cycle_date_for_month "$previous_month" "$cycle_day"
    fi
}

traffic_guard_boot_started_after_cycle_start() {
    local cycle_key="$1"
    local proc_uptime="${VPSO_TRAFFIC_GUARD_PROC_UPTIME:-/proc/uptime}"
    local cycle_epoch now_epoch uptime_raw uptime_seconds boot_epoch
    cycle_epoch=$(date -d "${cycle_key} 00:00:00" +%s 2>/dev/null) || return 1
    read -r uptime_raw _ < "$proc_uptime" 2>/dev/null || return 1
    uptime_seconds="${uptime_raw%%.*}"
    [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || return 1
    now_epoch=$(date +%s 2>/dev/null) || return 1
    boot_epoch=$(( now_epoch - uptime_seconds ))
    (( boot_epoch >= cycle_epoch ))
}

traffic_guard_read_stats() {
    local iface="$1"
    local sys_net
    sys_net=$(traffic_guard_sys_class_net)
    cat "${sys_net}/${iface}/statistics/rx_bytes" "${sys_net}/${iface}/statistics/tx_bytes" 2>/dev/null
}

traffic_guard_mode_usage_bytes() {
    local mode="$1"
    local rx="${2:-0}"
    local tx="${3:-0}"
    [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
    [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
    case "$mode" in
        rx) printf '%s' "$rx" ;;
        total) printf '%s' "$(( rx + tx ))" ;;
        max)
            if (( rx > tx )); then printf '%s' "$rx"; else printf '%s' "$tx"; fi
            ;;
        tx|*) printf '%s' "$tx" ;;
    esac
}

traffic_guard_scale_offset_bytes() {
    local total="${1:-0}"
    local part="${2:-0}"
    local whole="${3:-0}"
    awk -v total="$total" -v part="$part" -v whole="$whole" 'BEGIN {
        if (total !~ /^[0-9]+$/ || part !~ /^[0-9]+$/ || whole !~ /^[0-9]+$/ || whole <= 0) {
            print 0;
            exit;
        }
        printf "%.0f", total * part / whole;
    }'
}

traffic_guard_baseline_direction_offsets() {
    local mode="$1"
    local rx="${2:-0}"
    local tx="${3:-0}"
    local initial="${4:-0}"
    local rx_offset=0 tx_offset=0 current_total

    [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
    [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
    [[ "$initial" =~ ^[0-9]+$ ]] || initial=0

    case "$mode" in
        rx)
            rx_offset="$initial"
            ;;
        total)
            current_total=$(( rx + tx ))
            if (( current_total > 0 )); then
                rx_offset=$(traffic_guard_scale_offset_bytes "$initial" "$rx" "$current_total")
                tx_offset=$(awk -v total="$initial" -v rx_offset="$rx_offset" 'BEGIN {
                    v = total - rx_offset;
                    if (v < 0) v = 0;
                    printf "%.0f", v;
                }')
            else
                rx_offset="$initial"
            fi
            ;;
        max)
            if (( rx >= tx && rx > 0 )); then
                rx_offset="$initial"
                tx_offset=$(traffic_guard_scale_offset_bytes "$initial" "$tx" "$rx")
            elif (( tx > 0 )); then
                tx_offset="$initial"
                rx_offset=$(traffic_guard_scale_offset_bytes "$initial" "$rx" "$tx")
            else
                rx_offset="$initial"
                tx_offset="$initial"
            fi
            ;;
        tx|*)
            tx_offset="$initial"
            ;;
    esac

    printf '%s\n%s\n' "$rx_offset" "$tx_offset"
}

traffic_guard_existing_state_usage() {
    local iface="$1"
    local mode="$2"
    local cycle_day="${3:-}"
    local state_file="${TRAFFIC_GUARD_STATE_DIR}/state"
    [[ -r "$TRAFFIC_GUARD_CONFIG" && -r "$state_file" ]] || return 1
    (
        local expected_cycle
        # shellcheck disable=SC1090
        . "$TRAFFIC_GUARD_CONFIG"
        # shellcheck disable=SC1090
        . "$state_file"
        [[ "${IFACE:-}" == "$iface" && "${MODE:-}" == "$mode" ]] || exit 1
        expected_cycle=$(traffic_guard_current_cycle_key "${cycle_day:-${CYCLE_DAY:-1}}")
        [[ "${CYCLE_KEY:-}" == "$expected_cycle" ]] || exit 1
        [[ "${LAST_USAGE:-}" =~ ^[0-9]+$ ]] || exit 1
        printf '%s' "$LAST_USAGE"
    )
}

traffic_guard_detect_initial_used_bytes() {
    local iface="$1"
    local mode="$2"
    local current_stats current_rx current_tx
    mapfile -t current_stats < <(traffic_guard_read_stats "$iface")
    current_rx="${current_stats[0]:-0}"
    current_tx="${current_stats[1]:-0}"
    traffic_guard_mode_usage_bytes "$mode" "$current_rx" "$current_tx"
}

traffic_guard_write_state_baseline() {
    local iface="$1"
    local cycle_day="$2"
    local initial_used_bytes="${3:-0}"
    local mode="${4:-${MODE:-tx}}"
    local current_stats current_rx current_tx cycle_key state_file offset_stats offset_rx offset_tx offset_bytes

    [[ "$initial_used_bytes" =~ ^[0-9]+$ ]] || initial_used_bytes=0
    traffic_guard_valid_iface "$iface" || return 1
    mapfile -t current_stats < <(traffic_guard_read_stats "$iface")
    current_rx="${current_stats[0]:-0}"
    current_tx="${current_stats[1]:-0}"
    mapfile -t offset_stats < <(traffic_guard_baseline_direction_offsets "$mode" "$current_rx" "$current_tx" "$initial_used_bytes")
    offset_rx="${offset_stats[0]:-0}"
    offset_tx="${offset_stats[1]:-0}"
    offset_bytes=$(traffic_guard_mode_usage_bytes "$mode" "$offset_rx" "$offset_tx")
    cycle_key=$(traffic_guard_current_cycle_key "$cycle_day")
    mkdir -p "$TRAFFIC_GUARD_STATE_DIR" || return 1
    chmod 700 "$TRAFFIC_GUARD_STATE_DIR" 2>/dev/null || true
    state_file="${TRAFFIC_GUARD_STATE_DIR}/state"
    {
        echo "CYCLE_KEY='${cycle_key}'"
        echo "STATE_IFACE='${iface}'"
        echo "STATE_MODE='${mode}'"
        echo "BASE_RX='${current_rx}'"
        echo "BASE_TX='${current_tx}'"
        echo "OFFSET_RX_BYTES='${offset_rx}'"
        echo "OFFSET_TX_BYTES='${offset_tx}'"
        echo "OFFSET_BYTES='${offset_bytes}'"
        echo "WARN_SENT='0'"
        echo "TRIPPED='0'"
        echo "LAST_RX='${current_rx}'"
        echo "LAST_TX='${current_tx}'"
        echo "LAST_USAGE='${offset_bytes}'"
        echo "LAST_CHECKED_AT='$(date -Is 2>/dev/null || date)'"
    } > "$state_file"
    chmod 600 "$state_file" 2>/dev/null || true
}

traffic_guard_admin_log() {
    local msg="$1"
    mkdir -p "$(dirname "$TRAFFIC_GUARD_LOG")" 2>/dev/null || true
    printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$msg" >> "$TRAFFIC_GUARD_LOG" 2>/dev/null || true
    logger -t vps-traffic-guard "$msg" 2>/dev/null || true
}

traffic_guard_checker_first_line_hex() {
    local file="$1"
    [[ -r "$file" ]] || return 1
    head -n 1 "$file" 2>/dev/null | LC_ALL=C od -An -tx1 | awk '{$1=$1; print}'
}

traffic_guard_normalize_generated_checker() {
    local file="$1"
    local tmp
    tmp=$(mktemp "${file}.normalize.XXXXXX") || return 1
    if ! LC_ALL=C sed '1s/^\xef\xbb\xbf//' "$file" | tr -d '\r' > "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! cmp -s "$file" "$tmp"; then
        cat "$tmp" > "$file" || {
            rm -f "$tmp" 2>/dev/null || true
            return 1
        }
        traffic_guard_admin_log "normalized generated checker header/line endings: ${file}"
    fi
    rm -f "$tmp" 2>/dev/null || true
}

traffic_guard_report_checker_install_failure() {
    local reason="$1"
    local file="${2:-$TRAFFIC_GUARD_CHECKER}"
    local first_line_hex
    first_line_hex=$(traffic_guard_checker_first_line_hex "$file" 2>/dev/null || echo "unreadable")
    echo -e "${RED}❌ Не удалось установить проверяющий скрипт Traffic Guard: ${reason}${PLAIN}"
    echo -e "${YELLOW}Путь к проверяющему скрипту: ${TRAFFIC_GUARD_CHECKER}${PLAIN}"
    echo -e "${YELLOW}Файл для проверки: ${file}${PLAIN}"
    echo -e "${YELLOW}Фактические байты первой строки: ${first_line_hex:-empty}${PLAIN}"
    echo -e "${YELLOW}Путь к логу: ${TRAFFIC_GUARD_LOG}${PLAIN}"
    traffic_guard_admin_log "checker install failed: ${reason}; file=${file}; first_line_hex=${first_line_hex:-empty}"
}

traffic_guard_mark_checker_install_failure() {
    local kind="$1"
    local reason="$2"
    local file="${3:-$TRAFFIC_GUARD_CHECKER}"
    TRAFFIC_GUARD_CHECKER_INSTALL_FAILURE_KIND="$kind"
    TRAFFIC_GUARD_CHECKER_INSTALL_FAILURE_FILE="$file"
    traffic_guard_report_checker_install_failure "$reason" "$file"
}

traffic_guard_checker_install_failure_is_generated() {
    [[ "${TRAFFIC_GUARD_CHECKER_INSTALL_FAILURE_KIND:-}" == "generated-content" ]]
}

traffic_guard_install_checker_once() {
    local first_line write_rc tmp_checker
    mkdir -p "$(dirname "$TRAFFIC_GUARD_CHECKER")" "$TRAFFIC_GUARD_STATE_DIR" "$(dirname "$TRAFFIC_GUARD_CONFIG")" || return 1
    tmp_checker=$(mktemp "${TRAFFIC_GUARD_CHECKER}.tmp.XXXXXX") || {
        traffic_guard_mark_checker_install_failure "io" "не удалось создать временный проверяющий файл" "$TRAFFIC_GUARD_CHECKER"
        return 1
    }
    cat > "$tmp_checker" <<'GUARD_SCRIPT'
#!/usr/bin/env bash
set -u

CONFIG="${VPSO_TRAFFIC_GUARD_CONFIG:-/etc/vps-optimize/traffic-guard.conf}"
STATE_DIR="${VPSO_TRAFFIC_GUARD_STATE_DIR:-/var/lib/vps-optimize/traffic-guard}"
STATE_FILE="${STATE_DIR}/state"
LOG_FILE="${VPSO_TRAFFIC_GUARD_LOG:-/var/log/vps-traffic-guard.log}"
SYS_CLASS_NET="${VPSO_TRAFFIC_GUARD_SYS_CLASS_NET:-/sys/class/net}"
PROC_UPTIME="${VPSO_TRAFFIC_GUARD_PROC_UPTIME:-/proc/uptime}"
LOG_MAX_BYTES="${VPSO_TRAFFIC_GUARD_LOG_MAX_BYTES:-5242880}"
LOG_ROTATE_KEEP="${VPSO_TRAFFIC_GUARD_LOG_ROTATE_KEEP:-3}"

log_file_size_bytes() {
    local size
    [[ -f "$LOG_FILE" ]] || { echo 0; return 0; }
    size=$(wc -c < "$LOG_FILE" 2>/dev/null | awk '{print $1}')
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    echo "$size"
}

traffic_guard_rotate_log_file() {
    local size i old_path new_path
    [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || LOG_MAX_BYTES=5242880
    [[ "$LOG_ROTATE_KEEP" =~ ^[0-9]+$ ]] || LOG_ROTATE_KEEP=3
    (( LOG_MAX_BYTES > 0 && LOG_ROTATE_KEEP > 0 )) || return 0
    [[ -f "$LOG_FILE" ]] || return 0

    size=$(log_file_size_bytes)
    (( size >= LOG_MAX_BYTES )) || return 0

    rm -f "${LOG_FILE}.${LOG_ROTATE_KEEP}" 2>/dev/null || true
    for ((i = LOG_ROTATE_KEEP - 1; i >= 1; i--)); do
        old_path="${LOG_FILE}.${i}"
        new_path="${LOG_FILE}.$((i + 1))"
        [[ -e "$old_path" ]] && mv -f "$old_path" "$new_path" 2>/dev/null || true
    done
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
}

log_msg() {
    local msg="$1"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    traffic_guard_rotate_log_file
    printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    logger -t vps-traffic-guard "$msg" 2>/dev/null || true
}

SSH_ONLY_FIREWALL_TAG="VPSO-TRAFFIC-GUARD-SSH-ONLY"
SSH_ONLY_ICMPV6_TYPES="1 2 3 4 130 131 132 133 134 135 136 137 141 142 143"

firewall_delete_rule_all() {
    local bin="$1"
    shift
    while "$bin" -C "$@" >/dev/null 2>&1; do
        "$bin" -D "$@" >/dev/null 2>&1 || return 1
    done
}

clear_ssh_only_firewall() {
    local bin chain icmp_type
    local rc=0
    for bin in iptables ip6tables; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            if [[ "$bin" == "iptables" || -s /proc/net/if_inet6 ]]; then
                rc=1
            fi
            continue
        fi
        firewall_delete_rule_all "$bin" INPUT -p tcp --dport "${SSH_PORT:-0}" -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
        firewall_delete_rule_all "$bin" OUTPUT -p tcp --sport "${SSH_PORT:-0}" -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
        firewall_delete_rule_all "$bin" INPUT -i lo -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
        firewall_delete_rule_all "$bin" OUTPUT -o lo -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
        if [[ "$bin" == "ip6tables" ]]; then
            firewall_delete_rule_all "$bin" INPUT -p udp --sport 547 --dport 546 -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
            firewall_delete_rule_all "$bin" OUTPUT -p udp --sport 546 --dport 547 -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
            for chain in INPUT OUTPUT; do
                for icmp_type in $SSH_ONLY_ICMPV6_TYPES; do
                    firewall_delete_rule_all "$bin" "$chain" -p ipv6-icmp --icmpv6-type "$icmp_type" -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
                done
            done
        else
            firewall_delete_rule_all "$bin" INPUT -p udp --sport 67 --dport 68 -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
            firewall_delete_rule_all "$bin" OUTPUT -p udp --sport 68 --dport 67 -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || rc=1
        fi
        firewall_delete_rule_all "$bin" INPUT -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j DROP || rc=1
        firewall_delete_rule_all "$bin" OUTPUT -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j DROP || rc=1
        firewall_delete_rule_all "$bin" FORWARD -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j DROP || rc=1
    done
    return "$rc"
}

ensure_ssh_only_rule() {
    local bin="$1"
    local chain="$2"
    shift 2
    "$bin" -C "$chain" "$@" >/dev/null 2>&1 || "$bin" -I "$chain" 1 "$@" >/dev/null 2>&1
}

apply_ssh_only_firewall_for_bin() {
    local bin="$1" chain icmp_type
    ensure_ssh_only_rule "$bin" INPUT -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j DROP || return 1
    ensure_ssh_only_rule "$bin" OUTPUT -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j DROP || return 1
    ensure_ssh_only_rule "$bin" FORWARD -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j DROP || return 1
    ensure_ssh_only_rule "$bin" INPUT -i lo -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
    ensure_ssh_only_rule "$bin" OUTPUT -o lo -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
    if [[ "$bin" == "ip6tables" ]]; then
        ensure_ssh_only_rule "$bin" INPUT -p udp --sport 547 --dport 546 -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
        ensure_ssh_only_rule "$bin" OUTPUT -p udp --sport 546 --dport 547 -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
        for chain in INPUT OUTPUT; do
            for icmp_type in $SSH_ONLY_ICMPV6_TYPES; do
                ensure_ssh_only_rule "$bin" "$chain" -p ipv6-icmp --icmpv6-type "$icmp_type" -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
            done
        done
    else
        ensure_ssh_only_rule "$bin" INPUT -p udp --sport 67 --dport 68 -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
        ensure_ssh_only_rule "$bin" OUTPUT -p udp --sport 68 --dport 67 -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
    fi
    ensure_ssh_only_rule "$bin" INPUT -p tcp --dport "$SSH_PORT" -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
    ensure_ssh_only_rule "$bin" OUTPUT -p tcp --sport "$SSH_PORT" -m comment --comment "$SSH_ONLY_FIREWALL_TAG" -j ACCEPT || return 1
}

apply_ssh_only_firewall() {
    [[ "${SSH_PORT:-}" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || {
        log_msg "ssh-only action skipped: invalid SSH_PORT=${SSH_PORT:-empty}"
        return 1
    }
    command -v iptables >/dev/null 2>&1 || {
        log_msg "ssh-only action skipped: iptables is unavailable"
        return 1
    }
    if [[ -s /proc/net/if_inet6 ]] && ! command -v ip6tables >/dev/null 2>&1; then
        log_msg "ssh-only action skipped: IPv6 is enabled but ip6tables is unavailable"
        return 1
    fi

    if ! apply_ssh_only_firewall_for_bin iptables || { [[ -s /proc/net/if_inet6 ]] && ! apply_ssh_only_firewall_for_bin ip6tables; }; then
        clear_ssh_only_firewall >/dev/null 2>&1 || true
        log_msg "ssh-only action failed: unable to install managed firewall rules"
        return 1
    fi
    log_msg "ssh-only firewall enabled on TCP port ${SSH_PORT}"
}

if [[ "${1:-}" == "--restore-ssh-only-firewall" ]]; then
    if [[ -r "$CONFIG" ]]; then
        # shellcheck disable=SC1090
        . "$CONFIG"
    fi
    if clear_ssh_only_firewall; then
        log_msg "ssh-only firewall restored"
        exit 0
    fi
    log_msg "ssh-only firewall restore failed"
    exit 1
fi

guard_exit() {
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
        log_msg "checker exited unexpectedly rc=${rc}; keep timer healthy and retry next run"
        exit 0
    fi
}
trap guard_exit EXIT

normalize_cycle_day() {
    local cycle_day="${1:-1}"
    [[ "$cycle_day" =~ ^[0-9]+$ ]] || cycle_day=1
    cycle_day=$((10#$cycle_day))
    (( cycle_day >= 1 && cycle_day <= 31 )) || cycle_day=1
    printf '%s' "$cycle_day"
}

cycle_date_for_month() {
    local year_month="$1"
    local cycle_day
    local last_day effective_day
    cycle_day=$(normalize_cycle_day "${2:-1}")
    last_day=$(date -d "${year_month}-01 +1 month -1 day" +%d 2>/dev/null || echo 31)
    last_day=$((10#$last_day))
    effective_day="$cycle_day"
    (( effective_day > last_day )) && effective_day="$last_day"
    printf '%s-%02d' "$year_month" "$effective_day"
}

current_cycle_key() {
    local cycle_day="${1:-1}"
    local current_month previous_month current_day reset_date reset_day
    cycle_day=$(normalize_cycle_day "$cycle_day")
    current_month=$(date +%Y-%m)
    reset_date=$(cycle_date_for_month "$current_month" "$cycle_day")
    reset_day="${reset_date##*-}"
    current_day=$(date +%d)
    if (( 10#$current_day >= 10#$reset_day )); then
        printf '%s' "$reset_date"
    else
        previous_month=$(date -d "${current_month}-01 -1 month" +%Y-%m)
        cycle_date_for_month "$previous_month" "$cycle_day"
    fi
}

mode_usage_bytes() {
    local mode="$1"
    local rx="${2:-0}"
    local tx="${3:-0}"
    [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
    [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
    case "$mode" in
        rx) printf '%s' "$rx" ;;
        total) printf '%s' "$(( rx + tx ))" ;;
        max)
            if (( rx > tx )); then printf '%s' "$rx"; else printf '%s' "$tx"; fi
            ;;
        tx|*) printf '%s' "$tx" ;;
    esac
}

scale_offset_bytes() {
    local total="${1:-0}"
    local part="${2:-0}"
    local whole="${3:-0}"
    awk -v total="$total" -v part="$part" -v whole="$whole" 'BEGIN {
        if (total !~ /^[0-9]+$/ || part !~ /^[0-9]+$/ || whole !~ /^[0-9]+$/ || whole <= 0) {
            print 0;
            exit;
        }
        printf "%.0f", total * part / whole;
    }'
}

baseline_direction_offsets() {
    local mode="$1"
    local rx="${2:-0}"
    local tx="${3:-0}"
    local initial="${4:-0}"
    local rx_offset=0 tx_offset=0 current_total

    [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
    [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
    [[ "$initial" =~ ^[0-9]+$ ]] || initial=0

    case "$mode" in
        rx)
            rx_offset="$initial"
            ;;
        total)
            current_total=$(( rx + tx ))
            if (( current_total > 0 )); then
                rx_offset=$(scale_offset_bytes "$initial" "$rx" "$current_total")
                tx_offset=$(awk -v total="$initial" -v rx_offset="$rx_offset" 'BEGIN {
                    v = total - rx_offset;
                    if (v < 0) v = 0;
                    printf "%.0f", v;
                }')
            else
                rx_offset="$initial"
            fi
            ;;
        max)
            if (( rx >= tx && rx > 0 )); then
                rx_offset="$initial"
                tx_offset=$(scale_offset_bytes "$initial" "$tx" "$rx")
            elif (( tx > 0 )); then
                tx_offset="$initial"
                rx_offset=$(scale_offset_bytes "$initial" "$rx" "$tx")
            else
                rx_offset="$initial"
                tx_offset="$initial"
            fi
            ;;
        tx|*)
            tx_offset="$initial"
            ;;
    esac

    printf '%s\n%s\n' "$rx_offset" "$tx_offset"
}

ensure_direction_offsets() {
    local legacy_offset offset_stats
    if [[ "${OFFSET_RX_BYTES:-}" =~ ^[0-9]+$ && "${OFFSET_TX_BYTES:-}" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    legacy_offset="${OFFSET_BYTES:-${LAST_USAGE:-0}}"
    [[ "$legacy_offset" =~ ^[0-9]+$ ]] || legacy_offset=0
    mapfile -t offset_stats < <(baseline_direction_offsets "$MODE" "${BASE_RX:-0}" "${BASE_TX:-0}" "$legacy_offset")
    OFFSET_RX_BYTES="${offset_stats[0]:-0}"
    OFFSET_TX_BYTES="${offset_stats[1]:-0}"
    OFFSET_BYTES=$(mode_usage_bytes "$MODE" "$OFFSET_RX_BYTES" "$OFFSET_TX_BYTES")
    log_msg "migrated legacy scalar offset on ${IFACE}, mode=${MODE}, offset_rx=${OFFSET_RX_BYTES}, offset_tx=${OFFSET_TX_BYTES}"
}

direction_usage_at_last_check() {
    local last_rx="${LAST_RX:-${BASE_RX:-0}}"
    local last_tx="${LAST_TX:-${BASE_TX:-0}}"
    local delta_rx=0 delta_tx=0 usage_rx usage_tx
    [[ "$last_rx" =~ ^[0-9]+$ ]] || last_rx="${BASE_RX:-0}"
    [[ "$last_tx" =~ ^[0-9]+$ ]] || last_tx="${BASE_TX:-0}"
    if [[ "${BASE_RX:-0}" =~ ^[0-9]+$ ]] && (( last_rx >= BASE_RX )); then
        delta_rx=$(( last_rx - BASE_RX ))
    fi
    if [[ "${BASE_TX:-0}" =~ ^[0-9]+$ ]] && (( last_tx >= BASE_TX )); then
        delta_tx=$(( last_tx - BASE_TX ))
    fi
    usage_rx=$(( ${OFFSET_RX_BYTES:-0} + delta_rx ))
    usage_tx=$(( ${OFFSET_TX_BYTES:-0} + delta_tx ))
    printf '%s\n%s\n' "$usage_rx" "$usage_tx"
}

boot_started_after_cycle_start() {
    local cycle_epoch now_epoch uptime_raw uptime_seconds boot_epoch
    cycle_epoch=$(date -d "${CYCLE_KEY} 00:00:00" +%s 2>/dev/null) || return 1
    read -r uptime_raw _ < "$PROC_UPTIME" 2>/dev/null || return 1
    uptime_seconds="${uptime_raw%%.*}"
    [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || return 1
    now_epoch=$(date +%s 2>/dev/null) || return 1
    boot_epoch=$(( now_epoch - uptime_seconds ))
    (( boot_epoch >= cycle_epoch ))
}

save_state() {
    mkdir -p "$STATE_DIR" || exit 1
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    {
        echo "CYCLE_KEY='${CYCLE_KEY:-}'"
        echo "STATE_IFACE='${IFACE:-}'"
        echo "STATE_MODE='${MODE:-tx}'"
        echo "BASE_RX='${BASE_RX:-0}'"
        echo "BASE_TX='${BASE_TX:-0}'"
        echo "OFFSET_RX_BYTES='${OFFSET_RX_BYTES:-0}'"
        echo "OFFSET_TX_BYTES='${OFFSET_TX_BYTES:-0}'"
        echo "OFFSET_BYTES='${OFFSET_BYTES:-0}'"
        echo "WARN_SENT='${WARN_SENT:-0}'"
        echo "TRIPPED='${TRIPPED:-0}'"
        echo "LAST_RX='${CURRENT_RX:-0}'"
        echo "LAST_TX='${CURRENT_TX:-0}'"
        echo "LAST_USAGE='${USAGE_BYTES:-0}'"
        echo "LAST_CHECKED_AT='$(date -Is 2>/dev/null || date)'"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

[[ -r "$CONFIG" ]] || exit 0
# shellcheck disable=SC1090
. "$CONFIG"

[[ "${ENABLED:-0}" == "1" ]] || exit 0
IFACE="${IFACE:-}"
MODE="${MODE:-tx}"
LIMIT_BYTES="${LIMIT_BYTES:-0}"
CYCLE_DAY="${CYCLE_DAY:-1}"
WARN_PERCENT="${WARN_PERCENT:-90}"
ACTION="${ACTION:-poweroff}"
SSH_PORT="${SSH_PORT:-}"
INITIAL_USED_BYTES="${INITIAL_USED_BYTES:-0}"

[[ -n "$IFACE" && -r "${SYS_CLASS_NET}/${IFACE}/statistics/rx_bytes" && -r "${SYS_CLASS_NET}/${IFACE}/statistics/tx_bytes" ]] || {
    log_msg "interface ${IFACE:-empty} is not readable, skip"
    exit 0
}
[[ "$LIMIT_BYTES" =~ ^[0-9]+$ && "$LIMIT_BYTES" -gt 0 ]] || exit 0
[[ "$WARN_PERCENT" =~ ^[0-9]+$ ]] || WARN_PERCENT=90
(( WARN_PERCENT >= 1 && WARN_PERCENT <= 99 )) || WARN_PERCENT=90

CURRENT_RX=$(cat "${SYS_CLASS_NET}/${IFACE}/statistics/rx_bytes" 2>/dev/null || echo 0)
CURRENT_TX=$(cat "${SYS_CLASS_NET}/${IFACE}/statistics/tx_bytes" 2>/dev/null || echo 0)
[[ "$CURRENT_RX" =~ ^[0-9]+$ ]] || CURRENT_RX=0
[[ "$CURRENT_TX" =~ ^[0-9]+$ ]] || CURRENT_TX=0
CYCLE_NOW=$(current_cycle_key "$CYCLE_DAY")

STATE_EXISTS=0
if [[ -r "$STATE_FILE" ]]; then
    STATE_EXISTS=1
    # shellcheck disable=SC1090
    . "$STATE_FILE"
fi

if [[ "$STATE_EXISTS" -eq 1 ]]; then
    if [[ -n "${STATE_IFACE:-}" && "${STATE_IFACE:-}" != "$IFACE" ]]; then
        log_msg "state interface ${STATE_IFACE} does not match ${IFACE}; reinitialize baseline"
        STATE_EXISTS=0
        CYCLE_KEY=""
    elif [[ -n "${STATE_MODE:-}" && "${STATE_MODE:-}" != "$MODE" ]]; then
        log_msg "state mode ${STATE_MODE} does not match ${MODE}; reinitialize baseline"
        STATE_EXISTS=0
        CYCLE_KEY=""
    fi
fi

if [[ "${CYCLE_KEY:-}" != "$CYCLE_NOW" ]]; then
    if [[ "$ACTION" == "ssh-only" ]] && ! clear_ssh_only_firewall; then
        log_msg "new cycle ${CYCLE_NOW} detected but ssh-only firewall restore failed; will retry"
        exit 0
    fi
    offset_stats=()
    CYCLE_KEY="$CYCLE_NOW"
    BASE_RX="$CURRENT_RX"
    BASE_TX="$CURRENT_TX"
    if [[ "$STATE_EXISTS" -eq 0 ]]; then
        mapfile -t offset_stats < <(baseline_direction_offsets "$MODE" "$CURRENT_RX" "$CURRENT_TX" "${INITIAL_USED_BYTES:-0}")
        OFFSET_RX_BYTES="${offset_stats[0]:-0}"
        OFFSET_TX_BYTES="${offset_stats[1]:-0}"
    else
        OFFSET_RX_BYTES=0
        OFFSET_TX_BYTES=0
    fi
    OFFSET_BYTES=$(mode_usage_bytes "$MODE" "$OFFSET_RX_BYTES" "$OFFSET_TX_BYTES")
    if boot_started_after_cycle_start; then
        if (( CURRENT_RX > OFFSET_RX_BYTES )); then
            OFFSET_RX_BYTES="$CURRENT_RX"
        fi
        if (( CURRENT_TX > OFFSET_TX_BYTES )); then
            OFFSET_TX_BYTES="$CURRENT_TX"
        fi
        OFFSET_BYTES=$(mode_usage_bytes "$MODE" "$OFFSET_RX_BYTES" "$OFFSET_TX_BYTES")
        log_msg "cycle floor applied on ${IFACE}, boot is inside ${CYCLE_KEY}, usage=${OFFSET_BYTES}, rx=${OFFSET_RX_BYTES}, tx=${OFFSET_TX_BYTES}"
    fi
    WARN_SENT=0
    TRIPPED=0
    USAGE_BYTES="$OFFSET_BYTES"
    save_state
    log_msg "new cycle ${CYCLE_KEY}, baseline reset on ${IFACE}, initial used ${OFFSET_BYTES} bytes, offset_rx=${OFFSET_RX_BYTES}, offset_tx=${OFFSET_TX_BYTES}"
    exit 0
fi

BASE_RX="${BASE_RX:-$CURRENT_RX}"
BASE_TX="${BASE_TX:-$CURRENT_TX}"
[[ "$BASE_RX" =~ ^[0-9]+$ ]] || BASE_RX="$CURRENT_RX"
[[ "$BASE_TX" =~ ^[0-9]+$ ]] || BASE_TX="$CURRENT_TX"
WARN_SENT="${WARN_SENT:-0}"
TRIPPED="${TRIPPED:-0}"
ensure_direction_offsets

if (( CURRENT_RX < BASE_RX || CURRENT_TX < BASE_TX )); then
    mapfile -t previous_direction_usage < <(direction_usage_at_last_check)
    OFFSET_RX_BYTES=$(( ${previous_direction_usage[0]:-0} + CURRENT_RX ))
    OFFSET_TX_BYTES=$(( ${previous_direction_usage[1]:-0} + CURRENT_TX ))
    OFFSET_BYTES=$(mode_usage_bytes "$MODE" "$OFFSET_RX_BYTES" "$OFFSET_TX_BYTES")
    BASE_RX="$CURRENT_RX"
    BASE_TX="$CURRENT_TX"
    WARN_SENT=0
    TRIPPED=0
    USAGE_BYTES="$OFFSET_BYTES"
    save_state
    log_msg "counter reset detected on ${IFACE}, baseline reset and preserved current counters, usage=${OFFSET_BYTES}, offset_rx=${OFFSET_RX_BYTES}, offset_tx=${OFFSET_TX_BYTES}"
    exit 0
fi

DELTA_RX=$(( CURRENT_RX - BASE_RX ))
DELTA_TX=$(( CURRENT_TX - BASE_TX ))
USAGE_RX_BYTES=$(( OFFSET_RX_BYTES + DELTA_RX ))
USAGE_TX_BYTES=$(( OFFSET_TX_BYTES + DELTA_TX ))
OFFSET_BYTES=$(mode_usage_bytes "$MODE" "$OFFSET_RX_BYTES" "$OFFSET_TX_BYTES")
USAGE_BYTES=$(mode_usage_bytes "$MODE" "$USAGE_RX_BYTES" "$USAGE_TX_BYTES")

if [[ "$TRIPPED" != "1" ]] && (( USAGE_BYTES * 100 >= LIMIT_BYTES * WARN_PERCENT )) && (( USAGE_BYTES < LIMIT_BYTES )) && [[ "$WARN_SENT" != "1" ]]; then
    WARN_SENT=1
    save_state
    log_msg "warning ${USAGE_BYTES}/${LIMIT_BYTES} bytes (${WARN_PERCENT}%) on ${IFACE}, mode=${MODE}"
    exit 0
fi

if (( USAGE_BYTES >= LIMIT_BYTES )); then
    TRIPPED=1
    save_state
    log_msg "quota reached ${USAGE_BYTES}/${LIMIT_BYTES} bytes on ${IFACE}, mode=${MODE}, action=${ACTION}"
    case "$ACTION" in
        log)
            exit 0
            ;;
        ssh-only)
            if ! apply_ssh_only_firewall; then
                TRIPPED=0
                save_state
                log_msg "ssh-only firewall action failed; will retry on next timer run"
            fi
            ;;
        poweroff|*)
            sync
            if systemctl poweroff >/dev/null 2>&1 || poweroff >/dev/null 2>&1 || shutdown -h now >/dev/null 2>&1; then
                log_msg "poweroff command accepted"
            else
                TRIPPED=0
                save_state
                log_msg "poweroff command failed; will retry on next timer run"
            fi
            ;;
    esac
fi

save_state
exit 0
GUARD_SCRIPT
    write_rc=$?
    if (( write_rc != 0 )); then
        traffic_guard_mark_checker_install_failure "io" "не удалось записать временный проверяющий файл" "$tmp_checker"
        rm -f "$tmp_checker" 2>/dev/null || true
        return 1
    fi
    if ! traffic_guard_normalize_generated_checker "$tmp_checker"; then
        traffic_guard_mark_checker_install_failure "generated-content" "не удалось нормализовать переносы или заголовок файла" "$tmp_checker"
        return 1
    fi
    IFS= read -r first_line < "$tmp_checker" || first_line=""
    if [[ "${first_line%$'\r'}" != "#!/usr/bin/env bash" ]]; then
        traffic_guard_mark_checker_install_failure "generated-content" "первая строка должна быть #!/usr/bin/env bash" "$tmp_checker"
        return 1
    fi
    if LC_ALL=C grep -q $'\r' "$tmp_checker"; then
        traffic_guard_mark_checker_install_failure "generated-content" "обнаружены символы CRLF/перевода каретки" "$tmp_checker"
        return 1
    fi
    if ! bash -n "$tmp_checker"; then
        traffic_guard_mark_checker_install_failure "generated-content" "синтаксическая проверка Bash не пройдена" "$tmp_checker"
        return 1
    fi
    if ! chmod 700 "$tmp_checker"; then
        traffic_guard_mark_checker_install_failure "io" "не удалось установить права chmod 700" "$tmp_checker"
        return 1
    fi
    if ! mv -f "$tmp_checker" "$TRAFFIC_GUARD_CHECKER"; then
        traffic_guard_mark_checker_install_failure "io" "не удалось заменить ${TRAFFIC_GUARD_CHECKER}" "$tmp_checker"
        return 1
    fi
    traffic_guard_admin_log "checker installed: ${TRAFFIC_GUARD_CHECKER}"
}

install_traffic_guard_checker() {
    local attempt
    for attempt in 1 2; do
        TRAFFIC_GUARD_CHECKER_INSTALL_FAILURE_KIND=""
        TRAFFIC_GUARD_CHECKER_INSTALL_FAILURE_FILE=""
        if traffic_guard_install_checker_once; then
            return 0
        fi
        if [[ "$attempt" == "1" ]] && traffic_guard_checker_install_failure_is_generated; then
            echo -e "${YELLOW}⚠️ Содержимое проверяющего скрипта некорректно, безопасная повторная установка...${PLAIN}"
            traffic_guard_admin_log "retry checker install once after generated content validation failure"
            continue
        fi
        return 1
    done
    return 1
}

reset_traffic_guard_failed_state() {
    systemctl reset-failed vps-traffic-guard.service vps-traffic-guard.timer >/dev/null 2>&1 || true
}

traffic_guard_state_epoch() {
    local checked_at
    checked_at=$(traffic_guard_state_last_checked_at 2>/dev/null) || { echo 0; return 0; }
    date -d "$checked_at" +%s 2>/dev/null || echo 0
}

traffic_guard_print_timer_failure_context() {
    echo -e "${YELLOW}▶ Диагностический контекст сбоя проверяющего скрипта/Timer Traffic Guard${PLAIN}"
    echo -e "checker : ${TRAFFIC_GUARD_CHECKER}"
    ls -l "$TRAFFIC_GUARD_CHECKER" 2>/dev/null || true
    echo -e "config  : ${TRAFFIC_GUARD_CONFIG}"
    ls -l "$TRAFFIC_GUARD_CONFIG" 2>/dev/null || true
    echo -e "state   : ${TRAFFIC_GUARD_STATE_DIR}/state"
    ls -l "${TRAFFIC_GUARD_STATE_DIR}/state" 2>/dev/null || true
    echo -e "${YELLOW}▶ systemd timer:${PLAIN}"
    systemctl status vps-traffic-guard.timer --no-pager -l 2>/dev/null || true
    systemctl list-timers --all vps-traffic-guard.timer --no-pager 2>/dev/null || true
    echo -e "${YELLOW}▶ systemd service:${PLAIN}"
    systemctl status vps-traffic-guard.service --no-pager -l 2>/dev/null || true
    echo -e "${YELLOW}▶ Последние журналы:${PLAIN}"
    journalctl -u vps-traffic-guard.service -u vps-traffic-guard.timer -n 80 --no-pager 2>/dev/null || true
    echo -e "${YELLOW}▶ Последние логи скрипта:${PLAIN}"
    traffic_guard_recent_log_summary 20
}

traffic_guard_install_checker_or_report() {
    install_traffic_guard_checker && return 0
    echo -e "${RED}❌ Не удалось установить проверяющий скрипт. Ниже контекст для диагностики:${PLAIN}"
    traffic_guard_print_timer_failure_context
    return 1
}

traffic_guard_run_checker_once() {
    local before_epoch after_epoch age rc=0 runner
    before_epoch=$(traffic_guard_state_epoch)
    runner="direct"

    if [[ ! -x "$TRAFFIC_GUARD_CHECKER" ]]; then
        echo -e "${RED}❌ Проверяющий скрипт не существует или неисполняем: ${TRAFFIC_GUARD_CHECKER}${PLAIN}"
        return 1
    fi

    reset_traffic_guard_failed_state
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files vps-traffic-guard.service --no-legend >/dev/null 2>&1; then
        runner="systemd"
        systemctl start vps-traffic-guard.service >/dev/null 2>&1 || rc=$?
    else
        /usr/bin/env bash "$TRAFFIC_GUARD_CHECKER" >/dev/null 2>&1 || rc=$?
    fi
    reset_traffic_guard_failed_state

    if (( rc != 0 )); then
        echo -e "${RED}❌ Попытка запуска проверяющего скрипта через ${runner} не удалась, rc=${rc}.${PLAIN}"
        return 1
    fi

    after_epoch=$(traffic_guard_state_epoch)
    age=$(traffic_guard_state_age_seconds 2>/dev/null || echo "")
    if [[ "$age" =~ ^[0-9]+$ && "$age" -le 120 ]]; then
        echo -e "${GREEN}✅ Проверяющий скрипт сразу выполнен, файл состояния обновлён.${PLAIN}"
        return 0
    fi
    if [[ "$after_epoch" =~ ^[0-9]+$ && "$before_epoch" =~ ^[0-9]+$ && "$after_epoch" -gt "$before_epoch" ]]; then
        echo -e "${GREEN}✅ Проверяющий скрипт сразу выполнен, время состояния обновлено.${PLAIN}"
        return 0
    fi

    echo -e "${RED}❌ Проверяющий скрипт выполнен, но файл состояния не обновлён.${PLAIN}"
    return 1
}

install_traffic_guard_units() {
    local interval="$1"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=60
    (( interval >= 30 )) || interval=30

    cat > /etc/systemd/system/vps-traffic-guard.service <<EOF
[Unit]
Description=VPS-Optimize traffic quota guard
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/env bash ${TRAFFIC_GUARD_CHECKER}
TimeoutStartSec=30
StandardOutput=journal
StandardError=journal
EOF

    cat > /etc/systemd/system/vps-traffic-guard.timer <<EOF
[Unit]
Description=Run VPS-Optimize traffic quota guard periodically

[Timer]
OnBootSec=1min
OnActiveSec=${interval}s
OnUnitActiveSec=${interval}s
AccuracySec=10s
Persistent=true
Unit=vps-traffic-guard.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || return 1
    reset_traffic_guard_failed_state
    systemctl enable --now vps-traffic-guard.timer >/dev/null 2>&1 || return 1
    reset_traffic_guard_failed_state
}

write_traffic_guard_config() {
    local iface="$1"
    local mode="$2"
    local limit_gb="$3"
    local limit_bytes="$4"
    local cycle_day="$5"
    local warn_percent="$6"
    local action="$7"
    local initial_used_gb="$8"
    local initial_used_bytes="$9"
    local interval="${10}"
    local ssh_port="${11:-}"

    mkdir -p "$(dirname "$TRAFFIC_GUARD_CONFIG")" || return 1
    cat > "$TRAFFIC_GUARD_CONFIG" <<EOF
# VPS-Optimize traffic quota guard
# Generated: $(date -Is 2>/dev/null || date)
ENABLED=1
IFACE='${iface}'
MODE='${mode}'
LIMIT_GB='${limit_gb}'
LIMIT_BYTES='${limit_bytes}'
CYCLE_DAY='${cycle_day}'
WARN_PERCENT='${warn_percent}'
ACTION='${action}'
SSH_PORT='${ssh_port}'
INITIAL_USED_GB='${initial_used_gb}'
INITIAL_USED_BYTES='${initial_used_bytes}'
CHECK_INTERVAL='${interval}'
EOF
    chmod 600 "$TRAFFIC_GUARD_CONFIG" 2>/dev/null || true
}

load_traffic_guard_config() {
    [[ -r "$TRAFFIC_GUARD_CONFIG" ]] || return 1
    # shellcheck disable=SC1090
    . "$TRAFFIC_GUARD_CONFIG"
}

traffic_guard_restore_ssh_only_firewall_from_config() {
    local config_path="${1:-$TRAFFIC_GUARD_CONFIG}"
    local configured_action
    [[ -r "$config_path" ]] || return 0
    configured_action=$(
        unset ACTION
        # shellcheck disable=SC1090
        . "$config_path" || exit 1
        printf '%s' "${ACTION:-poweroff}"
    ) || return 1
    [[ "$configured_action" == "ssh-only" ]] || return 0
    [[ -x "$TRAFFIC_GUARD_CHECKER" ]] || return 1
    VPSO_TRAFFIC_GUARD_CONFIG="$config_path" \
    VPSO_TRAFFIC_GUARD_STATE_DIR="$TRAFFIC_GUARD_STATE_DIR" \
    VPSO_TRAFFIC_GUARD_LOG="$TRAFFIC_GUARD_LOG" \
        /usr/bin/env bash "$TRAFFIC_GUARD_CHECKER" --restore-ssh-only-firewall
}

traffic_guard_restore_ssh_only_firewall() {
    traffic_guard_restore_ssh_only_firewall_from_config "$TRAFFIC_GUARD_CONFIG"
}

traffic_guard_usage_from_state() {
    local state_file="${TRAFFIC_GUARD_STATE_DIR}/state"
    [[ -r "$state_file" ]] || return 1
    # shellcheck disable=SC1090
    . "$state_file"
    printf '%s' "${LAST_USAGE:-0}"
}

traffic_guard_direction_usage_from_state() {
    local state_file="${TRAFFIC_GUARD_STATE_DIR}/state"
    local base_rx base_tx last_rx last_tx offset_rx offset_tx delta_rx=0 delta_tx=0
    [[ -r "$state_file" ]] || return 1
    # shellcheck disable=SC1090
    . "$state_file"
    base_rx="${BASE_RX:-0}"
    base_tx="${BASE_TX:-0}"
    last_rx="${LAST_RX:-$base_rx}"
    last_tx="${LAST_TX:-$base_tx}"
    offset_rx="${OFFSET_RX_BYTES:-}"
    offset_tx="${OFFSET_TX_BYTES:-}"
    [[ "$base_rx" =~ ^[0-9]+$ && "$base_tx" =~ ^[0-9]+$ ]] || return 1
    [[ "$last_rx" =~ ^[0-9]+$ && "$last_tx" =~ ^[0-9]+$ ]] || return 1
    [[ "$offset_rx" =~ ^[0-9]+$ && "$offset_tx" =~ ^[0-9]+$ ]] || return 1
    if (( last_rx >= base_rx )); then
        delta_rx=$(( last_rx - base_rx ))
    fi
    if (( last_tx >= base_tx )); then
        delta_tx=$(( last_tx - base_tx ))
    fi
    printf '%s %s\n' "$(( offset_rx + delta_rx ))" "$(( offset_tx + delta_tx ))"
}

traffic_guard_state_last_checked_at() {
    local state_file="${TRAFFIC_GUARD_STATE_DIR}/state"
    [[ -r "$state_file" ]] || return 1
    grep -m1 '^LAST_CHECKED_AT=' "$state_file" | cut -d= -f2- | sed "s/^'//;s/'$//"
}

traffic_guard_state_age_seconds() {
    local checked_at checked_epoch now_epoch
    checked_at=$(traffic_guard_state_last_checked_at) || return 1
    checked_epoch=$(date -d "$checked_at" +%s 2>/dev/null) || return 1
    now_epoch=$(date +%s 2>/dev/null) || return 1
    (( now_epoch >= checked_epoch )) || return 1
    printf '%s' "$(( now_epoch - checked_epoch ))"
}

traffic_guard_stale_threshold_seconds() {
    local interval="${CHECK_INTERVAL:-60}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=60
    (( interval >= 30 )) || interval=60
    local threshold=$(( interval * 3 ))
    (( threshold < 300 )) && threshold=300
    printf '%s' "$threshold"
}

traffic_guard_live_usage_from_state() {
    local state_file="${TRAFFIC_GUARD_STATE_DIR}/state"
    local current_stats current_rx current_tx base_rx base_tx offset_rx offset_tx
    local last_rx last_tx delta_rx=0 delta_tx=0 usage_rx usage_tx usage mode cycle_now
    mode="${MODE:-tx}"
    traffic_guard_valid_iface "${IFACE:-}" || return 1
    mapfile -t current_stats < <(traffic_guard_read_stats "$IFACE")
    current_rx="${current_stats[0]:-0}"
    current_tx="${current_stats[1]:-0}"
    [[ "$current_rx" =~ ^[0-9]+$ ]] || current_rx=0
    [[ "$current_tx" =~ ^[0-9]+$ ]] || current_tx=0

    if [[ ! -r "$state_file" ]]; then
        usage=$(traffic_guard_mode_usage_bytes "$mode" "$current_rx" "$current_tx")
        printf '%s %s %s\n' "$usage" "$current_rx" "$current_tx"
        return 0
    fi

    # shellcheck disable=SC1090
    . "$state_file"
    cycle_now=$(traffic_guard_current_cycle_key "${CYCLE_DAY:-1}")
    if [[ "${STATE_IFACE:-$IFACE}" != "$IFACE" || "${STATE_MODE:-$mode}" != "$mode" ]]; then
        usage=$(traffic_guard_mode_usage_bytes "$mode" "$current_rx" "$current_tx")
        printf '%s %s %s\n' "$usage" "$current_rx" "$current_tx"
        return 0
    fi
    if [[ "${CYCLE_KEY:-}" != "$cycle_now" ]]; then
        if traffic_guard_boot_started_after_cycle_start "$cycle_now"; then
            usage=$(traffic_guard_mode_usage_bytes "$mode" "$current_rx" "$current_tx")
            printf '%s %s %s\n' "$usage" "$current_rx" "$current_tx"
        else
            printf '0 0 0\n'
        fi
        return 0
    fi

    base_rx="${BASE_RX:-$current_rx}"
    base_tx="${BASE_TX:-$current_tx}"
    offset_rx="${OFFSET_RX_BYTES:-}"
    offset_tx="${OFFSET_TX_BYTES:-}"
    if [[ ! "$offset_rx" =~ ^[0-9]+$ || ! "$offset_tx" =~ ^[0-9]+$ ]]; then
        local legacy_offset offset_stats
        legacy_offset="${OFFSET_BYTES:-${LAST_USAGE:-0}}"
        [[ "$legacy_offset" =~ ^[0-9]+$ ]] || legacy_offset=0
        mapfile -t offset_stats < <(traffic_guard_baseline_direction_offsets "$mode" "$base_rx" "$base_tx" "$legacy_offset")
        offset_rx="${offset_stats[0]:-0}"
        offset_tx="${offset_stats[1]:-0}"
    fi

    if [[ "$base_rx" =~ ^[0-9]+$ && "$base_tx" =~ ^[0-9]+$ ]] && (( current_rx >= base_rx && current_tx >= base_tx )); then
        delta_rx=$(( current_rx - base_rx ))
        delta_tx=$(( current_tx - base_tx ))
        usage_rx=$(( offset_rx + delta_rx ))
        usage_tx=$(( offset_tx + delta_tx ))
    else
        last_rx="${LAST_RX:-$base_rx}"
        last_tx="${LAST_TX:-$base_tx}"
        [[ "$last_rx" =~ ^[0-9]+$ ]] || last_rx="$base_rx"
        [[ "$last_tx" =~ ^[0-9]+$ ]] || last_tx="$base_tx"
        if [[ "$base_rx" =~ ^[0-9]+$ && "$last_rx" =~ ^[0-9]+$ ]] && (( last_rx >= base_rx )); then
            delta_rx=$(( last_rx - base_rx ))
        fi
        if [[ "$base_tx" =~ ^[0-9]+$ && "$last_tx" =~ ^[0-9]+$ ]] && (( last_tx >= base_tx )); then
            delta_tx=$(( last_tx - base_tx ))
        fi
        usage_rx=$(( offset_rx + delta_rx + current_rx ))
        usage_tx=$(( offset_tx + delta_tx + current_tx ))
    fi

    usage=$(traffic_guard_mode_usage_bytes "$mode" "$usage_rx" "$usage_tx")
    printf '%s %s %s\n' "$usage" "$usage_rx" "$usage_tx"
}

traffic_guard_recent_log_summary() {
    local lines="${1:-5}"

    [[ "$lines" =~ ^[0-9]+$ ]] || lines=5
    (( lines > 0 )) || lines=5

    if [[ ! -r "$TRAFFIC_GUARD_LOG" ]]; then
        echo "Логов пока нет"
        return 0
    fi

    if declare -F redact_sensitive_output >/dev/null; then
        tail -n "$lines" "$TRAFFIC_GUARD_LOG" 2>/dev/null | redact_sensitive_output
    else
        tail -n "$lines" "$TRAFFIC_GUARD_LOG" 2>/dev/null
    fi
}

print_traffic_guard_diagnostic_summary() {
    local log_lines="${1:-5}"
    local show_unconfigured="${2:-yes}"
    local state_file="${TRAFFIC_GUARD_STATE_DIR}/state"
    local timer_active timer_enabled has_config has_state has_log usage source_usage live_rx live_tx
    local limit pct mode_label state_age stale_threshold last_checked state_status config_status log_status
    local ENABLED IFACE MODE LIMIT_GB LIMIT_BYTES CYCLE_DAY WARN_PERCENT ACTION INITIAL_USED_GB INITIAL_USED_BYTES CHECK_INTERVAL

    [[ "$log_lines" =~ ^[0-9]+$ ]] || log_lines=5
    (( log_lines >= 0 )) || log_lines=5

    timer_active=$(systemctl is-active vps-traffic-guard.timer 2>/dev/null || true)
    timer_enabled=$(systemctl is-enabled vps-traffic-guard.timer 2>/dev/null || true)
    timer_active=${timer_active:-inactive}
    timer_enabled=${timer_enabled:-disabled}
    [[ -r "$TRAFFIC_GUARD_CONFIG" ]] && has_config="yes" || has_config="no"
    [[ -r "$state_file" ]] && has_state="yes" || has_state="no"
    [[ -r "$TRAFFIC_GUARD_LOG" ]] && has_log="yes" || has_log="no"

    if [[ "$has_config" == "no" && "$has_state" == "no" && "$has_log" == "no" && "$timer_active" != "active" && "$timer_enabled" == "disabled" ]]; then
        [[ "$show_unconfigured" == "yes" ]] && echo "Сводка защиты от превышения трафика: не настроена"
        return 0
    fi

    echo "Сводка защиты от превышения трафика:"
    echo "- timer: vps-traffic-guard.timer active=${timer_active}; enabled=${timer_enabled}"
    config_status="не читается или отсутствует"
    state_status="не читается или отсутствует"
    log_status="не читается или отсутствует"
    [[ "$has_config" == "yes" ]] && config_status="существует"
    [[ "$has_state" == "yes" ]] && state_status="существует"
    [[ "$has_log" == "yes" ]] && log_status="существует"
    echo "- Файл конфигурации: ${TRAFFIC_GUARD_CONFIG} (${config_status})"
    echo "- Файл состояния: ${state_file} (${state_status})"
    echo "- Файл лога: ${TRAFFIC_GUARD_LOG} (${log_status})"

    if [[ "$has_config" != "yes" ]]; then
        echo "- Текущая конфигурация: не настроена или не читается"
    else
        # shellcheck disable=SC1090
        . "$TRAFFIC_GUARD_CONFIG"
        limit="${LIMIT_BYTES:-0}"
        if read -r usage live_rx live_tx < <(traffic_guard_live_usage_from_state 2>/dev/null); then
            source_usage="текущая оценка"
        else
            usage=$(traffic_guard_usage_from_state 2>/dev/null || echo 0)
            live_rx=""
            live_tx=""
            source_usage="последнее состояние"
        fi
        [[ "$usage" =~ ^[0-9]+$ ]] || usage=0
        [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
        if (( limit > 0 )); then
            pct=$(awk -v u="$usage" -v l="$limit" 'BEGIN { printf "%.2f", (u/l)*100 }')
            mode_label=$(traffic_guard_mode_label "${MODE:-tx}")
            echo "- Текущая конфигурация: ENABLED=${ENABLED:-0}; режим=${mode_label}; действие=$(traffic_guard_action_label "${ACTION:-poweroff}"); интервал=${CHECK_INTERVAL:-60}s"
            echo "- ${source_usage}: $(traffic_guard_human_bytes "$usage") / $(traffic_guard_human_bytes "$limit") (${pct}%)"
        else
            echo "- Текущая конфигурация: ENABLED=${ENABLED:-0}; режим=$(traffic_guard_mode_label "${MODE:-tx}"); порог не установлен или недействителен"
        fi
        if [[ "$live_rx" =~ ^[0-9]+$ && "$live_tx" =~ ^[0-9]+$ ]]; then
            echo "- Оценка по направлениям: RX $(traffic_guard_human_bytes "$live_rx") / TX $(traffic_guard_human_bytes "$live_tx")"
        fi
    fi

    if [[ "$has_state" == "yes" ]]; then
        last_checked=$(traffic_guard_state_last_checked_at 2>/dev/null || echo "неизвестно")
        state_age=$(traffic_guard_state_age_seconds 2>/dev/null || echo "")
        stale_threshold=$(traffic_guard_stale_threshold_seconds)
        if [[ "$state_age" =~ ^[0-9]+$ ]]; then
            echo "- Последняя проверка: ${last_checked} (${state_age}s назад; порог устаревания ${stale_threshold}s)"
            if (( state_age > stale_threshold )); then
                if [[ "$timer_active" == "active" ]]; then
                    echo "- Аномалия: последняя проверка устарела, состояние не обновлялось ${state_age}s, хотя timer active, проверьте логи или используйте меню [10] -> [5] -> [6] для исправления timer"
                else
                    echo "- Аномалия: последняя проверка устарела, состояние не обновлялось ${state_age}s, timer в состоянии ${timer_active}"
                fi
            fi
        else
            echo "- Последняя проверка: ${last_checked}"
        fi
    else
        echo "- Последняя проверка: файл состояния ещё не создан"
    fi

    if (( log_lines > 0 )); then
        echo "- Последние логи vps-traffic-guard:"
        traffic_guard_recent_log_summary "$log_lines" | sed 's/^/  /'
    fi
}

show_traffic_guard_status() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Сеть/оптимизация ядра > Защита от превышения трафика"
    echo -e "${BOLD}🧯 Статус защиты от превышения трафика${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    if ! load_traffic_guard_config; then
        echo -e "${YELLOW}Защита от превышения трафика не настроена.${PLAIN}"
        echo -e "${BLUE}Рекомендуется сначала выбрать [1] для настройки, чтобы избежать превышения лимита и больших счетов.${PLAIN}"
        return 0
    fi

    local timer_state service_state usage limit pct cycle_key state_file current_stats current_rx current_tx
    local live_usage live_rx live_tx state_usage state_age stale_threshold last_checked
    timer_state=$(systemctl is-active vps-traffic-guard.timer 2>/dev/null || echo "inactive")
    service_state=$(systemctl is-enabled vps-traffic-guard.timer 2>/dev/null || echo "disabled")
    state_usage=$(traffic_guard_usage_from_state 2>/dev/null || echo 0)
    if read -r live_usage live_rx live_tx < <(traffic_guard_live_usage_from_state 2>/dev/null); then
        usage="$live_usage"
    else
        usage="$state_usage"
        live_rx=""
        live_tx=""
    fi
    limit="${LIMIT_BYTES:-0}"
    if [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]]; then
        pct=$(awk -v u="$usage" -v l="$limit" 'BEGIN { printf "%.2f", (u/l)*100 }')
    else
        pct="0.00"
    fi
    cycle_key=$(traffic_guard_current_cycle_key "${CYCLE_DAY:-1}")

    echo -e "Статус включения : ${GREEN}${ENABLED:-0}${PLAIN}  timer: ${timer_state}/${service_state}"
    echo -e "Мониторинг интерфейса : ${CYAN}${IFACE:-неизвестно}${PLAIN}"
    echo -e "Режим учёта : ${CYAN}$(traffic_guard_mode_label "${MODE:-tx}")${PLAIN}"
    echo -e "Текущий период : ${CYAN}${cycle_key}${PLAIN} (сброс ${CYCLE_DAY:-1}-го числа каждого месяца, в коротких месяцах — последний день)"
    echo -e "Порог : ${YELLOW}${LIMIT_GB:-неизвестно} ГБ${PLAIN} ($(traffic_guard_human_bytes "$limit"))"
    echo -e "Действие при превышении : ${RED}$(traffic_guard_action_label "${ACTION:-poweroff}")${PLAIN}"
    if [[ "${ACTION:-}" == "ssh-only" ]]; then
        echo -e "Оставить SSH : ${CYAN}${SSH_PORT:-неизвестно}/tcp${PLAIN}; в следующем периоде блокировка будет автоматически снята"
    fi
    echo -e "Использовано в текущем периоде : ${GREEN}$(traffic_guard_human_bytes "$usage")${PLAIN} / ${pct}% (оценка по базе и начальному использованию)"
    if [[ "$state_usage" =~ ^[0-9]+$ && "$state_usage" != "$usage" ]]; then
        echo -e "Запись состояния : ${YELLOW}$(traffic_guard_human_bytes "$state_usage")${PLAIN} (записано при последней проверке)"
    fi
    if [[ "$live_rx" =~ ^[0-9]+$ && "$live_tx" =~ ^[0-9]+$ ]]; then
        echo -e "По направлениям в текущем периоде : RX ${CYAN}$(traffic_guard_human_bytes "$live_rx")${PLAIN} / TX ${CYAN}$(traffic_guard_human_bytes "$live_tx")${PLAIN} (с учётом базы и начального использования)"
    fi
    echo -e "Уровень предупреждения : ${WARN_PERCENT:-90}%   Действие: ${ACTION:-poweroff}"
    if traffic_guard_valid_iface "${IFACE:-}"; then
        mapfile -t current_stats < <(traffic_guard_read_stats "$IFACE")
        current_rx="${current_stats[0]:-0}"
        current_tx="${current_stats[1]:-0}"
        echo -e "Сырые счётчики интерфейса : RX ${CYAN}$(traffic_guard_human_bytes "$current_rx")${PLAIN} / TX ${CYAN}$(traffic_guard_human_bytes "$current_tx")${PLAIN} (накоплено с запуска, НЕ равно использованию в текущем периоде)"
        echo -e "${BLUE}Пояснение: срабатывание защиты оценивается только по "использованию в текущем периоде"; сырые счётчики используются для вычисления разницы и могут быть значительно больше при долгом времени работы.${PLAIN}"
    fi
    echo -e "Файл конфигурации : ${CYAN}${TRAFFIC_GUARD_CONFIG}${PLAIN}"
    echo -e "Файл лога : ${CYAN}${TRAFFIC_GUARD_LOG}${PLAIN}"

    state_file="${TRAFFIC_GUARD_STATE_DIR}/state"
    if [[ -r "$state_file" ]]; then
        last_checked=$(traffic_guard_state_last_checked_at 2>/dev/null || echo "неизвестно")
        echo -e "Последняя проверка : ${CYAN}${last_checked}${PLAIN}"
        state_age=$(traffic_guard_state_age_seconds 2>/dev/null || echo "")
        stale_threshold=$(traffic_guard_stale_threshold_seconds)
        if [[ "$state_age" =~ ^[0-9]+$ && "$state_age" -gt "$stale_threshold" ]]; then
            echo -e "${RED}Аномалия : последняя проверка была более ${state_age} секунд назад, даже если timer показывает active — это не гарантирует, что проверяющий скрипт действительно обновляет состояние. Используйте пункт [7] для немедленной синхронизации/проверки; если не удаётся — [6] для переустановки timer.${PLAIN}"
        fi
    else
        echo -e "${YELLOW}Файл состояния ещё не создан, после первого запуска timer создаст базовую линию.${PLAIN}"
    fi
}

sync_traffic_guard_now() {
    load_traffic_guard_config || {
        echo -e "${YELLOW}Защита от превышения трафика не настроена.${PLAIN}"
        pause_return
        return 1
    }

    if [[ "${ACTION:-poweroff}" == "poweroff" ]]; then
        confirm_danger "Немедленный запуск проверяющего скрипта трафика" \
            "Будет считан трафик ${IFACE:-текущего интерфейса} и обновлён ${TRAFFIC_GUARD_STATE_DIR}/state; если порог превышен, будет выполнено действие в соответствии с конфигурацией (например, выключение)." \
            "Если просто timer не обновлял состояние, после сбоя синхронизации можно посмотреть диагностику и переустановить timer; если порог настроен неверно, сначала отключите защиту или сбросьте базовую линию." \
            "Если текущее использование ниже порога — это самый прямой способ синхронизации; при приближении к порогу сначала проверьте статистику в панели облачного провайдера." || return 1
    else
        confirm_risk_action "Немедленный запуск проверяющего скрипта трафика" \
            "Будет считан трафик ${IFACE:-текущего интерфейса} и обновлён ${TRAFFIC_GUARD_STATE_DIR}/state." \
            "При сбое синхронизации посмотрите диагностику или переустановите timer." \
            "Текущее действие: ${ACTION:-log}, при достижении порога будет выполнено только соответствующее действие." || return 1
    fi

    echo -e "${CYAN}▶ Немедленный запуск vps-traffic-guard-check и проверка обновления состояния...${PLAIN}"
    if traffic_guard_run_checker_once; then
        show_traffic_guard_status
        return 0
    fi
    traffic_guard_print_timer_failure_context
    return 1
}

configure_traffic_guard() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Сеть/оптимизация ядра > Настройка защиты от превышения трафика"
    echo -e "${BOLD}🧯 Настройка защиты от превышения трафика${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: периодическое чтение трафика интерфейса, при достижении порога — автоматическое выключение для предотвращения превышения лимита и больших счетов.${PLAIN}"
    echo -e "${YELLOW}Внимание: скрипт оценивает трафик по счётчикам локального интерфейса; статистика облачного провайдера может иметь задержки или отличаться, оставляйте запас.${PLAIN}"
    echo -e "------------------------------------------------"

    local default_iface iface limit_gb limit_bytes initial_used_gb initial_used_bytes
    local cycle_day cycle_default_day warn_percent action_choice action mode_choice mode interval ssh_port=""
    local current_stats current_rx current_tx detected_used_bytes detected_used_gb existing_used_bytes
    default_iface=$(traffic_guard_detect_iface)
    iface=$(ask_with_default "Мониторинг интерфейса (автоматически определяется активный публичный интерфейс)" "${default_iface:-eth0}")
    if ! traffic_guard_valid_iface "$iface"; then
        echo -e "${RED}❌ Интерфейс ${iface} не существует или не удаётся прочитать статистику.${PLAIN}"
        pause_return
        return 1
    fi
    mapfile -t current_stats < <(traffic_guard_read_stats "$iface")
    current_rx="${current_stats[0]:-0}"
    current_tx="${current_stats[1]:-0}"
    echo -e "${GREEN}✅ Выбран интерфейс: ${iface}${PLAIN}"
    echo -e "Текущие сырые счётчики интерфейса (накоплены с запуска, используются только для построения базовой линии): RX ${CYAN}$(traffic_guard_human_bytes "$current_rx")${PLAIN} / TX ${CYAN}$(traffic_guard_human_bytes "$current_tx")${PLAIN}"
    echo -e "${YELLOW}Пояснение: система может читать только локальные счётчики; после настройки будет построена базовая линия от текущих значений. Статистика облачного провайдера может отличаться, ориентируйтесь на панель провайдера и оставляйте запас.${PLAIN}"

    while true; do
        limit_gb=$(ask_with_default "Порог трафика за период в ГБ (рекомендуется 80%-95% от лимита тарифа)" "900")
        if limit_bytes=$(traffic_guard_gb_to_bytes "$limit_gb" 2>/dev/null); then
            break
        fi
        echo -e "${RED}❌ Неверный порог, введите число >0, например 900 или 0.5.${PLAIN}"
    done

    while true; do
        cycle_default_day=$(date +%d)
        cycle_default_day=$((10#$cycle_default_day))
        cycle_day=$(ask_with_default "День сброса периода 1-31 (в коротких месяцах — последний день)" "$cycle_default_day")
        if [[ "$cycle_day" =~ ^[0-9]+$ ]] && (( 10#$cycle_day >= 1 && 10#$cycle_day <= 31 )); then
            break
        fi
        echo -e "${RED}❌ День сброса должен быть 1-31.${PLAIN}"
    done

    echo -e "Режим учёта:"
    echo -e "  1. Исходящий TX"
    echo -e "  2. Общий RX+TX"
    echo -e "  3. Любое направление"
    echo -e "  4. Входящий RX"
    read_trimmed mode_choice "Выберите режим учёта (по умолчанию 1): "
    case "${mode_choice:-1}" in
        2) mode="total" ;;
        3) mode="max" ;;
        4) mode="rx" ;;
        *) mode="tx" ;;
    esac

    detected_used_bytes=$(traffic_guard_detect_initial_used_bytes "$iface" "$mode" "$cycle_day")
    detected_used_gb=$(traffic_guard_bytes_to_gb "$detected_used_bytes")
    existing_used_bytes=$(traffic_guard_existing_state_usage "$iface" "$mode" "$cycle_day" 2>/dev/null || true)
    if [[ "$existing_used_bytes" =~ ^[0-9]+$ && "$existing_used_bytes" != "$detected_used_bytes" ]]; then
        echo -e "Обнаружено существующее состояние защиты: ${YELLOW}$(traffic_guard_human_bytes "$existing_used_bytes")${PLAIN}"
        echo -e "${YELLOW}При повторной настройке по умолчанию используется оценка на основе текущих сырых счётчиков; базовая линия будет сброшена, чтобы не вводить в заблуждение.${PLAIN}"
    fi
    echo -e "Начальное использование по умолчанию оценивается по текущим счётчикам и выбранному режиму: ${CYAN}$(traffic_guard_human_bytes "$detected_used_bytes")${PLAIN} (можно просто нажать Enter)"
    echo -e "${YELLOW}Если в панели провайдера отображается другая цифра, вручную укажите значение в ГБ.${PLAIN}"
    while true; do
        initial_used_gb=$(ask_with_default "Использовано в текущем периоде (ГБ)" "$detected_used_gb")
        if initial_used_bytes=$(traffic_guard_gb_to_bytes_zero_ok "$initial_used_gb" 2>/dev/null); then
            break
        fi
        echo -e "${RED}❌ Неверное использование, введите число >=0.${PLAIN}"
    done

    while true; do
        warn_percent=$(ask_with_default "Процент предупреждения 1-99" "90")
        if [[ "$warn_percent" =~ ^[0-9]+$ ]] && (( 10#$warn_percent >= 1 && 10#$warn_percent <= 99 )); then
            break
        fi
        echo -e "${RED}❌ Неверный процент предупреждения.${PLAIN}"
    done

    interval=$(ask_with_default "Интервал проверки в секундах (минимум 30, по умолчанию 60)" "60")
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( 10#$interval < 30 )); then
        interval=60
    fi

    echo -e "Действие при срабатывании:"
    echo -e "  1. Немедленное выключение ${YELLOW}(предотвращение дальнейшего трафика)${PLAIN}"
    echo -e "  2. Оставить только SSH порт ${YELLOW}(заблокировать остальной публичный трафик, автоматическое восстановление в день сброса)${PLAIN}"
    echo -e "  3. Только запись в лог ${YELLOW}(тестовый режим)${PLAIN}"
    read_trimmed action_choice "Выберите действие (по умолчанию 1): "
    case "${action_choice:-1}" in
        2)
            traffic_guard_ssh_only_firewall_supported || {
                echo -e "${RED}❌ Отсутствует iptables, или при включённом IPv6 отсутствует ip6tables, невозможно безопасно включить режим "только SSH".${PLAIN}"
                pause_return
                return 1
            }
            ssh_port=$(traffic_guard_detect_ssh_port) || {
                echo -e "${RED}❌ Не удалось определить уникальный прослушиваемый SSH-порт, невозможно безопасно включить режим "только SSH".${PLAIN}"
                pause_return
                return 1
            }
            action="ssh-only"
            ;;
        3) action="log" ;;
        *) action="poweroff" ;;
    esac

    echo -e "------------------------------------------------"
    echo -e "Интерфейс: ${CYAN}${iface}${PLAIN}"
    echo -e "Порог: ${YELLOW}${limit_gb}ГБ${PLAIN}, начальное использование в периоде: ${initial_used_gb}ГБ"
    echo -e "Режим: ${CYAN}$(traffic_guard_mode_label "$mode")${PLAIN}"
    echo -e "Период: сброс ${cycle_day}-го числа каждого месяца (в коротких месяцах последний день); интервал: ${interval}с; предупреждение: ${warn_percent}%"
    echo -e "Действие: ${RED}$(traffic_guard_action_label "$action")${PLAIN}"
    [[ "$action" == "ssh-only" ]] && echo -e "Оставляется SSH: ${CYAN}${ssh_port}/tcp${PLAIN}; остальной публичный трафик временно блокируется, необходимый управляющий сетевой трафик сохраняется."

    if [[ "$action" == "poweroff" ]]; then
        confirm_danger "Включить автоматическое выключение при превышении трафика" \
            "Установка systemd timer vps-traffic-guard; при достижении порога выполняется systemctl poweroff." \
            "Вручную включите сервер через консоль провайдера; после включения настройте порог, сбросьте базовую линию или отключите защиту в этом меню." \
            "Рекомендуется устанавливать порог ниже лимита тарифа и проверять статистику в панели провайдера." || return 1
    elif [[ "$action" == "ssh-only" ]]; then
        confirm_danger "Включить режим "только SSH" при превышении" \
            "При достижении порога оставляется только SSH-порт ${ssh_port}/tcp и необходимый управляющий трафик; остальной публичный трафик блокируется." \
            "Блокировка автоматически снимается в день сброса тарифа; также можно сбросить базовую линию или отключить защиту в этом меню для немедленного снятия." \
            "SSH-порт должен быть доступен; если группа безопасности облака или служба SSH недоступны, вход может быть невозможен." || return 1
    fi

    traffic_guard_restore_ssh_only_firewall || {
        echo -e "${RED}❌ Не удалось снять блокировку "только SSH" с предыдущего периода, переконфигурация отменена.${PLAIN}"
        pause_return
        return 1
    }

    write_traffic_guard_config "$iface" "$mode" "$limit_gb" "$limit_bytes" "$cycle_day" "$warn_percent" "$action" "$initial_used_gb" "$initial_used_bytes" "$interval" "$ssh_port" || {
        echo -e "${RED}❌ Ошибка записи конфигурации.${PLAIN}"
        pause_return
        return 1
    }
    traffic_guard_install_checker_or_report || {
        pause_return
        return 1
    }
    traffic_guard_write_state_baseline "$iface" "$cycle_day" "$initial_used_bytes" "$mode" || {
        echo -e "${RED}❌ Ошибка записи базовой линии защиты трафика.${PLAIN}"
        pause_return
        return 1
    }
    install_traffic_guard_units "$interval" || {
        echo -e "${RED}❌ Ошибка включения systemd timer, проверьте состояние systemd.${PLAIN}"
        pause_return
        return 1
    }

    /usr/bin/env bash "$TRAFFIC_GUARD_CHECKER" >/dev/null 2>&1 || true
    reset_traffic_guard_failed_state
    echo -e "${GREEN}✅ Защита от превышения трафика включена.${PLAIN}"
    echo -e "${YELLOW}Статус можно посмотреть в этом меню [2]; лог: ${TRAFFIC_GUARD_LOG}${PLAIN}"
    pause_return
}

reset_traffic_guard_baseline() {
    local iface mode cycle_day initial_used_gb initial_used_bytes
    local detected_used_bytes detected_used_gb
    load_traffic_guard_config || {
        echo -e "${YELLOW}Защита от превышения трафика не настроена.${PLAIN}"
        pause_return
        return 1
    }
    iface="${IFACE:-}"
    mode="${MODE:-tx}"
    cycle_day="${CYCLE_DAY:-1}"
    traffic_guard_valid_iface "$iface" || {
        echo -e "${RED}❌ Настроенный интерфейс ${iface} не доступен для чтения.${PLAIN}"
        pause_return
        return 1
    }
    detected_used_bytes=$(traffic_guard_detect_initial_used_bytes "$iface" "$mode" "$cycle_day")
    detected_used_gb=$(traffic_guard_bytes_to_gb "$detected_used_bytes")
    echo -e "Начальное использование по умолчанию оценивается по текущим счётчикам и режиму: ${CYAN}$(traffic_guard_human_bytes "$detected_used_bytes")${PLAIN}"
    initial_used_gb=$(ask_with_default "Использовано в текущем периоде после сброса (ГБ)" "$detected_used_gb")
    if ! initial_used_bytes=$(traffic_guard_gb_to_bytes_zero_ok "$initial_used_gb" 2>/dev/null); then
        echo -e "${RED}❌ Неверное использование.${PLAIN}"
        pause_return
        return 1
    fi
    confirm_risk_action "Сбросить базовую линию защиты трафика" \
        "Статистика текущего периода будет пересчитана от текущих счётчиков, начальное использование установлено в ${initial_used_gb} ГБ." \
        "Вернитесь в это меню и снова сбросьте базовую линию, или скорректируйте использование вручную по данным облачного провайдера." \
        "Выполняйте только в начале периода биллинга, после настройки или при подтверждении статистики провайдера." || return 1

    traffic_guard_restore_ssh_only_firewall || {
        echo -e "${RED}❌ Не удалось снять блокировку "только SSH", статистика не сброшена.${PLAIN}"
        pause_return
        return 1
    }
    traffic_guard_write_state_baseline "$iface" "$cycle_day" "$initial_used_bytes" "$mode" || {
        echo -e "${RED}❌ Ошибка записи базовой линии защиты трафика.${PLAIN}"
        pause_return
        return 1
    }
    echo -e "${GREEN}✅ Базовая линия трафика для ${iface} сброшена.${PLAIN}"
    echo -e "Текущий режим: ${CYAN}$(traffic_guard_mode_label "$mode")${PLAIN}; использовано в периоде: $(traffic_guard_human_bytes "$initial_used_bytes")"
    pause_return
}

repair_traffic_guard_timer() {
    local interval
    load_traffic_guard_config || {
        echo -e "${YELLOW}Защита от превышения трафика не настроена.${PLAIN}"
        pause_return
        return 1
    }
    interval="${CHECK_INTERVAL:-60}"
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( 10#$interval < 30 )); then
        interval=60
    fi

    if [[ "${ACTION:-poweroff}" == "poweroff" ]]; then
        confirm_danger "Восстановить автоматический проверяющий timer защиты трафика" \
            "Будет переустановлен vps-traffic-guard-check и systemd timer, после восстановления проверка будет выполняться каждые ${interval}с." \
            "Если текущая оценка уже достигла порога, следующая проверка может выполнить systemctl poweroff." \
            "Сначала убедитесь в статистике облачного провайдера, пороге и способе восстановления через SSH/консоль." || return 1
    else
        confirm_risk_action "Восстановить автоматический проверяющий timer защиты трафика" \
            "Будет переустановлен vps-traffic-guard-check и systemd timer, после восстановления проверка будет выполняться каждые ${interval}с." \
            "Текущее действие: ${ACTION:-log}, при достижении порога будет выполнено только соответствующее действие." \
            "После восстановления проверьте страницу состояния, чтобы убедиться, что время последней проверки обновляется." || return 1
    fi

    traffic_guard_install_checker_or_report || {
        pause_return
        return 1
    }
    install_traffic_guard_units "$interval" || {
        echo -e "${RED}❌ Ошибка включения systemd timer, проверьте состояние systemd.${PLAIN}"
        pause_return
        return 1
    }
    systemctl restart vps-traffic-guard.timer >/dev/null 2>&1 || true
    reset_traffic_guard_failed_state
    echo -e "${GREEN}✅ vps-traffic-guard.timer переустановлен и перезапущен.${PLAIN}"
    echo -e "${CYAN}▶ Немедленный запуск проверяющего скрипта для проверки обновления файла состояния...${PLAIN}"
    if traffic_guard_run_checker_once; then
        echo -e "${GREEN}✅ Timer переустановлен, проверяющий скрипт может обновлять состояние.${PLAIN}"
    else
        echo -e "${RED}❌ Timer переустановлен, но проверяющий скрипт всё ещё не обновляет состояние. Ниже контекст для диагностики:${PLAIN}"
        traffic_guard_print_timer_failure_context
        pause_return
        return 1
    fi
    echo -e "${YELLOW}Затем вернитесь в [2] для просмотра состояния; если оно снова устареет, используйте [7] для немедленной проверки скрипта.${PLAIN}"
    systemctl list-timers --all vps-traffic-guard.timer --no-pager 2>/dev/null || true
    pause_return
}

disable_traffic_guard() {
    if ! systemctl list-unit-files vps-traffic-guard.timer >/dev/null 2>&1 && [[ ! -f "$TRAFFIC_GUARD_CONFIG" ]]; then
        echo -e "${YELLOW}Конфигурация защиты трафика не обнаружена.${PLAIN}"
        pause_return
        return 0
    fi
    confirm_risk_action "Отключить защиту от превышения трафика" \
        "vps-traffic-guard.timer будет остановлен, при достижении порога действие выполняться не будет." \
        "Снова включите защиту через [1] в этом меню." \
        "После отключения самостоятельно следите за трафиком через облачного провайдера, чтобы избежать превышения лимита." || return 1
    traffic_guard_restore_ssh_only_firewall || {
        echo -e "${RED}❌ Не удалось снять блокировку "только SSH", защита не отключена.${PLAIN}"
        pause_return
        return 1
    }
    systemctl disable --now vps-traffic-guard.timer >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    reset_traffic_guard_failed_state
    if [[ -f "$TRAFFIC_GUARD_CONFIG" ]]; then
        sed -i 's/^ENABLED=.*/ENABLED=0/' "$TRAFFIC_GUARD_CONFIG" 2>/dev/null || true
    fi
    echo -e "${GREEN}✅ Защита от превышения трафика отключена, файл конфигурации сохранён: ${TRAFFIC_GUARD_CONFIG}${PLAIN}"
    pause_return
}

func_traffic_guard_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Сеть/оптимизация ядра > Защита от превышения трафика"
        echo -e "${BOLD}🧯 Защита от превышения трафика${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}При достижении безопасного порога тарифа можно автоматически выключить сервер или оставить только SSH, чтобы предотвратить огромные счета.${PLAIN}"
        echo -e "${YELLOW}Рекомендуется устанавливать порог ниже лимита тарифа и использовать консервативный режим (исходящий или общий).${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Настроить / включить защиту${PLAIN}"
        echo -e "${GREEN}  2. Просмотреть статус и использованный трафик${PLAIN}"
        echo -e "${GREEN}  3. Сбросить базовую линию статистики текущего периода${PLAIN}"
        echo -e "${YELLOW}  4. Отключить защиту${PLAIN}"
        echo -e "${GREEN}  5. Просмотреть последние логи${PLAIN}"
        echo -e "${GREEN}  6. Восстановить/переустановить автоматический timer проверки${PLAIN}"
        echo -e "${GREEN}  7. Немедленная синхронизация/проверка${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1) configure_traffic_guard ;;
            2) show_traffic_guard_status; pause_return ;;
            3) reset_traffic_guard_baseline ;;
            4) disable_traffic_guard ;;
            5)
                echo -e "${CYAN}--- ${TRAFFIC_GUARD_LOG} ---${PLAIN}"
                tail -n 30 "$TRAFFIC_GUARD_LOG" 2>/dev/null || echo "Логов пока нет"
                pause_return
                ;;
            6) repair_traffic_guard_timer ;;
            7) sync_traffic_guard_now; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# Module: network_interface.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Обзор сетевых интерфейсов и оперативные управляющие функции.

network_iface_exists() {
    local iface="$1"
    [[ -n "$iface" && "$iface" != *"/"* && "$iface" != *".."* && -d "/sys/class/net/${iface}" ]]
}

network_default_ifaces() {
    {
        ip -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}'
        ip -o -6 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}'
    } | sort -u
}

network_iface_is_default_route() {
    local iface="$1"
    network_default_ifaces | grep -Fxq "$iface"
}

network_choose_iface() {
    local default_iface iface
    default_iface=$(traffic_guard_detect_iface)
    iface=$(ask_with_default "Имя интерфейса" "${default_iface:-eth0}")
    if ! network_iface_exists "$iface"; then
        echo -e "${RED}❌ Интерфейс ${iface} не существует.${PLAIN}" >&2
        return 1
    fi
    printf '%s' "$iface"
}

network_show_overview() {
    echo -e "${CYAN}--- Адреса интерфейсов ---${PLAIN}"
    ip -br addr 2>/dev/null || ip addr
    echo ""
    echo -e "${CYAN}--- Маршруты по умолчанию ---${PLAIN}"
    ip route show default 2>/dev/null || true
    ip -6 route show default 2>/dev/null || true
    echo ""
    echo -e "${CYAN}--- DNS ---${PLAIN}"
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns 2>/dev/null || cat /etc/resolv.conf 2>/dev/null
    else
        cat /etc/resolv.conf 2>/dev/null || true
    fi
}

network_show_iface_detail() {
    local iface
    iface=$(network_choose_iface) || return 1
    echo -e "${CYAN}--- Детали канала ${iface} ---${PLAIN}"
    ip -d link show dev "$iface" 2>/dev/null || ip link show dev "$iface"
    echo ""
    echo -e "${CYAN}--- Статистика трафика ${iface} ---${PLAIN}"
    ip -s link show dev "$iface" 2>/dev/null || true
    if command -v ethtool >/dev/null 2>&1; then
        echo ""
        echo -e "${CYAN}--- Драйвер/скорость ${iface} ---${PLAIN}"
        ethtool "$iface" 2>/dev/null | sed -n '1,40p' || true
    fi
}

network_set_iface_state() {
    local state="$1"
    local iface
    iface=$(network_choose_iface) || return 1
    if [[ "$state" == "down" ]]; then
        local default_hint=""
        if network_iface_is_default_route "$iface"; then
            default_hint="Этот интерфейс является маршрутом по умолчанию, его отключение, скорее всего, разорвёт SSH-соединение."
        else
            default_hint="Отключение интерфейса повлияет на все соединения через этот интерфейс."
        fi
        confirm_danger "Отключить интерфейс ${iface}" \
            "Состояние канала интерфейса ${iface}" \
            "Включите интерфейс через консоль провайдера или это меню" \
            "${default_hint}" || return 1
    fi
    ip link set dev "$iface" "$state" || {
        echo -e "${RED}❌ Не удалось установить ${iface} в состояние ${state}.${PLAIN}"
        return 1
    }
    echo -e "${GREEN}✅ Интерфейс ${iface} установлен в состояние: ${state}${PLAIN}"
}

network_set_iface_mtu() {
    local iface mtu
    iface=$(network_choose_iface) || return 1
    read_trimmed mtu "Введите временный MTU (576-9000, после перезагрузки может сброситься): "
    if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( 10#$mtu < 576 || 10#$mtu > 9000 )); then
        echo -e "${RED}❌ Неверный MTU.${PLAIN}"
        return 1
    fi
    confirm_risk_action "Установить MTU ${iface} в ${mtu}" \
        "Текущий MTU интерфейса ${iface}" \
        "Установите прежний MTU или перезагрузите сеть/систему для восстановления значений провайдера" \
        "Неверный MTU может вызвать проблемы с доступом к некоторым сайтам или туннелям." || return 1
    ip link set dev "$iface" mtu "$mtu" || {
        echo -e "${RED}❌ Не удалось установить MTU.${PLAIN}"
        return 1
    }
    echo -e "${GREEN}✅ MTU интерфейса ${iface} временно установлен в ${mtu}${PLAIN}"
}

network_renew_dhcp() {
    local iface
    iface=$(network_choose_iface) || return 1
    confirm_danger "Обновить DHCP-аренду на ${iface}" \
        "Сетевой адрес/подключение интерфейса ${iface}" \
        "Восстановите подключение через консоль провайдера или перезагрузите систему" \
        "Если это публичный интерфейс, используемый для SSH, обновление аренды может временно разорвать соединение." || return 1
    if command -v dhclient >/dev/null 2>&1; then
        dhclient -r "$iface" >/dev/null 2>&1 || true
        dhclient "$iface" || return 1
    elif command -v networkctl >/dev/null 2>&1; then
        networkctl renew "$iface" || return 1
    elif command -v nmcli >/dev/null 2>&1; then
        nmcli device reapply "$iface" || nmcli device connect "$iface" || return 1
    else
        echo -e "${YELLOW}⚠️ dhclient/networkctl/nmcli не обнаружены, автоматическое обновление DHCP невозможно.${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}✅ Попытка обновления DHCP/сети для ${iface} выполнена.${PLAIN}"
}

func_network_interface_manage() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Сеть/оптимизация ядра > Инструменты управления интерфейсами"
        echo -e "${BOLD}🧰 Инструменты управления интерфейсами${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: просмотр интерфейсов, маршрутов, DNS и состояния каналов; опасные операции требуют подтверждения.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Обзор интерфейсов / маршрутов / DNS${PLAIN}"
        echo -e "${GREEN}  2. Детали указанного интерфейса и статистика трафика${PLAIN}"
        echo -e "${GREEN}  3. Включить интерфейс${PLAIN}"
        echo -e "${RED}  4. Отключить интерфейс${PLAIN}"
        echo -e "${YELLOW}  5. Временно установить MTU интерфейса${PLAIN}"
        echo -e "${YELLOW}  6. Обновить DHCP/сетевое подключение${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        local choice
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1) network_show_overview; pause_return ;;
            2) network_show_iface_detail; pause_return ;;
            3) network_set_iface_state up; pause_return ;;
            4) network_set_iface_state down; pause_return ;;
            5) network_set_iface_mtu; pause_return ;;
            6) network_renew_dhcp; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# 24. Меню сетевого ускорения и оптимизации ядра (второй уровень)
# ---------------------------------------------------------

# ---------------------------------------------------------
# Module: menus.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Текст помощи и соединение главного и второго уровней меню.

show_main_help() {
    echo -e "${CYAN}VPS-Optimize > Главное меню > Справка${PLAIN}"
    echo "1/2 Подходит для первичной проверки и инициализации нового сервера."
    echo "3   Базовые компоненты и часто используемые службы; установка Docker, Python, WARP и полезных утилит."
    echo "4   Обратный прокси (Caddy/Nginx); подходит для сайтов/панелей, не подключенных к единому входу 443."
    echo "5   Управление 3x-ui, S-UI, Sing-box, Xray и инструментами подписки."
    echo "6   Центр безопасности SSH; управление портами, открытыми ключами и режимом входа по ключам пользователей."
    echo "8   Управление системным брандмауэром; поддержка открытия портов, удаления и ограничения числа соединений с каждого IP-адреса."
    echo "10  Оптимизация сети/ядра; включает BBR, TCP, ZRAM и очистку ядер."
    echo "15  Общий обзор состояния и диагностическая информация для отладки или отправки Issue."
    echo "16  Резервное копирование и откат, рекомендуется выполнять перед операциями с высоким риском."
    echo "19  Центр управления единым входом 443, общий публичный порт 443 для панелей/подписок/REALITY."
    echo "10 -> 5  Защита от превышения трафика, предотвращение накрутки трафика и превышения счетов по биллинговому периоду."
    echo "xcm прямой доступ к расширенному набору x-ui; также можно через 5 -> 2."
    echo "? Показать справку, 0/q выход."
}

show_beginner_help() {
    echo -e "${CYAN}VPS-Optimize > Новичок-гид > Справка${PLAIN}"
    echo "1 Инициализация нового сервера: пошаговое выполнение в безопасном порядке: предпроверка, инициализация, SSH, открытые ключи, Fail2ban, брандмауэр, резервное копирование."
    echo "2 Установка панели/узла: переход в меню панелей, узлов и инструментов подписки."
    echo "3 Настройка единого входа 443: переход в центр управления 443, подходит для совместного использования 443 панелями, подписками и REALITY."
    echo "4 Проверка состояния: просмотр служб, портов, сертификатов, а также генерация диагностической информации для обратной связи."
    echo "5 Резервное копирование/откат: создание резервной копии или восстановление из существующей."
    echo "? Показать справку, 0/q вернуться в главное меню."
}

show_panel_help() {
    echo -e "${CYAN}VPS-Optimize > Панели, узлы и инструменты подписок > Справка${PLAIN}"
    echo "1 Сценарий панели 3x-ui: установка, официальное меню, восстановление панели."
    echo "2 Расширенный набор x-ui: сброс даты, калибровка трафика, восстановление из резервной копии и логи."
    echo "3 Восстановление SSL панели, подходит для очистки пути сертификата панели перед подключением 443."
    echo "4 Сценарий панели S-UI: установка, официальное меню, удаление."
    echo "5/6 Сценарии Sing-box и Xray."
    echo "7/8/9 Стек подписок, 11 Dockge Compose, 12 Миграция Compose; публичный HTTPS: если единый вход 443 не включен, используйте главное меню [4 Обратный прокси], если включен - главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси]."
    echo "16 dog - измеритель трафика, показывает только фактический трафик на отслеживаемых портах."
    echo "? Показать справку, 0/q вернуться в главное меню."
}

show_sni_help() {
    echo -e "${CYAN}VPS-Optimize > Центр управления единым входом 443 > Справка${PLAIN}"
    echo "1 Просмотр текущего состояния входа / деталей прослушивания: отображает публичный 443, веб-прокси-движок, Xray и состояние служб."
    echo "2 Первоначальная настройка / установка: создание общего веб-домена, веб-прокси-движка, сертификата и стандартного входа Nginx Stream."
    echo "3/4/5 Переключение режимов входа: между Nginx Stream, Xray Fallback и TCP Peek + Splice."
    echo "6 Повторное применение: перегенерировать и запустить конфигурацию входа согласно текущему ENTRY_MODE."
    echo "7 Откат: восстановить резервную копию перед последним переключением режима входа."
    echo "8 Управление веб-доменами/прокси: добавление или удаление сайтов в дальнейшем, не требуется повторная первоначальная настройка."
    echo "9 Белый список IP для веб-доменов: ограничивает только веб-домены, не влияет на узлы Xray."
    echo "10 Изменение общих параметров 443: настройка панелей, подписок, REALITY, портов входа и путей."
    echo "11 Ссылки подписок / External Proxy: проверка, выводят ли ссылки узлов публичный порт 443."
    echo "12 Обслуживание сертификатов CF DNS / Caddy: переподпись сертификатов, восстановление символических ссылок, очистка и откат."
    echo "13 Проверка цепочки: диагностика ENTRY_MODE, прослушивания, сертификатов, веб- и Xray-маршрутизации."
    echo "14 Тест сетевого доступа: проверка DNS, TCP, TLS SNI, ответов панели и путей подписки."
    echo "15 Управление входящими Xray: запись SNI -> локальный адрес:порт, без редактирования входящих 3x-ui/Xray."
    echo "16 Просмотр статуса TCP Peek + Splice / предпроверка 8444: отображает статистику status.json; предпроверка слушает только 8444, не меняет публичный 443."
    echo "17 Проверка правил маршрутизации TCP Peek: только проверка конфигурации, без перезапуска входа."
    echo "18 Просмотр логов TCP Peek + Splice: просмотр логов分流ера (маршрутизатора) vpso-mux."
    echo "Для изменения домена панели используйте главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси] -> [9 Изменить домен панели]."
    echo "Если единый вход 443 не подключен, используйте главное меню [4 Обратный прокси] -> [5] для управления белым списком IP для доменов Caddy/Nginx."
    echo "? Показать справку, 0/q вернуться в главное меню."
}

show_backup_help() {
    echo -e "${CYAN}VPS-Optimize > Резервное копирование и откат > Справка${PLAIN}"
    echo "1 Создать резервную копию: использовать перед операциями с высоким риском."
    echo "2 Просмотр резервных копий: подтвердить доступные копии и время."
    echo "3 Откат: перезаписывает текущую конфигурацию, необходимо ввести yes для подтверждения (регистр не важен)."
    echo "4 Изолировать старые резервные копии: только переместить в карантинный каталог, без непосредственного удаления."
    echo "5 Просмотр/редактирование применённой конфигурации скрипта: сначала резервное копирование, затем проверка по типу конфигурации, возможен выбор reload/restart."
    echo "? Показать справку, 0/q вернуться в главное меню."
}

show_net_kernel_help() {
    echo -e "${CYAN}VPS-Optimize > Сеть/Оптимизация ядра > Справка${PLAIN}"
    echo "1 BBR / Управление перегрузками: вызов внешнего скрипта настройки, перед выполнением рекомендуется резервное копирование."
    echo "2 Параметры TCP: изменение sysctl, подходит для пользователей с конкретными требованиями к параметрам."
    echo "3 Оптимизация DNS: выбор DNS по умолчанию для Китая/мира, также поддерживается пользовательский IPv4 и IPv6."
    echo "4 Инструменты управления сетевыми интерфейсами: просмотр интерфейсов, маршрутов, DNS, временная настройка MTU или обновление DHCP."
    echo "5 Защита от превышения трафика: автоматическое выключение или сохранение только SSH в зависимости от трафика интерфейса и биллингового периода, предотвращение превышения счетов."
    echo "6 ZRAM / Swap: подходит для VPS с малым объёмом памяти."
    echo "7 Установка/переключение ядра: высокий риск, необходимо подтвердить наличие снимков и консоли восстановления."
    echo "8 Очистка старых ядер: не удалять текущее ядро и кастомные ядра от провайдера."
    echo "? Показать справку, 0/q вернуться в главное меню."
}

show_health_help() {
    echo -e "${CYAN}VPS-Optimize > Диагностика/Проверка состояния > Справка${PLAIN}"
    echo "Общий обзор состояния проверяет ключевые службы, прослушиваемые порты и сводку по сертификатам."
    echo "Если существуют правила connlimit, добавленные скриптом, также отображается информация о постоянном бэкенде, соответствии времени выполнения/сохранённых файлов и предупреждения о рисках перезапуска."
    echo "Общий обзор состояния показывает сводку по объёму логов; введите p для проверки прав на конфигурации, состояние и файлы логов, введите P для подтверждения и исправления."
    echo "Введите s для входа в восстановление служб, поддерживается перезапуск часто используемых/сбойных служб, сброс состояния сбоя и настройка автоматического перезапуска при сбое."
    echo "Аппаратный зонд системы включает обзор сценариев 443, Caddy, 3x-ui, инструментов подписки и Docker."
    echo "Генерация диагностической информации для отправки в GitHub Issue, старается избегать вывода токенов, закрытых ключей и конфиденциальных ключей."
}

NET_KERNEL_MENU_ITEMS=(
    "1|BBR / Управление перегрузками|Вызов скрипта настройки ядра ylx2016|func_bbr_manage|net_bbr"
    "2|Динамическая настройка TCP параметров|Вставить параметры Omnitt и автоматически проверить|func_tcp_tune|net_tcp_tune"
    "3|Оптимизация DNS|Китай/мир/пользовательский, IPv4+IPv6|func_dns_optimize|"
    "4|Инструменты управления сетевыми интерфейсами|Интерфейсы/маршруты/DNS/MTU/DHCP|func_network_interface_manage|"
    "5|Защита от превышения трафика|Предотвращение накрутки / превышения счетов|func_traffic_guard_menu|"
    "6|Оптимизация памяти ZRAM / Swap|Оптимизация VPS по объёму памяти|func_zram_swap|"
    "7|Установка/переключение оптимизированного ядра|Cloud/KVM стабильная рекомендация / XanMod продвинутый вариант|func_install_kernel|net_kernel_install"
    "8|Очистка старых ядер|Освободить место на диске, действовать осторожно|func_clean_kernel|"
)

confirm_menu_risk() {
    local risk="$1"
    case "$risk" in
        net_bbr)
            confirm_risk_action "BBR / Управление перегрузками" \
                "Модули ядра сети, управление перегрузками и параметры TCP" \
                "Восстановить из снимка или вернуться в это меню и переключиться обратно на исходную конфигурацию" \
                "Внешний скрипт настройки может установить/переключить ядро, убедитесь, что консоль восстановления доступна."
            ;;
        net_tcp_tune)
            confirm_risk_action "Динамическая настройка TCP параметров" \
                "Параметры sysctl TCP и конфигурация сетевого стека" \
                "Восстановить резервную конфигурацию из /etc/sysctl.d или вручную откатить параметры" \
                "Убедитесь, что источник параметров надежен, неверные параметры могут повлиять на сетевое соединение."
            ;;
        net_kernel_install)
            confirm_risk_action "Установка/переключение оптимизированного ядра" \
                "Пакеты ядра, конфигурация загрузчика и меню GRUB" \
                "Выбрать загрузку старого ядра из консоли облачного провайдера или использовать режим восстановления" \
                "Убедитесь, что создан снимок, и текущий VPS не является старой системой OpenVZ."
            ;;
        *) return 0 ;;
    esac
}


func_net_kernel_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Сеть/Оптимизация ядра"
        echo -e "${BOLD}🚀 Управление производительностью сети и ядра${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: настройка сетевого стека, сжатия памяти и ядра; перед установкой/очисткой ядра рекомендуется сделать снимок.${PLAIN}"
        echo -e "------------------------------------------------"
        render_menu NET_KERNEL_MENU_ITEMS
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться в главное меню / q вернуться на уровень выше${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local nk_choice
        read_trimmed nk_choice "👉 Выберите действие: "
        case $nk_choice in
            "?"|help) show_net_kernel_help; pause_return ;;
            0|q|Q) break ;;
            *) dispatch_menu_choice "$nk_choice" NET_KERNEL_MENU_ITEMS || { echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1; } ;;
        esac
    done
}

# ---------------------------------------------------------
# 24. Меню развертывания панелей и узлов (второй уровень)
# ---------------------------------------------------------
func_panel_deploy_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Панели, узлы и инструменты подписки"
        echo -e "${BOLD}🛰️ Развертывание панелей, узлов и инструментов подписки${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Панели / Ядро${PLAIN}"
        echo -e "  ${BOLD}${GREEN}1.${PLAIN} ${BOLD}Сценарий панели 3x-ui${PLAIN}     ${BOLD}${GREEN}2.${PLAIN} ${BOLD}Расширенный набор x-ui${PLAIN}      ${BOLD}${GREEN}3.${PLAIN} ${BOLD}Восстановление SSL панели${PLAIN}"
        echo -e "  ${BOLD}${GREEN}4.${PLAIN} ${BOLD}Сценарий панели S-UI${PLAIN}      ${BOLD}${GREEN}5.${PLAIN} ${BOLD}Сценарий Sing-box${PLAIN}      ${BOLD}${GREEN}6.${PLAIN} ${BOLD}Сценарий Xray${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Подписки / Compose${PLAIN}"
        echo -e "  ${BOLD}${GREEN}7.${PLAIN} ${BOLD}Стек подписок SublinkPro${PLAIN}  ${BOLD}${GREEN}8.${PLAIN} ${BOLD}Стек подписок Miaomiaowu${PLAIN}       ${BOLD}${GREEN}9.${PLAIN} ${BOLD}Стек подписок Sub-Store${PLAIN}"
        echo -e " ${BOLD}${YELLOW}10.${PLAIN} ${BOLD}Обновление стеков подписок${PLAIN}        ${BOLD}${GREEN}11.${PLAIN} ${BOLD}Dockge Compose${PLAIN}    ${BOLD}${GREEN}12.${PLAIN} ${BOLD}Миграция Compose${PLAIN}"
        echo -e " ${BOLD}${GREEN}13.${PLAIN} ${BOLD}Панель зонда Komari${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Инструменты / Вспомогательное${PLAIN}"
        echo -e " ${BOLD}${GREEN}14.${PLAIN} ${BOLD}Сценарий разблокировки DNS${PLAIN}      ${BOLD}${GREEN}15.${PLAIN} ${BOLD}Сценарий IP-Sentinel${PLAIN}  ${BOLD}${GREEN}16.${PLAIN} ${BOLD}dog - измеритель трафика${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться в главное меню / q вернуться на уровень выше${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local pd_choice
        read_trimmed pd_choice "👉 Выберите действие: "
        case $pd_choice in
            1) func_xpanel_menu ;;
            2) func_xui_custom_manager ;;
            3) func_rescue_panel ;;
            4) func_sui_menu ;;
            5) func_singbox_menu ;;
            6) func_xray_menu ;;
            7) func_sublinkpro_menu ;;
            8) func_miaomiaowu_menu ;;
            9) func_substore_menu ;;
            10) func_update_subscription_tools ;;
            11) func_dockge_menu ;;
            12) func_migrate_compose_to_dockge ;;
            13) func_komari_menu ;;
            14) func_dns_unlock ;;
            15) func_ip_sentinel ;;
            16) func_port_dog ;;
            xcm|XCM|xui-custom|外置|外置增强|外置管理) func_xui_custom_manager ;;
            "?"|help) show_panel_help; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

func_sni_stack_quick_menu() {
    while true; do
        clear
        show_current_entry_summary
        echo -e "------------------------------------------------"
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Центр управления единым входом 443"
        echo -e "${BOLD}🧩 Центр управления единым входом 443${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: централизованное управление режимом входа на публичном порту 443, веб-доменами, маршрутизацией входящих Xray и проверкой цепочки.${PLAIN}"
        echo -e "${YELLOW}При первом развертывании выберите [2]; после наличия конфигурации используйте [3]/[4]/[5] для переключения между тремя режимами входа.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Текущее состояние и режим входа${PLAIN}"
        echo -e "${GREEN}  1. Просмотр текущего состояния входа / деталей прослушивания${PLAIN} ${YELLOW}(публичный 443, веб-прокси, Xray, состояние служб)${PLAIN}"
        echo -e "${GREEN}  2. Первоначальная настройка / установка единого входа 443${PLAIN} ${YELLOW}(по умолчанию режим Nginx Stream, для первого развертывания)${PLAIN}"
        echo -e "${GREEN}  3. Переключиться на режим Nginx Stream${PLAIN}  ${YELLOW}(стабильный режим по умолчанию)${PLAIN}"
        echo -e "${GREEN}  4. Переключиться на режим Xray Fallback${PLAIN} ${YELLOW}(требуется уже существующий основной входящий Xray/3x-ui)${PLAIN}"
        echo -e "${GREEN}  5. Переключиться на режим TCP Peek + Splice${PLAIN} ${YELLOW}(требуется предварительная проверка 8444, при переключении автоматическая компиляция не выполняется)${PLAIN}"
        echo -e "${CYAN}  6. Повторно применить текущий режим входа${PLAIN}"
        echo -e "${YELLOW}  7. Откатить последнее переключение режима входа${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Общие конфигурации и проверка${PLAIN}"
        echo -e "${GREEN}  8. Управление веб-доменами/прокси${PLAIN}        ${YELLOW}(добавление/удаление/просмотр сайтов, наиболее часто)${PLAIN}"
        echo -e "${CYAN}  9. Управление белым списком IP для веб-доменов${PLAIN}   ${YELLOW}(ограничивает только веб-домены)${PLAIN}"
        echo -e "${CYAN} 10. Изменение общих параметров 443${PLAIN}         ${YELLOW}(панели/подписки/REALITY/порты и пути входа)${PLAIN}"
        echo -e "${CYAN} 11. Ссылки подписок / External Proxy${PLAIN} ${YELLOW}(проверка, выводят ли ссылки узлов публичный 443)${PLAIN}"
        echo -e "${CYAN} 12. Обслуживание сертификатов CF DNS / Caddy${PLAIN}   ${YELLOW}(переподпись/символические ссылки/очистка/восстановление/откат)${PLAIN}"
        echo -e "${GREEN} 13. Проверка цепочки 443${PLAIN}              ${YELLOW}(ENTRY_MODE/прослушивание/сертификаты/веб-маршрутизация/Xray)${PLAIN}"
        echo -e "${CYAN} 14. Тест сетевого доступа 443${PLAIN}          ${YELLOW}(DNS/TCP/TLS/панели/пути подписок)${PLAIN}"
        echo -e "${CYAN} 15. Управление входящими Xray${PLAIN}             ${YELLOW}(SNI -> локальный адрес:порт, запись маршрутизации)${PLAIN}"
        echo -e "${CYAN} 16. Просмотр статуса TCP Peek + Splice / предпроверка 8444${PLAIN} ${YELLOW}(не меняет публичный 443)${PLAIN}"
        echo -e "${CYAN} 17. Проверка правил маршрутизации TCP Peek${PLAIN} ${YELLOW}(только проверка конфигурации, без перезапуска входа)${PLAIN}"
        echo -e "${CYAN} 18. Просмотр логов TCP Peek + Splice${PLAIN} ${YELLOW}(логи分流ера vpso-mux)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${YELLOW}Примечание: три режима входа 443 не являются тремя отдельными установщиками; [2] создает общую конфигурацию, [3]/[4]/[5] отвечают за проверку зависимостей, генерацию целевой конфигурации и переключение входа.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться в главное меню / q/back/назад${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local sni_choice
        read_trimmed sni_choice "👉 Введите номер меню или ?: "
        case "$sni_choice" in
            1) show_current_entry_status ;;
            2) func_caddy_cf_reality_wizard ;;
            3) switch_entry_mode "nginx-stream" ;;
            4) switch_entry_mode "xray-fallback" ;;
            5) switch_entry_mode "tcp-peek" ;;
            6) reapply_current_entry_mode ;;
            7) rollback_last_entry_mode ;;
            8) manage_sni_stack_sites; continue ;;
            9) manage_sni_stack_ip_whitelist; continue ;;
            10) edit_sni_stack_runtime_profile; continue ;;
            11) check_sni_stack_subscription_hint ;;
            12) func_caddy_cf_maintenance_menu; continue ;;
            13) sni_stack_health_check_enhanced ;;
            14) func_443_network_test; continue ;;
            15) manage_xray_inbound_routes; continue ;;
            16) start_tcp_peek_test_port ;;
            17) tcp_peek_dry_run_config ;;
            18) view_vpso_mux_logs ;;
            "?"|help) show_sni_help; pause_return; continue ;;
            0) break ;;
            *) echo -e "${RED}❌ Неверный выбор, введите номер меню или ?.${PLAIN}"; sleep 1 ;;
        esac
        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}

normalize_main_choice() {
    local choice
    choice="$(trim_input "$1")"
    choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

    case "$choice" in
        q|quit|exit|0|退出) echo "0" ;;
        pre|preflight|check|预检) echo "1" ;;
        init|base|初始化) echo "2" ;;
        env|docker|组件) echo "3" ;;
        caddy|nginx|ngx|proxy|reverse|反代) echo "4" ;;
        xcm|xui-custom|外置|外置增强|外置管理) echo "xui-custom" ;;
        panel|node|nodes|面板|节点) echo "5" ;;
        ssh) echo "6" ;;
        fail2ban|f2b) echo "7" ;;
        fw|firewall|防火墙) echo "8" ;;
        tweak|system|系统) echo "9" ;;
        net|kernel|bbr|网络|内核) echo "10" ;;
        docker-safe|docker安全) echo "11" ;;
        test|speed|测速) echo "12" ;;
        port|端口) echo "13" ;;
        info|hardware|探针) echo "14" ;;
        h|health|健康|体检) echo "15" ;;
        b|backup|bak|备份) echo "16" ;;
        u|upd|update|更新) echo "17" ;;
        reboot|重启) echo "18" ;;
        sni|443|单入口) echo "19" ;;
        traffic|quota|bill|流量|达量|账单) echo "10" ;;
        *) echo "$choice" ;;
    esac
}

beginner_run_optional_step() {
    local step="$1"
    local total="$2"
    local label="$3"
    local function_name="$4"
    local choice

    echo -e "${CYAN}[${step}/${total}] ${label}${PLAIN}"
    read_trimmed choice "Перейти к этому шагу? (Y/n): "
    if [[ "${choice:-yes}" =~ ^[Nn]([Oo])?$ ]]; then
        echo -e "${BLUE}Пропущено: ${label}${PLAIN}"
        return 2
    fi
    "$function_name"
}

func_beginner_machine_init() {
    local total=7
    local step_rc step_entry step label function_name
    local VPSO_BEGINNER_FLOW=1
    local completed=("Предварительная проверка перед развертыванием")
    local skipped=()
    local optional_steps=(
        "3|Настройка безопасности SSH|func_security"
        "4|Настройка открытых ключей SSH|func_add_ssh_key"
        "5|Настройка Fail2ban|func_fail2ban"
        "6|Настройка брандмауэра|func_firewall_manage"
        "7|Резервное копирование конфигурации|func_backup_center"
    )

    echo -e "${CYAN}[1/${total}] Предварительная проверка перед развертыванием${PLAIN}"
    if ! func_preflight_check; then
        echo -e "${RED}❌ Обнаружены проблемы при предварительной проверке, инициализация нового сервера остановлена, система не была изменена.${PLAIN}"
        pause_return
        return 1
    fi

    echo -e "${CYAN}[2/${total}] Базовая инициализация${PLAIN}"
    if ! func_base_init; then
        echo -e "${RED}❌ Базовая инициализация завершена не полностью, последующие настройки безопасности остановлены.${PLAIN}"
        pause_return
        return 1
    fi
    completed+=("Базовая инициализация")

    for step_entry in "${optional_steps[@]}"; do
        IFS='|' read -r step label function_name <<< "$step_entry"
        beginner_run_optional_step "$step" "$total" "$label" "$function_name"
        step_rc=$?
        if [[ "$step_rc" -eq 0 ]]; then
            completed+=("$label")
        elif [[ "$step_rc" -eq 2 ]]; then
            skipped+=("$label")
        else
            echo -e "${RED}❌ ${label} не удалось выполнить, инициализация нового сервера остановлена.${PLAIN}"
            echo -e "${CYAN}Завершено: ${completed[*]}${PLAIN}"
            pause_return
            return 1
        fi
    done

    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${GREEN}✅ Процесс инициализации нового сервера завершен.${PLAIN}"
    echo -e "Завершено: ${completed[*]}"
    if [[ ${#skipped[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Пропущено: ${skipped[*]}${PLAIN}"
    fi
    pause_return
}

func_beginner_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Новичок-гид"
        echo -e "${BOLD}VPS-Optimize ${SCRIPT_VERSION}${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Это упрощенный вход, содержащий только наиболее часто используемые пути для первого развертывания; опытные пользователи могут вернуться в полное меню.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Инициализация нового сервера${PLAIN}       ${YELLOW}(предпроверка -> инициализация -> SSH/открытые ключи/Fail2ban/брандмауэр -> резервное копирование)${PLAIN}"
        echo -e "${GREEN}  2. Установка панели/узла${PLAIN}     ${YELLOW}(переход в меню панелей, узлов и подписок)${PLAIN}"
        echo -e "${GREEN}  3. Настройка единого входа 443${PLAIN}   ${YELLOW}(общий публичный 443 для панелей/подписок/REALITY)${PLAIN}"
        echo -e "${GREEN}  4. Проверка состояния${PLAIN}          ${YELLOW}(состояние служб, порты, сертификаты, диагностика)${PLAIN}"
        echo -e "${GREEN}  5. Резервное копирование/откат${PLAIN}         ${YELLOW}(создать резервную копию или восстановить конфигурацию)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться в главное меню / q вернуться${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local beginner_choice
        read_trimmed beginner_choice "👉 Выберите действие: "
        case "$beginner_choice" in
            1)
                func_beginner_machine_init
                ;;
            2) func_panel_deploy_menu ;;
            3) func_sni_stack_quick_menu ;;
            4) func_health_dashboard ;;
            5) func_backup_center ;;
            "?"|help|h) show_beginner_help; echo ""; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# Основной цикл интерфейса (добавлены IP-защита и SublinkPro)
# ---------------------------------------------------------
main_menu() {
    create_shortcut
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Главное меню"
        echo -e " ${BOLD}🚀 VPS-Optimize ${SCRIPT_VERSION} (горячие клавиши: ${YELLOW}cy${PLAIN}${BOLD})${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e " ${YELLOW}Быстрый ввод: 443 - прямой вход в единый вход, h - состояние, b - резервное копирование, u - обновление, q - выход.${PLAIN}"
        echo -e " ${YELLOW}Операции с высоким риском требуют ввода yes для подтверждения (регистр не важен); при сомнениях сначала сделайте [16] резервное копирование.${PLAIN}"
        print_auto_update_notice
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e " ${BOLD}${BLUE}▶ Вход в режимы${PLAIN}"
        echo -e "  ${GREEN}n.${PLAIN} Новичок-гид              ${YELLOW}(показывает только основные пути)${PLAIN}"
        echo -e "  ${GREEN}?.${PLAIN} Справка по текущему меню          ${YELLOW}(поясняет ключевые входы)${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        echo -e " ${BOLD}${BLUE}▶ ① Рекомендуемый порядок: сначала запустите здесь новый сервер${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} Предварительная проверка и сканирование рисков    ${YELLOW}(перед развертыванием проверьте порты/систему/состояние служб)${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} Инициализация базовой среды        ${YELLOW}(инструменты/часовой пояс/обновление системы/базовый BBR)${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} Базовые компоненты и часто используемые службы    ${YELLOW}(Docker/Python/WARP/полезные утилиты)${PLAIN}"
        echo -e "  ${GREEN}4.${PLAIN} Обратный прокси (Caddy/Nginx)   ${YELLOW}(для сайтов/панелей, не подключенных к единому входу 443)${PLAIN}"
        echo -e "  ${GREEN}5.${PLAIN} Панели, узлы и инструменты подписок  ${YELLOW}(3x-ui/Sing-box/управление подписками/Dockge)${PLAIN}"

        echo -e " ${BOLD}${BLUE}▶ ② Безопасность и контроль доступа${PLAIN}"
        echo -e "  ${GREEN}6.${PLAIN} Центр безопасности SSH          ${YELLOW}(порт/открытые ключи/режим входа по ключу)${PLAIN}"
        echo -e "  ${GREEN}7.${PLAIN} Fail2ban защита от взлома       ${YELLOW}(автоматическая блокировка IP при атаках на SSH)${PLAIN}"
        echo -e "  ${GREEN}8.${PLAIN} Управление правилами брандмауэра        ${YELLOW}(разрешить/удалить/просмотреть/отключить/ограничение числа соединений)${PLAIN}"
        echo -e "  ${GREEN}9.${PLAIN} Системные переключатели и очистка        ${YELLOW}(приоритет IPv6/IPv4/Ping/имя хоста/очистка)${PLAIN}"

        echo -e " ${BOLD}${BLUE}▶ ③ Сетевая производительность и контейнеры${PLAIN}"
        echo -e " ${GREEN}10.${PLAIN} Оптимизация сети и ядра        ${YELLOW}(BBR/TCP/ZRAM/DNS/легкое ядро)${PLAIN}"
        echo -e " ${GREEN}11.${PLAIN} Безопасность Docker       ${YELLOW}(защита от локального проникновения/восстановление доступа)${PLAIN}"

        echo -e " ${BOLD}${BLUE}▶ ④ Диагностика, резервирование и обслуживание${PLAIN}"
        echo -e " ${GREEN}12.${PLAIN} Тест скорости и проверка качества        ${YELLOW}(YABS/потоковое видео/обратный путь/качество IP)${PLAIN}"
        echo -e " ${GREEN}13.${PLAIN} Проверка и освобождение портов        ${YELLOW}(просмотр занятости и принудительное завершение процессов)${PLAIN}"
        echo -e " ${GREEN}14.${PLAIN} Аппаратный зонд системы          ${YELLOW}(CPU/память/диск/информация о сети в реальном времени)${PLAIN}"
        echo -e " ${GREEN}15.${PLAIN} Общий обзор состояния служб          ${YELLOW}(статус служб/сводка по сертификатам/обзор портов)${PLAIN}"
        echo -e " ${GREEN}16.${PLAIN} Резервное копирование и откат конфигурации        ${YELLOW}(резервирование/список/восстановление/очистка)${PLAIN}"
        echo -e " ${BOLD}${YELLOW}17.${PLAIN} Обновить скрипт              ${CYAN}(быстрый ввод: u / update / upd)${PLAIN}"
        echo -e " ${RED}18.${PLAIN} Перезагрузить сервер"
        echo -e ""
        echo -e " ${BOLD}${BLUE}▶ ⑤ Часто используемые${PLAIN}"
        echo -e " ${GREEN}19.${PLAIN} Центр управления единым входом 443    ${YELLOW}(инициализация/добавление сайтов/проверка/восстановление сертификатов)${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e " ${RED} 0.${PLAIN} Выйти из панели"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice
        read_trimmed choice "👉 Введите номер или быстрое слово для выбора функции: "
        choice=$(normalize_main_choice "$choice")

        case $choice in
            n|N|newbie|guide|新手|向导) func_beginner_menu ;;
            "?"|help|帮助) show_main_help; echo ""; pause_return ;;
            xui-custom) func_xui_custom_manager ;;
            1) func_preflight_check ;;
            2) func_base_init ;;
            3) func_env_install ;;
            4) func_caddy_reverse_proxy_menu ;;
            5) func_panel_deploy_menu ;;
            6) func_ssh_security_menu ;;
            7) func_fail2ban ;;
            8) func_firewall_manage ;;
            9) func_system_tweaks ;;
            10) func_net_kernel_menu ;;
            11) func_docker_manage ;;
            12) func_test_scripts ;;
            13) func_port_kill ;;
            14) func_system_info ;;
            15) func_health_dashboard ;;
            16) func_backup_center ;;
            17) func_update_script ;;
            18) func_reboot_server ;;
            19) func_sni_stack_quick_menu ;;
            0) exit 0 ;;
            *)
                echo -e "${RED}❌ Неверный ввод, введите номер, присутствующий в меню!${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# ---------------------------------------------------------
# Module: main.sh
# ---------------------------------------------------------
# shellcheck shell=bash
# Основная загрузка. Реализация функций находится в модулях src/*.sh.

# --- Главная точка входа ---
main() {
    ensure_runtime_root
    main_menu "$@"
}

main "$@"
