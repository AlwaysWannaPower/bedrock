-- ============================================================================
-- Файл: 05_sp_load_dim_warehouse.sql
-- Описание: Загрузка dwh.dim_warehouse.
--           SCD Type 2 по дате выгрузки date.
-- ============================================================================

USE BI_DWH;
GO

CREATE OR ALTER PROCEDURE dwh.sp_load_dim_warehouse
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;


        -- ================================================================
        -- 1. Получаем снимки складов
        --
        -- date = дата выгрузки состояния склада.
        --
        -- Если в ODS есть несколько строк одного склада
        -- на одну дату, оставляем одну запись.
        -- ================================================================

        ;WITH source_data AS
        (
            SELECT
                warehouse_code,
                shop_code,
                warehouse_type,
                directorate,
                mol_id,
                mol_position,

                CAST(date AS DATE) AS snapshot_date,

                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        warehouse_code,
                        CAST(date AS DATE)

                    ORDER BY
                        warehouse_code
                ) AS rn

            FROM ods.warehouses

            WHERE warehouse_code IS NOT NULL
              AND date IS NOT NULL
        )

        SELECT
            warehouse_code,
            shop_code,
            warehouse_type,
            directorate,
            mol_id,
            mol_position,
            snapshot_date

        INTO #snapshots

        FROM source_data

        WHERE rn = 1;


        -- ================================================================
        -- 2. Определяем реальные изменения состояния склада
        -- ================================================================

        ;WITH ordered AS
        (
            SELECT
                *,

                LAG(shop_code) OVER
                (
                    PARTITION BY warehouse_code
                    ORDER BY snapshot_date
                ) AS prev_shop_code,

                LAG(warehouse_type) OVER
                (
                    PARTITION BY warehouse_code
                    ORDER BY snapshot_date
                ) AS prev_warehouse_type,

                LAG(directorate) OVER
                (
                    PARTITION BY warehouse_code
                    ORDER BY snapshot_date
                ) AS prev_directorate,

                LAG(mol_id) OVER
                (
                    PARTITION BY warehouse_code
                    ORDER BY snapshot_date
                ) AS prev_mol_id,

                LAG(mol_position) OVER
                (
                    PARTITION BY warehouse_code
                    ORDER BY snapshot_date
                ) AS prev_mol_position

            FROM #snapshots
        )

        SELECT
            warehouse_code,
            shop_code,
            warehouse_type,
            directorate,
            mol_id,
            mol_position,
            snapshot_date

        INTO #changes

        FROM ordered

        WHERE
            -- Первая запись склада

            (
                prev_shop_code IS NULL
                AND prev_warehouse_type IS NULL
                AND prev_directorate IS NULL
                AND prev_mol_id IS NULL
                AND prev_mol_position IS NULL
            )

            OR

            -- Изменился цех

            ISNULL(shop_code, N'')
            <> ISNULL(prev_shop_code, N'')

            OR

            -- Изменился тип склада

            ISNULL(warehouse_type, N'')
            <> ISNULL(prev_warehouse_type, N'')

            OR

            -- Изменилась дирекция

            ISNULL(directorate, N'')
            <> ISNULL(prev_directorate, N'')

            OR

            -- Изменился МОЛ

            ISNULL(mol_id, -1)
            <> ISNULL(prev_mol_id, -1)

            OR

            -- Изменилась должность МОЛ

            ISNULL(mol_position, N'')
            <> ISNULL(prev_mol_position, N'');


        -- ================================================================
        -- 3. Первоначальная загрузка
        -- ================================================================

        IF NOT EXISTS
        (
            SELECT 1
            FROM dwh.dim_warehouse
        )
        BEGIN

            INSERT INTO dwh.dim_warehouse
            (
                warehouse_code,
                shop_code,
                warehouse_type,
                directorate,
                mol_id,
                mol_position,
                date_from,
                date_to,
                is_current
            )

            SELECT
                warehouse_code,
                shop_code,
                warehouse_type,
                directorate,
                mol_id,
                mol_position,

                snapshot_date AS date_from,

                ISNULL
                (
                    DATEADD
                    (
                        DAY,
                        -1,
                        LEAD(snapshot_date) OVER
                        (
                            PARTITION BY warehouse_code
                            ORDER BY snapshot_date
                        )
                    ),

                    CAST('9999-12-31' AS DATE)
                ) AS date_to,

                CASE
                    WHEN LEAD(snapshot_date) OVER
                    (
                        PARTITION BY warehouse_code
                        ORDER BY snapshot_date
                    ) IS NULL
                    THEN 1
                    ELSE 0
                END AS is_current

            FROM #changes;

        END;


        -- ================================================================
        -- 4. Последующие загрузки
        -- ================================================================

        ELSE
        BEGIN

            ;WITH latest_changes AS
            (
                SELECT
                    c.*,

                    ROW_NUMBER() OVER
                    (
                        PARTITION BY warehouse_code
                        ORDER BY snapshot_date DESC
                    ) AS rn

                FROM #changes AS c
            )

            SELECT
                c.warehouse_code,
                c.shop_code,
                c.warehouse_type,
                c.directorate,
                c.mol_id,
                c.mol_position,
                c.snapshot_date

            INTO #new_changes

            FROM latest_changes AS c

            INNER JOIN dwh.dim_warehouse AS d
                ON d.warehouse_code = c.warehouse_code
               AND d.is_current = 1

            WHERE c.rn = 1

              AND c.snapshot_date > d.date_from

              AND
              (
                    ISNULL(d.shop_code, N'')
                    <> ISNULL(c.shop_code, N'')

                 OR ISNULL(d.warehouse_type, N'')
                    <> ISNULL(c.warehouse_type, N'')

                 OR ISNULL(d.directorate, N'')
                    <> ISNULL(c.directorate, N'')

                 OR ISNULL(d.mol_id, -1)
                    <> ISNULL(c.mol_id, -1)

                 OR ISNULL(d.mol_position, N'')
                    <> ISNULL(c.mol_position, N'')
              );


            -- ============================================================
            -- 4.1 Закрываем старую версию
            -- ============================================================

            UPDATE d
            SET
                d.date_to = DATEADD(DAY, -1, n.snapshot_date),
                d.is_current = 0,
                d.updated_at = SYSDATETIME()

            FROM dwh.dim_warehouse AS d

            INNER JOIN #new_changes AS n
                ON n.warehouse_code = d.warehouse_code

            WHERE d.is_current = 1;


            -- ============================================================
            -- 4.2 Создаем новую версию
            -- ============================================================

            INSERT INTO dwh.dim_warehouse
            (
                warehouse_code,
                shop_code,
                warehouse_type,
                directorate,
                mol_id,
                mol_position,
                date_from,
                date_to,
                is_current
            )

            SELECT
                warehouse_code,
                shop_code,
                warehouse_type,
                directorate,
                mol_id,
                mol_position,

                snapshot_date,

                CAST('9999-12-31' AS DATE),

                1

            FROM #new_changes;

        END;


        COMMIT TRANSACTION;

    END TRY

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;

END;
GO