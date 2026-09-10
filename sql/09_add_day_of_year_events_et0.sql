-- =============================================================================
-- add_day_of_year_events_et0.sql
--
-- Adds "day-of-year trend" variants of the events and ET0 functions, matching
-- the pattern of climate.get_climate_day_of_year.
--
-- Functions added
-- ---------------
--   climate.get_climate_events_day_of_year(lon, lat, month, day, year_from, year_to)
--     – for every year in [year_from, year_to], returns the event flags and
--       degree-day contributions for the specific calendar day (month/day).
--       Result: { ..., "events": [{year, obs_date, model, scenario, ...}] }
--       Answer: "Is July 14 expected to be a heat day in 2030? In 2060?"
--
--   climate.get_et0_day_of_year(lon, lat, month, day, year_from, year_to)
--     – for every year in [year_from, year_to], returns the full FAO-56
--       Penman-Monteith ET0 output for the specific calendar day.
--       Result: { ..., "annual_et0": [{year, obs_date, model, scenario, et0_mm, ...}] }
--       Answer: "How does ET0 demand on July 14 change between 2030 and 2060?"
--
-- Key naming conventions
-- ----------------------
--   "events"     – same key as get_climate_events_annual / _seasonal
--   "annual_et0" – same key as get_et0_annual / get_et0_seasonal
--   Both use "year" as the primary time axis (not "season_year").
--
-- Consecutive-run stats (max_heatwave_days, max_dry_spell_days) are omitted:
-- they are meaningless for a single-day query.
--
-- Prerequisites
-- -------------
--   • migrate_to_climate_schema.sql
--   • add_scalar_observations.sql
--   • add_et0_functions.sql  (climate.calc_et0_pm helper)
--
-- Usage
-- -----
--   SELECT climate.get_climate_events_day_of_year(4.35, 50.85, 7, 14, 2025, 2060);
--   SELECT climate.get_et0_day_of_year(4.35, 50.85, 7, 14, 2025, 2060);
-- =============================================================================

SET search_path TO climate, public;


-- =============================================================================
-- 1.  get_climate_events_day_of_year
--
--     For each year, returns event flags and degree-day contributions for the
--     calendar day p_month/p_day.  Precipitation is joined via LEFT JOIN so
--     rows without precipitation data still appear (precipitation_mm = 0).
--
--     Field names match get_climate_events_annual / get_climate_events_seasonal
--     so client code can reuse the same display logic.  Counts are 0/1 since
--     this is a single day.  max_heatwave_days and max_dry_spell_days are
--     omitted as they carry no information for a single-day window.
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_climate_events_day_of_year(
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
    v_events       jsonb;
BEGIN
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

    -- ── Event flags + degree-day contributions for the specific day/year ──────
    SELECT jsonb_agg(
        jsonb_build_object(
            'year',                r.yr,
            'obs_date',            r.obs_date,
            'model_name',          r.model_name,
            'scenario_name',       r.scenario_name,
            'is_reference',        r.is_reference,
            -- Raw temperature
            'temp_min',            ROUND(r.temp_min::numeric,  2),
            'temp_max',            ROUND(r.temp_max::numeric,  2),
            'tmean',               ROUND(r.tmean::numeric,     2),
            -- Temperature threshold flags (0/1)
            'heat_days',           CASE WHEN r.temp_max > 30   THEN 1 ELSE 0 END,
            'desert_days',         CASE WHEN r.temp_max > 35   THEN 1 ELSE 0 END,
            'tropical_nights',     CASE WHEN r.temp_min > 20   THEN 1 ELSE 0 END,
            'frost_days',          CASE WHEN r.temp_min <  0   THEN 1 ELSE 0 END,
            'ice_days',            CASE WHEN r.temp_max <  0   THEN 1 ELSE 0 END,
            -- Degree-day contributions for this day
            'hdd18',               ROUND(GREATEST(0, 18.0 - r.tmean)::numeric, 2),
            'cdd22',               ROUND(GREATEST(0, r.tmean - 22.0)::numeric, 2),
            'gdd5',                ROUND(GREATEST(0, r.tmean -  5.0)::numeric, 2),
            'gdd10',               ROUND(GREATEST(0, r.tmean - 10.0)::numeric, 2),
            -- Precipitation
            'total_precip_mm',     ROUND(r.precip::numeric, 2),
            'wet_days',            CASE WHEN r.precip >= 1.0  THEN 1 ELSE 0 END,
            'dry_days',            CASE WHEN r.precip <  1.0  THEN 1 ELSE 0 END,
            'heavy_rain_days',     CASE WHEN r.precip >= 10.0 THEN 1 ELSE 0 END,
            'very_heavy_rain_days',CASE WHEN r.precip >= 20.0 THEN 1 ELSE 0 END,
            -- Wind
            'wind_speed_m_s',      ROUND(r.wind_speed::numeric, 3),
            'calm',                CASE WHEN r.wind_speed <  1.0 THEN 1 ELSE 0 END,
            'strong_wind',         CASE WHEN r.wind_speed > 10.0 THEN 1 ELSE 0 END,
            'storm',               CASE WHEN r.wind_speed > 17.0 THEN 1 ELSE 0 END,
            -- Humidity
            'rh_max_pct',          ROUND(r.rh_max::numeric, 1),
            'rh_min_pct',          ROUND(r.rh_min::numeric, 1),
            'high_humidity',       CASE WHEN r.rh_max > 90.0 THEN 1 ELSE 0 END,
            'low_humidity',        CASE WHEN r.rh_min < 30.0 THEN 1 ELSE 0 END,
            -- Radiation
            'swr_w_m2',            ROUND(r.swr_w_m2::numeric, 2),
            'lwr_w_m2',            ROUND(r.lwr_w_m2::numeric, 2),
            'high_solar',          CASE WHEN r.swr_w_m2 > 200.0 THEN 1 ELSE 0 END,
            'low_solar',           CASE WHEN r.swr_w_m2 <  50.0 THEN 1 ELSE 0 END,
            -- Combined cross-variable flags
            'hot_and_dry',         CASE WHEN r.temp_max > 30 AND r.rh_min  < 30 THEN 1 ELSE 0 END,
            'stagnation',          CASE WHEN r.tmean   > 25 AND r.wind_speed < 2 THEN 1 ELSE 0 END,
            'hot_humid_night',     CASE WHEN r.temp_min > 20 AND r.rh_max  > 80 THEN 1 ELSE 0 END,
            'day_count',           1
        )
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.yr
    )
    INTO v_events
    FROM (
        SELECT
            EXTRACT(YEAR FROM t.obs_date)::int      AS yr,
            t.obs_date::text                        AS obs_date,
            m.model_name,
            s.scenario_name,
            s.is_reference,
            t.temp_min,
            t.temp_max,
            (t.temp_min + t.temp_max) / 2.0        AS tmean,
            COALESCE(p.precipitation, 0.0)          AS precip,
            ws.value                                AS wind_speed,
            rx.value                                AS rh_max,
            rn.value                                AS rh_min,
            swr.value                               AS swr_w_m2,
            lwr.value                               AS lwr_w_m2
        FROM climate.temperature_observations t
        JOIN  climate.climate_models m  ON m.id = t.model_id
        JOIN  climate.scenarios      s  ON s.id = t.scenario_id
        LEFT JOIN climate.precipitation_observations p
            ON  p.station_id  = t.station_id
            AND p.model_id    = t.model_id
            AND p.scenario_id = t.scenario_id
            AND p.obs_date    = t.obs_date
        LEFT JOIN climate.scalar_observations ws
            ON  ws.station_id  = t.station_id
            AND ws.model_id    = t.model_id
            AND ws.scenario_id = t.scenario_id
            AND ws.obs_date    = t.obs_date
            AND ws.variable    = 'WindSpeed'
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
        WHERE t.station_id = v_station_id
          AND EXTRACT(MONTH FROM t.obs_date) = p_month
          AND EXTRACT(DAY   FROM t.obs_date) = p_day
          AND EXTRACT(YEAR  FROM t.obs_date) BETWEEN p_year_from AND p_year_to
    ) r;

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
        'events', COALESCE(v_events, '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_climate_events_day_of_year(double precision, double precision, integer, integer, integer, integer) IS
'Returns per-year event flags and degree-day contributions for a specific calendar
day (p_month / p_day) across [p_year_from, p_year_to].
Field names match get_climate_events_annual; counts are 0/1 (single day).
max_heatwave_days and max_dry_spell_days are omitted (meaningless for one day).
Result shape: { nearest_station, query, events: [{year, obs_date, model, scenario, ...}] }';


-- =============================================================================
-- 2.  get_et0_day_of_year
--
--     For each year, computes FAO-56 Penman-Monteith ET0 for the calendar day
--     p_month/p_day and returns all intermediate PM variables alongside ET0,
--     precipitation and water-balance metrics.
--
--     Return key is "annual_et0" (same as get_et0_annual / get_et0_seasonal)
--     so Python routing can share the same key name.  Each element carries
--     "year" (integer) and "obs_date" (the actual date string) for clarity.
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_et0_day_of_year(
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
    v_station_id       text;
    v_station_altitude double precision;
    v_station_json     jsonb;
    v_et0_by_year      jsonb;
BEGIN
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

    -- ── ET0 per (year × model × scenario) ────────────────────────────────────
    SELECT jsonb_agg(
        jsonb_build_object(
            'year',              r.yr,
            'obs_date',          r.obs_date,
            'model_name',        r.model_name,
            'scenario_name',     r.scenario_name,
            'is_reference',      r.is_reference,
            -- Core ET0 output
            'et0_mm',            ROUND(r.et0_mm::numeric,        3),
            'precip_mm',         ROUND(r.precip::numeric,        3),
            'water_deficit_mm',  ROUND(GREATEST(r.et0_mm - r.precip, 0.0)::numeric, 3),
            'water_surplus_mm',  ROUND(GREATEST(r.precip - r.et0_mm, 0.0)::numeric, 3),
            -- Radiation components
            'rn_mj_m2_day',      ROUND(r.rn::numeric,           4),
            'rns_mj_m2_day',     ROUND(r.rns::numeric,          4),
            'rnl_mj_m2_day',     ROUND(r.rnl::numeric,          4),
            -- Vapour pressure
            'es_kpa',            ROUND(r.es_kpa::numeric,        4),
            'ea_kpa',            ROUND(r.ea_kpa::numeric,        4),
            'vpd_kpa',           ROUND(r.vpd_kpa::numeric,       4),
            -- Ancillary PM parameters
            'delta_kpa_c',       ROUND(r.delta_kpa_c::numeric,   4),
            'gamma_kpa_c',       ROUND(r.gamma_kpa_c::numeric,   4),
            'pressure_kpa',      ROUND(r.pressure_kpa::numeric,  3),
            'lambda_mj_kg',      ROUND(r.lambda_mj_kg::numeric,  4),
            'u2_m_s',            ROUND(r.u2_m_s::numeric,        3),
            -- Raw climate inputs
            't_mean_c',          ROUND(((r.t_max + r.t_min) / 2.0)::numeric, 2),
            't_max_c',           ROUND(r.t_max::numeric,         2),
            't_min_c',           ROUND(r.t_min::numeric,         2),
            'swr_w_m2',          ROUND(r.swr_w_m2::numeric,      2),
            'lwr_w_m2',          ROUND(r.lwr_w_m2::numeric,      2),
            'wind_speed_m_s',    ROUND(r.wind_speed::numeric,    3),
            'rh_max_pct',        ROUND(r.rh_max::numeric,        1),
            'rh_min_pct',        ROUND(r.rh_min::numeric,        1)
        )
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.yr
    )
    INTO v_et0_by_year
    FROM (
        SELECT
            EXTRACT(YEAR FROM t.obs_date)::int  AS yr,
            t.obs_date::text                    AS obs_date,
            mdl.model_name,
            scn.scenario_name,
            scn.is_reference,
            t.temp_max                          AS t_max,
            t.temp_min                          AS t_min,
            COALESCE(p.precipitation, 0.0)      AS precip,
            swr.value                           AS swr_w_m2,
            lwr.value                           AS lwr_w_m2,
            ws.value                            AS wind_speed,
            rhmax.value                         AS rh_max,
            rhmin.value                         AS rh_min,
            pm.r_et0_mm                         AS et0_mm,
            pm.r_rns_mj_m2_day                  AS rns,
            pm.r_rnl_mj_m2_day                  AS rnl,
            pm.r_rn_mj_m2_day                   AS rn,
            pm.r_es_kpa                         AS es_kpa,
            pm.r_ea_kpa                         AS ea_kpa,
            pm.r_vpd_kpa                        AS vpd_kpa,
            pm.r_delta_kpa_c                    AS delta_kpa_c,
            pm.r_gamma_kpa_c                    AS gamma_kpa_c,
            pm.r_pressure_kpa                   AS pressure_kpa,
            pm.r_u2_m_s                         AS u2_m_s,
            pm.r_lambda_mj_kg                   AS lambda_mj_kg
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
            SELECT * FROM climate.calc_et0_pm(
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
          AND EXTRACT(MONTH FROM t.obs_date) = p_month
          AND EXTRACT(DAY   FROM t.obs_date) = p_day
          AND EXTRACT(YEAR  FROM t.obs_date) BETWEEN p_year_from AND p_year_to
    ) r;

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'month',      p_month,
            'day',        p_day,
            'year_from',  p_year_from,
            'year_to',    p_year_to,
            'method',     'FAO-56 Penman-Monteith',
            'wind_height_assumed_m', 10
        ),
        'annual_et0', COALESCE(v_et0_by_year, '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_et0_day_of_year(double precision, double precision, integer, integer, integer, integer) IS
'Returns per-year FAO-56 Penman-Monteith ET0 for a specific calendar day (p_month/p_day)
across [p_year_from, p_year_to].  Each element carries "year" and "obs_date" alongside
the full set of PM variables (Rn, es, ea, VPD, u2, …) and precipitation/water-balance.
Return key is "annual_et0" (same as get_et0_annual / get_et0_seasonal).
Requires: climate.scalar_observations with SWR, LWR, WindSpeed, RHmax, RHmin.';


-- =============================================================================
-- Done
-- =============================================================================
DO $$ BEGIN
    RAISE NOTICE '=================================================';
    RAISE NOTICE 'Day-of-year events + ET0 functions deployed:';
    RAISE NOTICE '  climate.get_climate_events_day_of_year(lon, lat, month, day, year_from, year_to)';
    RAISE NOTICE '  climate.get_et0_day_of_year(lon, lat, month, day, year_from, year_to)';
    RAISE NOTICE '=================================================';
END $$;
