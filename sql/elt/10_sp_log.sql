-- ============================================================================
-- Файл: 10_sp_log.sql
--
-- Назначение:
--     Универсальная процедура записи в журнал ELT (elt.elt_log).
--
-- Зачем нужна:
--     Раньше каждая процедура писала в elt.elt_log своим способом,
--     а часть процедур вообще не логировалась.
--
--     Теперь ВСЕ шаги главного пайплайна (elt.sp_master_etl)
--     логируются единообразно через эту процедуру:
--
--         RUNNING  -> шаг начался
--         SUCCESS  -> шаг завершился успешно
--         ERROR    -> шаг упал (с текстом ошибки)
--
--     Так в журнале видно полную картину:
--
--         какой шаг, когда начался, когда закончился,
--         сколько строк затронул (если известно), с какой ошибкой упал.
--
-- Статусы по ТЗ:
--
--     RUNNING / SUCCESS / ERROR
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

CREATE OR ALTER PROCEDURE elt.sp_log
    @proc_name     NVARCHAR(200),   -- имя процедуры/шага (например N'elt.sp_validate_turnover')
    @status        NVARCHAR(20),    -- RUNNING / SUCCESS / ERROR
    @start_dt      DATETIME2 = NULL,  -- время начала шага (для расчёта длительности)
    @rows_affected INT        = NULL, -- сколько строк обработано (если известно)
    @error_msg     NVARCHAR(MAX) = NULL -- текст ошибки (только для ERROR)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO elt.elt_log
    (
        proc_name,
        start_dt,
        end_dt,
        status,
        rows_affected,
        error_msg
    )
    VALUES
    (
        @proc_name,
        -- Время начала: если не передали — считаем текущий момент.
        ISNULL(@start_dt, SYSDATETIME()),
        -- Время окончания — всегда текущий момент.
        SYSDATETIME(),
        @status,
        @rows_affected,
        @error_msg
    );
END;
GO
