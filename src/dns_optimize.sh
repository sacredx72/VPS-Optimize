# shellcheck shell=bash
# Оптимизация профилей DNS-резолверов.

dns_write_static_resolv_conf() {
    local v4_servers="$1"
    local v6_servers="$2"
    local server

    if [[ -L /etc/resolv.conf ]]; then
        quarantine_path /etc/resolv.conf "/etc/vps-optimize/quarantine/dns" >/dev/null 2>&1 || return 1
    fi

    {
        echo "# Сгенерировано VPS-Optimize оптимизация DNS"
        echo "# Обновлено: $(date -Is 2>/dev/null || date)"
        for server in $v4_servers; do
            echo "nameserver $server"
        done
        for server in $v6_servers; do
            echo "nameserver $server"
        done
        echo "options timeout:2 attempts:3 rotate"
    } > /etc/resolv.conf
}

dns_apply_profile() {
    local profile_name="$1"
    local v4_servers="$2"
    local v6_servers="$3"
    local backup_dir all_servers resolved_active resolv_target

    confirm_risk_action "Изменить системный DNS на ${profile_name}" \
        "/etc/resolv.conf и конфигурацию systemd-resolved" \
        "Вернитесь в это меню и выберите [5] для восстановления последней DNS-резервной копии, или восстановите вручную из ${DNS_OPTIMIZE_BACKUP_DIR}" \
        "Ошибка в DNS может привести к сбоям разрешения имён; текущая SSH-сессия обычно не прерывается сразу." || return 1

    backup_dir=$(dns_backup_current_config)
    all_servers="${v4_servers} ${v6_servers}"

    resolved_active=0
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        resolved_active=1
    fi

    if [[ "$resolved_active" -eq 1 ]]; then
        mkdir -p /etc/systemd/resolved.conf.d
        {
            echo "[Resolve]"
            echo "DNS=${all_servers}"
            echo "FallbackDNS="
        } > "$DNS_OPTIMIZE_RESOLVED_DROPIN"
        systemctl restart systemd-resolved >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ Не удалось перезапустить systemd-resolved, продолжено с записью статического resolv.conf.${PLAIN}"

        resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
        if [[ "$resolv_target" != /run/systemd/resolve/* ]]; then
            dns_write_static_resolv_conf "$v4_servers" "$v6_servers" || return 1
        fi
    else
        dns_write_static_resolv_conf "$v4_servers" "$v6_servers" || return 1
    fi

    echo -e "${GREEN}✅ DNS переключён на ${profile_name}${PLAIN}"
    echo -e "IPv4 DNS: ${CYAN}${v4_servers}${PLAIN}"
    echo -e "IPv6 DNS: ${CYAN}${v6_servers}${PLAIN}"
    echo -e "${YELLOW}Резервная копия старой конфигурации: ${backup_dir}${PLAIN}"

    if getent hosts raw.githubusercontent.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Проверка DNS пройдена.${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ Проверка DNS не пройдена, проверьте сеть, доступность IPv6 или DNS-серверов.${PLAIN}"
    fi
}


func_dns_optimize() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Сеть/оптимизация ядра > Оптимизация DNS"
        echo -e "${BOLD}Оптимизация DNS${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Китайские по умолчанию: IPv4 223.5.5.5 / 119.29.29.29, IPv6 2400:3200::1 / 2402:4e00::${PLAIN}"
        echo -e "${YELLOW}Международные по умолчанию: IPv4 1.1.1.1 / 8.8.8.8, IPv6 2606:4700:4700::1111 / 2001:4860:4860::8888${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Использовать китайские DNS${PLAIN}       ${YELLOW}(Alibaba DNS + DNSPod)${PLAIN}"
        echo -e "${GREEN}  2. Использовать международные DNS${PLAIN}       ${YELLOW}(Cloudflare + Google)${PLAIN}"
        echo -e "${GREEN}  3. Пользовательские DNS${PLAIN}         ${YELLOW}(ввести IPv4 и IPv6 отдельно)${PLAIN}"
        echo -e "${GREEN}  4. Просмотр текущего DNS${PLAIN}"
        echo -e "${GREEN}  5. Восстановить последнюю DNS-резервную копию${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice v4_servers v6_servers raw_v4 raw_v6
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1)
                dns_apply_profile "Китайские DNS" "223.5.5.5 119.29.29.29" "2400:3200::1 2402:4e00::"
                pause_return
                ;;
            2)
                dns_apply_profile "Международные DNS" "1.1.1.1 8.8.8.8" "2606:4700:4700::1111 2001:4860:4860::8888"
                pause_return
                ;;
            3)
                read_trimmed raw_v4 "Введите IPv4 DNS (через запятую или пробел): "
                read_trimmed raw_v6 "Введите IPv6 DNS (через запятую или пробел): "
                v4_servers=$(dns_normalize_servers 4 "$raw_v4") || {
                    echo -e "${RED}❌ Неверный формат IPv4 DNS.${PLAIN}"
                    pause_return
                    continue
                }
                v6_servers=$(dns_normalize_servers 6 "$raw_v6") || {
                    echo -e "${RED}❌ Неверный формат IPv6 DNS.${PLAIN}"
                    pause_return
                    continue
                }
                dns_apply_profile "Пользовательские DNS" "$v4_servers" "$v6_servers"
                pause_return
                ;;
            4)
                echo -e "${CYAN}--- /etc/resolv.conf ---${PLAIN}"
                sed -n '1,80p' /etc/resolv.conf 2>/dev/null || true
                if command -v resolvectl >/dev/null 2>&1; then
                    echo -e "\n${CYAN}--- resolvectl dns ---${PLAIN}"
                    resolvectl dns 2>/dev/null || true
                fi
                pause_return
                ;;
            5) dns_restore_latest_backup; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# 23. Защита от превышения трафика (выключение при достижении лимита)
# ---------------------------------------------------------
