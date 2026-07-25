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
