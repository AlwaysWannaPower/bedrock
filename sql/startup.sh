#!/bin/bash

# ==============================================================================
# startup.sh
#
# Назначение:
#
#   1. Запустить SQL Server.
#   2. Дождаться его готовности.
#   3. Создать структуру БД.
#   4. Создать SQL Agent и ETL-процедуры.
#   5. Выполнить первичный ETL.
#   6. Настроить Database Mail для уведомлений.
#   7. Оставить SQL Server главным процессом контейнера.
#
# ВАЖНО:
#
#   SQL-файлы выполняются ПОСЛЕДОВАТЕЛЬНО.
#
#   Если любой SQL-файл завершился ошибкой:
#
#       sqlcmd
#           ↓
#       exit code != 0
#           ↓
#       pipefail
#           ↓
#       run_sql возвращает ошибку
#           ↓
#       set -e
#           ↓
#       startup.sh останавливается
#
# ==============================================================================


# ==============================================================================
# 0. РЕЖИМЫ BASH
# ==============================================================================

# Остановить скрипт при ошибке команды.
set -e

# Ошибка внутри pipeline тоже считается ошибкой.
#
# Например:
#
#   sqlcmd | tee
#
# Если sqlcmd упал, pipeline тоже будет считаться ошибочным.
set -o pipefail

# Показывать выполняемые команды.
# Очень удобно сейчас для отладки.
set -x


# ==============================================================================
# 1. НАСТРОЙКИ
# ==============================================================================

SCRIPTS_DIR="/var/opt/mssql/scripts"

LOGFILE="/tmp/startup.log"

SQLSERVER_LOG="/tmp/sqlservr.log"

MAX_ATTEMPTS=45

RETRY_INTERVAL=2


# ==============================================================================
# 2. ЛОГИРОВАНИЕ
# ==============================================================================

log()
{
    local timestamp

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] $1" | tee -a "$LOGFILE"
}


# ==============================================================================
# 3. ВЫПОЛНЕНИЕ SQL-ФАЙЛА
# ==============================================================================

run_sql()
{
    local sql_file="$1"
    
    # Проверяем, существует ли файл
    if [ ! -f "$sql_file" ]; then
        log "WARNING: SQL file not found: $sql_file"
        return 0
    fi

    log "============================================================"
    log "SQL SCRIPT START: $sql_file"
    log "============================================================"

    local start_time
    start_time=$(date +%s)


    # --------------------------------------------------------------------------
    # ВАЖНЫЕ ПАРАМЕТРЫ sqlcmd
    #
    # -S localhost
    #     SQL Server находится в этом же контейнере.
    #
    # -U sa
    #     пользователь SQL Server.
    #
    # -P
    #     пароль из Docker environment.
    #
    # -C
    #     доверять сертификату.
    #
    # -b
    #     КРИТИЧЕСКИ ВАЖНО.
    #
    #     Если SQL Server возвращает ошибку,
    #     sqlcmd завершится с ненулевым exit code.
    #
    #     Без -b у нас была проблема:
    #
    #         SQL Server -> Msg 2714
    #         sqlcmd    -> exit 0
    #         Bash      -> SUCCESS
    #
    # -i
    #     выполнить SQL-файл.
    #
    # -v
    #     передать переменные из окружения в SQL скрипт
    # --------------------------------------------------------------------------

    if /opt/mssql-tools18/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$MSSQL_SA_PASSWORD" \
        -C \
        -b \
        -v SMTP_SERVER="${SMTP_SERVER:-}" \
        -v SMTP_PORT="${SMTP_PORT:-587}" \
        -v SMTP_FROM_EMAIL="${SMTP_FROM_EMAIL:-dwh-alerts@example.com}" \
        -v SMTP_FROM_NAME="${SMTP_FROM_NAME:-DWH Alert System}" \
        -v SMTP_USERNAME="${SMTP_USERNAME:-}" \
        -v SMTP_PASSWORD="${SMTP_PASSWORD:-}" \
        -v ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}" \
        -i "$sql_file" \
        2>&1 | tee -a "$LOGFILE"
    then

        local end_time
        end_time=$(date +%s)

        local duration
        duration=$((end_time - start_time))

        log "SQL SCRIPT SUCCESS: $sql_file"
        log "Execution time: ${duration} sec"

    else

        local exit_code=$?

        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log "SQL SCRIPT FAILED: $sql_file"
        log "Exit code: $exit_code"
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

        return "$exit_code"

    fi
}


# ==============================================================================
# 4. ВЫПОЛНЕНИЕ SQL-КОМАНДЫ
# ==============================================================================

run_sql_query()
{
    local query="$1"
    
    # Определяем базу данных для запроса
    local database="${2:-BI_DWH}"

    log "============================================================"
    log "SQL QUERY START"
    log "Database: $database"
    log "Query: $query"
    log "============================================================"

    local start_time
    start_time=$(date +%s)


    # --------------------------------------------------------------------------
    # Здесь также ОБЯЗАТЕЛЬНО -b.
    #
    # Иначе:
    #
    #     EXEC etl.sp_master_etl
    #
    # может упасть внутри SQL Server,
    # но sqlcmd не сообщит Bash об ошибке.
    # --------------------------------------------------------------------------

    if /opt/mssql-tools18/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$MSSQL_SA_PASSWORD" \
        -C \
        -b \
        -d "$database" \
        -Q "$query" \
        2>&1 | tee -a "$LOGFILE"
    then

        local end_time
        end_time=$(date +%s)

        local duration
        duration=$((end_time - start_time))

        log "SQL QUERY SUCCESS"
        log "Execution time: ${duration} sec"

    else

        local exit_code=$?

        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log "SQL QUERY FAILED"
        log "Exit code: $exit_code"
        log "Query: $query"
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

        return "$exit_code"

    fi
}


# ==============================================================================
# 5. НАСТРОЙКА DATABASE MAIL (НОВАЯ ФУНКЦИЯ)
# ==============================================================================

configure_database_mail()
{
    log "============================================================"
    log "CONFIGURING DATABASE MAIL"
    log "============================================================"

    # Проверяем, заданы ли SMTP настройки
    if [ -z "${SMTP_SERVER:-}" ] || [ -z "${SMTP_USERNAME:-}" ] || [ -z "${SMTP_PASSWORD:-}" ]; then
        log "⚠️ SMTP настройки не заданы в .env"
        log "⚠️ Пропускаем настройку Database Mail (уведомления работать не будут)"
        log "⚠️ Для включения уведомлений добавьте в .env:"
        log "    SMTP_SERVER, SMTP_USERNAME, SMTP_PASSWORD"
        return 0
    fi

    log "✅ SMTP настройки найдены:"
    log "   Сервер: ${SMTP_SERVER}"
    log "   Порт: ${SMTP_PORT:-587}"
    log "   От: ${SMTP_FROM_EMAIL:-dwh-alerts@example.com}"
    log "   Кому: ${ADMIN_EMAIL:-admin@example.com}"

    # Ищем скрипт настройки Database Mail
    local mail_script="$SCRIPTS_DIR/00_configure_database_mail.sql"
    
    if [ ! -f "$mail_script" ]; then
        log "⚠️ Файл $mail_script не найден"
        log "⚠️ Создаю встроенный скрипт настройки..."
        
        # Создаем временный скрипт с настройками
        mail_script="/tmp/configure_mail.sql"
        cat > "$mail_script" <<'EOF'
-- ============================================================================
-- Встроенный скрипт настройки Database Mail
-- ============================================================================

USE master;
GO

PRINT '🔧 Настройка Database Mail...';

-- Включаем Database Mail
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
GO

-- Удаляем старые настройки
DECLARE @profile_id INT, @account_id INT;

SELECT @profile_id = profile_id FROM msdb.dbo.sysmail_profile WHERE name = 'DWH_Alerts';
IF @profile_id IS NOT NULL
BEGIN
    DELETE FROM msdb.dbo.sysmail_profileaccount WHERE profile_id = @profile_id;
    DELETE FROM msdb.dbo.sysmail_profile WHERE profile_id = @profile_id;
END

DELETE FROM msdb.dbo.sysmail_account WHERE name = 'SMTP_Account';

-- Создаем SMTP аккаунт
INSERT INTO msdb.dbo.sysmail_account (
    name, description, email_address, display_name, replyto_address,
    mailserver_name, mailserver_type, port, username, password,
    use_default_credentials, enable_ssl
)
VALUES (
    'SMTP_Account',
    'SMTP аккаунт для DWH уведомлений',
    '$(SMTP_FROM_EMAIL)',
    '$(SMTP_FROM_NAME)',
    '$(SMTP_FROM_EMAIL)',
    '$(SMTP_SERVER)',
    0,
    $(SMTP_PORT),
    '$(SMTP_USERNAME)',
    '$(SMTP_PASSWORD)',
    0,
    1
);

SET @account_id = SCOPE_IDENTITY();

-- Создаем профиль
INSERT INTO msdb.dbo.sysmail_profile (name, description)
VALUES ('DWH_Alerts', 'Профиль для ETL уведомлений');

SET @profile_id = SCOPE_IDENTITY();

-- Привязываем аккаунт
INSERT INTO msdb.dbo.sysmail_profileaccount (profile_id, account_id, sequence_number)
VALUES (@profile_id, @account_id, 1);

-- Делаем профиль публичным
EXEC msdb.dbo.sysmail_add_principalprofile_sp
    @profile_name = 'DWH_Alerts',
    @principal_name = 'public',
    @is_default = 1;

PRINT '✅ Database Mail настроен!';

-- Отправляем тестовое письмо
BEGIN TRY
    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'DWH_Alerts',
        @recipients = '$(ADMIN_EMAIL)',
        @subject = '✅ Database Mail настроен в Docker',
        @body = 'ETL уведомления настроены!';
    PRINT '✅ Тестовое письмо отправлено';
END TRY
BEGIN CATCH
    PRINT '⚠️ Ошибка отправки: ' + ERROR_MESSAGE();
END CATCH
GO
EOF
    fi

    # Выполняем скрипт настройки
    run_sql "$mail_script"
    
    # Проверяем, что настройка прошла успешно
    log "🔍 Проверка Database Mail..."
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -Q "
        SELECT 
            COUNT(*) AS ProfileCount 
        FROM msdb.dbo.sysmail_profile 
        WHERE name = 'DWH_Alerts'
    " 2>&1 | tee -a "$LOGFILE"
}


# ==============================================================================
# 6. НАЧАЛО STARTUP
# ==============================================================================

log "============================================================"
log "STARTUP SCRIPT STARTED"
log "============================================================"

log "Scripts directory: $SCRIPTS_DIR"
log "Startup log:       $LOGFILE"
log "SQL Server log:    $SQLSERVER_LOG"


# ==============================================================================
# 7. ПРОВЕРЯЕМ ПАРОЛЬ
# ==============================================================================

if [ -z "${MSSQL_SA_PASSWORD:-}" ]; then

    log "ERROR: MSSQL_SA_PASSWORD is not set."

    exit 1

fi


# ==============================================================================
# 8. ЗАПУСК SQL SERVER
# ==============================================================================

log "============================================================"
log "STARTING SQL SERVER"
log "============================================================"


/opt/mssql/bin/sqlservr \
    > "$SQLSERVER_LOG" \
    2>&1 &

SQL_PID=$!

log "SQL Server started."
log "SQL Server PID: $SQL_PID"


# ==============================================================================
# 9. ЖДЁМ ГОТОВНОСТИ SQL SERVER
# ==============================================================================

log "============================================================"
log "WAITING FOR SQL SERVER"
log "============================================================"

READY=0


for i in $(seq 1 "$MAX_ATTEMPTS")
do

    # --------------------------------------------------------------------------
    # Проверяем, что процесс SQL Server всё ещё существует.
    # --------------------------------------------------------------------------

    if ! kill -0 "$SQL_PID" 2>/dev/null
    then

        log "ERROR: SQL Server process died."

        log "========== SQL SERVER LOG =========="

        cat "$SQLSERVER_LOG" | tee -a "$LOGFILE"

        log "========== END SQL SERVER LOG ======"

        exit 1

    fi


    # --------------------------------------------------------------------------
    # Проверяем, что SQL Server уже принимает запросы.
    # --------------------------------------------------------------------------

    if /opt/mssql-tools18/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$MSSQL_SA_PASSWORD" \
        -C \
        -b \
        -Q "SELECT 1" \
        > /dev/null \
        2>&1
    then

        log "SQL Server is READY."

        log "Ready after attempt: $i/$MAX_ATTEMPTS"

        READY=1

        break

    fi


    log "SQL Server is not ready yet. Attempt $i/$MAX_ATTEMPTS"

    sleep "$RETRY_INTERVAL"

done


# ==============================================================================
# 10. ЕСЛИ SQL SERVER НЕ ГОТОВ
# ==============================================================================

if [ "$READY" -ne 1 ]
then

    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "ERROR: SQL Server startup timeout."
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    log "========== SQL SERVER LOG =========="

    cat "$SQLSERVER_LOG" | tee -a "$LOGFILE"

    log "========== END SQL SERVER LOG ======"

    exit 1

fi


# ==============================================================================
# 11. НАСТРОЙКА DATABASE MAIL (НОВЫЙ ЭТАП)
# ==============================================================================

# Настраиваем Database Mail до создания БД (или после - не критично)
# Лучше сделать до, чтобы уведомления были готовы сразу
configure_database_mail


# ==============================================================================
# 12. СОЗДАНИЕ БД / ТАБЛИЦ / ПРОЦЕДУР / AGENT
# ==============================================================================

log "============================================================"
log "STARTING DATABASE INITIALIZATION"
log "============================================================"


# --------------------------------------------------------------------------
# ПОРЯДОК ИМЕЕТ ЗНАЧЕНИЕ
#
# Сначала schema (включая etl.config для уведомлений)
#    ↓
# затем agent
#    ↓
# затем elt
#    ↓
# затем views
# --------------------------------------------------------------------------

for stage in schema agent elt views
do

    STAGE_DIR="$SCRIPTS_DIR/$stage"


    if [ ! -d "$STAGE_DIR" ]
    then

        log "Stage '$stage' does not exist. Skipping."

        continue

    fi


    log "============================================================"
    log "STAGE START: $stage"
    log "============================================================"


    # --------------------------------------------------------------------------
    # Получаем SQL-файлы.
    #
    # Например:
    #
    # schema/
    #
    #   01_create_schemas.sql
    #   02_staging_tables.sql
    #   03_ods_tables.sql
    #   04_dwh_dimensions.sql
    #   05_fact_tables.sql
    #   06_config_table.sql      <-- НОВЫЙ файл для etl.config
    #
    # sort гарантирует порядок.
    # --------------------------------------------------------------------------

    SQL_FILES=$(find "$STAGE_DIR" \
        -maxdepth 1 \
        -type f \
        -name "*.sql" \
        | sort)


    if [ -z "$SQL_FILES" ]
    then

        log "No SQL files found in stage '$stage'."

        continue

    fi


    # --------------------------------------------------------------------------
    # Каждый SQL-файл выполняется отдельно.
    #
    # Bash ждёт окончания одного файла.
    #
    # Поэтому:
    #
    #     01
    #      ↓
    #     SUCCESS
    #      ↓
    #     02
    #      ↓
    #     SUCCESS
    #      ↓
    #     03
    #
    # Если 02 упал:
    #
    #     01 SUCCESS
    #     02 FAILED
    #     03 НЕ ЗАПУСКАЕТСЯ
    #
    # благодаря:
    #
    #     set -e
    #     pipefail
    #     sqlcmd -b
    # --------------------------------------------------------------------------

    while IFS= read -r sql_file
    do

        run_sql "$sql_file"

    done <<< "$SQL_FILES"


    log "STAGE SUCCESS: $stage"

done


# ==============================================================================
# 13. ДОБАВЛЯЕМ НАСТРОЙКИ В etl.config (НОВЫЙ ШАГ)
# ==============================================================================

log "============================================================"
log "UPDATING ETL CONFIGURATION"
log "============================================================"

# Проверяем, существует ли таблица etl.config
if /opt/mssql-tools18/bin/sqlcmd \
    -S localhost \
    -U sa \
    -P "$MSSQL_SA_PASSWORD" \
    -C \
    -b \
    -d BI_DWH \
    -Q "IF OBJECT_ID('etl.config', 'U') IS NOT NULL SELECT 1 ELSE SELECT 0" \
    -h -1 \
    2>/dev/null | grep -q "1"
then
    log "✅ Таблица etl.config существует, обновляем настройки..."
    
    # Добавляем администратора и профиль Database Mail
    /opt/mssql-tools18/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$MSSQL_SA_PASSWORD" \
        -C \
        -b \
        -d BI_DWH \
        -Q "
            -- Обновляем email администратора
            MERGE etl.config AS target
            USING (SELECT 'admin_email' AS config_key, '${ADMIN_EMAIL:-admin@example.com}' AS config_value) AS source
            ON target.config_key = source.config_key
            WHEN MATCHED THEN UPDATE SET config_value = source.config_value
            WHEN NOT MATCHED THEN INSERT (config_key, config_value) VALUES (source.config_key, source.config_value);

            -- Обновляем профиль Database Mail
            MERGE etl.config AS target
            USING (SELECT 'dbmail_profile' AS config_key, 'DWH_Alerts' AS config_value) AS source
            ON target.config_key = source.config_key
            WHEN MATCHED THEN UPDATE SET config_value = source.config_value
            WHEN NOT MATCHED THEN INSERT (config_key, config_value) VALUES (source.config_key, source.config_value);

            -- Добавляем настройки SMTP (для справки)
            MERGE etl.config AS target
            USING (SELECT 'smtp_server' AS config_key, '${SMTP_SERVER:-not_configured}' AS config_value) AS source
            ON target.config_key = source.config_key
            WHEN MATCHED THEN UPDATE SET config_value = source.config_value
            WHEN NOT MATCHED THEN INSERT (config_key, config_value) VALUES (source.config_key, source.config_value);

            -- Добавляем флаг, что уведомления настроены
            MERGE etl.config AS target
            USING (SELECT 'notifications_enabled' AS config_key, 
                          CASE WHEN '${SMTP_SERVER:-}' != '' AND '${SMTP_USERNAME:-}' != '' 
                               THEN '1' ELSE '0' END AS config_value) AS source
            ON target.config_key = source.config_key
            WHEN MATCHED THEN UPDATE SET config_value = source.config_value
            WHEN NOT MATCHED THEN INSERT (config_key, config_value) VALUES (source.config_key, source.config_value);

            PRINT '✅ ETL конфигурация обновлена';
        " 2>&1 | tee -a "$LOGFILE"
else
    log "⚠️ Таблица etl.config не найдена, пропускаем обновление настроек"
fi


# ==============================================================================
# 14. ИНИЦИАЛИЗАЦИЯ СТРУКТУРЫ ЗАВЕРШЕНА
# ==============================================================================

log "============================================================"
log "DATABASE INITIALIZATION COMPLETED"
log "============================================================"


# ==============================================================================
# 15. ПЕРВИЧНЫЙ ETL
# ==============================================================================

log "============================================================"
log "STARTING MASTER ETL"
log "============================================================"


ETL_START=$(date +%s)


# --------------------------------------------------------------------------
# Именно здесь запускается твой pipeline.
#
# Первый шаг:
#
#     sp_load_staging_from_import
#
#     Файлы
#       ↓
#     file_registry
#       ↓
#     BULK INSERT
#       ↓
#     staging
#
# Второй шаг:
#
#     sp_etl_master
#
#     staging
#       ↓
#     quarantine
#     ods
#       ↓
#     dimensions
#       ↓
#     facts
#       ↓
#     datamart
# --------------------------------------------------------------------------

# Оборачиваем ETL в TRY...CATCH для отправки уведомлений при ошибке
run_sql_query "
DECLARE @etl_error NVARCHAR(MAX) = NULL;

BEGIN TRY
    EXEC etl.sp_load_staging_from_import;
    EXEC etl.sp_etl_master;
END TRY
BEGIN CATCH
    SET @etl_error = CONCAT(
        'Ошибка ETL: ', ERROR_NUMBER(), ' - ', ERROR_MESSAGE(),
        CHAR(10), 'Процедура: ', ERROR_PROCEDURE(),
        CHAR(10), 'Строка: ', ERROR_LINE()
    );
    
    -- Логируем в alert_queue (через вашу процедуру)
    IF OBJECT_ID('etl.sp_notify_admin', 'P') IS NOT NULL
    BEGIN
        EXEC etl.sp_notify_admin 
            @subject = N'❌ ETL FAILED при инициализации',
            @body = @etl_error;
    END
    
    -- Пробрасываем ошибку дальше
    THROW;
END CATCH
" BI_DWH


ETL_END=$(date +%s)

ETL_DURATION=$((ETL_END - ETL_START))


log "============================================================"
log "MASTER ETL COMPLETED"
log "ETL execution time: ${ETL_DURATION} sec"
log "============================================================"


# ==============================================================================
# 16. ОТПРАВЛЯЕМ УВЕДОМЛЕНИЕ ОБ УСПЕШНОМ ЗАПУСКЕ
# ==============================================================================

log "============================================================"
log "SENDING STARTUP NOTIFICATION"
log "============================================================"

# Отправляем уведомление об успешном запуске (если настроен Database Mail)
if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${SMTP_SERVER:-}" ]; then
    /opt/mssql-tools18/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$MSSQL_SA_PASSWORD" \
        -C \
        -b \
        -d BI_DWH \
        -Q "
            DECLARE @body NVARCHAR(MAX) = CONCAT(
                '✅ DWH инициализирован успешно!',
                CHAR(10), 'Время запуска: ', SYSDATETIME(),
                CHAR(10), 'Длительность ETL: ${ETL_DURATION} сек',
                CHAR(10), 'Контейнер: ${HOSTNAME:-unknown}',
                CHAR(10), '---------------------------',
                CHAR(10), 'Все системы готовы к работе.'
            );
            
            IF OBJECT_ID('etl.sp_notify_admin', 'P') IS NOT NULL
            BEGIN
                EXEC etl.sp_notify_admin 
                    @subject = N'✅ DWH инициализирован',
                    @body = @body;
            END
            ELSE
            BEGIN
                -- Запасной вариант: прямая отправка
                EXEC msdb.dbo.sp_send_dbmail
                    @profile_name = 'DWH_Alerts',
                    @recipients = '${ADMIN_EMAIL}',
                    @subject = N'✅ DWH инициализирован',
                    @body = @body;
            END
        " 2>&1 | tee -a "$LOGFILE" || log "⚠️ Не удалось отправить уведомление о запуске"
else
    log "⚠️ SMTP не настроен, уведомления не отправлены"
fi


# ==============================================================================
# 17. УСПЕШНАЯ ИНИЦИАЛИЗАЦИЯ
# ==============================================================================

log "============================================================"
log "STARTUP INITIALIZATION SUCCESSFUL"
log "============================================================"


# ==============================================================================
# 18. ОСТАВЛЯЕМ SQL SERVER РАБОТАТЬ
# ==============================================================================

log "SQL Server is running."
log "Waiting for SQL Server process..."
log "SQL Server PID: $SQL_PID"


# SQL Server — главный процесс контейнера.
#
# Пока он работает:
#
#     Docker container работает.
#
# Если SQL Server завершится:
#
#     wait вернёт его exit code
#     ↓
#     контейнер завершится.
#

wait "$SQL_PID"

EXIT_CODE=$?

log "SQL Server stopped with exit code: $EXIT_CODE"

exit "$EXIT_CODE"