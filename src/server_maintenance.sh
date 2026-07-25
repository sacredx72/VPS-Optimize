# shellcheck shell=bash
# Освобождение портов и перезагрузка сервера.

func_port_kill() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}🔍 Проверка занятости портов и освобождение процессов${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Список активных прослушиваемых портов:${PLAIN}"
        echo -e "------------------------------------------------"
        printf "%-10s %-15s %-20s\n" "Протокол" "Порт" "Процесс (PID)"
        
        ss -tulnp | grep -E 'LISTEN|UNCONN' | while read -r line; do
            local proto=$(echo "$line" | awk '{print $1}')
            local port=$(echo "$line" | awk '{print $5}' | awk -F: '{print $NF}')
            local pid=$(echo "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
            local proc=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
            
            local proc_info=""
            if [[ -z "$proc" || -z "$pid" ]]; then
                proc_info="Системный / нет прав"
            else
                proc_info="$proc (PID: $pid)"
            fi
            printf "%-10s %-15s %-20s\n" "$proto" "$port" "$proc_info"
        done | sort -n -k2 | uniq
        
        echo -e "------------------------------------------------"
        echo -e "${GREEN}👉 Найдите конфликтующий порт и введите его для принудительного завершения процесса.${PLAIN}"
        echo -e "${RED}⚠️ Не завершайте процесс sshd (обычно порт 22), иначе потеряете связь!${PLAIN}"
        echo -e "------------------------------------------------"
        
        local p_choice
        read_trimmed p_choice "❓ Введите порт для принудительного завершения (0 для возврата в главное меню): "
        
        if [[ "$p_choice" == "0" ]]; then break; fi
        
        if is_valid_port "$p_choice"; then
            local ssh_match
            ssh_match=$(ss -tulnp 2>/dev/null | awk -v port="$p_choice" '$5 ~ ":" port "$" && $0 ~ /(sshd|ssh)/ {print}')
            if [[ -n "$ssh_match" || "$p_choice" == "22" ]]; then
                echo -e "${RED}❌ Обнаружен SSH-порт, завершение отклонено во избежание потери связи.${PLAIN}"
                sleep 2
                continue
            fi
            confirm_danger "Принудительно завершить процесс, занимающий порт ${p_choice}" \
                "Будет отправлен SIGKILL процессу, использующему TCP/UDP ${p_choice}, служба будет немедленно прервана." \
                "Если процесс завершён ошибочно, потребуется вручную перезапустить соответствующую systemd-службу или контейнер." || {
                echo -e "${BLUE}Завершение отменено.${PLAIN}"
                sleep 1
                continue
            }
            echo -e "${CYAN}▶ Принудительное завершение процесса на порту $p_choice ...${PLAIN}"
            
            # Установка fuser, если отсутствует
            if ! command -v fuser >/dev/null 2>&1; then
                install_pkg psmisc
            fi
            
            # Однострочное завершение всех процессов, использующих TCP/UDP порт
            if fuser -k -9 -n tcp "$p_choice" >/dev/null 2>&1 || fuser -k -9 -n udp "$p_choice" >/dev/null 2>&1; then
                echo -e "${GREEN}✅ Процесс принудительно завершён (SIGKILL). Порт освобождён!${PLAIN}"
            else
                echo -e "${BLUE}ℹ️ Не найдено процессов для завершения на этом порту или недостаточно прав.${PLAIN}"
            fi
            sleep 2
        else
            echo -e "${RED}❌ Неверный ввод! Введите числовой порт.${PLAIN}"
            sleep 1
        fi
    done
}

func_reboot_server() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🔁 Перезагрузка сервера${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    confirm_danger "Немедленная перезагрузка сервера" \
        "Текущая SSH-сессия будет разорвана, все работающие службы временно прервутся." \
        "Убедитесь, что консоль облачного провайдера доступна и важные конфигурации сохранены." || {
        echo -e "${BLUE}Перезагрузка отменена.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    }
    reboot
}
# ---------------------------------------------------------
# 19. Горячее обновление скрипта
# ---------------------------------------------------------
