-- ============================================================================
-- Файл: 04_dwh_dimensions.sql
-- Описание: Измерения DWH по методологии Kimball.
--
-- Слои:
--   staging -> сырые данные
--   ods     -> очищенные и типизированные данные
--   dwh     -> измерения и факты для аналитики
--
-- Измерения:
--   dim_date      — календарь
--   dim_material  — материалы
--   dim_warehouse — склады, SCD Type 2
-- ============================================================================

USE BI_DWH;
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================================
-- 1. DIM_DATE
-- ============================================================================
--
-- Календарь не является SCD.
--
-- Он один раз заполняется календарными датами и затем используется
-- всеми фактами.
--
-- date_key = YYYYMMDD
-- ============================================================================

IF OBJECT_ID('dwh.dim_date', 'U') IS NULL
    CREATE TABLE dwh.dim_date
(
    date_key       INT          NOT NULL,
    full_date      DATE         NOT NULL,

    year_num       INT          NOT NULL,
    quarter_num    INT          NOT NULL,
    month_num      INT          NOT NULL,
    month_name     NVARCHAR(20) NOT NULL,

    day_of_month   INT          NOT NULL,
    day_of_week    INT          NOT NULL,
    is_weekend     BIT          NOT NULL,

    CONSTRAINT PK_dim_date
        PRIMARY KEY (date_key),

    CONSTRAINT UQ_dim_date_full_date
        UNIQUE (full_date)
);
GO
-- ============================================================================
-- 2. DIM_MATERIAL
-- ============================================================================
--
-- Материал имеет стабильный бизнес-ключ material_id.
--
-- В текущем ТЗ нам не требуется хранить историю изменения атрибутов
-- материала, поэтому используем SCD Type 1.
--
-- unit здесь хранится как атрибут материала.
-- ============================================================================

IF OBJECT_ID('dwh.dim_material', 'U') IS NULL
    CREATE TABLE dwh.dim_material
(
    material_sk    INT IDENTITY(1,1) NOT NULL,
    material_id    INT               NOT NULL,
    unit           NVARCHAR(50)      NULL,

    created_at     DATETIME2         NOT NULL
        CONSTRAINT DF_dim_material_created_at
        DEFAULT SYSDATETIME(),

    updated_at     DATETIME2         NOT NULL
        CONSTRAINT DF_dim_material_updated_at
        DEFAULT SYSDATETIME(),

    CONSTRAINT PK_dim_material
        PRIMARY KEY (material_sk),

    CONSTRAINT UQ_dim_material_id
        UNIQUE (material_id)
);
GO
-- ============================================================================
-- 3. DIM_WAREHOUSE
-- ============================================================================
--
-- Склад является историческим измерением.
--
-- Например:
--
--   S022
--   2024-01-01 -> МОЛ = 4
--   2025-03-01 -> МОЛ = 186
--
-- Мы НЕ перезаписываем старую запись.
-- Создаём новую версию склада.
--
-- warehouse_code — бизнес-ключ.
-- warehouse_sk   — суррогатный ключ конкретной версии.
--
-- Для текущей версии:
--
--   date_to    = 9999-12-31
--   is_current = 1
-- ============================================================================

IF OBJECT_ID('dwh.dim_warehouse', 'U') IS NULL
    CREATE TABLE dwh.dim_warehouse
(
    warehouse_sk      INT IDENTITY(1,1) NOT NULL,

    warehouse_code    NVARCHAR(50)  NOT NULL,
    shop_code         NVARCHAR(50)  NULL,
    warehouse_type    NVARCHAR(100) NULL,
    directorate       NVARCHAR(200) NULL,

    mol_id            INT           NULL,
    mol_position      NVARCHAR(200) NULL,

    date_from         DATE          NOT NULL,
    date_to           DATE          NOT NULL,

    is_current        BIT           NOT NULL,

    created_at        DATETIME2     NOT NULL
        CONSTRAINT DF_dim_warehouse_created_at
        DEFAULT SYSDATETIME(),

    updated_at        DATETIME2     NOT NULL
        CONSTRAINT DF_dim_warehouse_updated_at
        DEFAULT SYSDATETIME(),

    CONSTRAINT PK_dim_warehouse
        PRIMARY KEY (warehouse_sk),

    CONSTRAINT CK_dim_warehouse_dates
        CHECK (date_from <= date_to),

    CONSTRAINT CK_dim_warehouse_current
        CHECK
        (
            (is_current = 1 AND date_to = '9999-12-31')
            OR
            (is_current = 0 AND date_to <> '9999-12-31')
        )
);
GO
-- ============================================================================
-- 4. ИНДЕКСЫ DIM_WAREHOUSE
-- ============================================================================
--
-- Частая задача:
--
--   найти версию склада, действующую на конкретную дату.
--
-- Например:
--
--   warehouse_code = 'S022'
--   дата = '2025-02-15'
--
-- Поэтому индексируем бизнес-ключ и период действия.
-- ============================================================================

CREATE INDEX IX_dim_warehouse_business_date
ON dwh.dim_warehouse
(
    warehouse_code,
    date_from,
    date_to
);
GO


CREATE UNIQUE INDEX UX_dim_warehouse_current
ON dwh.dim_warehouse (warehouse_code)
WHERE is_current = 1;
GO
