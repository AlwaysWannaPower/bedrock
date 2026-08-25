-- ============================================================================
-- Файл: 05_fact_tables.sql
-- Описание: Фактовые таблицы DWH.
-- ============================================================================

USE BI_DWH;
GO


-- ============================================================================
-- FACT INVENTORY
--
-- Гранулярность:
-- одна строка = материал + склад + отчётный период
-- ============================================================================

USE BI_DWH;
GO

IF OBJECT_ID('dwh.fact_inventory', 'U') IS NULL
    CREATE TABLE dwh.fact_inventory
(
    inventory_sk INT IDENTITY(1,1) NOT NULL,

    date_key_start INT NOT NULL,
    date_key_end   INT NOT NULL,

    warehouse_sk INT NOT NULL,
    material_sk  INT NOT NULL,

    balance_start DECIMAL(18,2) NULL,
    income_qty    DECIMAL(18,2) NULL,
    expense_qty   DECIMAL(18,2) NULL,
    balance_end   DECIMAL(18,2) NULL,

    created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),

    CONSTRAINT PK_fact_inventory
        PRIMARY KEY (inventory_sk),

    CONSTRAINT UQ_fact_inventory_business
        UNIQUE
        (
            date_key_start,
            date_key_end,
            warehouse_sk,
            material_sk
        ),

    CONSTRAINT FK_fact_inventory_date_start
        FOREIGN KEY (date_key_start)
        REFERENCES dwh.dim_date(date_key),

    CONSTRAINT FK_fact_inventory_date_end
        FOREIGN KEY (date_key_end)
        REFERENCES dwh.dim_date(date_key),

    CONSTRAINT FK_fact_inventory_warehouse
        FOREIGN KEY (warehouse_sk)
        REFERENCES dwh.dim_warehouse(warehouse_sk),

    CONSTRAINT FK_fact_inventory_material
        FOREIGN KEY (material_sk)
        REFERENCES dwh.dim_material(material_sk)
);
GO
-- ============================================================================
-- FACT PRICES
--
-- Гранулярность:
-- одна строка = материал + отчётный период + цена
--
-- История цены сохраняется естественным образом:
-- новый период = новая строка факта.
-- ============================================================================

IF OBJECT_ID('dwh.fact_prices', 'U') IS NULL
    CREATE TABLE dwh.fact_prices
(
    price_sk INT IDENTITY(1,1) NOT NULL,

    -- Измерения
    date_key_start INT NOT NULL,
    date_key_end   INT NOT NULL,
    material_sk    INT NOT NULL,

    -- Мера
    price DECIMAL(18,2) NOT NULL,

    -- Технические поля
    created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),

    CONSTRAINT PK_fact_prices
        PRIMARY KEY (price_sk),

    CONSTRAINT UQ_fact_prices_business
        UNIQUE
        (
            date_key_start,
            date_key_end,
            material_sk
        )
);
GO
-- ============================================================================
-- FOREIGN KEYS
-- ============================================================================

ALTER TABLE dwh.fact_inventory
ADD
    CONSTRAINT FK_fact_inventory_date_start
        FOREIGN KEY (date_key_start)
        REFERENCES dwh.dim_date(date_key),

    CONSTRAINT FK_fact_inventory_date_end
        FOREIGN KEY (date_key_end)
        REFERENCES dwh.dim_date(date_key),

    CONSTRAINT FK_fact_inventory_warehouse
        FOREIGN KEY (warehouse_sk)
        REFERENCES dwh.dim_warehouse(warehouse_sk),

    CONSTRAINT FK_fact_inventory_material
        FOREIGN KEY (material_sk)
        REFERENCES dwh.dim_material(material_sk);
GO


ALTER TABLE dwh.fact_prices
ADD
    CONSTRAINT FK_fact_prices_date_start
        FOREIGN KEY (date_key_start)
        REFERENCES dwh.dim_date(date_key),

    CONSTRAINT FK_fact_prices_date_end
        FOREIGN KEY (date_key_end)
        REFERENCES dwh.dim_date(date_key),

    CONSTRAINT FK_fact_prices_material
        FOREIGN KEY (material_sk)
        REFERENCES dwh.dim_material(material_sk);
GO