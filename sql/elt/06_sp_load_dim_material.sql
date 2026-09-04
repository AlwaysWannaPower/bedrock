-- ============================================================================
-- Файл: 06_sp_load_dim_material.sql
-- Описание: Загрузка измерения материалов.
--           SCD Type 1.
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

CREATE OR ALTER PROCEDURE dwh.sp_load_dim_material
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;

        -- Собираем уникальные материалы.
        -- Приоритет unit: значение из turnover, затем NULL из prices.
        ;WITH materials AS
        (
            SELECT
                material_id,
                MAX(unit) AS unit
            FROM
            (
                SELECT
                    material_id,
                    unit
                FROM ods.turnover
                WHERE material_id IS NOT NULL

                UNION ALL

                SELECT
                    material_id,
                    NULL AS unit
                FROM ods.prices
                WHERE material_id IS NOT NULL
            ) AS src
            GROUP BY material_id
        )

        -- Обновляем существующие материалы.
        UPDATE m
        SET
            m.unit = src.unit,
            m.updated_at = SYSDATETIME()
        FROM dwh.dim_material AS m
        INNER JOIN materials AS src
            ON src.material_id = m.material_id
        WHERE src.unit IS NOT NULL
          AND (
                m.unit IS NULL
                OR m.unit <> src.unit
              );


        -- Добавляем новые материалы.
        ;WITH materials AS
        (
            SELECT
                material_id,
                MAX(unit) AS unit
            FROM
            (
                SELECT
                    material_id,
                    unit
                FROM ods.turnover
                WHERE material_id IS NOT NULL

                UNION ALL

                SELECT
                    material_id,
                    NULL AS unit
                FROM ods.prices
                WHERE material_id IS NOT NULL
            ) AS src
            GROUP BY material_id
        )

        INSERT INTO dwh.dim_material
        (
            material_id,
            unit
        )
        SELECT
            src.material_id,
            src.unit
        FROM materials AS src
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dwh.dim_material AS m
            WHERE m.material_id = src.material_id
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