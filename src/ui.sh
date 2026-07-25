# shellcheck shell=bash
# Помощники вывода UI и подтверждений.

print_breadcrumb() {
    echo -e "${CYAN}VPS-Optimize > $*${PLAIN}"
}

pause_return() {
    local prompt="${1:-Нажмите любую клавишу для продолжения...}"
    read -n 1 -s -r -p "$prompt"
    echo ""
}

confirm_danger() {
    local title="$1"
    local impact="$2"
    local rollback="$3"
    local advice="${4:-}"
    local snapshot_advice="${5:-Рекомендуется сначала создать снимок VPS или убедиться, что доступна консоль снимков/восстановления облачного провайдера.}"
    local confirm
    echo -e "${RED}⚠️ Операция высокого риска: ${title}${PLAIN}"
    echo ""
    echo -e "${YELLOW}Название операции:${PLAIN} ${title}"
    echo -e "${YELLOW}Что будет изменено:${PLAIN}"
    echo -e "- ${impact}"
    echo ""
    echo -e "${YELLOW}Возможные риски:${PLAIN}"
    echo "- При сбое операции SSH, панель, обратный прокси, сертификаты, контейнеры или сетевые службы могут временно стать недоступны."
    echo "- Если правила безопасности облака, брандмауэр, адрес прослушивания или конфигурация сертификатов не совпадают — удалённый доступ может прерваться."
    echo ""
    echo -e "${BLUE}Способы восстановления при ошибке:${PLAIN}"
    echo -e "- ${rollback}"
    echo "- Использовать текущую неразорванную SSH-сессию для восстановления конфигурации."
    echo "- Использовать консоль облачного провайдера, VNC или режим восстановления."
    echo "- Использовать раздел резервного копирования и отката для восстановления уже сохранённых конфигураций."
    echo ""
    echo -e "${CYAN}Рекомендуется ли сначала сделать снимок:${PLAIN} ${snapshot_advice}"
    echo -e "${CYAN}Рекомендации:${PLAIN}"
    echo "- Создан снимок VPS."
    echo "- Проверены правила безопасности облака и системного брандмауэра."
    echo "- Текущую SSH-сессию не разрывать."
    [[ -n "$advice" ]] && echo -e "- ${advice}"
    echo ""
    read_trimmed confirm "Для продолжения введите yes, просто Enter — отмена (регистр не важен): "
    is_yes "$confirm"
}

confirm_risk_action() {
    confirm_danger "$@"
}

render_menu() {
    local items_name="$1"
    local -n menu_items="$items_name"
    local item number title description handler risk

    for item in "${menu_items[@]}"; do
        IFS='|' read -r number title description handler risk <<< "$item"
        echo -e "${GREEN}  ${number}. ${title}${PLAIN}   ${YELLOW}(${description})${PLAIN}"
    done
}

dispatch_menu_choice() {
    local choice="$1"
    local items_name="$2"
    local -n menu_items="$items_name"
    local item number title description handler risk

    for item in "${menu_items[@]}"; do
        IFS='|' read -r number title description handler risk <<< "$item"
        if [[ "$choice" == "$number" ]]; then
            if [[ -n "$risk" ]] && declare -F confirm_menu_risk >/dev/null; then
                confirm_menu_risk "$risk" || return 0
            fi
            "$handler"
            return 0
        fi
    done
    return 1
}
