#!/usr/bin/env python3
"""Import the generic Observations/Projections climate data layout."""

from __future__ import annotations

import logging
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date
from pathlib import Path
from typing import Callable

import psycopg2
from psycopg2.extras import execute_values


LOG = logging.getLogger(__name__)
BATCH_SIZE = 50_000
MAX_RETRIES = 5
RETRY_DELAY = 10
SCALAR_VARIABLES = ("LWR", "SWR", "RHmax", "RHmin", "WindSpeed")
OBSERVATION_MODEL = "ERA5"
OBSERVATION_SCENARIO = "ERA5_Observed"


def build_dsn(host: str, port: int, database: str, user: str, password: str,
              sslmode: str = "prefer") -> dict:
    return {
        "host": host,
        "port": port,
        "dbname": database,
        "user": user,
        "password": password,
        "sslmode": sslmode,
        "connect_timeout": 30,
        "keepalives": 1,
        "keepalives_idle": 60,
        "keepalives_interval": 10,
        "keepalives_count": 5,
        "options": "-c search_path=climate,public",
    }


class Database:
    """Connection wrapper with the same reconnect behavior as the source importer."""

    def __init__(self, dsn: dict) -> None:
        self.dsn = dsn
        self.connection = psycopg2.connect(**dsn)

    def reconnect(self) -> None:
        try:
            self.connection.close()
        except Exception:
            pass
        self.connection = psycopg2.connect(**self.dsn)

    def execute_with_retry(self, callback: Callable[["Database"], object]):
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                return callback(self)
            except psycopg2.OperationalError as exc:
                LOG.warning("Database connection lost (%s/%s): %s", attempt, MAX_RETRIES, exc)
                try:
                    self.connection.rollback()
                except Exception:
                    pass
                if attempt == MAX_RETRIES:
                    raise
                time.sleep(RETRY_DELAY)
                self.reconnect()

    def close(self) -> None:
        self.connection.close()


def discover_cities(data_root: Path, requested: list[str] | None = None) -> list[str]:
    """Return exact city folder names found below Observations or Projections."""
    roots = (data_root / "Observations", data_root / "Projections")
    missing = [str(root) for root in roots if not root.is_dir()]
    if missing:
        raise FileNotFoundError("Missing data folder(s): " + ", ".join(missing))
    observation_names = {
        child.name
        for child in roots[0].iterdir()
        if child.is_dir()
    }
    projection_names = {
        child.name
        for child in roots[1].iterdir()
        if child.is_dir()
    }
    if requested:
        requested_names = set(requested)
        missing_observations = sorted(requested_names - observation_names)
        missing_projections = sorted(requested_names - projection_names)
        if missing_observations or missing_projections:
            raise ValueError(
                "Requested city folder is missing. "
                f"Only missing in Observations: {missing_observations or 'none'}; "
                f"only missing in Projections: {missing_projections or 'none'}"
            )
        return sorted(requested_names)
    if observation_names != projection_names:
        only_observations = sorted(observation_names - projection_names)
        only_projections = sorted(projection_names - observation_names)
        raise ValueError(
            "City folder names must match in Observations and Projections. "
            f"Only in Observations: {only_observations or 'none'}; "
            f"only in Projections: {only_projections or 'none'}"
        )
    if not observation_names:
        raise FileNotFoundError("No city folders found below Observations or Projections")
    return sorted(observation_names)


def parse_model_folder(folder_name: str) -> tuple[str, str] | None:
    match = re.match(r"^(\d+)_(.+)$", folder_name)
    return (match.group(1), match.group(2)) if match else None


def parse_scenario_folder(folder_name: str) -> tuple[str, bool]:
    match = re.match(r"^\d+_(ERA5_.+)$", folder_name)
    if match:
        return match.group(1), True
    return folder_name, False


def parse_station_id(filename: str) -> str | None:
    stem = Path(filename).stem
    prefix, separator, suffix = stem.rpartition("_")
    if not separator:
        return None
    if suffix.lower() in {"precipitation", "temperature"}:
        return prefix
    return suffix


def read_precipitation_file(path: Path) -> list[tuple[date, float]]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) < 4:
                continue
            try:
                day = date(int(parts[0]), int(parts[1]), int(parts[2]))
                rows.append((day, float(parts[3])))
            except ValueError:
                continue
    return rows


def read_temperature_file(path: Path) -> list[tuple[date, float, float]]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) < 5:
                continue
            try:
                day = date(int(parts[0]), int(parts[1]), int(parts[2]))
                rows.append((day, float(parts[3]), float(parts[4])))
            except ValueError:
                continue
    return rows


def create_or_get(conn: Database, insert_sql: str, select_sql: str,
                  insert_params: tuple, select_params: tuple) -> int:
    def operation(db: Database) -> int:
        with db.connection.cursor() as cursor:
            cursor.execute(insert_sql, insert_params)
            row = cursor.fetchone()
            if row is None:
                cursor.execute(select_sql, select_params)
                row = cursor.fetchone()
        db.connection.commit()
        return row[0]

    return conn.execute_with_retry(operation)


def upsert_city(conn: Database, name: str) -> int:
    return create_or_get(
        conn,
        "INSERT INTO climate.cities (name) VALUES (%s) ON CONFLICT (name) DO NOTHING RETURNING id",
        "SELECT id FROM climate.cities WHERE name = %s",
        (name,), (name,),
    )


def upsert_model(conn: Database, model_name: str, folder_prefix: str) -> int:
    return create_or_get(
        conn,
        "INSERT INTO climate.climate_models (model_name, folder_prefix) VALUES (%s, %s) "
        "ON CONFLICT (model_name) DO NOTHING RETURNING id",
        "SELECT id FROM climate.climate_models WHERE model_name = %s",
        (model_name, folder_prefix), (model_name,),
    )


def upsert_scenario(conn: Database, scenario_name: str, is_reference: bool = False) -> int:
    return create_or_get(
        conn,
        "INSERT INTO climate.scenarios (scenario_name, is_reference) VALUES (%s, %s) "
        "ON CONFLICT (scenario_name) DO NOTHING RETURNING id",
        "SELECT id FROM climate.scenarios WHERE scenario_name = %s",
        (scenario_name, is_reference), (scenario_name,),
    )


def load_stations(conn: Database, observatory_file: Path, city_id: int) -> int:
    rows = []
    with observatory_file.open(encoding="utf-8") as handle:
        for line in handle:
            parts = line.strip().split("\t")
            if len(parts) < 6:
                continue
            try:
                station_id = parts[0].strip()
                longitude = float(parts[1])
                latitude = float(parts[2])
            except ValueError:
                continue
            if not station_id:
                continue
            height = None
            if len(parts) >= 7:
                try:
                    height = float(parts[3])
                except ValueError:
                    pass
                name, region, country = parts[4].strip(), parts[5].strip(), parts[6].strip()
            else:
                name, region, country = parts[3].strip(), parts[4].strip(), parts[5].strip()
            rows.append((station_id, city_id, longitude, latitude, height, name, region,
                         country, longitude, latitude))

    if not rows:
        LOG.warning("No valid stations found in %s", observatory_file)
        return 0

    def operation(db: Database) -> None:
        with db.connection.cursor() as cursor:
            execute_values(
                cursor,
                """
                INSERT INTO climate.stations
                    (station_id, city_id, longitude, latitude, height,
                     name, region, country_code, geom)
                VALUES %s
                ON CONFLICT (station_id) DO UPDATE SET
                    city_id = EXCLUDED.city_id,
                    longitude = EXCLUDED.longitude,
                    latitude = EXCLUDED.latitude,
                    height = EXCLUDED.height,
                    name = EXCLUDED.name,
                    region = EXCLUDED.region,
                    country_code = EXCLUDED.country_code,
                    geom = EXCLUDED.geom
                """,
                rows,
                template="(%s, %s, %s, %s, %s, %s, %s, %s, "
                         "ST_SetSRID(ST_MakePoint(%s, %s), 4326))",
            )
        db.connection.commit()

    conn.execute_with_retry(operation)
    LOG.info("  %s station(s) from %s", len(rows), observatory_file.name)
    return len(rows)


def insert_rows(dsn: dict, variable: str, rows: list[tuple]) -> int:
    insert_sql = {
        "precipitation": """
            INSERT INTO climate.precipitation_observations
                (station_id, model_id, scenario_id, obs_date, precipitation)
            VALUES %s
            ON CONFLICT (station_id, model_id, scenario_id, obs_date) DO NOTHING
        """,
        "temperature": """
            INSERT INTO climate.temperature_observations
                (station_id, model_id, scenario_id, obs_date, temp_min, temp_max)
            VALUES %s
            ON CONFLICT (station_id, model_id, scenario_id, obs_date) DO NOTHING
        """,
        "scalar": """
            INSERT INTO climate.scalar_observations
                (station_id, model_id, scenario_id, variable, obs_date, value)
            VALUES %s
            ON CONFLICT (station_id, model_id, scenario_id, variable, obs_date) DO NOTHING
        """,
    }[variable]
    db = Database(dsn)
    try:
        for offset in range(0, len(rows), BATCH_SIZE):
            batch = rows[offset:offset + BATCH_SIZE]

            def operation(connection: Database, values=batch) -> None:
                with connection.connection.cursor() as cursor:
                    execute_values(cursor, insert_sql, values)
                connection.connection.commit()

            db.execute_with_retry(operation)
        return len(rows)
    finally:
        db.close()


def rows_for_file(path: Path, variable: str, model_id: int, scenario_id: int,
                  scalar_name: str | None = None) -> list[tuple]:
    station_id = parse_station_id(path.name)
    if station_id is None:
        LOG.warning("Cannot extract station id from %s", path.name)
        return []
    if variable == "temperature":
        return [
            (station_id, model_id, scenario_id, day, minimum, maximum)
            for day, minimum, maximum in read_temperature_file(path)
        ]
    if variable == "precipitation":
        return [
            (station_id, model_id, scenario_id, day, value)
            for day, value in read_precipitation_file(path)
        ]
    return [
        (station_id, model_id, scenario_id, scalar_name, day, value)
        for day, value in read_precipitation_file(path)
    ]


def process_file(dsn: dict, path: Path, variable: str, model_id: int,
                 scenario_id: int, scalar_name: str | None = None) -> int:
    rows = rows_for_file(path, variable, model_id, scenario_id, scalar_name)
    return insert_rows(dsn, variable, rows)


def ingest_files_parallel(dsn: dict, files: list[Path], variable: str,
                          model_id: int, scenario_id: int, workers: int,
                          scalar_name: str | None = None) -> int:
    total = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(process_file, dsn, path, variable, model_id, scenario_id, scalar_name): path
            for path in files
        }
        for future in as_completed(futures):
            path = futures[future]
            try:
                total += future.result()
            except Exception:
                LOG.exception("Import failed for %s", path)
                raise
    return total


def ingest_flat_observations(conn: Database, city_root: Path, dsn: dict,
                             workers: int) -> None:
    model_id = upsert_model(conn, OBSERVATION_MODEL, "OBS")
    scenario_id = upsert_scenario(conn, OBSERVATION_SCENARIO, True)
    for variable, folder in (("precipitation", "Precipitation"), ("temperature", "Temperature")):
        root = city_root / folder
        if not root.is_dir():
            LOG.warning("Observation folder not found: %s", root)
            continue
        files = sorted(root.glob("*.txt"))
        total = ingest_files_parallel(dsn, files, variable, model_id, scenario_id, workers)
        LOG.info("  observations %-13s %s row(s)", variable, f"{total:,}")


def scan_projection_units(conn: Database, root: Path, variable: str) -> list[tuple]:
    units = []
    for model_folder in sorted(root.iterdir()):
        if not model_folder.is_dir():
            continue
        parsed = parse_model_folder(model_folder.name)
        if parsed is None:
            continue
        prefix, model_name = parsed
        model_id = upsert_model(conn, model_name, prefix)
        for scenario_folder in sorted(model_folder.iterdir()):
            if not scenario_folder.is_dir():
                continue
            scenario_name, is_reference = parse_scenario_folder(scenario_folder.name)
            scenario_id = upsert_scenario(conn, scenario_name, is_reference)
            units.append((model_name, scenario_name, scenario_folder, model_id, scenario_id))
    return units


def ingest_projection_variable(conn: Database, city_root: Path, dsn: dict,
                               variable: str, workers: int) -> None:
    root = city_root / variable if variable in SCALAR_VARIABLES else city_root / {
        "precipitation": "Precipitation_corrected",
        "temperature": "Temperature_corrected",
    }[variable]
    if not root.is_dir():
        LOG.warning("Projection folder not found: %s", root)
        return
    units = scan_projection_units(conn, root, "scalar" if variable in SCALAR_VARIABLES else variable)
    for model_name, scenario_name, folder, model_id, scenario_id in units:
        files = sorted(folder.glob("*.txt"))
        scalar_name = variable if variable in SCALAR_VARIABLES else None
        storage_variable = "scalar" if scalar_name else variable
        total = ingest_files_parallel(dsn, files, storage_variable, model_id, scenario_id,
                                      workers, scalar_name)
        LOG.info("  %-13s | %-20s | %-16s | %s row(s)",
                 variable, model_name, scenario_name, f"{total:,}")


def import_city(conn: Database, data_root: Path, city: str, workers: int) -> None:
    observations_root = data_root / "Observations" / city
    projections_root = data_root / "Projections" / city
    if not observations_root.is_dir() and not projections_root.is_dir():
        raise FileNotFoundError(f"No data found for city '{city}'")

    city_id = upsert_city(conn, city)
    station_files = []
    for filename in ("Precipitation_observatories.txt", "Temperature_observatories.txt"):
        candidates = [observations_root / filename, projections_root / filename]
        station_file = next((path for path in candidates if path.is_file()), None)
        if station_file is not None:
            station_files.append(station_file)
            load_stations(conn, station_file, city_id)
    if not station_files:
        raise FileNotFoundError(f"No observatory files found for city '{city}'")

    dsn = conn.dsn
    if observations_root.is_dir():
        ingest_flat_observations(conn, observations_root, dsn, workers)
    if projections_root.is_dir():
        for variable in ("precipitation", "temperature", *SCALAR_VARIABLES):
            ingest_projection_variable(conn, projections_root, dsn, variable, workers)


def refresh_derived_objects(conn: Database) -> None:
    def operation(db: Database) -> None:
        with db.connection.cursor() as cursor:
            cursor.execute("REFRESH MATERIALIZED VIEW climate.mv_annual_temp")
            cursor.execute("REFRESH MATERIALIZED VIEW climate.mv_annual_precip")
            cursor.execute("SELECT climate.refresh_station_voronoi()")
        db.connection.commit()

    conn.execute_with_retry(operation)


def table_counts(conn: Database) -> dict[str, int]:
    tables = (
        "cities", "stations", "climate_models", "scenarios",
        "precipitation_observations", "temperature_observations",
        "scalar_observations", "station_voronoi",
    )
    result = {}
    with conn.connection.cursor() as cursor:
        for table in tables:
            cursor.execute(f"SELECT COUNT(*) FROM climate.{table}")
            result[table] = cursor.fetchone()[0]
    return result