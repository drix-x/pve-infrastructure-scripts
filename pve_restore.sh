#!/bin/bash

# ==============================================================================
# 🔥 STANDALONE NODE RESTORE SCRIPT / МАНИФЕСТ ВОССТАНОВЛЕНИЯ ОДИНОЧНОЙ НОДЫ 🔥
# ==============================================================================
# Версия: 24.1 (Hardened Transactional State Machine / Fixed)
# ==============================================================================

set -eu
set -o pipefail

# Состояния транзакции
SUCCESS=0
PHASE="PREPARE" # Допустимые фазы: PREPARE, DB_SWAP, UNPACKING, AUDIT
ROLLBACK_CREATED=0
ROLLBACK_EXECUTED=0
RESTORE_STARTED=0
TEMP_DIR=""
ROLLBACK_FILE="/root/pve_restore_rollback_$(date +%s).tar.gz"
BACKUP_FILE=""
FORCE_CONFIRM=""
VER_CONFIRM=""
CONFIRM=""

EXISTING_ROLLBACK_ITEMS=()
declare -A SEEN_ITEMS

MANDATORY_SERVICES=(pve-cluster pvedaemon pveproxy)
OPTIONAL_SERVICES=(corosync pve-ha-lrm pve-ha-crm spiceproxy)
declare -A STOPPED_OPTIONAL_SERVICES

# 1. Облегченный, детерминированный обработчик прерываний и ошибок
cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    
    # [FIX 3] Защита от маскировки кода ошибки при перехвате сигналов прерывания (например, Ctrl+C)
    if [ "$SUCCESS" -ne 1 ] && [ "$exit_code" -eq 0 ]; then
        exit_code=1
    fi
    
    if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR}" ]; then
        rm -rf "${TEMP_DIR}" || true
    fi
    
    if [ "$SUCCESS" -eq 1 ]; then
        exit "$exit_code"
    fi
    
    echo -e "\n🛑 КРИТИЧЕСКАЯ ОШИБКА ИЛИ ПРЕРЫВАНИЕ СЦЕНАРИЯ (Код возврата: $exit_code)" >&2
    
    # Защитный замок фазы распаковки
    if [ "$RESTORE_STARTED" -eq 1 ] && [ "$PHASE" = "UNPACKING" ]; then
        echo "💥 КРИТИЧЕСКИЙ СБОЙ: Процесс распаковки прерван на середине! Система деградирована." >&2
        echo "⛔ Автоматический слепой откат заблокирован во избежание уничтожения данных." >&2
        exit "$exit_code"
    fi
    
    if [ "${ROLLBACK_CREATED}" -ne 1 ] || [ ! -f "${ROLLBACK_FILE}" ]; then
        echo "⚠️ Автоматический откат невозможен: страховочный пакет не был собран." >&2
        exit "$exit_code"
    fi
    
    if [ "$PHASE" = "PREPARE" ]; then
        echo "[Фаза: PREPARE] Сбой до изменения системы. Никаких действий не требуется." >&2
        exit "$exit_code"
    fi
    
    if [ "$PHASE" = "DB_SWAP" ] && [ "$ROLLBACK_EXECUTED" -eq 0 ]; then
        ROLLBACK_EXECUTED=1
        echo "[Фаза: DB_SWAP] Сбой при модификации DB. Запускаю безопасный откат..." >&2
        
        for svc in "${MANDATORY_SERVICES[@]}" "${OPTIONAL_SERVICES[@]}"; do
            systemctl stop "$svc" 2>/dev/null || true
        done
        pkill -9 -x pmxcfs 2>/dev/null || true
        umount -l /etc/pve 2>/dev/null || true
        
        if tar -tzf "${ROLLBACK_FILE}" &>/dev/null; then
            if tar -xzf "${ROLLBACK_FILE}" -C /; then
                systemctl start pve-cluster 2>/dev/null || true
                systemctl start pvedaemon 2>/dev/null || true
                echo "✅ АВТОМАТИЧЕСКИЙ ОТКАТ БАЗЫ ДАННЫХ ВЫПОЛНЕН!" >&2
            else
                echo "💥 КАТАСТРОФИЧЕСКАЯ ОШИБКА: Ошибка при распаковке rollback-файла!" >&2
            fi
        else
            echo "💥 КАТАСТРОФИЧЕСКАЯ ОШИБКА: Роллбэк-архив поврежден!" >&2
        fi
    elif [ "$PHASE" = "UNPACKING" ] || [ "$PHASE" = "AUDIT" ]; then
        echo "========================================================================" >&2
        echo "⚠️ [Фаза: $PHASE] ТОЧКА НЕВОЗВРАТА ПРОЙДЕНА! Автоматический откат заблокирован." >&2
        echo "🛡️ Исходное состояние системы сохранено в: ${ROLLBACK_FILE}" >&2
        echo "========================================================================" >&2
    fi
    
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# 2. Проверки среды
if [ "$EUID" -ne 0 ]; then echo "Ошибка: Запуск только от root." >&2; exit 1; fi

REQUIRED_UTILS=(
    tar sqlite3 findmnt find gzip pgrep cut basename date sleep realpath perl
    timeout mountpoint install mv cp systemctl hostname umount df du awk sed wc diff grep qm pvesm pveum pveversion pvesh pkill sync
)
for util in "${REQUIRED_UTILS[@]}"; do
    if ! command -v "$util" >/dev/null 2>&1; then echo "Ошибка: Утилита '$util' не найдена!" >&2; exit 1; fi
done

CONFIG_DB="/var/lib/pve-cluster/config.db"
BACKUP_DIR="/mnt/Backups/pve_backups/host_configs"
HOST_NAME=$(hostname)

# 3. Поиск файла бэкапа
if [ -n "${1:-}" ]; then
    BACKUP_FILE="$1"
else
    echo "Аргумент не передан. Ищу последний бэкап в $BACKUP_DIR..."
    if ! findmnt -t cifs -T "$BACKUP_DIR" >/dev/null; then
        echo "Ошибка: Директория $BACKUP_DIR не смонтирована или не CIFS." >&2; exit 1
    fi
    LATEST_BACKUP=$(find "$BACKUP_DIR" -type f -name "${HOST_NAME}_config_*.tar.gz" -printf '%T@\t%p\n' 2>/dev/null | sort -n | tail -1 | cut -f2- || true)
    if [ -z "$LATEST_BACKUP" ]; then echo "Ошибка: Бэкапы для $HOST_NAME не найдены!" >&2; exit 1; fi
    BACKUP_FILE="$LATEST_BACKUP"
fi

if [ ! -f "$BACKUP_FILE" ]; then echo "Ошибка: Файл бэкапа не найден!" >&2; exit 1; fi

# 4. Проверка дискового пространства
ARCHIVE_SIZE_KB=$(du -k "$BACKUP_FILE" | cut -f1)
AVAILABLE_SPACE_KB=$(df -P / | awk 'NR==2 {print $4}')
REQUIRED_SPACE_KB=$((ARCHIVE_SIZE_KB * 6 + 153600))
if [ "$AVAILABLE_SPACE_KB" -lt "$REQUIRED_SPACE_KB" ]; then
    echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Недостаточно места на корневой ФС (/)!" >&2; exit 1
fi

# 5. Проверка соответствия имени хоста
FILE_BASE=$(basename "$BACKUP_FILE")
ARCHIVE_HOST="${FILE_BASE%_config_*}"
if [ "$ARCHIVE_HOST" != "$HOST_NAME" ]; then
    echo "🛑 ВНИМАНИЕ: Архив создан для хоста [$ARCHIVE_HOST], а текущий хост [$HOST_NAME]!" >&2
    read -r -p "Для принудительного продолжения введите 'FORCE': " FORCE_CONFIRM
    if [ "$FORCE_CONFIRM" != "FORCE" ]; then echo "Восстановление отменено."; exit 1; fi
fi

TEMP_DIR=$(mktemp -d /tmp/pve_restore.XXXXXX)

# 6. Комплексный аудит манифеста безопасности архива
echo "Выполнение аудита безопасности манифеста архива..."

if ! RAW_MANIFEST_STR=$(tar -tzf "$BACKUP_FILE" 2>/dev/null); then
    echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Архив поврежден, пуст или недоступен!" >&2; exit 1
fi

mapfile -t RAW_MANIFEST <<< "$RAW_MANIFEST_STR"

if ! printf '%s\n' "${RAW_MANIFEST[@]}" | grep -qE '(^|/)?config_backup\.db$'; then
    echo "Ошибка: Файл config_backup.db отсутствует в манифесте бэкапа!" >&2; exit 1
fi

for item in "${RAW_MANIFEST[@]}"; do
    [ -z "$item" ] && continue
    CLEAN_ITEM=$(echo "$item" | sed 's|^/||')
    
    if [[ "$CLEAN_ITEM" =~ (^|/)?config_backup\.db$ ]] || [ "$CLEAN_ITEM" = "pve_version.txt" ]; then
        continue
    fi

    if [[ "$CLEAN_ITEM" =~ (^|/)\.\.(/|$) ]] || [[ "$CLEAN_ITEM" =~ (^|/)\.(/|$) ]]; then
        echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Обнаружен опасный компонент пути (. или ..) в '$item'!" >&2; exit 1
    fi
    RESOLVED_PATH=$(realpath -m "/$CLEAN_ITEM")
    ALLOWED_PREFIX=0
    for prefix in "/etc/" "/var/lib/pve-cluster/" "/var/spool/cron/" "/root/"; do
        if [[ "$RESOLVED_PATH" == "$prefix"* ]]; then ALLOWED_PREFIX=1; break; fi
    done
    if [ "$ALLOWED_PREFIX" -eq 0 ]; then
        echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Путь '$RESOLVED_PATH' выходит за рамки разрешенной структуры!" >&2; exit 1
    fi
done

echo "Проверка структуры символических ссылок в теле архива..."
while read -r symlink_data; do
    [ -z "$symlink_data" ] && continue
    LINK_PATH="${symlink_data%%:::*}"
    LINK_TARGET="${symlink_data#*:::}"
    if [[ "$LINK_TARGET" == /* ]] || [[ "$LINK_TARGET" == *..* ]]; then
        echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Обнаружен опасный симлинк: $LINK_PATH -> $LINK_TARGET" >&2; exit 1
    fi
done < <(perl -MArchive::Tar -e '
    my $iter = Archive::Tar->iter($ARGV[0]);
    while (my $f = $iter->()) { print $f->full_path . ":::" . $f->linkname . "\n" if $f->is_symlink; }
' "$BACKUP_FILE" 2>/dev/null || true)

# 7. Контроль совместимости версий Proxmox
HOST_PVE_VERSION=$(pveversion | cut -d/ -f2 | cut -d- -f1)
set +e; tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR" pve_version.txt etc/os-release 2>/dev/null; set -e

BACKUP_PVE_VERSION="unknown"
if [ -f "${TEMP_DIR}/pve_version.txt" ]; then
    BACKUP_PVE_VERSION=$(grep -E '^pve-manager:' "${TEMP_DIR}/pve_version.txt" | cut -d: -f2 | tr -d ' ' | cut -d/ -f1 | cut -d- -f1 || echo "unknown")
elif [ -f "${TEMP_DIR}/etc/os-release" ]; then
    BACKUP_CODENAME=$(grep -E '^VERSION_CODENAME=' "${TEMP_DIR}/etc/os-release" | cut -d= -f2 | tr -d '"' || echo "")
    [[ "$BACKUP_CODENAME" == "bullseye" ]] && BACKUP_PVE_VERSION="7.x"
    [[ "$BACKUP_CODENAME" == "bookworm" ]] && BACKUP_PVE_VERSION="8.x"
fi

if [ "$HOST_PVE_VERSION" != "$BACKUP_PVE_VERSION" ] && [ "$BACKUP_PVE_VERSION" != "unknown" ]; then
    echo "⚠️ ВНИМАНИЕ: Несоответствие версий! Хост: PVE $HOST_PVE_VERSION, Бэкап: PVE $BACKUP_PVE_VERSION" >&2
    read -r -p "Для продолжения введите 'CONFIRM_VERSION': " VER_CONFIRM
    if [ "$VER_CONFIRM" != "CONFIRM_VERSION" ]; then echo "Прервано."; exit 1; fi
fi

read -r -p "Запустить восстановление одиночной ноды? Введите 'yes': " CONFIRM
if [ "$CONFIRM" != "yes" ]; then echo "Отмена."; exit 0; fi

# 8. Валидация базы данных SQLite ДО остановки продакшена
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR" config_backup.db
if ! sqlite3 "${TEMP_DIR}/config_backup.db" "PRAGMA integrity_check;" | grep -qx "ok"; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Резервная база SQLite логически повреждена!" >&2; exit 1
fi

# 9. Формирование списка элементов для честного Rollback-пакета
mapfile -t CLEAN_MANIFEST < <(printf '%s\n' "${RAW_MANIFEST[@]}" | sed 's|^/||' | grep -vE 'config_backup\.db$' || true)
for item in "${CLEAN_MANIFEST[@]}"; do
    [[ "$item" =~ ^etc/pve/ ]] && continue
    [ -z "$item" ] && continue
    CLEAN_ITEM="${item%/}"
    
    if [ -f "/$CLEAN_ITEM" ] || [ -L "/$CLEAN_ITEM" ] || { [ -d "/$CLEAN_ITEM" ] && [ -z "$(find "/$CLEAN_ITEM" -mindepth 1 -print -quit 2>/dev/null)" ]; }; then
        if [ -z "${SEEN_ITEMS["$CLEAN_ITEM"]:-}" ]; then
            SEEN_ITEMS["$CLEAN_ITEM"]=1; EXISTING_ROLLBACK_ITEMS+=("$CLEAN_ITEM")
        fi
    fi
done

if [ -f "$CONFIG_DB" ] && [ -z "${SEEN_ITEMS["var/lib/pve-cluster/config.db"]:-}" ]; then
    EXISTING_ROLLBACK_ITEMS+=("var/lib/pve-cluster/config.db")
fi

echo "Создание детерминированного пакета отката..."
# [FIX 2] Проверяем наличие элементов. Если нода пустая/чистая, tar не упадет с ошибкой пустого архива
if [ ${#EXISTING_ROLLBACK_ITEMS[@]} -gt 0 ]; then
    if ! tar -C / -czf "${ROLLBACK_FILE}.tmp" "${EXISTING_ROLLBACK_ITEMS[@]}"; then
        echo "Ошибка упаковки rollback-архива!" >&2; exit 1
    fi
    mv -f "${ROLLBACK_FILE}.tmp" "${ROLLBACK_FILE}"
else
    echo "ℹ️ Существующие конфигурационные файлы отсутствуют (чистая нода). Создаю маркер-архив..."
    tar -czf "${ROLLBACK_FILE}" -T /dev/null
fi

if [ ! -s "${ROLLBACK_FILE}" ]; then
    echo "CRITICAL: rollback archive is empty!" >&2; exit 1
fi
ROLLBACK_CREATED=1

# 10. Остановка служб PVE. Смена фазы на DB_SWAP
PHASE="DB_SWAP"
echo "Каскадная остановка служб Proxmox VE..."
HIGH_LEVEL_SVCS=(pvedaemon pveproxy spiceproxy pve-ha-lrm pve-ha-crm)
for svc in "${HIGH_LEVEL_SVCS[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl reset-failed "$svc" 2>/dev/null || true
        [[ " ${OPTIONAL_SERVICES[*]} " =~ " ${svc} " ]] && STOPPED_OPTIONAL_SERVICES[$svc]=1
    fi
done
if systemctl is-active --quiet corosync 2>/dev/null; then
    systemctl stop corosync 2>/dev/null || true
    systemctl reset-failed corosync 2>/dev/null || true
    STOPPED_OPTIONAL_SERVICES[corosync]=1
fi

systemctl stop pve-cluster 2>/dev/null || true
systemctl reset-failed pve-cluster 2>/dev/null || true

if mountpoint -q /etc/pve; then umount -l /etc/pve || true; sleep 1; fi

if pgrep -x pmxcfs >/dev/null; then
    pkill -15 -x pmxcfs || true; sleep 2
    if pgrep -x pmxcfs >/dev/null; then pkill -9 -x pmxcfs || true; sleep 1; fi
fi

if mountpoint -q /etc/pve; then umount -f /etc/pve || true; fi

# 11. Атомарное обновление базы данных кластера
TARGET_DIR=$(dirname "$CONFIG_DB")
mkdir -p "$TARGET_DIR"

install -m 640 -o root -g www-data "${TEMP_DIR}/config_backup.db" "${TARGET_DIR}/config.db.new"
sync
mv -f "${TARGET_DIR}/config.db.new" "$CONFIG_DB"
sync

if ! sqlite3 "$CONFIG_DB" "PRAGMA integrity_check;" | grep -qx "ok"; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: База повреждена при финальном переносе!" >&2; exit 1
fi

# 12. ТОЧКА НЕВОЗВРАТА. Распаковка конфигурационных файлов в корень
if mountpoint -q /etc/pve; then
    echo "Unmounting pmxcfs before restore phase..."
    umount -l /etc/pve || true
fi

PHASE="UNPACKING"
RESTORE_STARTED=1

echo "Распаковка конфигурационных файлов в корень /..."
set +e
tar -xvzf "$BACKUP_FILE" -C / --exclude='config_backup.db' --exclude='etc/pve' --exclude='/etc/pve' --warning=no-file-changed
TAR_EXIT_CODE=$?
set -e

if [ "$TAR_EXIT_CODE" -gt 1 ]; then
    echo "Ошибка распаковки конфигурационных файлов (Fatal Tar Error)!" >&2; exit 1
fi

# 13. Запуск инфраструктуры и семантический аудит
PHASE="AUDIT"
echo "Запуск служб и проведение семантического аудита..."

for svc in "${MANDATORY_SERVICES[@]}"; do
    if systemctl cat "$svc".service &>/dev/null; then
        systemctl start "$svc" || { echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Не удалось запустить обязательную службу $svc!" >&2; exit 1; }
        
        if [ "$svc" = "pve-cluster" ]; then
            if ! timeout 15 bash -c 'until pvesh get /version &>/dev/null; do sleep 1; done'; then
                echo "КРИТИЧЕСКАЯ ОШИБКА: pmxcfs работает, но локальный API не отвечает!" >&2; exit 1
            fi
        fi
    fi
done

for svc in "${OPTIONAL_SERVICES[@]}"; do
    if [ "${STOPPED_OPTIONAL_SERVICES[$svc]:-0}" -eq 1 ]; then systemctl start "$svc" || true; fi
done

sleep 2
timeout 10 pvesh get /version &>/dev/null || { echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Локальный API PVE недоступен!" >&2; exit 1; }
timeout 10 pveum user list &>/dev/null || { echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Сбой валидации user.cfg!" >&2; exit 1; }
timeout 10 qm list &>/dev/null || { echo "🛑 КРИТИЧЕСКАЯ ОШИБКА: Подсистема QEMU не отвечает!" >&2; exit 1; }

# 14. Успешный финал транзакции
SUCCESS=1
rm -rf "${TEMP_DIR}" || true
touch /var/run/pve_restore_requires_reboot || true
trap - EXIT INT TERM

echo -e "\n========================================================================"
echo " 🔥 ВОССТАНОВЛЕНИЕ ОДИНОЧНОЙ НОДЫ УСПЕШНО ЗАВЕРШЕНО! 🔥"
echo " ТРЕБУЕТСЯ ОБЯЗАТЕЛЬНАЯ ПЕРЕЗАГРУЗКА: reboot"
echo " Страховочный архив исходного состояния: $ROLLBACK_FILE"
echo "========================================================================"
