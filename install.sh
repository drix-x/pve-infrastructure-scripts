#!/bin/bash

# Строгий режим: выходить при ошибках в командах и пайпах
set -e
set -o pipefail

# Автоматическое определение окружения: включаем цвета только в интерактивном терминале (TTY)
if [ -t 1 ]; then
    RC='\e[0;31m'      # Red (Ошибки)
    GC='\e[0;32m'      # Green (Успех)
    YC='\e[0;33m'      # Yellow (Предупреждения)
    BC='\e[0;34m'      # Blue (Информационные сообщения)
    CYAN='\e[0;36m'    # Cyan (Заголовки / Промпты)
    BOLD='\e[1m'       # Жирный шрифт
    NC='\e[0m'         # Сброс цвета (No Color)
else
    # Если вывод перенаправлен в лог или cron — отключаем ANSI-коды, чтобы не загрязнять файл
    RC='' GC='' YC='' BC='' CYAN='' BOLD='' NC=''
fi

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RC}${BOLD}❌ Ошибка: Этот скрипт должен запускаться от имени root.${NC}" >&2
    exit 1
fi

# Конфигурация
SCRIPT_URL="https://raw.githubusercontent.com/drix-x/pve-infrastructure-scripts/main/pve_backup.sh"
INSTALL_DIR="/root/bin"
SCRIPT_PATH="${INSTALL_DIR}/pve_backup.sh"
LOG_PATH="/var/log/pve_backup.log"

# Оповещение о начале работы скрипта
echo -e "${CYAN}${BOLD}==================================================${NC}"
echo -e "${CYAN}${BOLD}🔔 ОПОВЕЩЕНИЕ: Запущена автоматическая настройка бэкапа PVE${NC}"
echo -e "${CYAN}${BOLD}==================================================${NC}"
echo

# 2. Интерактивный запрос времени запуска
echo -e "${BOLD}Настройка расписания (нажмите Enter для выбора значений по умолчанию):${NC}"

# Запрос часа с цветным приглашением
read -p "$(echo -e "${CYAN}Укажите час запуска (0-23) [по умолчанию: 3]: ${NC}")" USER_HOUR
USER_HOUR="${USER_HOUR:-3}"

# Валидация часа
if ! [[ "$USER_HOUR" =~ ^[0-9]+$ ]] || [ "$USER_HOUR" -lt 0 ] || [ "$USER_HOUR" -gt 23 ]; then
    echo -e "${YC}⚠️ Предупреждение: Введен неверный час. Установлено значение по умолчанию: 3${NC}"
    USER_HOUR=3
fi

# Запрос минуты с цветным приглашением
read -p "$(echo -e "${CYAN}Укажите минуту запуска (0-59) [по умолчанию: 0]: ${NC}")" USER_MIN
USER_MIN="${USER_MIN:-0}"

# Валидация минуты
if ! [[ "$USER_MIN" =~ ^[0-9]+$ ]] || [ "$USER_MIN" -lt 0 ] || [ "$USER_MIN" -gt 59 ]; then
    echo -e "${YC}⚠️ Предупреждение: Введена неверная минута. Установлено значение по умолчанию: 0${NC}"
    USER_MIN=0
fi

# Формируем строку для cron
CRON_JOB="${USER_MIN} ${USER_HOUR} * * * ${SCRIPT_PATH} >> ${LOG_PATH} 2>&1"

# Экранируем спецсимволы в пути для безопасного поиска в crontab
SAFE_PATH=$(echo "$SCRIPT_PATH" | sed 's/[.^+*?()|]/\\&/g; s/\[/\\\[/g; s/\]/\\\]/g')
CRON_REGEX="[[:space:]]${SAFE_PATH}([[:space:]]|$)"

# 3. Создание директории
echo -e "${BC}⏳ Создание директории ${INSTALL_DIR}...${NC}"
mkdir -p "$INSTALL_DIR"

# 4. Скачивание скрипта бэкапа с проверкой успешности
echo -e "${BC}⏳ Скачивание скрипта с GitHub...${NC}"
DOWNLOAD_FAILED=0

if command -v curl &> /dev/null; then
    curl -f -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH" || DOWNLOAD_FAILED=1
elif command -v wget &> /dev/null; then
    wget -qO "$SCRIPT_PATH" "$SCRIPT_URL" || DOWNLOAD_FAILED=1
else
    echo -e "${RC}❌ Ошибка: В системе не найдены curl или wget. Не удалось скачать файл.${NC}" >&2
    exit 1
fi

# Проверка на пустой файл или ошибку сети
if [ "$DOWNLOAD_FAILED" -eq 1 ] || [ ! -s "$SCRIPT_PATH" ]; then
    echo -e "${RC}❌ Ошибка: Не удалось скачать скрипт, или скачанный файл пуст!${NC}" >&2
    echo -e "${RC}Проверьте интернет-соединение и корректность URL: $SCRIPT_URL${NC}" >&2
    rm -f "$SCRIPT_PATH"
    exit 1
fi

# 5. Установка прав на исполнение
echo -e "${BC}⏳ Настройка прав доступа (chmod +x)...${NC}"
chmod +x "$SCRIPT_PATH"

# 6. Интеграция в планировщик crontab
echo -e "${BC}⏳ Обновление расписания в crontab...${NC}"

if crontab -l 2>/dev/null | grep -E -q "$CRON_REGEX"; then
    echo -e "${YC}[!] Скрипт уже был добавлен ранее. Обновляем время запуска на новое...${NC}"
    (crontab -l 2>/dev/null | grep -E -v "$CRON_REGEX"; echo "$CRON_JOB") | crontab -
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
fi

# Создаем файл лога заранее
touch "$LOG_PATH"
chmod 600 "$LOG_PATH"

# Форматирование вывода времени
PRINT_HOUR=$(printf "%02d" "$USER_HOUR")
PRINT_MIN=$(printf "%02d" "$USER_MIN")

# Финальный красивый отчет
echo
echo -e "${GC}${BOLD}--------------------------------------------------${NC}"
echo -e "${GC}${BOLD}[⚡] УСПЕШНО: Настройка автоматизации завершена!${NC}"
echo -e "${GC}${BOLD}--------------------------------------------------${NC}"
echo -e "${BOLD}Расписание:${NC}      каждый день в ${CYAN}${PRINT_HOUR}:${PRINT_MIN}${NC}"
echo -e "${BOLD}Лог работы:${NC}      ${CYAN}${LOG_PATH}${NC}"
echo -e "${BOLD}Путь к скрипту:${NC}  ${CYAN}${SCRIPT_PATH}${NC}"
echo
echo -e "${BOLD}Фактическая запись, добавленная в crontab:${NC}"
echo -e "${BC}${CRON_JOB}${NC}"
echo -e "${GC}${BOLD}==================================================${NC}"
