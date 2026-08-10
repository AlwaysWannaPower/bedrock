from pathlib import Path
import time
import polars as pl


# ============================================================================
# Настройки
# ============================================================================

EXCEL_ROOT = Path("/data/excel")
CSV_ROOT = Path("/data/csv")

SCAN_INTERVAL = 60


# ============================================================================
# Конвертация одного Excel-файла
# ============================================================================


def convert_file(excel_file: Path) -> None:
    """
    Конвертирует один XLSX-файл в CSV.

    Структура каталогов относительно /data/excel
    сохраняется в /data/csv.
    """

    relative_path = excel_file.relative_to(EXCEL_ROOT)

    csv_file = CSV_ROOT / relative_path.with_suffix(".csv")

    # Создаем каталог назначения.
    csv_file.parent.mkdir(parents=True, exist_ok=True)

    # Если CSV уже существует и новее Excel,
    # значит Excel с момента последней конвертации не менялся.
    if csv_file.exists():
        if csv_file.stat().st_mtime >= excel_file.stat().st_mtime:
            return

    print(f"[CONVERT] {excel_file} -> {csv_file}")

    try:
        # Читаем Excel через Polars.
        df = pl.read_excel(
            excel_file,
            engine="calamine",
        )

        # Записываем CSV.
        csv_text = df.write_csv(separator=";")

        csv_file.write_text(csv_text, encoding="utf-16", newline="")
        # csv_file.write_text(csv_text, encoding="utf-8", newline="")
        print(f"[OK] {excel_file.name}: {df.height} rows, {df.width} columns")

    except Exception as exc:
        print(f"[ERROR] Не удалось обработать {excel_file}: {exc}")


# ============================================================================
# Поиск Excel-файлов
# ============================================================================


def scan() -> None:
    """
    Ищет все XLSX-файлы внутри /data/excel
    и конвертирует новые/измененные файлы.
    """

    files = list(EXCEL_ROOT.rglob("*.xlsx"))

    print(f"[SCAN] Найдено Excel-файлов: {len(files)}")

    for excel_file in files:
        convert_file(excel_file)


# ============================================================================
# Основной цикл
# ============================================================================


def main() -> None:
    print("[START] Excel converter started")
    print(f"[INPUT]  {EXCEL_ROOT}")
    print(f"[OUTPUT] {CSV_ROOT}")

    while True:
        try:
            scan()

        except Exception as exc:
            print(f"[ERROR] Ошибка сканирования: {exc}")

        time.sleep(SCAN_INTERVAL)


if __name__ == "__main__":
    main()
