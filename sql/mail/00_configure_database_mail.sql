-- ============================================================================
-- Файл: 00_configure_database_mail.sql
-- Описание: Автоматическая настройка Database Mail через переменные Docker
-- Использует переменные: $(SMTP_SERVER), $(SMTP_PORT), $(SMTP_USERNAME) и т.д.
-- ============================================================================

USE master;
GO

PRINT '🔧 Настройка Database Mail...';

-- 1. Включаем Database Mail
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
GO

-- 2. Проверяем и удаляем старые настройки (если есть)
DECLARE @profile_id INT, @account_id INT;

-- Удаляем привязки аккаунтов к профилю
SELECT @profile_id = profile_id FROM msdb.dbo.sysmail_profile WHERE name = 'DWH_Alerts';
IF @profile_id IS NOT NULL
BEGIN
    DELETE FROM msdb.dbo.sysmail_profileaccount WHERE profile_id = @profile_id;
    DELETE FROM msdb.dbo.sysmail_profile WHERE profile_id = @profile_id;
END

-- Удаляем существующий аккаунт
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = 'SMTP_Account')
BEGIN
    DELETE FROM msdb.dbo.sysmail_account WHERE name = 'SMTP_Account';
END

-- 3. Создаем SMTP аккаунт
PRINT '📧 Создание SMTP аккаунта...';

INSERT INTO msdb.dbo.sysmail_account (
    name,
    description,
    email_address,
    display_name,
    replyto_address,
    mailserver_name,
    mailserver_type,
    port,
    username,
    password,
    use_default_credentials,
    enable_ssl,
    account_sid
)
VALUES (
    'SMTP_Account',
    'SMTP аккаунт для DWH уведомлений (настроен автоматически)',
    '$(SMTP_FROM_EMAIL)',
    '$(SMTP_FROM_NAME)',
    '$(SMTP_FROM_EMAIL)',
    '$(SMTP_SERVER)',
    0,  -- SMTP
    $(SMTP_PORT),  -- Порт (число!)
    '$(SMTP_USERNAME)',
    '$(SMTP_PASSWORD)',
    0,  -- Не использовать Windows аутентификацию
    1,  -- Включить SSL/TLS
    NULL
);

SET @account_id = SCOPE_IDENTITY();

-- 4. Создаем профиль
PRINT '👤 Создание профиля DWH_Alerts...';

INSERT INTO msdb.dbo.sysmail_profile (
    name,
    description,
    profile_sid
)
VALUES (
    'DWH_Alerts',
    'Профиль для отправки ETL уведомлений администратору',
    NULL
);

SET @profile_id = SCOPE_IDENTITY();

-- 5. Привязываем аккаунт к профилю
PRINT '🔗 Привязка аккаунта к профилю...';

INSERT INTO msdb.dbo.sysmail_profileaccount (
    profile_id,
    account_id,
    sequence_number
)
VALUES (
    @profile_id,
    @account_id,
    1
);

-- 6. Делаем профиль публичным (доступным из любой базы данных)
PRINT '🌐 Делаем профиль публичным...';

EXEC msdb.dbo.sysmail_add_principalprofile_sp
    @profile_name = 'DWH_Alerts',
    @principal_name = 'public',
    @is_default = 1;

-- 7. Проверяем настройки
PRINT '📊 Проверка настроек Database Mail...';

SELECT 
    a.name AS AccountName,
    a.email_address AS FromEmail,
    a.mailserver_name AS SMTPServer,
    a.port AS SMTPPort,
    a.username AS SMTPUser,
    a.enable_ssl AS SSL,
    p.name AS ProfileName
FROM msdb.dbo.sysmail_account a
JOIN msdb.dbo.sysmail_profileaccount pa ON a.account_id = pa.account_id
JOIN msdb.dbo.sysmail_profile p ON pa.profile_id = p.profile_id
WHERE p.name = 'DWH_Alerts';

-- 8. Отправляем тестовое письмо
PRINT '✉️ Отправка тестового письма...';

BEGIN TRY
    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'DWH_Alerts',
        @recipients = '$(ADMIN_EMAIL)',
        @subject = '✅ Database Mail настроен автоматически',
        @body = 'Привет! Это тестовое письмо из Docker контейнера.

Настройки SMTP:
- Сервер: $(SMTP_SERVER)
- Порт: $(SMTP_PORT)
- От: $(SMTP_FROM_EMAIL)
- Кому: $(ADMIN_EMAIL)

Если вы видите это письмо, значит Database Mail работает корректно!',
        @importance = 'HIGH';

    PRINT '✅ Тестовое письмо отправлено на $(ADMIN_EMAIL)';
END TRY
BEGIN CATCH
    PRINT '⚠️ Не удалось отправить тестовое письмо: ' + ERROR_MESSAGE();
    PRINT '⚠️ Проверьте настройки SMTP и сетевую доступность!';
END CATCH

PRINT '✅ Database Mail настроен успешно!';
GO