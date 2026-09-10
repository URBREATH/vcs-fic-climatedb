-- =============================================================================
-- add_scalar_observations.sql
--
-- This file is installed automatically by climatedb-delivery/run_setup.py
-- before any observation or projection data is imported. Do not run the
-- legacy initFunctions/add_scalar_observations.sql separately when using the
-- delivery bundle.
--
-- It can also be run manually as the second migration, after the base schema
-- and climate-schema migration, but before importing scalar data or installing
-- functions that depend on scalar_observations.
-- =============================================================================

SET search_path TO climate, public;

-- -----------------------------------------------------------------------------
-- 1. New table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS climate.scalar_observations (
    id          BIGSERIAL        PRIMARY KEY,
    station_id  TEXT             REFERENCES climate.stations(station_id),
    model_id    INTEGER          REFERENCES climate.climate_models(id),
    scenario_id INTEGER          REFERENCES climate.scenarios(id),
    variable    TEXT             NOT NULL,  -- 'LWR', 'SWR', 'RHmax', 'RHmin', 'WindSpeed'
    obs_date    DATE             NOT NULL,
    value       DOUBLE PRECISION,
    UNIQUE (station_id, model_id, scenario_id, variable, obs_date)
);

CREATE INDEX IF NOT EXISTS idx_scalar_lookup
    ON climate.scalar_observations(station_id, model_id, scenario_id, variable);


-- -----------------------------------------------------------------------------
-- 2. Replace get_climate(lon, lat, date_from, date_to) to also return scalars
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

    -- 2. Temperature
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

    -- 3. Precipitation
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

    -- 4. Scalar variables (LWR, SWR, RHmax, RHmin, WindSpeed …)
    --    Each variable becomes its own top-level key, same as temperature
    --    and precipitation.
    SELECT jsonb_object_agg(
        r.variable,
        r.entries
    )
    INTO v_scalars
    FROM (
        SELECT
            agg.variable,
            jsonb_agg(
                jsonb_build_object(
                    'model_name',    agg.model_name,
                    'scenario_name', agg.scenario_name,
                    'is_reference',  agg.is_reference,
                    'avg_value',     agg.avg_value,
                    'min_value',     agg.min_value,
                    'max_value',     agg.max_value,
                    'days',          agg.days
                )
                ORDER BY agg.is_reference DESC, agg.scenario_name, agg.model_name
            ) AS entries
        FROM (
            SELECT
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
              AND obs.obs_date BETWEEN p_date_from AND p_date_to
            GROUP BY obs.variable, m.model_name, s.scenario_name, s.is_reference
        ) agg
        GROUP BY agg.variable
    ) r;

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
    ) || COALESCE(v_scalars, '{}'::jsonb);
END;
$func$;

COMMENT ON FUNCTION climate.get_climate(double precision, double precision, date, date) IS
'Returns climate projections (temperature, precipitation, and scalar variables
LWR/SWR/RHmax/RHmin/WindSpeed) for the station nearest to (p_lon, p_lat)
within [p_date_from, p_date_to]. Result is JSONB.';

-- The year/month, year, and single-date overloads all delegate to the
-- date-range variant above, so they automatically benefit from this update.

DO $$ BEGIN
    RAISE NOTICE 'scalar_observations table and updated get_climate() installed.';
END $$;
