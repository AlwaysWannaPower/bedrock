# Database Mail в BI_DWH

## 1. Назначение

Database Mail используется в нашем DWH для уведомлений о состоянии ELT.

```text
ELT
 │
 ├─ успех → завершение
 │
 └─ ошибка
      ↓
elt.sp_notify_admin
      ↓
msdb.dbo.sp_send_dbmail
      ↓
Profile: DWH Alerts
      ↓
Account: DWH Alert Account
      ↓
smtp.yandex.ru:587
      ↓
почта администратора
```

Database Mail — встроенный механизм SQL Server. SMTP-сервер при этом остаётся внешним сервисом.

## 2. Database Mail XPs

Это серверная возможность SQL Server, позволяющая использовать Database Mail.

Проверка:

```sql
SELECT
    name,
    value,
    value_in_use
FROM sys.configurations
WHERE name = 'Database Mail XPs';
```

Нужно:

```text
value = 1
value_in_use = 1
```

Включение:

```sql
USE master;
GO

EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;

EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
```

`value` — настроенное значение, `value_in_use` — реально применённое.

## 3. Account

Наш Account:

```text
DWH Alert Account
```

Account отвечает на вопрос:

> Через какой SMTP-сервер отправлять письмо?

Наши параметры:

```text
email:       YourChoiseTechMetal@yandex.ru
SMTP:        smtp.yandex.ru
port:        587
SSL:         true
username:    YourChoiseTechMetal@yandex.ru
```

Проверка:

```sql
SELECT
    account_id,
    name,
    description,
    email_address,
    display_name
FROM msdb.dbo.sysmail_account;
```

SMTP-параметры:

```sql
SELECT
    a.account_id,
    a.name AS account_name,
    a.email_address,
    a.display_name,
    s.servername,
    s.port,
    s.enable_ssl,
    s.username
FROM msdb.dbo.sysmail_account a
JOIN msdb.dbo.sysmail_server s
    ON s.account_id = a.account_id;
```

Пароль обратно не читаем.

## 4. Profile

Наш Profile:

```text
DWH Alerts
```

Profile — логическое имя, через которое вызывается отправка.

```sql
SELECT
    profile_id,
    name,
    description
FROM msdb.dbo.sysmail_profile;
```

Profile не хранит сам SMTP-сервер как смысловой объект. Он связывается с Account.

## 5. Как Profile связан с Account

Смысл:

```text
PROFILE
DWH Alerts
    │
    ▼
ACCOUNT
DWH Alert Account
    │
    ▼
smtp.yandex.ru:587
```

Проверка:

```sql
SELECT
    p.profile_id,
    p.name AS profile_name,
    a.account_id,
    a.name AS account_name,
    pa.sequence_number
FROM msdb.dbo.sysmail_profileaccount pa
JOIN msdb.dbo.sysmail_profile p
    ON p.profile_id = pa.profile_id
JOIN msdb.dbo.sysmail_account a
    ON a.account_id = pa.account_id
WHERE p.name = 'DWH Alerts';
```

`sequence_number = 1` означает первый Account для Profile.

## 6. Доступ к Profile

```sql
SELECT
    p.profile_id,
    p.name,
    pp.is_default
FROM msdb.dbo.sysmail_principalprofile pp
JOIN msdb.dbo.sysmail_profile p
    ON p.profile_id = pp.profile_id
WHERE p.name = 'DWH Alerts';
```

У нас Profile настроен как default.

## 7. Отправка письма

Системная процедура:

```sql
msdb.dbo.sp_send_dbmail
```

Тест:

```sql
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = 'DWH Alerts',
    @recipients = 'YourChoiseTechMetal@yandex.ru',
    @subject = N'TEST: Unicode',
    @body = N'Привет! Это тест русского текста из SQL Server.';
```

Для русского текста используем Unicode-литералы:

```sql
N'Ошибка загрузки данных'
```

а параметры нашей процедуры должны быть `NVARCHAR`.

## 8. Наша обёртка

```sql
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
```

ELT не должен знать SMTP username, пароль, сервер и порт.

ELT знает только:

```sql
EXEC elt.sp_notify_admin
    @subject = N'BI_DWH: ELT FAILED',
    @body = N'Загрузка завершилась с ошибкой.';
```

## 9. Почему письмо пришло с `????`

SMTP-доставка уже подтверждена: письмо имеет статус `sent`.

Значит проблема не в SMTP.

Первый тест:

```sql
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = 'DWH Alerts',
    @recipients = 'YourChoiseTechMetal@yandex.ru',
    @subject = N'TEST: Unicode',
    @body = N'Привет! Это тест русского текста из SQL Server.';
```

Если этот текст приходит нормально, проблема находится в формировании предыдущего `@body`.

Проверять нужно прежде всего:

- используются ли `NVARCHAR`;
- есть ли `N` перед русскими строковыми литералами;
- не превращается ли текст раньше в `VARCHAR`.

## 10. Интеграция с Master ELT

У Master ELT есть этапы:

```text
0/7 Load staging
1/7 Validate turnover
2/7 Validate prices
3/7 Validate warehouses
4/7 Load dim_material
5/7 Load dim_warehouse
...
```

Почтовое уведомление должно находиться в `CATCH` верхнего уровня.

Пример:

```sql
BEGIN TRY

    EXEC elt.sp_load_staging;

    EXEC elt.sp_validate_turnover;
    EXEC elt.sp_validate_prices;
    EXEC elt.sp_validate_warehouses;

    EXEC dwh.sp_load_dim_material;
    EXEC dwh.sp_load_dim_warehouse;

    EXEC dwh.sp_load_fact_inventory;
    EXEC dwh.sp_load_fact_prices;

END TRY
BEGIN CATCH

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

    THROW;

END CATCH;
```

## 11. Зачем `THROW`

После отправки письма нужно сохранить исходный статус ошибки:

```text
ошибка
  ├─→ отправить письмо
  └─→ THROW
        ↓
     ELT = FAILED
```

Если только отправить письмо и не сделать `THROW`, внешний планировщик может получить успешный результат.

## 12. Мониторинг Database Mail

Письма:

```sql
SELECT TOP 20
    mailitem_id,
    profile_id,
    recipients,
    subject,
    send_request_date,
    sent_status,
    sent_date
FROM msdb.dbo.sysmail_allitems
ORDER BY send_request_date DESC;
```

Возможные статусы:

```text
sent
failed
unsent
retrying
```

Ошибки Database Mail:

```sql
SELECT TOP 20
    log_date,
    event_type,
    description
FROM msdb.dbo.sysmail_event_log
ORDER BY log_date DESC;
```

## 13. Переменные `$(...)`

В исходном SQL-файле используются:

```text
$(SMTP_FROM_EMAIL)
$(SMTP_FROM_NAME)
$(SMTP_SERVER)
$(SMTP_PORT)
$(SMTP_USERNAME)
$(SMTP_PASSWORD)
$(ADMIN_EMAIL)
```

Это не обычные T-SQL-переменные. Это переменные подстановки внешнего запуска.

Поэтому при прямом запуске через DataGrip:

```sql
@port = $(SMTP_PORT)
```

может привести к:

```text
Incorrect syntax near 'SMTP_PORT'
```

Это объясняет ошибку, которую мы получили в DataGrip.

## 14. Итоговая архитектура

```text
                    SQL SERVER
                        │
                        ▼
                Database Mail XPs
                        │
                        ▼
                 ┌──────────────┐
                 │ DWH Alerts   │
                 │   PROFILE    │
                 └──────┬───────┘
                        │
                        ▼
              ┌───────────────────┐
              │ DWH Alert Account │
              │      ACCOUNT      │
              └─────────┬─────────┘
                        │
                        ▼
                 smtp.yandex.ru
                     :587
                      SSL
                        │
                        ▼
                     Yandex
                        │
                        ▼
                  Администратор
```

ELT взаимодействует только с:

```text
elt.sp_notify_admin
```

## 15. Текущее состояние проекта

Подтверждено:

```text
Database Mail XPs       OK
SMTP Account            OK
SMTP Server             OK
SMTP port 587           OK
SSL                     OK
Profile DWH Alerts      OK
Profile → Account       OK
Profile default         OK
sp_send_dbmail          OK
SMTP delivery           OK
```

Тестовое письмо реально доставлено.

Следующие шаги:

1. Проверить Unicode-тест.
2. Исправить формирование `@body`, если русский текст снова превращается в `????`.
3. Добавить полноценный `TRY/CATCH` в Master ELT.
4. В `CATCH` вызвать `elt.sp_notify_admin`.
5. После уведомления выполнить `THROW`.
6. Проверить искусственной ошибкой весь сценарий.
7. Закрыть почтовый модуль.
8. Вернуться к `QUOTED_IDENTIFIER`.
9. После исправления ELT перейти к ключам и индексам.
