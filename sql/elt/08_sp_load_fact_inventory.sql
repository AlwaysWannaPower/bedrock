USE BI_DWH;
GO

CREATE OR ALTER PROCEDURE dwh.sp_load_fact_inventory
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;

        INSERT INTO dwh.fact_inventory
        (
            date_key_start,
            date_key_end,
            warehouse_sk,
            material_sk,
            balance_start,
            income_qty,
            expense_qty,
            balance_end
        )
        SELECT
            ds.date_key,
            de.date_key,

            w.warehouse_sk,
            m.material_sk,

            t.balance_start,
            t.income_qty,
            t.expense_qty,
            t.balance_end

        FROM ods.turnover AS t

        INNER JOIN dwh.dim_date AS ds
            ON ds.full_date = CAST(t.start_date AS DATE)

        INNER JOIN dwh.dim_date AS de
            ON de.full_date = CAST(t.end_date AS DATE)

        INNER JOIN dwh.dim_material AS m
            ON m.material_id = t.material_id

        INNER JOIN dwh.dim_warehouse AS w
            ON w.warehouse_code = t.warehouse_code
           AND CAST(t.date AS DATE) >= w.date_from
           AND CAST(t.date AS DATE) <= w.date_to

        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dwh.fact_inventory AS f
            WHERE f.date_key_start = ds.date_key
              AND f.date_key_end   = de.date_key
              AND f.warehouse_sk   = w.warehouse_sk
              AND f.material_sk    = m.material_sk
        );

        COMMIT TRANSACTION;

    END TRY

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;
END;
GO