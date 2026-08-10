-- ============================================================================
-- Файл: 04_dim_tables.sql
-- Описание: Таблицы измерений (Dimensions) по методологии Кимбалла.
--           Используют SCD Type 2 для хранения истории изменений.
-- ============================================================================

USE BI_DWH;
GO

-- Перед пересозданием измерений снимаем факты (FK) — идемпотентный редеплой
IF OBJECT_ID('dwh.fact_inventory', 'U') IS NOT NULL DROP TABLE dwh.fact_inventory;
IF OBJECT_ID('dwh.fact_prices', 'U') IS NOT NULL DROP TABLE dwh.fact_prices;
GO


-- --------------------------------------------------------------------------
-- Календарь (dim_date) — статическое измерение, генерируется один раз
-- --------------------------------------------------------------------------
IF OBJECT_ID('dwh.dim_date', 'U') IS NOT NULL DROP TABLE dwh.dim_date;
GO

CREATE TABLE dwh.dim_date (
    date_key          INT           NOT NULL,     -- ключ в формате YYYYMMDD
    full_date         DATE          NOT NULL,     -- сама дата
    year_num          INT           NOT NULL,
    quarter_num       INT           NOT NULL,
    month_num         INT           NOT NULL,
    month_name        NVARCHAR(20)  NOT NULL,     -- "Январь", "Февраль" ...
    day_of_month      INT           NOT NULL,
    day_of_week       INT           NOT NULL,     -- 1=Пн, 7=Вс
    is_weekend        BIT           NOT NULL,
    
    CONSTRAINT PK_dim_date PRIMARY KEY (date_key)
);
GO

-- --------------------------------------------------------------------------
-- Склады (dim_warehouse) — SCD Type 2
-- Одна и та же запись о складе может иметь несколько версий во времени,
-- если менялся цех, МОЛ, тип или дирекция.
-- --------------------------------------------------------------------------
IF OBJECT_ID('dwh.dim_warehouse', 'U') IS NOT NULL DROP TABLE dwh.dim_warehouse;
GO

CREATE TABLE dwh.dim_warehouse (
    warehouse_sk      INT IDENTITY(1,1) NOT NULL, -- суррогатный ключ
    warehouse_code    NVARCHAR(50)      NOT NULL, -- бизнес-ключ (код из файла)
    shop_code         NVARCHAR(50)      NULL,
    warehouse_type    NVARCHAR(100)     NULL,
    directorate       NVARCHAR(200)     NULL,
    mol_id            INT               NULL,
    mol_position      NVARCHAR(200)     NULL,
    
    -- Поля SCD Type 2
    date_from         DATE              NOT NULL, -- с какой даты версия актуальна
    date_to           DATE              NOT NULL, -- по какую (9999-12-31 = текущая)
    is_current        BIT               NOT NULL, -- 1 = актуальная версия
    
    -- Технические поля
    created_at        DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
    updated_at        DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
    
    CONSTRAINT PK_dim_warehouse PRIMARY KEY (warehouse_sk)
);
GO

-- --------------------------------------------------------------------------
-- Материалы (dim_material) — SCD Type 1 (перезапись, история не нужна)
-- --------------------------------------------------------------------------
IF OBJECT_ID('dwh.dim_material', 'U') IS NOT NULL DROP TABLE dwh.dim_material;
GO

CREATE TABLE dwh.dim_material (
    material_sk       INT IDENTITY(1,1) NOT NULL, -- суррогатный ключ
    material_id       INT               NOT NULL, -- бизнес-ключ (ID из файла)
    unit              NVARCHAR(50)      NULL,     -- базовая ЕИ
    
    created_at        DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
    updated_at        DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
    
    CONSTRAINT PK_dim_material PRIMARY KEY (material_sk),
    CONSTRAINT UQ_dim_material_id  UNIQUE (material_id)
);