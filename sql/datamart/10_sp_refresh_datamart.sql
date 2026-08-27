-- ============================================================================
-- Файл: 10_sp_refresh_datamart.sql
--
-- Назначение:
--     Слой витрин данных (datamart) для BI.
--
-- Зачем нужен отдельный слой (по Кимбаллу и ТЗ):
--     DWH хранит детальные факты и измерения (схема «звезда»).
--     Но BI (Superset) не должен сам считать тяжёлые агрегаты —
--     ТЗ прямо запрещает «тяжёлые агрегации на стороне BI»
--     и требует отклика дашборда ≤ 3 секунд.
--
--     Поэтому витрины СОДЕРЖАТ УЖЕ ПОСЧИТАННЫЕ метрики:
--         1) datamart.inventory_monthly — детализация: месяц × склад × материал
--         2) datamart.turnover_metrics  — агрегат по уровням срезов + MoM
--
-- Метрики по ТЗ (формулы взяты из learn/07_metrics_and_datamart.md):
--
--     stock_value      = Σ (остаток_на_конец × цена_периода)     — сумма запасов
--     avg_qty          = (остаток_начало + остаток_конец) / 2    — средний остаток (шт)
--     avg_stock_value  = Σ (avg_qty × цена)                       — средний остаток (₽)
--     expense_value    = Σ (|расход| × цена)                      — расход в деньгах
--     turnover_ratio   = expense_value / avg_stock_value          — оборачиваемость в разах
--     turnover_days    = 30 × avg_stock_value / expense_value     — оборачиваемость в днях
--
--     MoM (Month-over-Month) = (X_этот_месяц − X_прошлый_месяц) / X_прошлый_месяц
--
-- Уровни срезов (для ролей из ТЗ):
--     company     — вся компания                    (генеральный директор)
--     directorate — дирекция                        (директор по производству/закупкам)
--     shop        — цех                             (начальник цеха)
--     warehouse   — склад                           (начальник склада, менеджер закупок)
--
-- MoM считается ОТДЕЛЬНО для каждого уровня среза — иначе
-- «MoM суммы по всем складам» нельзя получить суммированием
-- MoM отдельных складов.
--
-- Процедура пересобирает витрины ПОЛНОСТЬЮ (DELETE + INSERT).
-- Это самый простой и надёжный способ: витрины — производные объекты,
-- их пересчёт из DWH всегда даёт актуальное состояние.
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
-- ТАБЛИЦА №1: datamart.inventory_monthly
--
-- Детализация: одна строка = месяц × склад × материал.
-- Содержит количества и «денежные» показатели.
-- ============================================================================

IF OBJECT_ID('datamart.inventory_monthly', 'U') IS NULL
    BEGIN
        CREATE TABLE datamart.inventory_monthly
        (
            -- =================================================================
            -- Ключи среза
            -- =================================================================
            month_key      INT             NOT NULL,   -- период: YYYYMM, например 202401
            year_num       INT             NOT NULL,   -- год
            month_num      INT             NOT NULL,   -- месяц (1-12)

            warehouse_code NVARCHAR(50)    NOT NULL,   -- бизнес-ключ склада
            directorate    NVARCHAR(200)   NULL,       -- дирекция склада
            shop_code      NVARCHAR(50)    NULL,       -- цех склада
            warehouse_type NVARCHAR(100)   NULL,       -- тип склада

            material_id    INT             NOT NULL,   -- бизнес-ключ материала
            unit           NVARCHAR(50)    NULL,       -- единица измерения

            -- =================================================================
            -- Меры: количества
            -- =================================================================
            balance_start  DECIMAL(18, 2)  NULL,       -- остаток на начало месяца
            income_qty     DECIMAL(18, 2)  NULL,       -- поступление за месяц
            expense_qty    DECIMAL(18, 2)  NULL,       -- расход за месяц (отрицательный)
            balance_end    DECIMAL(18, 2)  NULL,       -- остаток на конец месяца
            avg_qty        DECIMAL(18, 2)  NULL,       -- средний остаток в шт

            -- =================================================================
            -- Меры: деньги (цена периода × количество)
            -- =================================================================
            price          DECIMAL(18, 2)  NULL,       -- цена материала за период
            stock_value    DECIMAL(18, 2)  NULL,       -- сумма запасов (₽)
            avg_stock_value DECIMAL(18, 2) NULL,       -- средний остаток (₽)
            expense_value  DECIMAL(18, 2)  NULL,       -- расход в деньгах (₽)

            -- Бизнес-ключ витрины: месяц + склад + материал.
            CONSTRAINT PK_inventory_monthly
                PRIMARY KEY (month_key, warehouse_code, material_id)
        );
    END;
GO

-- Индексы для быстрых фильтров в Superset (по складу и материалу).
-- ВАЖНО: с проверкой существования (IF NOT EXISTS) — повторный запуск
-- скрипта (идемпотентный деплой) не падает с «index already exists».
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_inventory_monthly_wh' AND object_id = OBJECT_ID('datamart.inventory_monthly')
)
    CREATE INDEX IX_inventory_monthly_wh
    ON datamart.inventory_monthly (warehouse_code);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_inventory_monthly_mat' AND object_id = OBJECT_ID('datamart.inventory_monthly')
)
    CREATE INDEX IX_inventory_monthly_mat
    ON datamart.inventory_monthly (material_id);
GO

-- ============================================================================
-- ТАБЛИЦА №2: datamart.turnover_metrics
--
-- Агрегат по уровням срезов + MoM для каждой метрики.
-- Именно эту витрину читает дашборд для KPI.
-- ============================================================================

IF OBJECT_ID('datamart.turnover_metrics', 'U') IS NULL
    BEGIN
        CREATE TABLE datamart.turnover_metrics
        (
            month_key   INT             NOT NULL,   -- период: YYYYMM
            year_num    INT             NOT NULL,   -- год
            month_num   INT             NOT NULL,   -- месяц (1-12)
            month_name  NVARCHAR(20)    NOT NULL,   -- название месяца (для осей графиков)

            -- =================================================================
            -- Уровень среза (роль в дашборде)
            -- =================================================================
            agg_level   NVARCHAR(20)    NOT NULL,   -- company / directorate / shop / warehouse
            agg_key     NVARCHAR(200)   NOT NULL,   -- ключ среза: 'ALL' / дирекция / цех / склад

            -- Атрибуты среза (для фильтров в Superset).
            directorate    NVARCHAR(200)   NULL,
            shop_code      NVARCHAR(50)    NULL,
            warehouse_code NVARCHAR(50)    NULL,
            warehouse_type NVARCHAR(100)   NULL,

            -- =================================================================
            -- Метрики (уже посчитанные)
            -- =================================================================
            stock_value     DECIMAL(18, 2) NULL,    -- сумма запасов (₽)
            avg_stock_value DECIMAL(18, 2) NULL,    -- средний остаток (₽)
            expense_value   DECIMAL(18, 2) NULL,    -- расход в деньгах (₽)

            turnover_ratio  DECIMAL(18, 4) NULL,    -- оборачиваемость в разах
            turnover_days   DECIMAL(18, 2) NULL,    -- оборачиваемость в днях

            -- MoM (доли: 0.10 = +10%). NULL — если нет предыдущего месяца.
            mom_stock_value      DECIMAL(18, 4) NULL,
            mom_avg_stock_value  DECIMAL(18, 4) NULL,
            mom_turnover_ratio   DECIMAL(18, 4) NULL,
            mom_turnover_days    DECIMAL(18, 4) NULL,

            CONSTRAINT PK_turnover_metrics
                PRIMARY KEY (month_key, agg_level, agg_key)
        );
    END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_turnover_metrics_wh' AND object_id = OBJECT_ID('datamart.turnover_metrics')
)
    CREATE INDEX IX_turnover_metrics_wh
    ON datamart.turnover_metrics (warehouse_code);
GO

-- ============================================================================
-- ПРОЦЕДУРА ПЕРЕСЧЁТА ВИТРИН
-- ============================================================================

CREATE OR ALTER PROCEDURE datamart.sp_refresh_datamart
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        BEGIN TRANSACTION;

        -- ================================================================
        -- ШАГ 1. Детальная витрина: месяц × склад × материал
        -- ================================================================
        --
        -- Источник: dwh.fact_inventory (факт остатков)
        --           + dwh.fact_prices (цена периода)
        --
        -- Цена берётся через LEFT JOIN: если цены нет — денежные меры
        -- останутся NULL (в наших данных цена есть для всех материалов).
        --
        -- ВАЖНО: в GROUP BY не включаем атрибуты склада (дирекция/цех/тип),
        -- потому что у одного склада может быть несколько версий (SCD2),
        -- а нам нужна одна строка на месяц×склад×материал.
        -- Берём MAX() от атрибутов — внутри месяца версия одна и та же.
        -- ================================================================

        DELETE FROM datamart.inventory_monthly;

        INSERT INTO datamart.inventory_monthly
        (
            month_key,
            year_num,
            month_num,
            warehouse_code,
            directorate,
            shop_code,
            warehouse_type,
            material_id,
            unit,
            balance_start,
            income_qty,
            expense_qty,
            balance_end,
            avg_qty,
            price,
            stock_value,
            avg_stock_value,
            expense_value
        )
        SELECT
            -- Период: ключ YYYYMM из даты начала периода.
            d.year_num * 100 + d.month_num     AS month_key,
            d.year_num,
            d.month_num,

            w.warehouse_code,
            MAX(w.directorate)                 AS directorate,
            MAX(w.shop_code)                   AS shop_code,
            MAX(w.warehouse_type)              AS warehouse_type,

            m.material_id,
            m.unit,

            -- Количества: суммируем по всем строкам факта за месяц.
            SUM(f.balance_start)               AS balance_start,
            SUM(f.income_qty)                  AS income_qty,
            SUM(f.expense_qty)                 AS expense_qty,
            SUM(f.balance_end)                 AS balance_end,

            -- Средний остаток в шт: (начало + конец) / 2.
            (SUM(f.balance_start) + SUM(f.balance_end)) / 2 AS avg_qty,

            -- Цена периода (одна на материал×период, поэтому MAX).
            MAX(p.price)                       AS price,

            -- Сумма запасов: остаток на конец × цена.
            SUM(f.balance_end) * MAX(p.price)  AS stock_value,

            -- Средний остаток в деньгах: avg_qty × цена.
            (SUM(f.balance_start) + SUM(f.balance_end)) / 2
                * MAX(p.price)                 AS avg_stock_value,

            -- Расход в деньгах: |расход| × цена (расход в факте отрицательный).
            SUM(ABS(f.expense_qty)) * MAX(p.price) AS expense_value

        FROM dwh.fact_inventory AS f

        -- Календарь — берём год/месяц по дате начала периода.
        INNER JOIN dwh.dim_date AS d
            ON d.date_key = f.date_key_start

        -- Материал — для бизнес-ключа material_id и единицы измерения.
        INNER JOIN dwh.dim_material AS m
            ON m.material_sk = f.material_sk

        -- Склад — атрибуты той версии склада, что была актуальна на дату факта.
        INNER JOIN dwh.dim_warehouse AS w
            ON w.warehouse_sk = f.warehouse_sk

        -- Цена за тот же период и тот же материал (LEFT JOIN — может не быть).
        LEFT JOIN dwh.fact_prices AS p
            ON p.material_sk = f.material_sk
           AND p.date_key_start = f.date_key_start
           AND p.date_key_end = f.date_key_end

        GROUP BY
            d.year_num,
            d.month_num,
            w.warehouse_code,
            m.material_id,
            m.unit;

        -- ================================================================
        -- ШАГ 2. Агрегаты по уровням срезов
        -- ================================================================
        --
        -- Четыре уровня для четырёх ролей дашборда:
        --     company / directorate / shop / warehouse
        --
        -- Оборачиваемость считается ПОСЛЕ агрегации (из сумм),
        -- а не как среднее из коэффициентов — так корректнее.
        -- ================================================================

        DELETE FROM datamart.turnover_metrics;

        INSERT INTO datamart.turnover_metrics
        (
            month_key, year_num, month_num, month_name,
            agg_level, agg_key,
            directorate, shop_code, warehouse_code, warehouse_type,
            stock_value, avg_stock_value, expense_value,
            turnover_ratio, turnover_days,
            mom_stock_value, mom_avg_stock_value, mom_turnover_ratio, mom_turnover_days
        )

        -- ----------------------------------------------------------------
        -- УРОВЕНЬ 1: вся компания (генеральный директор)
        -- ----------------------------------------------------------------
        SELECT
            i.month_key, i.year_num, i.month_num, dd.month_name,
            N'company' AS agg_level,
            N'ALL'     AS agg_key,
            N'' AS directorate, N'' AS shop_code, N'' AS warehouse_code, NULL AS warehouse_type,
            SUM(i.stock_value)     AS stock_value,
            SUM(i.avg_stock_value) AS avg_stock_value,
            SUM(i.expense_value)   AS expense_value,
            CASE WHEN SUM(i.avg_stock_value) IS NULL OR SUM(i.avg_stock_value) = 0
                 THEN NULL
                 ELSE SUM(i.expense_value) / SUM(i.avg_stock_value) END AS turnover_ratio,
            CASE WHEN SUM(i.expense_value) IS NULL OR SUM(i.expense_value) = 0
                 THEN NULL
                 ELSE 30.0 * SUM(i.avg_stock_value) / SUM(i.expense_value) END AS turnover_days,
            NULL, NULL, NULL, NULL

        FROM datamart.inventory_monthly AS i
        INNER JOIN dwh.dim_date AS dd
            ON dd.full_date = DATEFROMPARTS(i.year_num, i.month_num, 1)
        GROUP BY i.month_key, i.year_num, i.month_num, dd.month_name

        UNION ALL

        -- ----------------------------------------------------------------
        -- УРОВЕНЬ 2: дирекция (директор по производству / закупкам)
        -- ----------------------------------------------------------------
        SELECT
            i.month_key, i.year_num, i.month_num, dd.month_name,
            N'directorate' AS agg_level,
            i.directorate   AS agg_key,
            i.directorate AS directorate, N'' AS shop_code, N'' AS warehouse_code, NULL AS warehouse_type,
            SUM(i.stock_value)     AS stock_value,
            SUM(i.avg_stock_value) AS avg_stock_value,
            SUM(i.expense_value)   AS expense_value,
            CASE WHEN SUM(i.avg_stock_value) IS NULL OR SUM(i.avg_stock_value) = 0
                 THEN NULL
                 ELSE SUM(i.expense_value) / SUM(i.avg_stock_value) END AS turnover_ratio,
            CASE WHEN SUM(i.expense_value) IS NULL OR SUM(i.expense_value) = 0
                 THEN NULL
                 ELSE 30.0 * SUM(i.avg_stock_value) / SUM(i.expense_value) END AS turnover_days,
            NULL, NULL, NULL, NULL

        FROM datamart.inventory_monthly AS i
        INNER JOIN dwh.dim_date AS dd
            ON dd.full_date = DATEFROMPARTS(i.year_num, i.month_num, 1)
        WHERE i.directorate IS NOT NULL
          AND i.directorate <> N''
        GROUP BY i.month_key, i.year_num, i.month_num, dd.month_name, i.directorate

        UNION ALL

        -- ----------------------------------------------------------------
        -- УРОВЕНЬ 3: цех (начальник цеха)
        -- ----------------------------------------------------------------
        SELECT
            i.month_key, i.year_num, i.month_num, dd.month_name,
            N'shop' AS agg_level,
            -- ISNULL: если у цеха нет дирекции, не даём NULL в ключ
            -- (конкатенация с NULL даёт NULL, а agg_key NOT NULL).
            ISNULL(i.directorate, N'') + N' | ' + i.shop_code AS agg_key,
            i.directorate AS directorate, i.shop_code AS shop_code, N'' AS warehouse_code, NULL AS warehouse_type,
            SUM(i.stock_value)     AS stock_value,
            SUM(i.avg_stock_value) AS avg_stock_value,
            SUM(i.expense_value)   AS expense_value,
            CASE WHEN SUM(i.avg_stock_value) IS NULL OR SUM(i.avg_stock_value) = 0
                 THEN NULL
                 ELSE SUM(i.expense_value) / SUM(i.avg_stock_value) END AS turnover_ratio,
            CASE WHEN SUM(i.expense_value) IS NULL OR SUM(i.expense_value) = 0
                 THEN NULL
                 ELSE 30.0 * SUM(i.avg_stock_value) / SUM(i.expense_value) END AS turnover_days,
            NULL, NULL, NULL, NULL

        FROM datamart.inventory_monthly AS i
        INNER JOIN dwh.dim_date AS dd
            ON dd.full_date = DATEFROMPARTS(i.year_num, i.month_num, 1)
        WHERE i.shop_code IS NOT NULL
          AND i.shop_code <> N''
        GROUP BY i.month_key, i.year_num, i.month_num, dd.month_name, i.directorate, i.shop_code

        UNION ALL

        -- ----------------------------------------------------------------
        -- УРОВЕНЬ 4: склад (начальник склада / менеджер закупок)
        -- ----------------------------------------------------------------
        SELECT
            i.month_key, i.year_num, i.month_num, dd.month_name,
            N'warehouse' AS agg_level,
            i.warehouse_code AS agg_key,
            MAX(i.directorate)    AS directorate,
            MAX(i.shop_code)      AS shop_code,
            i.warehouse_code      AS warehouse_code,
            MAX(i.warehouse_type) AS warehouse_type,
            SUM(i.stock_value)     AS stock_value,
            SUM(i.avg_stock_value) AS avg_stock_value,
            SUM(i.expense_value)   AS expense_value,
            CASE WHEN SUM(i.avg_stock_value) IS NULL OR SUM(i.avg_stock_value) = 0
                 THEN NULL
                 ELSE SUM(i.expense_value) / SUM(i.avg_stock_value) END AS turnover_ratio,
            CASE WHEN SUM(i.expense_value) IS NULL OR SUM(i.expense_value) = 0
                 THEN NULL
                 ELSE 30.0 * SUM(i.avg_stock_value) / SUM(i.expense_value) END AS turnover_days,
            NULL, NULL, NULL, NULL

        FROM datamart.inventory_monthly AS i
        INNER JOIN dwh.dim_date AS dd
            ON dd.full_date = DATEFROMPARTS(i.year_num, i.month_num, 1)
        GROUP BY i.month_key, i.year_num, i.month_num, dd.month_name, i.warehouse_code;

        -- ================================================================
        -- ШАГ 3. MoM (Month-over-Month) для каждой метрики
        -- ================================================================
        --
        -- Сравниваем с тем же уровнем среза за предыдущий месяц.
        --
        --     mom = (текущий − предыдущий) / предыдущий
        --
        -- Для января предыдущий месяц — декабрь прошлого года.
        -- Если предыдущего месяца нет (самый первый месяц) — MoM = NULL.
        -- ================================================================

        UPDATE m
        SET
            m.mom_stock_value =
                CASE WHEN prev.stock_value IS NULL OR prev.stock_value = 0
                     THEN NULL
                     ELSE (m.stock_value - prev.stock_value) / prev.stock_value
                END,

            m.mom_avg_stock_value =
                CASE WHEN prev.avg_stock_value IS NULL OR prev.avg_stock_value = 0
                     THEN NULL
                     ELSE (m.avg_stock_value - prev.avg_stock_value) / prev.avg_stock_value
                END,

            m.mom_turnover_ratio =
                -- Проверяем и NULL, и 0: деление на ноль дало бы ошибку 8134.
                CASE WHEN prev.turnover_ratio IS NULL OR prev.turnover_ratio = 0
                     THEN NULL
                     ELSE (m.turnover_ratio - prev.turnover_ratio) / prev.turnover_ratio
                END,

            m.mom_turnover_days =
                CASE WHEN prev.turnover_days IS NULL OR prev.turnover_days = 0
                     THEN NULL
                     ELSE (m.turnover_days - prev.turnover_days) / prev.turnover_days
                END

        FROM datamart.turnover_metrics AS m

        -- Предыдущий месяц: тот же срез (agg_level + agg_key), месяц назад.
        INNER JOIN datamart.turnover_metrics AS prev
            ON prev.agg_level = m.agg_level
           AND prev.agg_key = m.agg_key
           AND prev.month_key =
               CASE
                   WHEN m.month_num = 1
                       THEN (m.year_num - 1) * 100 + 12   -- январь -> декабрь прошлого года
                   ELSE m.month_key - 1                    -- остальные месяцы
               END;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;
END;
GO

-- ============================================================================
-- Самопроверка (можно запустить вручную после ETL):
--
--     SELECT TOP 20 *
--     FROM datamart.turnover_metrics
--     ORDER BY agg_level, month_key, agg_key;
--
--     -- Сумма запасов по компании по месяцам:
--     SELECT month_key, stock_value
--     FROM datamart.turnover_metrics
--     WHERE agg_level = N'company'
--     ORDER BY month_key;
-- ============================================================================
