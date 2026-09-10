-- =============================================================================
-- add_trend_functions.sql
--
-- Adds two trend-query functions to the climate schema:
--
--   climate.get_climate_day_of_year(lon, lat, month, day, year_from, year_to)
--     Returns the values for a specific calendar day (e.g. July 14) for every
--     year in [year_from, year_to].  Useful for "what will this day look like
--     over the next N years?" queries from VC Map.
--
--   climate.get_climate_annual(lon, lat, year_from, year_to)
--     Returns yearly aggregates (avg/min/max temp, total precip, scalar avgs)
--     for every year in [year_from, year_to].  Useful for long-term trend charts.
--
-- Run in pgAdmin / psql on the already-migrated database.
-- =============================================================================

SET search_path TO climate, public;


-- -----------------------------------------------------------------------------
-- 1.  get_climate_day_of_year
--
-- Example:
--   SELECT climate.get_climate_day_of_year(4.35, 50.85, 7, 14, 2025, 2060);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION climate.get_climate_day_of_year(
    p_lon       double precision,
    p_lat       double precision,
    p_month     integer,
    p_day       integer,
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
    v_temp         jsonb;
    v_precip       jsonb;
    v_scalars      jsonb;
BEGIN
    -- 1. Nearest station
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

    -- 2. Temperature: one row per (year, model, scenario)
    SELECT jsonb_agg(
        to_jsonb(r)
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.year
    )
    INTO v_temp
    FROM (
        SELECT
            EXTRACT(YEAR FROM obs.obs_date)::int AS year,
            m.model_name,
            s.scenario_name,
            s.is_reference,
            obs.temp_min,
            obs.temp_max
        FROM climate.temperature_observations obs
        JOIN climate.climate_models m ON m.id = obs.model_id
        JOIN climate.scenarios      s ON s.id = obs.scenario_id
        WHERE obs.station_id = v_station_id
          AND EXTRACT(MONTH FROM obs.obs_date) = p_month
          AND EXTRACT(DAY   FROM obs.obs_date) = p_day
          AND EXTRACT(YEAR  FROM obs.obs_date) BETWEEN p_year_from AND p_year_to
    ) r;

    -- 3. Precipitation: one row per (year, model, scenario)
    SELECT jsonb_agg(
        to_jsonb(r)
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.year
    )
    INTO v_precip
    FROM (
        SELECT
            EXTRACT(YEAR FROM obs.obs_date)::int AS year,
            m.model_name,
            s.scenario_name,
            s.is_reference,
            obs.precipitation
        FROM climate.precipitation_observations obs
        JOIN climate.climate_models m ON m.id = obs.model_id
        JOIN climate.scenarios      s ON s.id = obs.scenario_id
        WHERE obs.station_id = v_station_id
          AND EXTRACT(MONTH FROM obs.obs_date) = p_month
          AND EXTRACT(DAY   FROM obs.obs_date) = p_day
          AND EXTRACT(YEAR  FROM obs.obs_date) BETWEEN p_year_from AND p_year_to
    ) r;

    -- 4. Scalar variables: one row per (year, model, scenario) per variable
    SELECT jsonb_object_agg(agg.variable, agg.entries)
    INTO v_scalars
    FROM (
        SELECT
            r.variable,
            jsonb_agg(
                to_jsonb(r)
                ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.year
            ) AS entries
        FROM (
            SELECT
                EXTRACT(YEAR FROM obs.obs_date)::int AS year,
                obs.variable,
                m.model_name,
                s.scenario_name,
                s.is_reference,
                obs.value
            FROM climate.scalar_observations obs
            JOIN climate.climate_models m ON m.id = obs.model_id
            JOIN climate.scenarios      s ON s.id = obs.scenario_id
            WHERE obs.station_id = v_station_id
              AND EXTRACT(MONTH FROM obs.obs_date) = p_month
              AND EXTRACT(DAY   FROM obs.obs_date) = p_day
              AND EXTRACT(YEAR  FROM obs.obs_date) BETWEEN p_year_from AND p_year_to
        ) r
        GROUP BY r.variable
    ) agg;

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'month',      p_month,
            'day',        p_day,
            'year_from',  p_year_from,
            'year_to',    p_year_to
        ),
        'temperature',   COALESCE(v_temp,   '[]'::jsonb),
        'precipitation', COALESCE(v_precip, '[]'::jsonb)
    ) || COALESCE(v_scalars, '{}'::jsonb);
END;
$func$;

COMMENT ON FUNCTION climate.get_climate_day_of_year(double precision, double precision, integer, integer, integer, integer) IS
'Returns observed values for a specific calendar day (p_month / p_day) for every
year in [p_year_from, p_year_to] from the nearest station.
Each row in the result arrays carries a "year" field, making it suitable for
trend/time-series charts in VC Map.';


-- -----------------------------------------------------------------------------
-- 2.  get_climate_annual
--
-- Example:
--   SELECT climate.get_climate_annual(4.35, 50.85, 2025, 2060);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION climate.get_climate_annual(
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
    v_temp         jsonb;
    v_precip       jsonb;
    v_scalars      jsonb;
BEGIN
    -- 1. Nearest station
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

    -- 2. Temperature: annual aggregates per (year, model, scenario)
    SELECT jsonb_agg(
        to_jsonb(r)
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.year
    )
    INTO v_temp
    FROM (
        SELECT
            EXTRACT(YEAR FROM obs.obs_date)::int AS year,
            m.model_name,
            s.scenario_name,
            s.is_reference,
            ROUND(AVG(obs.temp_min)::numeric, 2) AS avg_temp_min,
            ROUND(AVG(obs.temp_max)::numeric, 2) AS avg_temp_max,
            ROUND(MIN(obs.temp_min)::numeric, 2) AS min_temp_min,
            ROUND(MAX(obs.temp_max)::numeric, 2) AS max_temp_max,
            COUNT(*)::int                        AS days
        FROM climate.temperature_observations obs
        JOIN climate.climate_models m ON m.id = obs.model_id
        JOIN climate.scenarios      s ON s.id = obs.scenario_id
        WHERE obs.station_id = v_station_id
          AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to
        GROUP BY 1, m.model_name, s.scenario_name, s.is_reference
    ) r;

    -- 3. Precipitation: annual aggregates per (year, model, scenario)
    SELECT jsonb_agg(
        to_jsonb(r)
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.year
    )
    INTO v_precip
    FROM (
        SELECT
            EXTRACT(YEAR FROM obs.obs_date)::int  AS year,
            m.model_name,
            s.scenario_name,
            s.is_reference,
            ROUND(SUM(obs.precipitation)::numeric, 2) AS total_precipitation_mm,
            ROUND(AVG(obs.precipitation)::numeric, 2) AS avg_daily_precipitation_mm,
            ROUND(MAX(obs.precipitation)::numeric, 2) AS max_daily_precipitation_mm,
            COUNT(*)::int                             AS days
        FROM climate.precipitation_observations obs
        JOIN climate.climate_models m ON m.id = obs.model_id
        JOIN climate.scenarios      s ON s.id = obs.scenario_id
        WHERE obs.station_id = v_station_id
          AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to
        GROUP BY 1, m.model_name, s.scenario_name, s.is_reference
    ) r;

    -- 4. Scalar variables: annual aggregates per (year, model, scenario) per variable
    SELECT jsonb_object_agg(agg.variable, agg.entries)
    INTO v_scalars
    FROM (
        SELECT
            r.variable,
            jsonb_agg(
                to_jsonb(r)
                ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.year
            ) AS entries
        FROM (
            SELECT
                EXTRACT(YEAR FROM obs.obs_date)::int AS year,
                obs.variable,
                m.model_name,
                s.scenario_name,
                s.is_reference,
                ROUND(AVG(obs.value)::numeric, 4) AS avg_value,
                ROUND(MIN(obs.value)::numeric, 4) AS min_value,
                ROUND(MAX(obs.value)::numeric, 4) AS max_value,
                COUNT(*)::int                     AS days
            FROM climate.scalar_observations obs
            JOIN climate.climate_models m ON m.id = obs.model_id
            JOIN climate.scenarios      s ON s.id = obs.scenario_id
            WHERE obs.station_id = v_station_id
              AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to
            GROUP BY 1, obs.variable, m.model_name, s.scenario_name, s.is_reference
        ) r
        GROUP BY r.variable
    ) agg;

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'year_from',  p_year_from,
            'year_to',    p_year_to
        ),
        'temperature',   COALESCE(v_temp,   '[]'::jsonb),
        'precipitation', COALESCE(v_precip, '[]'::jsonb)
    ) || COALESCE(v_scalars, '{}'::jsonb);
END;
$func$;

COMMENT ON FUNCTION climate.get_climate_annual(double precision, double precision, integer, integer) IS
'Returns yearly aggregated climate values (avg/min/max temperature, total precipitation,
scalar variable averages) for every year in [p_year_from, p_year_to] from the nearest
station. Suitable for long-term trend charts in VC Map.';


DO $$ BEGIN
    RAISE NOTICE 'Trend functions installed:';
    RAISE NOTICE '  climate.get_climate_day_of_year(lon, lat, month, day, year_from, year_to)';
    RAISE NOTICE '  climate.get_climate_annual(lon, lat, year_from, year_to)';
END $$;
