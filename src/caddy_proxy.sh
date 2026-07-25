# shellcheck shell=bash
# Обычные рабочие процессы обратного прокси Caddy/Nginx вне стека единого входа 443.

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
        echo -e "${YELLOW}Ошибка проверки Caddy:${PLAIN}"
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
    read_trimmed port "Введите локальный порт бэкенда панели (например 40000): "
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

    read_trimmed is_https "❓ Бэкенд панели использует собственный SSL-сертификат? (y/n): "

    local enable_ip_whitelist ip_whitelist_input ip_whitelist_ranges current_client_ip
    local -a ip_whitelist_array=()
    read_trimmed enable_ip_whitelist "❓ Разрешить доступ к домену только с указанных IP/CIDR? (y/n, по умолчанию n): "
    if is_yes "$enable_ip_whitelist"; then
        current_client_ip=$(detect_ssh_client_ip)
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен в белый список, чтобы не заблокировать себя.${PLAIN}"
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
            echo -e "${CYAN}Резервная копия конфигурации сохранена: ${backup_file}${PLAIN}"
        else
            echo -e "${RED}❌ Конфигурация Caddy проверена, но перезагрузка службы не удалась, выполняется откат...${PLAIN}"
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
    [[ -s "$cert_file" && -s "$key_file" ]] || { echo -e "${RED}❌ Сертификат отсутствует после установки: ${cert_file}|${key_file}${PLAIN}"; return 1; }
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
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен в белый список, чтобы не заблокировать себя.${PLAIN}"
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
    read_trimmed domain_input "Введите домен для настройки (например panel.example.com): "
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
    echo -e "${GREEN}  1. Caddy пропуск проверки сертификата бэкенда${PLAIN}"
    echo -e "${GREEN}  2. Nginx пропуск проверки сертификата бэкенда${PLAIN}"
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
            [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен в белый список.${PLAIN}"
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
                    echo -e "${CYAN}Резервная копия конфигурации сохранена: ${backup_file}${PLAIN}"
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
                echo -e "${CYAN}Резервная копия конфигурации сохранена: ${backup_file}${PLAIN}"
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
    echo -e "${GREEN}  1. IP-белый список Caddy для доменов${PLAIN}"
    echo -e "${GREEN}  2. IP-белый список Nginx для доменов${PLAIN}"
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
