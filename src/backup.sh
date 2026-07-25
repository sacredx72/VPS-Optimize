# shellcheck shell=bash
# Вспомогательные функции резервного копирования и точка входа в центр резервного копирования.

sni_stack_backup_dir() {
    echo "/etc/vps-optimize/backups/sni-stack_$(date +%Y%m%d_%H%M%S)"
}

create_sni_stack_backup() {
    local backup_dir
    backup_dir="${1:-$(sni_stack_backup_dir)}"
    mkdir -p "$backup_dir/nginx_stream.d" "$backup_dir/nginx_conf.d" "$backup_dir/caddy_conf.d" "$backup_dir/vps-optimize" "$backup_dir/systemd" "$backup_dir/usr-local-bin" "$backup_dir/x-ui"
    [[ -f /etc/nginx/nginx.conf ]] && cp -a /etc/nginx/nginx.conf "$backup_dir/nginx.conf" 2>/dev/null || true
    [[ -d /etc/nginx/stream.d ]] && cp -a /etc/nginx/stream.d/vps_sni_*.conf "$backup_dir/nginx_stream.d/" 2>/dev/null || true
    [[ -d /etc/nginx/conf.d ]] && cp -a /etc/nginx/conf.d/vps_sni_web_*.conf "$backup_dir/nginx_conf.d/" 2>/dev/null || true
    [[ -d /etc/nginx/conf.d ]] && cp -a /etc/nginx/conf.d/vps_proxy_*.conf "$backup_dir/nginx_conf.d/" 2>/dev/null || true
    [[ -f /etc/nginx/conf.d/00-vps-proxy-map.conf ]] && cp -a /etc/nginx/conf.d/00-vps-proxy-map.conf "$backup_dir/nginx_conf.d/" 2>/dev/null || true
    [[ -f /etc/caddy/Caddyfile ]] && cp -a /etc/caddy/Caddyfile "$backup_dir/Caddyfile" 2>/dev/null || true
    [[ -d /etc/caddy/conf.d ]] && cp -a /etc/caddy/conf.d/*.caddy "$backup_dir/caddy_conf.d/" 2>/dev/null || true
    [[ -f /etc/vps-optimize/sni-stack.env ]] && cp -a /etc/vps-optimize/sni-stack.env "$backup_dir/vps-optimize/sni-stack.env" 2>/dev/null || true
    [[ -f /etc/vps-optimize/xray-sni-routes.conf ]] && cp -a /etc/vps-optimize/xray-sni-routes.conf "$backup_dir/vps-optimize/xray-sni-routes.conf" 2>/dev/null || true
    [[ -f /etc/vps-optimize/443-engine.conf ]] && cp -a /etc/vps-optimize/443-engine.conf "$backup_dir/vps-optimize/443-engine.conf" 2>/dev/null || true
    [[ -f /etc/vps-optimize/vpso-mux.yaml ]] && cp -a /etc/vps-optimize/vpso-mux.yaml "$backup_dir/vps-optimize/vpso-mux.yaml" 2>/dev/null || true
    [[ -f /etc/systemd/system/vpso-mux.service ]] && cp -a /etc/systemd/system/vpso-mux.service "$backup_dir/systemd/vpso-mux.service" 2>/dev/null || true
    [[ -f /usr/local/bin/vpso-mux ]] && cp -a /usr/local/bin/vpso-mux "$backup_dir/usr-local-bin/vpso-mux" 2>/dev/null || true
    [[ -d /etc/x-ui ]] && cp -a /etc/x-ui "$backup_dir/x-ui/etc-x-ui" 2>/dev/null || true
    [[ -f /usr/local/x-ui/bin/config.json ]] && cp -a /usr/local/x-ui/bin/config.json "$backup_dir/x-ui/config.json" 2>/dev/null || true
    echo "$backup_dir" > /etc/vps-optimize/sni-stack.last-backup 2>/dev/null || true
    echo -e "${GREEN}✅ Создана резервная копия конфигурации: ${backup_dir}${PLAIN}"
}

make_secure_temp_dir() {
    local prefix="$1"
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/${prefix}.XXXXXX") || return 1
    chmod 700 "$tmp_dir" 2>/dev/null || true
    printf '%s' "$tmp_dir"
}

backup_copy_path() {
    local src="$1"
    local dest_rel="$2"
    local manifest_file="$3"
    local work_dir="$4"
    local dest_dir

    [[ -e "$src" || -L "$src" ]] || return 1
    dest_dir=$(dirname "$dest_rel")
    mkdir -p "$work_dir/$dest_dir" || return 1

    if cp -a -- "$src" "$work_dir/$dest_rel" 2>/dev/null; then
        echo " - $src" >> "$manifest_file"
        return 0
    fi
    return 1
}

backup_copy_xui_databases() {
    local manifest_file="$1"
    local work_dir="$2"
    local copied=1
    local db suffix src
    local db_paths=(
        "/etc/x-ui/x-ui.db"
        "/usr/local/x-ui/x-ui.db"
        "/usr/local/x-ui/bin/x-ui.db"
    )

    for db in "${db_paths[@]}"; do
        for suffix in "" "-wal" "-shm"; do
            src="${db}${suffix}"
            if backup_copy_path "$src" "${src#/}" "$manifest_file" "$work_dir"; then
                copied=0
            fi
        done
    done
    return "$copied"
}

redact_sensitive_output() {
    sed -E \
        -e 's/(authorization:[[:space:]]*(bearer|basic)[[:space:]]+)[^[:space:]]+/\1***REDACTED***/gI' \
        -e 's/((^|[^[:alnum:]_])(token|password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|CF_Token|CF_Key)[[:space:]]*[=:][[:space:]]*)[^[:space:],;"'\''}]+/\1***REDACTED***/gI' \
        -e 's/("(token|password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|CF_Token|CF_Key)"[[:space:]]*:[[:space:]]*")[^"]+/\1***REDACTED***/gI' \
        -e 's/([?&](token|password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret)=)[^&[:space:]]+/\1***REDACTED***/gI' \
        -e 's#(https?://)[^/@[:space:]]+@#\1***REDACTED***@#g'
}

dns_backup_current_config() {
    local ts backup_dir
    ts=$(date +%Y%m%d_%H%M%S)
    backup_dir="${DNS_OPTIMIZE_BACKUP_DIR}/${ts}"
    mkdir -p "$backup_dir"
    chmod 700 "$DNS_OPTIMIZE_BACKUP_DIR" "$backup_dir" 2>/dev/null || true
    [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]] && cp -a /etc/resolv.conf "$backup_dir/resolv.conf" 2>/dev/null || true
    [[ -f "$DNS_OPTIMIZE_RESOLVED_DROPIN" ]] && cp -a "$DNS_OPTIMIZE_RESOLVED_DROPIN" "$backup_dir/99-vps-optimize-dns.conf" 2>/dev/null || true
    echo "$backup_dir" > "${DNS_OPTIMIZE_BACKUP_DIR}/last" 2>/dev/null || true
    echo "$backup_dir"
}

applied_config_editor_command() {
    local editor="${EDITOR:-}"
    if [[ -n "$editor" && "$editor" != *" "* ]] && command -v "$editor" >/dev/null 2>&1; then
        printf '%s' "$editor"
        return 0
    fi

    local candidate
    for candidate in nano vim vi; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

append_applied_config_file() {
    local label="$1"
    local path="$2"
    local kind="$3"
    local existing

    [[ -e "$path" || -L "$path" ]] || return 0
    for existing in "${applied_config_paths[@]}"; do
        [[ "$existing" == "$path" ]] && return 0
    done

    applied_config_labels+=("$label")
    applied_config_paths+=("$path")
    applied_config_kinds+=("$kind")
}

collect_applied_config_files() {
    local scope="${1:-all}"
    local conf_file

    applied_config_labels=()
    applied_config_paths=()
    applied_config_kinds=()

    append_applied_config_file "Основной конфиг Caddy" "/etc/caddy/Caddyfile" "caddy"
    for conf_file in /etc/caddy/conf.d/*.caddy; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Сайт Caddy $(basename "$conf_file")" "$conf_file" "caddy"
    done
    append_applied_config_file "Основной конфиг Nginx" "/etc/nginx/nginx.conf" "nginx"
    for conf_file in /etc/nginx/conf.d/*.conf; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Nginx conf.d $(basename "$conf_file")" "$conf_file" "nginx"
    done
    for conf_file in /etc/nginx/sites-enabled/*; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Nginx sites-enabled $(basename "$conf_file")" "$conf_file" "nginx"
    done

    [[ "$scope" == "proxy" ]] && return 0

    for conf_file in /etc/nginx/stream.d/*.conf; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Nginx stream.d $(basename "$conf_file")" "$conf_file" "nginx"
    done
    append_applied_config_file "Общие параметры 443" "/etc/vps-optimize/sni-stack.env" "entry-mode"
    append_applied_config_file "Состояние движка 443" "/etc/vps-optimize/443-engine.conf" "entry-mode"
    append_applied_config_file "Записи маршрутизации Xray SNI" "/etc/vps-optimize/xray-sni-routes.conf" "xray-routes"
    append_applied_config_file "Конфигурация TCP Peek vpso-mux" "/etc/vps-optimize/vpso-mux.yaml" "vpso-mux"
    append_applied_config_file "systemd vpso-mux" "/etc/systemd/system/vpso-mux.service" "systemd"
    append_applied_config_file "systemd предпроверки vpso-mux 8444" "/etc/systemd/system/vpso-mux-preflight.service" "systemd"
    append_applied_config_file "Конфигурация Traffic Guard" "$TRAFFIC_GUARD_CONFIG" "traffic-guard"
    append_applied_config_file "Служба Traffic Guard" "/etc/systemd/system/vps-traffic-guard.service" "systemd"
    append_applied_config_file "Таймер Traffic Guard" "/etc/systemd/system/vps-traffic-guard.timer" "systemd"
    append_applied_config_file "Конфигурация Cloudflare DNS API" "/root/.config/vps-panel/cloudflare.env" "env"
    append_applied_config_file "Docker daemon.json" "/etc/docker/daemon.json" "docker-json"
    append_applied_config_file "Основной конфиг SSH" "/etc/ssh/sshd_config" "ssh"
    for conf_file in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$conf_file" ]] && append_applied_config_file "SSH drop-in $(basename "$conf_file")" "$conf_file" "ssh"
    done
    append_applied_config_file "Файл hosts" "/etc/hosts" "hosts"
    append_applied_config_file "Файл hostname" "/etc/hostname" "hostname"
    append_applied_config_file "DNS resolv.conf" "/etc/resolv.conf" "dns"
    append_applied_config_file "systemd-resolved DNS drop-in" "$DNS_OPTIMIZE_RESOLVED_DROPIN" "dns"
    append_applied_config_file "Fail2ban jail.local" "/etc/fail2ban/jail.local" "fail2ban"
    append_applied_config_file "x-ui config.json" "/usr/local/x-ui/bin/config.json" "xui-json"
    for conf_file in /etc/sysctl.d/*.conf; do
        [[ -f "$conf_file" ]] && append_applied_config_file "sysctl.d $(basename "$conf_file")" "$conf_file" "sysctl"
    done
    for conf_file in /opt/sublinkpro/docker-compose.yml /opt/miaomiaowu/docker-compose.yml /opt/sub-store/docker-compose.yml /opt/dockge/docker-compose.yml /opt/komari/docker-compose.yml /opt/*/compose.yaml /opt/*/compose.yml /opt/*/docker-compose.yml /opt/*/docker-compose.yaml; do
        [[ -f "$conf_file" ]] && append_applied_config_file "Compose $(basename "$(dirname "$conf_file")")/$(basename "$conf_file")" "$conf_file" "compose"
    done
}

validate_xray_routes_file() {
    local target_file="$1"
    awk -F'|' '
        /^[[:space:]]*($|#)/ { next }
        { for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
        NF != 3 { exit 1 }
        $1 == "" || $2 == "" || $3 !~ /^[0-9]+$/ || $3 < 1 || $3 > 65535 { exit 1 }
    ' "$target_file"
}

validate_hosts_file() {
    local target_file="$1"
    awk '
        /^[[:space:]]*($|#)/ { next }
        NF < 2 { exit 1 }
    ' "$target_file"
}

validate_hostname_file() {
    local target_file="$1"
    local hostname_value
    hostname_value=$(head -n1 "$target_file" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$hostname_value" && "$hostname_value" != *"/"* ]]
}

validate_json_file() {
    local target_file="$1"
    if command -v jq >/dev/null 2>&1; then
        jq empty "$target_file"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$target_file" >/dev/null
    else
        echo -e "${YELLOW}⚠️ jq/python3 не обнаружены, проверка синтаксиса JSON пропущена.${PLAIN}"
        return 0
    fi
}

load_docker_compose_runtime_helper() {
    local helper_path
    local -a helper_paths=()

    declare -F ensure_docker_compose_ready >/dev/null 2>&1 && return 0

    if [[ -n "${SCRIPT_DIR:-}" ]]; then
        helper_paths+=("${SCRIPT_DIR}/src/compose_runtime.sh")
    fi
    helper_paths+=("$(dirname "${BASH_SOURCE[0]}")/compose_runtime.sh")

    for helper_path in "${helper_paths[@]}"; do
        [[ -f "$helper_path" ]] || continue
        # shellcheck source=/dev/null
        . "$helper_path"
        declare -F ensure_docker_compose_ready >/dev/null 2>&1 && return 0
    done

    return 1
}

run_applied_config_compose() {
    local target_file="$1"
    local project_dir
    shift

    if ! load_docker_compose_runtime_helper; then
        echo -e "${RED}❌ Логика автоматической установки/обнаружения Docker Compose не загружена, невозможно применить операции Compose.${PLAIN}"
        return 1
    fi

    ensure_docker_compose_ready || return 1
    project_dir=$(dirname "$target_file")
    (cd "$project_dir" && $DOCKER_COMPOSE_CMD -f "$target_file" "$@")
}

validate_applied_config_kind() {
    local kind="$1"
    local target_file="$2"

    case "$kind" in
        caddy)
            command -v caddy >/dev/null 2>&1 || { echo -e "${RED}❌ Команда caddy не обнаружена, невозможно проверить конфигурацию.${PLAIN}"; return 1; }
            caddy validate --config /etc/caddy/Caddyfile
            ;;
        nginx)
            command -v nginx >/dev/null 2>&1 || { echo -e "${RED}❌ Команда nginx не обнаружена, невозможно проверить конфигурацию.${PLAIN}"; return 1; }
            nginx -t
            ;;
        systemd)
            if command -v systemd-analyze >/dev/null 2>&1; then
                systemd-analyze verify "$target_file"
            else
                echo -e "${YELLOW}⚠️ systemd-analyze не обнаружен, статическая проверка systemd unit пропущена.${PLAIN}"
            fi
            ;;
        docker-json|xui-json)
            validate_json_file "$target_file"
            ;;
        compose)
            run_applied_config_compose "$target_file" config >/dev/null
            ;;
        ssh)
            command -v sshd >/dev/null 2>&1 || { echo -e "${RED}❌ Команда sshd не обнаружена, невозможно проверить конфигурацию SSH.${PLAIN}"; return 1; }
            sshd -t
            ;;
        vpso-mux)
            if declare -F run_vpso_mux_config_check >/dev/null 2>&1; then
                run_vpso_mux_config_check "$target_file"
            elif [[ -x /usr/local/bin/vpso-mux ]]; then
                /usr/local/bin/vpso-mux -config "$target_file" -check
            else
                echo -e "${YELLOW}⚠️ Бинарный файл vpso-mux не обнаружен, проверка конфигурации во время выполнения пропущена.${PLAIN}"
            fi
            ;;
        entry-mode|traffic-guard|env)
            bash -n "$target_file"
            ;;
        xray-routes)
            validate_xray_routes_file "$target_file"
            ;;
        hosts)
            validate_hosts_file "$target_file"
            ;;
        hostname)
            validate_hostname_file "$target_file"
            ;;
        dns|sysctl)
            return 0
            ;;
        fail2ban)
            if command -v fail2ban-client >/dev/null 2>&1; then
                fail2ban-client -t
            else
                echo -e "${YELLOW}⚠️ fail2ban-client не обнаружен, проверка конфигурации Fail2ban пропущена.${PLAIN}"
            fi
            ;;
        *)
            echo -e "${YELLOW}⚠️ Неизвестный тип конфигурации ${kind}, только сохранение резервной копии, дополнительная проверка не выполняется.${PLAIN}"
            ;;
    esac
}

restart_named_service_if_available() {
    local service_name="$1"
    local rc
    restart_service_if_available "$service_name"
    rc=$?
    [[ "$rc" -eq 0 || "$rc" -eq 2 ]]
}

reload_applied_config_kind() {
    local kind="$1"
    local target_file="$2"
    local previous_file="${3:-}"
    local confirm unit_name

    case "$kind" in
        caddy)
            systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1
            ;;
        nginx)
            systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
            ;;
        systemd)
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            unit_name=$(basename "$target_file")
            read_trimmed confirm "systemd выполнил daemon-reload, перезапустить/перезагрузить ${unit_name} сейчас? (y/n, по умолчанию n): "
            if is_yes "$confirm"; then
                systemctl try-reload-or-restart "$unit_name" >/dev/null 2>&1 || systemctl restart "$unit_name" >/dev/null 2>&1
            else
                echo -e "${BLUE}Изменения unit сохранены, ${unit_name} не перезапущен.${PLAIN}"
            fi
            ;;
        docker-json)
            read_trimmed confirm "Docker daemon.json проверен, перезапустить Docker сейчас, чтобы изменения вступили в силу? (y/n, по умолчанию n): "
            if is_yes "$confirm"; then
                restart_named_service_if_available docker
            else
                echo -e "${YELLOW}⚠️ Docker не перезапущен, изменения в daemon.json пока не вступили в силу.${PLAIN}"
            fi
            ;;
        compose)
            read_trimmed confirm "Конфигурация Compose проверена, выполнить up -d для применения изменений? (y/n, по умолчанию n): "
            if is_yes "$confirm"; then
                run_applied_config_compose "$target_file" up -d
            else
                echo -e "${YELLOW}⚠️ Изменения Compose сохранены, но контейнеры не пересозданы.${PLAIN}"
            fi
            ;;
        ssh)
            if confirm_risk_action "Перезапустить службу SSH" \
                "Текущее состояние службы SSH" \
                "Восстановите ${target_file}.bak_* из текущей неразорванной SSH-сессии или через консоль облачного провайдера" \
                "Убедитесь, что новая конфигурация SSH прошла проверку sshd -t."; then
                restart_service_if_available sshd >/dev/null 2>&1 || restart_service_if_available ssh >/dev/null 2>&1
            else
                echo -e "${YELLOW}⚠️ SSH не перезапущен, изменения могут не вступить в силу.${PLAIN}"
            fi
            ;;
        vpso-mux)
            if confirm_risk_action "Перезапустить vpso-mux" \
                "Процесс分流ера (маршрутизатора) TCP Peek/vpso-mux" \
                "Восстановите ${target_file}.bak_* из текущей SSH-сессии или вернитесь в меню 443 для повторного применения/отката режима входа" \
                "Убедитесь, что текущий режим входа на публичном 443 и бэкенд-порты на хосте работают корректно."; then
                restart_named_service_if_available vpso-mux
            else
                echo -e "${YELLOW}⚠️ vpso-mux не перезапущен, изменения могут не вступить в силу.${PLAIN}"
            fi
            ;;
        entry-mode|xray-routes)
            if declare -F reapply_current_entry_mode >/dev/null 2>&1; then
                if confirm_risk_action "Повторно применить текущий режим входа 443" \
                    "Конфигурация входа на публичном 443, маршруты Caddy/Nginx/vpso-mux/Xray" \
                    "Скрипт создаст резервную копию режима входа и откатит при сбое; также можно восстановить из центра резервного копирования" \
                    "Убедитесь, что домены, порты и значение ENTRY_MODE в конфигурационных файлах совпадают."; then
                    reapply_current_entry_mode
                else
                    echo -e "${YELLOW}⚠️ Конфигурация сохранена, но режим входа 443 не был повторно применен.${PLAIN}"
                fi
            else
                echo -e "${YELLOW}⚠️ Конфигурация сохранена; вернитесь в меню 443 и повторно примените текущий режим входа.${PLAIN}"
            fi
            ;;
        traffic-guard)
            if [[ -n "$previous_file" ]] && declare -F traffic_guard_restore_ssh_only_firewall_from_config >/dev/null 2>&1; then
                traffic_guard_restore_ssh_only_firewall_from_config "$previous_file" || {
                    echo -e "${RED}❌ Не удалось снять правила блокировки с сохранением только SSH, применённые до редактирования, применение отменено.${PLAIN}"
                    return 1
                }
            fi
            if confirm_risk_action "Перезапустить таймер Traffic Guard" \
                "vps-traffic-guard.timer и период проверки порога трафика" \
                "Перередактируйте ${target_file} или восстановите из ${target_file}.bak_*; при необходимости отключите vps-traffic-guard.timer" \
                "Если ACTION=poweroff, убедитесь в порогах, периоде биллинга и способе восстановления у провайдера."; then
                systemctl daemon-reload >/dev/null 2>&1 || true
                systemctl restart vps-traffic-guard.timer >/dev/null 2>&1
            else
                echo -e "${YELLOW}⚠️ Таймер Traffic Guard не перезапущен, убедитесь, что конфигурация вступит в силу при следующем запуске.${PLAIN}"
            fi
            ;;
        hostname)
            local hostname_value
            hostname_value=$(head -n1 "$target_file" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$hostname_value" ]]; then
                hostnamectl set-hostname "$hostname_value" >/dev/null 2>&1 || hostname "$hostname_value" 2>/dev/null || true
            fi
            ;;
        dns)
            if confirm_risk_action "Перезапустить systemd-resolved" \
                "Служба DNS-разрешения системы и конфигурация resolved drop-in" \
                "Восстановите ${target_file}.bak_* или вернитесь в меню оптимизации DNS для переключения на исходную конфигурацию" \
                "Убедитесь, что текущая SSH-сессия сохраняется, при необходимости можно использовать прямой IP для устранения неполадок."; then
                restart_named_service_if_available systemd-resolved
            else
                echo -e "${BLUE}Конфигурация DNS сохранена, systemd-resolved не перезапущен.${PLAIN}"
            fi
            ;;
        sysctl)
            if confirm_risk_action "Применить конфигурацию sysctl" \
                "Текущие параметры sysctl работающего ядра" \
                "Восстановите ${target_file}.bak_* и выполните sysctl --system, или вручную откатите проблемные параметры" \
                "Убедитесь в надёжности источника параметров; ошибочные сетевые параметры могут нарушить удалённое соединение."; then
                sysctl --system >/dev/null
            else
                echo -e "${YELLOW}⚠️ Изменения sysctl пока не применены к работающему ядру.${PLAIN}"
            fi
            ;;
        fail2ban)
            if confirm_risk_action "Перезапустить fail2ban" \
                "Служба Fail2ban и правила защиты входа" \
                "Восстановите ${target_file}.bak_* и перезапустите fail2ban, или временно отключите проблемный jail" \
                "Убедитесь, что текущий источник SSH не будет ошибочно заблокирован новыми правилами."; then
                restart_named_service_if_available fail2ban
            else
                echo -e "${YELLOW}⚠️ Fail2ban не перезапущен, изменения могут не вступить в силу.${PLAIN}"
            fi
            ;;
        xui-json)
            if confirm_risk_action "Перезапустить x-ui/3x-ui" \
                "Процесс панели x-ui/3x-ui и рабочая конфигурация config.json" \
                "Восстановите ${target_file}.bak_* и перезапустите панель, или используйте официальную команду x-ui/3x-ui для входа в меню управления и восстановления" \
                "Убедитесь, что порт панели, путь к сертификатам и настройки единого входа 443 совпадают."; then
                restart_named_service_if_available x-ui
                restart_named_service_if_available 3x-ui
            else
                echo -e "${YELLOW}⚠️ x-ui/3x-ui не перезапущен, изменения могут не вступить в силу.${PLAIN}"
            fi
            ;;
        env|hosts)
            echo -e "${BLUE}Конфигурация сохранена; этот файл обычно считывается системой или скриптом позднее, немедленная перезагрузка не требуется.${PLAIN}"
            ;;
        *)
            echo -e "${BLUE}Конфигурация сохранена; автоматическая перезагрузка для ${kind} не определена.${PLAIN}"
            ;;
    esac
}

edit_applied_config_file() {
    local target_file="$1"
    local target_kind="$2"
    local target_label="${3:-$1}"
    local backup_file editor confirm rollback_confirm

    [[ -e "$target_file" || -L "$target_file" ]] || { echo -e "${RED}❌ Файл не существует: ${target_file}${PLAIN}"; return 1; }
    [[ -f "$target_file" || -L "$target_file" ]] || { echo -e "${RED}❌ Не является обычным конфигурационным файлом: ${target_file}${PLAIN}"; return 1; }

    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    echo -e "${BOLD}Текущий файл: ${target_label}${PLAIN}"
    echo -e "${CYAN}${target_file}${PLAIN}"
    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    nl -ba "$target_file"
    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    read_trimmed confirm "Открыть редактор для изменения этого файла? (y/n, по умолчанию n): "
    is_yes "$confirm" || return 0

    editor=$(applied_config_editor_command) || {
        echo -e "${RED}❌ Не найден доступный редактор. Установите nano/vim/vi или установите EDITOR.${PLAIN}"
        return 1
    }
    backup_file="${target_file}.bak_$(date +%s)"
    cp -p "$target_file" "$backup_file" || { echo -e "${RED}❌ Не удалось создать резервную копию, редактирование отменено.${PLAIN}"; return 1; }
    echo -e "${CYAN}Резервная копия перед редактированием: ${backup_file}${PLAIN}"

    "$editor" "$target_file" || {
        echo -e "${RED}❌ Редактор завершился с ошибкой, конфигурация не перезагружена.${PLAIN}"
        return 1
    }

    if cmp -s "$target_file" "$backup_file"; then
        echo -e "${BLUE}Конфигурация не изменилась.${PLAIN}"
        return 0
    fi

    echo -e "${CYAN}▶ Выполняется проверка конфигурации...${PLAIN}"
    if ! validate_applied_config_kind "$target_kind" "$target_file"; then
        echo -e "${RED}❌ Проверка не удалась, служба не будет перезагружена.${PLAIN}"
        read_trimmed rollback_confirm "Восстановить резервную копию до редактирования? (Y/n, по умолчанию yes): "
        if ! is_no "$rollback_confirm"; then
            cp -p "$backup_file" "$target_file" && echo -e "${GREEN}✅ Восстановлено: ${target_file}${PLAIN}"
        else
            echo -e "${YELLOW}⚠️ Оставлены изменения, не прошедшие проверку, исправьте их вручную перед применением.${PLAIN}"
        fi
        return 1
    fi

    if reload_applied_config_kind "$target_kind" "$target_file" "$backup_file"; then
        echo -e "${GREEN}✅ Конфигурация сохранена и выполнены возможные шаги проверки/применения.${PLAIN}"
        echo -e "${CYAN}Резервный файл: ${backup_file}${PLAIN}"
    else
        echo -e "${RED}❌ Проверка конфигурации пройдена, но применение/перезагрузка не удались.${PLAIN}"
        read_trimmed rollback_confirm "Восстановить резервную копию до редактирования? (Y/n, по умолчанию yes): "
        if ! is_no "$rollback_confirm"; then
            cp -p "$backup_file" "$target_file" && reload_applied_config_kind "$target_kind" "$target_file" >/dev/null 2>&1 || true
            echo -e "${GREEN}✅ Попытка восстановления конфигурации до редактирования выполнена.${PLAIN}"
        fi
        return 1
    fi
}

func_edit_applied_config_center() {
    local scope="${1:-all}"
    local -a applied_config_labels=()
    local -a applied_config_paths=()
    local -a applied_config_kinds=()
    collect_applied_config_files "$scope"

    clear
    echo -e "${CYAN}================================================${PLAIN}"
    if [[ "$scope" == "proxy" ]]; then
        echo -e "${BOLD}📝 Просмотр/редактирование применённых конфигураций обратного прокси${PLAIN}"
    else
        echo -e "${BOLD}📝 Просмотр/редактирование применённых скриптом конфигураций${PLAIN}"
    fi
    echo -e "${CYAN}================================================${PLAIN}"
    if [[ ${#applied_config_paths[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Не обнаружено редактируемых применённых конфигурационных файлов.${PLAIN}"
        return 0
    fi

    local i
    for i in "${!applied_config_paths[@]}"; do
        printf '%b%3d. %s%b\n' "$GREEN" "$((i + 1))" "${applied_config_labels[$i]} -> ${applied_config_paths[$i]}" "$PLAIN"
    done
    echo -e "${RED}  0. Отмена${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    local choice idx
    read_trimmed choice "Выберите конфигурационный файл для просмотра/редактирования: "
    [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" ]] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#applied_config_paths[@]} )); then
        echo -e "${RED}❌ Неверный выбор.${PLAIN}"
        return 1
    fi

    idx=$((choice - 1))
    edit_applied_config_file "${applied_config_paths[$idx]}" "${applied_config_kinds[$idx]}" "${applied_config_labels[$idx]}"
}

func_backup_center() {
    local backup_root="/etc/vps-optimize/backups/manual"
    mkdir -p "$backup_root"
    chmod 700 "$backup_root" 2>/dev/null || true

    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        print_breadcrumb "Резервное копирование и откат"
        echo -e "${BOLD}🗂️ Центр резервного копирования и отката конфигураций${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "Текущий каталог резервных копий: ${YELLOW}${backup_root}${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${GREEN}  1. Создать полную резервную копию конфигурации${PLAIN}       ${YELLOW}(система/панели/Caddy/конфиги скрипта)${PLAIN}"
        echo -e "${GREEN}  2. Просмотреть список существующих резервных копий${PLAIN}"
        echo -e "${GREEN}  3. Одним нажатием выполнить откат из резервной копии${PLAIN}"
        echo -e "${GREEN}  4. Изолировать старые резервные копии${PLAIN}             ${YELLOW}(оставить только последние 5, старые переместить в карантин)${PLAIN}"
        echo -e "${CYAN}  5. Просмотр/редактирование применённых скриптом конфигураций${PLAIN} ${YELLOW}(резервирование, проверка, выбор reload/restart)${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${BLUE}  ?. Показать справку${PLAIN}"
        echo -e "${RED}  0. Вернуться в главное меню / q вернуться на уровень выше${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"

        local b_choice
        read_trimmed b_choice "👉 Выберите действие: "

        case $b_choice in
            1)
                local ts
                ts=$(date +%Y%m%d_%H%M%S)
                local work_dir
                local tar_file="${backup_root}/backup_${ts}.tar.gz"
                local manifest_file
                local copied=0

                work_dir=$(make_secure_temp_dir "vps_backup_${ts}") || {
                    echo -e "${RED}❌ Не удалось создать безопасный временный каталог, резервное копирование отменено.${PLAIN}"
                    sleep 2
                    continue
                }
                manifest_file="${work_dir}/manifest.txt"
                {
                    echo "Манифест резервной копии VPS-Optimize"
                    echo "Создано: $(date -Is 2>/dev/null || date)"
                    echo "Файл резервной копии: ${tar_file}"
                    echo "Включённые пути:"
                } > "$manifest_file"

                backup_copy_path /etc/ssh/sshd_config etc/ssh/sshd_config "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/hostname etc/hostname "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/hosts etc/hosts "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/nginx.conf etc/nginx/nginx.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/stream.d etc/nginx/stream.d "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/conf.d etc/nginx/conf.d "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/sites-available etc/nginx/sites-available "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/nginx/sites-enabled etc/nginx/sites-enabled "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/caddy/Caddyfile etc/caddy/Caddyfile "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/caddy/conf.d etc/caddy/conf.d "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/caddy/certs etc/caddy/certs "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /root/cert root/cert "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /root/.acme.sh root/.acme.sh "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /root/.config/vps-panel/cloudflare.env root/.config/vps-panel/cloudflare.env "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/sni-stack.env etc/vps-optimize/sni-stack.env "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/sni-stack.last-backup etc/vps-optimize/sni-stack.last-backup "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/443-engine.conf etc/vps-optimize/443-engine.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/vpso-mux.yaml etc/vps-optimize/vpso-mux.yaml "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/systemd/system/vpso-mux.service etc/systemd/system/vpso-mux.service "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /usr/local/bin/vpso-mux usr/local/bin/vpso-mux "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/vps-optimize/traffic-guard.conf etc/vps-optimize/traffic-guard.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /var/lib/vps-optimize/traffic-guard var/lib/vps-optimize/traffic-guard "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /usr/local/bin/vps-traffic-guard-check usr/local/bin/vps-traffic-guard-check "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/systemd/system/vps-traffic-guard.service etc/systemd/system/vps-traffic-guard.service "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/systemd/system/vps-traffic-guard.timer etc/systemd/system/vps-traffic-guard.timer "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/resolv.conf etc/resolv.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/docker/daemon.json etc/docker/daemon.json "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/fail2ban/jail.local etc/fail2ban/jail.local "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/sysctl.d etc/sysctl.d "$manifest_file" "$work_dir" && copied=1
                backup_copy_path /etc/x-ui etc/x-ui "$manifest_file" "$work_dir" && copied=1
                backup_copy_xui_databases "$manifest_file" "$work_dir" && copied=1

                if [[ "$copied" -eq 0 ]]; then
                    quarantine_path "$work_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                    echo -e "${YELLOW}⚠️ Не обнаружено конфигурационных файлов для резервирования, создание отменено.${PLAIN}"
                else
                    if ( umask 077 && tar -czf "$tar_file" -C "$work_dir" . ) >/dev/null 2>&1; then
                        chmod 600 "$tar_file" 2>/dev/null || true
                        echo -e "${GREEN}✅ Резервная копия создана: ${tar_file}${PLAIN}"
                        echo -e "${YELLOW}⚠️ Резервная копия содержит закрытые ключи сертификатов, базы данных панелей и API-токены, храните её в надёжном месте.${PLAIN}"
                    else
                        echo -e "${RED}❌ Не удалось упаковать резервную копию, проверьте свободное место на диске и права доступа.${PLAIN}"
                    fi
                    quarantine_path "$work_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                fi
                ;;

            2)
                local backups
                backups=$(ls -1t "$backup_root"/backup_*.tar.gz 2>/dev/null)
                if [[ -z "$backups" ]]; then
                    echo -e "${YELLOW}⚠️ Нет доступных резервных копий.${PLAIN}"
                else
                    echo -e "${CYAN}👇 Список резервных копий (новые -> старые):${PLAIN}"
                    local idx=1
                    while IFS= read -r f; do
                        echo -e "  ${GREEN}${idx}.${PLAIN} $(basename "$f")"
                        idx=$((idx+1))
                    done <<< "$backups"
                fi
                ;;

            3)
                mapfile -t backups < <(ls -1t "$backup_root"/backup_*.tar.gz 2>/dev/null)
                if [[ ${#backups[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}⚠️ Нет доступных резервных копий, откат невозможен.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                echo -e "${CYAN}👇 Доступные резервные копии для отката:${PLAIN}"
                for i in "${!backups[@]}"; do
                    echo -e "  ${GREEN}$((i+1)).${PLAIN} $(basename "${backups[$i]}")"
                done

                local r_choice
                read_trimmed r_choice "👉 Введите номер резервной копии для отката: "
                if ! [[ "$r_choice" =~ ^[0-9]+$ ]] || [[ "$r_choice" -lt 1 ]] || [[ "$r_choice" -gt ${#backups[@]} ]]; then
                    echo -e "${RED}❌ Неверный номер, откат отменён.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                local target_file="${backups[$((r_choice-1))]}"
                confirm_danger "Откат системной конфигурации из резервной копии" "Будут перезаписаны текущие конфигурации SSH, Caddy, Docker, Fail2ban, sysctl и другие, включённые в резервную копию." "После отката скрипт попытается перезапустить соответствующие службы; сохраните текущую SSH-сессию и будьте готовы использовать консоль восстановления провайдера." || {
                    echo -e "${BLUE}Откат отменён.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                }

                local restore_dir
                local restore_failed=0
                local restore_quarantine="/etc/vps-optimize/quarantine/manual-restore"
                restore_dir=$(make_secure_temp_dir "vps_restore") || {
                    echo -e "${RED}❌ Не удалось создать безопасный временный каталог, откат прерван.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                }

                if ! tar -tzf "$target_file" >/dev/null 2>&1; then
                    quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                    echo -e "${RED}❌ Не удалось прочитать файл резервной копии, откат прерван.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi
                if tar -tzf "$target_file" 2>/dev/null | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
                    quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                    echo -e "${RED}❌ Файл резервной копии содержит небезопасные пути, откат прерван.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if ! tar -xzf "$target_file" -C "$restore_dir" >/dev/null 2>&1; then
                    quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                    echo -e "${RED}❌ Не удалось распаковать резервную копию, откат прерван.${PLAIN}"
                    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                    continue
                fi

                if [[ -f "$restore_dir/etc/vps-optimize/traffic-guard.conf" || -f "$restore_dir/usr/local/bin/vps-traffic-guard-check" ]]; then
                    if declare -F traffic_guard_restore_ssh_only_firewall >/dev/null 2>&1 && ! traffic_guard_restore_ssh_only_firewall; then
                        quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                        echo -e "${RED}❌ Не удалось снять текущие правила блокировки с сохранением только SSH, откат прерван.${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    fi
                fi

                restore_backup_file "$restore_dir/etc/ssh/sshd_config" /etc/ssh/sshd_config || restore_failed=1
                restore_backup_file "$restore_dir/etc/hostname" /etc/hostname || restore_failed=1
                restore_backup_file "$restore_dir/etc/hosts" /etc/hosts || restore_failed=1
                restore_backup_file "$restore_dir/etc/nginx/nginx.conf" /etc/nginx/nginx.conf || restore_failed=1
                restore_backup_dir "$restore_dir/etc/nginx/stream.d" /etc/nginx/stream.d "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/nginx/conf.d" /etc/nginx/conf.d "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/nginx/sites-available" /etc/nginx/sites-available "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/nginx/sites-enabled" /etc/nginx/sites-enabled "$restore_quarantine" || restore_failed=1
                restore_backup_file "$restore_dir/etc/caddy/Caddyfile" /etc/caddy/Caddyfile || restore_failed=1
                restore_backup_dir "$restore_dir/etc/caddy/conf.d" /etc/caddy/conf.d "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/caddy/certs" /etc/caddy/certs "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/root/cert" /root/cert "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/root/.acme.sh" /root/.acme.sh "$restore_quarantine" || restore_failed=1
                restore_backup_file "$restore_dir/root/.config/vps-panel/cloudflare.env" /root/.config/vps-panel/cloudflare.env || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/sni-stack.env" /etc/vps-optimize/sni-stack.env || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/sni-stack.last-backup" /etc/vps-optimize/sni-stack.last-backup || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/443-engine.conf" /etc/vps-optimize/443-engine.conf || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/vpso-mux.yaml" /etc/vps-optimize/vpso-mux.yaml || restore_failed=1
                restore_backup_file "$restore_dir/etc/systemd/system/vpso-mux.service" /etc/systemd/system/vpso-mux.service || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/bin/vpso-mux" /usr/local/bin/vpso-mux || restore_failed=1
                restore_backup_file "$restore_dir/etc/vps-optimize/traffic-guard.conf" /etc/vps-optimize/traffic-guard.conf || restore_failed=1
                restore_backup_dir "$restore_dir/var/lib/vps-optimize/traffic-guard" /var/lib/vps-optimize/traffic-guard "$restore_quarantine" || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/bin/vps-traffic-guard-check" /usr/local/bin/vps-traffic-guard-check || restore_failed=1
                restore_backup_file "$restore_dir/etc/systemd/system/vps-traffic-guard.service" /etc/systemd/system/vps-traffic-guard.service || restore_failed=1
                restore_backup_file "$restore_dir/etc/systemd/system/vps-traffic-guard.timer" /etc/systemd/system/vps-traffic-guard.timer || restore_failed=1
                restore_backup_file "$restore_dir/etc/resolv.conf" /etc/resolv.conf || restore_failed=1
                restore_backup_file "$restore_dir/etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf" /etc/systemd/resolved.conf.d/99-vps-optimize-dns.conf || restore_failed=1
                restore_backup_file "$restore_dir/etc/docker/daemon.json" /etc/docker/daemon.json || restore_failed=1
                restore_backup_file "$restore_dir/etc/fail2ban/jail.local" /etc/fail2ban/jail.local || restore_failed=1
                restore_backup_dir "$restore_dir/etc/sysctl.d" /etc/sysctl.d "$restore_quarantine" || restore_failed=1
                restore_backup_dir "$restore_dir/etc/x-ui" /etc/x-ui "$restore_quarantine" || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/x-ui.db" /usr/local/x-ui/x-ui.db || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/x-ui.db-wal" /usr/local/x-ui/x-ui.db-wal || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/x-ui.db-shm" /usr/local/x-ui/x-ui.db-shm || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/bin/x-ui.db" /usr/local/x-ui/bin/x-ui.db || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/bin/x-ui.db-wal" /usr/local/x-ui/bin/x-ui.db-wal || restore_failed=1
                restore_backup_file "$restore_dir/usr/local/x-ui/bin/x-ui.db-shm" /usr/local/x-ui/bin/x-ui.db-shm || restore_failed=1

                if [[ -d "$restore_dir/etc/sysctl.d" ]]; then
                    sysctl --system >/dev/null 2>&1
                fi
                if [[ -f "$restore_dir/etc/hostname" ]]; then
                    local restored_hostname
                    restored_hostname=$(cat /etc/hostname 2>/dev/null | head -n1)
                    restored_hostname="$(trim_input "$restored_hostname")"
                    if [[ -n "$restored_hostname" ]]; then
                        hostnamectl set-hostname "$restored_hostname" >/dev/null 2>&1 || hostname "$restored_hostname" 2>/dev/null || true
                    fi
                fi
                if [[ -f "$restore_dir/etc/systemd/system/vps-traffic-guard.timer" || -f "$restore_dir/etc/systemd/system/vps-traffic-guard.service" || -f "$restore_dir/etc/systemd/system/vpso-mux.service" ]]; then
                    systemctl daemon-reload >/dev/null 2>&1 || true
                fi

                local restart_failed=0
                local restart_rc=0
                restart_service_if_available sshd
                restart_rc=$?
                if [[ "$restart_rc" -eq 2 ]]; then
                    restart_service_if_available ssh
                    restart_rc=$?
                fi
                [[ "$restart_rc" -eq 1 ]] && restart_failed=1

                for svc in nginx caddy docker fail2ban systemd-resolved x-ui 3x-ui xray sing-box vpso-mux; do
                    restart_service_if_available "$svc"
                    restart_rc=$?
                    [[ "$restart_rc" -eq 1 ]] && restart_failed=1
                done

                quarantine_path "$restore_dir" "/etc/vps-optimize/quarantine/manual-temp" >/dev/null 2>&1 || true
                if [[ "$restore_failed" -eq 0 && "$restart_failed" -eq 0 ]]; then
                    echo -e "${GREEN}✅ Откат выполнен! Рекомендуется сразу проверить состояние SSH, обратного прокси и контейнеров.${PLAIN}"
                elif [[ "$restore_failed" -ne 0 ]]; then
                    echo -e "${YELLOW}⚠️ Часть файлов не удалось восстановить, проверьте права доступа, свободное место и ${restore_quarantine}.${PLAIN}"
                else
                    echo -e "${YELLOW}⚠️ Файлы отката записаны, но как минимум одна служба не перезапустилась, немедленно проверьте systemctl status.${PLAIN}"
                fi
                ;;

            4)
                mapfile -t backups < <(ls -1t "$backup_root"/backup_*.tar.gz 2>/dev/null)
                if [[ ${#backups[@]} -le 5 ]]; then
                    echo -e "${BLUE}Количество резервных копий не превышает 5, очистка не требуется.${PLAIN}"
                else
                    confirm_danger "Изоляция старых резервных копий" "Копии, начиная с 6-й и старше, будут перемещены в карантинный каталог, без непосредственного удаления." "При необходимости их можно восстановить вручную из /etc/vps-optimize/quarantine/manual-backups. Последние 5 копий останутся нетронутыми." || {
                        echo -e "${BLUE}Изоляция старых копий отменена.${PLAIN}"
                        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
                        continue
                    }
                    for i in "${!backups[@]}"; do
                        if [[ "$i" -ge 5 ]]; then
                            quarantine_path "${backups[$i]}" "/etc/vps-optimize/quarantine/manual-backups" >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ Не удалось изолировать: ${backups[$i]}${PLAIN}"
                        fi
                    done
                    echo -e "${GREEN}✅ Изоляция старых копий выполнена, последние 5 резервных копий сохранены.${PLAIN}"
                fi
                ;;

            5)
                func_edit_applied_config_center
                ;;

            "?"|help) show_backup_help ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}" ;;
        esac

        echo ""
        read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    done
}
