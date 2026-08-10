-- ============================================================================
-- Файл: 08_quarantine_tables.sql
-- Описание: Таблицы карантина для данных с ошибками (п. 8.c ТЗ).
-- ============================================================================

USE BI_DWH;
GO

IF OBJECT_ID('quarantine.turnover_bad', 'U') IS NOT NULL DROP TABLE quarantine.turnover_bad;
GO
CREATE TABLE quarantine.turnover_bad (
    load_id           INT               NOT NULL,
    file_name         NVARCHAR(255)     NULL,
    date_loaded       DATETIME2         NULL,
    date              DATETIME2         NULL,
    start_date        DATETIME2         NULL,
    end_date          DATETIME2         NULL,
    warehouse_code    NVARCHAR(50)      NULL,
    balance_start     DECIMAL(18,2)     NULL,
    income_qty        DECIMAL(18,2)     NULL,
    expense_qty       DECIMAL(18,2)     NULL,
    balance_end       DECIMAL(18,2)     NULL,
    unit              NVARCHAR(50)      NULL,
    material_id       INT               NULL,
    error_reason      NVARCHAR(500)     NOT NULL,
    quarantined_at    DATETIME2         NOT NULL  DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('quarantine.prices_bad', 'U') IS NOT NULL DROP TABLE quarantine.prices_bad;
GO
CREATE TABLE quarantine.prices_bad (
    load_id           INT               NOT NULL,
    file_name         NVARCHAR(255)     NULL,
    date_loaded       DATETIME2         NULL,
    date              DATETIME2         NULL,
    start_date        DATETIME2         NULL,
    end_date          DATETIME2         NULL,
    material_id       INT               NULL,
    price             DECIMAL(18,2)     NULL,
    error_reason      NVARCHAR(500)     NOT NULL,
    quarantined_at    DATETIME2         NOT NULL  DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('quarantine.warehouses_bad', 'U') IS NOT NULL DROP TABLE quarantine.warehouses_bad;
GO
CREATE TABLE quarantine.warehouses_bad (
    load_id           INT               NOT NULL,
    file_name         NVARCHAR(255)     NULL,
    date_loaded       DATETIME2         NULL,
    date              DATETIME2         NULL,
    start_date        DATETIME2         NULL,
    end_date          DATETIME2         NULL,
    warehouse_code    NVARCHAR(50)      NULL,
    shop_code         NVARCHAR(50)      NULL,
    warehouse_type    NVARCHAR(100)     NULL,
    directorate       NVARCHAR(200)     NULL,
    mol_id            INT               NULL,
    mol_position      NVARCHAR(200)     NULL,
    error_reason      NVARCHAR(500)     NOT NULL,
    quarantined_at    DATETIME2         NOT NULL  DEFAULT SYSDATETIME()
);
GO
