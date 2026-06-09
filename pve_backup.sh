#!/bin/bash

# Строгий режим: выходить при ошибках в командах и пайпах
set -e
set -o pipefail

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Ошибка: Этот скрипт должен запускаться от имени root." >&2
    exit 1
fi

# Конфигурация
BACKUP_DIR="/mnt/Backups/pve_backups/host_configs"
CONFIG_DB="/var/lib/pve-cluster/config.db"
HOST_NAME=$(hostname)
DATE=$(date +%Y-%m-%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/${HOST_NAME}_config_${DATE}.tar.gz"

# 2. Проверка сетевой шары с учетом systemd.automount
# Обращаемся к шаре, чтобы разбудить её, если она уснула по idle-timeout.
# Используем '|| true', чтобы скрипт не упал молча по 'set -e', если удаленный сервер недоступен.
ls /mnt >/dev/null 2>&1 || true

if ! findmnt -n -t cifs /mnt >/dev/null; then
    echo "Ошибка: Сетевая шара /mnt (CIFS) не примонтирована! Бэкап отменен." >&2
    exit 1
fi

# 3. Проверка утилиты sqlite3
if ! command -v sqlite3 &> /dev/null; then
    echo "Ошибка: Утилита 'sqlite3' не найдена в системе!" >&2
    echo "Пожалуйста, установите её вручную один раз: apt-get install sqlite3" >&2
    exit 1
fi

# 4. Проверка существования базы данных Proxmox
if [ ! -f "$CONFIG_DB" ]; then
    echo "Ошибка: Файл конфигурации PVE ($CONFIG_DB) не найден! Возможно, служба pve-cluster повреждена." >&2
    exit 1
fi

# Создаем папку для бэкапа, если её нет
mkdir -p "$BACKUP_DIR"

# 5. Безопасная работа с временными файлами
TEMP_DB=$(mktemp /tmp/pve_backup_db.XXXXXX.db)
# Ловушка: гарантированно удалит временный файл при любом исходе
trap 'rm -f "$TEMP_DB"' EXIT

echo "Создание консистентного снимка базы данных PVE..."
sqlite3 "$CONFIG_DB" ".backup $TEMP_DB"

echo "Проверка существования файлов перед архивацией..."
TARGETS=(
    "$TEMP_DB"
    /etc/pve
    /etc/network/interfaces
    /etc/fstab
    /etc/hosts
    /etc/resolv.conf
    /etc/passwd
    /etc/shadow
    /etc/group
    /etc/cron.d
    /var/spool/cron/crontabs
    /root/.ssh
)

# Отбираем только существующие пути
FILES_TO_BACKUP=()
for target in "${TARGETS[@]}"; do
    if [ -e "$target" ]; then
        FILES_TO_BACKUP+=("$target")
    fi
done

echo "Архивация конфигурационных файлов..."
set +e
tar -czf "$BACKUP_FILE" \
    --warning=no-file-changed \
    --warning=no-file-removed \
    --warning=no-file-ignored \
    "${FILES_TO_BACKUP[@]}"

TAR_EXIT_CODE=$?
set -e

# Проверка критических ошибок tar
if [ $TAR_EXIT_CODE -gt 1 ]; then
    echo "Ошибка: Резервное копирование завершилось с критической ошибкой tar (Код: $TAR_EXIT_CODE)" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

# Проверка, что архив реально создан и имеет ненулевой размер
if [ ! -s "$BACKUP_FILE" ]; then
    echo "Ошибка: Архив бэкапа не был создан или имеет нулевой размер (возможен сбой сети)!" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

# 6. Ротация старых бэкапов (удаляем только файлы этого хоста и конфигураций)
echo "Очистка старых бэкапов (старше 30 дней)..."
find "$BACKUP_DIR" \
    -type f \
    -name "${HOST_NAME}_config_*.tar.gz" \
    -mtime +30 \
    -delete

echo "Бэкап конфигурации успешно создан: $BACKUP_FILE"
