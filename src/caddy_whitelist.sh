# shellcheck shell=bash
# Манипуляции с блоком конфигурации белого списка IP для доменов Caddy/Web и поток меню.

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

    local domain conf_file first_site_line action backup_file
    read_trimmed domain "Введите домен для управления (например panel.example.com): "
    domain=$(normalize_domain_input "$domain")
    if ! is_valid_domain "$domain"; then
        echo -e "${RED}❌ Неверный формат домена.${PLAIN}"
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
    echo -e "0. Отмена"
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
                read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                return
            fi
            append_vps_public_ips_to_whitelist ip_whitelist_array
            ip_whitelist_ranges=$(join_array_by_space "${ip_whitelist_array[@]}")
            cp -p "$conf_file" "$backup_file" || { echo -e "${RED}❌ Резервное копирование не удалось, отмена.${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."; return; }
            if insert_caddy_ip_whitelist_block "$conf_file" "$ip_whitelist_ranges" && caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
                if systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ Для ${domain} включён IP-белый список: ${ip_whitelist_ranges}${PLAIN}"
                    echo -e "${CYAN}Резервная копия конфигурации сохранена: ${backup_file}${PLAIN}"
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
                echo -e "${CYAN}Резервная копия конфигурации сохранена: ${backup_file}${PLAIN}"
            else
                echo -e "${RED}❌ Проверка Caddy после очистки не удалась, откат...${PLAIN}"
                mv "$backup_file" "$conf_file"
            fi
            ;;
        0|"")
            echo -e "${BLUE}Отмена.${PLAIN}"
            ;;
        *)
            echo -e "${RED}❌ Неверное действие.${PLAIN}"
            ;;
    esac

    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# Оптимизация и рефакторинг: атомарная очистка сертификатов домена и освобождение портов (модульная безопасная версия)
# ---------------------------------------------------------
