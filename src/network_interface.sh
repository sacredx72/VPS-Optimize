# shellcheck shell=bash
# Обзор сетевых интерфейсов и оперативные управляющие функции.

network_iface_exists() {
    local iface="$1"
    [[ -n "$iface" && "$iface" != *"/"* && "$iface" != *".."* && -d "/sys/class/net/${iface}" ]]
}

network_default_ifaces() {
    {
        ip -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}'
        ip -o -6 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}'
    } | sort -u
}

network_iface_is_default_route() {
    local iface="$1"
    network_default_ifaces | grep -Fxq "$iface"
}

network_choose_iface() {
    local default_iface iface
    default_iface=$(traffic_guard_detect_iface)
    iface=$(ask_with_default "Имя сетевого интерфейса" "${default_iface:-eth0}")
    if ! network_iface_exists "$iface"; then
        echo -e "${RED}❌ Интерфейс ${iface} не существует.${PLAIN}" >&2
        return 1
    fi
    printf '%s' "$iface"
}

network_show_overview() {
    echo -e "${CYAN}--- Адреса интерфейсов ---${PLAIN}"
    ip -br addr 2>/dev/null || ip addr
    echo ""
    echo -e "${CYAN}--- Маршруты по умолчанию ---${PLAIN}"
    ip route show default 2>/dev/null || true
    ip -6 route show default 2>/dev/null || true
    echo ""
    echo -e "${CYAN}--- DNS ---${PLAIN}"
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns 2>/dev/null || cat /etc/resolv.conf 2>/dev/null
    else
        cat /etc/resolv.conf 2>/dev/null || true
    fi
}

network_show_iface_detail() {
    local iface
    iface=$(network_choose_iface) || return 1
    echo -e "${CYAN}--- Детали канала ${iface} ---${PLAIN}"
    ip -d link show dev "$iface" 2>/dev/null || ip link show dev "$iface"
    echo ""
    echo -e "${CYAN}--- Статистика трафика ${iface} ---${PLAIN}"
    ip -s link show dev "$iface" 2>/dev/null || true
    if command -v ethtool >/dev/null 2>&1; then
        echo ""
        echo -e "${CYAN}--- Драйвер/скорость ${iface} ---${PLAIN}"
        ethtool "$iface" 2>/dev/null | sed -n '1,40p' || true
    fi
}

network_set_iface_state() {
    local state="$1"
    local iface
    iface=$(network_choose_iface) || return 1
    if [[ "$state" == "down" ]]; then
        local default_hint=""
        if network_iface_is_default_route "$iface"; then
            default_hint="Этот интерфейс является маршрутом по умолчанию, его отключение, скорее всего, разорвёт SSH-соединение."
        else
            default_hint="Отключение интерфейса повлияет на все соединения через этот интерфейс."
        fi
        confirm_danger "Отключить интерфейс ${iface}" \
            "Состояние канала интерфейса ${iface}" \
            "Включите интерфейс через консоль провайдера или это меню" \
            "${default_hint}" || return 1
    fi
    ip link set dev "$iface" "$state" || {
        echo -e "${RED}❌ Не удалось установить ${iface} в состояние ${state}.${PLAIN}"
        return 1
    }
    echo -e "${GREEN}✅ Интерфейс ${iface} установлен в состояние: ${state}${PLAIN}"
}

network_set_iface_mtu() {
    local iface mtu
    iface=$(network_choose_iface) || return 1
    read_trimmed mtu "Введите временный MTU (576-9000, после перезагрузки может сброситься): "
    if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( 10#$mtu < 576 || 10#$mtu > 9000 )); then
        echo -e "${RED}❌ Неверный MTU.${PLAIN}"
        return 1
    fi
    confirm_risk_action "Установить MTU ${iface} в ${mtu}" \
        "Текущий MTU интерфейса ${iface}" \
        "Установите прежний MTU или перезагрузите сеть/систему для восстановления значений провайдера" \
        "Неверный MTU может вызвать проблемы с доступом к некоторым сайтам или туннелям." || return 1
    ip link set dev "$iface" mtu "$mtu" || {
        echo -e "${RED}❌ Не удалось установить MTU.${PLAIN}"
        return 1
    }
    echo -e "${GREEN}✅ MTU интерфейса ${iface} временно установлен в ${mtu}${PLAIN}"
}

network_renew_dhcp() {
    local iface
    iface=$(network_choose_iface) || return 1
    confirm_danger "Обновить DHCP-аренду на ${iface}" \
        "Сетевой адрес/подключение интерфейса ${iface}" \
        "Восстановите подключение через консоль провайдера или перезагрузите систему" \
        "Если это публичный интерфейс, используемый для SSH, обновление аренды может временно разорвать соединение." || return 1
    if command -v dhclient >/dev/null 2>&1; then
        dhclient -r "$iface" >/dev/null 2>&1 || true
        dhclient "$iface" || return 1
    elif command -v networkctl >/dev/null 2>&1; then
        networkctl renew "$iface" || return 1
    elif command -v nmcli >/dev/null 2>&1; then
        nmcli device reapply "$iface" || nmcli device connect "$iface" || return 1
    else
        echo -e "${YELLOW}⚠️ dhclient/networkctl/nmcli не обнаружены, автоматическое обновление DHCP невозможно.${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}✅ Попытка обновления DHCP/сети для ${iface} выполнена.${PLAIN}"
}

func_network_interface_manage() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Сеть/оптимизация ядра > Инструменты управления интерфейсами"
        echo -e "${BOLD}🧰 Инструменты управления интерфейсами${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: просмотр интерфейсов, маршрутов, DNS и состояния каналов; опасные операции требуют подтверждения.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Обзор интерфейсов / маршрутов / DNS${PLAIN}"
        echo -e "${GREEN}  2. Детали указанного интерфейса и статистика трафика${PLAIN}"
        echo -e "${GREEN}  3. Включить интерфейс${PLAIN}"
        echo -e "${RED}  4. Отключить интерфейс${PLAIN}"
        echo -e "${YELLOW}  5. Временно установить MTU интерфейса${PLAIN}"
        echo -e "${YELLOW}  6. Обновить DHCP/сетевое подключение${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться на уровень выше / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        local choice
        read_trimmed choice "👉 Выберите действие: "
        case "$choice" in
            1) network_show_overview; pause_return ;;
            2) network_show_iface_detail; pause_return ;;
            3) network_set_iface_state up; pause_return ;;
            4) network_set_iface_state down; pause_return ;;
            5) network_set_iface_mtu; pause_return ;;
            6) network_renew_dhcp; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------
# 24. Меню сетевого ускорения и оптимизации ядра (второй уровень)
# ---------------------------------------------------------
