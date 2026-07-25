# shellcheck shell=bash
# Обнаружение и миграция проектов в Dockge.

is_dockge_migration_seen() {
    local needle="$1"
    local item
    for item in "${DOCKGE_MIGRATION_DIRS[@]}"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

add_dockge_migration_candidate() {
    local dir="$1"
    local stacks_dir="$2"
    local name

    dir="${dir%/}"
    [[ -d "$dir" ]] || return 0
    [[ "$dir" == "/opt/dockge" ]] && return 0
    [[ "$dir" == "$stacks_dir" || "$dir" == "$stacks_dir"/* ]] && return 0
    find_compose_file "$dir" >/dev/null 2>&1 || return 0
    is_dockge_migration_seen "$dir" && return 0

    name=$(basename "$dir")
    DOCKGE_MIGRATION_NAMES+=("$name")
    DOCKGE_MIGRATION_DIRS+=("$dir")
}

discover_dockge_migration_candidates() {
    local stacks_dir="$1"
    local dir file
    DOCKGE_MIGRATION_NAMES=()
    DOCKGE_MIGRATION_DIRS=()

    for dir in /opt/sublinkpro /opt/miaomiaowu /opt/sub-store; do
        add_dockge_migration_candidate "$dir" "$stacks_dir"
    done

    for file in /opt/*/compose.yaml /opt/*/compose.yml /opt/*/docker-compose.yml /opt/*/docker-compose.yaml; do
        [[ -e "$file" ]] || continue
        add_dockge_migration_candidate "$(dirname "$file")" "$stacks_dir"
    done
}

migrate_compose_project_to_dockge() {
    local source_dir="$1"
    local stacks_dir="$2"
    local source_compose stack_name target_dir compose_name restart_confirm
    local restart_stack="true"

    source_dir="${source_dir%/}"
    source_compose=$(find_compose_file "$source_dir") || {
        echo -e "${RED}❌ Конфигурация Compose не найдена: ${source_dir}${PLAIN}"
        return 1
    }

    stack_name=$(ask_with_default "Имя стека Dockge" "$(basename "$source_dir")")
    if [[ ! "$stack_name" =~ ^[A-Za-z0-9_.-]+$ || "$stack_name" == "." || "$stack_name" == ".." ]]; then
        echo -e "${RED}❌ Неверное имя стека, разрешены только буквы, цифры, точки, подчёркивания и дефисы.${PLAIN}"
        return 1
    fi

    target_dir="${stacks_dir%/}/${stack_name}"
    if [[ "$source_dir" == "$target_dir" ]]; then
        echo -e "${YELLOW}⚠️ ${source_dir} уже находится в каталоге stacks Dockge, пропуск.${PLAIN}"
        return 0
    fi
    if [[ -e "$target_dir" ]]; then
        echo -e "${RED}❌ Целевой каталог уже существует: ${target_dir}${PLAIN}"
        echo -e "${YELLOW}Проверьте, есть ли уже такой стек в Dockge, или выберите другое имя.${PLAIN}"
        return 1
    fi

    echo -e "------------------------------------------------"
    echo -e "${YELLOW}Будет перенесён: ${CYAN}${source_dir}${PLAIN}"
    echo -e "${YELLOW}В: ${CYAN}${target_dir}${PLAIN}"
    echo -e "${YELLOW}Compose: ${CYAN}${source_compose}${PLAIN}"
    echo -e "${YELLOW}Пояснение: весь каталог проекта будет перемещён, относительные смонтированные каталоги данных сохранятся.${PLAIN}"
    echo -e "${YELLOW}Если проект использует именованные тома Docker, рекомендуется оставить имя стека таким же, как исходный каталог.${PLAIN}"
    confirm_risk_action "Миграция Compose-проекта в Dockge" \
        "Каталог Compose-проекта, остановка/запуск контейнеров и путь стека Dockge" \
        "Вручную переместите ${target_dir} обратно в ${source_dir} и перезапустите с исходным compose-файлом" \
        "Убедитесь, что проект не использует абсолютные пути, и важные данные зарезервированы." || { echo -e "${BLUE}Миграция ${source_dir} отменена.${PLAIN}"; return 0; }

    read_trimmed restart_confirm "Сначала остановить старые контейнеры и перезапустить в новом каталоге? (Y/n): "
    if is_no "$restart_confirm"; then
        restart_stack="false"
    fi

    if [[ "$restart_stack" == "true" ]]; then
        echo -e "${CYAN}▶ Остановка Compose-проекта в старом каталоге...${PLAIN}"
        ( cd "$source_dir" && $DOCKER_COMPOSE_CMD down ) || {
            echo -e "${RED}❌ Остановка старого проекта не удалась, миграция прервана.${PLAIN}"
            return 1
        }
    fi

    mkdir -p "$stacks_dir" || return 1
    mv "$source_dir" "$target_dir" || {
        echo -e "${RED}❌ Перемещение каталога не удалось: ${source_dir} -> ${target_dir}${PLAIN}"
        return 1
    }

    compose_name=$(basename "$source_compose")
    if [[ "$compose_name" == docker-compose.y* && ! -f "${target_dir}/compose.yaml" ]]; then
        mv "${target_dir}/${compose_name}" "${target_dir}/compose.yaml" || {
            echo -e "${RED}❌ Переименование файла Compose не удалось, проверьте вручную: ${target_dir}${PLAIN}"
            return 1
        }
    fi

    if [[ "$restart_stack" == "true" ]]; then
        echo -e "${CYAN}▶ Перезапуск Compose-проекта в новом каталоге...${PLAIN}"
        ( cd "$target_dir" && $DOCKER_COMPOSE_CMD up -d ) || {
            echo -e "${RED}❌ Запуск в новом каталоге не удался, проверьте вручную: ${target_dir}${PLAIN}"
            return 1
        }
    fi

    echo -e "${GREEN}✅ Проект перенесён в стеки Dockge: ${target_dir}${PLAIN}"
    echo -e "${YELLOW}Обновите/отсканируйте каталог stacks в интерфейсе Dockge для управления.${PLAIN}"
}

func_migrate_compose_to_dockge() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Перенос существующих Compose-проектов в Dockge${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Подходит для случая, когда Dockge установлен позже: переносит существующие проекты docker-compose.yml / compose.yaml в каталог stacks Dockge.${PLAIN}"
    echo -e "${YELLOW}Рекомендуется убедиться, что службы могут быть ненадолго остановлены, и сделана резервная копия важных данных.${PLAIN}"
    echo -e "------------------------------------------------"

    ensure_docker_compose_ready || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    local stacks_dir="/opt/stacks"
    local choice custom_dir i
    stacks_dir=$(ask_with_default "Каталог stacks Dockge" "$stacks_dir")
    mkdir -p "$stacks_dir" || { echo -e "${RED}❌ Не удалось создать каталог stacks: ${stacks_dir}${PLAIN}"; read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    discover_dockge_migration_candidates "$stacks_dir"

    if [[ "${#DOCKGE_MIGRATION_DIRS[@]}" -gt 0 ]]; then
        echo -e "${GREEN}Обнаружены следующие проекты Compose для переноса:${PLAIN}"
        for i in "${!DOCKGE_MIGRATION_DIRS[@]}"; do
            echo -e "${GREEN}  $((i + 1)). ${DOCKGE_MIGRATION_NAMES[$i]}${PLAIN} ${CYAN}(${DOCKGE_MIGRATION_DIRS[$i]})${PLAIN}"
        done
        echo -e "${BOLD}${YELLOW}  a. Перенести все обнаруженные проекты${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ Не обнаружено обычных Compose-проектов в /opt.${PLAIN}"
    fi
    echo -e "${CYAN}  c. Ввести каталог проекта вручную${PLAIN}"
    echo -e "${RED}  0. Вернуться${PLAIN}"
    echo -e "------------------------------------------------"

    read_trimmed choice "Выберите проект для переноса: "
    case "$choice" in
        0) return ;;
        a|A)
            if [[ "${#DOCKGE_MIGRATION_DIRS[@]}" -eq 0 ]]; then
                echo -e "${YELLOW}⚠️ Нет проектов для автоматического переноса.${PLAIN}"
            else
                for i in "${!DOCKGE_MIGRATION_DIRS[@]}"; do
                    migrate_compose_project_to_dockge "${DOCKGE_MIGRATION_DIRS[$i]}" "$stacks_dir" || true
                    echo -e "------------------------------------------------"
                done
            fi
            ;;
        c|C)
            read_trimmed custom_dir "Введите каталог существующего Compose-проекта: "
            migrate_compose_project_to_dockge "$custom_dir" "$stacks_dir"
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DOCKGE_MIGRATION_DIRS[@]} )); then
                migrate_compose_project_to_dockge "${DOCKGE_MIGRATION_DIRS[$((choice - 1))]}" "$stacks_dir"
            else
                echo -e "${RED}❌ Неверный выбор!${PLAIN}"
            fi
            ;;
    esac

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}
# ---------------------------------------------------------
# 18. Восстановление панели / сброс SSL (совместимость с новыми 3x-ui)
# ---------------------------------------------------------
