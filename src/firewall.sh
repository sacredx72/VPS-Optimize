# shellcheck shell=bash
# Управление правилами брандмауэра.

port_connlimit_comment() {
    local port="$1"
    printf 'VPSO_CONN_LIMIT_PORT_%s' "$port"
}

is_valid_connlimit_value() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value > 0 ))
}

ensure_connlimit_tool() {
    local cmd="$1"
    local family_label="$2"

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}⚠️ ${cmd} не обнаружен, попытка установить iptables-совместимый инструмент...${PLAIN}"
    install_pkg iptables || true

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${RED}❌ ${cmd} не обнаружен, невозможно записать правила connlimit для ${family_label}.${PLAIN}"
    echo -e "${YELLOW}Установите iptables/ip6tables и повторите попытку.${PLAIN}"
    return 1
}

try_load_connlimit_module() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe xt_connlimit >/dev/null 2>&1 || true
    fi
}

port_connlimit_runtime_rule_count() {
    local cmd="$1"
    local count

    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '0'
        return 0
    fi

    count=$("$cmd" -S INPUT 2>/dev/null | grep -Fc 'VPSO_CONN_LIMIT_PORT_' || true)
    printf '%s' "${count:-0}"
}

port_connlimit_persisted_rule_count() {
    local file="$1"
    local count

    if [[ ! -f "$file" ]]; then
        printf '0'
        return 0
    fi

    count=$(grep -Fc 'VPSO_CONN_LIMIT_PORT_' "$file" 2>/dev/null || true)
    printf '%s' "${count:-0}"
}

port_connlimit_command_path() {
    local cmd="$1"
    local candidate

    if command -v "$cmd" >/dev/null 2>&1; then
        command -v "$cmd"
        return 0
    fi

    for candidate in "/usr/sbin/${cmd}" "/sbin/${cmd}" "/usr/bin/${cmd}" "/bin/${cmd}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

port_connlimit_systemd_unit_exists() {
    local unit="$1"

    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl list-unit-files "${unit}.service" --no-legend 2>/dev/null | grep -q . && return 0
    systemctl list-units "${unit}.service" --all --no-legend 2>/dev/null | grep -q . && return 0
    return 1
}

port_connlimit_rhel_ipv4_persistence_available() {
    is_redhat || return 1
    port_connlimit_command_path iptables-save >/dev/null 2>&1 || return 1

    [[ -f /etc/sysconfig/iptables ]] && return 0
    port_connlimit_systemd_unit_exists iptables
}

port_connlimit_rhel_ipv6_persistence_available() {
    is_redhat || return 1
    port_connlimit_command_path ip6tables-save >/dev/null 2>&1 || return 1

    [[ -f /etc/sysconfig/ip6tables ]] && return 0
    port_connlimit_systemd_unit_exists ip6tables
}

port_connlimit_persistence_backend() {
    if port_connlimit_command_path netfilter-persistent >/dev/null 2>&1; then
        printf '%s\n' "netfilter-persistent"
        return 0
    fi

    if port_connlimit_rhel_ipv4_persistence_available; then
        printf '%s\n' "rhel-iptables-services"
        return 0
    fi

    printf '%s\n' "none"
}

port_connlimit_saved_file_for_family() {
    local family="$1"
    local backend="${2:-$(port_connlimit_persistence_backend)}"

    case "$backend:$family" in
        netfilter-persistent:4) printf '%s\n' "/etc/iptables/rules.v4" ;;
        netfilter-persistent:6) printf '%s\n' "/etc/iptables/rules.v6" ;;
        rhel-iptables-services:4) printf '%s\n' "/etc/sysconfig/iptables" ;;
        rhel-iptables-services:6) printf '%s\n' "/etc/sysconfig/ip6tables" ;;
        *) return 1 ;;
    esac
}

port_connlimit_saved_rule_count_for_family() {
    local family="$1"
    local backend="${2:-$(port_connlimit_persistence_backend)}"
    local file

    file=$(port_connlimit_saved_file_for_family "$family" "$backend" 2>/dev/null) || {
        printf '0'
        return 0
    }
    port_connlimit_persisted_rule_count "$file"
}

port_connlimit_runtime_rule_fingerprints_for_family() {
    local family="$1"
    local cmd="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    "$cmd" -S INPUT 2>/dev/null | grep -F 'VPSO_CONN_LIMIT_PORT_' | sed "s/^/${family}:/" || true
}

port_connlimit_saved_rule_fingerprints_for_file() {
    local family="$1"
    local file="$2"

    [[ -f "$file" ]] || return 0
    grep -F 'VPSO_CONN_LIMIT_PORT_' "$file" 2>/dev/null | sed "s/^/${family}:/" || true
}

port_connlimit_runtime_rule_fingerprints() {
    {
        port_connlimit_runtime_rule_fingerprints_for_family "IPv4" iptables
        port_connlimit_runtime_rule_fingerprints_for_family "IPv6" ip6tables
    } | sort -u
}

port_connlimit_saved_rule_fingerprints_for_backend() {
    local backend="$1"
    local v4_file v6_file

    v4_file=$(port_connlimit_saved_file_for_family 4 "$backend" 2>/dev/null || true)
    v6_file=$(port_connlimit_saved_file_for_family 6 "$backend" 2>/dev/null || true)
    {
        [[ -n "$v4_file" ]] && port_connlimit_saved_rule_fingerprints_for_file "IPv4" "$v4_file"
        [[ -n "$v6_file" ]] && port_connlimit_saved_rule_fingerprints_for_file "IPv6" "$v6_file"
    } | sort -u
}

port_connlimit_known_saved_rule_fingerprints() {
    {
        port_connlimit_saved_rule_fingerprints_for_file "IPv4" /etc/iptables/rules.v4
        port_connlimit_saved_rule_fingerprints_for_file "IPv6" /etc/iptables/rules.v6
        port_connlimit_saved_rule_fingerprints_for_file "IPv4" /etc/sysconfig/iptables
        port_connlimit_saved_rule_fingerprints_for_file "IPv6" /etc/sysconfig/ip6tables
    } | sort -u
}

port_connlimit_fingerprint_count() {
    local data="$1"

    if [[ -z "$data" ]]; then
        printf '0'
    else
        printf '%s\n' "$data" | grep -c .
    fi
}

print_port_connlimit_health_summary() {
    local backend runtime_rules saved_rules known_saved_rules
    local runtime_count saved_count known_saved_count backend_label consistency risk

    backend=$(port_connlimit_persistence_backend)
    runtime_rules=$(port_connlimit_runtime_rule_fingerprints)
    saved_rules=$(port_connlimit_saved_rule_fingerprints_for_backend "$backend")
    known_saved_rules=$(port_connlimit_known_saved_rule_fingerprints)
    runtime_count=$(port_connlimit_fingerprint_count "$runtime_rules")
    saved_count=$(port_connlimit_fingerprint_count "$saved_rules")
    known_saved_count=$(port_connlimit_fingerprint_count "$known_saved_rules")

    case "$backend" in
        netfilter-persistent) backend_label="${GREEN}netfilter-persistent${PLAIN}" ;;
        rhel-iptables-services) backend_label="${GREEN}rhel-iptables-services${PLAIN}" ;;
        *) backend_label="${YELLOW}Не обнаружен доступный бэкенд${PLAIN}" ;;
    esac

    if [[ "$backend" == "none" ]]; then
        consistency="${YELLOW}Не обнаружен (нет доступного бэкенда)${PLAIN}"
    elif [[ "$runtime_rules" == "$saved_rules" ]]; then
        consistency="${GREEN}Согласовано${PLAIN}"
    else
        consistency="${YELLOW}Не согласовано${PLAIN}"
    fi

    if [[ "$backend" == "none" && "$runtime_count" -gt 0 ]]; then
        risk="${YELLOW}Есть: правила выполняются, но нет доступного бэкенда; после перезагрузки могут потеряться или восстановиться из старого снимка.${PLAIN}"
    elif [[ "$backend" == "none" && "$known_saved_count" -gt 0 ]]; then
        risk="${YELLOW}Есть: обнаружены сохранённые правила скрипта, но нет доступного бэкенда; поведение после перезагрузки требует проверки.${PLAIN}"
    elif [[ "$backend" != "none" && "$runtime_count" -gt 0 && "$saved_count" -eq 0 ]]; then
        risk="${YELLOW}Есть: правила в памяти, но ещё не сохранены в файл; после перезагрузки могут потеряться.${PLAIN}"
    elif [[ "$backend" != "none" && "$runtime_count" -eq 0 && "$saved_count" -gt 0 ]]; then
        risk="${YELLOW}Есть: в памяти нет правил скрипта, но в сохранённом файле есть старые метки; после перезагрузки могут восстановиться.${PLAIN}"
    elif [[ "$backend" != "none" && "$runtime_rules" != "$saved_rules" ]]; then
        risk="${YELLOW}Есть: правила в памяти и сохранённом файле различаются; рекомендуется повторно сохранить/проверить через [8] -> [5] -> [5].${PLAIN}"
    else
        risk="${GREEN}Риск потери/восстановления не обнаружен${PLAIN}"
    fi

    echo -e "${CYAN}🔒 Сводка по сохранению connlimit${PLAIN}"
    if [[ "$runtime_count" -gt 0 ]]; then
        echo -e "Статус правил скрипта   : [ ${GREEN}Присутствуют${PLAIN} ]   В памяти: ${CYAN}${runtime_count}${PLAIN} правил"
    else
        echo -e "Статус правил скрипта   : [ ${BLUE}Правила в памяти не обнаружены${PLAIN} ]"
    fi
    echo -e "Доступный бэкенд        : [ $backend_label ]"
    echo -e "Память/сохранённый файл  : [ $consistency ]   Сохранённых правил: ${CYAN}${saved_count}${PLAIN}"
    echo -e "Риск при перезагрузке   : [ $risk ]"
}

print_port_connlimit_persistence_unavailable() {
    echo -e "${YELLOW}⚠️ Не обнаружен надёжно вызываемый бэкенд для сохранения connlimit.${PLAIN}"
    if is_debian; then
        echo -e "${YELLOW}На Debian/Ubuntu можно установить и включить iptables-persistent / netfilter-persistent перед сохранением.${PLAIN}"
    elif is_redhat; then
        echo -e "${YELLOW}На RHEL/Rocky/Alma/CentOS Stream автоматическое сохранение работает только при обнаружении iptables-services (iptables.service или /etc/sysconfig/iptables).${PLAIN}"
    else
        echo -e "${YELLOW}Текущий дистрибутив не предоставляет проверяемый путь для сохранения iptables; используйте системные средства для сохранения вручную.${PLAIN}"
    fi
    echo -e "${YELLOW}Текущие правила connlimit действуют только до перезагрузки, после могут потеряться или восстановиться из старого снимка.${PLAIN}"
}

print_port_connlimit_persistence_status() {
    local v4_runtime v6_runtime v4_saved v6_saved backend
    local v4_file deb_v4_saved deb_v6_saved rhel_v4_saved rhel_v6_saved

    backend=$(port_connlimit_persistence_backend)
    v4_runtime=$(port_connlimit_runtime_rule_count iptables)
    v6_runtime=$(port_connlimit_runtime_rule_count ip6tables)
    v4_saved=$(port_connlimit_saved_rule_count_for_family 4 "$backend")
    v6_saved=$(port_connlimit_saved_rule_count_for_family 6 "$backend")
    deb_v4_saved=$(port_connlimit_persisted_rule_count /etc/iptables/rules.v4)
    deb_v6_saved=$(port_connlimit_persisted_rule_count /etc/iptables/rules.v6)
    rhel_v4_saved=$(port_connlimit_persisted_rule_count /etc/sysconfig/iptables)
    rhel_v6_saved=$(port_connlimit_persisted_rule_count /etc/sysconfig/ip6tables)
    v4_file=$(port_connlimit_saved_file_for_family 4 "$backend" 2>/dev/null || true)

    echo -e "${CYAN}Проверка сохранения:${PLAIN}"
    echo "  Правила в памяти: IPv4 ${v4_runtime} шт., IPv6 ${v6_runtime} шт."
    echo "  Файлы на Debian/Ubuntu: /etc/iptables/rules.v4 содержит ${deb_v4_saved} шт., /etc/iptables/rules.v6 содержит ${deb_v6_saved} шт."
    echo "  Файлы на RHEL: /etc/sysconfig/iptables содержит ${rhel_v4_saved} шт., /etc/sysconfig/ip6tables содержит ${rhel_v6_saved} шт."

    if [[ "$backend" == "netfilter-persistent" ]]; then
        echo -e "${GREEN}  Обнаружен netfilter-persistent; при добавлении/удалении connlimit скрипт автоматически попытается сохранить, также можно использовать [5] для проверки/сохранения.${PLAIN}"
    elif command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null | grep -q 'install ok installed'; then
        echo -e "${YELLOW}  Обнаружен пакет iptables-persistent, но команда netfilter-persistent не найдена; проверьте, что /usr/sbin в PATH.${PLAIN}"
    elif [[ "$backend" == "rhel-iptables-services" ]]; then
        echo -e "${GREEN}  Обнаружен существующий путь сохранения iptables-services на RHEL; при добавлении/удалении connlimit будет запись в ${v4_file:-/etc/sysconfig/iptables}.${PLAIN}"
        if ! port_connlimit_rhel_ipv6_persistence_available; then
            echo -e "${YELLOW}  Для IPv6 не обнаружен ip6tables.service или /etc/sysconfig/ip6tables; правила IPv6 connlimit могут действовать только до перезагрузки.${PLAIN}"
        fi
    else
        print_port_connlimit_persistence_unavailable
    fi

    if [[ "$backend" == "netfilter-persistent" ]] && command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files netfilter-persistent.service --no-legend 2>/dev/null | grep -q .; then
        local enabled active
        enabled=$(systemctl is-enabled netfilter-persistent 2>/dev/null || true)
        active=$(systemctl is-active netfilter-persistent 2>/dev/null || true)
        echo "  Служба восстановления при загрузке: netfilter-persistent enabled=${enabled:-unknown}, active=${active:-unknown}."
    fi
    if port_connlimit_systemd_unit_exists iptables; then
        local iptables_enabled iptables_active
        iptables_enabled=$(systemctl is-enabled iptables 2>/dev/null || true)
        iptables_active=$(systemctl is-active iptables 2>/dev/null || true)
        echo "  Служба восстановления при загрузке: iptables enabled=${iptables_enabled:-unknown}, active=${iptables_active:-unknown}."
    fi
    if port_connlimit_systemd_unit_exists ip6tables; then
        local ip6tables_enabled ip6tables_active
        ip6tables_enabled=$(systemctl is-enabled ip6tables 2>/dev/null || true)
        ip6tables_active=$(systemctl is-active ip6tables 2>/dev/null || true)
        echo "  Служба восстановления при загрузке: ip6tables enabled=${ip6tables_enabled:-unknown}, active=${ip6tables_active:-unknown}."
    fi

    if (( v4_runtime > 0 && v4_saved == 0 )) || (( v6_runtime > 0 && v6_saved == 0 )); then
        echo -e "${YELLOW}  Обнаружены правила connlimit в памяти, но они отсутствуют в доступном сохранённом файле; после перезагрузки могут потеряться.${PLAIN}"
    elif (( v4_runtime + v6_runtime == 0 && v4_saved + v6_saved > 0 )); then
        echo -e "${YELLOW}  В памяти нет правил скрипта, но в сохранённом файле есть старые метки; если не обновить снимок, после перезагрузки могут восстановиться.${PLAIN}"
    elif (( v4_runtime + v6_runtime > 0 )); then
        echo -e "${GREEN}  В доступном сохранённом файле обнаружены метки правил скрипта; восстановление при загрузке зависит от соответствующей службы.${PLAIN}"
    else
        echo -e "${BLUE}  В данный момент правил connlimit, добавленных скриптом, не обнаружено.${PLAIN}"
    fi
}

enable_port_connlimit_persistence_service() {
    local backend="${1:-$(port_connlimit_persistence_backend)}"

    if [[ "$backend" == "netfilter-persistent" ]] && command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files netfilter-persistent.service --no-legend 2>/dev/null | grep -q .; then
        if systemctl enable netfilter-persistent >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Включена служба восстановления netfilter-persistent при загрузке.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Не удалось включить netfilter-persistent; файл правил сохранён, но восстановление при загрузке нужно проверить вручную.${PLAIN}"
        fi
    fi
    if [[ "$backend" == "rhel-iptables-services" ]] && port_connlimit_systemd_unit_exists iptables; then
        if systemctl enable iptables >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Включена служба восстановления iptables при загрузке.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Не удалось включить iptables; файл правил IPv4 сохранён, но восстановление при загрузке нужно проверить вручную.${PLAIN}"
        fi
    fi
    if [[ "$backend" == "rhel-iptables-services" ]] && port_connlimit_systemd_unit_exists ip6tables; then
        if systemctl enable ip6tables >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Включена служба восстановления ip6tables при загрузке.${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Не удалось включить ip6tables; файл правил IPv6 сохранён, но восстановление при загрузке нужно проверить вручную.${PLAIN}"
        fi
    fi
}

save_rhel_port_connlimit_family() {
    local save_cmd="$1"
    local file="$2"
    local label="$3"
    local tmp_file err_file output

    tmp_file=$(mktemp /tmp/vps-connlimit-rules.XXXXXX) || return 1
    err_file=$(mktemp /tmp/vps-connlimit-save.XXXXXX) || {
        rm -f "$tmp_file"
        return 1
    }
    if "$save_cmd" > "$tmp_file" 2>"$err_file"; then
        output=$(<"$err_file")
        mkdir -p "$(dirname "$file")" || {
            rm -f "$tmp_file"
            rm -f "$err_file"
            echo -e "${RED}❌ Не удалось создать $(dirname "$file"), сохранение ${label} connlimit не удалось.${PLAIN}"
            return 1
        }
        if cp "$tmp_file" "$file"; then
            chmod 600 "$file" 2>/dev/null || true
            rm -f "$tmp_file"
            rm -f "$err_file"
            echo -e "${GREEN}✅ Записано в ${file}, снимок ${label} connlimit сохранён.${PLAIN}"
            return 0
        fi
        rm -f "$tmp_file"
        rm -f "$err_file"
        echo -e "${RED}❌ Ошибка записи в ${file}, правила ${label} connlimit могут действовать только до перезагрузки.${PLAIN}"
        return 1
    fi

    output=$(<"$err_file")
    rm -f "$tmp_file"
    rm -f "$err_file"
    echo -e "${RED}❌ ${save_cmd} не удался, сохранение ${label} connlimit не удалось: ${output}${PLAIN}"
    return 1
}

save_rhel_port_connlimit_persistence() {
    local rc=0
    local iptables_save ip6tables_save
    local v6_runtime v6_saved

    iptables_save=$(port_connlimit_command_path iptables-save 2>/dev/null || true)
    if [[ -z "$iptables_save" ]]; then
        echo -e "${RED}❌ iptables-save не обнаружен, невозможно записать файл сохранения IPv4 connlimit на RHEL.${PLAIN}"
        rc=1
    else
        save_rhel_port_connlimit_family "$iptables_save" "/etc/sysconfig/iptables" "IPv4" || rc=1
    fi

    v6_runtime=$(port_connlimit_runtime_rule_count ip6tables)
    v6_saved=$(port_connlimit_persisted_rule_count /etc/sysconfig/ip6tables)
    if port_connlimit_rhel_ipv6_persistence_available; then
        ip6tables_save=$(port_connlimit_command_path ip6tables-save 2>/dev/null || true)
        save_rhel_port_connlimit_family "$ip6tables_save" "/etc/sysconfig/ip6tables" "IPv6" || rc=1
    elif (( v6_runtime > 0 || v6_saved > 0 )); then
        echo -e "${YELLOW}⚠️ Не обнаружен путь сохранения IPv6 на RHEL; текущие правила connlimit IPv6 или старый снимок не могут быть надёжно сохранены скриптом.${PLAIN}"
        rc=1
    fi

    enable_port_connlimit_persistence_service "rhel-iptables-services"
    print_port_connlimit_persistence_status
    return "$rc"
}

save_port_connlimit_persistence() {
    local output backend
    local v4_runtime v6_runtime v4_saved v6_saved

    backend=$(port_connlimit_persistence_backend)
    if [[ "$backend" == "none" ]]; then
        print_port_connlimit_persistence_unavailable
        return 1
    fi

    if [[ "$backend" == "rhel-iptables-services" ]]; then
        save_rhel_port_connlimit_persistence
        return $?
    fi

    local netfilter_cmd
    netfilter_cmd=$(port_connlimit_command_path netfilter-persistent)
    if output=$("$netfilter_cmd" save 2>&1); then
        echo -e "${GREEN}✅ Выполнено netfilter-persistent save, текущий снимок iptables/ip6tables записан в файлы.${PLAIN}"
    else
        echo -e "${RED}❌ netfilter-persistent save не удался: ${output}${PLAIN}"
        echo -e "${YELLOW}В этот раз сохранение не выполнено; текущие правила connlimit могут действовать только до перезагрузки.${PLAIN}"
        return 1
    fi

    enable_port_connlimit_persistence_service "$backend"
    print_port_connlimit_persistence_status

    v4_runtime=$(port_connlimit_runtime_rule_count iptables)
    v6_runtime=$(port_connlimit_runtime_rule_count ip6tables)
    v4_saved=$(port_connlimit_saved_rule_count_for_family 4 "$backend")
    v6_saved=$(port_connlimit_saved_rule_count_for_family 6 "$backend")

    if (( v4_runtime > 0 && v4_saved == 0 )) || (( v6_runtime > 0 && v6_saved == 0 )); then
        echo -e "${RED}❌ После сохранения метки правил скрипта не обнаружены в сохранённом файле; не рассчитывайте на восстановление после перезагрузки.${PLAIN}"
        return 1
    fi

    return 0
}

auto_save_port_connlimit_persistence_after_change() {
    local action_label="$1"

    echo ""
    echo -e "${CYAN}Попытка автоматического сохранения снимка connlimit (после ${action_label})...${PLAIN}"
    if save_port_connlimit_persistence; then
        echo -e "${GREEN}✅ Снимок connlimit обновлён.${PLAIN}"
    else
        echo -e "${YELLOW}⚠️ Правила connlimit применены, но сохранение не подтверждено; после перезагрузки они могут не сохраниться.${PLAIN}"
        echo -e "${YELLOW}Восстановите возможности сохранения или сохраните вручную в соответствии с вашим дистрибутивом.${PLAIN}"
        return 1
    fi
}

func_save_port_connlimit_persistence() {
    print_port_connlimit_persistence_status
    echo ""
    confirm_risk_action "Сохранение снимка ограничений параллельных соединений" \
        "Сохраняет текущий снимок iptables/ip6tables с использованием обнаруженного бэкенда; на Debian/Ubuntu предпочтение netfilter-persistent, на RHEL — существующий iptables-services" \
        "При добавлении/удалении правил connlimit скрипт автоматически сохраняет; этот пункт для ручной проверки или повторной попытки" \
        "Операция не удаляет правила, не меняет настройки UFW/firewalld; обновляется только снимок дополнительных правил connlimit." || {
        echo -e "${BLUE}Сохранение снимка отменено.${PLAIN}"
        return 0
    }

    save_port_connlimit_persistence
}

port_connlimit_loopback_only_listener() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1

    ss -Htlpn 2>/dev/null | awk -v port="$port" '
        function is_target(addr) {
            return addr ~ (":" port "$") || addr ~ ("\\]:" port "$")
        }
        is_target($4) {
            if ($4 ~ /^(127\.0\.0\.1|localhost):/ || $4 ~ /^\[::1\]:/) {
                loopback = 1
            } else {
                public = 1
            }
        }
        END {
            exit (loopback && !public ? 0 : 1)
        }
    '
}

print_port_connlimit_scope_notice() {
    local port="$1"

    echo -e "${YELLOW}Пояснение: эта функция добавляет дополнительные правила iptables/ip6tables connlimit, которые не являются правилами разрешения портов UFW/firewalld.${PLAIN}"
    echo -e "${YELLOW}По умолчанию ограничивается количество одновременных TCP-соединений с каждого исходного IP-адреса, а не общее количество соединений.${PLAIN}"
    echo -e "${YELLOW}При добавлении/удалении автоматически обновляется снимок; если система не поддерживает сохранение, будет выдано предупреждение.${PLAIN}"

    if [[ "$port" == "443" ]]; then
        echo -e "${RED}⚠️ Предупреждение для 443: если включён единый вход 443/мультиплексирование порта, это ограничение действует на весь публичный порт 443.${PLAIN}"
        echo -e "${RED}Оно не может быть применено к конкретному входящему Xray/3x-ui, SNI, UUID или пользователю.${PLAIN}"
    fi

    if port_connlimit_loopback_only_listener "$port"; then
        echo -e "${YELLOW}⚠️ Обнаружено, что порт, возможно, слушает только 127.0.0.1/::1. Эта функция предназначена для ограничения публичных портов.${PLAIN}"
        echo -e "${YELLOW}Если ограничить локальный бэкенд-порт, это может ограничить только соединения от прокси к бэкенду, но не реальные источники из интернета.${PLAIN}"
    fi
}

port_connlimit_has_rule_for_port() {
    local cmd="$1"
    local port="$2"
    local comment
    comment=$(port_connlimit_comment "$port")

    "$cmd" -S INPUT 2>/dev/null | grep -Fq "$comment"
}

run_port_connlimit_rule_action() {
    local cmd="$1"
    local action="$2"
    local port="$3"
    local limit="$4"
    local mask="$5"
    local family_label="$6"
    local comment output
    comment=$(port_connlimit_comment "$port")

    local args=(
        -p tcp --dport "$port" --syn
        -m connlimit --connlimit-above "$limit" --connlimit-mask "$mask" --connlimit-saddr
        -m comment --comment "$comment"
        -j REJECT --reject-with tcp-reset
    )

    case "$action" in
        add)
            if "$cmd" -C INPUT "${args[@]}" >/dev/null 2>&1; then
                echo -e "${BLUE}ℹ️ ${family_label} уже существует правило: порт ${port}, более ${limit} новых соединений с одного IP будут отклонены.${PLAIN}"
                return 0
            fi
            if port_connlimit_has_rule_for_port "$cmd" "$port"; then
                echo -e "${YELLOW}⚠️ ${family_label} уже существует правило для этого порта с меткой скрипта. Добавление приведёт к наложению; для замены сначала удалите старое правило.${PLAIN}"
            fi
            if output=$("$cmd" -I INPUT "${args[@]}" 2>&1); then
                echo -e "${GREEN}✅ ${family_label} добавлено: порт ${port}, максимум ${limit} одновременных соединений с одного IP.${PLAIN}"
                return 0
            fi
            echo -e "${RED}❌ ${family_label} ошибка добавления: ${output}${PLAIN}"
            return 1
            ;;
        delete)
            if ! "$cmd" -C INPUT "${args[@]}" >/dev/null 2>&1; then
                echo -e "${YELLOW}⚠️ ${family_label} правило не найдено: порт ${port}, соединений ${limit}.${PLAIN}"
                return 1
            fi
            if output=$("$cmd" -D INPUT "${args[@]}" 2>&1); then
                echo -e "${GREEN}✅ ${family_label} удалено: порт ${port}, соединений ${limit}.${PLAIN}"
                return 0
            fi
            echo -e "${RED}❌ ${family_label} ошибка удаления: ${output}${PLAIN}"
            return 1
            ;;
        *)
            echo -e "${RED}❌ Неизвестная операция connlimit: ${action}${PLAIN}"
            return 1
            ;;
    esac
}

read_connlimit_port() {
    local __target="$1"
    local port

    read_trimmed port "Введите номер порта (1-65535, Enter или 0 для отмены): "
    if [[ -z "$port" || "$port" == "0" ]]; then
        echo -e "${BLUE}Операция ограничения порта отменена.${PLAIN}"
        return 1
    fi
    if ! is_valid_port "$port"; then
        echo -e "${RED}❌ Неверный порт, должен быть 1-65535.${PLAIN}"
        return 1
    fi

    printf -v "$__target" '%s' "$((10#$port))"
}

read_connlimit_limit() {
    local __target="$1"
    local limit

    read_trimmed limit "Введите максимальное количество одновременных TCP-соединений с одного IP (положительное целое, Enter или 0 для отмены): "
    if [[ -z "$limit" || "$limit" == "0" ]]; then
        echo -e "${BLUE}Операция ограничения порта отменена.${PLAIN}"
        return 1
    fi
    if ! is_valid_connlimit_value "$limit"; then
        echo -e "${RED}❌ Неверное значение, должно быть положительным целым.${PLAIN}"
        return 1
    fi

    printf -v "$__target" '%s' "$((10#$limit))"
}

func_add_port_connlimit_rule() {
    local port limit apply_ipv6 rc=0 touched=0

    read_connlimit_port port || return 0
    read_connlimit_limit limit || return 0
    read_trimmed apply_ipv6 "Применить также для IPv6? (y/n, по умолчанию n): "

    print_port_connlimit_scope_notice "$port"
    echo -e "${CYAN}Будет добавлено правило с меткой: $(port_connlimit_comment "$port")${PLAIN}"

    ensure_connlimit_tool iptables "IPv4" || return 1
    if is_yes "$apply_ipv6"; then
        ensure_connlimit_tool ip6tables "IPv6" || return 1
    fi
    try_load_connlimit_module

    confirm_risk_action "Добавить ограничение параллельных соединений для порта ${port}" \
        "Правило connlimit в цепочке INPUT iptables/ip6tables, новые TCP-соединения свыше ${limit} будут отклоняться" \
        "Удалите правило через этот же пункт меню по порту и лимиту; при необходимости очистите iptables через VNC/консоль" \
        "Это дополнительное ограничение, не является правилом разрешения UFW/firewalld." || {
        echo -e "${BLUE}Добавление ограничения отменено.${PLAIN}"
        return 0
    }

    if run_port_connlimit_rule_action iptables add "$port" "$limit" 32 "IPv4"; then
        touched=1
    else
        rc=1
    fi
    if is_yes "$apply_ipv6"; then
        if run_port_connlimit_rule_action ip6tables add "$port" "$limit" 128 "IPv6"; then
            touched=1
        else
            rc=1
        fi
    fi
    if [[ "$touched" -eq 1 ]]; then
        auto_save_port_connlimit_persistence_after_change "добавление правила" || true
    else
        echo -e "${YELLOW}Добавление не завершено полностью, автоматическое сохранение не выполнено; сначала исправьте ошибки выше.${PLAIN}"
    fi
    return "$rc"
}

func_delete_port_connlimit_rule() {
    local port limit delete_ipv6 rc=0

    read_connlimit_port port || return 0
    read_connlimit_limit limit || return 0
    read_trimmed delete_ipv6 "Удалить также соответствующее правило IPv6? (Y/n, по умолчанию yes): "

    print_port_connlimit_scope_notice "$port"
    echo -e "${CYAN}Будет удалено правило с меткой: $(port_connlimit_comment "$port")${PLAIN}"

    ensure_connlimit_tool iptables "IPv4" || return 1
    if ! is_no "$delete_ipv6"; then
        ensure_connlimit_tool ip6tables "IPv6" || return 1
    fi

    confirm_risk_action "Удалить ограничение параллельных соединений для порта ${port}" \
        "Удаляет только правило connlimit для порта ${port}, лимита ${limit}, с меткой $(port_connlimit_comment "$port")" \
        "Если удалено по ошибке, можно добавить заново через этот же пункт меню" \
        "Это не удаляет правила UFW/firewalld и не очищает iptables массово." || {
        echo -e "${BLUE}Удаление ограничения отменено.${PLAIN}"
        return 0
    }

    run_port_connlimit_rule_action iptables delete "$port" "$limit" 32 "IPv4" || rc=1
    if ! is_no "$delete_ipv6"; then
        run_port_connlimit_rule_action ip6tables delete "$port" "$limit" 128 "IPv6" || rc=1
    fi
    auto_save_port_connlimit_persistence_after_change "удаление правила" || true
    return "$rc"
}

func_show_port_connlimit_rules() {
    local found=0

    echo -e "${CYAN}Текущие правила ограничения параллельных соединений, добавленные VPS-Optimize:${PLAIN}"
    echo -e "${YELLOW}Метка: VPSO_CONN_LIMIT_PORT_<порт>${PLAIN}"
    echo ""

    if command -v iptables >/dev/null 2>&1; then
        echo -e "${BOLD}IPv4:${PLAIN}"
        if iptables -S INPUT 2>/dev/null | grep -F 'VPSO_CONN_LIMIT_PORT_'; then
            found=1
        else
            echo "  Правил IPv4 не обнаружено."
        fi
    else
        echo -e "${YELLOW}IPv4: iptables не обнаружен.${PLAIN}"
    fi

    echo ""
    if command -v ip6tables >/dev/null 2>&1; then
        echo -e "${BOLD}IPv6:${PLAIN}"
        if ip6tables -S INPUT 2>/dev/null | grep -F 'VPSO_CONN_LIMIT_PORT_'; then
            found=1
        else
            echo "  Правил IPv6 не обнаружено."
        fi
    else
        echo -e "${YELLOW}IPv6: ip6tables не обнаружен.${PLAIN}"
    fi

    echo ""
    if [[ "$found" -eq 0 ]]; then
        echo -e "${BLUE}В данный момент правил connlimit от скрипта не обнаружено.${PLAIN}"
    fi
    echo -e "${YELLOW}Эти правила ограничивают количество соединений, они не являются правилами разрешения портов UFW/firewalld.${PLAIN}"
    echo ""
    print_port_connlimit_persistence_status
}

func_show_port_current_connections() {
    local port rows

    read_connlimit_port port || return 0

    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ss не обнаружен, попытка установить iproute2/iproute...${PLAIN}"
        install_pkg iproute2 || install_pkg iproute || true
    fi
    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${RED}❌ ss не обнаружен, невозможно просмотреть текущие соединения.${PLAIN}"
        return 1
    fi

    print_port_connlimit_scope_notice "$port"
    echo -e "${CYAN}Порт ${port}: статистика установленных TCP-соединений по исходным IP:${PLAIN}"
    rows=$(ss -Htan state established 2>/dev/null | awk -v port="$port" '
        function is_local_port(endpoint) {
            return endpoint ~ (":" port "$") || endpoint ~ ("\\]:" port "$")
        }
        function remote_ip(endpoint) {
            if (endpoint ~ /^\[/) {
                sub(/^\[/, "", endpoint)
                sub(/\]:[0-9]+$/, "", endpoint)
                return endpoint
            }
            sub(/:[0-9]+$/, "", endpoint)
            return endpoint
        }
        is_local_port($4) {
            print remote_ip($5)
        }
    ' | sort | uniq -c | sort -nr)

    if [[ -z "$rows" ]]; then
        echo "  В данный момент установленных соединений нет."
    else
        printf '%s\n' "$rows" | awk '{count=$1; $1=""; sub(/^ /, ""); printf "  %-45s %s\n", $0, count}'
    fi
}

show_firewall_menu_help() {
    echo "Меню брандмауэра предназначено для разрешения, удаления, просмотра или отключения системного брандмауэра. Для удаления и отключения требуется ввод yes для подтверждения."
    echo "Автоматическое разрешение создаёт минимальный план, показывая протокол, адрес прослушивания, процесс и Docker-маппинг; петлевые адреса не разрешаются, текущий SSH-порт не может быть исключён."
    echo "План основан только на текущем публичном прослушивании и опубликованных портах Docker; необходимо проверить, нужны ли они для бизнеса; можно исключить необязательные правила по номеру."
    echo "Маппинг Docker может обходить обычные правила UFW/firewalld; исключение из плана не закрывает маппинг контейнеров, требуется также изменить адрес публикации Docker или использовать безопасность Docker."
    echo "Ручное добавление по умолчанию разрешает TCP; можно указать udp или both. Удаление проверяет TCP и UDP."
    echo "Ограничение параллельных соединений используется для ограничения TCP-коннектов с одного IP на публичном порте; IPv4 использует iptables connlimit, IPv6 — ip6tables connlimit."
    echo "Это дополнительное ограничение, не является правилом разрешения портов UFW/firewalld; они могут сосуществовать."
    echo "При добавлении/удалении connlimit автоматически обновляется снимок; пункт [5] позволяет проверить или сохранить вручную. При отсутствии поддержки будет предупреждение."
    echo "Если ограничивается публичный 443 и включён единый вход 443/мультиплексирование, ограничение применяется ко всему публичному 443 и не может быть точным для конкретного входящего, SNI, UUID или пользователя."
}

func_port_connlimit_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Управление брандмауэром > Ограничение параллельных соединений"
        echo -e "${BOLD}Ограничение параллельных соединений на порт${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${YELLOW}Назначение: ограничить количество одновременных TCP-соединений с одного IP на публичном порте.${PLAIN}"
        echo -e "${YELLOW}Пояснение: это дополнительные правила connlimit, не являющиеся правилами разрешения UFW/firewalld.${PLAIN}"
        echo -e "${YELLOW}Сохранение: при добавлении/удалении автоматически обновляется; [5] для ручной проверки/повторной попытки.${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Добавить ограничение параллельных соединений для порта${PLAIN}"
        echo -e "${GREEN}  2. Удалить ограничение параллельных соединений для порта${PLAIN}"
        echo -e "${GREEN}  3. Просмотреть текущие правила ограничения${PLAIN}"
        echo -e "${GREEN}  4. Просмотреть текущие соединения для порта${PLAIN}"
        echo -e "${GREEN}  5. Сохранить/проверить сохранение при перезагрузке${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  0. Вернуться на уровень выше${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local connlimit_choice
        read_trimmed connlimit_choice "👉 Выберите действие: "
        case "$connlimit_choice" in
            1) func_add_port_connlimit_rule; pause_return ;;
            2) func_delete_port_connlimit_rule; pause_return ;;
            3) func_show_port_connlimit_rules; pause_return ;;
            4) func_show_port_current_connections; pause_return ;;
            5) func_save_port_connlimit_persistence; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}

firewall_detect_public_listener_rules() {
    firewall_collect_public_listener_details | awk -F'|' '
        NF >= 2 {
            print $1 "/" $2
        }
    ' | sort -t/ -k1,1n -k2,2 -u
}

firewall_collect_public_listener_details() {
    ss -H -lntup 2>/dev/null | awk '
        $1 ~ /^(tcp|udp)/ {
            proto = ($1 ~ /^tcp/) ? "tcp" : "udp"
            endpoint = $5
            port = endpoint
            sub(/^.*:/, "", port)
            address = endpoint
            sub(/:[0-9]+$/, "", address)
            normalized = tolower(address)
            gsub(/^\[|\]$/, "", normalized)
            sub(/%.*/, "", normalized)
            if (normalized == "localhost" ||
                normalized ~ /^127\./ ||
                normalized == "::1" ||
                normalized ~ /^::ffff:127\./) {
                next
            }
            process = "-"
            details = ""
            for (i = 7; i <= NF; i++) {
                details = details (details ? " " : "") $i
            }
            if (match(details, /users:\(\("[^"]+"/)) {
                process = substr(details, RSTART, RLENGTH)
                sub(/^users:\(\("/, "", process)
                sub(/".*$/, "", process)
            }
            if (port ~ /^[0-9]+$/ && port >= 1 && port <= 65535) {
                print port "|" proto "|" address "|" process "|Системный слушатель|"
            }
        }
    '
}

firewall_is_loopback_address() {
    local address
    address=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    address="${address#[}"
    address="${address%]}"
    address="${address%%%*}"
    [[ "$address" == "localhost" || "$address" == 127.* || "$address" == "::1" || "$address" == ::ffff:127.* ]]
}

firewall_collect_docker_listener_details() {
    command -v docker >/dev/null 2>&1 || return 0

    local container line container_port protocol binding host_address host_port
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        while IFS= read -r line; do
            if [[ "$line" =~ ^([0-9]+)/(tcp|udp)[[:space:]]+-\>[[:space:]]+(.+):([0-9]+)$ ]]; then
                container_port="${BASH_REMATCH[1]}"
                protocol="${BASH_REMATCH[2]}"
                host_address="${BASH_REMATCH[3]}"
                host_port="${BASH_REMATCH[4]}"
                if ! firewall_is_loopback_address "$host_address" && is_valid_port "$host_port"; then
                    binding="${host_port} -> ${container_port}/${protocol}"
                    printf '%s|%s|%s|docker:%s|Docker|%s\n' \
                        "$host_port" "$protocol" "$host_address" "$container" "$binding"
                fi
            fi
        done < <(docker port "$container" 2>/dev/null || true)
    done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
}

firewall_add_unique_plan_value() {
    local current="$1"
    local value="$2"
    local item
    local -a current_items=()
    [[ -n "$value" && "$value" != "-" ]] || {
        printf '%s\n' "$current"
        return 0
    }
    IFS=';' read -ra current_items <<< "$current"
    for item in "${current_items[@]}"; do
        if [[ "$item" == "$value" ]]; then
            printf '%s\n' "$current"
            return 0
        fi
    done
    if [[ -n "$current" ]]; then
        printf '%s;%s\n' "$current" "$value"
    else
        printf '%s\n' "$value"
    fi
}

firewall_detect_ssh_port() {
    local ssh_port=""
    local -a ssh_connection_parts=()
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -ra ssh_connection_parts <<< "$SSH_CONNECTION"
        ssh_port="${ssh_connection_parts[3]:-}"
        is_valid_port "$ssh_port" || ssh_port=""
    fi
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(ss -H -tlnp 2>/dev/null | awk '
            /users:\(\("sshd"/ {
                port = $5
                sub(/^.*:/, "", port)
                if (port ~ /^[0-9]+$/) {
                    print port
                    exit
                }
            }
        ' || true)
    fi
    [[ -n "$ssh_port" ]] || ssh_port=$(awk 'tolower($1) == "port" { print $2; exit }' /etc/ssh/sshd_config 2>/dev/null || true)
    ssh_port="${ssh_port:-22}"
    is_valid_port "$ssh_port" || ssh_port=22
    printf '%s\n' "$ssh_port"
}

firewall_build_minimum_plan() {
    local ssh_port="${1:-}"
    local port protocol address process source mapping key
    local -A addresses=()
    local -A processes=()
    local -A sources=()
    local -A mappings=()
    local -A protected=()
    local -A seen=()
    local -a keys=()

    while IFS='|' read -r port protocol address process source mapping; do
        [[ -n "$port" && -n "$protocol" ]] || continue
        key="${port}/${protocol}"
        if [[ -z "${seen[$key]:-}" ]]; then
            keys+=("$key")
            seen["$key"]=1
            protected["$key"]="no"
        fi
        addresses["$key"]=$(firewall_add_unique_plan_value "${addresses[$key]:-}" "$address")
        processes["$key"]=$(firewall_add_unique_plan_value "${processes[$key]:-}" "$process")
        sources["$key"]=$(firewall_add_unique_plan_value "${sources[$key]:-}" "$source")
        mappings["$key"]=$(firewall_add_unique_plan_value "${mappings[$key]:-}" "$mapping")
    done < <(
        firewall_collect_public_listener_details
        firewall_collect_docker_listener_details
    )

    [[ -n "$ssh_port" ]] || ssh_port=$(firewall_detect_ssh_port 2>/dev/null || true)
    if is_valid_port "$ssh_port"; then
        key="${ssh_port}/tcp"
        if [[ -z "${seen[$key]:-}" ]]; then
            keys+=("$key")
            seen["$key"]=1
            addresses["$key"]="Защищено SSH конфигурацией"
        fi
        processes["$key"]=$(firewall_add_unique_plan_value "${processes[$key]:-}" "sshd")
        sources["$key"]=$(firewall_add_unique_plan_value "${sources[$key]:-}" "Защита SSH")
        protected["$key"]="yes"
    fi

    for key in "${keys[@]}"; do
        port="${key%/*}"
        protocol="${key#*/}"
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$port" "$protocol" "${addresses[$key]:--}" "${processes[$key]:--}" \
            "${sources[$key]:--}" "${mappings[$key]:--}" "${protected[$key]:-no}"
    done | sort -t'|' -k1,1n -k2,2
}

firewall_print_minimum_plan() {
    local plan="$1"
    local index=0 port protocol address process source mapping protected
    echo -e "${CYAN}👇 Минимальный план брандмауэра:${PLAIN}"
    while IFS='|' read -r port protocol address process source mapping protected; do
        [[ -n "$port" ]] || continue
        index=$((index + 1))
        printf '  [%d] %s/%s\n' "$index" "$port" "$protocol"
        printf '      Адрес прослушивания: %s\n' "${address:--}"
        printf '      Процесс: %s\n' "${process:--}"
        printf '      Источник: %s\n' "${source:--}"
        printf '      Docker маппинг: %s\n' "${mapping:--}"
        if [[ "$protected" == "yes" ]]; then
            echo "      Защищено: текущий SSH-порт, не может быть исключён"
        fi
    done <<< "$plan"
}

firewall_select_minimum_plan_rules() {
    local plan="$1"
    local exclusions="${2:-}"
    local count index item item_number port protocol address process source mapping protected
    local -A excluded=()
    local -a exclusion_items=()

    exclusions="${exclusions//[[:space:]]/}"
    count=$(grep -c '^[0-9]' <<< "$plan" || true)
    if [[ -n "$exclusions" ]]; then
        [[ "$exclusions" =~ ^[0-9]+(,[0-9]+)*$ ]] || {
            echo "Неверный формат номеров для исключения, используйте запятые, например 2,4." >&2
            return 1
        }
        IFS=',' read -ra exclusion_items <<< "$exclusions"
        for item in "${exclusion_items[@]}"; do
            item_number=$((10#$item))
            if (( item_number < 1 || item_number > count )); then
                echo "Номер ${item} вне диапазона плана." >&2
                return 1
            fi
            excluded["$item_number"]=1
        done
    fi

    index=0
    while IFS='|' read -r port protocol address process source mapping protected; do
        [[ -n "$port" ]] || continue
        index=$((index + 1))
        if [[ -n "${excluded[$index]:-}" && "$protected" == "yes" ]]; then
            echo "Номер ${index} — текущий SSH-порт, оставлен принудительно." >&2
        elif [[ -n "${excluded[$index]:-}" ]]; then
            continue
        fi
        printf '%s/%s\n' "$port" "$protocol"
    done <<< "$plan"
}

normalize_firewall_protocol() {
    local protocol
    protocol=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$protocol" in
        tcp|udp|both) printf '%s\n' "$protocol" ;;
        *) return 1 ;;
    esac
}

firewall_apply_port_rule() {
    local action="$1"
    local port_rule="$2"
    local protocol="$3"
    local output command_rc

    if [[ "$OS" =~ debian|ubuntu ]]; then
        port_rule="${port_rule//-/:}"
        if [[ "$action" == "add" ]]; then
            output=$(ufw allow "${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        else
            output=$(ufw delete allow "${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        fi
    else
        port_rule="${port_rule//:/-}"
        if [[ "${VPSO_FIREWALLD_OFFLINE_MODE:-0}" == "1" && "$action" == "add" ]]; then
            output=$(firewall-offline-cmd --add-port="${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        elif [[ "$action" == "add" ]]; then
            output=$(firewall-cmd --permanent --add-port="${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        else
            output=$(firewall-cmd --permanent --remove-port="${port_rule}/${protocol}" 2>&1)
            command_rc=$?
        fi
    fi
    if [[ "$command_rc" -ne 0 ]]; then
        echo -e "${RED}❌ ${action} ${port_rule}/${protocol} не удалось: ${output:-неизвестная ошибка}${PLAIN}"
        return 1
    fi
}

firewall_apply_port_input() {
    local action="$1"
    local port_input="$2"
    local protocol="$3"
    local rc=0 port_rule current_protocol
    local protocols=()
    local port_rules=()

    if [[ "$protocol" == "both" ]]; then
        protocols=(tcp udp)
    else
        protocols=("$protocol")
    fi
    IFS=',' read -ra port_rules <<< "$port_input"
    for port_rule in "${port_rules[@]}"; do
        if [[ "$action" == "delete" && "$protocol" == "both" && "$OS" =~ debian|ubuntu ]]; then
            local legacy_port_rule="${port_rule//-/:}"
            if ufw delete allow "$legacy_port_rule" >/dev/null 2>&1; then
                continue
            fi
        fi
        for current_protocol in "${protocols[@]}"; do
            firewall_apply_port_rule "$action" "$port_rule" "$current_protocol" || rc=1
        done
    done
    return "$rc"
}

func_firewall_manage() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Управление брандмауэром"
        echo -e "${BOLD}🛡️ Управление правилами брандмауэра${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local fw_status
        local str_fw
        if [[ "$OS" =~ debian|ubuntu ]]; then
            fw_status=$(ufw status 2>/dev/null | grep -wi active)
        else
            fw_status=$(systemctl is-active firewalld 2>/dev/null)
        fi

        if [[ "$fw_status" == *"active"* ]]; then
            str_fw="${GREEN}Активен${PLAIN}"
        else
            str_fw="${RED}Отключён / не настроен${PLAIN}"
        fi

        echo -e "Текущий статус брандмауэра: [ $str_fw ]"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Просмотр списка разрешённых правил${PLAIN}"
        echo -e "${GREEN}  2. Включить брандмауэр и применить минимальный план${PLAIN} ${YELLOW}(можно просмотреть/исключить, не перезаписывает существующие правила)${PLAIN}"
        echo -e "${GREEN}  3. Разрешить порт вручную${PLAIN} ${YELLOW}(TCP/UDP, пакетно/диапазон)${PLAIN}"
        echo -e "${GREEN}  4. Удалить разрешённый порт${PLAIN} ${YELLOW}(TCP/UDP, пакетно/диапазон)${PLAIN}"
        echo -e "${GREEN}  5. Ограничение параллельных соединений на порт${PLAIN} ${YELLOW}(по IP)${PLAIN}"
        echo -e "${RED}  6. Отключить брандмауэр${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${BLUE}  0. Вернуться в предыдущее меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local fw_choice
        read_trimmed fw_choice "👉 Выберите действие: "

        case $fw_choice in
            1)
                echo -e "${CYAN}👇 Список текущих правил брандмауэра:${PLAIN}"
                if [[ "$OS" =~ debian|ubuntu ]]; then
                    ufw status numbered
                else
                    firewall-cmd --list-ports
                fi
                read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                ;;
            2)
                echo -e "${CYAN}👉 Проверка публичных слушателей, процессов и опубликованных портов Docker...${PLAIN}"
                local firewall_plan active_rules exclusions selection_cancelled
                firewall_plan=$(firewall_build_minimum_plan)

                if [[ -z "$firewall_plan" ]]; then
                    echo -e "${RED}❌ Не удалось определить порты для разрешения, включение отменено во избежание блокировки SSH.${PLAIN}"
                    echo -e "${YELLOW}Убедитесь, что ss/iproute2 доступны, или используйте [3] для ручного добавления SSH-порта.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi
                firewall_print_minimum_plan "$firewall_plan"
                echo -e "${YELLOW}План основан на текущем публичном прослушивании и Docker-маппинге; вы должны проверить, нужны ли они для бизнеса.${PLAIN}"
                if grep -Fq '|Docker|' <<< "$firewall_plan"; then
                    echo -e "${RED}⚠️ Маппинг Docker может обходить обычные правила UFW/firewalld; исключение из плана не закрывает маппинг контейнеров.${PLAIN}"
                    echo -e "${YELLOW}Для ограничения также измените адрес публикации Docker или используйте [11 Docker безопасность].${PLAIN}"
                fi

                selection_cancelled=0
                while true; do
                    read_trimmed exclusions "👉 Введите номера для исключения (через запятую, Enter для сохранения всех, q отмена): "
                    if [[ "$exclusions" =~ ^[qQ]$ ]]; then
                        selection_cancelled=1
                        break
                    fi
                    if active_rules=$(firewall_select_minimum_plan_rules "$firewall_plan" "$exclusions"); then
                        break
                    fi
                done
                if [[ "$selection_cancelled" -eq 1 ]]; then
                    echo -e "${BLUE}Включение брандмауэра отменено.${PLAIN}"
                    sleep 1
                    continue
                fi
                echo -e "${CYAN}Будут разрешены: $(echo "$active_rules" | tr '\n' ' ')${PLAIN}"
                confirm_risk_action "Включить брандмауэр и применить минимальный план разрешений" \
                    "Политика по умолчанию для входящих соединений и выбранные правила TCP/UDP" \
                    "Сохраните текущую SSH-сессию, используйте консоль провайдера/VNC для отключения брандмауэра или восстановления бизнес-портов" \
                    "Убедитесь, что план покрывает текущий SSH и все необходимые публичные службы." || {
                    echo -e "${BLUE}Включение брандмауэра отменено.${PLAIN}"
                    sleep 1
                    continue
                }

                local firewall_rc=0 rule_entry rule_port rule_protocol
                local firewalld_was_inactive=0
                if [[ "$OS" =~ debian|ubuntu ]]; then
                    if ! install_pkg ufw || ! command -v ufw >/dev/null 2>&1; then
                        echo -e "${RED}❌ Не удалось установить UFW, брандмауэр не включён.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    ufw default deny incoming >/dev/null 2>&1 || firewall_rc=1
                    ufw default allow outgoing >/dev/null 2>&1 || firewall_rc=1
                else
                    if ! install_pkg firewalld || ! command -v firewall-cmd >/dev/null 2>&1; then
                        echo -e "${RED}❌ Не удалось установить firewalld, брандмауэр не включён.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    if ! systemctl is-active --quiet firewalld; then
                        if ! command -v firewall-offline-cmd >/dev/null 2>&1; then
                            echo -e "${RED}❌ Отсутствует firewall-offline-cmd, невозможно безопасно добавить SSH-порт до запуска firewalld.${PLAIN}"
                            sleep 2
                            continue
                        fi
                        firewalld_was_inactive=1
                        VPSO_FIREWALLD_OFFLINE_MODE=1
                    fi
                fi
                while IFS= read -r rule_entry; do
                    [[ -n "$rule_entry" ]] || continue
                    rule_port="${rule_entry%/*}"
                    rule_protocol="${rule_entry#*/}"
                    firewall_apply_port_rule add "$rule_port" "$rule_protocol" || firewall_rc=1
                done <<< "$active_rules"
                unset VPSO_FIREWALLD_OFFLINE_MODE

                if [[ "$OS" =~ debian|ubuntu ]]; then
                    if [[ "$firewall_rc" -eq 0 ]]; then
                        ufw --force enable >/dev/null 2>&1 || firewall_rc=1
                        ufw status 2>/dev/null | grep -qi active || firewall_rc=1
                    fi
                elif [[ "$firewall_rc" -eq 0 ]]; then
                    if [[ "$firewalld_was_inactive" -eq 1 ]]; then
                        systemctl enable --now firewalld >/dev/null 2>&1 || firewall_rc=1
                        systemctl is-active --quiet firewalld || firewall_rc=1
                    else
                        firewall-cmd --reload >/dev/null 2>&1 || firewall_rc=1
                    fi
                fi

                if [[ "$firewall_rc" -ne 0 ]]; then
                    echo -e "${RED}❌ Конфигурация брандмауэра не завершена полностью, исправьте ошибки выше.${PLAIN}"
                    echo -e "${YELLOW}План разрешений: $(echo "$active_rules" | tr '\n' ' ')${PLAIN}"
                    sleep 3
                    continue
                fi
                echo -e "${GREEN}✅ Брандмауэр включён, разрешены: $(echo "$active_rules" | tr '\n' ' ')${PLAIN}"
                sleep 2
                ;;
            3)
                local add_p add_protocol
                echo -e "${YELLOW}💡 Форматы: одиночный порт(80), несколько портов(80,443), диапазон(8000:9000 или 8000-9000)${PLAIN}"
                read_trimmed add_p "👉 Введите порт для разрешения: "
                add_p=$(normalize_port_rule_input "$add_p")
                if [[ -z "$add_p" || "$add_p" == "0" ]]; then
                    echo -e "${BLUE}Добавление правила отменено.${PLAIN}"
                    sleep 1
                    continue
                fi

                if is_valid_port_rule_input "$add_p"; then
                    if [[ "$OS" =~ debian|ubuntu ]]; then
                        install_pkg ufw
                        if ! command -v ufw >/dev/null 2>&1; then
                            echo -e "${RED}❌ ufw не обнаружен, невозможно записать правило.${PLAIN}"
                            sleep 2
                            continue
                        fi
                        if ! ufw status 2>/dev/null | grep -qi active; then
                            echo -e "${YELLOW}⚠️ UFW в данный момент не активен, правило будет добавлено, но для применения требуется включить UFW через [1].${PLAIN}"
                        fi
                    elif ! systemctl is-active --quiet firewalld 2>/dev/null; then
                        echo -e "${RED}❌ Firewalld не запущен. Во избежание блокировки порта сначала используйте [2] для включения и автоматического разрешения активных портов.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    read_trimmed add_protocol "👉 Выберите протокол tcp/udp/both (по умолчанию tcp): "
                    add_protocol=$(normalize_firewall_protocol "${add_protocol:-tcp}" 2>/dev/null || true)
                    if [[ -z "$add_protocol" ]]; then
                        echo -e "${RED}❌ Протокол должен быть tcp, udp или both.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    if firewall_apply_port_input add "$add_p" "$add_protocol" \
                        && { [[ "$OS" =~ debian|ubuntu ]] || firewall-cmd --reload >/dev/null 2>&1; }; then
                        echo -e "${GREEN}✅ Правило [${add_p}/${add_protocol}] добавлено.${PLAIN}"
                    else
                        echo -e "${RED}❌ Правило [${add_p}/${add_protocol}] не добавлено полностью, проверьте ошибки.${PLAIN}"
                    fi
                else
                    echo -e "${RED}❌ Неверный формат порта!${PLAIN}"
                fi
                sleep 2
                ;;
            4)
                local del_p del_protocol
                echo -e "${YELLOW}💡 Форматы: одиночный порт(80), несколько портов(80,443), диапазон(8000:9000 или 8000-9000)${PLAIN}"
                read_trimmed del_p "👉 Введите порт для удаления: "
                del_p=$(normalize_port_rule_input "$del_p")
                if [[ -z "$del_p" || "$del_p" == "0" ]]; then
                    echo -e "${BLUE}Удаление правила отменено.${PLAIN}"
                    sleep 1
                    continue
                fi

                if is_valid_port_rule_input "$del_p"; then
                    confirm_risk_action "Удалить правило разрешения порта ${del_p}" \
                        "Правило разрешения порта в системном брандмауэре" \
                        "Вернитесь в меню брандмауэра и разрешите порт вручную, или восстановите через консоль провайдера/VNC" \
                        "Убедитесь, что не удаляете текущий SSH-порт или бизнес-порт." || {
                        echo -e "${BLUE}Удаление правила отменено.${PLAIN}"
                        sleep 1
                        continue
                    }
                    if [[ "$OS" =~ debian|ubuntu ]]; then
                        install_pkg ufw
                        if ! command -v ufw >/dev/null 2>&1; then
                            echo -e "${RED}❌ ufw не обнаружен, невозможно удалить правило.${PLAIN}"
                            sleep 2
                            continue
                        fi
                    elif ! systemctl is-active --quiet firewalld 2>/dev/null; then
                        echo -e "${RED}❌ Firewalld не запущен, невозможно удалить правила.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    read_trimmed del_protocol "👉 Выберите протокол tcp/udp/both (по умолчанию both): "
                    del_protocol=$(normalize_firewall_protocol "${del_protocol:-both}" 2>/dev/null || true)
                    if [[ -z "$del_protocol" ]]; then
                        echo -e "${RED}❌ Протокол должен быть tcp, udp или both.${PLAIN}"
                        sleep 2
                        continue
                    fi
                    if firewall_apply_port_input delete "$del_p" "$del_protocol" \
                        && { [[ "$OS" =~ debian|ubuntu ]] || firewall-cmd --reload >/dev/null 2>&1; }; then
                        echo -e "${GREEN}✅ Правило [${del_p}/${del_protocol}] удалено.${PLAIN}"
                    else
                        echo -e "${RED}❌ Правило [${del_p}/${del_protocol}] не удалено полностью, проверьте ошибки.${PLAIN}"
                    fi
                else
                    echo -e "${RED}❌ Неверный формат порта!${PLAIN}"
                fi
                sleep 2
                ;;
            5) func_port_connlimit_menu ;;
            6)
                confirm_risk_action "Отключить системный брандмауэр" \
                    "Служба ufw/firewalld и контроль доступа" \
                    "Включите брандмауэр повторно и восстановите правила; при необходимости ограничьте доступ через безопасную группу провайдера" \
                    "Убедитесь, что после отключения не будут открыты базы данных, панели или внутренние службы." || {
                    echo -e "${BLUE}Отключение брандмауэра отменено.${PLAIN}"
                    sleep 1
                    continue
                }
                echo -e "${RED}⚠️ Отключение брандмауэра...${PLAIN}"
                if [[ "$OS" =~ debian|ubuntu ]]; then
                    if ufw disable >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi inactive; then
                        echo -e "${GREEN}✅ Брандмауэр отключён.${PLAIN}"
                    else
                        echo -e "${RED}❌ Не удалось отключить UFW или статус active.${PLAIN}"
                    fi
                else
                    if systemctl disable --now firewalld >/dev/null 2>&1 && ! systemctl is-active --quiet firewalld; then
                        echo -e "${GREEN}✅ Брандмауэр отключён.${PLAIN}"
                    else
                        echo -e "${RED}❌ Не удалось отключить firewalld или служба всё ещё работает.${PLAIN}"
                    fi
                fi
                sleep 2
                ;;
            "?"|help) show_firewall_menu_help; pause_return ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1 ;;
        esac
    done
}
