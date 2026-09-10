#!/usr/bin/env python3
"""Run lightweight checks against an installed climate database."""

from __future__ import annotations

import argparse
import getpass
import os

import psycopg2

from import_climate import build_dsn, table_counts, Database


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate a climate database installation.")
    parser.add_argument("--host", default=os.getenv("DB_HOST"), required=not os.getenv("DB_HOST"))
    parser.add_argument("--port", type=int, default=int(os.getenv("DB_PORT", "5432")))
    parser.add_argument("--database", default=os.getenv("DB_NAME"), required=not os.getenv("DB_NAME"))
    parser.add_argument("--user", default=os.getenv("DB_USER"), required=not os.getenv("DB_USER"))
    parser.add_argument("--sslmode", default=os.getenv("DB_SSLMODE", "prefer"))
    args = parser.parse_args()
    password = os.getenv("DB_PASSWORD") or getpass.getpass("PostgreSQL password: ")
    dsn = build_dsn(args.host, args.port, args.database, args.user, password, args.sslmode)
    connection = psycopg2.connect(**dsn)
    connection.close()
    db = Database(dsn)
    try:
        with db.connection.cursor() as cursor:
            cursor.execute("SELECT postgis_version()")
            postgis_version = cursor.fetchone()[0]
            cursor.execute("SELECT climate.get_climate(0, 0, CURRENT_DATE, CURRENT_DATE)")
        print(f"PostGIS: {postgis_version}")
        for table, count in table_counts(db).items():
            print(f"{table:30} {count:,}")
        print("Validation: OK")
    finally:
        db.close()


if __name__ == "__main__":
    main()