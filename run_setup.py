#!/usr/bin/env python3
"""Install the climate database objects and import all detected city folders."""

from __future__ import annotations

import argparse
import getpass
import logging
import os
from pathlib import Path

import psycopg2

from import_climate import (
    Database,
    build_dsn,
    discover_cities,
    import_city,
    refresh_derived_objects,
    table_counts,
)


SQL_FILES = (
    "00_base_schema.sql",
    "01_migrate_to_climate_schema.sql",
    "02_add_scalar_observations.sql",
    "03_add_indexes_and_mvs.sql",
    "04_add_et0_functions.sql",
    "05_add_events_functions.sql",
    "06_add_trend_functions.sql",
    "07_add_seasonal_function.sql",
    "08_add_seasonal_events_et0.sql",
    "09_add_day_of_year_events_et0.sql",
    "10_add_cwb_functions.sql",
    "11_add_single_date_overload.sql",
    "12_add_voronoi.sql",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install the climate schema and import Observations/Projections city folders."
    )
    parser.add_argument("--data-root", type=Path, required=True,
                        help="Folder containing Observations/<city> and Projections/<city>")
    parser.add_argument("--city", action="append", dest="cities",
                        help="Import only this city; repeat for multiple cities (default: all)")
    parser.add_argument("--host", default=os.getenv("DB_HOST"), help="PostgreSQL host")
    parser.add_argument("--port", type=int, default=int(os.getenv("DB_PORT", "5432")))
    parser.add_argument("--database", default=os.getenv("DB_NAME"), help="Database name")
    parser.add_argument("--user", default=os.getenv("DB_USER"), help="Database user")
    parser.add_argument("--sslmode", default=os.getenv("DB_SSLMODE", "prefer"))
    parser.add_argument("--workers", type=int, default=4,
                        help="Parallel file import workers per variable (default: 4)")
    parser.add_argument("--sql-dir", type=Path,
                        default=Path(__file__).resolve().parent / "sql")
    return parser.parse_args()


def required_value(value: str | None, label: str) -> str:
    if value:
        return value
    return input(f"{label}: ").strip()


def install_sql(conn, sql_dir: Path) -> None:
    for filename in SQL_FILES:
        path = sql_dir / filename
        if not path.is_file():
            raise FileNotFoundError(f"Required SQL file not found: {path}")
        logging.info("Installing %s", filename)
        with path.open(encoding="utf-8") as handle:
            conn.cursor().execute(handle.read())


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-8s %(message)s",
                        datefmt="%H:%M:%S")
    args = parse_args()
    if args.workers < 1:
        raise SystemExit("--workers must be at least 1")
    data_root = args.data_root.resolve()
    if not data_root.is_dir():
        raise SystemExit(f"Data root does not exist: {data_root}")
    try:
        available = discover_cities(data_root, args.cities)
    except (FileNotFoundError, ValueError) as exc:
        raise SystemExit(str(exc)) from exc

    host = required_value(args.host, "PostgreSQL host")
    database = required_value(args.database, "Database name")
    user = required_value(args.user, "Database user")
    password = os.getenv("DB_PASSWORD") or getpass.getpass("PostgreSQL password: ")
    dsn = build_dsn(host, args.port, database, user, password, args.sslmode)

    logging.info("Connecting to %s:%s/%s", host, args.port, database)
    connection = psycopg2.connect(**dsn)
    connection.autocommit = True
    try:
        install_sql(connection, args.sql_dir.resolve())
    except Exception as exc:
        raise SystemExit(f"Database object installation failed: {exc}") from exc
    finally:
        connection.close()

    db = Database(dsn)
    try:
        cities = args.cities or available
        logging.info("Cities to import: %s", ", ".join(cities))
        for city in cities:
            logging.info("Importing city: %s", city)
            import_city(db, data_root, city, args.workers)
        refresh_derived_objects(db)
        logging.info("Derived views and Voronoi cells refreshed.")
        for table, count in table_counts(db).items():
            logging.info("%-30s %s", table, f"{count:,}")
    finally:
        db.close()


if __name__ == "__main__":
    main()