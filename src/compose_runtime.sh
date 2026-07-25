# shellcheck shell=bash
# Вспомогательные функции для выполнения Docker Compose и управления проектами Compose.

install_docker_compose_standalone() {
    local compose_url tmp_file
    compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
    tmp_file=$(mktemp /tmp/docker-compose.XXXXXX) || { echo -e "${RED}❌ Не удалось создать временный файл.${PLAIN}"; return 1; }

    if ! download_remote_script "$compose_url" "$tmp_file"; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Не удалось загрузить Docker Compose, проверьте сеть или доступ к GitHub.${PLAIN}"
        return 1
    fi

    if [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Загруженный файл Docker Compose пуст, установка отменена.${PLAIN}"
        return 1
    fi

    if ! mv "$tmp_file" /usr/local/bin/docker-compose; then
        rm -f "$tmp_file"
        echo -e "${RED}❌ Не удалось записать Docker Compose в /usr/local/bin.${PLAIN}"
        return 1
    fi
    chmod +x /usr/local/bin/docker-compose || return 1
}

ensure_docker_engine_ready() {
    if command -v docker >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        return 0
    fi

    echo -e "${YELLOW}⚠️ Docker не обнаружен, автоматическая установка Docker Engine...${PLAIN}"
    if ! VPSO_REMOTE_SCRIPT_CONFIRM=0 run_remote_script "Установка Docker Engine" "https://get.docker.com"; then
        echo -e "${RED}❌ Автоматическая установка Docker не удалась, проверьте сеть или источники.${PLAIN}"
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker не доступен после установки, проверьте логи.${PLAIN}"
        return 1
    fi

    systemctl enable --now docker >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ Docker Engine установлен.${PLAIN}"
}

ensure_docker_compose_ready() {
    DOCKER_COMPOSE_CMD=""
    ensure_docker_engine_ready || return 1

    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo -e "${YELLOW}⚠️ Docker Compose плагин не обнаружен, установка...${PLAIN}"
        install_docker_compose_standalone || return 1
        DOCKER_COMPOSE_CMD="docker-compose"
        echo -e "${GREEN}✅ Docker Compose установлен.${PLAIN}"
    fi
}

find_compose_file() {
    local dir="$1"
    local file
    for file in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        if [[ -f "${dir}/${file}" ]]; then
            echo "${dir}/${file}"
            return 0
        fi
    done
    return 1
}

is_managed_compose_dir() {
    local dir="${1%/}"
    case "$dir" in
        /opt/sublinkpro|/opt/miaomiaowu|/opt/sub-store|/opt/dockge|/opt/komari)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

manage_compose_project() {
    local project_name="$1"
    local project_dir="${2%/}"
    local data_hint="$3"
    local compose_file choice yn

    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🧭 ${project_name} управление / удаление${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Каталог развёртывания: ${CYAN}${project_dir}${PLAIN}"
        echo -e "${YELLOW}Подсказка по данным: ${CYAN}${data_hint}${PLAIN}"
        echo -e "------------------------------------------------"

        if [[ ! -d "$project_dir" ]] || ! compose_file=$(find_compose_file "$project_dir"); then
            echo -e "${YELLOW}Развёртывание ${project_name} через Compose не обнаружено.${PLAIN}"
            echo -e "${BLUE}Сначала вернитесь в предыдущее меню и выберите соответствующий пункт установки.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        fi

        echo -e "${GREEN}  1. Просмотр состояния выполнения${PLAIN}"
        echo -e "${CYAN}  2. Просмотр/редактирование конфигурации Compose${PLAIN} ${YELLOW}(резервное копирование, проверка, up -d)${PLAIN}"
        echo -e "${GREEN}  3. Перезапуск службы${PLAIN}"
        echo -e "${GREEN}  4. Обновить образы и пересобрать${PLAIN}"
        echo -e "${YELLOW}  5. Остановить и удалить контейнеры (данные каталога сохраняются)${PLAIN}"
        echo -e "${RED}  6. Архивация каталога развёртывания (остановка контейнеров и изоляция конфигурации/данных)${PLAIN}"
        echo -e "${RED}  0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1)
                ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" ps)
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            2)
                edit_applied_config_file "$compose_file" "compose" "${project_name} конфигурация Compose"
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            3)
                ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" restart)
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            4)
                ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" pull && $DOCKER_COMPOSE_CMD -f "$compose_file" up -d)
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            5)
                if confirm_risk_action "Остановить и удалить контейнеры ${project_name}" \
                    "Состояние выполнения контейнеров Docker Compose" \
                    "Повторно выполните compose up -d в ${project_dir}, или вернитесь в меню управления и пересоберите" \
                    "Данные каталога сохраняются, но служба будет немедленно прервана."; then
                    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                    (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" down)
                    echo -e "${GREEN}✅ Контейнеры остановлены и удалены, каталог развёртывания сохранён: ${project_dir}${PLAIN}"
                else
                    echo -e "${BLUE}Операция отменена.${PLAIN}"
                fi
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            6)
                echo -e "${RED}⚠️ Высокий риск: контейнеры будут остановлены, а ${project_dir} перемещён в карантин — конфигурация, базы данных или локальные данные перестанут быть доступны на месте.${PLAIN}"
                echo -e "${YELLOW}После архивации для окончательной очистки подтвердите и вручную обработайте карантинный каталог.${PLAIN}"
                if confirm_risk_action "Архивация каталога развёртывания ${project_name}" \
                    "Контейнеры Docker Compose, каталог развёртывания, конфигурация и локальные данные" \
                    "Восстановите вручную из /opt/.vps-optimize-quarantine, вернув на исходный путь, затем перезапустите" \
                    "Убедитесь, что база данных и конфигурация зарезервированы, и служба может быть прервана."; then
                    if ! is_managed_compose_dir "$project_dir"; then
                        echo -e "${RED}❌ Проверка безопасности не пройдена, отказ в архивации не управляемого скриптом каталога: ${project_dir}${PLAIN}"
                    else
                        ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }
                        (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$compose_file" down -v)
                        if quarantine_path "$project_dir" "/opt/.vps-optimize-quarantine"; then
                            echo -e "${GREEN}✅ Архивация ${project_name} выполнена.${PLAIN}"
                        else
                            echo -e "${RED}❌ Ошибка архивации, проверьте каталог вручную: ${project_dir}${PLAIN}"
                        fi
                    fi
                else
                    echo -e "${BLUE}Архивация отменена.${PLAIN}"
                fi
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
                ;;
            0|q|Q) return ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}
