-- ============================================================================
-- Таблица elt.config для хранения настроек уведомлений
-- ============================================================================

USE BI_DWH;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'elt')
BEGIN
    EXEC('CREATE SCHEMA elt');
END
GO

IF OBJECT_ID('elt.config', 'U') IS NULL
BEGIN
    CREATE TABLE elt.config (
        config_id     INT IDENTITY(1,1) NOT NULL,
        config_key    NVARCHAR(100) NOT NULL,
        config_value  NVARCHAR(MAX) NOT NULL,
        created_at    DATETIME2 DEFAULT SYSDATETIME(),
        updated_at    DATETIME2 DEFAULT SYSDATETIME(),
        CONSTRAINT PK_elt_config PRIMARY KEY (config_id),
        CONSTRAINT UQ_elt_config_key UNIQUE (config_key)
    );
    
    -- Добавляем дефолтные настройки (будут перезаписаны из .env)
    INSERT INTO elt.config (config_key, config_value) VALUES 
        (N'admin_email', N'admin@example.com'),
        (N'dbmail_profile', N'DWH_Alerts'),
        (N'notifications_enabled', N'0');
END
GO

PRINT '✅ Таблица elt.config создана';