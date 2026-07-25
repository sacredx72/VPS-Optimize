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
        # Простая очистка: удаляем символы возврата каретки и лишние пробелы
        line="$(trim_input "$line")"
        
        # Проверка на завершающий маркер (регистронезависимо)
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
        # Проверяем, принимает ли ядро все новые параметры
        if sysctl_tune_check_supported_file "$temp_f" && sysctl_tune_apply_file "$temp_f"; then
            echo -e "${GREEN}✅ Динамическая оптимизация TCP применена успешно! Пропускная способность улучшена.${PLAIN}"
            rm -f "$backup_f" # Удаляем резервную копию при успехе
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
    echo -e "${RED}  0. Вернуться / q вернуться${PLAIN}"
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
    echo -e "${RED}⚠️ Система автоматически исключила работающее ядро, а также популярные облачные/виртуальные/оптимизированные ядра.${PLAIN}"
    echo -e "------------------------------------------------"
    
    # Автоматически извлекаем все не текущие пакеты ядра в массив (исключая мета-пакеты, используя высокодоступное сопоставление полей)
    mapfile -t old_kernels < <(dpkg -l | awk '$1 == "ii" && $2 ~ /^linux-image-[0-9]/ {print $2}' | grep -v "$current_k" | grep -Ev "cloud|kvm|virtual|generic|xanmod")

    if [[ ${#old_kernels[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Система очень чистая, не найдено старых ядер для очистки.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "${YELLOW}Обнаружены следующие старые ядра для очистки:${PLAIN}"
    for i in "${!old_kernels[@]}"; do
        echo -e " [${CYAN}$((i+1))${PLAIN}] ${old_kernels[$i]}"
    done
    echo -e " [${RED}0${PLAIN}] Отмена и возврат"
    echo -e "------------------------------------------------"

    local k_choice
    read_trimmed k_choice "👉 Введите номер для удаления: "

    if [[ "$k_choice" == "0" ]]; then
        echo -e "${BLUE}Удаление отменено.${PLAIN}"
    elif [[ "$k_choice" =~ ^[1-9][0-9]*$ ]] && [[ "$k_choice" -le "${#old_kernels[@]}" ]]; then
        local target_k="${old_kernels[$((k_choice-1))]}"
        confirm_danger "Удалить старое ядро ${target_k}" "Будет удалён пакет ядра и обновлён GRUB; проблемы с загрузкой могут повлиять на следующий запуск." "Рекомендуется создать снимок VPS; работающее ядро автоматически исключено, в случае ошибки восстановитесь из снимка или режима восстановления." || {
            echo -e "${BLUE}Удаление отменено.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        }
        echo -e "${CYAN}Выполняется тихое удаление $target_k и обновление загрузчика...${PLAIN}"
        export DEBIAN_FRONTEND=noninteractive
        if apt-get purge -yq "$target_k" && update-grub >/dev/null 2>&1 && apt-get autoremove --purge -yq >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Старое ядро [$target_k] удалено! Освобождено место на диске.${PLAIN}"
        else
            echo -e "${RED}❌ Ошибка очистки! Проблемы с зависимостями или прерывание выполнения.${PLAIN}"
        fi
        unset DEBIAN_FRONTEND
    else
        echo -e "${RED}❌ Неверный выбор!${PLAIN}"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

# ---------------------------------------------------------
# 11. Быстрый аппаратный зонд
# ---------------------------------------------------------
