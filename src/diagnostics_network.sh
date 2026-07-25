# shellcheck shell=bash
# Сетевые пробы 443, запуск бенчмарк-скриптов и интеграция port-dog.

probe_host_for_listen_addr() {
    local addr="$1"
    case "$addr" in
        ""|"0.0.0.0"|"::"|"[::]") echo "127.0.0.1" ;;
        *:*) echo "localhost" ;;
        *) echo "$addr" ;;
    esac
}

tcp_probe_host() {
    local label="$1"
    local host="$2"
    local port="$3"
    local attempts="${4:-3}"
    local delay="${5:-1}"
    local i

    for ((i = 1; i <= attempts; i++)); do
        if tcp_probe_once "$host" "$port"; then
            echo -e "${GREEN}✅ ${label}: ${host}:${port} доступен${PLAIN}"
            return 0
        fi
        if local_listen_socket_matches_probe "$host" "$port"; then
            echo -e "${GREEN}✅ ${label}: ${host}:${port} обнаружен локальный слушатель${PLAIN}"
            return 0
        fi
        [[ "$i" -lt "$attempts" ]] && sleep "$delay"
    done

    echo -e "${RED}❌ ${label}: ${host}:${port} недоступен${PLAIN}"
    return 1
}

tcp_probe_once() {
    local host="$1"
    local port="$2"

    tcp_target_reachable "$host" "$port"
}

is_loopback_probe_host() {
    case "$1" in
        127.*|localhost|::1|"[::1]") return 0 ;;
        *) return 1 ;;
    esac
}

local_listen_socket_matches_probe() {
    local host="$1"
    local port="$2"
    local endpoint

    is_loopback_probe_host "$host" || return 1
    command -v ss >/dev/null 2>&1 || return 1

    while IFS= read -r endpoint; do
        [[ -n "$endpoint" ]] || continue
        case "$endpoint" in
            127.*:"$port"|0.0.0.0:"$port"|\*:"$port"|"[::1]":"$port"|"[::]":"$port")
                return 0
                ;;
        esac
    done < <(ss -H -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print $4}')

    return 1
}

probe_tls_sni_certificate() {
    local label="$1"
    local host="$2"
    local port="$3"
    local sni="$4"
    local connect_target

    if ! command -v timeout >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ${label}: отсутствует timeout или openssl, проверка TLS/SNI пропущена.${PLAIN}"
        return 0
    fi

    connect_target=$(format_hostport "$host" "$port")
    if timeout 10 openssl s_client -connect "$connect_target" -servername "$sni" </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
        echo -e "${GREEN}✅ ${label}: ${connect_target} / SNI ${sni} вернул цепочку сертификатов${PLAIN}"
        return 0
    fi

    echo -e "${RED}❌ ${label}: ${connect_target} / SNI ${sni} не вернул цепочку сертификатов${PLAIN}"
    return 1
}

https_url_for_port() {
    local host="$1"
    local port="$2"
    local path="$3"
    if [[ "$port" == "443" ]]; then
        printf 'https://%s%s' "$host" "$path"
    else
        printf 'https://%s:%s%s' "$host" "$port" "$path"
    fi
}

curl_sni_path_probe() {
    local label="$1"
    local domain="$2"
    local port="$3"
    local path="$4"
    local url code curl_rc
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ${label}: curl не установлен, проверка HTTPS-пути пропущена.${PLAIN}"
        return 1
    fi
    url=$(https_url_for_port "$domain" "$port" "$path")
    code=$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 --resolve "${domain}:${port}:127.0.0.1" "$url" 2>/dev/null)
    curl_rc=$?
    if [[ "$curl_rc" -ne 0 || ! "$code" =~ ^[0-9]{3}$ || "$code" == "000" ]]; then
        echo -e "${RED}❌ ${label}: ${url} нет ответа или TLS/SNI не работает (curl exit ${curl_rc}, HTTP ${code:-000})${PLAIN}"
        return 1
    fi
    case "$code" in
        404)
            echo -e "${YELLOW}⚠️ ${label}: ${url} HTTP ${code}, 443/SNI достигнут, но путь или бэкенд могут не совпадать.${PLAIN}"
            return 0
            ;;
        *)
            echo -e "${GREEN}✅ ${label}: ${url} HTTP ${code}${PLAIN}"
            return 0
            ;;
    esac
}

tls_sni_probe_local() {
    local label="$1"
    local sni="$2"
    local port="$3"
    if ! command -v openssl >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ${label}: отсутствует openssl/timeout, проверка TLS SNI пропущена.${PLAIN}"
        return 1
    fi
    if timeout 10 openssl s_client -connect "127.0.0.1:${port}" -servername "$sni" </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
        echo -e "${GREEN}✅ ${label}: Nginx вход может попасть по SNI ${sni} на цепочку сертификатов${PLAIN}"
        return 0
    fi
    echo -e "${YELLOW}⚠️ ${label}: цепочка сертификатов не получена, проверьте Nginx stream, сертификаты Caddy или SNI.${PLAIN}"
    return 1
}

func_443_network_test() {
    clear
    echo -e "${CYAN}================================================${PLAIN}"
    print_breadcrumb "Тесты скорости и качества > Проверка единого входа 443"
    echo -e "${BOLD}🧪 Сетевой тест единого входа 443${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"

    if [[ ! -f /etc/vps-optimize/sni-stack.env ]]; then
        echo -e "${YELLOW}Конфигурация единого входа 443 не обнаружена. Сначала выполните [19] -> [2] первичную настройку.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi
    load_sni_stack_env || { read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."; return; }

    echo -e "Вход панели: https://${PANEL_DOMAIN}${PANEL_WEB_PATH}"
    echo -e "Вход подписки: https://${PANEL_DOMAIN}${SUB_URI_PATH}"
    echo -e "Clash/Mihomo: https://${PANEL_DOMAIN}${CLASH_URI_PATH}"
    echo -e "REALITY SNI: ${REALITY_SNI}:${NGINX_LISTEN_PORT} -> ${XRAY_LISTEN_ADDR}:${XRAY_LISTEN_PORT}"
    echo -e "------------------------------------------------"

    check_domain_dns_sanity "$PANEL_DOMAIN" "Домен панели" "warn" || true
    [[ "$PANEL_DOMAIN" != "$REALITY_SNI" ]] && check_domain_dns_sanity "$REALITY_SNI" "REALITY SNI" "warn" || true

    echo -e "------------------------------------------------"
    tcp_probe_host "Публичный TCP вход" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" || true
    tcp_probe_host "Локальный Nginx вход" "127.0.0.1" "$NGINX_LISTEN_PORT" || true
    tcp_probe_host "$(web_proxy_engine_label) локальный TLS" "$(probe_host_for_listen_addr "$CADDY_LISTEN_ADDR")" "$CADDY_LISTEN_PORT" || true
    tcp_probe_host "Бэкенд панели 3x-ui" "$(probe_host_for_listen_addr "$PANEL_LISTEN_ADDR")" "$PANEL_LISTEN_PORT" || true
    tcp_probe_host "Бэкенд подписки 3x-ui" "$(probe_host_for_listen_addr "$SUB_LISTEN_ADDR")" "$SUB_LISTEN_PORT" || true
    tcp_probe_host "Локальный Xray/REALITY" "$(probe_host_for_listen_addr "$XRAY_LISTEN_ADDR")" "$XRAY_LISTEN_PORT" || true

    echo -e "------------------------------------------------"
    tls_sni_probe_local "TLS SNI панели" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" || true
    curl_sni_path_probe "Путь панели" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" "$PANEL_WEB_PATH" || true
    curl_sni_path_probe "Путь обычной подписки" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" "$SUB_URI_PATH" || true
    curl_sni_path_probe "Путь Clash/Mihomo" "$PANEL_DOMAIN" "$NGINX_LISTEN_PORT" "$CLASH_URI_PATH" || true

    echo -e "------------------------------------------------"
    echo -e "${YELLOW}Пояснение: HTTP 401/403/302 обычно означает, что цепочка достигла бэкенда; 404 чаще всего — несовпадение пути или настроек подписки 3x-ui.${PLAIN}"
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

func_test_scripts() {
    while true; do
        clear
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${BOLD}📊 Комплексный набор тестов скорости и качества VPS${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        echo -e "${GREEN}  1. YABS тест производительности ${YELLOW}  2. SuperBench комплексный${PLAIN}"
        echo -e "${GREEN}  3. bench.sh базовый тест      ${YELLOW}  4. FusionBench детальный${PLAIN}"
        echo -e "${GREEN}  5. Трассировка обратного пути  ${YELLOW}  6. Качество IP / мошенничество${PLAIN}"
        echo -e "${GREEN}  7. NodeSeek комплексный      ${YELLOW}  8. Проверка разблокировки стриминга${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "${RED}  0. Вернуться в главное меню / q${PLAIN}"
        echo -e "${CYAN}================================================${PLAIN}"
        
        local t
        local ran_test=false
        read_trimmed t "👉 Введите соответствующий номер: "
        case $t in
            1) ran_test=true; run_remote_script "Запуск YABS теста производительности" "https://yabs.sh" ;;
            2) ran_test=true; run_remote_script "Запуск SuperBench комплексного теста" "https://about.superbench.pro" ;;
            3) ran_test=true; run_remote_script "Запуск bench.sh базового теста" "https://bench.sh" ;;
            4) ran_test=true; run_remote_script "Запуск FusionBench детального теста" "https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh" ;;
            5) ran_test=true; run_remote_script "Запуск трассировки обратного пути" "https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh" ;;
            6) ran_test=true; run_remote_script "Запуск проверки качества IP / мошенничества" "https://IP.Check.Place" ;;
            7) ran_test=true; run_remote_script "Запуск NodeSeek комплексного теста" "https://run.NodeQuality.com" ;;
            8) ran_test=true; run_remote_script "Запуск проверки разблокировки стриминга" "https://check.unlock.media" ;;
            0|q|Q) break ;;
            *) echo -e "${RED}❌ Неверный выбор!${PLAIN}"; sleep 1; continue ;;
        esac
        echo ""
        if [[ "$ran_test" == "true" ]]; then
            pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню тестов..."
        fi
    done
}
# ---------------------------------------------------------
# 13, 14, 15 Быстрое развертывание панелей и dog
# ---------------------------------------------------------
func_port_dog() {
    clear
    echo -e "${CYAN}👉 Загрузка и выполнение инструмента мониторинга реального трафика портов...${PLAIN}"
    run_remote_script "Установка инструмента мониторинга реального трафика портов" "https://raw.githubusercontent.com/sacredx72/VPS-Optimize/main/dog.sh"
    pause_after_external_script "Операция завершена, нажмите Enter для возврата в меню..."
}
