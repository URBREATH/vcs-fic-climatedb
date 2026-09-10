#!/usr/bin/env python3
"""
Climate query function.

Finds the nearest observation station to a WGS84 coordinate and returns
aggregated temperature and precipitation projections for all models and
scenarios as a JSON-serialisable dict.

Usage as a library
------------------
    from query_climate import query_climate, connect_db
    from datetime import date

    db = connect_db("path/to/.env")

    # Single day
    result = query_climate(db, lon=4.35, lat=50.85, date_from=date(2045, 7, 14))

    # One full month – also request event counts and ET0
    result = query_climate(db, lon=4.35, lat=50.85, year=2045, month=7,
                           include=["events", "et0"])

    # Date range with full water-balance analysis
    result = query_climate(db, lon=4.35, lat=50.85,
                           date_from=date(2045, 1, 1), date_to=date(2045, 12, 31),
                           include=["events", "et0", "cwb"])

    import json
    print(json.dumps(result, indent=2, default=str))

Usage from the command line
---------------------------
    python query_climate.py --env path/to/.env --lon 4.35 --lat 50.85 --from 2045-01-01 --to 2045-12-31
    python query_climate.py --env path/to/.env --lon 4.35 --lat 50.85 --year 2045 --month 7
    python query_climate.py --env path/to/.env --lon 4.35 --lat 50.85 --date 2045-07-14
    python query_climate.py --env path/to/.env --lon 4.35 --lat 50.85 --year 2045 --include events et0 cwb

include options
---------------
    events   Threshold event counts + degree-day sums + heatwave/dry-spell streaks
             (get_climate_events). Adds keys: temperature_events, precipitation_events.
    et0      FAO-56 Penman-Monteith reference evapotranspiration per model/scenario
             (get_et0). Requires scalar observations (SWR, LWR, RHmax, RHmin, WindSpeed).
             Adds key: et0.
    cwb      Climatic water balance incl. Thornthwaite-Mather soil moisture model
             (get_cwb). Requires scalar observations. Implies et0 internally.
             Adds key: cwb.
"""

import argparse
import calendar
import json
import os
import sys
from datetime import date
from pathlib import Path

import psycopg2
import psycopg2.extras
from dotenv import load_dotenv


# ── DB connection ──────────────────────────────────────────────────────────────

def connect_db(env_path: str | Path) -> psycopg2.extensions.connection:
    """Open a psycopg2 connection using credentials from an .env file."""
    load_dotenv(env_path)
    return psycopg2.connect(
        host=os.getenv("DB_HOST"),
        dbname=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
        port=int(os.getenv("DB_PORT", 5432)),
        connect_timeout=30,
        options="-c search_path=climate,public",
    )


# ── Stored-function call helper ───────────────────────────────────────────────

def _call_fn(cur, sql: str, params: tuple) -> dict:
    """Execute a stored function that returns JSONB and return it as a dict."""
    cur.execute(sql, params)
    row = cur.fetchone()
    return row[0] if row and row[0] else {}


# ── Include extras ────────────────────────────────────────────────────────────
#
# Each entry maps an include key to:
#   point_fn    – function for date-range queries  (date_from / date_to)
#   annual_fn   – function for year_from / year_to queries
#   point_keys  – top-level JSONB keys to merge from point result
#   annual_keys – top-level JSONB keys to merge from annual result
#
_INCLUDE_CFG = {
    "events": dict(
        point_fn      = "get_climate_events",
        annual_fn     = "get_climate_events_annual",
        seasonal_fn   = "get_climate_events_seasonal",
        doy_fn        = "get_climate_events_day_of_year",
        point_keys    = ["temperature_events", "precipitation_events"],
        annual_keys   = ["events"],
        seasonal_keys = ["events"],
        doy_keys      = ["events"],
    ),
    "et0": dict(
        point_fn      = "get_et0",
        annual_fn     = "get_et0_annual",
        seasonal_fn   = "get_et0_seasonal",
        doy_fn        = "get_et0_day_of_year",
        point_keys    = ["et0_daily", "et0_period_summary"],
        annual_keys   = ["annual_et0"],
        seasonal_keys = ["annual_et0"],
        doy_keys      = ["annual_et0"],
    ),
    "cwb": dict(
        point_fn    = "get_cwb",
        annual_fn   = "get_cwb_annual",
        # No seasonal_fn / doy_fn — cwb requires full-year sequential soil
        # moisture simulation; partial-window variants not yet implemented.
        point_keys  = ["cwb_daily", "cwb_period_summary"],
        annual_keys = ["annual_cwb"],
    ),
}
_VALID_INCLUDE = frozenset(_INCLUDE_CFG)


# ── Main public function ──────────────────────────────────────────────────────

def query_climate(
    conn: psycopg2.extensions.connection,
    lon: float,
    lat: float,
    # Point-in-time variants
    date_from: date | None = None,
    date_to: date | None = None,
    year: int | None = None,
    month: int | None = None,
    # Trend variants
    year_from: int | None = None,
    year_to: int | None = None,
    season: str | None = None,
    day: int | None = None,
    # Optional extras
    include: list[str] | None = None,
) -> dict:
    """
    Query climate projections for the station nearest to (lon, lat).

    All DB functions return JSONB; this function is thin routing glue.

    Period selection — provide exactly one of:
      Point-in-time (aggregates over the period):
        date_from only                    → single day
        date_from + date_to               → explicit date range
        year + month                      → full calendar month
        year only                         → full calendar year

      Trend (one row per year or season):
        year_from + year_to               → annual trend
        year_from + year_to + season      → seasonal trend (spring/summer/autumn/winter)
        year_from + year_to + month + day → same calendar day across years

    include — optional list of extra datasets (point-in-time and annual trend only):
        'events'  threshold event counts, degree-day sums, heatwave/dry-spell streaks
        'et0'     FAO-56 Penman-Monteith ET0  (requires scalar observations)
        'cwb'     Climatic water balance / soil moisture model  (requires scalar obs)
    """
    unknown = set(include or []) - _VALID_INCLUDE
    if unknown:
        raise ValueError(
            f"Unknown include value(s): {unknown}. "
            f"Valid options: {sorted(_VALID_INCLUDE)}"
        )

    with conn.cursor() as cur:

        # ── Trend queries ─────────────────────────────────────────────────────
        if year_from is not None and year_to is not None:

            if month is not None and day is not None:
                result = _call_fn(cur,
                    "SELECT climate.get_climate_day_of_year(%s,%s,%s,%s,%s,%s)",
                    (lon, lat, month, day, year_from, year_to),
                )
                for key in (include or []):
                    cfg = _INCLUDE_CFG[key]
                    if "doy_fn" not in cfg:
                        # cwb day-of-year not yet implemented — silently skip
                        continue
                    extra = _call_fn(cur,
                        f"SELECT climate.{cfg['doy_fn']}(%s,%s,%s,%s,%s,%s)",
                        (lon, lat, month, day, year_from, year_to),
                    )
                    for k in cfg["doy_keys"]:
                        result[k] = extra.get(k)

            elif season is not None:
                result = _call_fn(cur,
                    "SELECT climate.get_climate_seasonal(%s,%s,%s,%s,%s)",
                    (lon, lat, season, year_from, year_to),
                )
                for key in (include or []):
                    cfg = _INCLUDE_CFG[key]
                    if "seasonal_fn" not in cfg:
                        # cwb seasonal not yet implemented — silently skip
                        continue
                    extra = _call_fn(cur,
                        f"SELECT climate.{cfg['seasonal_fn']}(%s,%s,%s,%s,%s)",
                        (lon, lat, season, year_from, year_to),
                    )
                    for k in cfg["seasonal_keys"]:
                        result[k] = extra.get(k)

            else:
                result = _call_fn(cur,
                    "SELECT climate.get_climate_annual(%s,%s,%s,%s)",
                    (lon, lat, year_from, year_to),
                )
                for key in (include or []):
                    cfg = _INCLUDE_CFG[key]
                    extra = _call_fn(cur,
                        f"SELECT climate.{cfg['annual_fn']}(%s,%s,%s,%s)",
                        (lon, lat, year_from, year_to),
                    )
                    for k in cfg["annual_keys"]:
                        result[k] = extra.get(k)

            return result

        # ── Point-in-time queries ─────────────────────────────────────────────
        if year is not None and month is not None:
            date_from = date(year, month, 1)
            date_to   = date(year, month, calendar.monthrange(year, month)[1])
        elif year is not None:
            date_from = date(year, 1, 1)
            date_to   = date(year, 12, 31)
        elif date_from is not None and date_to is None:
            date_to = date_from
        elif date_from is None:
            raise ValueError(
                "Provide one of: (date_from), (date_from+date_to), "
                "(year+month), (year), or (year_from+year_to[+season|+month+day])."
            )

        if date_from > date_to:
            raise ValueError(f"date_from ({date_from}) must not be after date_to ({date_to}).")

        result = _call_fn(cur,
            "SELECT climate.get_climate(%s,%s,%s::date,%s::date)",
            (lon, lat, date_from, date_to),
        )

        for key in (include or []):
            cfg = _INCLUDE_CFG[key]
            extra = _call_fn(cur,
                f"SELECT climate.{cfg['point_fn']}(%s,%s,%s::date,%s::date)",
                (lon, lat, date_from, date_to),
            )
            for k in cfg["point_keys"]:
                result[k] = extra.get(k)

        return result


# ── CLI ───────────────────────────────────────────────────────────────────────

def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Query nearest-station climate projections and print JSON."
    )
    p.add_argument("--env",   required=True, help="Path to .env file with DB credentials")
    p.add_argument("--lon",   required=True, type=float, help="WGS84 longitude")
    p.add_argument("--lat",   required=True, type=float, help="WGS84 latitude")

    grp = p.add_mutually_exclusive_group(required=True)
    grp.add_argument("--date",      help="Single date YYYY-MM-DD")
    grp.add_argument("--from",      dest="date_from", help="Start of range YYYY-MM-DD")
    grp.add_argument("--year",      type=int, help="Full year, or year+month")
    grp.add_argument("--year-from", dest="year_from", type=int, help="Start year for trend queries")

    p.add_argument("--to",       dest="date_to",  help="End of range YYYY-MM-DD (with --from)")
    p.add_argument("--month",    type=int, help="Month 1-12 (with --year or --year-from+--year-to)")
    p.add_argument("--day",      type=int, help="Day 1-31 (with --year-from+--year-to+--month)")
    p.add_argument("--year-to",  dest="year_to",   type=int, help="End year for trend queries")
    p.add_argument("--season",   choices=["spring","summer","autumn","winter"],
                   help="Season for seasonal trend (with --year-from+--year-to)")
    p.add_argument("--include",  nargs="+", choices=sorted(_VALID_INCLUDE), metavar="DATASET",
                   help=f"Extra datasets: {', '.join(sorted(_VALID_INCLUDE))}")
    return p


def main() -> None:
    args = _build_arg_parser().parse_args()

    # Resolve args → query_climate kwargs
    kwargs: dict = {"lon": args.lon, "lat": args.lat, "include": args.include}

    if args.year_from:
        kwargs["year_from"] = args.year_from
        kwargs["year_to"]   = args.year_to
        if args.season:
            kwargs["season"] = args.season
        elif args.month and args.day:
            kwargs["month"] = args.month
            kwargs["day"]   = args.day
    elif args.date:
        kwargs["date_from"] = date.fromisoformat(args.date)
    elif args.date_from:
        kwargs["date_from"] = date.fromisoformat(args.date_from)
        if args.date_to:
            kwargs["date_to"] = date.fromisoformat(args.date_to)
    elif args.year:
        kwargs["year"]  = args.year
        kwargs["month"] = args.month  # may be None → full year

    conn = connect_db(args.env)
    try:
        result = query_climate(conn, **kwargs)
    finally:
        conn.close()

    print(json.dumps(result, indent=2, default=str))


if __name__ == "__main__":
    main()
