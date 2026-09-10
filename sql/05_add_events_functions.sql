-- =============================================================================
-- add_events_functions.sql
--
-- Adds climate event counting and degree-day functions to the climate schema.
-- "Events" covers threshold crossings, consecutive-run statistics, and degree-
-- day sums – the metrics powering the "Threshold Analysis" section of
-- analyze.md.
--
-- Prerequisites
-- -------------
--   • migrate_to_climate_schema.sql  (core tables)
--   • add_scalar_observations.sql    (scalar_observations table)
--   • add_indexes_and_mvs.sql        (mv_annual_temp, mv_annual_precip)
--
-- Functions added
-- ---------------
--   climate.get_climate_events(lon, lat, date_from, date_to)
--     – aggregate event counts for any date period
--   climate.get_climate_events(lon, lat, year, month)
--     – convenience: single calendar month
--   climate.get_climate_events(lon, lat, year)
--     – convenience: full calendar year
--   climate.get_climate_events(lon, lat, date)
--     – convenience: single calendar day
--
--   climate.get_climate_events_annual(lon, lat, year_from, year_to)
--     – per-year event counts for long-term trend analysis
--       (mv_annual_temp / mv_annual_precip for speed;
--        raw tables only for consecutive-run stats)
--
-- Metrics returned  (per model × scenario [× year for the annual variant])
-- -------------------------------------------------------------------------
--   Temperature thresholds:
--     heat_days            T_max > 30 °C
--     desert_days          T_max > 35 °C
--     tropical_nights      T_min > 20 °C
--     frost_days           T_min <  0 °C
--     ice_days             T_max <  0 °C
--     max_heatwave_days    longest consecutive T_max > 30 streak [days]
--   Degree days:
--     hdd18                heating degree days, base 18 °C
--     cdd22                cooling degree days, base 22 °C
--     gdd5                 growing degree days, base  5 °C
--     gdd10                growing degree days, base 10 °C
--   Precipitation thresholds:
--     wet_days             precip ≥  1 mm
--     dry_days             precip <  1 mm
--     heavy_rain_days      precip ≥ 10 mm
--     very_heavy_rain_days precip ≥ 20 mm
--     total_precip_mm      sum of daily precipitation
--     max_daily_precip_mm  peak daily precipitation
--     max_dry_spell_days   longest consecutive precip < 1 mm streak [days]
--
-- Gaps-and-islands approach for consecutive runs
-- -----------------------------------------------
--   cool_grp = SUM(temp_max <= 30) OVER (... ORDER BY obs_date)
--   All days in the same hot streak share the same cool_grp value.
--   → MAX(COUNT(*) GROUP BY cool_grp) = longest heatwave.
--
--   Year boundaries act as hard resets (PARTITION BY year).
--   A heatwave spanning Dec-31 → Jan-1 is counted separately in each year.
--   Same logic applies to dry spells via wet_grp.
--
-- Usage
-- -----
--   SELECT climate.get_climate_events(4.35, 50.85, '2045-06-01'::date, '2045-08-31'::date);
--   SELECT climate.get_climate_events(4.35, 50.85, 2045, 7);
--   SELECT climate.get_climate_events(4.35, 50.85, 2045);
--   SELECT climate.get_climate_events(4.35, 50.85, '2045-07-14'::date);
--   SELECT climate.get_climate_events_annual(4.35, 50.85, 2025, 2100);
-- =============================================================================

SET search_path TO climate, public;


-- =============================================================================
-- 1.  Core: date range → single aggregate per (model × scenario)
--     Scans raw observation tables. Works for any period length.
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_climate_events(
    p_lon       double precision,
    p_lat       double precision,
    p_date_from date,
    p_date_to   date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = climate, public
AS $func$
DECLARE
    v_station_id       text;
    v_station_json     jsonb;
    v_temp_events      jsonb;
    v_precip_events    jsonb;
    v_wind_events      jsonb;
    v_humidity_events  jsonb;
    v_radiation_events jsonb;
    v_combined_events  jsonb;
BEGIN
    -- ── 1. Nearest station ────────────────────────────────────────────────────
    SELECT
        s.station_id,
        jsonb_build_object(
            'station_id',   s.station_id,
            'name',         s.name,
            'city',         c.name,
            'region',       s.region,
            'country_code', s.country_code,
            'latitude',     s.latitude,
            'longitude',    s.longitude,
            'height_m',     s.height,
            'distance_m',   ROUND(
                                ST_Distance(
                                    s.geom::geography,
                                    ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography
                                )::numeric, 1
                            ),
            'voronoi_cell', (
                SELECT ST_AsGeoJSON(v.geom, 6)::jsonb
                FROM climate.station_voronoi v
                WHERE v.station_id = s.station_id
            )
        )
    INTO v_station_id, v_station_json
    FROM climate.stations s
    LEFT JOIN climate.cities c ON c.id = s.city_id
    ORDER BY s.geom <-> ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)
    LIMIT 1;

    IF v_station_id IS NULL THEN
        RAISE EXCEPTION 'No stations found in the database.';
    END IF;

    -- ── 2. Temperature events + max heatwave length ───────────────────────────
    SELECT jsonb_agg(
        to_jsonb(r) ORDER BY r.is_reference DESC, r.scenario_name, r.model_name
    )
    INTO v_temp_events
    FROM (
        WITH daily AS (
            SELECT
                model_id,
                scenario_id,
                temp_min,
                temp_max,
                (temp_min + temp_max) / 2.0 AS tmean,
                -- group key increments on every non-hot day
                SUM(CASE WHEN temp_max <= 30 THEN 1 ELSE 0 END)
                    OVER (PARTITION BY model_id, scenario_id ORDER BY obs_date) AS cool_grp
            FROM climate.temperature_observations
            WHERE station_id = v_station_id
              AND obs_date BETWEEN p_date_from AND p_date_to
        ),
        hw AS (
            SELECT model_id, scenario_id, MAX(cnt)::int AS max_heatwave_days
            FROM (
                SELECT model_id, scenario_id, cool_grp, COUNT(*) AS cnt
                FROM daily
                WHERE temp_max > 30
                GROUP BY model_id, scenario_id, cool_grp
            ) x
            GROUP BY model_id, scenario_id
        )
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            COUNT(*) FILTER (WHERE d.temp_max > 30)::int          AS heat_days,
            COUNT(*) FILTER (WHERE d.temp_max > 35)::int          AS desert_days,
            COUNT(*) FILTER (WHERE d.temp_min > 20)::int          AS tropical_nights,
            COUNT(*) FILTER (WHERE d.temp_min <  0)::int          AS frost_days,
            COUNT(*) FILTER (WHERE d.temp_max <  0)::int          AS ice_days,
            COALESCE(MAX(hw.max_heatwave_days), 0)                AS max_heatwave_days,
            ROUND(SUM(GREATEST(0, 18.0 - d.tmean))::numeric, 1)  AS hdd18,
            ROUND(SUM(GREATEST(0, d.tmean - 22.0))::numeric, 1)  AS cdd22,
            ROUND(SUM(GREATEST(0, d.tmean -  5.0))::numeric, 1)  AS gdd5,
            ROUND(SUM(GREATEST(0, d.tmean - 10.0))::numeric, 1)  AS gdd10,
            COUNT(*)::int                                          AS days
        FROM daily d
        JOIN climate.climate_models m  ON m.id = d.model_id
        JOIN climate.scenarios      s  ON s.id = d.scenario_id
        LEFT JOIN hw                   ON hw.model_id    = d.model_id
                                      AND hw.scenario_id = d.scenario_id
        GROUP BY m.model_name, s.scenario_name, s.is_reference
    ) r;

    -- ── 3. Precipitation events + max dry-spell length ────────────────────────
    SELECT jsonb_agg(
        to_jsonb(r) ORDER BY r.is_reference DESC, r.scenario_name, r.model_name
    )
    INTO v_precip_events
    FROM (
        WITH daily AS (
            SELECT
                model_id,
                scenario_id,
                precipitation,
                -- group key increments on every wet day
                SUM(CASE WHEN precipitation >= 1.0 THEN 1 ELSE 0 END)
                    OVER (PARTITION BY model_id, scenario_id ORDER BY obs_date) AS wet_grp
            FROM climate.precipitation_observations
            WHERE station_id = v_station_id
              AND obs_date BETWEEN p_date_from AND p_date_to
        ),
        ds AS (
            SELECT model_id, scenario_id, MAX(cnt)::int AS max_dry_spell_days
            FROM (
                SELECT model_id, scenario_id, wet_grp, COUNT(*) AS cnt
                FROM daily
                WHERE precipitation < 1.0
                GROUP BY model_id, scenario_id, wet_grp
            ) x
            GROUP BY model_id, scenario_id
        )
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            ROUND(SUM(d.precipitation)::numeric, 1)                    AS total_precip_mm,
            ROUND(MAX(d.precipitation)::numeric, 2)                    AS max_daily_precip_mm,
            COUNT(*) FILTER (WHERE d.precipitation >= 1.0)::int        AS wet_days,
            COUNT(*) FILTER (WHERE d.precipitation <  1.0)::int        AS dry_days,
            COUNT(*) FILTER (WHERE d.precipitation >= 10.0)::int       AS heavy_rain_days,
            COUNT(*) FILTER (WHERE d.precipitation >= 20.0)::int       AS very_heavy_rain_days,
            COALESCE(MAX(ds.max_dry_spell_days), 0)                    AS max_dry_spell_days,
            COUNT(*)::int                                               AS days
        FROM daily d
        JOIN climate.climate_models m  ON m.id = d.model_id
        JOIN climate.scenarios      s  ON s.id = d.scenario_id
        LEFT JOIN ds                   ON ds.model_id    = d.model_id
                                      AND ds.scenario_id = d.scenario_id
        GROUP BY m.model_name, s.scenario_name, s.is_reference
    ) r;

    -- ── 4. Wind events ────────────────────────────────────────────────────────
    SELECT jsonb_agg(
        to_jsonb(r) ORDER BY r.is_reference DESC, r.scenario_name, r.model_name
    )
    INTO v_wind_events
    FROM (
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            ROUND(AVG(obs.value)::numeric, 2)                            AS mean_wind_speed,
            ROUND(MAX(obs.value)::numeric, 2)                            AS max_wind_speed,
            COUNT(*) FILTER (WHERE obs.value <  1.0)::int                AS calm_days,
            COUNT(*) FILTER (WHERE obs.value > 10.0)::int                AS strong_wind_days,
            COUNT(*) FILTER (WHERE obs.value > 17.0)::int                AS storm_days,
            COUNT(*)::int                                                 AS days
        FROM climate.scalar_observations obs
        JOIN climate.climate_models m ON m.id = obs.model_id
        JOIN climate.scenarios      s ON s.id = obs.scenario_id
        WHERE obs.station_id = v_station_id
          AND obs.variable   = 'WindSpeed'
          AND obs.obs_date BETWEEN p_date_from AND p_date_to
        GROUP BY m.model_name, s.scenario_name, s.is_reference
    ) r;

    -- ── 5. Humidity events (RHmax + RHmin joined at day level) ────────────────
    SELECT jsonb_agg(
        to_jsonb(r) ORDER BY r.is_reference DESC, r.scenario_name, r.model_name
    )
    INTO v_humidity_events
    FROM (
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            ROUND(AVG((rx.value + rn.value) / 2.0)::numeric, 1)         AS mean_rh,
            ROUND(AVG(rx.value)::numeric, 1)                             AS mean_rh_max,
            ROUND(AVG(rn.value)::numeric, 1)                             AS mean_rh_min,
            COUNT(*) FILTER (WHERE rx.value > 90.0)::int                 AS high_humidity_days,
            COUNT(*) FILTER (WHERE rn.value < 30.0)::int                 AS low_humidity_days,
            COUNT(*)::int                                                 AS days
        FROM climate.scalar_observations rx
        JOIN climate.scalar_observations rn
            ON  rn.station_id  = rx.station_id
            AND rn.model_id    = rx.model_id
            AND rn.scenario_id = rx.scenario_id
            AND rn.obs_date    = rx.obs_date
            AND rn.variable    = 'RHmin'
        JOIN climate.climate_models m ON m.id = rx.model_id
        JOIN climate.scenarios      s ON s.id = rx.scenario_id
        WHERE rx.station_id = v_station_id
          AND rx.variable   = 'RHmax'
          AND rx.obs_date BETWEEN p_date_from AND p_date_to
        GROUP BY m.model_name, s.scenario_name, s.is_reference
    ) r;

    -- ── 6. Radiation events (SWR primary; LWR as summary stats) ──────────────
    SELECT jsonb_agg(
        to_jsonb(r) ORDER BY r.is_reference DESC, r.scenario_name, r.model_name
    )
    INTO v_radiation_events
    FROM (
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            ROUND(AVG(swr.value)::numeric, 2)                            AS mean_swr_w_m2,
            ROUND(MAX(swr.value)::numeric, 2)                            AS max_swr_w_m2,
            COUNT(*) FILTER (WHERE swr.value > 200.0)::int               AS high_solar_days,
            COUNT(*) FILTER (WHERE swr.value <  50.0)::int               AS low_solar_days,
            ROUND((SUM(swr.value) * 24.0 / 1000.0)::numeric, 1)         AS total_solar_kwh_m2,
            ROUND(AVG(lwr.value)::numeric, 2)                            AS mean_lwr_w_m2,
            ROUND(MIN(lwr.value)::numeric, 2)                            AS min_lwr_w_m2,
            ROUND(MAX(lwr.value)::numeric, 2)                            AS max_lwr_w_m2,
            COUNT(*)::int                                                 AS days
        FROM climate.scalar_observations swr
        LEFT JOIN climate.scalar_observations lwr
            ON  lwr.station_id  = swr.station_id
            AND lwr.model_id    = swr.model_id
            AND lwr.scenario_id = swr.scenario_id
            AND lwr.obs_date    = swr.obs_date
            AND lwr.variable    = 'LWR'
        JOIN climate.climate_models m ON m.id = swr.model_id
        JOIN climate.scenarios      s ON s.id = swr.scenario_id
        WHERE swr.station_id = v_station_id
          AND swr.variable   = 'SWR'
          AND swr.obs_date BETWEEN p_date_from AND p_date_to
        GROUP BY m.model_name, s.scenario_name, s.is_reference
    ) r;

    -- ── 7. Combined cross-variable events ─────────────────────────────────────
    --       hot_and_dry_days   T_max > 30 °C  AND RH_min < 30 %
    --       stagnation_days    T_mean > 25 °C AND wind  < 2 m/s
    --       hot_humid_nights   T_min > 20 °C  AND RH_max > 80 %
    SELECT jsonb_agg(
        to_jsonb(r) ORDER BY r.is_reference DESC, r.scenario_name, r.model_name
    )
    INTO v_combined_events
    FROM (
        WITH daily AS (
            SELECT
                t.model_id,
                t.scenario_id,
                (t.temp_min + t.temp_max) / 2.0 AS tmean,
                t.temp_max,
                t.temp_min,
                w.value  AS wind_speed,
                rx.value AS rh_max,
                rn.value AS rh_min
            FROM climate.temperature_observations t
            LEFT JOIN climate.scalar_observations w
                ON  w.station_id  = t.station_id
                AND w.model_id    = t.model_id
                AND w.scenario_id = t.scenario_id
                AND w.obs_date    = t.obs_date
                AND w.variable    = 'WindSpeed'
            LEFT JOIN climate.scalar_observations rx
                ON  rx.station_id  = t.station_id
                AND rx.model_id    = t.model_id
                AND rx.scenario_id = t.scenario_id
                AND rx.obs_date    = t.obs_date
                AND rx.variable    = 'RHmax'
            LEFT JOIN climate.scalar_observations rn
                ON  rn.station_id  = t.station_id
                AND rn.model_id    = t.model_id
                AND rn.scenario_id = t.scenario_id
                AND rn.obs_date    = t.obs_date
                AND rn.variable    = 'RHmin'
            WHERE t.station_id = v_station_id
              AND t.obs_date BETWEEN p_date_from AND p_date_to
        )
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            COUNT(*) FILTER (WHERE d.temp_max > 30 AND d.rh_min  < 30)::int AS hot_and_dry_days,
            COUNT(*) FILTER (WHERE d.tmean    > 25 AND d.wind_speed < 2)::int AS stagnation_days,
            COUNT(*) FILTER (WHERE d.temp_min > 20 AND d.rh_max  > 80)::int AS hot_humid_nights,
            COUNT(*)::int                                                      AS days
        FROM daily d
        JOIN climate.climate_models m ON m.id = d.model_id
        JOIN climate.scenarios      s ON s.id = d.scenario_id
        GROUP BY m.model_name, s.scenario_name, s.is_reference
    ) r;

    RETURN jsonb_build_object(
        'nearest_station',      v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'date_from',  p_date_from::text,
            'date_to',    p_date_to::text
        ),
        'temperature_events',   COALESCE(v_temp_events,      '[]'::jsonb),
        'precipitation_events', COALESCE(v_precip_events,    '[]'::jsonb),
        'wind_events',          COALESCE(v_wind_events,      '[]'::jsonb),
        'humidity_events',      COALESCE(v_humidity_events,  '[]'::jsonb),
        'radiation_events',     COALESCE(v_radiation_events, '[]'::jsonb),
        'combined_events',      COALESCE(v_combined_events,  '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_climate_events(double precision, double precision, date, date) IS
'Returns climate event counts, degree-day sums, and consecutive-run stats
(heatwave / dry-spell length) for all models × scenarios, for the station
nearest to (p_lon, p_lat) within [p_date_from, p_date_to].
Result keys: nearest_station, query, temperature_events, precipitation_events,
wind_events, humidity_events, radiation_events, combined_events.';


-- =============================================================================
-- 1b.  Convenience overloads → all delegate to the date-range core above
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_climate_events(
    p_lon   double precision,
    p_lat   double precision,
    p_year  integer,
    p_month integer
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = climate, public
AS $func$
    SELECT climate.get_climate_events(
        p_lon, p_lat,
        make_date(p_year, p_month, 1),
        (make_date(p_year, p_month, 1) + interval '1 month' - interval '1 day')::date
    );
$func$;

COMMENT ON FUNCTION climate.get_climate_events(double precision, double precision, integer, integer) IS
'Convenience overload: queries a full calendar month. Delegates to the date-range variant.';


CREATE OR REPLACE FUNCTION climate.get_climate_events(
    p_lon  double precision,
    p_lat  double precision,
    p_year integer
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = climate, public
AS $func$
    SELECT climate.get_climate_events(
        p_lon, p_lat,
        make_date(p_year, 1,  1),
        make_date(p_year, 12, 31)
    );
$func$;

COMMENT ON FUNCTION climate.get_climate_events(double precision, double precision, integer) IS
'Convenience overload: queries a full calendar year. Delegates to the date-range variant.';


CREATE OR REPLACE FUNCTION climate.get_climate_events(
    p_lon  double precision,
    p_lat  double precision,
    p_date date
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = climate, public
AS $func$
    SELECT climate.get_climate_events(p_lon, p_lat, p_date, p_date);
$func$;

COMMENT ON FUNCTION climate.get_climate_events(double precision, double precision, date) IS
'Convenience overload: queries a single calendar day. Delegates to the date-range variant.';


-- =============================================================================
-- 2.  Annual trend: year_from → year_to, one row per (model × scenario × year)
--
--     Simple event counts come from mv_annual_temp / mv_annual_precip (fast).
--     Consecutive heatwave and dry-spell lengths are computed from raw tables
--     using year-partitioned gaps-and-islands window functions.
--     Year boundaries act as hard resets, so cross-year runs are split.
--
--   SELECT climate.get_climate_events_annual(4.35, 50.85, 2025, 2100);
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_climate_events_annual(
    p_lon       double precision,
    p_lat       double precision,
    p_year_from integer,
    p_year_to   integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = climate, public
AS $func$
DECLARE
    v_station_id   text;
    v_station_json jsonb;
    v_events       jsonb;
BEGIN
    -- ── 1. Nearest station ────────────────────────────────────────────────────
    SELECT
        s.station_id,
        jsonb_build_object(
            'station_id',   s.station_id,
            'name',         s.name,
            'city',         c.name,
            'region',       s.region,
            'country_code', s.country_code,
            'latitude',     s.latitude,
            'longitude',    s.longitude,
            'height_m',     s.height,
            'distance_m',   ROUND(
                                ST_Distance(
                                    s.geom::geography,
                                    ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography
                                )::numeric, 1
                            ),
            'voronoi_cell', (
                SELECT ST_AsGeoJSON(v.geom, 6)::jsonb
                FROM climate.station_voronoi v
                WHERE v.station_id = s.station_id
            )
        )
    INTO v_station_id, v_station_json
    FROM climate.stations s
    LEFT JOIN climate.cities c ON c.id = s.city_id
    ORDER BY s.geom <-> ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)
    LIMIT 1;

    IF v_station_id IS NULL THEN
        RAISE EXCEPTION 'No stations found in the database.';
    END IF;

    -- ── 2. MV counts + raw consecutive-run stats ──────────────────────────────
    SELECT jsonb_agg(
        to_jsonb(r) ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.year
    )
    INTO v_events
    FROM (
        WITH
        -- Longest consecutive T_max > 30 streak per (model, scenario, year).
        -- obs_date range filter uses actual dates so the composite index
        -- (station_id, model_id, scenario_id, obs_date) is used as a range scan.
        hw_daily AS (
            SELECT
                model_id,
                scenario_id,
                EXTRACT(YEAR FROM obs_date)::int AS year,
                temp_max,
                SUM(CASE WHEN temp_max <= 30 THEN 1 ELSE 0 END)
                    OVER (
                        PARTITION BY model_id, scenario_id,
                                     EXTRACT(YEAR FROM obs_date)::int
                        ORDER BY obs_date
                    ) AS cool_grp
            FROM climate.temperature_observations
            WHERE station_id = v_station_id
              AND obs_date >= make_date(p_year_from, 1,  1)
              AND obs_date <= make_date(p_year_to,  12, 31)
        ),
        hw_max AS (
            SELECT model_id, scenario_id, year, MAX(cnt)::int AS max_heatwave_days
            FROM (
                SELECT model_id, scenario_id, year, cool_grp, COUNT(*) AS cnt
                FROM hw_daily
                WHERE temp_max > 30
                GROUP BY model_id, scenario_id, year, cool_grp
            ) x
            GROUP BY model_id, scenario_id, year
        ),

        -- Longest consecutive precip < 1 mm streak per (model, scenario, year).
        ds_daily AS (
            SELECT
                model_id,
                scenario_id,
                EXTRACT(YEAR FROM obs_date)::int AS year,
                precipitation,
                SUM(CASE WHEN precipitation >= 1.0 THEN 1 ELSE 0 END)
                    OVER (
                        PARTITION BY model_id, scenario_id,
                                     EXTRACT(YEAR FROM obs_date)::int
                        ORDER BY obs_date
                    ) AS wet_grp
            FROM climate.precipitation_observations
            WHERE station_id = v_station_id
              AND obs_date >= make_date(p_year_from, 1,  1)
              AND obs_date <= make_date(p_year_to,  12, 31)
        ),
        ds_max AS (
            SELECT model_id, scenario_id, year, MAX(cnt)::int AS max_dry_spell_days
            FROM (
                SELECT model_id, scenario_id, year, wet_grp, COUNT(*) AS cnt
                FROM ds_daily
                WHERE precipitation < 1.0
                GROUP BY model_id, scenario_id, year, wet_grp
            ) x
            GROUP BY model_id, scenario_id, year
        ),

        -- ── Scalar variable annual aggregates (wind / humidity / radiation) ────
        scalar_annual AS (
            SELECT
                model_id,
                scenario_id,
                EXTRACT(YEAR FROM obs_date)::int                                      AS year,
                ROUND(AVG(value) FILTER (WHERE variable = 'WindSpeed')::numeric,  2) AS mean_wind_speed,
                ROUND(MAX(value) FILTER (WHERE variable = 'WindSpeed')::numeric,  2) AS max_wind_speed,
                COUNT(*) FILTER (WHERE variable = 'WindSpeed' AND value <  1.0)::int AS calm_days,
                COUNT(*) FILTER (WHERE variable = 'WindSpeed' AND value > 10.0)::int AS strong_wind_days,
                COUNT(*) FILTER (WHERE variable = 'WindSpeed' AND value > 17.0)::int AS storm_days,
                ROUND(AVG(value) FILTER (WHERE variable = 'RHmax')::numeric,       1) AS mean_rh_max,
                ROUND(AVG(value) FILTER (WHERE variable = 'RHmin')::numeric,       1) AS mean_rh_min,
                COUNT(*) FILTER (WHERE variable = 'RHmax' AND value > 90.0)::int    AS high_humidity_days,
                COUNT(*) FILTER (WHERE variable = 'RHmin' AND value < 30.0)::int    AS low_humidity_days,
                ROUND(AVG(value) FILTER (WHERE variable = 'SWR')::numeric,         2) AS mean_swr_w_m2,
                ROUND(MAX(value) FILTER (WHERE variable = 'SWR')::numeric,         2) AS max_swr_w_m2,
                COUNT(*) FILTER (WHERE variable = 'SWR' AND value > 200.0)::int     AS high_solar_days,
                COUNT(*) FILTER (WHERE variable = 'SWR' AND value <  50.0)::int     AS low_solar_days,
                ROUND((SUM(value) FILTER (WHERE variable = 'SWR') * 24.0 / 1000.0)::numeric, 1) AS total_solar_kwh_m2,
                ROUND(AVG(value) FILTER (WHERE variable = 'LWR')::numeric,         2) AS mean_lwr_w_m2,
                ROUND(MIN(value) FILTER (WHERE variable = 'LWR')::numeric,         2) AS min_lwr_w_m2,
                ROUND(MAX(value) FILTER (WHERE variable = 'LWR')::numeric,         2) AS max_lwr_w_m2
            FROM climate.scalar_observations
            WHERE station_id = v_station_id
              AND obs_date >= make_date(p_year_from, 1,  1)
              AND obs_date <= make_date(p_year_to,  12, 31)
            GROUP BY model_id, scenario_id, EXTRACT(YEAR FROM obs_date)::int
        ),

        -- ── Combined cross-variable annual counts ────────────────────────────
        combined_annual AS (
            SELECT
                t.model_id,
                t.scenario_id,
                EXTRACT(YEAR FROM t.obs_date)::int                                       AS year,
                COUNT(*) FILTER (WHERE t.temp_max > 30 AND rn.value < 30)::int           AS hot_and_dry_days,
                COUNT(*) FILTER (WHERE (t.temp_min + t.temp_max) / 2.0 > 25
                                   AND w.value < 2)::int                                 AS stagnation_days,
                COUNT(*) FILTER (WHERE t.temp_min > 20 AND rx.value > 80)::int           AS hot_humid_nights
            FROM climate.temperature_observations t
            LEFT JOIN climate.scalar_observations w
                ON  w.station_id  = t.station_id AND w.model_id    = t.model_id
                AND w.scenario_id = t.scenario_id AND w.obs_date   = t.obs_date
                AND w.variable    = 'WindSpeed'
            LEFT JOIN climate.scalar_observations rx
                ON  rx.station_id  = t.station_id AND rx.model_id   = t.model_id
                AND rx.scenario_id = t.scenario_id AND rx.obs_date  = t.obs_date
                AND rx.variable    = 'RHmax'
            LEFT JOIN climate.scalar_observations rn
                ON  rn.station_id  = t.station_id AND rn.model_id   = t.model_id
                AND rn.scenario_id = t.scenario_id AND rn.obs_date  = t.obs_date
                AND rn.variable    = 'RHmin'
            WHERE t.station_id = v_station_id
              AND t.obs_date >= make_date(p_year_from, 1,  1)
              AND t.obs_date <= make_date(p_year_to,  12, 31)
            GROUP BY t.model_id, t.scenario_id, EXTRACT(YEAR FROM t.obs_date)::int
        )

        -- Final result: MV precomputed counts joined with raw consecutive stats
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            t.year,
            -- Temperature events (from mv_annual_temp)
            t.heat_days,
            t.desert_days,
            t.tropical_nights,
            t.frost_days,
            t.ice_days,
            COALESCE(hw.max_heatwave_days, 0)    AS max_heatwave_days,
            t.hdd18,
            t.cdd22,
            t.gdd5,
            t.gdd10,
            -- Precipitation events (from mv_annual_precip)
            p.total_precip_mm,
            p.max_daily_precip_mm,
            p.wet_days,
            p.dry_days,
            p.heavy_rain_days,
            p.very_heavy_rain_days,
            COALESCE(ds.max_dry_spell_days, 0)   AS max_dry_spell_days,
            -- Wind events (from scalar_annual)
            sc.mean_wind_speed,
            sc.max_wind_speed,
            COALESCE(sc.calm_days, 0)            AS calm_days,
            COALESCE(sc.strong_wind_days, 0)     AS strong_wind_days,
            COALESCE(sc.storm_days, 0)           AS storm_days,
            -- Humidity events (from scalar_annual)
            sc.mean_rh_max,
            sc.mean_rh_min,
            COALESCE(sc.high_humidity_days, 0)   AS high_humidity_days,
            COALESCE(sc.low_humidity_days, 0)    AS low_humidity_days,
            -- Radiation events (from scalar_annual)
            sc.mean_swr_w_m2,
            sc.max_swr_w_m2,
            COALESCE(sc.high_solar_days, 0)      AS high_solar_days,
            COALESCE(sc.low_solar_days, 0)       AS low_solar_days,
            sc.total_solar_kwh_m2,
            sc.mean_lwr_w_m2,
            sc.min_lwr_w_m2,
            sc.max_lwr_w_m2,
            -- Combined cross-variable events (from combined_annual)
            COALESCE(cb.hot_and_dry_days, 0)     AS hot_and_dry_days,
            COALESCE(cb.stagnation_days, 0)      AS stagnation_days,
            COALESCE(cb.hot_humid_nights, 0)     AS hot_humid_nights,
            t.day_count
        FROM climate.mv_annual_temp    t
        JOIN climate.mv_annual_precip  p  ON  p.station_id  = t.station_id
                                          AND p.model_id    = t.model_id
                                          AND p.scenario_id = t.scenario_id
                                          AND p.year        = t.year
        JOIN climate.climate_models    m  ON  m.id = t.model_id
        JOIN climate.scenarios         s  ON  s.id = t.scenario_id
        LEFT JOIN hw_max               hw ON  hw.model_id    = t.model_id
                                          AND hw.scenario_id = t.scenario_id
                                          AND hw.year        = t.year
        LEFT JOIN ds_max               ds ON  ds.model_id    = t.model_id
                                          AND ds.scenario_id = t.scenario_id
                                          AND ds.year        = t.year
        LEFT JOIN scalar_annual        sc ON  sc.model_id    = t.model_id
                                          AND sc.scenario_id = t.scenario_id
                                          AND sc.year        = t.year
        LEFT JOIN combined_annual      cb ON  cb.model_id    = t.model_id
                                          AND cb.scenario_id = t.scenario_id
                                          AND cb.year        = t.year
        WHERE t.station_id = v_station_id
          AND t.year BETWEEN p_year_from AND p_year_to
    ) r;

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'year_from',  p_year_from,
            'year_to',    p_year_to
        ),
        'events', COALESCE(v_events, '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_climate_events_annual(double precision, double precision, integer, integer) IS
'Returns per-year climate event statistics for [p_year_from, p_year_to].
Simple event counts (heat/frost/tropical nights etc. and degree days) are
read from mv_annual_temp / mv_annual_precip for speed.
Consecutive heatwave and dry-spell lengths are computed from raw tables
using year-partitioned gaps-and-islands window functions.
Result shape: { nearest_station, query, events: [{model, scenario, year, ...}] }';


-- =============================================================================
-- Done
-- =============================================================================
DO $$ BEGIN
    RAISE NOTICE '=================================================';
    RAISE NOTICE 'Events functions deployed. Available:';
    RAISE NOTICE '  climate.get_climate_events(lon, lat, date_from, date_to)';
    RAISE NOTICE '  climate.get_climate_events(lon, lat, year, month)';
    RAISE NOTICE '  climate.get_climate_events(lon, lat, year)';
    RAISE NOTICE '  climate.get_climate_events(lon, lat, date)';
    RAISE NOTICE '  climate.get_climate_events_annual(lon, lat, year_from, year_to)';
    RAISE NOTICE '=================================================';
END $$;
