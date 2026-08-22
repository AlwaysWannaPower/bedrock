USE BI_DWH;
GO

CREATE OR ALTER PROCEDURE elt.sp_validate_prices
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;


        -- ====================================================================
        -- 1. STAGING -> нормальные типы
        -- ====================================================================

        SELECT s.load_id,
               s.file_name,

               -- ------------------------------------------------------------
               -- Исходные значения.
               -- Нужны для QUARANTINE.
               -- ------------------------------------------------------------

               s.date        AS raw_date,
               s.start_date  AS raw_start_date,
               s.end_date    AS raw_end_date,
               s.material_id AS raw_material_id,
               s.price       AS raw_price,

               -- ------------------------------------------------------------
               -- Преобразованные значения.
               -- ------------------------------------------------------------

               TRY_CONVERT(
                   DATE,
                       DATEADD(
                               DAY,
                               TRY_CONVERT(
                                   INT,
                                       TRY_CONVERT(DECIMAL(18, 2), s.date)
                               ),
                               '1899-12-30'
                       )
               )             AS date,

               TRY_CONVERT(
                   DATE,
                       DATEADD(
                               DAY,
                               TRY_CONVERT(
                                   INT,
                                       TRY_CONVERT(DECIMAL(18, 2), s.start_date)
                               ),
                               '1899-12-30'
                       )
               )             AS start_date,

               TRY_CONVERT(
                   DATE,
                       DATEADD(
                               DAY,
                               TRY_CONVERT(
                                   INT,
                                       TRY_CONVERT(DECIMAL(18, 2), s.end_date)
                               ),
                               '1899-12-30'
                       )
               )             AS end_date,

               TRY_CONVERT(
                   INT,
                       TRY_CONVERT(
                           DECIMAL(18, 2),
                               s.material_id
                       )
               )             AS material_id,

               TRY_CONVERT(
                   DECIMAL(18, 2),
                       s.price
               )             AS price

        INTO #data
        FROM staging.prices AS s;


        -- ====================================================================
        -- 2. Добавляем поле с причиной ошибки
        -- ====================================================================

        ALTER TABLE #data
            ADD error_reason NVARCHAR(700) NULL;


        -- ====================================================================
        -- 3. Проверка данных
        -- ====================================================================

        UPDATE #data
        SET error_reason =
                NULLIF(
                        CONCAT_WS(
                                N'; ',
                            -- --------------------------------------------------------
                            -- Ошибки преобразования
                            -- --------------------------------------------------------

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
                                    WHEN price IS NULL
                                        THEN N'Некорректный price'
                                    END,
                            -- --------------------------------------------------------
                            -- Бизнес-правила
                            -- --------------------------------------------------------

                                CASE
                                    WHEN start_date IS NOT NULL
                                        AND end_date IS NOT NULL
                                        AND start_date > end_date
                                        THEN N'start_date > end_date'
                                    END,

                                CASE
                                    WHEN material_id IS NOT NULL
                                        AND material_id <= 0
                                        THEN N'material_id <= 0'
                                    END,
                                CASE
                                    WHEN price IS NOT NULL
                                        AND price <= 0
                                        THEN N'price <= 0'
                                    END
                        ),
                        N''
                );


        -- ====================================================================
        -- 4. Дубликаты внутри STAGING
        -- ====================================================================


        WITH duplicates AS
                 (SELECT load_id,

                         ROW_NUMBER() OVER
                             (
                             PARTITION BY
                             date,
                             material_id,
                             start_date,
                             end_date
                             ORDER BY load_id
                             ) AS rn

                  FROM #data
                  WHERE error_reason IS NULL)

        UPDATE d
        SET error_reason = N'Дубликат строки в staging'
        FROM #data AS d
                 INNER JOIN duplicates AS x
                            ON x.load_id = d.load_id
        WHERE x.rn > 1;


        -- ====================================================================
        -- 5. Проверяем существование строки в ODS
        -- ====================================================================

        UPDATE d
        SET error_reason = N'Дубликат строки в ODS'
        FROM #data AS d
        WHERE d.error_reason IS NULL

          AND EXISTS
            (SELECT 1
             FROM ods.prices AS o
             WHERE o.date = d.date
               AND o.material_id = d.material_id
               AND o.start_date = d.start_date
               AND o.end_date = d.end_date);


        -- ====================================================================
        -- 6. QUARANTINE
        --
        -- Только строки, у которых действительно есть ошибка.
        -- ====================================================================

        INSERT INTO quarantine.prices
        (load_id,
         file_name,
         error_reason,
         date,
         start_date,
         end_date,
         material_id,
         price)
        SELECT load_id,
               file_name,
               error_reason,

               raw_date,
               raw_start_date,
               raw_end_date,

               raw_material_id,
               raw_price

        FROM #data
        WHERE error_reason IS NOT NULL;


        -- ====================================================================
        -- 7. ODS
        --
        -- Только строки без ошибок.
        -- ====================================================================

        INSERT INTO ods.prices
        (staging_load_id,
         date,
         start_date,
         end_date,
         material_id,
         price)
        SELECT load_id,
               date,
               start_date,
               end_date,
               material_id,
               price

        FROM #data
        WHERE error_reason IS NULL;


        -- ====================================================================
        -- 8. Завершение
        -- ====================================================================

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;

END;
GO