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
-- ============================================================================
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
--   - Уникальность: (date, material_id, warehouse_code, start_date, end_date)
-- ============================================================================
IF OBJECT_ID('ods.turnover', 'U') IS NULL
CREATE TABLE
    ods.turnover
(
    turnover_id     INT IDENTITY (1, 1) NOT NULL, -- Суррогатный ключ
    staging_load_id INT                 NOT NULL, -- Ссылка на запись в STAGING

    -- Бизнес-поля
    material_id     INT                 NOT NULL, -- ID материала
    warehouse_code  NVARCHAR(50)        NOT NULL, -- Код склада

    date            DATETIME2           NOT NULL, -- Дата выгрузки
    start_date      DATETIME2           NOT NULL, -- Начало периода
    end_date        DATETIME2           NOT NULL, -- Конец периода


    -- Количественные показатели (обязательные)

    balance_start   DECIMAL(18, 3)      NOT NULL, -- Остаток на начало
    income_qty      DECIMAL(18, 3)      NOT NULL, -- Поступление
    expense_qty     DECIMAL(18, 3)      NOT NULL, -- Расход (отрицательное)
    balance_end     DECIMAL(18, 3)      NOT NULL, -- Остаток на конец
    unit            NVARCHAR(50)        NOT NULL, -- Единица измерения (обязательная)

    -- ========================================================================
    -- ОГРАНИЧЕНИЯ
    -- ========================================================================
    CONSTRAINT PK_ods_turnover PRIMARY KEY (turnover_id),
    -- Бизнес-ключ: уникальная комбинация для предотвращения дубликатов
    CONSTRAINT UQ_ods_turnover_business UNIQUE (date, material_id, warehouse_code, start_date, end_date),
    -- Проверка: дата начала <= дата конца
    CONSTRAINT CHK_ods_turnover_dates CHECK (start_date <= end_date),
    -- Проверка: расход должен быть <= 0 (отрицательное число)
    CONSTRAINT CHK_ods_turnover_expense CHECK (expense_qty <= 0),
    -- Проверка: поступление >= 0
    CONSTRAINT CHK_ods_turnover_income CHECK (income_qty >= 0),
    -- Проверка: остатки не отрицательные
    CONSTRAINT CHK_ods_turnover_balance_start CHECK (balance_start >= 0),
    CONSTRAINT CHK_ods_turnover_balance_end CHECK (balance_end >= 0),
    -- Проверка: material_id > 0
    CONSTRAINT CHK_ods_turnover_material CHECK (material_id > 0)
);

GO

-- ============================================================================
-- 2. ЦЕНЫ МАТЕРИАЛОВ (очищенные)
-- ============================================================================
-- Очистка данных:
--   - material_id, date, start_date, end_date - обязательны
--   - price > 0 (цена должна быть положительной)
--   - start_date <= end_date
--   - Уникальность: (date, material_id, start_date, end_date)
-- ============================================================================
IF OBJECT_ID('ods.prices', 'U') IS NULL
CREATE TABLE
    ods.prices
(

    price_id        INT IDENTITY (1, 1) NOT NULL, -- Суррогатный ключ
    staging_load_id INT                 NOT NULL, -- Ссылка на STAGING


    date            DATE                NOT NULL,
    start_date      DATE                NOT NULL,
    end_date        DATE                NOT NULL,

    -- Бизнес-поля
    material_id     INT                 NOT NULL,
    price           DECIMAL(18, 2)      NOT NULL,

    -- ========================================================================
    -- ОГРАНИЧЕНИЯ
    -- ========================================================================
    CONSTRAINT PK_ods_prices PRIMARY KEY (price_id),
    -- Бизнес-ключ
    CONSTRAINT UQ_ods_prices_business UNIQUE (date, material_id, start_date, end_date),
    -- Проверка дат
    CONSTRAINT CHK_ods_prices_dates CHECK (start_date <= end_date),
    -- Проверка: цена > 0
    CONSTRAINT CHK_ods_prices_price CHECK (price > 0),
    -- Проверка: material_id > 0
    CONSTRAINT CHK_ods_prices_material CHECK (material_id > 0)
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
IF OBJECT_ID('ods.warehouses', 'U') IS NULL
CREATE TABLE
    ods.warehouses
(

    warehouses_id   INT IDENTITY (1, 1) NOT NULL, -- Суррогатный ключ
    staging_load_id INT                 NOT NULL, -- Ссылка на STAGING

    -- Бизнес-поля
    warehouse_code  NVARCHAR(50)        NOT NULL, -- Код склада (обязателен)
    shop_code       NVARCHAR(50)        NULL,     -- Атрибуты склада
    warehouse_type  NVARCHAR(100)       NOT NULL,
    directorate     NVARCHAR(200)       NULL,
    mol_id          INT                 NULL,
    mol_position    NVARCHAR(200)       NULL,

    date            DATETIME2           NOT NULL,
    start_date      DATETIME2           NOT NULL,
    end_date        DATETIME2           NOT NULL,


    -- Версионирование
    valid_from      DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    valid_to        DATETIME2           NULL,
    is_current      BIT                 NOT NULL DEFAULT 1,
    -- ========================================================================
    -- ОГРАНИЧЕНИЯ
    -- ========================================================================
    CONSTRAINT PK_ods_warehouses PRIMARY KEY (warehouses_id),
    -- Бизнес-ключ: склад уникален в пределах периода
    CONSTRAINT UQ_ods_warehouses_business UNIQUE (date, warehouse_code, start_date, end_date),
    -- Проверка дат
    CONSTRAINT CHK_ods_warehouses_dates CHECK (start_date <= end_date),
    -- Проверка: код склада не пустой
    CONSTRAINT CHK_ods_warehouses_code CHECK (LEN(warehouse_code) > 0),
    -- Проверка: тип склада не пустой
    CONSTRAINT CHK_ods_warehouses_type CHECK (LEN(warehouse_type) > 0),
    -- Проверка: mol_id > 0 (если указан)
    CONSTRAINT CHK_ods_warehouses_mol CHECK (
        mol_id IS NULL
            OR mol_id > 0
        ),
    -- Проверка версионирования
    CONSTRAINT CHK_ods_warehouses_valid_dates CHECK (valid_from <= ISNULL(valid_to, '9999-12-31'))
);
GO