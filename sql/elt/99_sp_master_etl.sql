-- ============================================================================
-- Файл: 99_sp_master_etl.sql
-- Описание: Главная процедура ETL-пайплайна.
--           Выполняет все этапы последовательно.
--
-- Порядок шагов соответствует зависимостям (по ТЗ §16):
--
--     0. STAGING        файлы CSV -> staging (через file_registry)
--     1-3. VALIDATION   staging -> quarantine / ods
--     4-5. DIMENSIONS   ods -> dwh.dim_* (SCD1 / SCD2)
--     6-7. FACTS        ods + dims -> dwh.fact_*
--     8. DATAMART       dwh -> datamart.* (витрины для Superset)
--
-- Логирование:
--     Каждый шаг логируется через elt.sp_log:
--         RUNNING -> шаг начался
--         SUCCESS -> шаг завершился
--         ERROR   -> шаг упал (текст ошибки в etl.elt_log.error_msg)
--
--     В случае ошибки:
--         1) пишем алерт в elt.alert_queue (страховка, не зависит от почты);
--         2) отправляем письмо через elt.sp_notify_admin (если почта настроена);
--         3) THROW — ошибка НЕ проглатывается, внешний планировщик её увидит.
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

CREATE OR ALTER PROCEDURE elt.sp_master_etl
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Переменные для логирования текущего шага.
    DECLARE @step     NVARCHAR(200);   -- имя шага
    DECLARE @start_dt DATETIME2;       -- время начала шага

    BEGIN TRY

        PRINT '========================================';
        PRINT 'START ETL';
        PRINT '========================================';

        -- ================================================================
        -- 0. STAGING
        -- Загрузка новых CSV из /import (инкрементально через file_registry)
        -- ================================================================
        SET @step = N'elt.sp_load_staging_from_import';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '0/8 Load staging...';
        EXEC elt.sp_load_staging_from_import;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        -- ================================================================
        -- 1. ODS
        -- Валидация оборотной ведомости (staging -> quarantine / ods)
        -- ================================================================
        SET @step = N'elt.sp_validate_turnover';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '1/8 Validate turnover...';
        EXEC elt.sp_validate_turnover;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        -- ================================================================
        -- 2. ODS
        -- Валидация цен
        -- ================================================================
        SET @step = N'elt.sp_validate_prices';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '2/8 Validate prices...';
        EXEC elt.sp_validate_prices;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        -- ================================================================
        -- 3. ODS
        -- Валидация складов
        -- ================================================================
        SET @step = N'elt.sp_validate_warehouses';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '3/8 Validate warehouses...';
        EXEC elt.sp_validate_warehouses;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        -- ================================================================
        -- 4. DWH
        -- Загрузка измерения материалов (SCD Type 1)
        -- ================================================================
        SET @step = N'dwh.sp_load_dim_material';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '4/8 Load dim_material...';
        EXEC dwh.sp_load_dim_material;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        -- ================================================================
        -- 5. DWH
        -- Загрузка измерения складов (SCD Type 2)
        -- ================================================================
        SET @step = N'dwh.sp_load_dim_warehouse';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '5/8 Load dim_warehouse...';
        EXEC dwh.sp_load_dim_warehouse;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        -- ================================================================
        -- 6. DWH
        -- Загрузка факта оборотов (последняя версия выгрузки)
        -- ================================================================
        SET @step = N'dwh.sp_load_fact_inventory';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '6/8 Load fact_inventory...';
        EXEC dwh.sp_load_fact_inventory;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        -- ================================================================
        -- 7. DWH
        -- Загрузка факта цен (последняя версия цены)
        -- ================================================================
        SET @step = N'dwh.sp_load_fact_prices';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '7/8 Load fact_prices...';
        EXEC dwh.sp_load_fact_prices;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        -- ================================================================
        -- 8. DATAMART
        -- Пересчёт витрин для Superset (метрики + MoM)
        -- ================================================================
        SET @step = N'datamart.sp_refresh_datamart';
        SET @start_dt = SYSDATETIME();
        EXEC elt.sp_log @step, N'RUNNING', @start_dt;
        PRINT '8/8 Refresh datamart...';
        EXEC datamart.sp_refresh_datamart;
        EXEC elt.sp_log @step, N'SUCCESS', @start_dt;

        PRINT '========================================';
        PRINT 'ETL COMPLETED SUCCESSFULLY';
        PRINT '========================================';

    END TRY
    BEGIN CATCH

        -- ====================================================================
        -- Обработка ошибки:
        -- 1) фиксируем ERROR в журнале шагов;
        -- 2) пишем алерт в elt.alert_queue (всегда, даже без почты);
        -- 3) отправляем письмо администратору (если почта настроена);
        -- 4) THROW — не проглатываем ошибку.
        -- ====================================================================

        -- 1) Логируем падение текущего шага в etl.elt_log.
        --
        -- ВАЖНО: ERROR_MESSAGE() нельзя передавать прямо в списке аргументов
        -- EXEC (парсер «голой» формы EXEC не принимает вызовы функций).
        -- Поэтому сначала сохраняем текст ошибки в переменную.
        DECLARE @err_msg NVARCHAR(MAX) = ERROR_MESSAGE();

        IF @step IS NOT NULL
            EXEC elt.sp_log @step, N'ERROR', @start_dt, NULL, @err_msg;

        -- 2) Алерт в базу (страховка, не зависит от почты).
        INSERT INTO elt.alert_queue
        (severity, subject, body)
        VALUES
        (
            N'ERROR',
            N'BI_DWH: ELT FAILED',
            N'Ошибка: ' + CAST(ERROR_NUMBER() AS NVARCHAR(20))
                + CHAR(13) + CHAR(10)
                + N'Сообщение: ' + ERROR_MESSAGE()
                + CHAR(13) + CHAR(10)
                + N'Процедура: ' + ISNULL(ERROR_PROCEDURE(), N'-')
                + CHAR(13) + CHAR(10)
                + N'Строка: ' + CAST(ERROR_LINE() AS NVARCHAR(20))
        );

        -- 3) Письмо администратору (внутри процедуры ошибка почты
        --    НЕ выбрасывается — см. 11_elt_notify.sql).
        DECLARE @body NVARCHAR(MAX);

        SET @body =
                N'ELT завершился с ошибкой.'
                    + CHAR(13) + CHAR(10)
                    + N'--------------------------------'
                    + CHAR(13) + CHAR(10)
                    + N'Ошибка: ' + CAST(ERROR_NUMBER() AS NVARCHAR(20))
                    + CHAR(13) + CHAR(10)
                    + N'Сообщение: ' + ERROR_MESSAGE()
                    + CHAR(13) + CHAR(10)
                    + N'Процедура: ' + ISNULL(ERROR_PROCEDURE(), N'-')
                    + CHAR(13) + CHAR(10)
                    + N'Строка: ' + CAST(ERROR_LINE() AS NVARCHAR(20));

        EXEC elt.sp_notify_admin
             @subject = N'BI_DWH: ELT FAILED',
             @body = @body;

        -- 4) Пробрасываем исходную ошибку наверх.
        THROW;

    END CATCH;
END;
GO
