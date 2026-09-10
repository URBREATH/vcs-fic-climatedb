-- =============================================================================
-- migrate_to_climate_schema.sql
--
-- Run this ONCE on the database to:
--   1. Create the dedicated 'climate' schema
--   2. Move existing tables from 'public' to 'climate' (safe / idempotent)
--   3. Create the get_climate() stored function family
--
-- Usage (psql):
--   psql -h <host> -U <user> -d <db> -f migrate_to_climate_schema.sql
--
-- Usage (pgAdmin):
--   Open Query Tool, paste contents, Execute (F5)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Schema
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS climate;


-- -----------------------------------------------------------------------------
-- 2. Move existing tables from public → climate (idempotent)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY[
        'cities',
        'stations',
        'climate_models',
        'scenarios',
        'precipitation_observations',
        'temperature_observations'
    ]
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = tbl
        ) THEN
            EXECUTE format('ALTER TABLE public.%I SET SCHEMA climate', tbl);
            RAISE NOTICE 'Moved table % → climate schema', tbl;
        ELSE
            RAISE NOTICE 'Table % not found in public (already moved or not yet created)', tbl;
        END IF;
    END LOOP;
END;
$$;


-- -----------------------------------------------------------------------------
-- 3a. Core function: explicit date range
--
--   SELECT climate.get_climate(4.35, 50.85, '2045-01-01'::date, '2045-12-31'::date);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION climate.get_climate(
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
    v_station_id   text;
    v_station_json jsonb;
    v_temp         jsonb;
    v_precip       jsonb;
BEGIN
    -- 1. Nearest station (KNN via <-> operator, exact distance via ST_Distance)
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

    -- 2. Temperature aggregation
    SELECT jsonb_agg(
        to_jsonb(t)
        ORDER BY t.is_reference DESC, t.scenario_name, t.model_name
    )
    INTO v_temp
    FROM (
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            ROUND(AVG(obs.temp_min)::numeric, 2)  AS avg_temp_min,
            ROUND(AVG(obs.temp_max)::numeric, 2)  AS avg_temp_max,
            ROUND(MIN(obs.temp_min)::numeric, 2)  AS min_temp_min,
            ROUND(MAX(obs.temp_max)::numeric, 2)  AS max_temp_max,
            COUNT(*)::int                         AS days
        FROM climate.temperature_observations obs
        JOIN climate.climate_models m ON m.id = obs.model_id
        JOIN climate.scenarios      s ON s.id = obs.scenario_id
        WHERE obs.station_id = v_station_id
          AND obs.obs_date BETWEEN p_date_from AND p_date_to
        GROUP BY m.model_name, s.scenario_name, s.is_reference
    ) t;

    -- 3. Precipitation aggregation
    SELECT jsonb_agg(
        to_jsonb(p)
        ORDER BY p.is_reference DESC, p.scenario_name, p.model_name
    )
    INTO v_precip
    FROM (
        SELECT
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
          AND obs.obs_date BETWEEN p_date_from AND p_date_to
        GROUP BY m.model_name, s.scenario_name, s.is_reference
    ) p;

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'date_from',  p_date_from::text,
            'date_to',    p_date_to::text
        ),
        'temperature',   COALESCE(v_temp,   '[]'::jsonb),
        'precipitation', COALESCE(v_precip, '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_climate(double precision, double precision, date, date) IS
'Returns climate projections (temperature + precipitation) for all models and scenarios
for the observation station nearest to (p_lon, p_lat) within [p_date_from, p_date_to].
Result is a JSONB document with keys: nearest_station, query, temperature, precipitation.';


-- -----------------------------------------------------------------------------
-- 3b. Overload: year + month
--
--   SELECT climate.get_climate(4.35, 50.85, 2045, 7);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION climate.get_climate(
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
    SELECT climate.get_climate(
        p_lon,
        p_lat,
        make_date(p_year, p_month, 1),
        (make_date(p_year, p_month, 1) + interval '1 month' - interval '1 day')::date
    );
$func$;

COMMENT ON FUNCTION climate.get_climate(double precision, double precision, integer, integer) IS
'Convenience overload: queries a full calendar month. Delegates to the date-range variant.';


-- -----------------------------------------------------------------------------
-- 3c. Overload: full calendar year
--
--   SELECT climate.get_climate(4.35, 50.85, 2045);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION climate.get_climate(
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
    SELECT climate.get_climate(
        p_lon,
        p_lat,
        make_date(p_year, 1,  1),
        make_date(p_year, 12, 31)
    );
$func$;

COMMENT ON FUNCTION climate.get_climate(double precision, double precision, integer) IS
'Convenience overload: queries a full calendar year. Delegates to the date-range variant.';


-- -----------------------------------------------------------------------------
-- 3d. Overload: single date
--
--   SELECT climate.get_climate(4.35, 50.85, '2045-07-14'::date);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION climate.get_climate(
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
    SELECT climate.get_climate(p_lon, p_lat, p_date, p_date);
$func$;

COMMENT ON FUNCTION climate.get_climate(double precision, double precision, date) IS
'Convenience overload: queries a single calendar day. Delegates to the date-range variant.';


-- -----------------------------------------------------------------------------
-- Done
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    RAISE NOTICE '=================================================';
    RAISE NOTICE 'Migration complete. Available functions:';
    RAISE NOTICE '  climate.get_climate(lon, lat, date_from, date_to)';
    RAISE NOTICE '  climate.get_climate(lon, lat, year, month)';
    RAISE NOTICE '  climate.get_climate(lon, lat, year)';
    RAISE NOTICE '  climate.get_climate(lon, lat, date)';
    RAISE NOTICE '=================================================';
END $$;
