-- ============================================================================
-- Файл: 07_indexes.sql
-- Описание: Индексы для ускорения Live-запросов Superset (≤ 3 сек).
-- ============================================================================

USE BI_DWH;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_inventory_period' AND object_id = OBJECT_ID('dwh.fact_inventory'))
    CREATE NONCLUSTERED INDEX IX_fact_inventory_period ON dwh.fact_inventory (date_key_end);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_inventory_wh' AND object_id = OBJECT_ID('dwh.fact_inventory'))
    CREATE NONCLUSTERED INDEX IX_fact_inventory_wh ON dwh.fact_inventory (warehouse_sk);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_inventory_mat' AND object_id = OBJECT_ID('dwh.fact_inventory'))
    CREATE NONCLUSTERED INDEX IX_fact_inventory_mat ON dwh.fact_inventory (material_sk);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_dim_warehouse_code_dates' AND object_id = OBJECT_ID('dwh.dim_warehouse'))
    CREATE NONCLUSTERED INDEX IX_dim_warehouse_code_dates ON dwh.dim_warehouse (warehouse_code, date_from, date_to);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_prices_mat_dates' AND object_id = OBJECT_ID('dwh.fact_prices'))
    CREATE NONCLUSTERED INDEX IX_fact_prices_mat_dates ON dwh.fact_prices (material_sk, date_from, date_to);
GO
