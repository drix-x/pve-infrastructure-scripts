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
# Безопасное создание каталога. Если automount завис из-за мёртвого NAS, timeout спасет от вечного сна.
if ! timeout 5 mkdir -p "$BACKUP_DIR"; then
    echo "Ошибка: Не удалось получить доступ или создать директорию бэкапа (таймаут шары)!" >&2
    exit 1
fi

# Умная проверка: ищет точку монтирования для конкретного пути BACKUP_DIR
if ! findmnt -t cifs -T "$BACKUP_DIR" >/dev/null; then
    echo "Ошибка: Директория бэкапа ($BACKUP_DIR) не находится на сетевой шаре CIFS! Бэкап отменен." >&2
    exit 1
fi

# 3. Проверка утилиты sqlite3
if ! command -v sqlite3 &> /dev/null; then
    echo "Ошибка: Утилита 'sqlite3' не найдена в системе!" >&2
    echo "Пожалуйста, установите её вручную один раз: apt-get install sqlite3" >&2
    exit 1
fi

# 4. Проверка существования и доступности компонентов Proxmox
if [ ! -f "$CONFIG_DB" ]; then
    echo "Ошибка: Файл конфигурации PVE ($CONFIG_DB) не найден! Возможно, служба pve-cluster повреждена." >&2
    exit 1
fi

# Проверка живости pmxcfs (/etc/pve). Если кворум кластера потерян, stat зависнет. Предотвращаем это.
if ! timeout 3 stat /etc/pve >/dev/null 2>&1; then
    echo "Ошибка: Файловая система /etc/pve недоступна (возможно, потерян кворум кластера Proxmox)!" >&2
    exit 1
fi

# 5. Безопасная работа с временной директорией
TEMP_DIR=$(mktemp -d /tmp/pve_backup.XXXXXX)
# Ловушка: гарантированно удалит временную папку при любом исходе 
trap 'rm -rf "$TEMP_DIR"' EXIT

# Имя файла внутри архива теперь всегда статичное и понятное
TEMP_DB="${TEMP_DIR}/config_backup.db"

echo "Создание консистентного снимка базы данных PVE..."
sqlite3 "$CONFIG_DB" ".backup $TEMP_DB"

echo "Проверка существования файлов перед архивацией..."
TARGETS=(
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

# Отбираем только существующие системные пути
FILES_TO_BACKUP=()
for target in "${TARGETS[@]}"; do
    if [ -e "$target" ]; then
        FILES_TO_BACKUP+=("$target")
    fi
done

echo "Архивация конфигурационных файлов..."
set +e

# Опции модификаторов GNU tar вынесены в самый верх, до указания архива и файлов
tar --warning=no-file-changed \
    --warning=no-file-removed \
    --warning=no-file-ignored \
    -czf "$BACKUP_FILE" \
    -C "$TEMP_DIR" config_backup.db \
    -C / \
    "${FILES_TO_BACKUP[@]#/}"

TAR_EXIT_CODE=$?
set -e

# Проверка критических ошибок tar (переменная экранирована кавычками)
if [ "$TAR_EXIT_CODE" -gt 1 ]; then
    echo "Ошибка: Резервное копирование завершилось с критической ошибкой tar (Код: $TAR_EXIT_CODE)" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

# Проверка, что архив реально создан и имеет ненулевой размер
if [ ! -s "$BACKUP_FILE" ]; then
    echo "Ошибка: Архив бэкапа не был создан или имеет нулевой размер!" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

# Проверка целостности архива (защита от сетевых сбоев и обрывов CIFS)
echo "Проверка целостности созданного архива..."
if ! gzip -t "$BACKUP_FILE"; then
    echo "Ошибка: Архив поврежден или не полностью записан на сетевую шару!" >&2
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

echo "Бэкап конфигурации успешно создан и проверен: $BACKUP_FILE"
