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

CREATE OR ALTER PROCEDURE dwh.sp_load_fact_prices
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;

        /*
        ========================================================================
        1. Формируем актуальный набор цен
        ========================================================================

        Один бизнес-ключ:

            material_id
            start_date
            end_date

        может встречаться в ODS несколько раз.

        Например:

            material 4 | 01.04-30.04 | 01.05 | 33
            material 4 | 01.04-30.04 | 17.05 | 33
            material 4 | 01.04-30.04 | 20.05 | 35

        Для FACT нам нужна последняя версия.

        Сначала определяем её через ROW_NUMBER().
        ========================================================================
        */

        SELECT
            p.staging_load_id,
            p.date,
            p.start_date,
            p.end_date,
            p.material_id,
            p.price,

            ds.date_key AS date_key_start,
            de.date_key AS date_key_end,
            m.material_sk

        INTO #latest_prices

        FROM
        (
            SELECT
                p.*,

                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        p.start_date,
                        p.end_date,
                        p.material_id

                    ORDER BY
                        p.date DESC,
                        p.staging_load_id DESC
                ) AS rn

            FROM ods.prices AS p
        ) AS p

        INNER JOIN dwh.dim_date AS ds
            ON ds.full_date = p.start_date

        INNER JOIN dwh.dim_date AS de
            ON de.full_date = p.end_date

        INNER JOIN dwh.dim_material AS m
            ON m.material_id = p.material_id

        WHERE p.rn = 1;


        /*
        ========================================================================
        2. Обновляем существующие цены
        ========================================================================

        Если бизнес-ключ уже существует в FACT,
        но цена изменилась — обновляем её.
        ========================================================================
        */

        UPDATE f
        SET
            f.price = p.price

        FROM dwh.fact_prices AS f

        INNER JOIN #latest_prices AS p
            ON p.date_key_start = f.date_key_start
            AND p.date_key_end = f.date_key_end
            AND p.material_sk = f.material_sk

        WHERE
            ISNULL(f.price, -999999999.99)
            <>
            ISNULL(p.price, -999999999.99);


        /*
        ========================================================================
        3. Добавляем новые цены
        ========================================================================

        Если такого бизнес-ключа ещё нет в FACT,
        создаём новую запись.
        ========================================================================
        */

        INSERT INTO dwh.fact_prices
        (
            date_key_start,
            date_key_end,
            material_sk,
            price
        )

        SELECT
            p.date_key_start,
            p.date_key_end,
            p.material_sk,
            p.price

        FROM #latest_prices AS p

        WHERE NOT EXISTS
        (
            SELECT 1

            FROM dwh.fact_prices AS f

            WHERE f.date_key_start = p.date_key_start
              AND f.date_key_end = p.date_key_end
              AND f.material_sk = p.material_sk
        );


        /*
        ========================================================================
        4. Успешное завершение
        ========================================================================

        Логирование (RUNNING/SUCCESS/ERROR) выполняет elt.sp_master_etl
        как шаг 7 — здесь повторно не пишем.
        */

        COMMIT TRANSACTION;

    END TRY

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;

END;
GO