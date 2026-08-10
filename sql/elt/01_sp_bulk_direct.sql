-- ============================================================================
-- Файл: 03_bulk_turnover.sql
--
-- Назначение:
--     Непосредственная загрузка одного CSV-файла оборотной ведомости
--     в staging.turnover_raw.
--
-- Архитектурная роль:
--
--     Эта процедура является НИЖНИМ уровнем ETL.
--
--     Она НЕ:
--         - ищет файлы;
--         - сканирует директории;
--         - определяет, новый файл или старый;
--         - считает SHA-256;
--         - управляет elt.file_registry;
--         - решает, нужно ли загружать файл.
--
--     Всем этим занимается:
--
--         elt.sp_load_staging_from_import
--                     ↓
--         elt.sp_load_folder
--
--
--     Эта процедура получает:
--
--         @file_id
--         @file_path
--
--     и выполняет одну конкретную задачу:
--
--         CSV → staging.turnover_raw
--
--
-- Схема:
--
--     /import/turnover/file.csv
--                 │
--                 ▼
--          #bulk_turnover
--                 │
--                 │ BULK INSERT
--                 ▼
--       staging.turnover_raw
--
--
-- ВАЖНО:
--
--     staging является RAW-слоем.
--
--     Поэтому здесь намеренно НЕ выполняются:
--
--         - преобразование дат;
--         - преобразование чисел;
--         - бизнес-валидация;
--         - очистка строк;
--         - исправление ошибок данных.
--
--     Все поля исходного CSV принимаются как NVARCHAR.
--
--     Преобразование типов будет выполняться позднее,
--     при загрузке из staging в DWH.
--
-- ============================================================================


USE BI_DWH;
GO
-- ============================================================================
-- Создание / изменение процедуры
-- ============================================================================

CREATE OR ALTER PROCEDURE elt.sp_bulk_turnover_direct
    @file_id INT,
    @file_path NVARCHAR(1000)
AS
BEGIN

    SET NOCOUNT ON;


    -- ========================================================================
    -- TRY
    --
    -- Вся операция загрузки конкретного файла находится внутри TRY.
    --
    -- Если BULK INSERT или INSERT завершится ошибкой,
    -- управление перейдёт в CATCH.
    -- ========================================================================

    BEGIN TRY


        -- ====================================================================
        -- Временная таблица для непосредственного BULK INSERT
        -- ====================================================================
        --
        -- Почему сначала временная таблица?
        --
        -- Потому что staging.turnover_raw содержит технические поля:
        --
        --     load_id
        --     file_name
        --
        -- а CSV их не содержит.
        --
        -- Поэтому мы сначала загружаем CSV "как есть",
        -- а затем добавляем техническую информацию отдельным INSERT.
        --
        -- Это также делает границу между:
        --
        --     структура CSV
        --
        -- и:
        --
        --     структура staging
        --
        -- максимально очевидной.
        --
        -- ====================================================================

        CREATE TABLE #bulk_turnover
        (
            date NVARCHAR(100) NULL,
            start_date NVARCHAR(100) NULL,
            end_date NVARCHAR(100) NULL,
            warehouse_code NVARCHAR(100) NULL,
            balance_start NVARCHAR(100) NULL,
            income_qty NVARCHAR(100) NULL,
            expense_qty NVARCHAR(100) NULL,
            balance_end NVARCHAR(100) NULL,
            unit NVARCHAR(100) NULL,
            material_id NVARCHAR(100) NULL
        );


        -- ====================================================================
        -- Непосредственная загрузка CSV
        -- ====================================================================
        --
        -- FORMAT = 'CSV'
        --
        -- говорит SQL Server, что входной файл является CSV.
        --
        -- FIELDQUOTE = '"'
        --
        -- указывает стандартный символ кавычек CSV.
        --
        -- FIELDTERMINATOR = ';'
        --
        -- потому что файлы проекта используют ";" как разделитель.
        --
        -- FIRSTROW = 2
        --
        -- пропускает первую строку CSV, содержащую заголовки.
        --
        -- ====================================================================

        DECLARE @sql NVARCHAR(MAX);

        SET @sql = N'BULK INSERT #bulk_turnover
        FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
        WITH (
                FORMAT = ''CSV'',
                DATAFILETYPE = ''widechar'',
                ROWTERMINATOR = ''0x0a00'',
                FIELDQUOTE = ''"'',
                FIELDTERMINATOR = '';'',
                FIRSTROW = 2,
                TABLOCK
            );
        ';
        EXEC sys.sp_executesql @sql;


        -- ====================================================================
        -- Перенос данных из временной bulk-таблицы в staging
        -- ====================================================================
        --
        -- load_id НЕ указываем.
        --
        -- Он заполняется автоматически:
        --
        --     IDENTITY(1,1)
        --
        -- file_name берём из @file_path.
        --
        -- Это сохраняет происхождение каждой строки.
        -- ====================================================================

        INSERT INTO staging.turnover_raw
        (
            file_name,
            date,
            start_date,
            end_date,
            warehouse_code,
            balance_start,
            income_qty,
            expense_qty,
            balance_end,
            unit,
            material_id
        )
        SELECT
            @file_path,
            date,
            start_date,
            end_date,
            warehouse_code,
            balance_start,
            income_qty,
            expense_qty,
            balance_end,
            unit,
            material_id
        FROM #bulk_turnover;


        -- ====================================================================
        -- Завершение
        --
        -- Если мы дошли сюда, BULK INSERT и INSERT завершились успешно.
        --
        -- Процедура просто завершается.
        --
        -- Статус файла:
        --
        --     loaded
        --
        -- будет установлен НЕ ЗДЕСЬ, а родительской процедурой
        -- elt.sp_load_folder.
        -- ====================================================================

    END TRY


    BEGIN CATCH

        -- ====================================================================
        -- Здесь намеренно НЕ обновляем elt.file_registry.
        --
        -- Почему?
        --
        -- Потому что этим занимается родительская процедура:
        --
        --     elt.sp_load_folder
        --
        -- Она поймает нашу ошибку, запишет:
        --
        --     status = failed
        --     error_message = ERROR_MESSAGE()
        --
        -- и затем выполнит THROW.
        --
        -- Таким образом ответственность разделена:
        --
        --     bulk loader
        --         ↓
        --     "я не смог загрузить CSV"
        --
        --     sp_load_folder
        --         ↓
        --     "я фиксирую состояние файла в реестре"
        -- ====================================================================

        THROW;

    END CATCH;

END;
GO
-- ============================================================================
-- Файл: 04_bulk_prices.sql
--
-- Назначение:
--     Непосредственная загрузка одного CSV-файла цен
--     в staging.prices_raw.
--
-- Архитектурная роль:
--
--     CSV → #bulk_prices → staging.prices_raw
--
--     Процедура работает только с одним конкретным файлом.
--
--     Поиск файлов, SHA-256, инкрементальная логика и file_registry
--     находятся на более высоком уровне ETL.
--
-- ============================================================================


USE BI_DWH;
GO


CREATE OR ALTER PROCEDURE elt.sp_bulk_prices_direct
    @file_id INT,
    @file_path NVARCHAR(500)
AS
BEGIN

    SET NOCOUNT ON;


    -- ========================================================================
    -- Основной блок загрузки
    -- ========================================================================

    BEGIN TRY


        -- ====================================================================
        -- Временная таблица.
        --
        -- Её структура соответствует именно CSV-файлу цен.
        --
        -- Технические поля staging:
        --
        --     load_id
        --     file_name
        --
        -- сюда не попадают.
        -- ====================================================================

        CREATE TABLE #bulk_prices
        (
            date NVARCHAR(100) NULL,
            start_date NVARCHAR(100) NULL,
            end_date NVARCHAR(100) NULL,
            material_id NVARCHAR(100) NULL,
            price NVARCHAR(100) NULL
        );


        -- ====================================================================
        -- Загружаем CSV во временную таблицу.
        --
        -- FIRSTROW = 2:
        --     первая строка содержит заголовок.
        --
        -- FIELDTERMINATOR = ';':
        --     поля разделены точкой с запятой.
        --
        -- FORMAT = 'CSV':
        --     включаем CSV-парсер SQL Server.
        -- 
        -- ============================================================================
        -- BULK INSERT
        -- ============================================================================
        --
        -- SQL Server не позволяет использовать переменную напрямую
        -- в конструкции:
        --
        --     BULK INSERT ...
        --     FROM @file_path
        --
        -- Поэтому формируем команду BULK INSERT динамически.
        --
        -- @file_path содержит путь к конкретному CSV-файлу.
        --
        -- REPLACE(...):
        --     экранирует одинарные кавычки внутри пути.
        --
        -- sp_executesql:
        --     выполняет сформированный BULK INSERT.
        -- ============================================================================
        DECLARE @sql NVARCHAR(MAX);

        SET @sql = N'
            BULK INSERT #bulk_prices
            FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
            WITH
            (
                FORMAT = ''CSV'',
                DATAFILETYPE = ''widechar'',
                ROWTERMINATOR = ''0x0a00'',
                FIELDQUOTE = ''"'',
                FIELDTERMINATOR = '';'',
                FIRSTROW = 2,
                TABLOCK
            );
        ';

        EXEC sys.sp_executesql @sql;


        -- ====================================================================
        -- Перенос из bulk-таблицы в RAW staging.
        -- ====================================================================

        INSERT INTO staging.prices_raw
        (
            file_name,
            date,
            start_date,
            end_date,
            material_id,
            price
        )
        SELECT
            @file_path,
            date,
            start_date,
            end_date,
            material_id,
            price
        FROM #bulk_prices;


    END TRY


    BEGIN CATCH

        -- Передаём исходную ошибку вызывающей процедуре.
        --
        -- sp_load_folder затем:
        --
        --     status = failed
        --     error_message = ERROR_MESSAGE()
        --
        -- и повторно выбросит ошибку.
        THROW;

    END CATCH;

END;
GO

-- ============================================================================
-- Файл: 05_bulk_warehouses.sql
--
-- Назначение:
--     Непосредственная загрузка одного CSV-файла складов
--     в staging.warehouses_raw.
--
-- Архитектурная роль:
--
--     CSV → #bulk_warehouses → staging.warehouses_raw
--
--     Это специализированный загрузчик структуры warehouses.
--
-- ============================================================================


USE BI_DWH;
GO


CREATE OR ALTER PROCEDURE elt.sp_bulk_warehouses_direct
    @file_id INT,
    @file_path NVARCHAR(1000)
AS
BEGIN

    SET NOCOUNT ON;


    -- ========================================================================
    -- Основной блок загрузки файла.
    -- ========================================================================

    BEGIN TRY


        -- ====================================================================
        -- Временная таблица.
        --
        -- Здесь структура должна соответствовать CSV warehouses.
        --
        -- Все значения NVARCHAR, потому что staging является RAW-слоем.
        -- ====================================================================

        CREATE TABLE #bulk_warehouses
        (
            date NVARCHAR(100) NULL,
            start_date NVARCHAR(100) NULL,
            end_date NVARCHAR(100) NULL,
            warehouse_code NVARCHAR(100) NULL,
            shop_code NVARCHAR(100) NULL,
            warehouse_type NVARCHAR(100) NULL,
            directorate NVARCHAR(100) NULL,
            mol_id NVARCHAR(100) NULL,
            mol_position NVARCHAR(100) NULL
        );


        -- ====================================================================
        -- Загружаем CSV.
        --
        -- Первая строка пропускается, потому что содержит заголовки.
        -- ====================================================================

        DECLARE @sql NVARCHAR(MAX);

        SET @sql = N'
            BULK INSERT #bulk_warehouses
            FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
            WITH
            (
                FORMAT = ''CSV'',
                ROWTERMINATOR = ''0x0a'',
                FIELDQUOTE = ''"'',
                FIELDTERMINATOR = '';'',
                FIRSTROW = 2,
                TABLOCK
            );
        ';

        EXEC sys.sp_executesql @sql;


        -- ====================================================================
        -- Переносим данные в staging.warehouses_raw.
        --
        -- load_id создаётся автоматически через IDENTITY.
        --
        -- file_name записывается для сохранения lineage:
        --
        --     строка staging → исходный файл.
        -- ====================================================================

        INSERT INTO staging.warehouses_raw
        (
            file_name,
            date,
            start_date,
            end_date,
            warehouse_code,
            shop_code,
            warehouse_type,
            directorate,
            mol_id,
            mol_position
        )
        SELECT
            @file_path,
            date,
            start_date,
            end_date,
            warehouse_code,
            shop_code,
            warehouse_type,
            directorate,
            mol_id,
            mol_position
        FROM #bulk_warehouses;


    END TRY


    BEGIN CATCH

        -- Передаём исходную ошибку родительской процедуре.
        THROW;

    END CATCH;

END;
GO