# shellcheck shell=bash
# Аудит публичных портов Docker, статус управляемых проектов и безопасность Docker.

docker_port_line_is_public() {
    local line="$1"
    case "$line" in
        *"0.0.0.0:"*|*":::"*|*"[::]:"*|*"[0:0:0:0:0:0:0:0]:"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

print_managed_container_status() {
    local title="$1"
    local container="$2"
    local dir="$3"
    local state health ports compose_file

    if docker inspect "$container" >/dev/null 2>&1; then
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)
        ports=$(docker port "$container" 2>/dev/null | tr '\n' '; ')
        [[ -z "$ports" ]] && ports="Не опубликованы порты Docker или используется host-сеть"
        [[ -z "$health" ]] && health="healthcheck отсутствует"
        echo -e "${GREEN}${title}${PLAIN}: ${state} / ${health}"
        echo -e "  Порты: ${ports}"
    else
        echo -e "${YELLOW}${title}${PLAIN}: контейнер ${container} не обнаружен"
    fi

    compose_file=$(find_compose_file "$dir" 2>/dev/null || true)
    if [[ -n "$compose_file" ]]; then
        echo -e "  Compose: ${CYAN}${compose_file}${PLAIN}"
    else
        echo -e "  Compose: ${BLUE}каталог ${dir} не обнаружен${PLAIN}"
    fi
}

print_subscription_compose_status() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker не установлен, пропускаем состояние контейнеров подписок.${PLAIN}"
        return 0
    fi
    print_managed_container_status "SublinkPro" "sublinkpro" "/opt/sublinkpro"
    print_managed_container_status "妙妙屋订阅管理" "miaomiaowu" "/opt/miaomiaowu"
    print_managed_container_status "Sub-Store" "sub-store" "/opt/sub-store"
    print_managed_container_status "Dockge" "dockge" "/opt/dockge"
    print_managed_container_status "Komari" "komari" "/opt/komari"
}

func_docker_project_status() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Безопасность Docker > Статус контейнеров проектов"
    echo -e "${BOLD}🐳 Статус контейнеров, связанных с 443 / подписками${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Здесь проверяются только контейнеры, относящиеся к этому проекту: SublinkPro, 妙妙屋, Sub-Store, Dockge, Komari.${PLAIN}"
    echo -e "${YELLOW}3x-ui, Caddy, Nginx обычно управляются как systemd-службы, смотрите [15] или проверку [19].${PLAIN}"
    echo -e "------------------------------------------------"
    print_subscription_compose_status
    echo -e "------------------------------------------------"
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_docker_443_exposure_audit() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Безопасность Docker > Аудит публичного доступа 443"
    echo -e "${BOLD}🔎 Аудит публичных портов Docker${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Цель: после включения единого входа 443 инструменты подписки и панели управления должны по возможности слушать только 127.0.0.1, а наружу их выставлять через Caddy/Nginx.${PLAIN}"
    echo -e "------------------------------------------------"

    local found_public=false
    local line name ports
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        ports=$(docker port "$name" 2>/dev/null || true)
        [[ -z "$ports" ]] && continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if docker_port_line_is_public "$line"; then
                found_public=true
                echo -e "${YELLOW}⚠️ ${name}: ${line}${PLAIN}"
            fi
        done <<< "$ports"
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)

    if $found_public; then
        echo -e "------------------------------------------------"
        echo -e "${YELLOW}Рекомендация: подписки, Dockge, Komari следует привязывать к 127.0.0.1, а публичный доступ организовывать через [19] -> [8] добавление прокси-домена 443.${PLAIN}"
        echo -e "${YELLOW}Если действительно нужен прямой доступ, убедитесь, что безопасная группа облака, брандмауэр и доступ защищены.${PLAIN}"
    else
        echo -e "${GREEN}✅ Не обнаружено публичных портов Docker через 0.0.0.0 / ::.${PLAIN}"
    fi

    echo -e "------------------------------------------------"
    print_subscription_compose_status
    echo -e "------------------------------------------------"
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_docker_manage() {
    if declare -F ensure_docker_engine_ready >/dev/null 2>&1; then
        ensure_docker_engine_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
    elif ! command -v docker >/dev/null 2>&1; then
        clear
        echo -e "${RED}❌ Docker не обнаружен, и среда выполнения не поддерживает автоматическую установку.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    
    # Установка зависимостей (используем install_pkg)
    if ! command -v jq >/dev/null 2>&1; then install_pkg jq; fi

    while true; do
        clear
        local docker_ver
        docker_ver=$(docker -v | awk '{print $3}' | tr -d ',')
        
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Безопасность Docker"
        echo -e "${BOLD}🐳 Безопасность Docker (версия: ${GREEN}${docker_ver}${PLAIN}${BOLD})${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${GREEN}  1. Статус контейнеров 443 / подписок${PLAIN}"
        echo -e "${GREEN}  2. Аудит публичных портов Docker${PLAIN} ${YELLOW}(проверка обхода единого входа 443)${PLAIN}"
        echo -e "${GREEN}  3. Включить локальную защиту Docker${PLAIN} ${YELLOW}(ограничить опубликованные порты только 127.0.0.1)${PLAIN}"
        echo -e "${GREEN}  4. Отключить локальную защиту Docker${PLAIN} ${YELLOW}(восстановить доступ извне)${PLAIN}"
        echo -e "${BOLD}${YELLOW}  5. Обновить контейнеры подписок${PLAIN} ${CYAN}(SublinkPro / 妙妙屋 / Sub-Store)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        
        local c
        read_trimmed c "👉 Выберите действие: "
        case $c in
            1) func_docker_project_status ;;
            2) func_docker_443_exposure_audit ;;
            3)
                confirm_risk_action "Включить локальную защиту Docker" \
                    "Docker daemon.json и перезапуск службы Docker" \
                    "Восстановите из автоматически созданной резервной копии daemon.json и перезапустите Docker" \
                    "Убедитесь, что существующие контейнеры не зависят от прямого публичного доступа." || { echo -e "${BLUE}Операция отменена.${PLAIN}"; sleep 1; continue; }
                echo -e "${CYAN}▶ Настройка политики безопасности Docker...${PLAIN}"
                mkdir -p /etc/docker
                local conf_file="/etc/docker/daemon.json"
                local backup_file="${conf_file}.bak_$(date +%s)"
                local tmp_json
                tmp_json=$(mktemp /tmp/docker-daemon.XXXXXX) || { echo -e "${RED}❌ Не удалось создать временный файл, отмена.${PLAIN}"; sleep 1; continue; }
                
                if [[ -f "$conf_file" ]]; then
                    if ! cp -p "$conf_file" "$backup_file"; then
                        echo -e "${RED}❌ Не удалось создать резервную копию конфигурации Docker, отмена.${PLAIN}"
                        rm -f "$tmp_json"
                        sleep 1
                        continue
                    fi
                    echo -e "${YELLOW}⚠️ Создана резервная копия исходной конфигурации: $backup_file${PLAIN}"
                    
                    # Неразрушающее слияние с jq, сохранение всех существующих настроек
                    if ! jq '. + {"ip": "127.0.0.1", "log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}}' "$conf_file" > "$tmp_json" 2>/dev/null; then
                        echo -e "${RED}❌ Исходный daemon.json повреждён, слияние не удалось! Операция прервана.${PLAIN}"
                        rm -f "$tmp_json"
                        echo -e "${YELLOW}Резервная копия сохранена: $backup_file${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    fi
                    mv "$tmp_json" "$conf_file"
                else
                    # Файл отсутствует — создаём новый
                    cat <<EOF > "$conf_file"
{
  "ip": "127.0.0.1",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
                fi
                
                # Безопасный перезапуск с откатом при сбое
                if systemctl restart docker >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ Включена локальная защита, порты контейнеров доступны только для локального прокси!${PLAIN}"
                    [[ -f "$backup_file" ]] && echo -e "${CYAN}Резервная копия конфигурации Docker сохранена: $backup_file${PLAIN}"
                else
                    echo -e "${RED}❌ Критическая ошибка: новая конфигурация не позволяет запустить Docker! Автоматический откат...${PLAIN}"
                    if [[ -f "$backup_file" ]]; then
                        mv "$backup_file" "$conf_file"
                    else
                        quarantine_path "$conf_file" "/etc/vps-optimize/quarantine/docker" >/dev/null 2>&1 || true
                    fi
                    systemctl restart docker >/dev/null 2>&1
                fi
                sleep 2
                ;;
            4)
                local conf_file="/etc/docker/daemon.json"
                if [[ -f "$conf_file" ]]; then
                    confirm_risk_action "Отключить локальную защиту Docker" \
                        "Docker daemon.json и перезапуск Docker" \
                        "Восстановите из автоматически созданной резервной копии daemon.json" \
                        "После отключения опубликованные порты контейнеров могут снова стать публично доступными, проверьте брандмауэр и безопасную группу." || { echo -e "${BLUE}Операция отменена.${PLAIN}"; sleep 1; continue; }
                    echo -e "${CYAN}▶ Безопасное удаление ограничений Docker...${PLAIN}"
                    local backup_file="${conf_file}.bak_$(date +%s)"
                    local tmp_json
                    tmp_json=$(mktemp /tmp/docker-daemon.XXXXXX) || { echo -e "${RED}❌ Не удалось создать временный файл, отмена.${PLAIN}"; sleep 1; continue; }
                    if ! cp -p "$conf_file" "$backup_file"; then
                        echo -e "${RED}❌ Не удалось создать резервную копию конфигурации Docker, отмена.${PLAIN}"
                        rm -f "$tmp_json"
                        sleep 1
                        continue
                    fi

                    # Удаляем только поле ip
                    if ! jq 'del(.ip)' "$conf_file" > "$tmp_json" 2>/dev/null; then
                        echo -e "${RED}❌ Ошибка разбора JSON, операция прервана.${PLAIN}"
                        rm -f "$tmp_json"
                        echo -e "${YELLOW}Резервная копия сохранена: $backup_file${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    fi
                    mv "$tmp_json" "$conf_file"

                    if systemctl restart docker >/dev/null 2>&1; then
                        echo -e "${GREEN}✅ Локальная защита отключена, контейнеры снова доступны извне!${PLAIN}"
                        echo -e "${CYAN}Резервная копия сохранена: $backup_file${PLAIN}"
                    else
                        echo -e "${RED}❌ Ошибка: не удалось запустить Docker! Откат...${PLAIN}"
                        mv "$backup_file" "$conf_file"
                        systemctl restart docker >/dev/null 2>&1
                    fi
                else
                    echo -e "${BLUE}Файл ограничений не обнаружен, система уже открыта.${PLAIN}"
                fi
                sleep 2
                ;;
            5) func_update_subscription_tools ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный ввод!${PLAIN}"; sleep 1 ;;
        esac
    done
}
# ---------------------------------------------------------
# 6. Управление BBR
# ---------------------------------------------------------
