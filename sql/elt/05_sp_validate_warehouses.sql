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

CREATE OR ALTER PROCEDURE elt.sp_validate_warehouses
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;


        -- ====================================================================
        -- 1. STAGING -> нормальные типы
        -- ====================================================================
        --
        -- STAGING хранит всё как строки.
        --
        -- Здесь:
        --
        --     Excel Serial Date -> DATE
        --     material-like numbers -> INT
        --     текстовые поля -> очищенный NVARCHAR
        --
        -- Исходные значения сохраняем отдельно для QUARANTINE.
        -- ====================================================================

        SELECT s.load_id,
               s.file_name,

               -- ------------------------------------------------------------
               -- Исходные значения
               -- ------------------------------------------------------------

               s.date           AS raw_date,
               s.start_date     AS raw_start_date,
               s.end_date       AS raw_end_date,

               s.warehouse_code AS raw_warehouse_code,
               s.shop_code      AS raw_shop_code,
               s.warehouse_type AS raw_warehouse_type,
               s.directorate    AS raw_directorate,
               s.mol_id         AS raw_mol_id,
               s.mol_position   AS raw_mol_position,

               -- ------------------------------------------------------------
               -- Преобразованные значения
               -- ------------------------------------------------------------

               -- Дата в ДВУХ форматах (см. elt.fn_parse_date):
               --   1) Excel Serial Date:  '45292'  -> 2024-01-01  (склады приходят как '45292.0')
               --   2) обычная дата:       '2024-01-31' -> 2024-01-31
               elt.fn_parse_date(s.date)        AS date,
               elt.fn_parse_date(s.start_date)  AS start_date,
               elt.fn_parse_date(s.end_date)    AS end_date,

               NULLIF(
                       TRIM(s.warehouse_code),
                       N''
               )                AS warehouse_code,

               NULLIF(
                       TRIM(s.shop_code),
                       N''
               )                AS shop_code,

               NULLIF(
                       TRIM(s.warehouse_type),
                       N''
               )                AS warehouse_type,

               NULLIF(
                       TRIM(s.directorate),
                       N''
               )                AS directorate,

               TRY_CONVERT(
                   INT,
                       TRY_CONVERT(
                           DECIMAL(18, 2),
                               s.mol_id
                       )
               )                AS mol_id,

               NULLIF(
                       TRIM(s.mol_position),
                       N''
               )                AS mol_position

        INTO #data
        FROM staging.warehouses AS s;


        -- ====================================================================
        -- 2. Поле с причиной ошибки
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
                            -- Проверка преобразования дат
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
                            -- --------------------------------------------------------
                            -- Обязательные поля
                            -- --------------------------------------------------------

                                CASE
                                    WHEN warehouse_code IS NULL
                                        THEN N'Пустой warehouse_code'
                                    END,
                                CASE
                                    WHEN warehouse_type IS NULL
                                        THEN N'Пустой warehouse_type'
                                    END,
                            -- --------------------------------------------------------
                            -- mol_id
                            --
                            -- NULL разрешён.
                            -- Но если значение присутствует, оно должно быть > 0.
                            -- --------------------------------------------------------

                                CASE
                                    WHEN mol_id IS NULL
                                        AND NULLIF(TRIM(raw_mol_id), N'') IS NOT NULL
                                        THEN N'Некорректный mol_id'
                                    END,
                                CASE
                                    WHEN mol_id IS NOT NULL
                                        AND mol_id <= 0
                                        THEN N'mol_id <= 0'
                                    END,
                            -- --------------------------------------------------------
                            -- Период
                            -- --------------------------------------------------------

                                CASE
                                    WHEN start_date IS NOT NULL
                                        AND end_date IS NOT NULL
                                        AND start_date > end_date
                                        THEN N'start_date > end_date'
                                    END,

                            -- --------------------------------------------------------
                            -- Пустые обязательные текстовые поля
                            -- --------------------------------------------------------

                                CASE
                                    WHEN LEN(warehouse_code) = 0
                                        THEN N'Пустой warehouse_code'
                                    END,
                                CASE
                                    WHEN LEN(warehouse_type) = 0
                                        THEN N'Пустой warehouse_type'
                                    END
                        ),
                        N''
                );


        -- ====================================================================
        -- 4. Дубликаты внутри STAGING
        -- ====================================================================
        --
        -- Если один и тот же склад с одинаковой датой/периодом встретился
        -- несколько раз, первую запись оставляем,
        -- остальные отправляем в QUARANTINE.
        --
        -- ВАЖНО:
        -- одинаковый warehouse_code в разные даты НЕ является дубликатом.
        -- ====================================================================

        ;
        WITH duplicates AS
                 (SELECT load_id,

                         ROW_NUMBER() OVER
                             (
                             PARTITION BY
                             date,
                             warehouse_code,
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
        -- 5. (нет) — строки, уже существующие в ODS, НЕ отправляются в карантин
        -- ====================================================================
        --
        -- Раньше здесь стояла проверка «если бизнес-ключ уже есть в ODS —
        -- строка в карантин». Это ломало идемпотентность: при ПОВТОРНОМ
        -- запуске ETL все старые строки staging снова помечались как
        -- «Дубликат строки в ODS» и заново падали в карантин (затопление).
        --
        -- Правильно: строка уже обработана ранее → просто пропускаем её
        -- (см. NOT EXISTS в шаге 7). Карантин — только для новых ошибок.
        -- ====================================================================


        -- ====================================================================
        -- 6. QUARANTINE
        -- ====================================================================
        --
        -- Сюда попадают ТОЛЬКО строки,
        -- у которых error_reason действительно заполнен.
        --
        -- Защита от повторного карантина: load_id, который уже лежит
        -- в quarantine.warehouses (с прошлого запуска), не вставляем снова.
        -- ====================================================================

        INSERT INTO quarantine.warehouses
        (load_id,
         file_name,
         error_reason,
         date,
         start_date,
         end_date,
         warehouse_code,
         shop_code,
         warehouse_type,
         directorate,
         mol_id,
         mol_position)
        SELECT load_id,
               file_name,
               error_reason,

               raw_date,
               raw_start_date,
               raw_end_date,

               raw_warehouse_code,
               raw_shop_code,
               raw_warehouse_type,
               raw_directorate,
               raw_mol_id,
               raw_mol_position

        FROM #data AS d
        WHERE error_reason IS NOT NULL

          -- Уже в карантине с прошлого запуска — пропускаем (идемпотентность).
          AND NOT EXISTS
            (SELECT 1
             FROM quarantine.warehouses AS q
             WHERE q.load_id = d.load_id);


        -- ====================================================================
        -- 7. ODS
        -- ====================================================================
        --
        -- Только полностью валидные строки.
        --
        -- NOT EXISTS: если бизнес-ключ уже есть в ODS (строка загружена
        -- в прошлый запуск) — пропускаем, дубликат не создаём.
        -- ====================================================================

        INSERT INTO ods.warehouses
        (staging_load_id,
         warehouse_code,
         shop_code,
         warehouse_type,
         directorate,
         mol_id,
         mol_position,
         date,
         start_date,
         end_date)
        SELECT load_id,

               warehouse_code,
               shop_code,
               warehouse_type,
               directorate,
               mol_id,
               mol_position,

               date,
               start_date,
               end_date

        FROM #data AS d
        WHERE error_reason IS NULL

          AND NOT EXISTS
            (SELECT 1
             FROM ods.warehouses AS o
             WHERE o.date = d.date
               AND o.warehouse_code = d.warehouse_code
               AND o.start_date = d.start_date
               AND o.end_date = d.end_date);


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

