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
