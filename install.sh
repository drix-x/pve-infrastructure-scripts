#!/bin/bash

# Строгий режим: выходить при ошибках
set -e

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Ошибка: Этот скрипт должен запускаться от имени root." >&2
    exit 1
fi

# Конфигурация
SCRIPT_URL="https://raw.githubusercontent.com/drix-x/pve-infrastructure-scripts/main/pve_backup.sh"
INSTALL_DIR="/root/bin"
SCRIPT_PATH="${INSTALL_DIR}/pve_backup.sh"
LOG_PATH="/var/log/pve_backup.log"

echo "=== Запуск автоматической настройки бэкапа ==="

# 2. Интерактивный запрос времени запуска
echo "Настройка расписания (нажмите Enter для выбора значений по умолчанию):"

# Запрос часа
read -p "Укажите час запуска (0-23) [по умолчанию: 3]: " USER_HOUR
USER_HOUR="${USER_HOUR:-3}"

# Валидация часа
if ! [[ "$USER_HOUR" =~ ^[0-9]+$ ]] || [ "$USER_HOUR" -lt 0 ] || [ "$USER_HOUR" -gt 23 ]; then
    echo "⚠️ Предупреждение: Введен неверный час. Установлено значение по умолчанию: 3"
    USER_HOUR=3
fi

# Запрос минуты
read -p "Укажите минуту запуска (0-59) [по умолчанию: 0]: " USER_MIN
USER_MIN="${USER_MIN:-0}"

# Валидация минуты
if ! [[ "$USER_MIN" =~ ^[0-9]+$ ]] || [ "$USER_MIN" -lt 0 ] || [ "$USER_MIN" -gt 59 ]; then
    echo "⚠️ Предупреждение: Введена неверная минута. Установлено значение по умолчанию: 0"
    USER_MIN=0
fi

# Формируем строку для cron
CRON_JOB="${USER_MIN} ${USER_HOUR} * * * ${SCRIPT_PATH} >> ${LOG_PATH} 2>&1"

# Экранируем спецсимволы в пути. Так как путь статический и известен заранее,
# этого набора более чем достаточно для безопасного поиска в crontab.
SAFE_PATH=$(echo "$SCRIPT_PATH" | sed 's/[.^+*?()|]/\\&/g; s/\[/\\\[/g; s/\]/\\\]/g')
CRON_REGEX="[[:space:]]${SAFE_PATH}([[:space:]]|$)"

# 3. Создание директории
echo "Создание директории ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

# 4. Скачивание скрипта бэкапа с проверкой успешности
echo "Скачивание скрипта с GitHub..."
DOWNLOAD_FAILED=0

if command -v curl &> /dev/null; then
    curl -f -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH" || DOWNLOAD_FAILED=1
elif command -v wget &> /dev/null; then
    wget -qO "$SCRIPT_PATH" "$SCRIPT_URL" || DOWNLOAD_FAILED=1
else
    echo "Ошибка: В системе не найдены curl или wget. Не удалось скачать файл." >&2
    exit 1
fi

# Проверка на пустой файл или ошибку сети
if [ "$DOWNLOAD_FAILED" -eq 1 ] || [ ! -s "$SCRIPT_PATH" ]; then
    echo "Ошибка: Не удалось скачать скрипт, или скачанный файл пуст!" >&2
    echo "Проверьте интернет-соединение и корректность URL: $SCRIPT_URL" >&2
    rm -f "$SCRIPT_PATH"
    exit 1
fi

# 5. Установка прав на исполнение
echo "Настройка прав доступа (chmod +x)..."
chmod +x "$SCRIPT_PATH"

# 6. Интеграция в планировщик crontab
echo "Обновление расписания в crontab..."

if crontab -l 2>/dev/null | grep -E -q "$CRON_REGEX"; then
    echo "[!] Скрипт уже был добавлен ранее. Обновляем время запуска на новое..."
    (crontab -l 2>/dev/null | grep -E -v "$CRON_REGEX"; echo "$CRON_JOB") | crontab -
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
fi

# Создаем файл лога заранее
touch "$LOG_PATH"
chmod 600 "$LOG_PATH"

# Форматирование вывода времени с обязательным кавычением переменных
PRINT_HOUR=$(printf "%02d" "$USER_HOUR")
PRINT_MIN=$(printf "%02d" "$USER_MIN")

echo "---------------------------------------------"
echo "[⚡] Успешно: Задача автоматизирована."
echo "Расписание: каждый день в ${PRINT_HOUR}:${PRINT_MIN}"
echo "Лог работы будет вестись в: ${LOG_PATH}"
echo "Путь к скрипту: $SCRIPT_PATH"
echo
echo "Фактическая запись, добавленная в crontab:"
echo "$CRON_JOB"
echo "============================================="
