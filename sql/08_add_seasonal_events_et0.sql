-- =============================================================================
-- add_seasonal_events_et0.sql
--
-- Adds seasonal trend variants of the events and ET0 functions.
--
-- Functions added
-- ---------------
--   climate.get_climate_events_seasonal(lon, lat, season, year_from, year_to)
--     – per-(season_year × model × scenario) event counts, degree-day sums,
--       and longest consecutive-run stats for the requested season across years.
--       All metrics computed from raw tables (no MV — MVs are full-year only).
--
--   climate.get_et0_seasonal(lon, lat, season, year_from, year_to)
--     – per-(season_year × model × scenario) FAO-56 Penman-Monteith ET0
--       aggregates and drought indicators for the requested season across years.
--
-- Season definitions (identical to get_climate_seasonal)
-- -------------------------------------------------------
--   spring  → March, April, May         (MAM)
--   summer  → June, July, August        (JJA)
--   autumn  → September, October, Nov   (SON)
--   winter  → December, January, Feb    (DJF)
--
-- Winter year convention
-- ----------------------
--   December is assigned to the *following* year so that Dec-YYYY +
--   Jan/Feb-(YYYY+1) form a single coherent winter season_year.
--   Example: Dec 2025 + Jan 2026 + Feb 2026 → winter season_year = 2026.
--
-- Result key design
-- -----------------
--   get_climate_events_seasonal → { ..., "events": [...] }
--     Each element has "season_year" (not "year") plus the same event
--     fields as get_climate_events_annual.
--
--   get_et0_seasonal → { ..., "annual_et0": [...] }
--     Same key name as get_et0_annual so Python routing can share the key.
--     Each element has "season_year" (not "year").
--
-- Prerequisites
-- -------------
--   • migrate_to_climate_schema.sql   (core tables)
--   • add_scalar_observations.sql     (scalar_observations)
--   • add_et0_functions.sql           (climate.calc_et0_pm helper)
--   • add_events_functions.sql        (for context / consistency)
--
-- Usage
-- -----
--   SELECT climate.get_climate_events_seasonal(4.35, 50.85, 'summer', 2025, 2060);
--   SELECT climate.get_climate_events_seasonal(4.35, 50.85, 'winter', 2025, 2060);
--   SELECT climate.get_et0_seasonal(4.35, 50.85, 'summer', 2025, 2060);
--   SELECT climate.get_et0_seasonal(4.35, 50.85, 'winter', 2025, 2060);
-- =============================================================================

SET search_path TO climate, public;


-- =============================================================================
-- 1.  get_climate_events_seasonal
--
--     Scans raw observation tables; no MV (MVs contain full-year aggregates).
--     Heatwave and dry-spell streaks are bounded within each season window
--     so a heatwave cannot cross the season boundary.
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_climate_events_seasonal(
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
    v_events       jsonb;
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

    -- ── Event counts + consecutive-run stats ──────────────────────────────────
    -- Uses CTEs to:
    --   A/C  tag each observation row with season_year (winter convention)
    --        and apply the month + date-range filter
    --   B    gaps-and-islands for heatwave streaks (partitioned by season_year)
    --   D    gaps-and-islands for dry-spell streaks (partitioned by season_year)
    --   E/F  aggregate threshold counts and degree-day sums
    --   G    join everything into one row per (model × scenario × season_year)
    SELECT jsonb_agg(
        to_jsonb(r)
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.season_year
    )
    INTO v_events
    FROM (
        WITH
        -- ── A. Temperature rows with season_year ──────────────────────────────
        base_temp AS (
            SELECT
                model_id,
                scenario_id,
                obs_date,
                temp_min,
                temp_max,
                (temp_min + temp_max) / 2.0 AS tmean,
                CASE
                    WHEN v_is_winter AND EXTRACT(MONTH FROM obs_date) = 12
                    THEN EXTRACT(YEAR FROM obs_date)::int + 1
                    ELSE EXTRACT(YEAR FROM obs_date)::int
                END AS season_year
            FROM climate.temperature_observations
            WHERE station_id = v_station_id
              AND EXTRACT(MONTH FROM obs_date) = ANY(v_months)
              AND (
                (NOT v_is_winter
                    AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from AND p_year_to)
                OR
                (v_is_winter AND (
                    (EXTRACT(MONTH FROM obs_date) = 12
                        AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from - 1 AND p_year_to - 1)
                    OR
                    (EXTRACT(MONTH FROM obs_date) IN (1, 2)
                        AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from AND p_year_to)
                ))
              )
        ),
        temp AS (
            SELECT * FROM base_temp
            WHERE season_year BETWEEN p_year_from AND p_year_to
        ),

        -- ── B. Heatwave gaps-and-islands (bounded within each season_year) ────
        temp_grp AS (
            SELECT
                model_id,
                scenario_id,
                season_year,
                obs_date,
                temp_min,
                temp_max,
                tmean,
                -- cool_grp increments on every non-hot day within the season
                SUM(CASE WHEN temp_max <= 30 THEN 1 ELSE 0 END)
                    OVER (
                        PARTITION BY model_id, scenario_id, season_year
                        ORDER BY obs_date
                    ) AS cool_grp
            FROM temp
        ),
        hw_max AS (
            SELECT
                model_id, scenario_id, season_year,
                MAX(cnt)::int AS max_heatwave_days
            FROM (
                SELECT model_id, scenario_id, season_year, cool_grp, COUNT(*) AS cnt
                FROM temp_grp
                WHERE temp_max > 30
                GROUP BY model_id, scenario_id, season_year, cool_grp
            ) x
            GROUP BY model_id, scenario_id, season_year
        ),

        -- ── C. Precipitation rows with season_year ────────────────────────────
        base_precip AS (
            SELECT
                model_id,
                scenario_id,
                obs_date,
                precipitation,
                CASE
                    WHEN v_is_winter AND EXTRACT(MONTH FROM obs_date) = 12
                    THEN EXTRACT(YEAR FROM obs_date)::int + 1
                    ELSE EXTRACT(YEAR FROM obs_date)::int
                END AS season_year
            FROM climate.precipitation_observations
            WHERE station_id = v_station_id
              AND EXTRACT(MONTH FROM obs_date) = ANY(v_months)
              AND (
                (NOT v_is_winter
                    AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from AND p_year_to)
                OR
                (v_is_winter AND (
                    (EXTRACT(MONTH FROM obs_date) = 12
                        AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from - 1 AND p_year_to - 1)
                    OR
                    (EXTRACT(MONTH FROM obs_date) IN (1, 2)
                        AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from AND p_year_to)
                ))
              )
        ),
        precip AS (
            SELECT * FROM base_precip
            WHERE season_year BETWEEN p_year_from AND p_year_to
        ),

        -- ── D. Dry-spell gaps-and-islands (bounded within each season_year) ───
        precip_grp AS (
            SELECT
                model_id,
                scenario_id,
                season_year,
                obs_date,
                precipitation,
                -- wet_grp increments on every wet day within the season
                SUM(CASE WHEN precipitation >= 1.0 THEN 1 ELSE 0 END)
                    OVER (
                        PARTITION BY model_id, scenario_id, season_year
                        ORDER BY obs_date
                    ) AS wet_grp
            FROM precip
        ),
        ds_max AS (
            SELECT
                model_id, scenario_id, season_year,
                MAX(cnt)::int AS max_dry_spell_days
            FROM (
                SELECT model_id, scenario_id, season_year, wet_grp, COUNT(*) AS cnt
                FROM precip_grp
                WHERE precipitation < 1.0
                GROUP BY model_id, scenario_id, season_year, wet_grp
            ) x
            GROUP BY model_id, scenario_id, season_year
        ),

        -- ── E. Aggregate temperature events per (model × scenario × season_year)
        temp_agg AS (
            SELECT
                model_id,
                scenario_id,
                season_year,
                COUNT(*) FILTER (WHERE temp_max > 30)::int          AS heat_days,
                COUNT(*) FILTER (WHERE temp_max > 35)::int          AS desert_days,
                COUNT(*) FILTER (WHERE temp_min > 20)::int          AS tropical_nights,
                COUNT(*) FILTER (WHERE temp_min <  0)::int          AS frost_days,
                COUNT(*) FILTER (WHERE temp_max <  0)::int          AS ice_days,
                ROUND(SUM(GREATEST(0, 18.0 - tmean))::numeric, 1)  AS hdd18,
                ROUND(SUM(GREATEST(0, tmean - 22.0))::numeric, 1)  AS cdd22,
                ROUND(SUM(GREATEST(0, tmean -  5.0))::numeric, 1)  AS gdd5,
                ROUND(SUM(GREATEST(0, tmean - 10.0))::numeric, 1)  AS gdd10,
                COUNT(*)::int                                        AS day_count
            FROM temp_grp
            GROUP BY model_id, scenario_id, season_year
        ),

        -- ── F. Aggregate precipitation events per (model × scenario × season_year)
        precip_agg AS (
            SELECT
                model_id,
                scenario_id,
                season_year,
                ROUND(SUM(precipitation)::numeric,  1)               AS total_precip_mm,
                ROUND(MAX(precipitation)::numeric,  2)               AS max_daily_precip_mm,
                COUNT(*) FILTER (WHERE precipitation >= 1.0)::int    AS wet_days,
                COUNT(*) FILTER (WHERE precipitation <  1.0)::int    AS dry_days,
                COUNT(*) FILTER (WHERE precipitation >= 10.0)::int   AS heavy_rain_days,
                COUNT(*) FILTER (WHERE precipitation >= 20.0)::int   AS very_heavy_rain_days
            FROM precip_grp
            GROUP BY model_id, scenario_id, season_year
        ),

        -- ── H. Scalar seasonal aggregates (wind / humidity / radiation) ────────
        base_scalar AS (
            SELECT
                model_id,
                scenario_id,
                variable,
                value,
                CASE
                    WHEN v_is_winter AND EXTRACT(MONTH FROM obs_date) = 12
                    THEN EXTRACT(YEAR FROM obs_date)::int + 1
                    ELSE EXTRACT(YEAR FROM obs_date)::int
                END AS season_year
            FROM climate.scalar_observations
            WHERE station_id = v_station_id
              AND variable IN ('WindSpeed', 'RHmax', 'RHmin', 'SWR', 'LWR')
              AND EXTRACT(MONTH FROM obs_date) = ANY(v_months)
              AND (
                (NOT v_is_winter
                    AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from AND p_year_to)
                OR
                (v_is_winter AND (
                    (EXTRACT(MONTH FROM obs_date) = 12
                        AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from - 1 AND p_year_to - 1)
                    OR
                    (EXTRACT(MONTH FROM obs_date) IN (1, 2)
                        AND EXTRACT(YEAR FROM obs_date) BETWEEN p_year_from AND p_year_to)
                ))
              )
        ),
        scalar_filtered AS (
            SELECT * FROM base_scalar
            WHERE season_year BETWEEN p_year_from AND p_year_to
        ),
        scalar_agg AS (
            SELECT
                model_id,
                scenario_id,
                season_year,
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
            FROM scalar_filtered
            GROUP BY model_id, scenario_id, season_year
        ),

        -- ── I. Combined cross-variable seasonal counts ────────────────────────
        combined_base AS (
            SELECT
                t.model_id,
                t.scenario_id,
                t.season_year,
                t.temp_min,
                t.temp_max,
                t.tmean,
                w.value  AS wind_speed,
                rx.value AS rh_max,
                rn.value AS rh_min
            FROM temp t
            LEFT JOIN climate.scalar_observations w
                ON  w.station_id  = v_station_id
                AND w.model_id    = t.model_id
                AND w.scenario_id = t.scenario_id
                AND w.obs_date    = t.obs_date
                AND w.variable    = 'WindSpeed'
            LEFT JOIN climate.scalar_observations rx
                ON  rx.station_id  = v_station_id
                AND rx.model_id    = t.model_id
                AND rx.scenario_id = t.scenario_id
                AND rx.obs_date    = t.obs_date
                AND rx.variable    = 'RHmax'
            LEFT JOIN climate.scalar_observations rn
                ON  rn.station_id  = v_station_id
                AND rn.model_id    = t.model_id
                AND rn.scenario_id = t.scenario_id
                AND rn.obs_date    = t.obs_date
                AND rn.variable    = 'RHmin'
        ),
        combined_agg AS (
            SELECT
                model_id,
                scenario_id,
                season_year,
                COUNT(*) FILTER (WHERE temp_max > 30 AND rh_min  < 30)::int  AS hot_and_dry_days,
                COUNT(*) FILTER (WHERE tmean    > 25 AND wind_speed < 2)::int AS stagnation_days,
                COUNT(*) FILTER (WHERE temp_min > 20 AND rh_max  > 80)::int  AS hot_humid_nights
            FROM combined_base
            GROUP BY model_id, scenario_id, season_year
        )

        -- ── G. Final join ──────────────────────────────────────────────────────
        SELECT
            m.model_name,
            s.scenario_name,
            s.is_reference,
            ta.season_year,
            -- Temperature events
            ta.heat_days,
            ta.desert_days,
            ta.tropical_nights,
            ta.frost_days,
            ta.ice_days,
            COALESCE(hw.max_heatwave_days, 0)    AS max_heatwave_days,
            ta.hdd18,
            ta.cdd22,
            ta.gdd5,
            ta.gdd10,
            -- Precipitation events
            pa.total_precip_mm,
            pa.max_daily_precip_mm,
            pa.wet_days,
            pa.dry_days,
            pa.heavy_rain_days,
            pa.very_heavy_rain_days,
            COALESCE(ds.max_dry_spell_days, 0)   AS max_dry_spell_days,
            -- Wind events
            sa.mean_wind_speed,
            sa.max_wind_speed,
            COALESCE(sa.calm_days, 0)            AS calm_days,
            COALESCE(sa.strong_wind_days, 0)     AS strong_wind_days,
            COALESCE(sa.storm_days, 0)           AS storm_days,
            -- Humidity events
            sa.mean_rh_max,
            sa.mean_rh_min,
            COALESCE(sa.high_humidity_days, 0)   AS high_humidity_days,
            COALESCE(sa.low_humidity_days, 0)    AS low_humidity_days,
            -- Radiation events
            sa.mean_swr_w_m2,
            sa.max_swr_w_m2,
            COALESCE(sa.high_solar_days, 0)      AS high_solar_days,
            COALESCE(sa.low_solar_days, 0)       AS low_solar_days,
            sa.total_solar_kwh_m2,
            sa.mean_lwr_w_m2,
            sa.min_lwr_w_m2,
            sa.max_lwr_w_m2,
            -- Combined cross-variable events
            COALESCE(ca.hot_and_dry_days, 0)     AS hot_and_dry_days,
            COALESCE(ca.stagnation_days, 0)      AS stagnation_days,
            COALESCE(ca.hot_humid_nights, 0)     AS hot_humid_nights,
            ta.day_count
        FROM temp_agg ta
        JOIN  climate.climate_models m   ON m.id = ta.model_id
        JOIN  climate.scenarios      s   ON s.id = ta.scenario_id
        LEFT JOIN hw_max   hw  ON  hw.model_id    = ta.model_id
                               AND hw.scenario_id  = ta.scenario_id
                               AND hw.season_year  = ta.season_year
        LEFT JOIN precip_agg pa ON  pa.model_id    = ta.model_id
                               AND  pa.scenario_id  = ta.scenario_id
                               AND  pa.season_year  = ta.season_year
        LEFT JOIN ds_max   ds  ON  ds.model_id    = ta.model_id
                               AND ds.scenario_id  = ta.scenario_id
                               AND ds.season_year  = ta.season_year
        LEFT JOIN scalar_agg   sa ON  sa.model_id    = ta.model_id
                               AND  sa.scenario_id  = ta.scenario_id
                               AND  sa.season_year  = ta.season_year
        LEFT JOIN combined_agg ca ON  ca.model_id    = ta.model_id
                               AND  ca.scenario_id  = ta.scenario_id
                               AND  ca.season_year  = ta.season_year
    ) r;

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'season',     v_season_norm,
            'year_from',  p_year_from,
            'year_to',    p_year_to
        ),
        'events', COALESCE(v_events, '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_climate_events_seasonal(double precision, double precision, text, integer, integer) IS
'Returns per-season_year climate event statistics for [p_year_from, p_year_to].
All metrics computed from raw observation tables (MVs are full-year only).
Heatwave and dry-spell streaks are bounded within each season window.
Winter year convention: December is assigned to the following year.
Result shape: { nearest_station, query, events: [{model, scenario, season_year, ...}] }';


-- =============================================================================
-- 2.  get_et0_seasonal
--
--     FAO-56 Penman-Monteith ET0 aggregated by season window per year.
--     Uses a CTE to tag each daily row with its season_year, applies the
--     seasonal filter, then aggregates with LATERAL calc_et0_pm calls.
--
--     Return key is "annual_et0" (same as get_et0_annual) so Python routing
--     can share the same key lookup. Rows carry "season_year" rather than
--     "year" to make the seasonal context explicit.
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_et0_seasonal(
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
    v_station_id       text;
    v_station_altitude double precision;
    v_station_json     jsonb;
    v_seasonal_et0     jsonb;
    v_months           integer[];
    v_is_winter        boolean := FALSE;
    v_season_norm      text;
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
        COALESCE(s.height, 50.0),
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
    INTO v_station_id, v_station_altitude, v_station_json
    FROM climate.stations s
    LEFT JOIN climate.cities c ON c.id = s.city_id
    ORDER BY s.geom <-> ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)
    LIMIT 1;

    IF v_station_id IS NULL THEN
        RAISE EXCEPTION 'No stations found in the database.';
    END IF;

    -- ── Seasonal ET0 aggregates ───────────────────────────────────────────────
    -- CTE "tagged" computes season_year for each daily row and calls
    -- calc_et0_pm via LATERAL, producing one row per observation day.
    -- The outer SELECT then filters to [p_year_from, p_year_to] and
    -- groups by (season_year × model × scenario).
    SELECT jsonb_agg(
        jsonb_build_object(
            'season_year',              s.season_year,
            'model_name',               s.model_name,
            'scenario_name',            s.scenario_name,
            'is_reference',             s.is_reference,
            'total_et0_mm',             ROUND(s.total_et0::numeric,      2),
            'total_precip_mm',          ROUND(s.total_precip::numeric,   2),
            'total_water_deficit_mm',   ROUND(s.total_deficit::numeric,  2),
            'total_water_surplus_mm',   ROUND(s.total_surplus::numeric,  2),
            'mean_daily_et0_mm',        ROUND(s.mean_et0::numeric,       3),
            'max_daily_et0_mm',         ROUND(s.max_et0::numeric,        3),
            'aridity_index',            ROUND(s.ai::numeric,             3),
            'drought_category',         CASE
                WHEN s.ai >= 0.65 THEN 'humid'
                WHEN s.ai >= 0.50 THEN 'dry_subhumid'
                WHEN s.ai >= 0.20 THEN 'semiarid'
                WHEN s.ai >= 0.05 THEN 'arid'
                ELSE                   'hyperarid'
            END,
            'days_with_et0',            s.days_et0
        )
        ORDER BY s.is_reference DESC, s.scenario_name, s.model_name, s.season_year
    )
    INTO v_seasonal_et0
    FROM (
        WITH tagged AS (
            SELECT
                -- season_year: December → following year for winter
                CASE
                    WHEN v_is_winter AND EXTRACT(MONTH FROM t.obs_date) = 12
                    THEN EXTRACT(YEAR FROM t.obs_date)::int + 1
                    ELSE EXTRACT(YEAR FROM t.obs_date)::int
                END                                      AS season_year,
                mdl.model_name,
                scn.scenario_name,
                scn.is_reference,
                pm.r_et0_mm,
                COALESCE(p.precipitation, 0.0)           AS precipitation
            FROM climate.temperature_observations t
            JOIN  climate.climate_models mdl ON mdl.id = t.model_id
            JOIN  climate.scenarios      scn ON scn.id = t.scenario_id
            LEFT JOIN climate.precipitation_observations p
                ON  p.station_id  = t.station_id
                AND p.model_id    = t.model_id
                AND p.scenario_id = t.scenario_id
                AND p.obs_date    = t.obs_date
            LEFT JOIN climate.scalar_observations swr
                ON  swr.station_id  = t.station_id
                AND swr.model_id    = t.model_id
                AND swr.scenario_id = t.scenario_id
                AND swr.obs_date    = t.obs_date
                AND swr.variable    = 'SWR'
            LEFT JOIN climate.scalar_observations lwr
                ON  lwr.station_id  = t.station_id
                AND lwr.model_id    = t.model_id
                AND lwr.scenario_id = t.scenario_id
                AND lwr.obs_date    = t.obs_date
                AND lwr.variable    = 'LWR'
            LEFT JOIN climate.scalar_observations ws
                ON  ws.station_id  = t.station_id
                AND ws.model_id    = t.model_id
                AND ws.scenario_id = t.scenario_id
                AND ws.obs_date    = t.obs_date
                AND ws.variable    = 'WindSpeed'
            LEFT JOIN climate.scalar_observations rhmax
                ON  rhmax.station_id  = t.station_id
                AND rhmax.model_id    = t.model_id
                AND rhmax.scenario_id = t.scenario_id
                AND rhmax.obs_date    = t.obs_date
                AND rhmax.variable    = 'RHmax'
            LEFT JOIN climate.scalar_observations rhmin
                ON  rhmin.station_id  = t.station_id
                AND rhmin.model_id    = t.model_id
                AND rhmin.scenario_id = t.scenario_id
                AND rhmin.obs_date    = t.obs_date
                AND rhmin.variable    = 'RHmin'
            LEFT JOIN LATERAL (
                SELECT r_et0_mm FROM climate.calc_et0_pm(
                    t.temp_max,
                    t.temp_min,
                    swr.value,
                    lwr.value,
                    ws.value,
                    rhmax.value,
                    rhmin.value,
                    v_station_altitude,
                    10.0              -- climate-model wind speed at 10 m
                )
            ) pm ON TRUE
            WHERE t.station_id = v_station_id
              AND EXTRACT(MONTH FROM t.obs_date) = ANY(v_months)
              AND (
                (NOT v_is_winter
                    AND EXTRACT(YEAR FROM t.obs_date) BETWEEN p_year_from AND p_year_to)
                OR
                (v_is_winter AND (
                    (EXTRACT(MONTH FROM t.obs_date) = 12
                        AND EXTRACT(YEAR FROM t.obs_date) BETWEEN p_year_from - 1 AND p_year_to - 1)
                    OR
                    (EXTRACT(MONTH FROM t.obs_date) IN (1, 2)
                        AND EXTRACT(YEAR FROM t.obs_date) BETWEEN p_year_from AND p_year_to)
                ))
              )
        )
        SELECT
            season_year,
            model_name,
            scenario_name,
            is_reference,
            COALESCE(SUM(r_et0_mm), 0.0)                                                   AS total_et0,
            COALESCE(SUM(precipitation), 0.0)                                               AS total_precip,
            COALESCE(SUM(GREATEST(r_et0_mm - precipitation, 0.0)), 0.0)                    AS total_deficit,
            COALESCE(SUM(GREATEST(precipitation - r_et0_mm, 0.0)), 0.0)                    AS total_surplus,
            AVG(r_et0_mm)                                                                   AS mean_et0,
            MAX(r_et0_mm)                                                                   AS max_et0,
            CASE WHEN SUM(r_et0_mm) > 0
                 THEN SUM(precipitation) / SUM(r_et0_mm)
                 ELSE NULL
            END                                                                             AS ai,
            COUNT(r_et0_mm)::int                                                            AS days_et0
        FROM tagged
        WHERE season_year BETWEEN p_year_from AND p_year_to
        GROUP BY season_year, model_name, scenario_name, is_reference
    ) s;

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'season',     v_season_norm,
            'year_from',  p_year_from,
            'year_to',    p_year_to,
            'method',     'FAO-56 Penman-Monteith',
            'wind_height_assumed_m', 10
        ),
        'annual_et0', COALESCE(v_seasonal_et0, '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_et0_seasonal(double precision, double precision, text, integer, integer) IS
'Returns per-season_year FAO-56 Penman-Monteith ET0 aggregates for [p_year_from, p_year_to].
Filters observations to the requested season months, computes ET0 via calc_et0_pm
for each day, then aggregates by (season_year × model × scenario).
Winter year convention: December is assigned to the following year.
Return key is "annual_et0" (same as get_et0_annual) — rows carry "season_year".
Requires: climate.scalar_observations with SWR, LWR, WindSpeed, RHmax, RHmin.';


-- =============================================================================
-- Done
-- =============================================================================
DO $$ BEGIN
    RAISE NOTICE '=================================================';
    RAISE NOTICE 'Seasonal events + ET0 functions deployed:';
    RAISE NOTICE '  climate.get_climate_events_seasonal(lon, lat, season, year_from, year_to)';
    RAISE NOTICE '  climate.get_et0_seasonal(lon, lat, season, year_from, year_to)';
    RAISE NOTICE '=================================================';
END $$;
