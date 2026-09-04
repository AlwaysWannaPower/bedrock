-- ============================================================================
-- Файл: 09_populate_dim_date.sql
-- Описание: Первоначальное заполнение календаря.
-- ============================================================================

USE BI_DWH;
GO

SET DATEFIRST 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dwh.dim_date
)
BEGIN

    ;WITH dates AS
    (
        SELECT
            CAST('2023-01-01' AS DATE) AS dt

        UNION ALL

        SELECT
            DATEADD(DAY, 1, dt)
        FROM dates
        WHERE dt < '2026-12-31'
    )
    INSERT INTO dwh.dim_date
    (
        date_key,
        full_date,
        year_num,
        quarter_num,
        month_num,
        month_name,
        day_of_month,
        day_of_week,
        is_weekend
    )
    SELECT
        YEAR(dt) * 10000
            + MONTH(dt) * 100
            + DAY(dt),

        dt,

        YEAR(dt),

        DATEPART(QUARTER, dt),

        MONTH(dt),

        CASE MONTH(dt)
            WHEN 1  THEN N'Январь'
            WHEN 2  THEN N'Февраль'
            WHEN 3  THEN N'Март'
            WHEN 4  THEN N'Апрель'
            WHEN 5  THEN N'Май'
            WHEN 6  THEN N'Июнь'
            WHEN 7  THEN N'Июль'
            WHEN 8  THEN N'Август'
            WHEN 9  THEN N'Сентябрь'
            WHEN 10 THEN N'Октябрь'
            WHEN 11 THEN N'Ноябрь'
            WHEN 12 THEN N'Декабрь'
        END,

        DAY(dt),

        DATEPART(WEEKDAY, dt),

        CASE
            WHEN DATEPART(WEEKDAY, dt) IN (6, 7)
                THEN 1
            ELSE 0
        END

    FROM dates

    OPTION (MAXRECURSION 2000);

END;
GO

