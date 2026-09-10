-- =============================================================================
-- add_seasonal_function.sql
--
-- Adds a seasonal trend function:
--
--   climate.get_climate_seasonal(lon, lat, season, year_from, year_to)
--
-- Seasons (case-insensitive):
--   'spring'  → March, April, May         (MAM)
--   'summer'  → June, July, August        (JJA)
--   'autumn'  → September, October, Nov   (SON)
--   'winter'  → December, January, Feb    (DJF)
--
-- Winter year convention: December is assigned to the *following* year so that
-- Dec 2025 + Jan 2026 + Feb 2026 all belong to winter 2026.
--
-- Each entry in the result arrays carries a "season_year" field so VC Map can
-- plot the values on a timeline.
--
-- Example:
--   SELECT climate.get_climate_seasonal(4.35, 50.85, 'summer', 2025, 2060);
--   SELECT climate.get_climate_seasonal(4.35, 50.85, 'winter', 2025, 2060);
-- =============================================================================

SET search_path TO climate, public;


CREATE OR REPLACE FUNCTION climate.get_climate_seasonal(
    p_lon       double precision,
    p_lat       double precision,
    p_season    text,
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
    v_months       integer[];
    v_is_winter    boolean := FALSE;
    v_season_norm  text;
BEGIN
    -- ── Resolve season ────────────────────────────────────────────────────────
    v_season_norm := lower(trim(p_season));
    CASE v_season_norm
        WHEN 'spring' THEN v_months := ARRAY[3, 4, 5];
        WHEN 'summer' THEN v_months := ARRAY[6, 7, 8];
        WHEN 'autumn', 'fall' THEN v_months := ARRAY[9, 10, 11];
        WHEN 'winter' THEN
            v_months    := ARRAY[12, 1, 2];
            v_is_winter := TRUE;
        ELSE
            RAISE EXCEPTION 'Unknown season "%". Use spring, summer, autumn, or winter.', p_season;
    END CASE;

    -- ── Nearest station ───────────────────────────────────────────────────────
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

    -- ── Temperature ───────────────────────────────────────────────────────────
    -- season_year: for winter, December is bumped to the next year so that
    -- Dec-YYYY + Jan/Feb-(YYYY+1) form one coherent winter season.
    SELECT jsonb_agg(
        to_jsonb(r)
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.season_year
    )
    INTO v_temp
    FROM (
        SELECT
            CASE
                WHEN v_is_winter AND EXTRACT(MONTH FROM obs.obs_date) = 12
                THEN EXTRACT(YEAR FROM obs.obs_date)::int + 1
                ELSE EXTRACT(YEAR FROM obs.obs_date)::int
            END                                  AS season_year,
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
          AND EXTRACT(MONTH FROM obs.obs_date) = ANY(v_months)
          AND (
            -- For non-winter: year must fall directly in range
            (NOT v_is_winter AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to)
            OR
            -- For winter: Dec of (year-1) feeds into season_year=year
            (v_is_winter AND (
                (EXTRACT(MONTH FROM obs.obs_date) = 12
                    AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from - 1 AND p_year_to - 1)
                OR
                (EXTRACT(MONTH FROM obs.obs_date) IN (1, 2)
                    AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to)
            ))
          )
        GROUP BY 1, m.model_name, s.scenario_name, s.is_reference
        -- Filter assembled season_year to requested range
        HAVING
            CASE
                WHEN v_is_winter AND EXTRACT(MONTH FROM MIN(obs.obs_date)) = 12
                THEN EXTRACT(YEAR FROM MIN(obs.obs_date))::int + 1
                ELSE EXTRACT(YEAR FROM MIN(obs.obs_date))::int
            END BETWEEN p_year_from AND p_year_to
    ) r;

    -- ── Precipitation ─────────────────────────────────────────────────────────
    SELECT jsonb_agg(
        to_jsonb(r)
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.season_year
    )
    INTO v_precip
    FROM (
        SELECT
            CASE
                WHEN v_is_winter AND EXTRACT(MONTH FROM obs.obs_date) = 12
                THEN EXTRACT(YEAR FROM obs.obs_date)::int + 1
                ELSE EXTRACT(YEAR FROM obs.obs_date)::int
            END                                       AS season_year,
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
          AND EXTRACT(MONTH FROM obs.obs_date) = ANY(v_months)
          AND (
            (NOT v_is_winter AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to)
            OR
            (v_is_winter AND (
                (EXTRACT(MONTH FROM obs.obs_date) = 12
                    AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from - 1 AND p_year_to - 1)
                OR
                (EXTRACT(MONTH FROM obs.obs_date) IN (1, 2)
                    AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to)
            ))
          )
        GROUP BY 1, m.model_name, s.scenario_name, s.is_reference
        HAVING
            CASE
                WHEN v_is_winter AND EXTRACT(MONTH FROM MIN(obs.obs_date)) = 12
                THEN EXTRACT(YEAR FROM MIN(obs.obs_date))::int + 1
                ELSE EXTRACT(YEAR FROM MIN(obs.obs_date))::int
            END BETWEEN p_year_from AND p_year_to
    ) r;

    -- ── Scalar variables ──────────────────────────────────────────────────────
    SELECT jsonb_object_agg(agg.variable, agg.entries)
    INTO v_scalars
    FROM (
        SELECT
            r.variable,
            jsonb_agg(
                to_jsonb(r)
                ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.season_year
            ) AS entries
        FROM (
            SELECT
                CASE
                    WHEN v_is_winter AND EXTRACT(MONTH FROM obs.obs_date) = 12
                    THEN EXTRACT(YEAR FROM obs.obs_date)::int + 1
                    ELSE EXTRACT(YEAR FROM obs.obs_date)::int
                END                               AS season_year,
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
              AND EXTRACT(MONTH FROM obs.obs_date) = ANY(v_months)
              AND (
                (NOT v_is_winter AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to)
                OR
                (v_is_winter AND (
                    (EXTRACT(MONTH FROM obs.obs_date) = 12
                        AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from - 1 AND p_year_to - 1)
                    OR
                    (EXTRACT(MONTH FROM obs.obs_date) IN (1, 2)
                        AND EXTRACT(YEAR FROM obs.obs_date) BETWEEN p_year_from AND p_year_to)
                ))
              )
            GROUP BY 1, obs.variable, m.model_name, s.scenario_name, s.is_reference
            HAVING
                CASE
                    WHEN v_is_winter AND EXTRACT(MONTH FROM MIN(obs.obs_date)) = 12
                    THEN EXTRACT(YEAR FROM MIN(obs.obs_date))::int + 1
                    ELSE EXTRACT(YEAR FROM MIN(obs.obs_date))::int
                END BETWEEN p_year_from AND p_year_to
        ) r
        GROUP BY r.variable
    ) agg;

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'season',     v_season_norm,
            'year_from',  p_year_from,
            'year_to',    p_year_to
        ),
        'temperature',   COALESCE(v_temp,   '[]'::jsonb),
        'precipitation', COALESCE(v_precip, '[]'::jsonb)
    ) || COALESCE(v_scalars, '{}'::jsonb);
END;
$func$;

COMMENT ON FUNCTION climate.get_climate_seasonal(double precision, double precision, text, integer, integer) IS
'Returns seasonal aggregates (avg/min/max temp, total precip, scalar avgs) for every
season_year in [p_year_from, p_year_to] from the nearest station.
Seasons: spring (MAM), summer (JJA), autumn/fall (SON), winter (DJF).
Winter uses meteorological year convention: December is counted in the following year
so that Dec-YYYY + Jan/Feb-(YYYY+1) form one coherent winter.
Each result array entry carries a "season_year" field for time-series charting.';


DO $$ BEGIN
    RAISE NOTICE 'Seasonal function installed:';
    RAISE NOTICE '  climate.get_climate_seasonal(lon, lat, season, year_from, year_to)';
    RAISE NOTICE '  Seasons: spring | summer | autumn | winter';
END $$;
