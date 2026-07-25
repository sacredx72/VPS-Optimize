# shellcheck shell=bash
# Обслуживание сертификатов Cloudflare DNS и Caddy — соединение меню.

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
                local domain
                local acme_bin="/root/.acme.sh/acme.sh"
                local cf_env_file="/root/.config/vps-panel/cloudflare.env"

                read_trimmed domain "👉 Введите домен для перевыпуска: "
                domain=$(normalize_domain_input "$domain")
                if ! is_valid_domain "$domain"; then
                    echo -e "${RED}❌ Неверный формат домена.${PLAIN}"
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
                local link_mode domain
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
                    read_trimmed domain "👉 Введите домен: "
                    domain=$(normalize_domain_input "$domain")
                    if ! is_valid_domain "$domain"; then
                        echo -e "${RED}❌ Неверный формат домена.${PLAIN}"
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
                local domain purge_acme
                read_trimmed domain "👉 Введите домен для изоляции: "
                domain=$(normalize_domain_input "$domain")
                if ! is_valid_domain "$domain"; then
                    echo -e "${RED}❌ Неверный формат домена.${PLAIN}"
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
