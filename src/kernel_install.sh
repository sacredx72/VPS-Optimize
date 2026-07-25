# shellcheck shell=bash
# Обнаружение оптимизированных ядер, настройка репозиториев, установка и выбор загрузки.

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
        echo -e "${YELLOW}⚠️ dpkg или конфигурация GRUB не обнаружены, автоматическое управление загрузкой пропущено.${PLAIN}"
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
    echo -e "${RED}  0. Вернуться${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local kernel_choice virt
    read_trimmed kernel_choice "👉 Выберите тип ядра [рекомендуется 1]: "
    kernel_choice="${kernel_choice:-1}"
    [[ "$kernel_choice" == "0" ]] && return

    virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    if [[ "$virt" =~ lxc|openvz ]]; then
        echo -e "${RED}❌ Критическая ошибка: обнаружена контейнерная виртуализация $virt!${PLAIN}"
        echo -e "${YELLOW}💡 Контейнеры используют ядро хоста, смена ядра невозможна. Операция безопасно остановлена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    local arch
    arch=$(normalize_kernel_arch)
    if [[ "$arch" == "unknown" ]]; then
        echo -e "${RED}❌ Критическая ошибка: текущая архитектура $(uname -m) не поддерживает автоматическую смену ядра!${PLAIN}"
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
# 10. Очистка старых ядер (управляемая массивом + защита от "кирпича")
# ---------------------------------------------------------
