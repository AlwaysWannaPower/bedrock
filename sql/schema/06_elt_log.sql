-- ============================================================================
-- Файл: 06_elt_log.sql
-- Назначение:
--     Реестр файлов для механизма инкрементальной загрузки.
--
-- Что хранит:
--     • путь к файлу;
--     • SHA-256 содержимого;
--     • статус загрузки;
--     • количество строк;
--     • время последней успешной загрузки.
--
-- Почему нужен:
--     SQL Agent каждую ночь сравнивает текущий hash файла с сохранённым.
--     Если hash совпадает → файл пропускается.
--     Если hash отличается → файл считается изменённым.


-- Описание: Таблица логирования elt + таблица watermark для инкремента
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 2. Реестр файлов
--    Храним путь, хэш содержимого и статус загрузки.
--    За счёт этого:
--      - не грузим один и тот же файл повторно (инкрементальность)
--      - видим, если файл изменился, и перегружаем его
--      - повторная загрузка не создаёт дубликатов
-- ----------------------------------------------------------------------------
USE BI_DWH;

IF OBJECT_ID('elt.file_registry', 'U') IS NULL
    BEGIN
        CREATE TABLE
            elt.file_registry
        (
            file_id         INT IDENTITY (1,1) NOT NULL
                CONSTRAINT PK_elt_file_registry PRIMARY KEY,
            source_type     NVARCHAR(50)       NOT NULL, -- turnover / prices / warehouses
            file_name       NVARCHAR(255)      NOT NULL, -- имя файла
            file_path       NVARCHAR(1000)     NOT NULL, -- полный путь внутри контейнера
            file_hash       VARBINARY(32)      NULL,     -- SHA2-256 содержимого файла
            file_size_bytes BIGINT             NULL,     -- размер файла
            status          NVARCHAR(20)       NOT NULL
                CONSTRAINT DF_elt_file_registry_status DEFAULT (N'pending'),
            -- pending / loaded / failed
            rows_loaded     INT                NULL,     -- сколько строк загружено
            loaded_at       DATETIME2          NULL,     -- когда успешно загружен
            error_message   NVARCHAR(MAX)      NULL,     -- ошибка загрузки (если была)
            created_at      DATETIME2          NOT NULL
                CONSTRAINT DF_elt_file_registry_created DEFAULT (SYSDATETIME()),
            updated_at      DATETIME2          NULL,
            CONSTRAINT UQ_elt_file_registry_path UNIQUE (file_path)
        );
    END;
GO

IF OBJECT_ID('elt.elt_log', 'U') IS NOT NULL
    DROP TABLE elt.elt_log;
GO
-- ----------------------------------------------------------------------------
-- 1. Журнал elt
--    Записываем старт/финиш каждой процедуры, статус и текст ошибки.
-- ----------------------------------------------------------------------------
CREATE TABLE
    elt.elt_log
(
    log_id        INT IDENTITY (1,1) NOT NULL
        CONSTRAINT PK_elt_elt_log PRIMARY KEY,
    proc_name     NVARCHAR(200)      NOT NULL, -- имя процедуры
    start_dt      DATETIME2          NOT NULL, -- время старта
    end_dt        DATETIME2          NULL,     -- время завершения
    status        NVARCHAR(20)       NOT NULL, -- SUCCESS / ERROR
    rows_affected INT                NULL,     -- сколько строк обработано
    error_msg     NVARCHAR(MAX)      NULL      -- текст ошибки (если была)
);
GO

