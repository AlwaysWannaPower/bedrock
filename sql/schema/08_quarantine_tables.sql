-- ============================================================================
-- Файл: 08_quarantine_tables.sql
-- Описание: Таблицы карантина для данных с ошибками
-- ============================================================================

USE BI_DWH;
GO

IF OBJECT_ID('quarantine.turnover', 'U') IS NOT NULL DROP TABLE quarantine.turnover;
GO
CREATE TABLE quarantine.turnover (
    quarantine_id     BIGINT      IDENTITY PRIMARY KEY ,
    file_name         NVARCHAR(255)     NOT NULL,
    load_id           BIGINT            NOT NULL,
    quarantined_at    DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
----------------------------------------------------------
    error_reason      NVARCHAR(700)     NOT NULL,
----------------------------------------------------------
    date_loaded       NVARCHAR(100),
    date              NVARCHAR(100),
    start_date        NVARCHAR(100),
    end_date          NVARCHAR(100),
----------------------------------------------------------
    warehouse_code    NVARCHAR(100),
    balance_start     NVARCHAR(100),
    income_qty        NVARCHAR(100),
    expense_qty       NVARCHAR(100),
    balance_end       NVARCHAR(100),
----------------------------------------------------------
    unit              NVARCHAR(100),
    material_id       NVARCHAR(100),

    
    
);
GO

IF OBJECT_ID('quarantine.prices', 'U') IS NOT NULL DROP TABLE quarantine.prices;
GO
CREATE TABLE quarantine.prices (
    quarantine_id     BIGINT      IDENTITY PRIMARY KEY ,
    file_name         NVARCHAR(255)     NOT NULL,
    load_id           BIGINT            NOT NULL,
    quarantined_at    DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
----------------------------------------------------------
    error_reason      NVARCHAR(500)     NOT NULL, 
----------------------------------------------------------
    date              NVARCHAR(100),
    start_date        NVARCHAR(100),
    end_date          NVARCHAR(100),
    material_id       NVARCHAR(100),
    price             NVARCHAR(100),
    
);
GO

IF OBJECT_ID('quarantine.warehouses', 'U') IS NOT NULL DROP TABLE quarantine.warehouses;
GO
CREATE TABLE quarantine.warehouses(
    quarantine_id     BIGINT      IDENTITY PRIMARY KEY ,
    file_name         NVARCHAR(255)     NOT NULL,
    load_id           BIGINT            NOT NULL,
    quarantined_at    DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
----------------------------------------------------------
    error_reason      NVARCHAR(500)     NOT NULL, 
----------------------------------------------------------
    date              NVARCHAR(100),
    start_date        NVARCHAR(100),
    end_date          NVARCHAR(100),
    warehouse_code    NVARCHAR(100),
    shop_code         NVARCHAR(100),
    warehouse_type    NVARCHAR(100),
    directorate       NVARCHAR(100),
    mol_id            NVARCHAR(100),
    mol_position      NVARCHAR(100),
);
GO
