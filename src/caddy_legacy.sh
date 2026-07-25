# shellcheck shell=bash
# Отключённая заглушка совместимости со старым мастером Caddy + Reality.

func_caddy_cf_reality_wizard_legacy_disabled() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧩 Мастер автоматизации Reality 443 + Cloudflare DNS${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Этот мастер заставит Caddy слушать только локальный порт, не занимая публичные 80/443.${PLAIN}"
    echo -e "${YELLOW}Рекомендуется для: 3x-ui Reality уже занял 443, но веб-службам нужен HTTPS на том же домене.${PLAIN}"
    echo -e "------------------------------------------------"

    read_trimmed reality_occupied "❓ Порт 443 уже занят VLESS-Reality 3x-ui? (y/n): "
    if is_no "$reality_occupied"; then
        echo -e "${BLUE}ℹ️ Вы выбрали, что 443 не занят, мастер всё равно будет использовать локальный режим во избежание конфликтов.${PLAIN}"
    fi

    local listen_port
    read_trimmed listen_port "👉 Введите локальный TLS-порт Caddy (по умолчанию 8443): "
    listen_port=${listen_port:-8443}
    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [[ "$listen_port" -lt 1 || "$listen_port" -gt 65535 ]]; then
        echo -e "${RED}❌ Неверный порт! Должен быть 1-65535.${PLAIN}"
        return
    fi
    if is_yes "$reality_occupied" && [[ "$listen_port" -eq 443 ]]; then
        echo -e "${RED}❌ 443 уже используется Reality, используйте локальный высокий порт (например 8443/9443).${PLAIN}"
        return
    fi

    local cf_token
    echo -e "${CYAN}👇 Введите Cloudflare API Token (нужны права Zone.DNS.Edit)${PLAIN}"
    read_secret_trimmed cf_token "CF Token: "
    if [[ -z "$cf_token" || ${#cf_token} -lt 20 ]]; then
        echo -e "${RED}❌ Неверная длина Token, отмена.${PLAIN}"
        return
    fi
    echo -e "${CYAN}▶ Онлайн-проверка Cloudflare Token...${PLAIN}"
    verify_cf_token_online "$cf_token"
    local verify_rc=$?
    if [[ "$verify_rc" -eq 0 ]]; then
        echo -e "${GREEN}✅ Проверка Token пройдена.${PLAIN}"
    elif [[ "$verify_rc" -eq 2 ]]; then
        echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку.${PLAIN}"
    else
        echo -e "${RED}❌ Ошибка онлайн-проверки Token: проверьте права или правильность ввода.${PLAIN}"
        echo -e "${YELLOW}Требуются права: Zone.DNS.Edit + Zone.Zone.Read${PLAIN}"
        return
    fi

    if ! install_caddy_if_needed; then
        echo -e "${RED}❌ Не удалось установить Caddy, проверьте сеть.${PLAIN}"
        return
    fi

    local acme_bin="/root/.acme.sh/acme.sh"
    local acme_email
    acme_email=$(get_acme_account_email)
    if [[ ! -x "$acme_bin" ]]; then
        if ! install_acme_sh "$acme_email"; then
            echo -e "${RED}❌ Не удалось установить acme.sh, проверьте сеть.${PLAIN}"
            return
        fi
    fi
    if [[ ! -x "$acme_bin" ]]; then
        echo -e "${RED}❌ acme.sh не найден или неисполняем.${PLAIN}"
        return
    fi
    if ! prepare_acme_account "$acme_bin" "$acme_email"; then
        echo -e "${RED}❌ Не удалось инициализировать аккаунт acme.${PLAIN}"
        return
    fi

    local cf_env_dir="/root/.config/vps-panel"
    local cf_env_file="${cf_env_dir}/cloudflare.env"
    mkdir -p "$cf_env_dir"
    chmod 700 "$cf_env_dir"
    local escaped_token
    escaped_token=${cf_token//\'/\'"\'"\'}
    printf "CF_Token='%s'\n" "$escaped_token" > "$cf_env_file"
    chmod 600 "$cf_env_file"

    mkdir -p /etc/caddy/conf.d /etc/caddy/certs /root/cert

    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        cat <<EOF > /etc/caddy/Caddyfile
# Управляется VPS-Optimize
import conf.d/*
EOF
    elif ! grep -q "import conf.d/\*" /etc/caddy/Caddyfile; then
        echo -e "\nimport conf.d/*" >> /etc/caddy/Caddyfile
    fi

    echo -e "${CYAN}▶ Сканирование и изоляция старых конфигураций Caddy (во избежание захвата 443)...${PLAIN}"
    quarantine_legacy_caddy_443_configs

    echo -e "${YELLOW}👇 Добавление правил обратного прокси для доменов (можно несколько)${PLAIN}"
    echo -e "${YELLOW}Формат: домен -> локальный порт, например panel.example.com -> 8000${PLAIN}"
    echo -e "------------------------------------------------"

    local success_count=0
    local fail_count=0
    local summary_file="/root/cert/caddy_cf_manifest.txt"

    while true; do
        local domain domain_input backend_port continue_add
        read_trimmed domain_input "👉 Введите домен (Enter для завершения): "
        domain=$(normalize_domain_input "$domain_input")
        if [[ -z "$domain" ]]; then
            break
        fi

        if ! is_valid_domain "$domain"; then
            print_domain_validation_error "домен" "$domain_input" "$domain"
            ((fail_count++))
            continue
        fi

        read_trimmed backend_port "👉 Введите локальный порт бэкенда для этого домена: "
        if ! is_valid_port "$backend_port"; then
            echo -e "${RED}❌ Неверный порт: $backend_port${PLAIN}"
            ((fail_count++))
            continue
        fi

        local conf_file="/etc/caddy/conf.d/${domain}.caddy"
        if [[ -f "$conf_file" ]]; then
            echo -e "${RED}❌ Конфигурация для домена уже существует: $conf_file${PLAIN}"
            ((fail_count++))
            continue
        fi

        # shellcheck disable=SC1090
        source "$cf_env_file"
        echo -e "${CYAN}▶ Запрос сертификата DNS для ${domain}...${PLAIN}"
        if ! issue_cf_dns_cert_with_retry "$domain" "$CF_Token" "$acme_bin"; then
            echo -e "${RED}❌ Ошибка запроса сертификата: ${domain}${PLAIN}"
            echo -e "${YELLOW}   Подсказка: используйте главное меню [19] -> [12] -> [14] для автоматического исправления.${PLAIN}"
            ((fail_count++))
            continue
        fi

        local cert_file="/etc/caddy/certs/${domain}.crt"
        local key_file="/etc/caddy/certs/${domain}.key"

        if ! "$acme_bin" --install-cert -d "$domain" --ecc \
            --fullchain-file "$cert_file" \
            --key-file "$key_file" \
            --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true" >/dev/null 2>&1; then
            echo -e "${RED}❌ Ошибка установки сертификата: ${domain}${PLAIN}"
            ((fail_count++))
            continue
        fi

        if id caddy >/dev/null 2>&1; then
            chown root:caddy "$cert_file" "$key_file" >/dev/null 2>&1
            chmod 640 "$cert_file" "$key_file"
        else
            chmod 600 "$cert_file" "$key_file"
        fi

        ln -sfn "$cert_file" "/root/cert/${domain}.crt"
        ln -sfn "$key_file" "/root/cert/${domain}.key"

        cat <<EOF > "$conf_file"
https://${domain}:${listen_port} {
    bind 127.0.0.1
    tls ${cert_file} ${key_file}
    reverse_proxy 127.0.0.1:${backend_port}
}
EOF

        echo -e "${GREEN}✅ Домен ${domain} готов: сертификат выдан + прокси настроен.${PLAIN}"
        ((success_count++))

        read_trimmed continue_add "Продолжить добавление следующего домена? (y/n): "
        if ! is_yes "$continue_add"; then
            break
        fi
    done

    echo -e "${CYAN}▶ Проверка и загрузка конфигурации Caddy...${PLAIN}"
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        systemctl enable caddy >/dev/null 2>&1
        systemctl restart caddy >/dev/null 2>&1
        echo -e "${GREEN}✅ Caddy успешно перезагружен, конфигурация активна.${PLAIN}"
    else
        echo -e "${RED}❌ Проверка конфигурации Caddy не удалась! Проверьте синтаксис новых файлов в /etc/caddy/conf.d/.${PLAIN}"
        echo -e "${YELLOW}Сертификаты сохранены, после исправления конфигурации выполните: systemctl restart caddy${PLAIN}"
    fi

    generate_caddy_cf_manifest

    echo -e "------------------------------------------------"
    echo -e "${GREEN}🎯 Мастер выполнен: успешно ${success_count}, ошибок ${fail_count}.${PLAIN}"
    echo -e "${CYAN}Каталог символических ссылок сертификатов:${PLAIN} /root/cert"
    echo -e "${CYAN}Файл манифеста:${PLAIN} ${summary_file}"
    echo -e "${YELLOW}💡 Ручная настройка 3x-ui:${PLAIN}"
    echo -e "1) В узле Reality установите fallback/dest на: 127.0.0.1:${listen_port}"
    echo -e "2) Каждый fallback SNI должен соответствовать введённому домену для корректного попадания на сертификат и прокси"
    echo -e "3) Если нужен реальный IP посетителя, позже включите PROXY Protocol"
}

# ---------------------------------------------------------
# Новая функция: меню обслуживания сертификатов CF DNS
# ---------------------------------------------------------
