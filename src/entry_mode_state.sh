# shellcheck shell=bash
# Состояние режима входа 443, обнаружение слушателей и вспомогательные функции совместимости.

sni_stack_env_path() {
    echo "/etc/vps-optimize/sni-stack.env"
}

canonical_legacy_entry_mode_name() {
    case "$1" in
        "nginx_stream") echo "nginx-stream" ;;
        "xray_fallback") echo "xray-fallback" ;;
        "tcp_peek") echo "tcp-peek" ;;
        *) return 1 ;;
    esac
}

rewrite_legacy_entry_mode_assignment() {
    local file="$1"
    local key="$2"
    local legacy_value="$3"
    local canonical_value assignment_count

    canonical_value=$(canonical_legacy_entry_mode_name "$legacy_value" 2>/dev/null) || return 1
    [[ -f "$file" && -w "$file" ]] || return 1

    assignment_count=$(grep -Ec "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null || true)
    [[ "$assignment_count" == "1" ]] || return 1
    grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*('${legacy_value}'|\"${legacy_value}\"|${legacy_value})[[:space:]]*$" "$file" 2>/dev/null || return 1

    sed -i -E \
        -e "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)'${legacy_value}'[[:space:]]*$|\\1'${canonical_value}'|" \
        -e "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)\"${legacy_value}\"[[:space:]]*$|\\1\"${canonical_value}\"|" \
        -e "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)${legacy_value}[[:space:]]*$|\\1${canonical_value}|" \
        "$file"
}

get_entry_mode() {
    local env_file mode=""
    env_file=$(sni_stack_env_path)

    if [[ ! -f "$env_file" ]]; then
        echo "not-configured"
        return 0
    fi

    mode=$(
        # shellcheck disable=SC1090
        unset ENTRY_MODE
        source "$env_file" 2>/dev/null || true
        printf '%s' "${ENTRY_MODE:-}"
    )

    case "$mode" in
        ""|"nginx-stream"|"nginx_stream")
            rewrite_legacy_entry_mode_assignment "$env_file" "ENTRY_MODE" "$mode" 2>/dev/null || true
            echo "nginx-stream"
            ;;
        "xray-fallback"|"xray_fallback")
            rewrite_legacy_entry_mode_assignment "$env_file" "ENTRY_MODE" "$mode" 2>/dev/null || true
            echo "xray-fallback"
            ;;
        "tcp-peek"|"tcp_peek")
            rewrite_legacy_entry_mode_assignment "$env_file" "ENTRY_MODE" "$mode" 2>/dev/null || true
            echo "tcp-peek"
            ;;
        *)
            echo "invalid:${mode}"
            ;;
    esac
}

print_entry_mode_compat_notice() {
    local env_file
    local state_file env_mode state_engine normalized
    env_file=$(sni_stack_env_path)
    state_file=$(single_443_engine_state_path 2>/dev/null || echo "/etc/vps-optimize/443-engine.conf")

    if [[ -f "$env_file" ]]; then
        env_mode=$(
            # shellcheck disable=SC1090
            unset ENTRY_MODE
            source "$env_file" 2>/dev/null || true
            printf '%s' "${ENTRY_MODE:-}"
        )
        if [[ -z "$env_mode" ]]; then
            echo -e "${YELLOW}Совместимость: ${env_file} не содержит ENTRY_MODE, сейчас читается как nginx-stream; при сохранении будет записано ENTRY_MODE='nginx-stream'.${PLAIN}"
        else
            case "$env_mode" in
                "nginx_stream"|"xray_fallback"|"tcp_peek")
                    normalized=$(normalize_entry_mode_name "$env_mode" 2>/dev/null || echo "nginx-stream")
                    if ! rewrite_legacy_entry_mode_assignment "$env_file" "ENTRY_MODE" "$env_mode" 2>/dev/null; then
                        echo -e "${YELLOW}Совместимость: обнаружен старый ENTRY_MODE='${env_mode}', сейчас читается как '${normalized}'; при сохранении будет новое имя.${PLAIN}"
                    fi
                    ;;
            esac
        fi
    fi

    if [[ -f "$state_file" ]]; then
        state_engine=$(
            # shellcheck disable=SC1090
            unset engine
            source "$state_file" 2>/dev/null || true
            printf '%s' "${engine:-}"
        )
        case "$state_engine" in
            "nginx_stream"|"xray_fallback"|"tcp_peek")
                normalized=$(normalize_entry_mode_name "$state_engine" 2>/dev/null || echo "nginx-stream")
                if ! rewrite_legacy_entry_mode_assignment "$state_file" "engine" "$state_engine" 2>/dev/null; then
                    echo -e "${YELLOW}Совместимость: обнаружен старый engine='${state_engine}', сейчас читается как '${normalized}'; при переключении/повторном применении будет новое имя.${PLAIN}"
                fi
                ;;
        esac
    fi
}

set_entry_mode() {
    local mode="$1"
    local env_file
    env_file=$(sni_stack_env_path)

    case "$mode" in
        "nginx_stream") mode="nginx-stream" ;;
        "xray_fallback") mode="xray-fallback" ;;
        "tcp_peek") mode="tcp-peek" ;;
    esac

    case "$mode" in
        "nginx-stream"|"xray-fallback"|"tcp-peek") ;;
        *)
            echo -e "${RED}Invalid ENTRY_MODE: ${mode}${PLAIN}"
            return 1
            ;;
    esac

    mkdir -p "$(dirname "$env_file")"
    if [[ -f "$env_file" ]] && grep -q '^ENTRY_MODE=' "$env_file" 2>/dev/null; then
        sed -i "s|^ENTRY_MODE=.*|ENTRY_MODE='${mode}'|" "$env_file"
    else
        printf "ENTRY_MODE='%s'\n" "$mode" >> "$env_file"
    fi
    chmod 600 "$env_file" 2>/dev/null || true
}

listen_process_from_ss_line() {
    local line="$1"
    local proc
    proc=$(printf '%s\n' "$line" | awk -F'"' '/users:/ {print $2; exit}')
    printf '%s' "${proc:-unknown}"
}

normalize_entry_listener_process() {
    local proc="$1"
    case "$proc" in
        nginx*) echo "nginx" ;;
        xray*|x-ui*|3x-ui*) echo "xray" ;;
        vpso-mux*|tcppeek*|tcp-peek*) echo "tcppeek" ;;
        caddy*) echo "caddy" ;;
        unknown|"") echo "unknown" ;;
        *) echo "unknown:${proc}" ;;
    esac
}

entry_listener_display_name() {
    local listener="$1"
    case "$listener" in
        nginx) echo "Nginx Stream (nginx)" ;;
        xray) echo "Xray Fallback (xray/3x-ui/x-ui)" ;;
        tcppeek) echo "Режим TCP Peek + Splice (разделитель vpso-mux)" ;;
        caddy) echo "Caddy (не должен напрямую занимать порт 443)" ;;
        none) echo "Не слушает" ;;
        multiple) echo "Несколько процессов слушают/совпадают" ;;
        unknown) echo "Слушает, но процесс не виден" ;;
        unknown:*) echo "Неизвестный процесс ${listener#unknown:}" ;;
        *) echo "$listener" ;;
    esac
}

entry_mode_expected_listener() {
    local mode="$1"
    mode=$(normalize_entry_mode_name "$mode" 2>/dev/null || echo "$mode")
    case "$mode" in
        "nginx-stream") echo "nginx" ;;
        "xray-fallback") echo "xray" ;;
        "tcp-peek") echo "tcppeek" ;;
        *) echo "" ;;
    esac
}

listen_line_status() {
    local addr="$1"
    local port="$2"
    local line="$3"
    local proc

    if [[ "$addr" == "not-configured" || "$port" == "not-configured" ]]; then
        echo "Не настроен"
        return 0
    fi
    if [[ -z "$line" || "$line" == "Не слушает" || "$line" == "not-configured" ]]; then
        echo "Не слушает"
        return 0
    fi

    proc=$(listen_process_from_ss_line "$line")
    if [[ "$proc" == "unknown" ]]; then
        echo "Слушает (процесс не виден)"
    else
        echo "Слушает (${proc})"
    fi
}

detect_443_listener() {
    local port="${1:-${NGINX_LISTEN_PORT:-443}}"
    local lines line proc normalized seen procs
    lines=$(ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true)

    if [[ -z "$lines" ]]; then
        echo "none|none"
        return 0
    fi

    seen=" "
    procs=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        proc=$(listen_process_from_ss_line "$line")
        normalized=$(normalize_entry_listener_process "$proc")
        if [[ "$seen" != *" ${normalized} "* ]]; then
            seen+="${normalized} "
            if [[ -z "$procs" ]]; then
                procs="$normalized"
            else
                procs="${procs},${normalized}"
            fi
        fi
    done <<< "$lines"

    if [[ "$procs" == *,* ]]; then
        echo "multiple|${procs}"
    else
        echo "${procs}|${procs}"
    fi
}

listener_info_has_entry() {
    local listener_info="$1"
    local expected="$2"
    local primary labels
    primary="${listener_info%%|*}"
    labels="${listener_info#*|}"
    [[ "$primary" == "$expected" || ",${labels}," == *",${expected},"* ]]
}

detect_current_entry_status() {
    local env_file
    local listener_info expected_listener xui_svc xui_status
    env_file=$(sni_stack_env_path)

    ENTRY_STATUS_MODE=$(get_entry_mode)
    ENTRY_STATUS_CADDY_ADDR="not-configured"
    ENTRY_STATUS_CADDY_PORT="not-configured"
    ENTRY_STATUS_XRAY_ADDR="not-configured"
    ENTRY_STATUS_XRAY_PORT="not-configured"

    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        source "$env_file" 2>/dev/null || true
        ENTRY_STATUS_CADDY_ADDR="${CADDY_LISTEN_ADDR:-not-configured}"
        ENTRY_STATUS_CADDY_PORT="${CADDY_LISTEN_PORT:-not-configured}"
        ENTRY_STATUS_XRAY_ADDR="${XRAY_LISTEN_ADDR:-not-configured}"
        ENTRY_STATUS_XRAY_PORT="${XRAY_LISTEN_PORT:-not-configured}"
    fi

    listener_info=$(detect_443_listener)
    ENTRY_STATUS_LISTENER="${listener_info%%|*}"
    ENTRY_STATUS_LISTENER_PROCESS="${listener_info#*|}"
    ENTRY_STATUS_LISTENER_DISPLAY=$(entry_listener_display_name "$ENTRY_STATUS_LISTENER")
    ENTRY_STATUS_NGINX_SERVICE=$(service_status_compact nginx)
    xui_status=$(xui_panel_status_compact)
    if xui_svc=$(xui_panel_service_name 2>/dev/null); then
        xui_status="${xui_svc}.service ${xui_status}"
    fi
    ENTRY_STATUS_XRAY_SERVICE="Панель управляет Xray: ${xui_status} / независимый xray.service: $(service_status_compact xray)"
    ENTRY_STATUS_TCPPEEK_SERVICE=$(service_status_compact vpso-mux)
    ENTRY_STATUS_CADDY_LISTEN_LINE="not-configured"
    ENTRY_STATUS_XRAY_LISTEN_LINE="not-configured"

    if is_valid_port "$ENTRY_STATUS_CADDY_PORT"; then
        ENTRY_STATUS_CADDY_LISTEN_LINE=$(get_listen_line_by_port "$ENTRY_STATUS_CADDY_PORT")
    fi
    if is_valid_port "$ENTRY_STATUS_XRAY_PORT"; then
        ENTRY_STATUS_XRAY_LISTEN_LINE=$(get_listen_line_by_port "$ENTRY_STATUS_XRAY_PORT")
    fi

    expected_listener=$(entry_mode_expected_listener "$ENTRY_STATUS_MODE")

    if [[ -n "$expected_listener" ]] && listener_info_has_entry "$listener_info" "$expected_listener"; then
        ENTRY_STATUS_CONSISTENT="yes"
    else
        ENTRY_STATUS_CONSISTENT="no"
    fi
}

show_current_entry_status() {
    detect_current_entry_status
    echo -e "${BOLD}Текущее состояние единого входа 443${PLAIN}"
    echo -e "Режим конфигурации: ${CYAN}${ENTRY_STATUS_MODE}${PLAIN}"
    print_entry_mode_compat_notice
    echo -e "Публичный 443: ${ENTRY_STATUS_LISTENER_DISPLAY}"
    echo -e "Процесс слушателя: ${ENTRY_STATUS_LISTENER_PROCESS}"
    if [[ "$ENTRY_STATUS_LISTENER" == "xray" ]]; then
        echo -e "Xray публичный: ${GREEN}публичный 443 сейчас слушается Xray/панельным Xray${PLAIN}"
    else
        echo -e "Xray публичный: Xray, слушающий публичный 443, не обнаружен"
    fi
    if [[ "$ENTRY_STATUS_CONSISTENT" == "yes" ]]; then
        echo -e "Согласованность: ${GREEN}режим конфигурации и фактический слушатель совпадают${PLAIN}"
    else
        echo -e "Согласованность: ${YELLOW}режим конфигурации и фактический слушатель не совпадают${PLAIN}"
        echo -e "${YELLOW}Несовпадение, рекомендуется повторно применить текущий режим входа.${PLAIN}"
    fi
    echo -e "------------------------------------------------"
    echo -e "${BOLD}Локальные слушатели${PLAIN}"
    echo -e "Caddy: ${ENTRY_STATUS_CADDY_ADDR}:${ENTRY_STATUS_CADDY_PORT} - $(listen_line_status "$ENTRY_STATUS_CADDY_ADDR" "$ENTRY_STATUS_CADDY_PORT" "$ENTRY_STATUS_CADDY_LISTEN_LINE")"
    echo -e "Xray: ${ENTRY_STATUS_XRAY_ADDR}:${ENTRY_STATUS_XRAY_PORT} - $(listen_line_status "$ENTRY_STATUS_XRAY_ADDR" "$ENTRY_STATUS_XRAY_PORT" "$ENTRY_STATUS_XRAY_LISTEN_LINE")"
    echo -e "------------------------------------------------"
    echo -e "${BOLD}Состояние служб${PLAIN}"
    echo -e "nginx: ${ENTRY_STATUS_NGINX_SERVICE}"
    echo -e "TCP Peek + Splice / разделитель vpso-mux: ${ENTRY_STATUS_TCPPEEK_SERVICE}"
    echo -e "Xray/3x-ui/x-ui: ${ENTRY_STATUS_XRAY_SERVICE}"
}

show_current_entry_summary() {
    detect_current_entry_status
    echo -e "${BOLD}Текущий режим входа: ${CYAN}${ENTRY_STATUS_MODE}${PLAIN}"
    print_entry_mode_compat_notice
    if [[ "$ENTRY_STATUS_CONSISTENT" != "yes" ]]; then
        echo -e "${YELLOW}⚠️ Режим конфигурации и фактическое прослушивание 443 не совпадают, проверьте через [1] и повторно примените текущий режим.${PLAIN}"
    fi
}
