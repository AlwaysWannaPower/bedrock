-- ============================================================================
-- Файл: 01_datamart_views.sql
--
-- Назначение:
--     Представления (VIEW) слоя datamart для Apache Superset.
--
-- Зачем нужны VIEW, если есть таблицы:
--     1. Удобные «красивые имена» для подключения в Superset.
--     2. Скрой лишние технические колонки — BI видит только нужное.
--     3. Данные НЕ пересчитываются: VIEW читает готовую витрину
--        (предварительно агрегированную процедурой datamart.sp_refresh_datamart).
--
-- ТЗ: «тяжёлые агрегации на стороне BI запрещены» —
--     поэтому VIEW не содержат GROUP BY, а просто SELECT * из таблиц.
-- ============================================================================

USE BI_DWH;
GO

-- ============================================================================
-- ВАЖНО: явно включаем SET-параметры.
--     Без QUOTED_IDENTIFIER ON INSERT в таблицы с фильтрованными
--     индексами (например dwh.dim_warehouse) падает с ошибкой 1934,
--     потому что sqlcmd по умолчанию выставляет QUOTED_IDENTIFIER OFF.
-- ============================================================================
SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================================
-- 1. vw_turnover_metrics — главная витрина для KPI дашборда
--
--    Уровни срезов (agg_level):
--        company     — вся компания
--        directorate — дирекция
--        shop        — цех
--        warehouse   — склад
--
--    Колонки:
--        month_key, year_num, month_num, month_name
--        directorate, shop_code, warehouse_code, warehouse_type
--        stock_value, avg_stock_value, expense_value
--        turnover_ratio, turnover_days
--        mom_* — MoM по каждой метрике (доли: 0.10 = +10%)
-- ============================================================================

CREATE OR ALTER VIEW datamart.vw_turnover_metrics
AS
    SELECT
        month_key,
        year_num,
        month_num,
        month_name,
        agg_level,
        agg_key,
        directorate,
        shop_code,
        warehouse_code,
        warehouse_type,
        stock_value,
        avg_stock_value,
        expense_value,
        turnover_ratio,
        turnover_days,
        mom_stock_value,
        mom_avg_stock_value,
        mom_turnover_ratio,
        mom_turnover_days
    FROM datamart.turnover_metrics;
GO

-- ============================================================================
-- 2. vw_inventory_monthly — детализация: месяц × склад × материал
--
--    Нужна для «копания вглубь»: по какому материалу/складу
--    складывается сумма запасов.
-- ============================================================================

CREATE OR ALTER VIEW datamart.vw_inventory_monthly
AS
    SELECT
        month_key,
        year_num,
        month_num,
        warehouse_code,
        directorate,
        shop_code,
        warehouse_type,
        material_id,
        unit,
        balance_start,
        income_qty,
        expense_qty,
        balance_end,
        avg_qty,
        price,
        stock_value,
        avg_stock_value,
        expense_value
    FROM datamart.inventory_monthly;
GO

-- ============================================================================
-- 3. vw_warehouse_hierarchy — справочник складов для фильтров
--
--    Помогает строить иерархию фильтров:
--        дирекция → цех → склад
-- ============================================================================

CREATE OR ALTER VIEW datamart.vw_warehouse_hierarchy
AS
    SELECT DISTINCT
        warehouse_code,
        directorate,
        shop_code,
        warehouse_type
    FROM datamart.turnover_metrics
    WHERE agg_level = N'warehouse';
GO
