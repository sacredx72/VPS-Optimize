# shellcheck shell=bash
# Установка Fail2ban и защита от взлома SSH.

func_fail2ban() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}Управление Fail2ban защитой от взлома${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    
    local current_p
    current_p=$(ss -tlnp 2>/dev/null | grep -w 'sshd' | awk '{print $4}' | awk -F: '{print $NF}' | head -n1)
    if [[ -z "$current_p" ]]; then
        current_p=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    fi
    current_p=${current_p:-22}
    
    echo -e "${YELLOW}👉 Текущий обнаруженный SSH-порт: ${GREEN}$current_p${PLAIN}"
    echo -e "------------------------------------------------"
    
    local f2b_status="${RED}Не установлен${PLAIN}"
    if command -v fail2ban-server >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban; then
            f2b_status="${GREEN}Запущен${PLAIN}"
        else
            f2b_status="${YELLOW}Остановлен${PLAIN}"
        fi
    fi
    
    echo -e "Текущий статус Fail2ban: [ $f2b_status ]"
    echo -e "  ${GREEN}1.${PLAIN} Установить и настроить Fail2ban ${YELLOW}(автоматически привязывается к текущему SSH-порту)${PLAIN}"
    echo -e "  ${BLUE}2.${PLAIN} Обновить защищаемый порт ${YELLOW}(если вы только что изменили SSH-порт)${PLAIN}"
    echo -e "  ${RED}3.${PLAIN} Полное удаление Fail2ban"
    echo -e "  ${RED}0.${PLAIN} Вернуться в главное меню"
    echo -e "------------------------------------------------"
    
    local f_choice
    read_trimmed f_choice "👉 Выберите действие: "
    
    case $f_choice in
        1|2)
            if [[ "$f_choice" == "1" ]]; then
                echo -e "${CYAN}Установка Fail2ban...${PLAIN}"
                if is_debian; then
                    install_pkg fail2ban python3-systemd
                else
                    install_pkg fail2ban
                fi
            fi
            
            if command -v fail2ban-server >/dev/null 2>&1; then
                echo -e "${CYAN}Запись конфигурации с привязкой к порту $current_p ...${PLAIN}"
                local f2b_backend="auto"
                if command -v journalctl >/dev/null 2>&1; then
                    f2b_backend="systemd"
                fi
                cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $current_p
backend = $f2b_backend
EOF
                systemctl enable fail2ban >/dev/null 2>&1
                systemctl restart fail2ban >/dev/null 2>&1
                if systemctl is-active --quiet fail2ban; then
                    echo -e "${GREEN}✅ Fail2ban настроен и запущен! (защищённый порт: $current_p, бэкенд: $f2b_backend)${PLAIN}"
                    echo -e "${YELLOW}💡 Правило: 5 ошибок пароля за 10 минут — IP блокируется на 24 часа.${PLAIN}"
                else
                    echo -e "${RED}❌ Не удалось запустить Fail2ban, показываю логи:${PLAIN}"
                    fail2ban-client -t 2>/dev/null || true
                    journalctl -u fail2ban -n 20 --no-pager 2>/dev/null || true
                fi
            else
                echo -e "${RED}❌ Не удалось установить или обнаружить Fail2ban, проверьте источники пакетов.${PLAIN}"
            fi
            ;;
        3)
            echo -e "${CYAN}Удаление Fail2ban...${PLAIN}"
            remove_pkg fail2ban
            quarantine_path /etc/fail2ban "/etc/vps-optimize/quarantine" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ Fail2ban удалён, старые конфигурации изолированы в /etc/vps-optimize/quarantine.${PLAIN}"
            ;;
        0) return ;;
        *) echo -e "${RED}❌ Неверный ввод!${PLAIN}"; sleep 1 ;;
    esac
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
}
# ---------------------------------------------------------
# Новая функция: добавление SSH-публичного ключа
# ---------------------------------------------------------
