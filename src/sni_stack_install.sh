# shellcheck shell=bash
# 443 single-entry collection, installation, rendering, certificates, and runtime apply flows.

collect_sni_stack_config() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}443 общая конфигурация для одного входа${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Публичный порт 443 будет прослушиваться выбранным вами режимом входа; домен Web, движок обратного прокси, сертификаты и белый список являются общими для трех режимов.${PLAIN}"
    echo -e "${YELLOW}Движок Web-обратного прокси и локальный бэкенд Xray/3x-ui по умолчанию привязаны к 127.0.0.1.${PLAIN}"
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
    echo -e "${CYAN}Пожалуйста, выберите движок Web-обратного прокси для одного входа 443:${PLAIN}"
    echo -e "${GREEN}  1. Локальный HTTPS-обратный прокси Caddy${PLAIN} ${YELLOW}(по умолчанию, совместим с существующей конфигурацией одного входа 443)${PLAIN}"
    echo -e "${GREEN}  2. Локальный HTTPS-обратный прокси Nginx${PLAIN} ${YELLOW}(прослушивает только локальный порт, не занимает публичный 443)${PLAIN}"
    read_trimmed web_engine_choice "Выберите движок Web-обратного прокси (по умолчанию 1): "
    case "${web_engine_choice:-1}" in
        1) WEB_PROXY_ENGINE="caddy" ;;
        2) WEB_PROXY_ENGINE="nginx" ;;
        *) echo -e "${RED}❌ Неверный выбор движка Web-обратного прокси.${PLAIN}"; return 1 ;;
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
    site_domains_input=$(ask_with_default "Домен сайта/обратного прокси (опционально, несколько через запятую, например site1.example.com,site2.example.com)" "")
    split_csv_to_array "$site_domains_input" SITE_DOMAINS
    site_domain_raw_inputs=("${SITE_DOMAINS[@]}")
    echo -e "${YELLOW}Для SNI маскировки REALITY введите домен внешнего реального HTTPS-сайта, не вводите домен панели или узла.${PLAIN}"
    echo -e "${YELLOW}Пример шаблона: your-reality-sni.example.com (замените на выбранный вами реальный сайт)${PLAIN}"
    read_trimmed reality_sni_input "SNI маскировки REALITY (обязательно): "
    REALITY_SNI="$reality_sni_input"
    NGINX_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания Nginx для публичного доступа" "0.0.0.0")
    NGINX_LISTEN_PORT=$(ask_with_default "Порт прослушивания Nginx для публичного доступа" "443")

    local advanced_mode
    read_trimmed advanced_mode "Войти в расширенный режим и разрешить изменение локальных адресов прослушивания служб? (y/n, по умолчанию n): "
    if is_yes "$advanced_mode"; then
        CADDY_LISTEN_ADDR=$(ask_with_default "$(web_proxy_engine_label "$WEB_PROXY_ENGINE")Адрес прослушивания" "127.0.0.1")
        XRAY_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания Xray REALITY" "127.0.0.1")
        PANEL_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания панели 3x-ui" "$default_panel_addr")
        SUB_LISTEN_ADDR=$(ask_with_default "Адрес прослушивания службы подписок 3x-ui" "$default_sub_addr")
    else
        CADDY_LISTEN_ADDR="127.0.0.1"
        XRAY_LISTEN_ADDR="127.0.0.1"
        PANEL_LISTEN_ADDR="$default_panel_addr"
        SUB_LISTEN_ADDR="$default_sub_addr"
        echo -e "${GREEN}Обычный режим: движок Web-обратного прокси, Xray, 3x-ui, подписки и бэкенд сайтов используют 127.0.0.1.${PLAIN}"
    fi

    CADDY_LISTEN_PORT=$(ask_with_default "$(web_proxy_engine_label "$WEB_PROXY_ENGINE")Порт прослушивания" "8443")
    XRAY_LISTEN_PORT=$(ask_with_default "Порт прослушивания Xray REALITY" "1443")
    PANEL_LISTEN_PORT=$(ask_with_default "Порт панели 3x-ui" "$default_panel_port")
    PANEL_WEB_PATH=$(normalize_path_prefix "$(ask_with_default "Публичный путь панели 3x-ui / webBasePath (должен совпадать с корневым путем URL панели)" "$default_panel_path")")
    SUB_LISTEN_PORT=$(ask_with_default "Порт службы подписок 3x-ui (можно настроить)" "$default_sub_port")
    SUB_URI_PATH=$(normalize_path_prefix "$(ask_with_default "Префикс пути для обычных подписок 3x-ui (без порта и клиентской подписки, рекомендуется /sub/)" "$default_sub_path")")
    CLASH_URI_PATH=$(normalize_path_prefix "$(ask_with_default "Префикс пути для подписок Clash/Mihomo 3x-ui (без клиентской подписки, рекомендуется /clash/)" "$default_clash_path")")
    local panel_whitelist_enabled panel_whitelist_input panel_whitelist_ranges current_client_ip
    local -a panel_whitelist_array=()
    read_trimmed panel_whitelist_enabled "Включить IP-белый список для домена панели? (y/n, по умолчанию n): "
    if is_yes "$panel_whitelist_enabled"; then
        if ! web_proxy_engine_supports_web_whitelist "${ENTRY_MODE:-nginx-stream}" "$WEB_PROXY_ENGINE"; then
            echo -e "${RED}❌ Режим xray-fallback не поддерживает веб-белый список.${PLAIN}"
            echo -e "${YELLOW}Пожалуйста, используйте режим входа Nginx Stream/TCP Peek.${PLAIN}"
            return 1
        fi
        current_client_ip=$(detect_ssh_client_ip)
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-адрес источника SSH может быть: ${current_client_ip}, убедитесь, что он добавлен в белый список.${PLAIN}"
        read_trimmed panel_whitelist_input "Введите IP/CIDR, разрешенные для доступа к домену панели (несколько через пробел или запятую): "
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
                SITE_BACKEND_ADDRS[$i]=$(ask_with_default "Адрес бэкенда для сайта ${SITE_DOMAINS[$i]}" "127.0.0.1")
            else
                SITE_BACKEND_ADDRS[$i]="127.0.0.1"
            fi
            SITE_BACKEND_PORTS[$i]=$(ask_with_default "Порт бэкенда для сайта ${SITE_DOMAINS[$i]}" "$default_site_port")
            default_site_port=$((default_site_port + 1))
        done
    fi

    echo -e "${YELLOW}Для одного входа 443 требуется, чтобы панель 3x-ui и бэкенд подписок использовали HTTP, а $(web_proxy_engine_label "$WEB_PROXY_ENGINE") унифицированно управлял публичными сертификатами.${PLAIN}"
    echo -e "${YELLOW}Этот мастер настроит $(web_proxy_engine_label "$WEB_PROXY_ENGINE") для подключения по HTTP к ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT} и ${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT}.${PLAIN}"
    echo -e "${CYAN}Обработка сертификатов делится на два случая:${PLAIN}"
    echo -e "  Новая установка 3x-ui 3.x: в официальном установщике выберите Skip SSL / не запрашивать SSL, этот шаг выполняет только проверку на случай ошибок."
    echo -e "  3x-ui 2.x, обновление старой конфигурации или если ранее был включен SSL 3x-ui: продолжайте по старому процессу очистки путей к сертификатам панели/подписок."
    local cert_clear_confirm
    read_trimmed cert_clear_confirm "Очистить ли сейчас пути к сертификатам панели/подписок 3x-ui в 2.x/старой конфигурации? (Y/n, по умолчанию yes): "
    cert_clear_confirm="${cert_clear_confirm:-yes}"
    if is_yes "$cert_clear_confirm"; then
        if ! clear_xui_cert_settings_for_single_443; then
            read_trimmed cert_clear_confirm "Не удалось автоматически подтвердить очистку, вы уже вручную очистили пути к сертификатам панели и подписок? (y/n, по умолчанию n): "
            is_yes "$cert_clear_confirm" || { echo -e "${YELLOW}Сначала вернитесь в 3x-ui, очистите пути к сертификатам, сохраните и перезапустите, затем запустите этот мастер.${PLAIN}"; return 1; }
        fi
    else
        read_trimmed cert_clear_confirm "Подтвердите, что вы вручную очистили пути к сертификатам панели и подписок? (y/n, по умолчанию n): "
        is_yes "$cert_clear_confirm" || { echo -e "${YELLOW}Сначала вернитесь в 3x-ui, очистите пути к сертификатам, сохраните и перезапустите, затем запустите этот мастер.${PLAIN}"; return 1; }
    fi

    echo -e "${CYAN}Введите токен API Cloudflare (требуется Zone.DNS.Edit + Zone.Zone.Read)${PLAIN}"
    read_secret_trimmed CF_TOKEN "CF Token: "

    PANEL_DOMAIN=$(normalize_domain_input "$panel_domain_input")
    REALITY_SNI=$(normalize_domain_input "$reality_sni_input")
    local site_idx
    for site_idx in "${!SITE_DOMAINS[@]}"; do
        SITE_DOMAINS[$site_idx]=$(normalize_domain_input "${SITE_DOMAINS[$site_idx]}")
        SITE_BACKEND_ADDRS[$site_idx]=$(normalize_backend_addr_input "${SITE_BACKEND_ADDRS[$site_idx]:-127.0.0.1}")
    done

    if ! is_valid_domain "$PANEL_DOMAIN"; then print_domain_validation_error "Домен панели" "$panel_domain_input" "$PANEL_DOMAIN"; return 1; fi
    if ! is_valid_domain "$REALITY_SNI"; then print_domain_validation_error "SNI REALITY" "$reality_sni_input" "$REALITY_SNI"; return 1; fi
    check_domain_dns_sanity "$PANEL_DOMAIN" "Домен панели" "prompt" || return 1
    check_domain_dns_sanity "$REALITY_SNI" "SNI REALITY" "prompt" || return 1
    local site_domain seen_domains
    seen_domains=" ${PANEL_DOMAIN} ${REALITY_SNI} "
    for site_idx in "${!SITE_DOMAINS[@]}"; do
        site_domain="${SITE_DOMAINS[$site_idx]}"
        [[ -z "$site_domain" ]] && continue
        if ! is_valid_domain "$site_domain"; then print_domain_validation_error "Домен сайта/обратного прокси" "${site_domain_raw_inputs[$site_idx]:-$site_domain}" "$site_domain"; return 1; fi
        if [[ "$site_domain" == "$PANEL_DOMAIN" || "$site_domain" == "$REALITY_SNI" || "$seen_domains" == *" ${site_domain} "* ]]; then
            echo -e "${RED}❌ Домен панели, домен сайта/обратного прокси и SNI REALITY не могут совпадать: ${site_domain}${PLAIN}"
            return 1
        fi
        check_domain_dns_sanity "$site_domain" "Домен сайта/обратного прокси" "prompt" || return 1
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
    is_valid_path_prefix "$SUB_URI_PATH" || { echo -e "${RED}❌ Неверный префикс пути для обычных подписок: ${SUB_URI_PATH}${PLAIN}"; return 1; }
    is_valid_path_prefix "$CLASH_URI_PATH" || { echo -e "${RED}❌ Неверный префикс пути для подписок Clash/Mihomo: ${CLASH_URI_PATH}${PLAIN}"; return 1; }
    if [[ "$PANEL_WEB_PATH" == "$SUB_URI_PATH" || "$PANEL_WEB_PATH" == "$CLASH_URI_PATH" || "$SUB_URI_PATH" == "$CLASH_URI_PATH" ]]; then
        echo -e "${RED}❌ Путь панели, путь обычных подписок и путь Clash/Mihomo не могут совпадать.${PLAIN}"
        return 1
    fi
    SITE_DOMAIN="${SITE_DOMAINS[0]:-}"
    SITE_BACKEND_ADDR="${SITE_BACKEND_ADDRS[0]:-127.0.0.1}"
    SITE_BACKEND_PORT="${SITE_BACKEND_PORTS[0]:-3000}"
    if [[ -n "${panel_whitelist_ranges:-}" ]]; then
        set_sni_ip_whitelist_for_domain "$PANEL_DOMAIN" "$panel_whitelist_ranges"
    fi
    [[ "$NGINX_LISTEN_PORT" != "443" ]] && echo -e "${YELLOW}⚠️  Публичный порт Nginx не 443, не рекомендуется.${PLAIN}"

    warn_if_public_bind "$(web_proxy_engine_label "$WEB_PROXY_ENGINE")" "$CADDY_LISTEN_ADDR" "$CADDY_LISTEN_PORT" || return 1
    warn_if_public_bind "Xray REALITY" "$XRAY_LISTEN_ADDR" "$XRAY_LISTEN_PORT" || return 1
    warn_if_public_bind "Панель 3x-ui" "$PANEL_LISTEN_ADDR" "$PANEL_LISTEN_PORT" || return 1
    warn_if_public_bind "Служба подписок 3x-ui" "$SUB_LISTEN_ADDR" "$SUB_LISTEN_PORT" || return 1
    for site_idx in "${!SITE_DOMAINS[@]}"; do
        [[ -n "${SITE_DOMAINS[$site_idx]}" ]] || continue
        confirm_backend_target_or_continue "Бэкенд сайта/обратного прокси ${SITE_DOMAINS[$site_idx]}" "${SITE_BACKEND_ADDRS[$site_idx]}" "${SITE_BACKEND_PORTS[$site_idx]}" || return 1
    done

    if [[ -z "$CF_TOKEN" || ${#CF_TOKEN} -lt 20 ]]; then echo -e "${RED}❌ Некорректная длина токена Cloudflare.${PLAIN}"; return 1; fi
    echo -e "${CYAN}▶ Выполняется онлайн-проверка токена Cloudflare...${PLAIN}"
    verify_cf_token_online "$CF_TOKEN"
    local verify_rc=$?
    if [[ "$verify_rc" -eq 0 ]]; then
        echo -e "${GREEN}✅ Проверка токена Cloudflare пройдена.${PLAIN}"
    elif [[ "$verify_rc" -eq 2 ]]; then
        echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку.${PLAIN}"
    else
        echo -e "${RED}❌ Проверка токена Cloudflare не удалась.${PLAIN}"
        return 1
    fi
}

install_caddy_if_needed() {
    command -v caddy >/dev/null 2>&1 && return 0
    echo -e "${CYAN}▶ Caddy не обнаружен, устанавливаем...${PLAIN}"
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
            echo -e "${RED}❌ Не удалось загрузить GPG-ключ Caddy.${PLAIN}"
            return 1
        fi
        if ! gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$key_tmp"; then
            rm -f "$key_tmp"
            rm -f "$repo_tmp"
            echo -e "${RED}❌ Не удалось записать GPG-ключ Caddy.${PLAIN}"
            return 1
        fi
        if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$repo_tmp"; then
            rm -f "$key_tmp"
            rm -f "$repo_tmp"
            echo -e "${RED}❌ Не удалось загрузить конфигурацию APT-репозитория Caddy.${PLAIN}"
            return 1
        fi
        if ! mv "$repo_tmp" /etc/apt/sources.list.d/caddy-stable.list; then
            rm -f "$key_tmp"
            rm -f "$repo_tmp"
            echo -e "${RED}❌ Не удалось записать конфигурацию APT-репозитория Caddy.${PLAIN}"
            return 1
        fi
        rm -f "$key_tmp"
        install_pkg caddy || return 1
    elif is_redhat; then
        install_pkg yum-utils || true
        if command -v yum-config-manager >/dev/null 2>&1; then
            yum-config-manager --add-repo https://openrepo.io/repo/caddy/caddy.repo >/dev/null 2>&1 || return 1
        else
            echo -e "${YELLOW}⚠️ yum-config-manager не обнаружен, будет выполнена попытка установки Caddy из системного репозитория.${PLAIN}"
        fi
        install_pkg caddy || return 1
    else
        echo -e "${RED}❌ Автоматическая установка Caddy на текущей системе не поддерживается.${PLAIN}"
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
    echo -e "${CYAN}▶ Проверяем компоненты Nginx stream...${PLAIN}"
    local need_install=0
    local nginx_build
    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Nginx не обнаружен, устанавливаем базовые компоненты...${PLAIN}"
        need_install=1
    else
        nginx_build=$(nginx -V 2>&1 || true)
    fi

    if [[ "$need_install" -eq 0 ]]; then
        if [[ "$nginx_build" == *"--with-stream=dynamic"* ]]; then
            if grep -Rqs 'load_module .*ngx_stream_module\.so' /etc/nginx/nginx.conf /etc/nginx/modules-enabled 2>/dev/null; then
                echo -e "${GREEN}✅ Обнаружена конфигурация загрузки динамического модуля Nginx stream, пропускаем установку.${PLAIN}"
            else
                echo -e "${YELLOW}⚠️ Nginx поддерживает динамический модуль stream, но не подтверждена загрузка модуля, пробуем установить недостающие модули...${PLAIN}"
                need_install=1
            fi
        elif [[ "$nginx_build" == *"--with-stream"* || "$nginx_build" == *"--with-stream_ssl_preread_module"* ]]; then
            echo -e "${GREEN}✅ Обнаружена статическая поддержка Nginx stream, пропускаем установку.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Поддержка Nginx stream не подтверждена, пробуем установить недостающие модули...${PLAIN}"
            need_install=1
        fi
    fi

    if [[ "$need_install" -eq 1 ]]; then
        if is_debian; then
            install_pkg nginx libnginx-mod-stream
        elif is_redhat; then
            install_pkg nginx
            install_pkg nginx-mod-stream || echo -e "${YELLOW}⚠️ Установка nginx-mod-stream не удалась или отсутствует в репозитории, продолжаем проверку поддержки Nginx stream.${PLAIN}"
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
        echo -e "${YELLOW}⚠️ Изолировано ${moved} конфигураций сайтов Nginx по умолчанию в: ${quarantine_dir}${PLAIN}"
    fi
    echo -e "${GREEN}✅ Отключено отображение версии Nginx и записано правило по умолчанию для порта 80 (отбрасывать).${PLAIN}"
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
# Managed by VPS-Optimize 443 single-entry. Local HTTPS Web proxy only.
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
        echo -e "${YELLOW}⚠️ Изолировано ${moved} старых конфигураций локального Web-обратного прокси Nginx для 443.${PLAIN}"
        reload_nginx_after_config_quarantine || echo -e "${YELLOW}⚠️ Не удалось немедленно перезагрузить Nginx после изоляции конфигурации, проверка будет выполнена на этапе применения.${PLAIN}"
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
        echo -e "${YELLOW}⚠️ Изолировано ${moved} старых конфигураций локального Web-обратного прокси Caddy для 443.${PLAIN}"
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
        echo -e "${RED}❌ Проверка конфигурации локального Web-обратного прокси Nginx не удалась, новая конфигурация изолирована.${PLAIN}"
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

    echo -e "${CYAN}▶ Предварительная проверка планируемой конфигурации Caddy, без изменений в /etc/caddy...${PLAIN}"
    if caddy validate --config "${plan_dir}/Caddyfile" >"$validate_log" 2>&1; then
        echo -e "${GREEN}✅ Проверка планируемой конфигурации Caddy пройдена.${PLAIN}"
        return 0
    fi

    echo -e "${RED}❌ Проверка планируемой конфигурации Caddy не удалась, запись и переключение остановлены.${PLAIN}"
    echo -e "${YELLOW}Каталог предварительной проверки: ${plan_dir}${PLAIN}"
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
    echo -e "${CYAN}▶ Запрашиваем сертификат Cloudflare DNS для ${domain}...${PLAIN}"
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
    echo -e "${YELLOW}Опционально: брандмауэр оставляет только порты SSH и публичного входа Nginx.${PLAIN}"
    echo -e "${YELLOW}Напоминание: если 3x-ui все еще прослушивает 0.0.0.0:${PANEL_LISTEN_PORT}, функция скрипта «автоматическое добавление текущих активных портов» может снова разрешить его.${PLAIN}"
    read_trimmed yn "Затянуть правила брандмауэра сейчас? (y/n, по умолчанию n): "
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
        echo -e "${YELLOW}⚠️ ufw/firewalld не обнаружены, пропускаем ужесточение брандмауэра.${PLAIN}"
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
        "xray-fallback") entry_label="Режим Xray Fallback"; entry_listener="основной входящий Xray/3x-ui" ;;
        "tcp-peek") entry_label="Режим TCP Peek + Splice"; entry_listener="мультиплексор vpso-mux" ;;
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
    echo -e "${GREEN}✅ Конфигурация разделения трафика для одного входа 443 завершена${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "Текущий режим входа: ${entry_label} (${entry_mode})"
    echo -e "Текущий движок Web-обратного прокси: ${web_label} (${web_engine})"
    echo -e "${BOLD}I. В дальнейшем извне обращайтесь только к этим адресам${PLAIN}"
    echo -e "  Вход в панель:      https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "  Вход для обычных подписок:  https://${PANEL_DOMAIN}${SUB_URI_PATH}"
    echo -e "  Clash/Mihomo:  https://${PANEL_DOMAIN}${CLASH_URI_PATH}"
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local i
        for i in "${!SITE_DOMAINS[@]}"; do
            echo -e "  Вход для сайта/обратного прокси: https://${SITE_DOMAINS[$i]}/"
        done
    fi
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            echo -e "  Входящий TCP/SNI:  ${TCP_ROUTE_SNIS[$tcp_i]}:${NGINX_LISTEN_PORT} -> ${TCP_ROUTE_ADDRS[$tcp_i]}:${TCP_ROUTE_PORTS[$tcp_i]}"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            echo -e "  Входящий Xray:     ${XRAY_SNI_ROUTE_SNIS[$xray_route_i]}:${NGINX_LISTEN_PORT} -> ${XRAY_SNI_ROUTE_ADDRS[$xray_route_i]}:${XRAY_SNI_ROUTE_PORTS[$xray_route_i]}"
        done
    fi
    echo -e "  Порт REALITY:  ${NGINX_LISTEN_PORT}"
    echo -e ""
    echo -e "${YELLOW}Не обращайтесь к этим внутренним портам из публичной сети: ${CADDY_LISTEN_PORT}/${XRAY_LISTEN_PORT}/${PANEL_LISTEN_PORT}/${SUB_LISTEN_PORT}/${SITE_BACKEND_PORTS[*]} ${TCP_ROUTE_PORTS[*]} ${XRAY_SNI_ROUTE_PORTS[*]}${PLAIN}"
    echo -e "${YELLOW}Они должны использоваться только для внутренних соединений между службами на этом хосте, не для входа через браузер.${PLAIN}"
    echo -e ""
    echo -e "${BOLD}II. Рекомендации по настройке панели 3x-ui${PLAIN}"
    echo -e "  Адрес прослушивания панели: ${PANEL_LISTEN_ADDR}"
    echo -e "  Порт панели:    ${PANEL_LISTEN_PORT}"
    echo -e "  webBasePath: ${PANEL_WEB_PATH}"
    echo -e "  Для новой установки 3.x опция SSL: Skip SSL / не запрашивать SSL"
    echo -e "  Для 2.x/старой конфигурации пути к сертификату панели/закрытому ключу: очистить"
    echo -e "  Подключение бэкенда движка Web-обратного прокси: http://${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "  Panel URL / Public URL / External URL: https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "  Subscription URI Path: ${SUB_URI_PATH}"
    echo -e "  Subscription External URL: https://${PANEL_DOMAIN}${SUB_URI_PATH}"
    echo -e "  Clash/Mihomo URI Path: ${CLASH_URI_PATH}"
    echo -e "  Clash/Mihomo External URL: https://${PANEL_DOMAIN}${CLASH_URI_PATH}"
    echo -e "${YELLOW}Не рекомендуется использовать webBasePath=/, случайный путь панели снижает вероятность попадания под массовое сканирование.${PLAIN}"
    echo -e "  Для 2.x/старой конфигурации пути к сертификату подписок/закрытому ключу: очистить"
    echo -e ""
    echo -e "${BOLD}III. Заполните входящий REALITY Xray / 3x-ui следующим образом${PLAIN}"
    echo -e "  Адрес прослушивания входящего listen: ${XRAY_LISTEN_ADDR}"
    echo -e "  Порт прослушивания входящего port:  ${XRAY_LISTEN_PORT}"
    echo -e "  Протокол protocol:      VLESS"
    echo -e "  Сеть network:       tcp"
    echo -e "  Безопасность security:      reality"
    echo -e "  REALITY dest:       ${REALITY_SNI}:443"
    echo -e "  serverNames:        ${REALITY_SNI}"
    echo -e "  SpiderX:            /"
    echo -e "  Адрес подключения клиента:     ваш IP-адрес сервера или домен, разрешенный на сервер"
    echo -e "  Порт подключения клиента:     ${NGINX_LISTEN_PORT}"
    echo -e "  SNI/serverName клиента: ${REALITY_SNI}"
    echo -e "${YELLOW}Внимание: dest/serverNames REALITY должны быть внешним реальным сайтом, не пишите домен панели.${PLAIN}"
    echo -e ""
    echo -e "${BOLD}IV. Как определить частые ошибки${PLAIN}"
    echo -e "  ERR_SSL_PROTOCOL_ERROR: обычно возникает при обращении к внутреннему порту, извне обращайтесь только к https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "  ERR_TOO_MANY_REDIRECTS: обычно возникает при ошибочном включении SSL 3x-ui в 3.x, неочищенных путях к сертификатам в 2.x/старой конфигурации или несоответствии внешнего адреса/пути"
    echo -e "  HTTP 404: сначала проверьте, соответствует ли путь доступа webBasePath 3x-ui, затем проверьте, проксирует ли движок Web-обратного прокси на ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT}"
    echo -e "  502 Bad Gateway: обычно возникает, если 3x-ui не запущен, порт неверен или бэкенд 3x-ui все еще использует HTTPS"
    echo -e ""
    echo -e "${BOLD}V. Конфигурация входа и бэкенда${PLAIN}"
    echo -e "  ${NGINX_LISTEN_ADDR}:${NGINX_LISTEN_PORT} -> ${entry_listener}"
    echo -e "  ${CADDY_LISTEN_ADDR}:${CADDY_LISTEN_PORT} -> ${web_label}"
    echo -e "  ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT} -> xray"
    echo -e "  ${PANEL_LISTEN_ADDR}:${PANEL_LISTEN_PORT} -> 3x-ui"
    echo -e "  ${SUB_LISTEN_ADDR}:${SUB_LISTEN_PORT} -> подписки 3x-ui"
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local i
        for i in "${!SITE_DOMAINS[@]}"; do
            echo -e "  ${SITE_BACKEND_ADDRS[$i]}:${SITE_BACKEND_PORTS[$i]} -> бэкенд сайта ${SITE_DOMAINS[$i]}"
        done
    fi
    if [[ ${#TCP_ROUTE_SNIS[@]} -gt 0 ]]; then
        local tcp_i
        for tcp_i in "${!TCP_ROUTE_SNIS[@]}"; do
            echo -e "  ${TCP_ROUTE_ADDRS[$tcp_i]}:${TCP_ROUTE_PORTS[$tcp_i]} -> входящий TCP/SNI ${TCP_ROUTE_SNIS[$tcp_i]}"
        done
    fi
    if [[ ${#XRAY_SNI_ROUTE_SNIS[@]} -gt 0 ]]; then
        local xray_route_i
        for xray_route_i in "${!XRAY_SNI_ROUTE_SNIS[@]}"; do
            echo -e "  ${XRAY_SNI_ROUTE_ADDRS[$xray_route_i]}:${XRAY_SNI_ROUTE_PORTS[$xray_route_i]} -> входящий Xray ${XRAY_SNI_ROUTE_SNIS[$xray_route_i]}"
        done
    fi
    echo -e ""
    echo -e "${BOLD}VI. Команды для проверки${PLAIN}"
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
    echo -e "  openssl s_client -connect IP_сервера:${NGINX_LISTEN_PORT} -servername ${PANEL_DOMAIN}"
    echo -e "  openssl s_client -connect IP_сервера:${NGINX_LISTEN_PORT} -servername ${REALITY_SNI}"
    [[ "$web_engine" == "nginx" ]] && echo -e "  journalctl -u nginx -n 80 --no-pager"
    echo -e "  journalctl -u x-ui -u 3x-ui -n 80 --no-pager"
    echo -e ""
    case "$entry_mode" in
        "xray-fallback")
            echo -e "${RED}Категорически не делайте: не позволяйте движку Web-обратного прокси прослушивать публичный 443; не выставляйте панель 3x-ui, службу подписок или дополнительные локальные входящие в публичную сеть; не включайте SSL 3x-ui при установке 3.x и не запускайте Web fallback без очистки путей к сертификатам в 2.x/старой конфигурации; не пишите домен панели в REALITY dest/serverNames.${PLAIN}"
            ;;
        *)
            echo -e "${RED}Категорически не делайте: не позволяйте движку Web-обратного прокси прослушивать публичный 443; не позволяйте основному входящему Xray/3x-ui занимать публичный 443; не выставляйте панель 3x-ui или дополнительные локальные входящие в публичную сеть; не включайте SSL 3x-ui при установке 3.x и не запускайте 443 без очистки путей к сертификатам в 2.x/старой конфигурации; не пишите домен панели в REALITY dest/serverNames.${PLAIN}"
            ;;
    esac
}

apply_sni_stack_runtime_config() {
    local backup_dir current_mode
    current_mode="${ENTRY_MODE:-$(get_entry_mode)}"
    current_mode=$(normalize_entry_mode_name "$current_mode" 2>/dev/null || echo "nginx-stream")

    create_sni_stack_backup
    backup_dir=$(cat /etc/vps-optimize/sni-stack.last-backup 2>/dev/null)
    guard_current_ssh_not_on_entry_port "Повторное применение параметров работы одного входа 443" || return 1
    check_entry_mode_dependencies "$current_mode" || { rollback_sni_stack_after_failure "$backup_dir" "Проверка зависимостей режима входа не удалась"; return 1; }
    preflight_entry_mode_before_cutover "$current_mode" || { echo -e "${RED}❌ Предварительная проверка режима входа ${current_mode} не удалась, публичный 443 не был повторно применен.${PLAIN}"; return 1; }
    stop_public_443_entry_services_for_target "$current_mode" || { rollback_sni_stack_after_failure "$backup_dir" "Не удалось остановить старые службы входа на публичный 443"; return 1; }
    apply_entry_mode_by_name "$current_mode" "$backup_dir" || { rollback_sni_stack_after_failure "$backup_dir" "Не удалось применить режим входа ${current_mode}"; return 1; }
    ENTRY_MODE="$current_mode"
    save_sni_stack_env
    write_single_443_engine_state "$(entry_mode_engine_name "$current_mode")" "$backup_dir"
    generate_caddy_cf_manifest
}
