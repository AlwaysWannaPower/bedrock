-- ============================================================================
-- Файл: 13_sql_agent_job.sql
-- Описание: Ночной SQL Agent Job — ежедневная инкрементальная загрузка (п. 7.b ТЗ).
--           Расписание: каждый день в 02:00.
--           Требует MSSQL_AGENT_ENABLED=True (уже в docker-compose / .env).
--
-- ВАЖНО про один шаг:
--     Job вызывает ТОЛЬКО elt.sp_master_etl. Загрузка staging
--     (elt.sp_load_staging_from_import) — это шаг 0 внутри master,
--     и именно master логирует каждый шаг в elt.elt_log, пишет алерт
--     в elt.alert_queue и шлёт письмо администратору при ЛЮБОМ сбое
--     (включая сбой загрузки файлов). Если бы job вызывал загрузку
--     staging отдельным шагом ДО master, то при сбое файла шаг падал бы
--     раньше, чем запускается master, и уведомление администратору
--     не отправлялось бы (нарушение п. 7.d ТЗ).
-- ============================================================================

USE msdb;
GO

-- Удаляем job, если уже есть (идемпотентный деплой)
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'BI_DWH_Nightly_ETL')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N'BI_DWH_Nightly_ETL', @delete_unused_schedule = 1;
END
GO

BEGIN TRY
    DECLARE @job_id UNIQUEIDENTIFIER;

    EXEC msdb.dbo.sp_add_job
        @job_name = N'BI_DWH_Nightly_ETL',
        @enabled  = 1,
        @description = N'Ежедневная инкрементальная загрузка CSV → DWH → datamart',
        @owner_login_name = N'sa',
        @job_id = @job_id OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @job_id,
        @step_name = N'Master ETL (включает загрузку staging)',
        @subsystem = N'TSQL',
        @database_name = N'BI_DWH',
        @command = N'
EXEC BI_DWH.elt.sp_master_etl;
',
        @on_success_action = 1, -- Quit with success
        @on_fail_action = 2;    -- Quit with failure

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'BI_DWH_Daily_0200',
        @freq_type = 4,          -- daily
        @freq_interval = 1,
        @active_start_time = 20000; -- 02:00:00

    EXEC msdb.dbo.sp_attach_schedule
        @job_id = @job_id,
        @schedule_name = N'BI_DWH_Daily_0200';

    EXEC msdb.dbo.sp_add_jobserver
        @job_id = @job_id,
        @server_name = N'(LOCAL)';

    PRINT N'SQL Agent job BI_DWH_Nightly_ETL создан (02:00 daily).';
END TRY
BEGIN CATCH
    -- В Developer Edition Agent может быть недоступен — не роняем startup
    PRINT N'WARN: не удалось создать SQL Agent job: ' + ERROR_MESSAGE();
END CATCH
GO
