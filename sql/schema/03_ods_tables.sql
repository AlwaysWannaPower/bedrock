-- ============================================================================
-- Файл: 03_ods_tables.sql
-- Описание: Очищенные таблицы (ODS - Operational Data Store)
--           Данные проходят валидацию при загрузке через ETL.
--           В таблицах только СХЕМА данных, без индексов и ETL-логики.
-- ============================================================================
-- Отличие от STAGING:
--   1. Убраны служебные поля: file_name, date_loaded (они не нужны в очищенных данных)
--   2. Добавлен staging_load_id (ссылка на исходную запись в staging)
--   3. Поля с NOT NULL (обязательные поля, которые должны быть заполнены)
--   4. Добавлены CHECK-ограничения для защиты от невалидных данных
--   5. Добавлен бизнес-ключ (уникальность записей)
--   6. Добавлены поля для SCD Type 2 (версионирование)
-- ============================================================================
-- SCD Type 2 
-- Что есть медленное версионирование измерения?
-- Это измерения (справочники), которые меняются со временем, но не часто.
-- У меня есть таблица Склад, Оборотная Ведемость, Цена материала 
-- По Кимбалу звезда собирается из фактов и измерений справочники. 
-- Факты это обычно численные величина 
-- А справочники - текст и тд
-- То есть примерная таблица это набор величин и внешние ключи на другие таблицы(справочники)
-- 
-- SCD Type 2  валиден для всех трех таблиц
-- 
-- Таблица цен -цены меняются от месяца к месяцу, а у нас 2 года
-- Таблица Складов - там меняются сотрудники склады и тд.
-- Оборотная ведомость -- тут уже менее явно, и она больше как таблица фактов. Но в оборотке тоже есть исторические данные, и, предварительно, рассмотрим 
-- версионоировапние и для нее
-- turnover_clean — каждая запись УЖЕ уникальна по периоду
-- (material_id, warehouse_code, start_date, end_date)
-- Это исторические данные "как было в том месяце"
-- SCD Type 2 здесь для версионирования загрузки
-- prices_clean — каждая запись УЖЕ уникальна по периоду
-- (material_id, start_date, end_date)  
-- Это история цен "какая цена была в том месяце"
-- warehouses_clean — ЗДЕСЬ SCD Type 2 НУЖЕН БОЛЬШЕ ВСЕГО!
-- Склад WH001 может изменить тип с "Склад ГП" на "Склад сырья"
-- Без SCD Type 2 мы потеряем информацию о том, каким был склад раньше
-- 
USE BI_DWH;

GO
-- ============================================================================
-- 1. ОБОРОТНАЯ ВЕДОМОСТЬ (очищенная)
-- ============================================================================
-- Очистка данных:
--   - material_id, warehouse_code, date, start_date, end_date - обязательны
--   - balance_start, income_qty, expense_qty, balance_end - обязательны
--   - start_date <= end_date (проверка)
--   - expense_qty <= 0 (расход должен быть отрицательным)
--   - income_qty >= 0 (поступление не отрицательное)
--   - balance_start >= 0, balance_end >= 0
--   - Уникальность: (material_id, warehouse_code, start_date, end_date)
-- ============================================================================
IF OBJECT_ID ('ods.turnover_clean', 'U') IS NOT NULL
DROP TABLE ods.turnover_clean;

GO
CREATE TABLE
    ods.turnover_clean (
        -- Суррогатный ключ (искусственный ID, как в staging)
        ods_id INT IDENTITY (1, 1) NOT NULL,
        -- Ссылка на запись в STAGING (для аудита и отслеживания)
        staging_load_id INT NOT NULL,
        -- Бизнес-поля (обязательные, NOT NULL)
        -- ID материала
        material_id INT NOT NULL,
        -- Код склада
        warehouse_code NVARCHAR (50) NOT NULL,
        -- Дата выгрузки
        date DATETIME2 NOT NULL,
        -- Начало периода
        start_date DATETIME2 NOT NULL,
        -- Конец периода
        end_date DATETIME2 NOT NULL,
        -- Количественные показатели (обязательные)
        -- Остаток на начало
        balance_start DECIMAL(18, 2) NOT NULL,
        -- Поступление
        income_qty DECIMAL(18, 2) NOT NULL,
        -- Расход (отрицательное)
        expense_qty DECIMAL(18, 2) NOT NULL,
        -- Остаток на конец
        balance_end DECIMAL(18, 2) NOT NULL,
        -- Единица измерения (обязательная)
        unit NVARCHAR (50) NOT NULL,
        -- ========================================================================
        -- Поля для версионирования (SCD Type 2)
        -- Нужны для отслеживания изменений в DWH
        -- ========================================================================
        -- Дата начала версии
        valid_from DATETIME2 NOT NULL DEFAULT SYSDATETIME (),
        -- Дата конца версии (NULL = текущая)
        valid_to DATETIME2 NULL,
        -- 1 = текущая версия
        is_current BIT NOT NULL DEFAULT 1,
        -- Аудит (кто и когда создал)
        created_date DATETIME2 NOT NULL DEFAULT SYSDATETIME (),
        created_by NVARCHAR (100) NULL DEFAULT SYSTEM_USER,
        -- ========================================================================
        -- ОГРАНИЧЕНИЯ
        -- ========================================================================
        CONSTRAINT PK_ods_turnover_clean PRIMARY KEY (ods_id),
        -- Бизнес-ключ: уникальная комбинация для предотвращения дубликатов
        CONSTRAINT UQ_ods_turnover_clean_business UNIQUE (material_id, warehouse_code, start_date, end_date),
        -- Проверка: дата начала <= дата конца
        CONSTRAINT CHK_ods_turnover_clean_dates CHECK (start_date <= end_date),
        -- Проверка: дата выгрузки внутри периода
        CONSTRAINT CHK_ods_turnover_clean_date_range CHECK (date BETWEEN start_date AND end_date),
        -- Проверка: расход должен быть <= 0 (отрицательное число)
        CONSTRAINT CHK_ods_turnover_clean_expense CHECK (expense_qty <= 0),
        -- Проверка: поступление >= 0
        CONSTRAINT CHK_ods_turnover_clean_income CHECK (income_qty >= 0),
        -- Проверка: остатки не отрицательные
        CONSTRAINT CHK_ods_turnover_clean_balance_start CHECK (balance_start >= 0),
        CONSTRAINT CHK_ods_turnover_clean_balance_end CHECK (balance_end >= 0),
        -- Проверка: material_id > 0
        CONSTRAINT CHK_ods_turnover_clean_material CHECK (material_id > 0),
        -- Проверка версионирования
        CONSTRAINT CHK_ods_turnover_clean_valid_dates CHECK (valid_from <= ISNULL (valid_to, '9999-12-31'))
    );

GO
-- ============================================================================
-- 2. ЦЕНЫ МАТЕРИАЛОВ (очищенные)
-- ============================================================================
-- Очистка данных:
--   - material_id, date, start_date, end_date - обязательны
--   - price > 0 (цена должна быть положительной)
--   - start_date <= end_date
--   - Уникальность: (material_id, start_date, end_date)
-- ============================================================================
IF OBJECT_ID ('ods.prices_clean', 'U') IS NOT NULL
DROP TABLE ods.prices_clean;

GO
CREATE TABLE
    ods.prices_clean (
        -- Суррогатный ключ
        ods_id INT IDENTITY (1, 1) NOT NULL,
        -- Ссылка на STAGING
        staging_load_id INT NOT NULL,
        -- Бизнес-поля
        material_id INT NOT NULL,
        date DATETIME2 NOT NULL,
        start_date DATETIME2 NOT NULL,
        end_date DATETIME2 NOT NULL,
        price DECIMAL(18, 2) NOT NULL,
        -- Цена (обязательна)
        -- Версионирование
        valid_from DATETIME2 NOT NULL DEFAULT SYSDATETIME (),
        valid_to DATETIME2 NULL,
        is_current BIT NOT NULL DEFAULT 1,
        -- Аудит
        created_date DATETIME2 NOT NULL DEFAULT SYSDATETIME (),
        created_by NVARCHAR (100) NULL DEFAULT SYSTEM_USER,
        -- ========================================================================
        -- ОГРАНИЧЕНИЯ
        -- ========================================================================
        CONSTRAINT PK_ods_prices_clean PRIMARY KEY (ods_id),
        -- Бизнес-ключ
        CONSTRAINT UQ_ods_prices_clean_business UNIQUE (material_id, start_date, end_date),
        -- Проверка дат
        CONSTRAINT CHK_ods_prices_clean_dates CHECK (start_date <= end_date),
        -- Проверка: дата выгрузки внутри периода
        CONSTRAINT CHK_ods_prices_clean_date_range CHECK (date BETWEEN start_date AND end_date),
        -- Проверка: цена > 0
        CONSTRAINT CHK_ods_prices_clean_price CHECK (price > 0),
        -- Проверка: material_id > 0
        CONSTRAINT CHK_ods_prices_clean_material CHECK (material_id > 0),
        -- Проверка версионирования
        CONSTRAINT CHK_ods_prices_clean_valid_dates CHECK (valid_from <= ISNULL (valid_to, '9999-12-31'))
    );

GO
-- ============================================================================
-- 3. СКЛАДЫ (очищенные)
-- ============================================================================
-- Очистка данных:
--   - warehouse_code - обязателен и уникален
--   - warehouse_type - обязателен
--   - date, start_date, end_date - обязательны
--   - start_date <= end_date
--   - shop_code, directorate, mol_id, mol_position - могут быть NULL
--   - Уникальность: (warehouse_code, start_date, end_date)
-- ============================================================================
IF OBJECT_ID ('ods.warehouses_clean', 'U') IS NOT NULL
DROP TABLE ods.warehouses_clean;

GO
CREATE TABLE
    ods.warehouses_clean (
        -- Суррогатный ключ
        ods_id INT IDENTITY (1, 1) NOT NULL,
        -- Ссылка на STAGING
        staging_load_id INT NOT NULL,
        -- Бизнес-поля
        warehouse_code NVARCHAR (50) NOT NULL,
        -- Код склада (обязателен)
        date DATETIME2 NOT NULL,
        start_date DATETIME2 NOT NULL,
        end_date DATETIME2 NOT NULL,
        -- Атрибуты склада
        shop_code NVARCHAR (50) NULL,
        -- Может быть NULL
        warehouse_type NVARCHAR (100) NOT NULL,
        -- Обязателен
        directorate NVARCHAR (200) NULL,
        -- Может быть NULL
        mol_id INT NULL,
        -- Может быть NULL
        mol_position NVARCHAR (200) NULL,
        -- Может быть NULL
        -- Версионирование
        valid_from DATETIME2 NOT NULL DEFAULT SYSDATETIME (),
        valid_to DATETIME2 NULL,
        is_current BIT NOT NULL DEFAULT 1,
        -- Аудит
        created_date DATETIME2 NOT NULL DEFAULT SYSDATETIME (),
        created_by NVARCHAR (100) NULL DEFAULT SYSTEM_USER,
        -- ========================================================================
        -- ОГРАНИЧЕНИЯ
        -- ========================================================================
        CONSTRAINT PK_ods_warehouses_clean PRIMARY KEY (ods_id),
        -- Бизнес-ключ: склад уникален в пределах периода
        CONSTRAINT UQ_ods_warehouses_clean_business UNIQUE (warehouse_code, start_date, end_date),
        -- Проверка дат
        CONSTRAINT CHK_ods_warehouses_clean_dates CHECK (start_date <= end_date),
        -- Проверка: дата выгрузки внутри периода
        CONSTRAINT CHK_ods_warehouses_clean_date_range CHECK (date BETWEEN start_date AND end_date),
        -- Проверка: код склада не пустой
        CONSTRAINT CHK_ods_warehouses_clean_code CHECK (LEN (warehouse_code) > 0),
        -- Проверка: тип склада не пустой
        CONSTRAINT CHK_ods_warehouses_clean_type CHECK (LEN (warehouse_type) > 0),
        -- Проверка: mol_id > 0 (если указан)
        CONSTRAINT CHK_ods_warehouses_clean_mol CHECK (
            mol_id IS NULL
            OR mol_id > 0
        ),
        -- Проверка версионирования
        CONSTRAINT CHK_ods_warehouses_clean_valid_dates CHECK (valid_from <= ISNULL (valid_to, '9999-12-31'))
    );

GO