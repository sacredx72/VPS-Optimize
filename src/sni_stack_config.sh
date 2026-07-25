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
            echo -e "${RED}Invalid ENTRY_MODE: ${mode}${PLAIN}"
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
        echo -e "Xray публичный: ${GREEN}публичный 443 сейчас слушается Xray/панельным Xray${PLAIN}"
    else
        echo -e "Xray публичный: Xray, слушающий публичный 443, не обнаружен"
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
