# BI_DWH — аналитическая система учёта запасов и оборачиваемости материалов

Проект реализует классическое хранилище данных **DWH + BI по методологии Кимбалла**:

- **MS SQL Server 2022** — целевая СУБД: все этапы ETL/ELT, очистка данных, историчность справочников (SCD), расчёт метрик и витрин выполняются строго на стороне СУБД.
- **Apache Superset 6.1.0** — тонкий BI-клиент: только отображение, кеширование запрещено, Live-запросы к готовым витринам.
- **Docker Compose** — развёртывание всей системы **одной командой**.

---

## 1. Быстрый старт (развёртывание одной командой)

```bash
# 1. Скопировать пример конфигурации и при необходимости поменять значения
cp .env.example .env
#    ⚠️ ВАЖНО: MSSQL_SA_PASSWORD и SUPERSET_SECRET_KEY должны совпадать с теми,
#    что были у того, кто создавал backups/superset_data.tar.gz,
#    иначе Superset не сможет расшифровать подключение к MSSQL из своего volume.

# 2. [РЕКОМЕНДУЕТСЯ] Привязать предзаполненный volume Superset из архива backups/.
#    В архиве: роли, учётки, RLS-правила, дашборд, чарты, datasets
#    и подключение к MSSQL — ничего настраивать не нужно.
#    (Пропусти шаг — Superset поднимется «пустым», только с admin.)
docker compose down -v                                   # чистый старт: стирает старые volume
docker volume create "$(basename "$PWD")_superset_data"   # имя = <имя папки проекта>_superset_data
docker run --rm \
  -v "$(basename "$PWD")_superset_data:/dest" \
  -v "$(pwd)/backups/superset_data.tar.gz:/backup/superset_data.tar.gz:ro" \
  alpine tar xzf /backup/superset_data.tar.gz -C /dest

# 3. Запустить ВСЮ систему (SQL Server + конвертер + Superset)
docker compose up -d --build

# 4. Дождаться готовности (первый запуск: скачивание образов + ETL, 10–15 минут;
#    данные BI_DWH mssql создаст сам, а Superset с архивом готов сразу)
docker compose logs -f mssql
```

> **⚠️ Про исходные данные и структуру файлов:**
> - Исходные `excel`-файлы (`data/excel/{turnover,prices,warehouses}/`) в git **не хранятся**
>   (в `.gitignore`) — их передают отдельно и кладут в `data/excel/...`.
> - Сервис **Converter** превращает `xlsx` → `csv`, копируя структуру каталогов
>   (`data/excel/x/y/f.xlsx` → `data/csv/x/y/f.csv`, разделитель `;`, кодировка UTF-16).
> - ETL в SQL Server читает `csv` только из трёх папок `data/csv/`:
>```text
>data/csv/turnover/*.csv
>data/csv/prices/*.csv
>data/csv/warehouses/*.csv
>```
> - Поэтому `excel` кладут в соответствующую подпапку `data/excel/turnover|prices|warehouses`.

**Если система уже запускалась без архива** (volume `*_superset_data` уже существует) —
`down -v` не нужен, достаточно перезалить архив в существующий volume:

```bash
docker compose stop superset
SUPERSET_VOL=$(docker volume ls -q | grep '_superset_data$' | head -1)
docker run --rm \
  -v "$SUPERSET_VOL:/dest" \
  -v "$(pwd)/backups/superset_data.tar.gz:/backup/superset_data.tar.gz:ro" \
  alpine tar xzf /backup/superset_data.tar.gz -C /dest
docker compose start superset
```

> **💡 Имя volume зависит от имени папки проекта.** Если клонируешь репозиторий не в папку
> `bedrock` (или задан `COMPOSE_PROJECT_NAME`), подставь `<имя-папки>_superset_data` в команды
> выше либо задай единое имя: `export COMPOSE_PROJECT_NAME=bedrock` перед всеми `docker compose ...`.

> **💡 Как проверить, что volume подхватился:** открой http://localhost:8088 и войди под любой
> учёткой из архива: `admin@example.com` / `admin`, либо демо-роли (`gen_dir@gmail.com`,
> `dir_directorate@gmail.com`, `manager@gmail.com`, `shop@gmail.com`, `warehouse@gmail.com`, пароль `12345678`).
> У каждой роли — своя RLS-зона (см. `docs/Дашборд: фильтры, скопы и доступ.md`).

После завершения инициализации в логе появится:

```text
STARTUP INITIALIZATION SUCCESSFUL
```

Проверить готовность:

```bash
docker compose ps                     # все контейнеры в статусе Up / healthy
docker compose logs mssql | tail -50  # лог инициализации и ETL
```

**Что происходит при старте** (см. `sql/startup.sh`):

```text
Docker
  │
  ▼
startup.sh
  ├── запуск SQL Server
  ├── ожидание готовности (SELECT 1)
  ├── schema/*.sql        — схемы и таблицы
  ├── agent/*.sql         — SQL Agent job (ночной запуск)
  ├── elt/*.sql           — ETL-процедуры + настройка почты
  ├── datamart/*.sql      — витрины и процедура их пересчёта
  ├── views/*.sql         — представления для Superset
  ├── mail/*.sql          — тестовое письмо (один раз)
  ├── EXEC elt.sp_master_etl   — первичная загрузка всех данных
  └── ожидание SQL Server (контейнер жив)
```

---

## 2. Структура репозитория

```text
.
├── docker-compose.yaml      # оркестрация: mssql + superset + converter
├── .env.example             # шаблон конфигурации (пароли, SMTP, Superset)
│
├── sql/
│   ├── startup.sh           # entrypoint контейнера SQL Server
│   ├── schema/              # DDL: схемы, таблицы, индексы, календарь
│   ├── agent/               # SQL Agent job (ночная загрузка 02:00)
│   ├── elt/                 # ETL-процедуры (загрузка, валидация, DWH, почта)
│   ├── datamart/            # витрины данных + процедура пересчёта
│   ├── views/               # представления витрин для Superset
│   └── mail/                # тестовое письмо при первом старте
│
├── converter/               # Python-конвертер Excel → CSV (Polars)
├── superset/                # конфигурация Apache Superset (Dockerfile, superset_config.py)
├── dashboard/               # скриншоты дашборда + ZIP-экспорт из Superset
├── backups/                 # архив volume Superset (роли, учётки, RLS, дашборд) — см. §1
├── data/                    # исходные данные (в git не хранятся)
│   ├── excel/               #   исходные XLSX (кладут сюда)
│   └── csv/                 #   CSV для загрузки (монтируется в /import)
│
└── docs/                    # документация
    ├── README.md            # индекс документации
    ├── Архитектура.md       # архитектура, слои, ER-диаграмма, обоснование
    ├── Руководство пользователя.md
    ├── Сборка дашборда в Superset.md
    ├── Рецепты чартов.md
    ├── Дашборд: фильтры, скопы и доступ.md
    ├── архитектура.png      # схема архитектуры (по ТЗ)
    └── Отчёт_реализация_BI_DWH.docx   # Word-файл описания (по ТЗ)
```

---

## 3. Архитектура и поток данных

```text
            EXCEL (.xlsx)
               │
               ▼
       CSV CONVERTER        Python + Polars
               │
               ▼
          STAGING           сырой слой (как в файле, всё NVARCHAR)
               │
           VALIDATION        проверки типов, дат, бизнес-правил
               │
      ┌────────┴────────┐
      ▼                 ▼
 QUARANTINE           ODS
 ошибочные строки      очищенные данные
      │                 │
      │                 ▼
      │          DWH Kimball (звезда)
      │                 │
      │      DIM_DATE ─ FACT_INVENTORY ─ DIM_MATERIAL
      │            └──── FACT_PRICES ──── DIM_WAREHOUSE (SCD2)
      │                 │
      │                 ▼
      │           DATAMART (витрины: метрики + MoM)
      │                 │
      │                 ▼
      └────────── Apache Superset (Live, без кеша)
```

**Слои базы данных** (`BI_DWH`):

| Схема | Назначение |
|---|---|
| `staging` | Сырые данные из CSV, как пришли от заказчика |
| `quarantine` | Строки с ошибками: исходные значения + причина |
| `ods` | Очищенные, типизированные, валидированные данные |
| `dwh` | Модель Кимбалла: измерения, факты, суррогатные ключи, SCD |
| `datamart` | Готовые витрины с метриками для BI |
| `elt` | Служебный слой: реестр файлов, журналы, алерты |

---

## 4. ETL-пайплайн

Главная процедура: `elt.sp_master_etl` (файл `sql/elt/99_sp_master_etl.sql`).

```text
 0. elt.sp_load_staging_from_import   CSV → STAGING (инкрементально, file_registry)
 1. elt.sp_validate_turnover          STAGING → QUARANTINE / ODS (оборотки)
 2. elt.sp_validate_prices            STAGING → QUARANTINE / ODS (цены)
 3. elt.sp_validate_warehouses        STAGING → QUARANTINE / ODS (склады)
 4. dwh.sp_load_dim_material          ODS → DIM_MATERIAL (SCD1)
 5. dwh.sp_load_dim_warehouse         ODS → DIM_WAREHOUSE (SCD2)
 6. dwh.sp_load_fact_inventory        ODS → FACT_INVENTORY (последняя версия)
 7. dwh.sp_load_fact_prices           ODS → FACT_PRICES (последняя версия)
 8. datamart.sp_refresh_datamart      DWH → DATAMART (метрики + MoM)
```

**Инкрементальная загрузка**:

- `elt.file_registry` хранит SHA-256 каждого файла.
- Новый файл → загружается; тот же файл (тот же hash) → пропускается;
- изменённый файл (hash отличается) → перезагружается;
- повторный запуск ETL **не создаёт дубликатов** (проверено, см. отчёт о проверке).

**Карантин**: строка с ошибкой не останавливает ETL — она уходит в `quarantine.*` с причиной, корректные строки продолжают путь в ODS.

**Даты**: поддерживаются два формата — числовой (Excel Serial Date, `45292` → `2024-01-01`) и обычный текстовый (`2024-01-31`, `31.01.2024`). Логика в функции `elt.fn_parse_date`.

**Логирование** (`elt.elt_log`): каждый шаг фиксируется со статусом `RUNNING / SUCCESS / ERROR`, временем старта/завершения и текстом ошибки. При падении ETL дополнительно:

1. пишется алерт в `elt.alert_queue` (не зависит от почты);
2. отправляется письмо администратору (Database Mail, если SMTP настроен).

---

## 5. Витрины данных (для Superset)

| Объект | Назначение |
|---|---|
| `datamart.vw_turnover_metrics` | KPI по уровням срезов + MoM (главная витрина дашборда) |
| `datamart.vw_inventory_monthly` | Детализация: месяц × склад × материал |
| `datamart.vw_warehouse_hierarchy` | Справочник складов для иерархии фильтров |

Уровни срезов (`agg_level`) соответствуют ролям из ТЗ:

| `agg_level` | Роль |
|---|---|
| `company` | Генеральный директор (вся компания) |
| `directorate` | Директор по производству / закупкам (своя дирекция); менеджер по закупкам (срез «дирекция закупок») |
| `shop` | Начальник цеха |
| `warehouse` | Начальник склада |

**Метрики (формулы):**

| Метрика | Формула |
|---|---|
| Сумма запасов | `stock_value = Σ (остаток_на_конец × цена_периода)` |
| Средний остаток | `avg_qty = (остаток_начало + остаток_конец) / 2`, `avg_stock_value = avg_qty × цена` |
| Оборачиваемость в разах | `turnover_ratio = расход_в_деньгах / средний_остаток` |
| Оборачиваемость в днях | `turnover_days = 30 × средний_остаток / расход_в_деньгах` |
| MoM | `mom = (значение_этого_месяца − значение_прошлого) / значение_прошлого` |

---

## 6. Ночной запуск (SQL Agent)

SQL Agent job `BI_DWH_Nightly_ETL` запускается **каждый день в 02:00** и выполняет:

```sql
EXEC BI_DWH.elt.sp_master_etl;
```

Загрузка staging (`elt.sp_load_staging_from_import`) — шаг 0 внутри `sp_master_etl`,
поэтому любой сбой ночного прогона (включая сбой загрузки файлов) попадает в
`elt.elt_log`, `elt.alert_queue` и отправляется администратору по почте.

Включить Agent можно в `.env`: `MSSQL_AGENT_ENABLED=True`.

---

## 7. Уведомления (Database Mail)

Настройки SMTP задаются в `.env`:

```text
SMTP_SERVER=smtp.yandex.ru
SMTP_PORT=587
SMTP_FROM_EMAIL=...
SMTP_USERNAME=...
SMTP_PASSWORD=...
ADMIN_EMAIL=...
```

- При первом старте контейнера отправляется **тестовое письмо** (один раз).
- При падении ETL администратору уходит письмо `BI_DWH: ELT FAILED`.
- Если почта не настроена — система работает, алерты копятся в `elt.alert_queue`.

Проверка отправленных писем:

```sql
SELECT TOP 20 mailitem_id, recipients, subject, sent_status, send_request_date
FROM msdb.dbo.sysmail_allitems
ORDER BY send_request_date DESC;
```

---

## 8. Документация

- `docs/README.md` — индекс документации
- `docs/Архитектура.md` — архитектура, слои БД, ER-диаграмма, обоснование решений
- `docs/Руководство пользователя.md` — руководство пользователя (для заказчика)
- `docs/Сборка дашборда в Superset.md`, `docs/Рецепты чартов.md` — сборка дашборда
- `docs/Дашборд: фильтры, скопы и доступ.md` — фильтры, роли и RLS
- `docs/архитектура.png` — схема архитектуры (формат сдачи по ТЗ)
- `docs/Отчёт_реализация_BI_DWH.docx` — Word-файл описания архитектуры (формат сдачи по ТЗ)

