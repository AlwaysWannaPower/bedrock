-- ============================================================================
-- Файл: 11_etl_notify.sql
-- Описание: Уведомление администратора при сбое ETL.
--
-- 1. Записывает ошибку в elt.alert_queue.
-- 2. Если Database Mail настроен — отправляет письмо.
-- ============================================================================

USE BI_DWH;
GO

-- ============================================================================
-- 1. Очередь уведомлений
-- ============================================================================

IF OBJECT_ID('elt.alert_queue', 'U') IS NULL
BEGIN
    CREATE TABLE elt.alert_queue
    (
        alert_id      INT IDENTITY(1,1) NOT NULL,
        created_at    DATETIME2         NOT NULL
            CONSTRAINT DF_elt_alert_queue_created_at
            DEFAULT SYSDATETIME(),

        severity      NVARCHAR(20)      NOT NULL
            CONSTRAINT DF_elt_alert_queue_severity
            DEFAULT N'ERROR',

        subject       NVARCHAR(200)     NOT NULL,
        body          NVARCHAR(MAX)     NOT NULL,

        is_sent       BIT               NOT NULL
            CONSTRAINT DF_elt_alert_queue_is_sent
            DEFAULT 0,

        sent_at       DATETIME2         NULL,

        CONSTRAINT PK_elt_alert_queue
            PRIMARY KEY (alert_id)
    );
END
GO


-- ============================================================================
-- 2. Процедура уведомления администратора
-- ============================================================================

CREATE OR ALTER PROCEDURE elt.sp_notify_admin
    @subject NVARCHAR(200),
    @body    NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    -- ------------------------------------------------------------
    -- Сначала всегда сохраняем ошибку.
    -- Даже если Database Mail не работает.
    -- ------------------------------------------------------------

    INSERT INTO elt.alert_queue
    (
        severity,
        subject,
        body,
        is_sent
    )
    VALUES
    (
        N'ERROR',
        @subject,
        @body,
        0
    );

    DECLARE @alert_id INT = SCOPE_IDENTITY();


    -- ------------------------------------------------------------
    -- Пытаемся отправить письмо.
    -- ------------------------------------------------------------

    BEGIN TRY

        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = N'$(DBMAIL_PROFILE)',
            @recipients   = N'$(ADMIN_EMAIL)',
            @subject      = @subject,
            @body         = @body;


        -- Письмо успешно отправлено.
        UPDATE elt.alert_queue
        SET
            is_sent = 1,
            sent_at = SYSDATETIME()
        WHERE alert_id = @alert_id;

    END TRY

    BEGIN CATCH

        -- --------------------------------------------------------
        -- Database Mail не сработал.
        --
        -- Сам ETL при этом не должен потерять информацию
        -- об ошибке.
        -- --------------------------------------------------------

        UPDATE elt.alert_queue
        SET
            body =
                body
                + NCHAR(10)
                + N'[mail_error] '
                + ERROR_MESSAGE()
        WHERE alert_id = @alert_id;

    END CATCH
END;
GO