# shellcheck shell=bash
# Быстрые установщики панелей, узлов, DNS разблокировки и IP Sentinel.

func_xpanel() {
    clear
    local version_choice install_url install_desc ssl_hint
    local -a install_args=()
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Установка 3x-ui / x-ui панели${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Пояснение по учётным данным: этот пункт запускает официальный установщик 3x-ui.${PLAIN}"
    echo -e "${YELLOW}Имя администратора, пароль и путь к панели обычно задаются интерактивно или выводятся в конце установки.${PLAIN}"
    echo -e "${YELLOW}Обратите внимание на вывод и сохраните данные; позже их можно изменить через официальное меню x-ui / 3x-ui.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${GREEN}  1. Установить последнюю версию${PLAIN}       ${YELLOW}(по умолчанию, master установщик)${PLAIN}"
    echo -e "${GREEN}  2. Установить v2.9.4${PLAIN}      ${YELLOW}(фиксированная версия, для машин, использующих туториалы по 2.9.4)${PLAIN}"
    echo -e "${RED}  0. Отмена${PLAIN}"
    echo -e "------------------------------------------------"
    read_trimmed version_choice "Выберите версию 3x-ui (по умолчанию 1): "
    case "$(echo "${version_choice:-1}" | tr '[:upper:]' '[:lower:]')" in
        1|latest|последняя)
            install_desc="Установка 3x-ui / x-ui панели (МОД АВГ)"
            install_url="https://raw.githubusercontent.com/AlexeyLCP/lucx-ui/main/install.sh"
            ssl_hint="Для новых установок 3.x, если установщик спрашивает о методе настройки SSL, выберите Skip SSL / не запрашивать SSL. Единый вход 443 будет обслуживать публичные сертификаты через Caddy + acme.sh."
            ;;
        2|2.9.4|v2.9.4)
            install_desc="Установка 3x-ui / x-ui панели (v2.9.4)"
            install_url="https://raw.githubusercontent.com/mhsanaei/3x-ui/v2.9.4/install.sh"
            install_args=("v2.9.4")
            ssl_hint="v2.9.4 — старый процесс 2.x: если в установщике или панели уже был настроен SSL, последующий мастер единого входа 443 продолжит очистку путей сертификатов панели/подписки по-старому."
            ;;
        0|q|Q)
            echo -e "${BLUE}Установка отменена.${PLAIN}"
            pause_after_external_script "Нажмите Enter для возврата в меню..."
            return
            ;;
        *)
            echo -e "${RED}❌ Неверный выбор, установка отменена.${PLAIN}"
            pause_after_external_script "Нажмите Enter для возврата в меню..."
            return
            ;;
    esac
    echo -e "${YELLOW}${ssl_hint}${PLAIN}"
    echo -e "${CYAN}👉 Загрузка официального установочного скрипта 3x-ui от mhsanaei...${PLAIN}"
    if run_remote_script "$install_desc" "$install_url" "${install_args[@]}"; then
        detect_xui_single_443_defaults
        print_xui_single_443_detected_defaults
    fi
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_xpanel_manage() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Управление / Удаление 3x-ui / x-ui${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: вход в официальное меню управления, просмотр конфигурации, управление учётными записями, обновление или удаление.${PLAIN}"
    echo -e "------------------------------------------------"

    local panel_cmd=""
    if command -v x-ui >/dev/null 2>&1; then
        panel_cmd="x-ui"
    elif command -v 3x-ui >/dev/null 2>&1; then
        panel_cmd="3x-ui"
    fi

    if [[ -z "$panel_cmd" ]]; then
        echo -e "${YELLOW}Команда x-ui / 3x-ui не обнаружена, возможно, панель ещё не установлена.${PLAIN}"
        local yn
        read_trimmed yn "Установить 3x-ui панель сейчас? (y/n): "
        if is_yes "$yn"; then
            func_xpanel
        else
            echo -e "${BLUE}Операция отменена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        fi
        return
    fi

    echo -e "${GREEN}Будет открыто официальное меню управления ${panel_cmd}.${PLAIN}"
    echo -e "${YELLOW}Для удаления выберите соответствующий пункт в официальном меню.${PLAIN}"
    echo -e "------------------------------------------------"
    "$panel_cmd"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_xui_custom_manager() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Расширенный набор x-ui${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: дополняет возможности, отсутствующие в панели 3x-ui, например кастомный сброс трафика, калибровка использованного трафика, бэкап/восстановление и проверка состояния.${PLAIN}"
    echo -e "${YELLOW}Подсказка: также можно ввести xcm в главном меню; внутри скрипта можно нажать ? для просмотра функционала.${PLAIN}"
    echo -e "${YELLOW}Рекомендация: перед изменением базы данных или восстановлением создайте снимок или сделайте бэкап данных x-ui через скрипт.${PLAIN}"
    echo -e "------------------------------------------------"
    run_remote_script "Запуск расширенного набора x-ui" "https://raw.githubusercontent.com/sacredx72/VPS-Optimize/main/xui-custom-manager.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_sui_panel() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Установка S-UI панели${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Пояснение по учётным данным: этот пункт запускает официальный установщик S-UI.${PLAIN}"
    echo -e "${YELLOW}Имя администратора, пароль и параметры доступа к панели задаются установщиком или выводятся в конце.${PLAIN}"
    echo -e "${YELLOW}Обратите внимание на вывод и сохраните данные; позже их можно изменить через официальное меню s-ui.${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${CYAN}👉 Загрузка официального установочного скрипта S-UI от alireza0...${PLAIN}"
    run_remote_script "Установка S-UI панели" "https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_sui_manage() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Управление / Удаление S-UI${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: вход в официальное меню управления S-UI, просмотр конфигурации, управление учётными записями, обновление или удаление.${PLAIN}"
    echo -e "------------------------------------------------"

    if ! command -v s-ui >/dev/null 2>&1; then
        echo -e "${YELLOW}Команда s-ui не обнаружена, возможно, S-UI ещё не установлен.${PLAIN}"
        local yn
        read_trimmed yn "Установить S-UI сейчас? (y/n): "
        if is_yes "$yn"; then
            func_sui_panel
        else
            echo -e "${BLUE}Операция отменена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        fi
        return
    fi

    echo -e "${GREEN}Будет открыто официальное меню управления S-UI.${PLAIN}"
    echo -e "${YELLOW}Для удаления выберите соответствующий пункт в официальном меню.${PLAIN}"
    echo -e "------------------------------------------------"
    s-ui
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_singbox_233boy() {
    clear
    echo -e "${CYAN}👉 Загрузка скрипта 233boy для Sing-box...${PLAIN}"
    echo -e "${YELLOW}Источник: https://github.com/233boy/sing-box${PLAIN}"
    echo -e "${YELLOW}Документация: https://233boy.com/sing-box/sing-box-script/${PLAIN}"
    echo -e "${GREEN}После установки обычно можно использовать команду sing-box или sb для входа в меню управления.${PLAIN}"
    run_remote_script "Установка скрипта 233boy для Sing-box" "https://github.com/233boy/sing-box/raw/main/install.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_singbox_manage() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Управление / Удаление Sing-box${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: вход в меню управления установленного скрипта Sing-box.${PLAIN}"
    echo -e "------------------------------------------------"

    local sb_cmd=""
    if command -v sb >/dev/null 2>&1; then
        sb_cmd="sb"
    elif command -v sing-box >/dev/null 2>&1; then
        sb_cmd="sing-box"
    fi

    if [[ -z "$sb_cmd" ]]; then
        echo -e "${YELLOW}Команда sb / sing-box не обнаружена.${PLAIN}"
        echo -e "${BLUE}Если это первая установка, сначала выберите соответствующий пункт установки Sing-box.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "${GREEN}Будет открыто меню управления ${sb_cmd}.${PLAIN}"
    echo -e "${YELLOW}Для удаления выберите соответствующий пункт в меню скрипта.${PLAIN}"
    echo -e "------------------------------------------------"
    "$sb_cmd"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_xray_233boy() {
    clear
    echo -e "${CYAN}👉 Загрузка скрипта 233boy для Xray...${PLAIN}"
    echo -e "${YELLOW}Источник: https://github.com/233boy/Xray${PLAIN}"
    echo -e "${YELLOW}Документация: https://233boy.com/xray/xray-script/${PLAIN}"
    echo -e "${GREEN}После установки обычно можно использовать команду xray для входа в меню управления.${PLAIN}"
    run_remote_script "Установка скрипта 233boy для Xray" "https://github.com/233boy/Xray/raw/main/install.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

func_xray_manage() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧭 Управление / Удаление Xray${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Назначение: вход в официальное меню управления 233boy Xray.${PLAIN}"
    echo -e "------------------------------------------------"

    if ! command -v xray >/dev/null 2>&1; then
        echo -e "${YELLOW}Команда xray не обнаружена, возможно, скрипт 233boy Xray ещё не установлен.${PLAIN}"
        local yn
        read_trimmed yn "Установить Xray сейчас? (y/n): "
        if is_yes "$yn"; then
            func_xray_233boy
        else
            echo -e "${BLUE}Операция отменена.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        fi
        return
    fi

    echo -e "${GREEN}Будет открыто меню управления xray.${PLAIN}"
    echo -e "${YELLOW}Для удаления выберите соответствующий пункт в официальном меню.${PLAIN}"
    echo -e "------------------------------------------------"
    xray
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

# ---------------------------------------------------------
# 17. DNS разблокировка стриминга (Alice DNS)
# ---------------------------------------------------------
func_dns_unlock() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔓 DNS разблокировка стриминга (DNS-Alice-Unlock)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Описание и инструкция:${PLAIN}"
    echo -e " 1. Скрипт изменяет локальное DNS-разрешение для разблокировки Netflix, Disney+ и других региональных стримингов."
    echo -e " 2. ${GREEN}Маршрутизирует только домены стримингов${PLAIN}, не влияет на ваш реальный IP и обычную скорость интернета."
    echo -e " 3. Проект: ${BLUE}https://github.com/Jimmyzxk/DNS-Alice-Unlock/${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "${RED}⚠️ Предупреждение: этот скрипт изменяет /etc/resolv.conf вашего сервера.${PLAIN}"
    echo -e "    Если вы не знаете, как самостоятельно настраивать DNS для разблокировки, обязательно изучите документацию проекта!"
    echo -e "------------------------------------------------"
    
    local yn
    read_trimmed yn "❓ Запустить скрипт разблокировки Alice DNS сейчас? (y/n): "
    if is_yes "$yn"; then
        run_remote_script "Запуск скрипта разблокировки Alice DNS" "https://raw.githubusercontent.com/Jimmyzxk/DNS-Alice-Unlock/refs/heads/main/dns-unlock.sh"
    else
        echo -e "${BLUE}Операция безопасно отменена.${PLAIN}"
    fi
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}
# ---------------------------------------------------------
# Новая функция: установка IP Sentinel (предотвращение смены локации IP)
# ---------------------------------------------------------
func_ip_sentinel() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🛡️ Установка IP Sentinel (предотвращение смены локации IP)${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${YELLOW}Этот скрипт будет постоянно контролировать и исправлять маршрутизацию, чтобы IP сервера не был ошибочно определён как китайский.${PLAIN}"
    echo -e "------------------------------------------------"
    
    read_trimmed yn "❓ Установить и настроить IP Sentinel (публичный шлюз)? (y/n): "
    if is_yes "$yn"; then
        run_remote_script "Установка и настройка IP Sentinel" "https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh"
    else
        echo -e "${BLUE}Операция отменена.${PLAIN}"
    fi
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}

# ---------------------------------------------------------
# Новая функция: установка SublinkPro (мощная панель управления подписками)
# ---------------------------------------------------------
