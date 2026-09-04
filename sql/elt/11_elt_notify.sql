-- ============================================================================
-- Файл: 11_elt_notify.sql
-- Описание: Настройка Database Mail для уведомлений об ошибках ETL.
--
-- ============================================================================
-- ВАЖНО про переменные $(SMTP_...):
--
--     Это НЕ переменные T-SQL. Это переменные подстановки sqlcmd,
--     которые подставляет startup.sh при вызове:
--
--         sqlcmd -i 11_elt_notify.sql
--                -v SMTP_SERVER="$SMTP_SERVER"
--                -v SMTP_PORT="$SMTP_PORT"
--                ...
--
--     Если переменная не передана (или пустая) — строка '$(SMTP_SERVER)'
--     превращается в пустую строку, и настройка почты пропускается
--     (см. проверки LEN(...) ниже).
--
--     Именно из-за отсутствия -v в startup.sh почтовый модуль
--     «не включался» при перезапуске контейнера: аккаунт создавался
--     с пустым SMTP-сервером.
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

-- ============================================================================
-- 0. Включаем Database Mail XPs (серверная возможность)
-- ============================================================================
-- Без этой настройки sp_send_dbmail не работает вовсе.
-- Идемпотентно: повторный вызов не даёт ошибки.
-- ============================================================================

EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
GO

-- ============================================================================
-- 1. SMTP account
-- ============================================================================
-- Создаём аккаунт ТОЛЬКО если в .env реально задан SMTP-сервер.
-- Если SMTP не настроен — почтовый модуль просто пропускается,
-- а ELT продолжает работать (алерты всё равно пишутся в elt.alert_queue).
-- ============================================================================

IF LEN('$(SMTP_SERVER)') > 0
   AND LEN('$(SMTP_FROM_EMAIL)') > 0
BEGIN

    BEGIN TRY

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

        -- ====================================================================
        -- 2. Database Mail profile
        -- ====================================================================

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

        -- ====================================================================
        -- 3. Связываем account с profile
        -- ====================================================================

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

        -- ====================================================================
        -- 4. Делаем профиль доступным для ETL
        -- ====================================================================
        --
        -- Делаем профиль доступным роли public (principal_id = 1 в msdb).
        --
        -- ВАЖНО: sysmail_principalprofile НЕ содержит колонки principal_id
        -- (запрос к ней падает с ошибкой 207, которую TRY/CATCH не ловит).
        -- У роли public фиксированный SID = 0x00, поэтому проверяем его.
        -- ====================================================================

        IF NOT EXISTS (
            SELECT 1
            FROM msdb.dbo.sysmail_principalprofile pp
            JOIN msdb.dbo.sysmail_profile p
                ON p.profile_id = pp.profile_id
            WHERE p.name = 'DWH Alerts'
              AND pp.principal_sid = 0x00
        )
        BEGIN
            EXEC msdb.dbo.sysmail_add_principalprofile_sp
                @profile_name = 'DWH Alerts',
                @principal_name = 'public',
                @is_default = 1;
        END;

        PRINT N'Database Mail: аккаунт и профиль DWH Alerts настроены.';

    END TRY
    BEGIN CATCH

        -- Если настройка почты упала — НЕ роняем весь startup.
        -- Пишем предупреждение в лог и продолжаем (ELT без почты работает).
        PRINT N'WARN: не удалось настроить Database Mail: ' + ERROR_MESSAGE();

    END CATCH;

END;
ELSE
BEGIN
    PRINT N'Database Mail: SMTP не настроен в .env — почтовый модуль пропущен.';
END;
GO

-- ============================================================================
-- 5. Процедура уведомления
-- ============================================================================
--
-- Обёртка над sp_send_dbmail, которую вызывает ELT.
--
-- ВАЖНО: если отправка письма упадёт, процедура НЕ выбрасывает ошибку
-- (только PRINT). Иначе ошибка почты «замаскировала» бы исходную ошибку
-- ETL в блоке CATCH главного пайплайна.
--
-- Сам факт падения ELT уже зафиксирован в elt.alert_queue ДО вызова почты,
-- поэтому информация не теряется, даже если SMTP молчит.
-- ============================================================================

CREATE OR ALTER PROCEDURE elt.sp_notify_admin
    @subject NVARCHAR(200),
    @body    NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = 'DWH Alerts',
            @recipients   = '$(ADMIN_EMAIL)',
            @subject      = @subject,
            @body         = @body;

        PRINT N'Уведомление отправлено: ' + @subject;

    END TRY
    BEGIN CATCH

        -- Почта не работает — пишем в лог, но НЕ бросаем ошибку.
        PRINT N'WARN: не удалось отправить письмо: ' + ERROR_MESSAGE();

    END CATCH;
END;
GO
