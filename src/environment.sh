# shellcheck shell=bash
# Установка общих сред выполнения и зависимостей.

func_env_install() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Базовые компоненты и службы"
        echo -e "${BOLD}📦 Базовые компоненты и службы${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: установка базовых компонентов, туннелей и служб. Обратный прокси Caddy/Nginx — через главное меню [4], единый вход 443 — через [19].${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BOLD}${BLUE}▶ Базовая среда выполнения${PLAIN}"
        echo -e "${GREEN}  1. Docker Engine        ${YELLOW}  2. Python окружение   ${GREEN}  3. iperf3 инструмент${PLAIN}"
        echo -e "${BOLD}${BLUE}▶ Туннели, прокси и службы${PLAIN}"
        echo -e "${GREEN}  4. WARP разблокировка   ${YELLOW}  5. Realm проброс портов${GREEN}  6. Gost туннель${PLAIN}"
        echo -e "${GREEN}  7. Forwardx панель      ${YELLOW}  8. Argox узел         ${GREEN}  9. Aurora панель${PLAIN}"
        echo -e "${GREEN} 10. nftables NAT трансляция${YELLOW} 11. Aria2 загрузка    ${GREEN} 12. PVE виртуализация${PLAIN}"
        echo -e "${GREEN} 13. FLVX панель          ${YELLOW} 14. EasyTier сеть     ${GREEN} 15. Tailscale сеть${PLAIN}"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local env_choice
        read_trimmed env_choice "👉 Выберите: "
        
        case $env_choice in
            1) 
                echo -e "${CYAN}▶ Установка Docker Engine...${PLAIN}"
                run_remote_script "Установка Docker Engine" "https://get.docker.com" || echo -e "${RED}❌ Ошибка установки Docker, проверьте сеть!${PLAIN}"
                ;;
            2) run_remote_script "Установка Python окружения" "https://raw.githubusercontent.com/lx969788249/lxspacepy/master/pyinstall.sh" ;;
            3) run_safe "Установка iperf3" install_pkg iperf3 ;;
            4) run_remote_script "Установка WARP разблокировки" "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" ;;
            5) run_remote_script "Установка Realm проброса портов" "https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh" install ;;
            6) run_remote_script "Установка Gost туннеля" "https://raw.githubusercontent.com/qqrrooty/EZgost/main/gost.sh" ;;
            7) run_remote_script "Установка Forwardx панели" "https://raw.githubusercontent.com/poouo/Forwardx/main/scripts/install-panel-local.sh" install ;;
            8) run_remote_script "Установка Argox узла" "https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh" ;;
            9) run_remote_script "Установка Aurora панели" "https://raw.githubusercontent.com/Aurora-Admin-Panel/deploy/main/install.sh" ;;
            10) run_remote_script "Установка nftables NAT трансляции" "https://us.arloor.dev/https://github.com/arloor/nftables-nat-rust/releases/download/v2.0.0/setup.sh" toml ;;
            11) run_remote_script "Установка Aria2 загрузчика" "https://git.io/aria2.sh" ;;
            12) run_remote_script "Установка PVE виртуализации" "https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/build_backend.sh" ;;
            13) run_remote_script "Установка FLVX панели" "https://raw.githubusercontent.com/Sagit-chu/flvx/main/panel_install.sh" ;;
            14) run_remote_script "Установка EasyTier сети" "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh" install ;;
            15)
                if run_remote_script "Установка Tailscale сети" "https://tailscale.com/install.sh"; then
                    echo -e "${GREEN}✅ После установки выполните tailscale up и следуйте инструкциям для входа.${PLAIN}"
                fi
                ;;
            "?"|help) echo "Меню базовых компонентов устанавливает Docker, Python, WARP, туннели и службы. Обратный прокси — через [4], единый вход 443 — через [19]."; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный ввод!${PLAIN}" ;;
        esac
        echo ""
        pause_after_external_script "Нажмите Enter для продолжения..."
    done
}

# ---------------------------------------------------------
# Старый мастер Reality+CF отключён, меню [19] использует новый SNI stack.
# ---------------------------------------------------------
