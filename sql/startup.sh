#!/bin/bash --файл нужно выполнять через Bash.
# ==============================================================================
# startup.sh — запуск SQL Server + автоинициализация DWH + первичная загрузка CSV
# Порядок: schema → elt → views → sp_load_staging_from_import + sp_etl_master
# ==============================================================================
set -e # Если команда завершилась с ошибкой — Bash должен остановить скрипт.
set -x # Bash начинает печатать выполняемые команды в лог:

SCRIPTS_DIR="/var/opt/mssql/scripts"
LOGFILE="/tmp/startup.log"

echo "=== STARTUP SCRIPT STARTED at $(date) ===" | tee -a "$LOGFILE"

# 1. SQL Server в фоне
echo "Starting sqlservr..." | tee -a "$LOGFILE"
/opt/mssql/bin/sqlservr > /tmp/sqlservr.log 2>&1 &
SQL_PID=$!  # Запусти процесс в фоне и не жди его завершения. Процесс работает в фоне, 
#а мы идем дальше по скриту, сохраняем номер процесса в переменную

# 2. Ждём готовности (до 90 сек)
READY=0
for i in $(seq 1 45); do
    if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" > /dev/null 2>&1; then
        echo "SQL Server ready!" | tee -a "$LOGFILE"
        READY=1
        break
    fi
    if ! kill -0 "$SQL_PID" 2>/dev/null; then
        echo "sqlservr crashed!" | tee -a "$LOGFILE"
        cat /tmp/sqlservr.log | tee -a "$LOGFILE"
        exit 1
    fi
    echo "  ...attempt $i/45" | tee -a "$LOGFILE"
    sleep 2
done

if [ "$READY" -eq 0 ]; then
    echo "SQL Server timeout" | tee -a "$LOGFILE"
    exit 1
fi
##
# Ниже две функции для упрощения. Каждая получает один аргумент, и клиентом подключается к бд.  
# Первая = -i Ожидает путь скрипта и выполняет его
# Вторая = -Q ожидает скль команду
##
run_sql() {
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -i "$1" 2>&1 | tee -a "$LOGFILE"
}

run_sql_query() {
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "$1" 2>&1 | tee -a "$LOGFILE"
}

# 3. DDL + процедуры + витрины (порядок по именам файлов)
# По очереди обработай три папки schema agent elt views (добавить агент папку)
# sql/
# ├── schema/
# ├── agent/
# ├── elt/
# └── views/
# Далее
# if [ -d "$SCRIPTS_DIR/$stage" ]; then
# Пример: stage = schema,  получается  /var/opt/mssql/scripts/schema
# --- Если папка существует — идём внутрь. 
# Далее
# Найди все .sql файлы в текущей папке и отсортируй их.
# 
# 
# 

for stage in schema elt agent views; do # По очереди обработай 4 папки
    if [ -d "$SCRIPTS_DIR/$stage" ]; then # --- Если папка существует — идём внутрь. 
        echo "Stage: $stage" | tee -a "$LOGFILE"
        for f in $(ls "$SCRIPTS_DIR/$stage"/*.sql 2>/dev/null | sort); do # Найди все .sql файлы в текущей папке и отсортируй их.
            echo "  >> $f" | tee -a "$LOGFILE"
            run_sql "$f" || echo "  WARN: error in $f" | tee -a "$LOGFILE" # Функция run_sql выполняет каждый файл.
        done
    fi
done
# -- ============================================================================
# -- Все схемы, таблицы, хранимые процедуры загружены
# -- 
# -- Вызываем храним.процедуры        
# -- ============================================================================
# 4. Первичная / инкрементальная загрузка CSV из /import
sleep 10
echo "Running ETL pipeline..." | tee -a "$LOGFILE"
run_sql_query "EXEC BI_DWH.elt.sp_load_staging_from_import;"

# echo "Initialization complete!" | tee -a "$LOGFILE"

# 5. Удерживаем контейнер живым
echo "Handing over to sqlservr (PID $SQL_PID)..." | tee -a "$LOGFILE"
wait "$SQL_PID" # Жди завершения SQL Server.
#
# startup.sh
#     │
#     ├── SQL Server запустился
#     ├── SQL Server готов
#     ├── DDL выполнен
#     ├── ETL выполнен
#     │
#     └── wait SQL Server
#               │
#               │
#               └── контейнер продолжает жить
exit $? # вернёт код завершения SQL Server.
