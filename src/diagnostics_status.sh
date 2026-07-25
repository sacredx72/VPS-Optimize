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
