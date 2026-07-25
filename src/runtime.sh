# shellcheck shell=bash
# Проверка привилегий перед запуском меню.

# --- Runtime guard ---
ensure_runtime_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Ошибка: запускайте этот скрипт от имени root!${PLAIN}"
        exit 1
    fi
}
