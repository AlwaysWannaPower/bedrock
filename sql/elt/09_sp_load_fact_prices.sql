USE BI_DWH;
GO

CREATE OR ALTER PROCEDURE dwh.sp_load_fact_prices
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;

        INSERT INTO dwh.fact_prices
        (
            date_key_start,
            date_key_end,
            material_sk,
            price
        )
        SELECT
            ds.date_key,
            de.date_key,

            m.material_sk,

            p.price

        FROM ods.prices AS p

        INNER JOIN dwh.dim_date AS ds
            ON ds.full_date = CAST(p.start_date AS DATE)

        INNER JOIN dwh.dim_date AS de
            ON de.full_date = CAST(p.end_date AS DATE)

        INNER JOIN dwh.dim_material AS m
            ON m.material_id = p.material_id

        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dwh.fact_prices AS f
            WHERE f.date_key_start = ds.date_key
              AND f.date_key_end   = de.date_key
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