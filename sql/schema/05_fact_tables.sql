-- ============================================================================
-- Файл: 05_fact_tables.sql
-- Описание: Таблицы фактов (Facts) по методологии Кимбалла.
--           Хранят измеримые бизнес-события: остатки, цены.
-- ============================================================================

USE BI_DWH;
GO

-- --------------------------------------------------------------------------
-- Факт остатков (fact_inventory)
-- Гранулярность: 1 строка = (период, склад, материал)
-- --------------------------------------------------------------------------
IF OBJECT_ID('dwh.fact_inventory', 'U') IS NOT NULL DROP TABLE dwh.fact_inventory;
GO

CREATE TABLE dwh.fact_inventory (
    inventory_sk      INT IDENTITY(1,1) NOT NULL, -- суррогатный ключ
    
    -- Внешние ключи к измерениям
    date_key_start    INT               NOT NULL, -- начало периода (FK → dim_date)
    date_key_end      INT               NOT NULL, -- конец периода  (FK → dim_date)
    warehouse_sk      INT               NOT NULL, -- FK → dim_warehouse
    material_sk       INT               NOT NULL, -- FK → dim_material
    
    -- Метрики (количественные)
    balance_start     DECIMAL(18,2)     NULL,     -- остаток на начало
    income_qty        DECIMAL(18,2)     NULL,     -- поступление
    expense_qty       DECIMAL(18,2)     NULL,     -- расход
    balance_end       DECIMAL(18,2)     NULL,     -- остаток на конец
    unit              NVARCHAR(50)      NULL,
    
    -- Технические поля
    created_at        DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
    updated_at        DATETIME2         NULL,
    
    CONSTRAINT PK_fact_inventory PRIMARY KEY (inventory_sk),
    -- Уникальность на уровне бизнес-ключей (защита от дублей)
    CONSTRAINT UQ_fact_inventory_period_wh_mat 
        UNIQUE (date_key_start, warehouse_sk, material_sk)
);
GO

-- --------------------------------------------------------------------------
-- Факт цен (fact_prices) — SCD Type 2
-- Цена может меняться от периода к периоду, историю храним.
-- --------------------------------------------------------------------------
IF OBJECT_ID('dwh.fact_prices', 'U') IS NOT NULL DROP TABLE dwh.fact_prices;
GO

CREATE TABLE dwh.fact_prices (
    price_sk          INT IDENTITY(1,1) NOT NULL,
    
    date_key_start    INT               NOT NULL,
    date_key_end      INT               NOT NULL,
    material_sk       INT               NOT NULL,
    
    price             DECIMAL(18,2)     NOT NULL,
    
    -- SCD Type 2
    date_from         DATE              NOT NULL,
    date_to           DATE              NOT NULL,
    is_current        BIT               NOT NULL,
    
    created_at        DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
    updated_at        DATETIME2         NOT NULL  DEFAULT SYSDATETIME(),
    
    CONSTRAINT PK_fact_prices PRIMARY KEY (price_sk)
);
GO

-- --------------------------------------------------------------------------
-- Внешние ключи (добавляем после создания всех таблиц)
-- --------------------------------------------------------------------------
ALTER TABLE dwh.fact_inventory 
    ADD CONSTRAINT FK_fact_inv_date_start FOREIGN KEY (date_key_start) REFERENCES dwh.dim_date(date_key),
        CONSTRAINT FK_fact_inv_date_end   FOREIGN KEY (date_key_end)   REFERENCES dwh.dim_date(date_key),
        CONSTRAINT FK_fact_inv_wh         FOREIGN KEY (warehouse_sk)   REFERENCES dwh.dim_warehouse(warehouse_sk),
        CONSTRAINT FK_fact_inv_mat        FOREIGN KEY (material_sk)    REFERENCES dwh.dim_material(material_sk);
GO

ALTER TABLE dwh.fact_prices 
    ADD CONSTRAINT FK_fact_price_date_start FOREIGN KEY (date_key_start) REFERENCES dwh.dim_date(date_key),
        CONSTRAINT FK_fact_price_date_end   FOREIGN KEY (date_key_end)   REFERENCES dwh.dim_date(date_key),
        CONSTRAINT FK_fact_price_mat        FOREIGN KEY (material_sk)    REFERENCES dwh.dim_material(material_sk);
GO