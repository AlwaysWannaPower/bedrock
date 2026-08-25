-- ============================================================================
-- Файл: 11_etl_notify.sql
-- Описание: Уведомление администратора при сбое ETL (п. 7.e ТЗ).
--           1) Пишет запись в etl.alert_queue (всегда работает).
--           2) При настроенном Database Mail — отправляет письмо.
-- ============================================================================

USE BI_DWH;
GO

IF OBJECT_ID('elt.alert_queue', 'U') IS NULL
BEGIN
    CREATE TABLE etl.alert_queue (
        alert_id      INT IDENTITY(1,1) NOT NULL,
        created_at    DATETIME2         NOT NULL DEFAULT SYSDATETIME(),
        severity      NVARCHAR(20)      NOT NULL DEFAULT N'ERROR',
        subject       NVARCHAR(200)     NOT NULL,
        body          NVARCHAR(MAX)     NOT NULL,
        is_sent       BIT               NOT NULL DEFAULT 0,
        sent_at       DATETIME2         NULL,
        CONSTRAINT PK_etl_alert_queue PRIMARY KEY (alert_id)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM etl.config WHERE config_key = N'admin_email')
    INSERT INTO etl.config (config_key, config_value)
    VALUES (N'admin_email', N'admin@example.com');

IF NOT EXISTS (SELECT 1 FROM etl.config WHERE config_key = N'dbmail_profile')
    INSERT INTO etl.config (config_key, config_value)
    VALUES (N'dbmail_profile', N'DWH_Alerts');
GO

CREATE OR ALTER PROCEDURE etl.sp_notify_admin
    @subject NVARCHAR(200),
    @body    NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @email   NVARCHAR(1000);
    DECLARE @profile NVARCHAR(1000);

    SELECT @email   = config_value FROM etl.config WHERE config_key = N'admin_email';
    SELECT @profile = config_value FROM etl.config WHERE config_key = N'dbmail_profile';

    INSERT INTO etl.alert_queue (severity, subject, body, is_sent)
    VALUES (N'ERROR', @subject, @body, 0);

    DECLARE @alert_id INT = SCOPE_IDENTITY();

    BEGIN TRY
        IF EXISTS (
            SELECT 1
            FROM msdb.dbo.sysmail_profile
            WHERE name = @profile
        )
        BEGIN
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = @profile,
                @recipients   = @email,
                @subject      = @subject,
                @body         = @body;

            UPDATE etl.alert_queue
            SET is_sent = 1, sent_at = SYSDATETIME()
            WHERE alert_id = @alert_id;
        END
    END TRY
    BEGIN CATCH
        UPDATE etl.alert_queue
        SET body = body + NCHAR(10) + N'[mail_error] ' + ERROR_MESSAGE()
        WHERE alert_id = @alert_id;
    END CATCH
END;
GO
