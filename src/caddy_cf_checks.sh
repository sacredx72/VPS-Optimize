# shellcheck shell=bash
# Проверки состояния сертификатов Cloudflare/Caddy и автоматическое исправление.

func_caddy_cf_health_check() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🩺 Быстрая проверка CF DNS${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local ok_count=0
    local warn_count=0
    local err_count=0
    local cf_env_file="/root/.config/vps-panel/cloudflare.env"

    echo -e "${YELLOW}▶ [1/5] Проверка Cloudflare Token ...${PLAIN}"
    if [[ -f "$cf_env_file" ]]; then
        # shellcheck disable=SC1090
        source "$cf_env_file"
        if [[ -n "$CF_Token" ]]; then
            if command -v curl >/dev/null 2>&1; then
                local verify_resp
                verify_resp=$(curl -s --max-time 8 -H "Authorization: Bearer ${CF_Token}" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)
                if echo "$verify_resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
                    echo -e "${GREEN}✅ Проверка Cloudflare Token пройдена${PLAIN}"
                    ((ok_count++))
                else
                    echo -e "${YELLOW}⚠️ Файл Token существует, но онлайн-проверка не удалась (возможно, недостаточно прав/сетевые проблемы)${PLAIN}"
                    ((warn_count++))
                fi
            else
                echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку.${PLAIN}"
                ((warn_count++))
            fi
        else
            echo -e "${RED}❌ Файл Token пуст, перезапишите в меню обслуживания [2].${PLAIN}"
            ((err_count++))
        fi
    else
        echo -e "${RED}❌ Файл Token не найден: ${cf_env_file}${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [2/5] Проверка состояния службы Caddy...${PLAIN}"
    if command -v caddy >/dev/null 2>&1; then
        if systemctl is-active --quiet caddy; then
            echo -e "${GREEN}✅ Caddy работает${PLAIN}"
            ((ok_count++))
        else
            echo -e "${YELLOW}⚠️ Caddy установлен, но не запущен${PLAIN}"
            ((warn_count++))
        fi
    else
        echo -e "${RED}❌ Caddy не установлен${PLAIN}"
        ((err_count++))
    fi

    echo -e "${YELLOW}▶ [3/5] Проверка конфигураций доменов, сертификатов и символических ссылок...${PLAIN}"
    local domain_count=0
    if [[ -d /etc/caddy/conf.d ]]; then
        while IFS= read -r conf_file; do
            local domain
            local listen_addr
            local listen_port
            local listen_target
            local backend
            local backend_addr
            local backend_port
            local cert_file
            local key_file
            local cert_end
            local cert_ts
            local now_ts
            local days_left

            domain=$(basename "$conf_file" .caddy)
            cert_file="/etc/caddy/certs/${domain}.crt"
            key_file="/etc/caddy/certs/${domain}.key"

            if ! head -n1 "$conf_file" | grep -q '^https://'; then
                continue
            fi
            ((domain_count++))

            listen_addr=$(caddy_conf_site_bind_addr "$conf_file")
            listen_port=$(caddy_conf_site_listen_port "$conf_file")
            listen_target=$(caddy_conf_site_listen_target "$conf_file")
            backend=$(caddy_conf_first_reverse_proxy_target "$conf_file")
            backend_addr=$(caddy_reverse_proxy_target_host "$backend")
            backend_port=$(caddy_reverse_proxy_target_port "$backend")

            echo -e "${CYAN}  - Домен: ${domain}${PLAIN}"

            if [[ -f "$cert_file" && -f "$key_file" ]]; then
                cert_end=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2-)
                cert_ts=$(date -d "$cert_end" +%s 2>/dev/null)
                now_ts=$(date +%s)
                days_left=$(( (cert_ts - now_ts) / 86400 ))

                if [[ -n "$cert_end" && "$days_left" -gt 15 ]]; then
                    echo -e "    ${GREEN}Сертификат: норма (осталось ${days_left} дн.)${PLAIN}"
                    ((ok_count++))
                elif [[ -n "$cert_end" ]]; then
                    echo -e "    ${YELLOW}Сертификат: скоро истекает (осталось ${days_left} дн.)${PLAIN}"
                    ((warn_count++))
                else
                    echo -e "    ${RED}Сертификат: не удалось прочитать срок действия${PLAIN}"
                    ((err_count++))
                fi
            else
                echo -e "    ${RED}Сертификат отсутствует: /etc/caddy/certs/${domain}.crt|.key${PLAIN}"
                ((err_count++))
            fi

            if [[ -L "/root/cert/${domain}.crt" && -e "/root/cert/${domain}.crt" && -L "/root/cert/${domain}.key" && -e "/root/cert/${domain}.key" ]]; then
                echo -e "    ${GREEN}Символические ссылки: /root/cert правильно${PLAIN}"
                ((ok_count++))
            else
                echo -e "    ${YELLOW}Символические ссылки: отсутствуют или повреждены, выполните обслуживание [10] для восстановления${PLAIN}"
                ((warn_count++))
            fi

            [[ -z "$listen_target" ]] && listen_target="неизвестно"
            if [[ -n "$listen_port" ]] && caddy_listen_addr_port_is_visible "$listen_addr" "$listen_port"; then
                echo -e "    ${GREEN}Прослушивание: локальный порт ${listen_target} виден${PLAIN}"
                ((ok_count++))
            else
                echo -e "    ${YELLOW}Прослушивание: не обнаружено ${listen_target}${PLAIN}"
                ((warn_count++))
            fi

            [[ -z "$backend" ]] && backend="неизвестно"
            if [[ -z "$backend_addr" || -z "$backend_port" ]]; then
                echo -e "    ${YELLOW}⚠️ Бэкенд: не удалось прочитать адрес бэкенда из конфигурации${PLAIN}"
                ((warn_count++))
            elif probe_backend_target "    Бэкенд" "$backend_addr" "$backend_port"; then
                ((ok_count++))
            else
                ((warn_count++))
            fi
        done < <(find /etc/caddy/conf.d -maxdepth 1 -type f -name "*.caddy" 2>/dev/null | sort)
    fi

    if [[ "$domain_count" -eq 0 ]]; then
        echo -e "${YELLOW}⚠️ Не обнаружено конфигураций доменов, управляемых этой функцией (https://домен:порт).${PLAIN}"
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [4/5] Проверка файла манифеста...${PLAIN}"
    if [[ -f /root/cert/caddy_cf_manifest.txt ]]; then
        echo -e "${GREEN}✅ Файл манифеста существует: /root/cert/caddy_cf_manifest.txt${PLAIN}"
        ((ok_count++))
    else
        echo -e "${YELLOW}⚠️ Файл манифеста отсутствует, выполните обслуживание [11] для восстановления.${PLAIN}"
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [5/5] Итог...${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${CYAN}Результат проверки: ${GREEN}${ok_count} OK${PLAIN} / ${YELLOW}${warn_count} предупреждений${PLAIN} / ${RED}${err_count} ошибок${PLAIN}"
    if [[ "$err_count" -gt 0 ]]; then
        echo -e "${RED}Рекомендуется сначала исправить ошибки перед переключением трафика.${PLAIN}"
    elif [[ "$warn_count" -gt 0 ]]; then
        echo -e "${YELLOW}Можно продолжать, но рекомендуется обработать предупреждения для повышения стабильности.${PLAIN}"
    else
        echo -e "${GREEN}Проверка не выявила проблем.${PLAIN}"
    fi
}

func_caddy_cf_auto_fix() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧰 Автоматическое исправление CF DNS${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local fixed_count=0
    local warn_count=0
    local fail_count=0
    local cf_env_file="/root/.config/vps-panel/cloudflare.env"
    local acme_bin="/root/.acme.sh/acme.sh"

    echo -e "${YELLOW}▶ [1/7] Восстановление базовых каталогов и основной конфигурации...${PLAIN}"
    mkdir -p /root/cert /etc/caddy/certs /etc/caddy/conf.d /root/.config/vps-panel
    chmod 700 /root/.config/vps-panel >/dev/null 2>&1

    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        cat <<EOF > /etc/caddy/Caddyfile
# Managed by VPS-Optimize
import conf.d/*
EOF
        ((fixed_count++))
    elif ! grep -q "import conf.d/\*" /etc/caddy/Caddyfile; then
        echo -e "\nimport conf.d/*" >> /etc/caddy/Caddyfile
        ((fixed_count++))
    fi

    echo -e "${YELLOW}▶ [1.5/7] Изоляция старых конфигураций сайтов (во избежание захвата 443)...${PLAIN}"
    quarantine_legacy_caddy_443_configs

    echo -e "${YELLOW}▶ [2/7] Восстановление прав на сертификаты...${PLAIN}"
    if [[ -d /etc/caddy/certs ]]; then
        if id caddy >/dev/null 2>&1; then
            chown root:caddy /etc/caddy/certs/* 2>/dev/null
            chmod 640 /etc/caddy/certs/* 2>/dev/null
        else
            chmod 600 /etc/caddy/certs/* 2>/dev/null
        fi
        ((fixed_count++))
    else
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [3/7] Полное восстановление символических ссылок /root/cert...${PLAIN}"
    local relink_count=0
    if [[ -d /etc/caddy/certs ]]; then
        while IFS= read -r cert_path; do
            local domain
            domain=$(basename "$cert_path" .crt)
            if [[ -f "/etc/caddy/certs/${domain}.key" ]]; then
                ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
                ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
                ((relink_count++))
            fi
        done < <(find /etc/caddy/certs -maxdepth 1 -type f -name "*.crt" 2>/dev/null | sort)
    fi
    echo -e "${GREEN}✅ Восстановлено ${relink_count} групп символических ссылок.${PLAIN}"
    ((fixed_count++))

    echo -e "${YELLOW}▶ [4/7] Автоматическое продление сертификатов с истекающим сроком...${PLAIN}"
    local renew_count=0
    local renew_fail=0
    if [[ -x "$acme_bin" && -f "$cf_env_file" ]]; then
        # shellcheck disable=SC1090
        source "$cf_env_file"
        if [[ -n "$CF_Token" ]]; then
            while IFS= read -r conf_file; do
                local domain
                local cert_file
                local cert_end
                local cert_ts
                local now_ts
                local days_left

                domain=$(basename "$conf_file" .caddy)
                cert_file="/etc/caddy/certs/${domain}.crt"

                if ! head -n1 "$conf_file" | grep -q '^https://'; then
                    continue
                fi
                if [[ ! -f "$cert_file" ]]; then
                    continue
                fi

                cert_end=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2-)
                cert_ts=$(date -d "$cert_end" +%s 2>/dev/null)
                now_ts=$(date +%s)
                days_left=$(( (cert_ts - now_ts) / 86400 ))

                if [[ -z "$cert_end" || "$days_left" -le 15 ]]; then
                    if issue_cf_dns_cert_with_retry "$domain" "$CF_Token" "$acme_bin"; then
                        "$acme_bin" --install-cert -d "$domain" --ecc \
                            --fullchain-file "/etc/caddy/certs/${domain}.crt" \
                            --key-file "/etc/caddy/certs/${domain}.key" \
                            --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true" >/dev/null 2>&1
                        ((renew_count++))
                    else
                        ((renew_fail++))
                    fi
                fi
            done < <(find /etc/caddy/conf.d -maxdepth 1 -type f -name "*.caddy" 2>/dev/null | sort)

            if [[ "$renew_fail" -gt 0 ]]; then
                ((warn_count+=renew_fail))
            fi
            echo -e "${GREEN}✅ Автоматическое продление выполнено: успешно ${renew_count}, ошибок ${renew_fail}.${PLAIN}"
            ((fixed_count++))
        else
            echo -e "${YELLOW}⚠️ Token пуст, пропускаем автоматическое продление.${PLAIN}"
            ((warn_count++))
        fi
    else
        echo -e "${YELLOW}⚠️ acme.sh или файл Token не обнаружены, пропускаем автоматическое продление.${PLAIN}"
        ((warn_count++))
    fi

    echo -e "${YELLOW}▶ [5/7] Проверка и перезагрузка Caddy...${PLAIN}"
    if command -v caddy >/dev/null 2>&1; then
        if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
            systemctl enable caddy >/dev/null 2>&1
            if systemctl restart caddy >/dev/null 2>&1; then
                echo -e "${GREEN}✅ Проверка конфигурации Caddy пройдена, перезапуск успешен.${PLAIN}"
                ((fixed_count++))
            else
                echo -e "${RED}❌ Перезапуск Caddy не удался, проверьте логи вручную.${PLAIN}"
                ((fail_count++))
            fi
        else
            echo -e "${RED}❌ Проверка конфигурации Caddy не удалась, перезапуск не выполнен.${PLAIN}"
            ((fail_count++))
        fi
    else
        echo -e "${RED}❌ Caddy не установлен, невозможно выполнить перезагрузку.${PLAIN}"
        ((fail_count++))
    fi

    echo -e "${YELLOW}▶ [6/7] Восстановление файла манифеста...${PLAIN}"
    generate_caddy_cf_manifest
    ((fixed_count++))
    echo -e "${GREEN}✅ Манифест восстановлен: /root/cert/caddy_cf_manifest.txt${PLAIN}"

    echo -e "${YELLOW}▶ [7/7] Дополнение задачи автоматического продления acme...${PLAIN}"
    if [[ -x "$acme_bin" ]]; then
        if "$acme_bin" --install-cronjob >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Задача автоматического продления acme.sh подтверждена.${PLAIN}"
            ((fixed_count++))
        else
            echo -e "${YELLOW}⚠️ Не удалось подтвердить задачу продления acme.sh, проверьте crontab вручную.${PLAIN}"
            ((warn_count++))
        fi
    else
        echo -e "${YELLOW}⚠️ acme.sh не установлен, пропускаем дополнение задачи.${PLAIN}"
        ((warn_count++))
    fi

    echo -e "------------------------------------------------"
    echo -e "${CYAN}Результат автоматического исправления: ${GREEN}${fixed_count} исправлено${PLAIN} / ${YELLOW}${warn_count} предупреждений${PLAIN} / ${RED}${fail_count} ошибок${PLAIN}"
    if [[ "$fail_count" -gt 0 ]]; then
        echo -e "${RED}Есть ошибки, рекомендуется выполнить проверку [13] в меню обслуживания и просмотреть логи caddy.${PLAIN}"
    else
        echo -e "${GREEN}Автоматическое исправление завершено, выполните проверку [13] для подтверждения.${PLAIN}"
    fi
}
