# shellcheck shell=bash
# Просмотр, удаление сертификатов Caddy, очистка конфигураций и настройка прокси с пропуском проверки.

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

func_caddy_delete_cert() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Очистка сертификатов домена и конфигураций${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Будут изолированы сертификаты и конфигурация указанного домена, а также очищены остатки acme.sh.${PLAIN}"
    echo -e "------------------------------------------------"
    
    local domain
    read_trimmed domain "👉 Введите домен для очистки (например panel.site.com): "
    domain=$(normalize_domain_input "$domain")
    if [[ -z "$domain" ]]; then
        echo -e "${RED}❌ Домен не может быть пустым!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    if ! is_valid_domain "$domain"; then
        echo -e "${RED}❌ Неверный формат домена, очистка отменена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "\n${CYAN}▶ Очистка сертификатов и конфигураций домена...${PLAIN}"
    echo -e "${YELLOW}Эта операция переместит сертификаты и конфигурацию этого домена, связанные сайты станут временно недоступны.${PLAIN}"
    echo -e "Подтвердите действие...${PLAIN}"
    if confirm_danger "Очистка сертификатов и конфигурации ${domain}" "Будет остановлен Caddy, изолированы сертификаты, остатки acme.sh и конфигурация Caddy, затем Caddy будет перезапущен." "Убедитесь, что у вас есть системный снимок или резервная копия Caddy; после очистки сертификаты необходимо перевыпустить."; then
        # 1. Остановка Caddy для освобождения портов
        systemctl stop caddy >/dev/null 2>&1
        echo -e "${GREEN}✅ [1/5] Caddy остановлен для освобождения сетевых портов.${PLAIN}"
        
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
            echo -e "${GREEN}✅ [2/5] Ключи и сертификаты для ${domain} удалены из движка Caddy.${PLAIN}"
        else
            echo -e "${BLUE}ℹ️ [2/5] Сертификаты для этого домена не найдены в движке Caddy.${PLAIN}"
        fi
        
        # 3. Очистка остатков acme.sh
        if [[ -d "/root/.acme.sh" ]]; then
            local acme_target=$(find "/root/.acme.sh" -type d -name "*${domain}*" -print -quit 2>/dev/null)
            if [[ -n "$acme_target" ]]; then
                quarantine_path "$acme_target" "/root/.acme.sh/_quarantine" >/dev/null 2>&1 || true
                echo -e "${GREEN}✅ [3/5] Остатки acme.sh для ${domain} удалены.${PLAIN}"
            else
                echo -e "${BLUE}ℹ️ [3/5] Остатков acme.sh не обнаружено.${PLAIN}"
            fi
        else
            echo -e "${BLUE}ℹ️ [3/5] Независимая среда acme.sh не установлена, пропущено.${PLAIN}"
        fi
        
        # 4. Модульное удаление конфигурации
        local domain_conf="/etc/caddy/conf.d/${domain}.caddy"
        if [[ -f "$domain_conf" ]]; then
            echo -e "${YELLOW}⏳ [4/5] Обнаружен файл конфигурации, изоляция...${PLAIN}"
            quarantine_path "$domain_conf" "/etc/vps-optimize/quarantine/caddy-conf" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ [4/5] Файл конфигурации ($domain_conf) изолирован!${PLAIN}"
        else
            echo -e "${GREEN}✅ [4/5] Файл конфигурации для этого домена не найден.${PLAIN}"
        fi

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
    
    local domain
    local backend_addr port
    local backend_hostport
    local enable_ip_whitelist ip_whitelist_input ip_whitelist_ranges current_client_ip
    local -a ip_whitelist_array=()
    read_trimmed domain "👉 Введите разрешённый домен (например panel.site.com): "
    read_trimmed port "👉 Введите локальный HTTPS-порт бэкенда (например 40000): "
    backend_addr=$(ask_with_default "Адрес бэкенда" "127.0.0.1")
    backend_addr=$(normalize_backend_addr_input "$backend_addr")
    domain=$(normalize_domain_input "$domain")
    
    if ! is_valid_domain "$domain" || ! is_valid_port "$port" || ! is_valid_backend_addr "$backend_addr"; then
        echo -e "${RED}❌ Домен пуст или неверный формат порта! Операция отменена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
        return
    fi
    backend_hostport=$(format_hostport "$backend_addr" "$port")

    read_trimmed enable_ip_whitelist "❓ Разрешить доступ к этому домену только с указанных IP/CIDR? (y/n, по умолчанию n): "
    if [[ "$enable_ip_whitelist" =~ ^[Yy]$ ]]; then
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
    
    cat <<EOF > "$conf_file"
$domain {
$(caddy_ip_whitelist_block "$ip_whitelist_ranges")    reverse_proxy https://${backend_hostport} {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF
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
