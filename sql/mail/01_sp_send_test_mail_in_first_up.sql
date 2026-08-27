-- ============================================================================
-- Файл: 01_sp_send_test_mail_in_first_up.sql
--
USE BI_DWH;
GO

CREATE OR ALTER PROCEDURE elt.sp_send_test_mail_in_first_up
AS
    BEGIN

    SET NOCOUNT ON;

    BEGIN TRY
    DECLARE @body NVARCHAR(MAX);

    SET @body = N'Добрый день, товарищ Администратор!' + CHAR(10) + CHAR(10) +
            N'Это тест почтового модуля SQL Server при первичном разворачивание docker-compose ✅';
    EXEC msdb.dbo.sp_send_dbmail
    @profile_name = 'DWH Alerts',
    @recipients = 'YourChoiseTechMetal@yandex.ru',
    @subject = N'Проверка почтового модуля',
    @body = @body
    END TRY
    BEGIN CATCH
            PRINT N'❌ Ошибка отправки письма: ' + ERROR_MESSAGE();
            THROW;

    END CATCH;

END;
GO