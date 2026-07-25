# shellcheck shell=bash
# Old kernel cleanup workflow.

func_clean_kernel() {
    clear
    if [[ ! "$OS" =~ debian|ubuntu ]]; then
        echo -e "${RED}❌ Эта функция поддерживается только на Debian/Ubuntu!${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    local current_k
    current_k=$(uname -r)
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "${BOLD}🧹 Очистка старых ядер${PLAIN}"
    echo -e "${CYAN}================================================${PLAIN}"
    echo -e "Текущее работающее ядро: ${GREEN}${current_k}${PLAIN}"
    echo -e "${RED}⚠️ Система автоматически исключила работающее ядро, а также популярные облачные/виртуальные/оптимизированные ядра.${PLAIN}"
    echo -e "------------------------------------------------"
    
    # Автоматически извлекаем все не текущие пакеты ядра в массив (исключая мета-пакеты, используя высокодоступное сопоставление полей)
    mapfile -t old_kernels < <(dpkg -l | awk '$1 == "ii" && $2 ~ /^linux-image-[0-9]/ {print $2}' | grep -v "$current_k" | grep -Ev "cloud|kvm|virtual|generic|xanmod")

    if [[ ${#old_kernels[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Система очень чистая, не найдено старых ядер для очистки.${PLAIN}"
        read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
        return
    fi

    echo -e "${YELLOW}Обнаружены следующие старые ядра для очистки:${PLAIN}"
    for i in "${!old_kernels[@]}"; do
        echo -e " [${CYAN}$((i+1))${PLAIN}] ${old_kernels[$i]}"
    done
    echo -e " [${RED}0${PLAIN}] Отмена и возврат"
    echo -e "------------------------------------------------"

    local k_choice
    read_trimmed k_choice "👉 Введите номер для удаления: "

    if [[ "$k_choice" == "0" ]]; then
        echo -e "${BLUE}Удаление отменено.${PLAIN}"
    elif [[ "$k_choice" =~ ^[1-9][0-9]*$ ]] && [[ "$k_choice" -le "${#old_kernels[@]}" ]]; then
        local target_k="${old_kernels[$((k_choice-1))]}"
        confirm_danger "Удалить старое ядро ${target_k}" "Будет удалён пакет ядра и обновлён GRUB; проблемы с загрузкой могут повлиять на следующий запуск." "Рекомендуется создать снимок VPS; работающее ядро автоматически исключено, в случае ошибки восстановитесь из снимка или режима восстановления." || {
            echo -e "${BLUE}Удаление отменено.${PLAIN}"
            read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
            return
        }
        echo -e "${CYAN}Выполняется тихое удаление $target_k и обновление загрузчика...${PLAIN}"
        export DEBIAN_FRONTEND=noninteractive
        if apt-get purge -yq "$target_k" && update-grub >/dev/null 2>&1 && apt-get autoremove --purge -yq >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Старое ядро [$target_k] удалено! Освобождено место на диске.${PLAIN}"
        else
            echo -e "${RED}❌ Ошибка очистки! Проблемы с зависимостями или прерывание выполнения.${PLAIN}"
        fi
        unset DEBIAN_FRONTEND
    else
        echo -e "${RED}❌ Неверный выбор!${PLAIN}"
    fi

    read -n 1 -s -r -p "Нажмите любую клавишу для возврата..."
}

# ---------------------------------------------------------
# 11. Быстрый аппаратный зонд
# ---------------------------------------------------------
