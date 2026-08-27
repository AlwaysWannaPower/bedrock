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

--         staging.turnover
--             │
--             ▼
--          SELECT
--             │
--             │ преобразование
--             ▼
--            #data
--             │
--             │ добавляем error_reason
--             ▼
-- ┌───────────────┐
-- │   ПРОВЕРКИ    │
-- │               │
-- │ типы          │
-- │ обязательные  │
-- │ бизнес-правила│
-- └───────┬───────┘
--           │
--           ▼
--      error_reason
--           │
-- ┌─────────┴─────────┐
-- │                   │
-- │                   │
-- ▼                   ▼
-- IS NOT NULL          IS NULL
-- │                   │
-- ▼                   ▼
-- Невалидная             Валидная
-- строка                 строка
-- │                   │
-- ▼                   ▼
-- QUARANTINE               ODS
-- │                   │
-- ▼                   ▼
-- raw-значения         clean-значения

CREATE OR ALTER PROCEDURE elt.sp_validate_turnover
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;

        -- ================================================================
        -- 1. Преобразуем строки STAGING в нормальные типы
        -- ================================================================

        SELECT s.load_id,
               s.file_name,

               s.date           AS raw_date,
               s.start_date     AS raw_start_date,
               s.end_date       AS raw_end_date,
               s.warehouse_code AS raw_warehouse_code,
               s.material_id    AS raw_material_id,
               s.unit           AS raw_unit,
               s.balance_start  AS raw_balance_start,
               s.income_qty     AS raw_income_qty,
               s.expense_qty    AS raw_expense_qty,
               s.balance_end    AS raw_balance_end,

               -- Дата в ДВУХ форматах (см. elt.fn_parse_date):
               --   1) Excel Serial Date:  '45292'  -> 2024-01-01
               --   2) обычная дата:       '2024-01-31' -> 2024-01-31
               elt.fn_parse_date(s.date)        AS date,
               elt.fn_parse_date(s.start_date)  AS start_date,
               elt.fn_parse_date(s.end_date)    AS end_date,

               NULLIF(TRIM(s.warehouse_code), '')
                                AS warehouse_code,

               -- '391' и '391.0' -> 391
               TRY_CONVERT(
                   INT,
                       TRY_CONVERT(DECIMAL(18, 2), s.material_id)
               )                AS material_id,

               NULLIF(TRIM(s.unit), '')
                                AS unit,

               TRY_CONVERT(
                   DECIMAL(18, 2),
                       s.balance_start
               )                AS balance_start,

               TRY_CONVERT(
                   DECIMAL(18, 2),
                       s.income_qty
               )                AS income_qty,

               TRY_CONVERT(
                   DECIMAL(18, 2),
                       s.expense_qty
               )                AS expense_qty,

               TRY_CONVERT(
                   DECIMAL(18, 2),
                       s.balance_end
               )                AS balance_end

        INTO #data
        FROM staging.turnover AS s;


        -- ================================================================
        -- 2. Находим ошибки
        -- ================================================================

        ALTER TABLE #data
            ADD error_reason NVARCHAR(700) NULL;;


        UPDATE #data
        SET error_reason =
                NULLIF(
                        CONCAT_WS(
                                N'; ',
                            -- ============================================================
                            -- Типы данных
                            -- ============================================================

                                CASE
                                    WHEN date IS NULL
                                        THEN N'Некорректная date'
                                    END,
                                CASE
                                    WHEN start_date IS NULL
                                        THEN N'Некорректная start_date'
                                    END,
                                CASE
                                    WHEN end_date IS NULL
                                        THEN N'Некорректная end_date'
                                    END,
                                CASE
                                    WHEN material_id IS NULL
                                        THEN N'Некорректный material_id'
                                    END,
                                CASE
                                    WHEN balance_start IS NULL
                                        THEN N'Некорректный balance_start'
                                    END,
                                CASE
                                    WHEN income_qty IS NULL
                                        THEN N'Некорректный income_qty'
                                    END,
                                CASE
                                    WHEN expense_qty IS NULL
                                        THEN N'Некорректный expense_qty'
                                    END,
                                CASE
                                    WHEN balance_end IS NULL
                                        THEN N'Некорректный balance_end'
                                    END,
                            -- ============================================================
                            -- Обязательные поля
                            -- ============================================================

                                CASE
                                    WHEN warehouse_code IS NULL
                                        THEN N'Пустой warehouse_code'
                                    END,
                                CASE
                                    WHEN material_id IS NULL
                                        THEN N'Пустой material_id'
                                    END,
                                CASE
                                    WHEN unit IS NULL
                                        THEN N'Пустой unit'
                                    END,
                            -- ============================================================
                            -- Бизнес-правила
                            -- ============================================================

                                CASE
                                    WHEN start_date > end_date
                                        THEN N'start_date > end_date'
                                    END,
                                CASE
                                    WHEN material_id <= 0
                                        THEN N'material_id <= 0'
                                    END,
                                CASE
                                    WHEN income_qty < 0
                                        THEN N'income_qty < 0'
                                    END,
                                CASE
                                    WHEN expense_qty > 0
                                        THEN N'expense_qty > 0'
                                    END,
                                CASE
                                    WHEN balance_start < 0
                                        THEN N'balance_start < 0'
                                    END,
                                CASE
                                    WHEN balance_end < 0
                                        THEN N'balance_end < 0'
                                    END,
                                CASE
                                    WHEN ABS(
                                                 balance_start
                                                     + income_qty
                                                     + expense_qty
                                                     - balance_end
                                         ) > 0.001
                                        THEN N'Несоответствие остатков и движений'
                                    END
                        ),
                        N''
                );


        -- ================================================================
        -- 3. Невалидные строки -> QUARANTINE
        -- ================================================================
        --
        -- Защита от повторного карантина: load_id, который уже лежит
        -- в quarantine.turnover (с прошлого запуска), не вставляем снова.
        -- Это нужно для идемпотентности повторного запуска ETL.

        INSERT INTO quarantine.turnover
        (load_id,
         file_name,
         error_reason,
         date,
         start_date,
         end_date,
         warehouse_code,
         balance_start,
         income_qty,
         expense_qty,
         balance_end,
         unit,
         material_id)
        SELECT load_id,
               file_name,
               error_reason,

               raw_date,
               raw_start_date,
               raw_end_date,

               raw_warehouse_code,
               raw_balance_start,
               raw_income_qty,
               raw_expense_qty,
               raw_balance_end,

               raw_unit,
               raw_material_id

        FROM #data AS d
        WHERE error_reason IS NOT NULL

          -- Уже в карантине с прошлого запуска — пропускаем (идемпотентность).
          AND NOT EXISTS
            (SELECT 1
             FROM quarantine.turnover AS q
             WHERE q.load_id = d.load_id);


        -- ================================================================
        -- 4. Валидные строки -> ODS
        -- ================================================================

        INSERT INTO ods.turnover
        (staging_load_id,
         material_id,
         warehouse_code,
         date,
         start_date,
         end_date,
         balance_start,
         income_qty,
         expense_qty,
         balance_end,
         unit)
        SELECT load_id,

               material_id,
               warehouse_code,

               date,
               start_date,
               end_date,

               balance_start,
               income_qty,
               expense_qty,
               balance_end,

               unit

        FROM #data AS d
        WHERE error_reason IS NULL

          -- Защита от дублей
          AND NOT EXISTS
            (SELECT 1
             FROM ods.turnover AS o
             WHERE o.date = d.date
               AND o.material_id = d.material_id
               AND o.warehouse_code = d.warehouse_code
               AND o.start_date = d.start_date
               AND o.end_date = d.end_date);


        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;

END;
GO