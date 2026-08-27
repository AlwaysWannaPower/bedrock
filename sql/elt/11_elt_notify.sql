-- ============================================================================
-- Файл: 11_elt_notify.sql
-- Описание: Настройка Database Mail для уведомлений об ошибках ETL.
-- ============================================================================

USE BI_DWH;
GO

-- ============================================================================
-- 1. SMTP account
-- ============================================================================

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_account
    WHERE name = 'DWH Alert Account'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_account_sp
        @account_name = 'DWH Alert Account',
        @description = 'Account for DWH ETL alerts',
        @email_address = '$(SMTP_FROM_EMAIL)',
        @display_name = '$(SMTP_FROM_NAME)',
        @mailserver_name = '$(SMTP_SERVER)',
        @mailserver_type = 'SMTP',
        @port = $(SMTP_PORT),
        @username = '$(SMTP_USERNAME)',
        @password = '$(SMTP_PASSWORD)',
        @use_default_credentials = 0,
        @enable_ssl = 1;
END;
GO

-- ============================================================================
-- 2. Database Mail profile
-- ============================================================================

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profile
    WHERE name = 'DWH Alerts'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_profile_sp
        @profile_name = 'DWH Alerts',
        @description = 'Profile for DWH ETL alerts';
END;
GO

-- ============================================================================
-- 3. Связываем account с profile
-- ============================================================================

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profileaccount pa
    JOIN msdb.dbo.sysmail_profile p
        ON p.profile_id = pa.profile_id
    JOIN msdb.dbo.sysmail_account a
        ON a.account_id = pa.account_id
    WHERE p.name = 'DWH Alerts'
      AND a.name = 'DWH Alert Account'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_profileaccount_sp
        @profile_name = 'DWH Alerts',
        @account_name = 'DWH Alert Account',
        @sequence_number = 1;
END;
GO

-- ============================================================================
-- 4. Делаем профиль доступным для ETL
-- ============================================================================

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_principalprofile pp
    JOIN msdb.dbo.sysmail_profile p
        ON p.profile_id = pp.profile_id
    WHERE p.name = 'DWH Alerts'
      AND pp.principal_sid = 0x01
)
BEGIN
    EXEC msdb.dbo.sysmail_add_principalprofile_sp
        @profile_name = 'DWH Alerts',
        @principal_name = 'public',
        @is_default = 1;
END;
GO

-- ============================================================================
-- 5. Процедура уведомления
-- ============================================================================

CREATE OR ALTER PROCEDURE elt.sp_notify_admin
    @subject NVARCHAR(200),
    @body    NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'DWH Alerts',
        @recipients   = '$(ADMIN_EMAIL)',
        @subject      = @subject,
        @body         = @body;
END;
GO