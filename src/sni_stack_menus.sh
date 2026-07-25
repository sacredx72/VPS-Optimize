# shellcheck shell=bash
# 443 single-entry secondary menus for sites, routes, and web whitelist controls.

manage_sni_stack_sites() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🌐 Управление сайтами/доменами обратного прокси для 443${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: добавление, удаление или просмотр сайтов/доменов обратного прокси для машин, уже настроенных на единый вход 443.${PLAIN}"
        echo -e "${YELLOW}Для последующего добавления сайтов не нужно перезапускать первоначальную настройку, достаточно указать домен и локальный порт бэкенда.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Просмотр текущих сайтов/доменов обратного прокси${PLAIN}"
        echo -e "${GREEN}  2. Добавить сайт/домен обратного прокси${PLAIN}"
        echo -e "${GREEN}  3. Изменить бэкенд сайта/обратного прокси${PLAIN}"
        echo -e "${GREEN}  4. Удалить сайт/домен обратного прокси${PLAIN}"
        echo -e "${GREEN}  5. Управление IP-белым списком доменов${PLAIN}       ${YELLOW}(ограничивает только выбранный домен)${PLAIN}"
        echo -e "${GREEN}  6. Применить заново и перезапустить Nginx/Caddy${PLAIN}"
        echo -e "${GREEN}  7. Проверка состояния цепочки единого входа 443${PLAIN}"
        echo -e "${GREEN}  8. Переключить движок Web-обратного прокси${PLAIN}       ${YELLOW}(Caddy / Nginx локальный обратный прокси)${PLAIN}"
        echo -e "${GREEN}  9. Изменить домен панели${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Просмотр справки${PLAIN}"
        echo -e "${RED}  0. Вернуться на уровень выше / q/back/назад${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local choice
        read_trimmed choice "👉 Введите номер меню или ?: "
        case "$choice" in
            1) list_sni_stack_sites ;;
            2) add_sni_stack_site ;;
            3) edit_sni_stack_site_backend ;;
            4) remove_sni_stack_site ;;
            5) manage_sni_stack_ip_whitelist ;;
            6) reapply_sni_stack_from_env ;;
            7) sni_stack_health_check ;;
            8) switch_sni_stack_web_proxy_engine ;;
            9) edit_sni_stack_panel_domain_profile ;;
            "?"|help) show_sni_help; pause_return; continue ;;
            0) break ;;
            *) echo -e "${RED}❌ Неверный выбор, введите номер меню или ?.${PLAIN}" ;;
        esac
        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}
