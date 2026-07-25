# shellcheck shell=bash
# Обслуживание сертификатов Cloudflare/Caddy, восстановление конфигурации Caddy, белые списки и инструменты очистки.

func_caddy_cf_reality_wizard() {
    if [[ -f /etc/vps-optimize/sni-stack.env ]]; then
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}Обнаружена существующая конфигурация единого входа 443${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Если вы просто хотите добавить новый сайт или прокси-домен, вернитесь и выберите [8] Управление веб-доменами/прокси.${PLAIN}"
        echo -e "${YELLOW}Продолжение первичной настройки перезапишет основные конфигурации входа 443, Web-прокси и маршрутизации Xray.${PLAIN}"
        echo -e "------------------------------------------------"
        grep -E '^(PANEL_DOMAIN|PANEL_WEB_PATH|REALITY_SNI|NGINX_LISTEN_ADDR|NGINX_LISTEN_PORT|CADDY_LISTEN_PORT|XRAY_LISTEN_PORT|SUB_URI_PATH|CLASH_URI_PATH)=' /etc/vps-optimize/sni-stack.env 2>/dev/null || true
        echo -e "------------------------------------------------"
        confirm_danger "Повторное выполнение первичной настройки 443" "Будет перезаписана основная конфигурация единого входа 443 на основе новых данных, и перезапущены службы входа/Caddy." "Скрипт сначала создаст резервную копию; можно откатить из меню обслуживания 443 или из каталога резервных копий." || return 1
    fi
    select_initial_entry_mode || return 1
    collect_sni_stack_config || return 1
    probe_reality_sni "$REALITY_SNI" || return 1
    print_sni_stack_preview || return 1
    guard_current_ssh_not_on_entry_port "Первичная настройка единого входа 443" || return 1
    local cf_env_dir="/root/.config/vps-panel"
    local cf_env_file="${cf_env_dir}/cloudflare.env"
    local escaped_token
    mkdir -p "$cf_env_dir"
    chmod 700 "$cf_env_dir"
    escaped_token=${CF_TOKEN//\'/\'"\'"\'}
    printf "CF_Token='%s'\n" "$escaped_token" > "$cf_env_file"
    chmod 600 "$cf_env_file"

    local backup_dir
    backup_dir=$(backup_entry_mode_config) || return 1
    prepare_initial_entry_mode_dependencies "$ENTRY_MODE" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка проверки зависимостей режима входа"; return 1; }
    quarantine_legacy_caddy_443_configs
    quarantine_legacy_nginx_https_proxy_configs
    issue_and_install_cert_for_domain "$PANEL_DOMAIN" "$CF_TOKEN" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка выдачи/установки сертификата для домена панели"; return 1; }
    if [[ ${#SITE_DOMAINS[@]} -gt 0 ]]; then
        local site_domain
        for site_domain in "${SITE_DOMAINS[@]}"; do
            [[ -z "$site_domain" ]] && continue
            issue_and_install_cert_for_domain "$site_domain" "$CF_TOKEN" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка выдачи/установки сертификата для домена ${site_domain}"; return 1; }
        done
    fi
    preflight_entry_mode_before_cutover "$ENTRY_MODE" || { rollback_sni_stack_after_failure "$backup_dir" "Предпроверка режима ${ENTRY_MODE} не удалась, публичный 443 не переключён"; return 1; }
    stop_public_443_entry_services_for_target "$ENTRY_MODE" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка остановки старых служб публичного 443"; return 1; }
    apply_entry_mode_by_name "$ENTRY_MODE" "$backup_dir" || { rollback_sni_stack_after_failure "$backup_dir" "Ошибка применения режима ${ENTRY_MODE}"; return 1; }
    save_sni_stack_env
    harden_single_443_firewall
    generate_caddy_cf_manifest
    print_sni_stack_result
}

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
# Управляется VPS-Optimize
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

func_caddy_cf_maintenance_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🛠️ Центр обслуживания 443 / Caddy / Cloudflare${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: диагностика цепочки 443, переподпись сертификатов, восстановление символических ссылок, изоляция старых конфигураций и откат.${PLAIN}"
        echo -e "${YELLOW}Рекомендуемый порядок: сначала [1] проверка, затем исправление по результатам.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Часто используемые для единого входа 443${PLAIN}"
        echo -e "${GREEN}  1. Проверка цепочки и безопасности 443${PLAIN}       ${YELLOW}(Nginx/Caddy/REALITY/панель/скрытие версии)${PLAIN}"
        echo -e "${GREEN}  2. Управление веб-доменами/прокси 443${PLAIN}    ${YELLOW}(добавление/удаление/просмотр, самое частое)${PLAIN}"
        echo -e "${GREEN}  3. Изменение параметров маршрутизации 443${PLAIN}         ${YELLOW}(панель/подписка/REALITY/порты/пути)${PLAIN}"
        echo -e "${GREEN}  4. Повторное применение последней конфигурации 443${PLAIN}     ${YELLOW}(чтение sni-stack.env и восстановление конфигурации)${PLAIN}"
        echo -e "${GREEN}  5. Подсказки по ссылкам подписок / External Proxy${PLAIN} ${YELLOW}(проверка, что ссылки узлов используют публичный 443)${PLAIN}"
        echo -e "${RED}  6. Откат конфигурации единого входа 443${PLAIN}       ${YELLOW}(восстановление из последней резервной копии)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Сертификаты и Cloudflare${PLAIN}"
        echo -e "${GREEN}  7. Просмотр управляемых доменов / путей сертификатов${PLAIN}"
        echo -e "${GREEN}  8. Обновление Cloudflare API Token${PLAIN}"
        echo -e "${GREEN}  9. Перевыпуск сертификата для указанного домена${PLAIN}"
        echo -e "${GREEN} 10. Восстановление символических ссылок /root/cert${PLAIN}"
        echo -e "${GREEN} 11. Восстановление файла манифеста сертификатов${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Восстановление и очистка Caddy${PLAIN}"
        echo -e "${GREEN} 12. Проверка и перезагрузка Caddy${PLAIN}"
        echo -e "${GREEN} 13. Быстрая проверка Caddy/сертификатов${PLAIN}       ${YELLOW}(Token/сертификаты/прослушивание/бэкенды)${PLAIN}"
        echo -e "${GREEN} 14. Автоматическое исправление частых проблем${PLAIN}"
        echo -e "${GREEN} 15. Изоляция старых конфигураций Caddy${PLAIN}        ${YELLOW}(во избежание захвата 443)${PLAIN}"
        echo -e "${RED} 16. Изоляция конфигурации и сертификатов для указанного домена${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local m_choice
        read_trimmed m_choice "👉 Выберите действие: "

        case "$m_choice" in
            1) m_choice=11 ;;
            2) m_choice=15 ;;
            3) m_choice=16 ;;
            4) m_choice=12 ;;
            5) m_choice=13 ;;
            6) m_choice=14 ;;
            7) m_choice=1 ;;
            8) m_choice=2 ;;
            9) m_choice=3 ;;
            10) m_choice=4 ;;
            11) m_choice=7 ;;
            12) m_choice=6 ;;
            13) m_choice=8 ;;
            14) m_choice=9 ;;
            15) m_choice=10 ;;
            16) m_choice=5 ;;
        esac

        case $m_choice in
            16)
                edit_sni_stack_runtime_profile
                ;;

            1)
                generate_caddy_cf_manifest
                echo -e "${CYAN}👇 Текущее содержимое манифеста:${PLAIN}"
                cat /root/cert/caddy_cf_manifest.txt 2>/dev/null
                ;;

            2)
                local new_token escaped_token
                mkdir -p /root/.config/vps-panel
                chmod 700 /root/.config/vps-panel
                echo -e "${CYAN}👇 Введите новый Cloudflare API Token${PLAIN}"
                read_secret_trimmed new_token "CF Token: "
                if [[ -z "$new_token" || ${#new_token} -lt 20 ]]; then
                    echo -e "${RED}❌ Неверная длина Token, обновление отменено.${PLAIN}"
                else
                    echo -e "${CYAN}▶ Онлайн-проверка Cloudflare Token...${PLAIN}"
                    verify_cf_token_online "$new_token"
                    local verify_rc=$?
                    if [[ "$verify_rc" -eq 1 ]]; then
                        echo -e "${RED}❌ Онлайн-проверка Token не удалась, запись отменена.${PLAIN}"
                        echo -e "${YELLOW}Требуются права: Zone.DNS.Edit + Zone.Zone.Read${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    elif [[ "$verify_rc" -eq 2 ]]; then
                        echo -e "${YELLOW}⚠️ curl не установлен, пропускаем онлайн-проверку, продолжаем запись.${PLAIN}"
                    else
                        echo -e "${GREEN}✅ Проверка Token пройдена.${PLAIN}"
                    fi

                    escaped_token=${new_token//\'/\'"\'"\'}
                    printf "CF_Token='%s'\n" "$escaped_token" > /root/.config/vps-panel/cloudflare.env
                    chmod 600 /root/.config/vps-panel/cloudflare.env
                    echo -e "${GREEN}✅ Cloudflare Token обновлён.${PLAIN}"
                fi
                ;;

            3)
                local domain domain_input
                local acme_bin="/root/.acme.sh/acme.sh"
                local cf_env_file="/root/.config/vps-panel/cloudflare.env"

                read_trimmed domain_input "👉 Введите домен для перевыпуска: "
                domain=$(normalize_domain_input "$domain_input")
                if ! is_valid_domain "$domain"; then
                    print_domain_validation_error "домен" "$domain_input" "$domain"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if [[ ! -x "$acme_bin" ]]; then
                    echo -e "${RED}❌ acme.sh не обнаружен, сначала выполните первичную настройку единого входа 443 через [19] -> [2].${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi
                if [[ ! -f "$cf_env_file" ]]; then
                    echo -e "${RED}❌ Cloudflare Token не найден, сначала выполните [2] в этом меню.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                # shellcheck disable=SC1090
                source "$cf_env_file"
                confirm_risk_action "Перевыпустить и установить сертификат для ${domain}" \
                    "Кеш сертификатов acme.sh, /etc/caddy/certs и символические ссылки /root/cert" \
                    "Восстановите из существующей резервной копии Caddy/сертификатов или повторите выпуск в меню обслуживания" \
                    "Убедитесь, что DNS домена разрешается, и Cloudflare Token имеет правильные права." || {
                    echo -e "${BLUE}Перевыпуск сертификата отменён.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                }
                echo -e "${CYAN}▶ Перевыпуск сертификата: ${domain}${PLAIN}"

                if ! issue_cf_dns_cert_with_retry "$domain" "$CF_Token" "$acme_bin"; then
                    echo -e "${RED}❌ Ошибка выдачи сертификата: ${domain}${PLAIN}"
                    echo -e "${YELLOW}   Подсказка: сначала выполните автоматическое исправление [14] в этом меню.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                mkdir -p /etc/caddy/certs /root/cert
                if ! "$acme_bin" --install-cert -d "$domain" --ecc \
                    --fullchain-file "/etc/caddy/certs/${domain}.crt" \
                    --key-file "/etc/caddy/certs/${domain}.key" \
                    --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true" >/dev/null 2>&1; then
                    echo -e "${RED}❌ Ошибка установки сертификата: ${domain}${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if id caddy >/dev/null 2>&1; then
                    chown root:caddy "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key" >/dev/null 2>&1
                    chmod 640 "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key"
                else
                    chmod 600 "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key"
                fi

                ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
                ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
                generate_caddy_cf_manifest
                echo -e "${GREEN}✅ Перевыпуск выполнен и символические ссылки /root/cert обновлены.${PLAIN}"
                ;;

            4)
                local link_mode domain domain_input
                mkdir -p /root/cert
                read_trimmed link_mode "❓ Восстановить все ссылки или для одного домена? (all/one): "

                if [[ "$link_mode" == "all" ]]; then
                    local relink_count=0
                    if [[ -d /etc/caddy/certs ]]; then
                        while IFS= read -r cert_path; do
                            domain=$(basename "$cert_path" .crt)
                            if [[ -f "/etc/caddy/certs/${domain}.key" ]]; then
                                ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
                                ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
                                ((relink_count++))
                            fi
                        done < <(find /etc/caddy/certs -maxdepth 1 -type f -name "*.crt" 2>/dev/null | sort)
                    fi
                    generate_caddy_cf_manifest
                    echo -e "${GREEN}✅ Восстановлено ${relink_count} групп символических ссылок сертификатов.${PLAIN}"
                else
                    read_trimmed domain_input "👉 Введите домен: "
                    domain=$(normalize_domain_input "$domain_input")
                    if ! is_valid_domain "$domain"; then
                        print_domain_validation_error "домен" "$domain_input" "$domain"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    fi
                    if [[ -f "/etc/caddy/certs/${domain}.crt" && -f "/etc/caddy/certs/${domain}.key" ]]; then
                        ln -sfn "/etc/caddy/certs/${domain}.crt" "/root/cert/${domain}.crt"
                        ln -sfn "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.key"
                        generate_caddy_cf_manifest
                        echo -e "${GREEN}✅ Символические ссылки восстановлены: /root/cert/${domain}.crt и /root/cert/${domain}.key${PLAIN}"
                    else
                        echo -e "${RED}❌ Файлы сертификатов для этого домена не найдены.${PLAIN}"
                    fi
                fi
                ;;

            5)
                local domain domain_input purge_acme
                read_trimmed domain_input "👉 Введите домен для изоляции: "
                domain=$(normalize_domain_input "$domain_input")
                if ! is_valid_domain "$domain"; then
                    print_domain_validation_error "домен" "$domain_input" "$domain"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if ! confirm_risk_action "Изолировать конфигурацию и сертификаты для ${domain}" \
                    "Конфигурация Caddy, файлы сертификатов и опционально историю acme.sh" \
                    "Восстановите вручную из карантинного каталога или перевыпустите сертификат и восстановите конфигурацию Caddy" \
                    "Убедитесь, что этот домен больше не обслуживает работающие службы, или вы готовы перевыпустить сертификат."; then
                    echo -e "${BLUE}Изоляция отменена.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                local domain_quarantine_dir="/etc/vps-optimize/quarantine/caddy-domain-${domain}-$(date +%s)"
                mkdir -p "$domain_quarantine_dir"
                quarantine_path "/etc/caddy/conf.d/${domain}.caddy" "$domain_quarantine_dir" >/dev/null 2>&1 || true
                quarantine_path "/etc/caddy/certs/${domain}.crt" "$domain_quarantine_dir" >/dev/null 2>&1 || true
                quarantine_path "/etc/caddy/certs/${domain}.key" "$domain_quarantine_dir" >/dev/null 2>&1 || true
                quarantine_path "/root/cert/${domain}.crt" "$domain_quarantine_dir" >/dev/null 2>&1 || true
                quarantine_path "/root/cert/${domain}.key" "$domain_quarantine_dir" >/dev/null 2>&1 || true

                read_trimmed purge_acme "❓ Также удалить историю acme.sh? (y/n, по умолчанию n, рекомендуется оставить): "
                if is_yes "$purge_acme"; then
                    /root/.acme.sh/acme.sh --remove -d "$domain" --ecc >/dev/null 2>&1 || true
                    quarantine_path "/root/.acme.sh/${domain}_ecc" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
                    quarantine_path "/root/.acme.sh/${domain}" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
                fi

                if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                    systemctl restart caddy >/dev/null 2>&1
                fi
                generate_caddy_cf_manifest
                echo -e "${GREEN}✅ Конфигурация и сертификаты для ${domain} изолированы в: ${domain_quarantine_dir}${PLAIN}"
                ;;

            6)
                caddy_format_configs
                if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                    systemctl restart caddy >/dev/null 2>&1
                    echo -e "${GREEN}✅ Конфигурация Caddy отформатирована, проверена и перезапущена.${PLAIN}"
                else
                    echo -e "${RED}❌ Проверка конфигурации Caddy не удалась, проверьте /etc/caddy/conf.d/*.caddy${PLAIN}"
                fi
                ;;

            7)
                generate_caddy_cf_manifest
                echo -e "${GREEN}✅ Манифест восстановлен: /root/cert/caddy_cf_manifest.txt${PLAIN}"
                ;;

            8)
                func_caddy_cf_health_check
                ;;

            9)
                func_caddy_cf_auto_fix
                ;;

            10)
                quarantine_legacy_caddy_443_configs
                if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                    systemctl restart caddy >/dev/null 2>&1
                    echo -e "${GREEN}✅ Изоляция выполнена, Caddy перезагружен.${PLAIN}"
                else
                    echo -e "${RED}❌ Текущая конфигурация Caddy не прошла проверку, сначала исправьте синтаксические ошибки.${PLAIN}"
                fi
                ;;

            11)
                sni_stack_health_check
                ;;

            12)
                reapply_sni_stack_from_env
                ;;

            13)
                check_sni_stack_subscription_hint
                ;;

            14)
                rollback_sni_stack_config
                ;;

            15)
                manage_sni_stack_sites
                ;;

            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}" ;;
        esac

        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}

# ---------------------------------------------------------
# Новая функция: просмотр путей сертификатов Caddy
# ---------------------------------------------------------
func_view_caddy_cert() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔑 Просмотр путей выданных сертификатов Caddy${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    
    if [[ ! -f "/etc/caddy/Caddyfile" ]]; then
        echo -e "${RED}❌ /etc/caddy/Caddyfile не найден, сначала настройте обратный прокси!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    
    # Извлечение доменов из Caddyfile и conf.d (игнорируя комментарии)
    local domains
    domains=$(cat /etc/caddy/Caddyfile /etc/caddy/conf.d/*.caddy 2>/dev/null | grep -vE '^[[:space:]]*#' | grep '{' | awk '{print $1}' | tr -d '{')
    
    if [[ -z "$domains" ]]; then
        echo -e "${YELLOW}⚠️ В Caddyfile нет явно настроенных доменов.${PLAIN}"
    else
        # Корневой каталог сертификатов Caddy
        local cert_root="/var/lib/caddy/.local/share/caddy/certificates"
        [[ ! -d "$cert_root" ]] && cert_root="/root/.local/share/caddy/certificates"
        
        for domain in $domains; do
            # Отфильтровываем локальные и незначащие блоки
            if [[ "$domain" == ":80" || "$domain" == "localhost" ]]; then continue; fi
            
            echo -e "${BLUE}🌐 Домен: ${BOLD}${domain}${PLAIN}"
            
            local found=false
            if [[ -d "$cert_root" ]]; then
                # Рекурсивный поиск .crt и .key
                local cert_file
                local key_file
                cert_file=$(find "$cert_root" -name "${domain}.crt" -print -quit 2>/dev/null)
                key_file=$(find "$cert_root" -name "${domain}.key" -print -quit 2>/dev/null)
                
                if [[ -n "$cert_file" && -n "$key_file" ]]; then
                    echo -e "   ${GREEN}📄 Публичный ключ (CRT):${PLAIN} ${cert_file}"
                    echo -e "   ${YELLOW}🔑 Приватный ключ (KEY):${PLAIN} ${key_file}"
                    found=true
                fi
            fi
            
            if ! $found; then
                echo -e "   ${RED}❌ Сертификат не найден, возможно, ещё не выдан или путь неверен.${PLAIN}"
            fi
            echo -e "------------------------------------------------"
        done
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}

# ---------------------------------------------------------
# Новая функция: очистка конфигураций Caddy (модульная версия)
# ---------------------------------------------------------
func_caddy_clear_config() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧹 Очистка конфигураций Caddy (модульная версия)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    
    if [[ -f /etc/caddy/Caddyfile ]] || [[ -d /etc/caddy/conf.d ]]; then
        echo -e "${YELLOW}Будут очищены /etc/caddy/conf.d/*.caddy и сброшен /etc/caddy/Caddyfile в начальное модульное состояние.${PLAIN}"
        if confirm_danger "Очистка конфигураций обратного прокси Caddy" "Все независимые конфигурации Caddy прокси станут неактивны, связанные сайты/панели могут быть временно недоступны." "Скрипт создаст резервную копию Caddyfile и conf.d, можно восстановить вручную."; then
            
            # 1. Резервное копирование существующего модульного каталога
            if [[ -d /etc/caddy/conf.d ]]; then
                local backup_dir="/etc/caddy/conf.d_bak_$(date +%s)"
                cp -r /etc/caddy/conf.d "$backup_dir" 2>/dev/null
                echo -e "${BLUE}Создана резервная копия конфигурационного каталога: $backup_dir${PLAIN}"
                
                # Точная изоляция всех .caddy файлов
                while IFS= read -r caddy_conf; do
                    mv "$caddy_conf" "$backup_dir/" 2>/dev/null || true
                done < <(find /etc/caddy/conf.d -maxdepth 1 -type f -name '*.caddy' 2>/dev/null | sort)
            fi
            
            # 2. Сброс основного файла в модульную архитектуру
            cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak_$(date +%s)" 2>/dev/null
            echo "# Caddyfile очищен и сброшен к модульной архитектуре" > /etc/caddy/Caddyfile
            echo "import conf.d/*" >> /etc/caddy/Caddyfile
            
            # 3. Перезагрузка
            systemctl restart caddy >/dev/null 2>&1
            echo -e "${GREEN}✅ Все конфигурации прокси очищены и успешно перезагружены! Система возвращена к чистому модульному состоянию.${PLAIN}"
        else
            echo -e "${BLUE}Очистка отменена.${PLAIN}"
        fi
    else
        echo -e "${RED}❌ Конфигурационный файл Caddy или модульный каталог не обнаружены!${PLAIN}"
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}

strip_caddy_ip_whitelist_block() {
    local conf_file="$1"
    local tmp_file
    tmp_file=$(mktemp /tmp/caddy-ipwl.XXXXXX) || return 1
    awk '
        /# vps-optimize-ip-whitelist-start/ {skip=1; next}
        /# vps-optimize-ip-whitelist-end/ {skip=0; next}
        !skip {print}
    ' "$conf_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv "$tmp_file" "$conf_file"
}

insert_caddy_ip_whitelist_block() {
    local conf_file="$1"
    local ranges="$2"
    local tmp_file block
    strip_caddy_ip_whitelist_block "$conf_file" || return 1
    tmp_file=$(mktemp /tmp/caddy-ipwl.XXXXXX) || return 1
    block=$(caddy_ip_whitelist_block "$ranges")
    awk -v block="$block" '
        inserted == 0 && /^[[:space:]]*[^#[:space:]].*\{[[:space:]]*$/ {
            print
            printf "%s", block
            inserted=1
            next
        }
        {print}
        END { if (inserted == 0) exit 1 }
    ' "$conf_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv "$tmp_file" "$conf_file"
}

func_caddy_manage_ip_whitelist() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔐 IP-белый список Caddy для доменов${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Применяется для доменов, где не включён единый вход 443 и Caddy обслуживает напрямую.${PLAIN}"
    echo -e "${YELLOW}Если домен уже использует единый вход 443, используйте главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси] -> [5 Управление IP-белым списком домена], не ограничивайте на уровне Caddy.${PLAIN}"
    echo -e "------------------------------------------------"

    if ! command -v caddy >/dev/null 2>&1 || [[ ! -f /etc/caddy/Caddyfile ]]; then
        echo -e "${RED}❌ Caddy или /etc/caddy/Caddyfile не обнаружены, сначала настройте Caddy прокси.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    local domain domain_input conf_file first_site_line action backup_file
    read_trimmed domain_input "Введите домен для управления (например panel.example.com): "
    domain=$(normalize_domain_input "$domain_input")
    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    conf_file="/etc/caddy/conf.d/${domain}.caddy"
    if [[ ! -f "$conf_file" ]]; then
        echo -e "${RED}❌ ${conf_file} не найден. Этот пункт управляет только модульными конфигурациями Caddy, созданными скриптом.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    first_site_line=$(grep -m1 -E '^[[:space:]]*[^#[:space:]].*\{' "$conf_file" 2>/dev/null | sed 's/^[[:space:]]*//')
    if [[ "$first_site_line" != "$domain "* && "$first_site_line" != "$domain{"* && "$first_site_line" != "https://${domain}"* ]]; then
        echo -e "${RED}❌ Первый блок сайта в ${conf_file} не относится к ${domain}, изменение отменено во избежание ошибок.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi
    if [[ "$first_site_line" =~ ^https://[^[:space:]]+:[0-9]+[[:space:]]*\{ ]]; then
        echo -e "${RED}❌ Эта конфигурация похожа на локальный TLS-сайт единого входа 443. Используйте главное меню [19 Центр управления единым входом 443] -> [8 Управление веб-доменами/прокси] -> [5 Управление IP-белым списком домена].${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    echo -e "Текущий файл конфигурации: ${conf_file}"
    if grep -q '# vps-optimize-ip-whitelist-start' "$conf_file" 2>/dev/null; then
        echo -e "${YELLOW}Текущее состояние: включён управляемый скриптом IP-белый список.${PLAIN}"
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
            [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен.${PLAIN}"
            read_trimmed ip_whitelist_input "Введите IP/CIDR, разрешённые для ${domain} (несколько через пробел или запятую): "
            if ! normalize_ip_whitelist_input "$ip_whitelist_input" ip_whitelist_array; then
                echo -e "${RED}❌ Белый список пуст или неверный формат, отмена.${PLAIN}"
                read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                return
            fi
            append_vps_public_ips_to_whitelist ip_whitelist_array
            ip_whitelist_ranges=$(join_array_by_space "${ip_whitelist_array[@]}")
            cp -p "$conf_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, отмена.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."; return; }
            if insert_caddy_ip_whitelist_block "$conf_file" "$ip_whitelist_ranges" && caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                if systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ Для ${domain} включён IP-белый список: ${ip_whitelist_ranges}${PLAIN}"
                    echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
                else
                    echo -e "${RED}❌ Перезагрузка Caddy не удалась, откат...${PLAIN}"
                    mv "$backup_file" "$conf_file"
                    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
                fi
            else
                echo -e "${RED}❌ Проверка Caddy после записи не удалась, откат...${PLAIN}"
                mv "$backup_file" "$conf_file"
            fi
            ;;
        2)
            if ! grep -q '# vps-optimize-ip-whitelist-start' "$conf_file" 2>/dev/null; then
                echo -e "${BLUE}Для этого домена нет блока белого списка, созданного скриптом.${PLAIN}"
                read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                return
            fi
            cp -p "$conf_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, отмена.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."; return; }
            if strip_caddy_ip_whitelist_block "$conf_file" && caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
                echo -e "${GREEN}✅ IP-белый список Caddy для ${domain} очищен.${PLAIN}"
                echo -e "${CYAN}Резервная копия сохранена: ${backup_file}${PLAIN}"
            else
                echo -e "${RED}❌ Проверка Caddy после очистки не удалась, откат...${PLAIN}"
                mv "$backup_file" "$conf_file"
            fi
            ;;
        0|q|Q|"")
            echo -e "${BLUE}Отмена.${PLAIN}"
            ;;
        *)
            echo -e "${RED}❌ Неверное действие.${PLAIN}"
            ;;
    esac

    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# Очистка сертификатов домена, конфигураций и занятости портов
# ---------------------------------------------------------
sync_sni_stack_state_after_caddy_domain_delete() {
    local domain="$1"
    local env_file="/etc/vps-optimize/sni-stack.env"
    local i removed=0
    local -a new_domains=()
    local -a new_addrs=()
    local -a new_ports=()

    [[ -f "$env_file" ]] || return 0
    load_sni_stack_env >/dev/null 2>&1 || return 0

    if [[ "$domain" == "${PANEL_DOMAIN:-}" ]]; then
        echo -e "${YELLOW}⚠️ ${domain} — текущий домен панели единого входа 443, сохранённое состояние всё равно будет ссылаться на него; перед повторным применением необходимо перевыпустить сертификат или сменить домен панели.${PLAIN}"
        return 0
    fi

    for i in "${!SITE_DOMAINS[@]}"; do
        if [[ "$domain" == "${SITE_DOMAINS[$i]}" ]]; then
            removed=1
            continue
        fi
        new_domains+=("${SITE_DOMAINS[$i]}")
        new_addrs+=("${SITE_BACKEND_ADDRS[$i]}")
        new_ports+=("${SITE_BACKEND_PORTS[$i]}")
    done

    [[ "$removed" -eq 1 ]] || return 0
    SITE_DOMAINS=("${new_domains[@]}")
    SITE_BACKEND_ADDRS=("${new_addrs[@]}")
    SITE_BACKEND_PORTS=("${new_ports[@]}")
    remove_sni_ip_whitelist_for_domain "$domain"
    save_sni_stack_env
    echo -e "${GREEN}✅ Синхронизировано удаление веб-домена ${domain} из сохранённого состояния единого входа 443.${PLAIN}"
}

func_caddy_delete_cert() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Очистка сертификатов домена и конфигураций${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Будут изолированы сертификаты и конфигурация указанного домена, а также очищены остатки acme.sh.${PLAIN}"
    echo -e "------------------------------------------------"
    
    local domain domain_input
    read_trimmed domain_input "👉 Введите домен для очистки (например panel.site.com): "
    domain=$(normalize_domain_input "$domain_input")
    if [[ -z "$domain" ]]; then
        echo -e "${RED}❌ Домен не может быть пустым!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        echo -e "${RED}❌ Очистка отменена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "\n${CYAN}▶ Очистка сертификатов и конфигураций домена...${PLAIN}"
    echo -e "${YELLOW}Эта операция переместит сертификаты и конфигурацию этого домена, связанные сайты станут временно недоступны.${PLAIN}"
    echo -e "Подтвердите действие...${PLAIN}"
    if confirm_danger "Очистка сертификатов и конфигурации ${domain}" "Будет остановлен Caddy, изолированы конфигурации Caddy/Nginx для этого домена, общие файлы сертификатов и остатки acme.sh, затем службы будут перезапущены." "Убедитесь, что у вас есть системный снимок или резервная копия конфигурации прокси; после очистки сертификаты необходимо перевыпустить."; then
        # 1. Остановка Caddy для освобождения портов
        systemctl stop caddy >/dev/null 2>&1
        echo -e "${GREEN}✅ [1/4] Caddy остановлен для освобождения сетевых портов.${PLAIN}"
        
        # 2. Глубокая очистка кеша сертификатов Caddy
        local caddy_paths=("/var/lib/caddy/.local/share/caddy/certificates" "/root/.local/share/caddy/certificates")
        local caddy_found=false
        for cp in "${caddy_paths[@]}"; do
            if [[ -d "$cp" ]]; then
                local target=$(find "$cp" -type d -name "${domain}" -print -quit 2>/dev/null)
                if [[ -n "$target" ]]; then
                    quarantine_path "$target" "/root/vps-optimize-quarantine/caddy-certs" >/dev/null 2>&1 || true
                    caddy_found=true
                fi
            fi
        done
        if $caddy_found; then
            echo -e "${GREEN}✅ [2/4] Ключи и сертификаты для ${domain} удалены из движка Caddy.${PLAIN}"
        else
            echo -e "${BLUE}ℹ️ [2/4] Сертификаты для этого домена не найдены в движке Caddy.${PLAIN}"
        fi
        
        # 3. Очистка остатков acme.sh
        if [[ -d "/root/.acme.sh" ]]; then
            local acme_target=$(find "/root/.acme.sh" -type d -name "*${domain}*" -print -quit 2>/dev/null)
            if [[ -n "$acme_target" ]]; then
                quarantine_path "$acme_target" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
                echo -e "${GREEN}✅ [3/4] Остатки acme.sh для ${domain} удалены.${PLAIN}"
            else
                echo -e "${BLUE}ℹ️ [3/4] Остатков acme.sh не обнаружено.${PLAIN}"
            fi
        else
            echo -e "${BLUE}ℹ️ [3/4] Независимая среда acme.sh не установлена, пропущено.${PLAIN}"
        fi
        
        # 4. Модульное удаление конфигураций Caddy/Nginx
        local domain_conf="/etc/caddy/conf.d/${domain}.caddy"
        if [[ -f "$domain_conf" ]]; then
            echo -e "${YELLOW}⏳ [4/5] Обнаружен файл конфигурации Caddy, изоляция...${PLAIN}"
            quarantine_path "$domain_conf" "/etc/vps-optimize/quarantine/caddy-conf" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ [4/5] Файл конфигурации Caddy ($domain_conf) изолирован!${PLAIN}"
        else
            echo -e "${GREEN}✅ [4/5] Файл конфигурации Caddy для этого домена не найден.${PLAIN}"
        fi
        local nginx_domain_conf
        nginx_domain_conf=$(nginx_proxy_conf_path "$domain" 2>/dev/null || echo "/etc/nginx/conf.d/vps_proxy_${domain}.conf")
        if [[ -f "$nginx_domain_conf" ]]; then
            quarantine_path "$nginx_domain_conf" "/etc/vps-optimize/quarantine/nginx-proxy" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ Изолирована конфигурация Nginx прокси: ${nginx_domain_conf}${PLAIN}"
        fi

        # 5. Изоляция общих сертификатов
        local shared_cert_file
        echo -e "${YELLOW}⏳ [5/5] Изоляция общих путей сертификатов...${PLAIN}"
        for shared_cert_file in "/etc/caddy/certs/${domain}.crt" "/etc/caddy/certs/${domain}.key" "/root/cert/${domain}.crt" "/root/cert/${domain}.key"; do
            if [[ -e "$shared_cert_file" || -L "$shared_cert_file" ]]; then
                quarantine_path "$shared_cert_file" "/etc/vps-optimize/quarantine/shared-certs" >/dev/null 2>&1 || true
                echo -e "${GREEN}✅ Изолирован общий сертификат: ${shared_cert_file}${PLAIN}"
            fi
        done

        # Перезапуск Caddy с чистой конфигурацией
        systemctl start caddy >/dev/null 2>&1
        if command -v nginx >/dev/null 2>&1; then
            nginx -t >/dev/null 2>&1 && { systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true; }
        fi
        sync_sni_stack_state_after_caddy_domain_delete "$domain" || true
        generate_caddy_cf_manifest 2>/dev/null || true

        echo -e "------------------------------------------------"
        echo -e "${GREEN}✅ Очистка завершена; соответствующие конфигурации и сертификаты перемещены в карантин.${PLAIN}"
    else
        echo -e "${BLUE}Операция отменена.${PLAIN}"
    fi
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}

# ---------------------------------------------------------
# Новая функция: добавление независимого прокси Caddy с пропуском проверки сертификата (модульная версия)
# ---------------------------------------------------------
func_caddy_add_insecure() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🛡️ Настройка независимого прокси Caddy с пропуском проверки сертификата${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        echo -e "${RED}❌ Caddyfile не найден, сначала установите Caddy через [13]!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    
    local domain domain_input
    local backend_addr port
    local enable_ip_whitelist ip_whitelist_input ip_whitelist_ranges current_client_ip
    local -a ip_whitelist_array=()
    read_trimmed domain_input "👉 Введите разрешённый домен (например panel.site.com): "
    read_trimmed port "👉 Введите локальный HTTPS-порт бэкенда (например 40000): "
    backend_addr=$(ask_with_default "Адрес бэкенда" "127.0.0.1")
    backend_addr=$(normalize_backend_addr_input "$backend_addr")
    if ! is_valid_backend_addr "$backend_addr"; then
        echo -e "${RED}❌ Неверный адрес бэкенда: ${backend_addr}${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi
    domain=$(normalize_domain_input "$domain_input")
    
    if ! is_valid_domain "$domain"; then
        print_domain_validation_error "домен" "$domain_input" "$domain"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi
    if ! is_valid_port "$port"; then
        echo -e "${RED}❌ Неверный порт: ${port}, должен быть 1-65535. Отмена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi

    read_trimmed enable_ip_whitelist "❓ Разрешить доступ к этому домену только с указанных IP/CIDR? (y/n, по умолчанию n): "
    if is_yes "$enable_ip_whitelist"; then
        current_client_ip=$(detect_ssh_client_ip)
        [[ -n "$current_client_ip" ]] && echo -e "${YELLOW}Текущий IP-источник SSH возможно: ${current_client_ip}, убедитесь, что он добавлен.${PLAIN}"
        read_trimmed ip_whitelist_input "Введите IP/CIDR, разрешённые для ${domain} (несколько через пробел или запятую): "
        if ! normalize_ip_whitelist_input "$ip_whitelist_input" ip_whitelist_array; then
            echo -e "${RED}❌ Белый список пуст или неверный формат, отмена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
            return
        fi
        append_vps_public_ips_to_whitelist ip_whitelist_array
        ip_whitelist_ranges=$(join_array_by_space "${ip_whitelist_array[@]}")
    else
        ip_whitelist_ranges=""
    fi
    
    # Убедиться, что основной файл содержит импорт модульного каталога
    grep -q "import conf.d/\*" /etc/caddy/Caddyfile || echo -e "\nimport conf.d/*" >> /etc/caddy/Caddyfile
    
    mkdir -p /etc/caddy/conf.d
    local conf_file="/etc/caddy/conf.d/${domain}.caddy"
    local backup_file=""
    if [[ -f "$conf_file" ]]; then
        backup_file="${conf_file}.bak_$(date +%s)"
        if ! cp -p "$conf_file" "$backup_file"; then
            echo -e "${RED}❌ Не удалось создать резервную копию существующей конфигурации, отмена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
            return
        fi
    fi
    
    write_caddy_reverse_proxy_conf "$domain" "$backend_addr" "$port" "y" "$conf_file" "$ip_whitelist_ranges"
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        systemctl reload caddy >/dev/null 2>&1
        echo -e "${GREEN}✅ Независимый прокси с пропуском проверки успешно создан и активен!${PLAIN}"
        [[ -n "$ip_whitelist_ranges" ]] && echo -e "${GREEN}✅ Для ${domain} включён IP-белый список: ${ip_whitelist_ranges}${PLAIN}"
    else
        echo -e "${RED}❌ Синтаксическая ошибка в новой конфигурации, откат...${PLAIN}"
        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/caddy-conf" >/dev/null 2>&1 || true
        [[ -n "$backup_file" && -f "$backup_file" ]] && mv "$backup_file" "$conf_file"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# 4. Усиление безопасности SSH (окончательная версия: защита от обрезания, перезаписи, конфликтов сокетов)
# ---------------------------------------------------------
