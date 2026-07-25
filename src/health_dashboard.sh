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
