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

CREATE OR ALTER PROCEDURE dwh.sp_load_fact_inventory
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;


        /*
        ========================================================================
        1. Формируем итоговый набор данных из ODS
        ========================================================================

        В ODS могут находиться несколько выгрузок одного периода.

        Например:

            date        start_date   end_date     warehouse   material
            ----------  ----------   ----------   ---------   --------
            2024-05-01  2024-04-01   2024-04-30   0101        90
            2024-05-17  2024-04-01   2024-04-30   0101        90

        Это две версии одного бизнес-факта.

        Поэтому оставляем только ПОСЛЕДНЮЮ выгрузку.

        Ключ версии:

            start_date
            end_date
            warehouse_code
            material_id

        При одинаковой date дополнительно используем turnover_id.
        ========================================================================
        */

        ;
        WITH ranked_turnover AS
                 (SELECT t.*,

                         ROW_NUMBER() OVER
                             (
                             PARTITION BY
                             t.start_date,
                             t.end_date,
                             t.warehouse_code,
                             t.material_id
                             ORDER BY
                                 t.date DESC,
                                 t.turnover_id DESC
                             ) AS rn

                  FROM ods.turnover AS t)

        /*
        ========================================================================
        2. Сохраняем результат во временную таблицу.

        Почему не оставляем CTE?

        Потому что CTE действует только для ОДНОГО следующего SQL-оператора.

        Нам этот набор понадобится два раза:

            UPDATE существующих фактов
            INSERT новых фактов

        Поэтому используем #source_data.
        ========================================================================
        */

        SELECT ds.date_key AS date_key_start,
               de.date_key AS date_key_end,

               -- Версия склада на дату выгрузки; если её нет —
               -- берём текущую версию (COALESCE). Для складов без снимка
               -- в справочнике dwh.sp_load_dim_warehouse создаёт
               -- плейсхолдер warehouse_type = 'UNKNOWN'.
               ISNULL(w.warehouse_sk, w_current.warehouse_sk) AS warehouse_sk,
               m.material_sk,

               t.balance_start,
               t.income_qty,
               t.expense_qty,
               t.balance_end

        INTO #source_data

        FROM ranked_turnover AS t

                 /*
                 ------------------------------------------------------------------------
                 Дата начала периода
                 ------------------------------------------------------------------------
                 */

                 INNER JOIN dwh.dim_date AS ds
                            ON ds.full_date = CAST(t.start_date AS DATE)

            /*
            ------------------------------------------------------------------------
            Дата окончания периода
            ------------------------------------------------------------------------
            */

                 INNER JOIN dwh.dim_date AS de
                            ON de.full_date = CAST(t.end_date AS DATE)

            /*
            ------------------------------------------------------------------------
            Материал

            material_id из ODS превращаем в surrogate key DWH.
            ------------------------------------------------------------------------
            */

                 INNER JOIN dwh.dim_material AS m
                            ON m.material_id = t.material_id

            /*
            ------------------------------------------------------------------------
            Склад

            Здесь используется SCD Type 2.

            Нам нужна именно та версия склада,
            которая была актуальна на дату выгрузки t.date.
            ------------------------------------------------------------------------
            */

            /*
            ------------------------------------------------------------------------
            ВАЖНО про LEFT JOIN:
                Раньше здесь был INNER JOIN, и строки обороток для складов,
                которых нет в справочнике (или нет версии на дату), МОЛЧА
                ТЕРЯЛИСЬ (~10% данных).

                Теперь:
                1) dwh.sp_load_dim_warehouse создаёт плейсхолдер 'UNKNOWN'
                   для каждого кода склада из обороток, которого нет в справочнике;
                2) здесь LEFT JOIN + COALESCE на «текущую версию» склада —
                   строка факта создаётся ВСЕГДА, даже если точная версия
                   на дату не найдена (берём текущую версию склада).
            ------------------------------------------------------------------------
            */

                 LEFT JOIN dwh.dim_warehouse AS w
                            ON w.warehouse_code = t.warehouse_code
                                AND CAST(t.date AS DATE) >= w.date_from
                                AND CAST(t.date AS DATE) <= w.date_to

            -- Запасной вариант: текущая (актуальная) версия склада.
            LEFT JOIN dwh.dim_warehouse AS w_current
                       ON w_current.warehouse_code = t.warehouse_code
                      AND w_current.is_current = 1

        /*
        ------------------------------------------------------------------------
        Берём только последнюю версию записи.
        ------------------------------------------------------------------------
        */

        WHERE t.rn = 1;


        /*
        ========================================================================
        3. UPDATE существующих фактов
        ========================================================================

        Если бизнес-ключ уже существует:

            date_key_start
            date_key_end
            warehouse_sk
            material_sk

        проверяем показатели.

        Если показатели изменились — обновляем факт.

        Это необходимо для выполнения требования ТЗ:

            "загружаются только новые и измененные данные".
        ========================================================================
        */

        UPDATE f
        SET f.balance_start = s.balance_start,
            f.income_qty    = s.income_qty,
            f.expense_qty   = s.expense_qty,
            f.balance_end   = s.balance_end

        FROM dwh.fact_inventory AS f

                 INNER JOIN #source_data AS s
                            ON s.date_key_start = f.date_key_start
                                AND s.date_key_end = f.date_key_end
                                AND s.warehouse_sk = f.warehouse_sk
                                AND s.material_sk = f.material_sk

        /*
        ------------------------------------------------------------------------
        Не выполняем бессмысленный UPDATE,
        если данные фактически не изменились.
        ------------------------------------------------------------------------
        */

        WHERE ISNULL(f.balance_start, 0)
            <> ISNULL(s.balance_start, 0)

           OR ISNULL(f.income_qty, 0)
            <> ISNULL(s.income_qty, 0)

           OR ISNULL(f.expense_qty, 0)
            <> ISNULL(s.expense_qty, 0)

           OR ISNULL(f.balance_end, 0)
            <> ISNULL(s.balance_end, 0);


        /*
        ========================================================================
        4. INSERT новых фактов
        ========================================================================

        Если такой бизнес-ключ ещё отсутствует в fact_inventory,
        добавляем новую строку.
        ========================================================================
        */

        INSERT INTO dwh.fact_inventory
        (date_key_start,
         date_key_end,
         warehouse_sk,
         material_sk,
         balance_start,
         income_qty,
         expense_qty,
         balance_end)

        SELECT s.date_key_start,
               s.date_key_end,
               s.warehouse_sk,
               s.material_sk,
               s.balance_start,
               s.income_qty,
               s.expense_qty,
               s.balance_end

        FROM #source_data AS s

        WHERE NOT EXISTS
                  (SELECT 1
                   FROM dwh.fact_inventory AS f

                   WHERE f.date_key_start = s.date_key_start
                     AND f.date_key_end = s.date_key_end
                     AND f.warehouse_sk = s.warehouse_sk
                     AND f.material_sk = s.material_sk);


        /*
        ========================================================================
        5. Завершаем транзакцию
        ========================================================================
        */

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH

        /*
        Если любой этап упал —
        откатываем всю транзакцию.
        */

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;

END;
GO