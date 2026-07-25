# shellcheck shell=bash
# Сохранение окружения стека 443, ужесточение брандмауэра, вывод результата и применение во время выполнения.

save_sni_stack_env() {
    mkdir -p /etc/vps-optimize
    local entry_mode site_domains_csv site_backend_addrs_csv site_backend_ports_csv
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
    [[ "$yn" =~ ^[Yy]$ ]] || return 0
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
    local p entry_mode entry_label entry_listener
    entry_mode="${ENTRY_MODE:-nginx-stream}"
    entry_mode=$(normalize_entry_mode_name "$entry_mode" 2>/dev/null || echo "nginx-stream")
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
    echo -e "  Пути сертификатов/приватных ключей панели: очистить"
    echo -e "  Web-прокси подключается по: http://${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "  Panel URL / Public URL / External URL: https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "  Subscription URI Path: ${SUB_URI_PATH}"
    echo -e "  Subscription External URL: https://${PANEL_DOMAIN}${SUB_URI_PATH}"
    echo -e "  Clash/Mihomo URI Path: ${CLASH_URI_PATH}"
    echo -e "  Clash/Mihomo External URL: https://${PANEL_DOMAIN}${CLASH_URI_PATH}"
    echo -e "${YELLOW}  Не рекомендуется использовать webBasePath=/, случайный путь снижает риск сканирования.${PLAIN}"
    echo -e "  Пути сертификатов/приватных ключей подписки: очистить"
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
    echo -e "  ERR_TOO_MANY_REDIRECTS: обычно пути сертификатов панели или подписки не очищены, либо несовпадение внешнего адреса/пути"
    echo -e "  HTTP 404: сначала проверьте, совпадает ли путь с webBasePath 3x-ui, затем проверьте, проксирует ли Caddy на ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "  502 Bad Gateway: обычно 3x-ui не запущен, порт не тот, или бэкенд 3x-ui всё ещё HTTPS"
    echo -e ""
    echo -e "${BOLD}5. Вход и конфигурация бэкендов${PLAIN}"
    echo -e "  ${NGINX_LISTEN_ADDR}:${NGINX_LISTEN_PORT} -> ${entry_listener}"
    echo -e "  ${CADDY_LISTEN_ADDR}:${CADDY_LISTEN_PORT} -> caddy"
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
    echo -e "  caddy validate --config /etc/caddy/Caddyfile"
    echo -e "  curl -I http://${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}/"
    echo -e "  openssl s_client -connect SERVER_IP:${NGINX_LISTEN_PORT} -servername ${PANEL_DOMAIN}"
    echo -e "  openssl s_client -connect SERVER_IP:${NGINX_LISTEN_PORT} -servername ${REALITY_SNI}"
    echo -e "  journalctl -u caddy -n 80 --no-pager"
    echo -e "  journalctl -u x-ui -u 3x-ui -n 80 --no-pager"
    echo -e ""
    case "$entry_mode" in
        "xray-fallback")
            echo -e "${RED}Абсолютно не делать: Caddy напрямую слушает публичный 443; панель 3x-ui, подписка или дополнительные локальные входящие выставлять наружу; не очищать пути сертификатов 3x-ui и запускать Web fallback; указывать REALITY dest/serverNames как домен панели.${PLAIN}"
            ;;
        *)
            echo -e "${RED}Абсолютно не делать: Caddy напрямую слушает публичный 443; основной входящий Xray/3x-ui напрямую занимает публичный 443; панель 3x-ui или новые локальные входящие выставлять наружу; не очищать пути сертификатов 3x-ui и запускать 443; указывать REALITY dest/serverNames как домен панели.${PLAIN}"
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
