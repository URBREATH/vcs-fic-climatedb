-- =============================================================================
-- add_cwb_functions.sql
--
-- Adds Climatic Water Balance (CWB) functions to the climate schema.
-- Combines FAO-56 Penman-Monteith ET0 with a Thornthwaite-Mather sequential
-- soil water balance to track soil drying, groundwater recharge and drought.
--
-- Prerequisites
-- -------------
--   • add_et0_functions.sql must have been run first (provides calc_et0_pm).
--   • climate.scalar_observations must contain SWR, LWR, WindSpeed, RHmax, RHmin.
--
-- Functions added
-- ---------------
--   climate.get_cwb(lon, lat, date_from, date_to [, awc_mm])
--   climate.get_cwb(lon, lat, year, month        [, awc_mm])
--   climate.get_cwb(lon, lat, year               [, awc_mm])
--   climate.get_cwb(lon, lat, date               [, awc_mm])
--   climate.get_cwb_annual(lon, lat, year_from, year_to [, awc_mm])
--
-- Water balance method (Thornthwaite-Mather, 1955)
-- -------------------------------------------------
--   available      = soil_moisture(prev) + precipitation
--
--   If available ≥ ET0:
--     AET          = ET0
--     soil_moisture = min(AWC, available − ET0)
--     runoff        = max(0, available − ET0 − AWC)   ← recharge proxy
--
--   If available < ET0:
--     AET          = available               (soil + rain fully consumed)
--     soil_moisture = 0
--     runoff        = 0
--
--   CWB (signed)              = precipitation − ET0
--   water_stress_index        = 1 − AET/ET0  (0 = no stress, 1 = max stress)
--   soil_moisture_deficit_mm  = AWC − soil_moisture
--
--   Simulation starts at field capacity (soil_moisture = AWC) on p_date_from.
--   Soil moisture carries forward day-by-day and year-to-year.
--
-- p_awc_mm  Available Water Capacity [mm]:
--    50–80  mm – shallow / coarse soils
--   100–150 mm – medium loam (default 150 mm)
--   150–250 mm – deep clay / high-organic soils
-- =============================================================================

SET search_path TO climate, public;


-- =============================================================================
-- 1.  get_cwb – daily CWB + sequential Thornthwaite-Mather water balance
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_cwb(
    p_lon        double precision,
    p_lat        double precision,
    p_date_from  date,
    p_date_to    date,
    p_awc_mm     double precision DEFAULT 150.0
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

    v_combo            record;
    v_day              record;

    v_sm               double precision;
    v_available        double precision;
    v_aet              double precision;
    v_new_sm           double precision;
    v_runoff           double precision;
    v_cwb              double precision;
    v_smd              double precision;
    v_stress           double precision;

    v_consec           int;
    v_max_consec       int;

    v_sum_et0          double precision;
    v_sum_precip       double precision;
    v_sum_cwb          double precision;
    v_sum_aet          double precision;
    v_sum_runoff       double precision;
    v_min_sm           double precision;
    v_n_days           int;

    v_combo_daily      jsonb;
    v_daily_arr        jsonb := '[]'::jsonb;
    v_summary_arr      jsonb := '[]'::jsonb;
    v_ai               double precision;
BEGIN
    -- ── 1. Nearest station ────────────────────────────────────────────────────
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
            'distance_m',   ROUND(ST_Distance(
                                s.geom::geography,
                                ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography
                            )::numeric, 1),
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

    -- ── 2. Outer loop: one iteration per model / scenario combination ─────────
    FOR v_combo IN
        SELECT DISTINCT
            mdl.id          AS model_id,
            mdl.model_name,
            scn.id          AS scenario_id,
            scn.scenario_name,
            scn.is_reference
        FROM climate.temperature_observations t
        JOIN climate.climate_models mdl ON mdl.id = t.model_id
        JOIN climate.scenarios      scn ON scn.id = t.scenario_id
        WHERE t.station_id = v_station_id
          AND t.obs_date BETWEEN p_date_from AND p_date_to
        ORDER BY scn.is_reference DESC, scn.scenario_name, mdl.model_name
    LOOP
        v_sm          := p_awc_mm;
        v_combo_daily := '[]'::jsonb;
        v_sum_et0     := 0.0;  v_sum_precip := 0.0;  v_sum_cwb    := 0.0;
        v_sum_aet     := 0.0;  v_sum_runoff := 0.0;  v_min_sm     := p_awc_mm;
        v_n_days      := 0;    v_consec     := 0;    v_max_consec := 0;

        -- ── 3. Sequential daily loop ──────────────────────────────────────────
        FOR v_day IN
            SELECT
                t.obs_date,
                t.temp_max,
                t.temp_min,
                COALESCE(p.precipitation, 0.0)  AS precip,
                swr.value   AS swr_w_m2,
                lwr.value   AS lwr_w_m2,
                ws.value    AS wind_speed,
                rhmax.value AS rh_max,
                rhmin.value AS rh_min,
                pm.r_et0_mm
            FROM climate.temperature_observations t
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
                SELECT r_et0_mm
                FROM climate.calc_et0_pm(
                    t.temp_max, t.temp_min,
                    swr.value, lwr.value, ws.value,
                    rhmax.value, rhmin.value,
                    v_station_altitude, 10.0
                )
            ) pm ON TRUE
            WHERE t.station_id  = v_station_id
              AND t.model_id    = v_combo.model_id
              AND t.scenario_id = v_combo.scenario_id
              AND t.obs_date   BETWEEN p_date_from AND p_date_to
            ORDER BY t.obs_date
        LOOP
            v_available := v_sm + v_day.precip;

            IF v_day.r_et0_mm IS NOT NULL THEN
                IF v_available >= v_day.r_et0_mm THEN
                    v_aet    := v_day.r_et0_mm;
                    v_new_sm := LEAST(p_awc_mm, v_available - v_day.r_et0_mm);
                    v_runoff := GREATEST(0.0, v_available - v_day.r_et0_mm - p_awc_mm);
                ELSE
                    v_aet    := v_available;
                    v_new_sm := 0.0;
                    v_runoff := 0.0;
                END IF;

                v_cwb    := v_day.precip - v_day.r_et0_mm;
                v_stress := CASE WHEN v_day.r_et0_mm > 0.0
                                 THEN GREATEST(0.0, 1.0 - v_aet / v_day.r_et0_mm)
                                 ELSE 0.0 END;

                IF v_cwb < 0.0 THEN
                    v_consec := v_consec + 1;
                    IF v_consec > v_max_consec THEN v_max_consec := v_consec; END IF;
                ELSE
                    v_consec := 0;
                END IF;

                v_sum_et0    := v_sum_et0    + v_day.r_et0_mm;
                v_sum_precip := v_sum_precip + v_day.precip;
                v_sum_cwb    := v_sum_cwb    + v_cwb;
                v_sum_aet    := v_sum_aet    + v_aet;
                v_sum_runoff := v_sum_runoff + v_runoff;
                v_n_days     := v_n_days + 1;
            ELSE
                -- ET0 unavailable: soil still recharged by rain
                v_new_sm     := LEAST(p_awc_mm, v_available);
                v_runoff     := GREATEST(0.0, v_available - p_awc_mm);
                v_aet        := NULL;
                v_cwb        := NULL;
                v_stress     := NULL;
                v_sum_precip := v_sum_precip + v_day.precip;
            END IF;

            v_sm  := v_new_sm;
            v_smd := p_awc_mm - v_new_sm;
            IF v_new_sm < v_min_sm THEN v_min_sm := v_new_sm; END IF;

            v_combo_daily := v_combo_daily || jsonb_build_array(
                jsonb_build_object(
                    'obs_date',                  v_day.obs_date,
                    'model_name',                v_combo.model_name,
                    'scenario_name',             v_combo.scenario_name,
                    'is_reference',              v_combo.is_reference,
                    'et0_mm',                    CASE WHEN v_day.r_et0_mm IS NOT NULL
                                                      THEN ROUND(v_day.r_et0_mm::numeric, 3)
                                                      ELSE NULL END,
                    'precip_mm',                 ROUND(v_day.precip::numeric, 3),
                    'cwb_mm',                    CASE WHEN v_cwb IS NOT NULL
                                                      THEN ROUND(v_cwb::numeric, 3)
                                                      ELSE NULL END,
                    'aet_mm',                    CASE WHEN v_aet IS NOT NULL
                                                      THEN ROUND(v_aet::numeric, 3)
                                                      ELSE NULL END,
                    'water_stress_index',        CASE WHEN v_stress IS NOT NULL
                                                      THEN ROUND(v_stress::numeric, 3)
                                                      ELSE NULL END,
                    'soil_moisture_mm',          ROUND(v_sm::numeric, 1),
                    'soil_moisture_deficit_mm',  ROUND(v_smd::numeric, 1),
                    'runoff_mm',                 ROUND(v_runoff::numeric, 3)
                )
            );
        END LOOP;  -- daily

        v_daily_arr := v_daily_arr || v_combo_daily;

        v_ai := CASE WHEN v_sum_et0 > 0.0
                     THEN v_sum_precip / v_sum_et0
                     ELSE NULL END;

        v_summary_arr := v_summary_arr || jsonb_build_array(
            jsonb_build_object(
                'model_name',                   v_combo.model_name,
                'scenario_name',                v_combo.scenario_name,
                'is_reference',                 v_combo.is_reference,
                'total_et0_mm',                 ROUND(v_sum_et0::numeric,    2),
                'total_precip_mm',              ROUND(v_sum_precip::numeric, 2),
                'total_cwb_mm',                 ROUND(v_sum_cwb::numeric,    2),
                'total_aet_mm',                 ROUND(v_sum_aet::numeric,    2),
                'total_recharge_proxy_mm',      ROUND(v_sum_runoff::numeric, 2),
                'min_soil_moisture_mm',         ROUND(v_min_sm::numeric,     1),
                'final_soil_moisture_mm',       ROUND(v_sm::numeric,         1),
                'max_consecutive_deficit_days', v_max_consec,
                'aridity_index',                CASE WHEN v_ai IS NOT NULL
                                                     THEN ROUND(v_ai::numeric, 3)
                                                     ELSE NULL END,
                'drought_category',             CASE
                    WHEN v_ai IS NULL  THEN NULL
                    WHEN v_ai >= 0.65  THEN 'humid'
                    WHEN v_ai >= 0.50  THEN 'dry_subhumid'
                    WHEN v_ai >= 0.20  THEN 'semiarid'
                    WHEN v_ai >= 0.05  THEN 'arid'
                    ELSE                    'hyperarid'
                END,
                'days_with_cwb',                v_n_days,
                'awc_mm',                       p_awc_mm
            )
        );
    END LOOP;  -- combo

    RETURN jsonb_build_object(
        'nearest_station',    v_station_json,
        'query', jsonb_build_object(
            'input_lon',             p_lon,
            'input_lat',             p_lat,
            'date_from',             p_date_from::text,
            'date_to',               p_date_to::text,
            'method',                'FAO-56 PM + Thornthwaite-Mather water balance',
            'awc_mm',                p_awc_mm,
            'wind_height_assumed_m', 10,
            'note',                  'soil_moisture initialised at AWC on date_from'
        ),
        'cwb_daily',          v_daily_arr,
        'cwb_period_summary', v_summary_arr
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_cwb(double precision, double precision, date, date, double precision) IS
'Daily climatic water balance using FAO-56 PM ET0 + Thornthwaite-Mather soil model.
Key fields: cwb_mm (signed P-ET0), aet_mm, water_stress_index,
            soil_moisture_mm, soil_moisture_deficit_mm, runoff_mm (recharge proxy).
p_awc_mm = Available Water Capacity [mm], default 150 mm (medium loam).';


-- =============================================================================
-- 2a. Convenience: month
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_cwb(
    p_lon    double precision,
    p_lat    double precision,
    p_year   integer,
    p_month  integer,
    p_awc_mm double precision DEFAULT 150.0
)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = climate, public
AS $func$
    SELECT climate.get_cwb(
        p_lon, p_lat,
        make_date(p_year, p_month, 1),
        (make_date(p_year, p_month, 1) + interval '1 month' - interval '1 day')::date,
        p_awc_mm
    );
$func$;

-- =============================================================================
-- 2b. Convenience: year
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_cwb(
    p_lon    double precision,
    p_lat    double precision,
    p_year   integer,
    p_awc_mm double precision DEFAULT 150.0
)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = climate, public
AS $func$
    SELECT climate.get_cwb(
        p_lon, p_lat,
        make_date(p_year, 1,  1),
        make_date(p_year, 12, 31),
        p_awc_mm
    );
$func$;

-- =============================================================================
-- 2c. Convenience: single day
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_cwb(
    p_lon    double precision,
    p_lat    double precision,
    p_date   date,
    p_awc_mm double precision DEFAULT 150.0
)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = climate, public
AS $func$
    SELECT climate.get_cwb(p_lon, p_lat, p_date, p_date, p_awc_mm);
$func$;


-- =============================================================================
-- 3.  get_cwb_annual – annual CWB aggregates; soil moisture crosses year boundary
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_cwb_annual(
    p_lon        double precision,
    p_lat        double precision,
    p_year_from  integer,
    p_year_to    integer,
    p_awc_mm     double precision DEFAULT 150.0
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

    v_combo            record;
    v_day              record;

    v_sm               double precision;
    v_available        double precision;
    v_aet              double precision;
    v_new_sm           double precision;
    v_runoff           double precision;
    v_cwb              double precision;

    v_curr_yr          int;
    v_this_yr          int;

    v_yr_et0           double precision;
    v_yr_precip        double precision;
    v_yr_cwb           double precision;
    v_yr_aet           double precision;
    v_yr_runoff        double precision;
    v_yr_min_sm        double precision;
    v_yr_n_days        int;
    v_yr_consec        int;
    v_yr_max_consec    int;

    v_combo_annual     jsonb;
    v_annual_arr       jsonb := '[]'::jsonb;
    v_ai               double precision;
BEGIN
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
            'distance_m',   ROUND(ST_Distance(
                                s.geom::geography,
                                ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography
                            )::numeric, 1),
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

    FOR v_combo IN
        SELECT DISTINCT
            mdl.id          AS model_id,
            mdl.model_name,
            scn.id          AS scenario_id,
            scn.scenario_name,
            scn.is_reference
        FROM climate.temperature_observations t
        JOIN climate.climate_models mdl ON mdl.id = t.model_id
        JOIN climate.scenarios      scn ON scn.id = t.scenario_id
        WHERE t.station_id = v_station_id
          AND EXTRACT(YEAR FROM t.obs_date) BETWEEN p_year_from AND p_year_to
        ORDER BY scn.is_reference DESC, scn.scenario_name, mdl.model_name
    LOOP
        v_sm           := p_awc_mm;
        v_combo_annual := '[]'::jsonb;
        v_curr_yr      := p_year_from;
        v_yr_et0    := 0.0;  v_yr_precip := 0.0;  v_yr_cwb    := 0.0;
        v_yr_aet    := 0.0;  v_yr_runoff := 0.0;  v_yr_min_sm := p_awc_mm;
        v_yr_n_days := 0;    v_yr_consec := 0;    v_yr_max_consec := 0;

        FOR v_day IN
            SELECT
                t.obs_date,
                t.temp_max,
                t.temp_min,
                COALESCE(p.precipitation, 0.0)  AS precip,
                swr.value   AS swr_w_m2,
                lwr.value   AS lwr_w_m2,
                ws.value    AS wind_speed,
                rhmax.value AS rh_max,
                rhmin.value AS rh_min,
                pm.r_et0_mm
            FROM climate.temperature_observations t
            LEFT JOIN climate.precipitation_observations p
                ON  p.station_id  = t.station_id AND p.model_id = t.model_id
                AND p.scenario_id = t.scenario_id AND p.obs_date = t.obs_date
            LEFT JOIN climate.scalar_observations swr
                ON  swr.station_id = t.station_id AND swr.model_id = t.model_id
                AND swr.scenario_id = t.scenario_id AND swr.obs_date = t.obs_date
                AND swr.variable = 'SWR'
            LEFT JOIN climate.scalar_observations lwr
                ON  lwr.station_id = t.station_id AND lwr.model_id = t.model_id
                AND lwr.scenario_id = t.scenario_id AND lwr.obs_date = t.obs_date
                AND lwr.variable = 'LWR'
            LEFT JOIN climate.scalar_observations ws
                ON  ws.station_id = t.station_id AND ws.model_id = t.model_id
                AND ws.scenario_id = t.scenario_id AND ws.obs_date = t.obs_date
                AND ws.variable = 'WindSpeed'
            LEFT JOIN climate.scalar_observations rhmax
                ON  rhmax.station_id = t.station_id AND rhmax.model_id = t.model_id
                AND rhmax.scenario_id = t.scenario_id AND rhmax.obs_date = t.obs_date
                AND rhmax.variable = 'RHmax'
            LEFT JOIN climate.scalar_observations rhmin
                ON  rhmin.station_id = t.station_id AND rhmin.model_id = t.model_id
                AND rhmin.scenario_id = t.scenario_id AND rhmin.obs_date = t.obs_date
                AND rhmin.variable = 'RHmin'
            LEFT JOIN LATERAL (
                SELECT r_et0_mm FROM climate.calc_et0_pm(
                    t.temp_max, t.temp_min, swr.value, lwr.value, ws.value,
                    rhmax.value, rhmin.value, v_station_altitude, 10.0
                )
            ) pm ON TRUE
            WHERE t.station_id  = v_station_id
              AND t.model_id    = v_combo.model_id
              AND t.scenario_id = v_combo.scenario_id
              AND EXTRACT(YEAR FROM t.obs_date) BETWEEN p_year_from AND p_year_to
            ORDER BY t.obs_date
        LOOP
            v_this_yr := EXTRACT(YEAR FROM v_day.obs_date)::int;

            -- Year boundary: flush completed year
            IF v_this_yr != v_curr_yr THEN
                v_ai := CASE WHEN v_yr_et0 > 0.0 THEN v_yr_precip / v_yr_et0 ELSE NULL END;
                v_combo_annual := v_combo_annual || jsonb_build_array(jsonb_build_object(
                    'year',                         v_curr_yr,
                    'model_name',                   v_combo.model_name,
                    'scenario_name',                v_combo.scenario_name,
                    'is_reference',                 v_combo.is_reference,
                    'total_et0_mm',                 ROUND(v_yr_et0::numeric,    2),
                    'total_precip_mm',              ROUND(v_yr_precip::numeric, 2),
                    'total_cwb_mm',                 ROUND(v_yr_cwb::numeric,    2),
                    'total_aet_mm',                 ROUND(v_yr_aet::numeric,    2),
                    'total_recharge_proxy_mm',      ROUND(v_yr_runoff::numeric, 2),
                    'min_soil_moisture_mm',         ROUND(v_yr_min_sm::numeric, 1),
                    'end_soil_moisture_mm',         ROUND(v_sm::numeric,        1),
                    'max_consecutive_deficit_days', v_yr_max_consec,
                    'mean_daily_et0_mm',            CASE WHEN v_yr_n_days > 0
                                                         THEN ROUND((v_yr_et0/v_yr_n_days)::numeric, 3)
                                                         ELSE NULL END,
                    'aridity_index',                CASE WHEN v_ai IS NOT NULL THEN ROUND(v_ai::numeric, 3) ELSE NULL END,
                    'drought_category',             CASE
                        WHEN v_ai IS NULL  THEN NULL WHEN v_ai >= 0.65 THEN 'humid'
                        WHEN v_ai >= 0.50  THEN 'dry_subhumid' WHEN v_ai >= 0.20 THEN 'semiarid'
                        WHEN v_ai >= 0.05  THEN 'arid' ELSE 'hyperarid' END,
                    'days_with_cwb',                v_yr_n_days,
                    'awc_mm',                       p_awc_mm
                ));
                v_curr_yr := v_this_yr;
                v_yr_et0 := 0.0; v_yr_precip := 0.0; v_yr_cwb := 0.0;
                v_yr_aet := 0.0; v_yr_runoff := 0.0; v_yr_min_sm := v_sm;
                v_yr_n_days := 0; v_yr_consec := 0; v_yr_max_consec := 0;
            END IF;

            v_available := v_sm + v_day.precip;
            IF v_day.r_et0_mm IS NOT NULL THEN
                IF v_available >= v_day.r_et0_mm THEN
                    v_aet    := v_day.r_et0_mm;
                    v_new_sm := LEAST(p_awc_mm, v_available - v_day.r_et0_mm);
                    v_runoff := GREATEST(0.0, v_available - v_day.r_et0_mm - p_awc_mm);
                ELSE
                    v_aet    := v_available;
                    v_new_sm := 0.0;
                    v_runoff := 0.0;
                END IF;
                v_cwb := v_day.precip - v_day.r_et0_mm;
                IF v_cwb < 0.0 THEN
                    v_yr_consec := v_yr_consec + 1;
                    IF v_yr_consec > v_yr_max_consec THEN v_yr_max_consec := v_yr_consec; END IF;
                ELSE
                    v_yr_consec := 0;
                END IF;
                v_yr_et0    := v_yr_et0    + v_day.r_et0_mm;
                v_yr_precip := v_yr_precip + v_day.precip;
                v_yr_cwb    := v_yr_cwb    + v_cwb;
                v_yr_aet    := v_yr_aet    + v_aet;
                v_yr_runoff := v_yr_runoff + v_runoff;
                v_yr_n_days := v_yr_n_days + 1;
            ELSE
                v_new_sm    := LEAST(p_awc_mm, v_available);
                v_runoff    := GREATEST(0.0, v_available - p_awc_mm);
                v_yr_precip := v_yr_precip + v_day.precip;
            END IF;
            v_sm := v_new_sm;
            IF v_sm < v_yr_min_sm THEN v_yr_min_sm := v_sm; END IF;
        END LOOP;  -- daily

        -- Flush final year
        IF v_yr_n_days > 0 OR v_yr_precip > 0.0 THEN
            v_ai := CASE WHEN v_yr_et0 > 0.0 THEN v_yr_precip / v_yr_et0 ELSE NULL END;
            v_combo_annual := v_combo_annual || jsonb_build_array(jsonb_build_object(
                'year',                         v_curr_yr,
                'model_name',                   v_combo.model_name,
                'scenario_name',                v_combo.scenario_name,
                'is_reference',                 v_combo.is_reference,
                'total_et0_mm',                 ROUND(v_yr_et0::numeric,    2),
                'total_precip_mm',              ROUND(v_yr_precip::numeric, 2),
                'total_cwb_mm',                 ROUND(v_yr_cwb::numeric,    2),
                'total_aet_mm',                 ROUND(v_yr_aet::numeric,    2),
                'total_recharge_proxy_mm',      ROUND(v_yr_runoff::numeric, 2),
                'min_soil_moisture_mm',         ROUND(v_yr_min_sm::numeric, 1),
                'end_soil_moisture_mm',         ROUND(v_sm::numeric,        1),
                'max_consecutive_deficit_days', v_yr_max_consec,
                'mean_daily_et0_mm',            CASE WHEN v_yr_n_days > 0
                                                     THEN ROUND((v_yr_et0/v_yr_n_days)::numeric, 3)
                                                     ELSE NULL END,
                'aridity_index',                CASE WHEN v_ai IS NOT NULL THEN ROUND(v_ai::numeric, 3) ELSE NULL END,
                'drought_category',             CASE
                    WHEN v_ai IS NULL THEN NULL WHEN v_ai >= 0.65 THEN 'humid'
                    WHEN v_ai >= 0.50 THEN 'dry_subhumid' WHEN v_ai >= 0.20 THEN 'semiarid'
                    WHEN v_ai >= 0.05 THEN 'arid' ELSE 'hyperarid' END,
                'days_with_cwb',                v_yr_n_days,
                'awc_mm',                       p_awc_mm
            ));
        END IF;

        v_annual_arr := v_annual_arr || v_combo_annual;
    END LOOP;  -- combo

    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,         'input_lat',  p_lat,
            'year_from',  p_year_from,   'year_to',    p_year_to,
            'method',     'FAO-56 PM + Thornthwaite-Mather water balance',
            'awc_mm',     p_awc_mm,      'wind_height_assumed_m', 10,
            'note',       'soil_moisture initialised at AWC on 1 Jan year_from; carries across year boundaries'
        ),
        'annual_cwb', v_annual_arr
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_cwb_annual(double precision, double precision, integer, integer, double precision) IS
'Annual climatic water balance with soil moisture continuity across years.
Key fields per year/model/scenario: total_cwb_mm, total_aet_mm,
total_recharge_proxy_mm, min_soil_moisture_mm, end_soil_moisture_mm,
max_consecutive_deficit_days, aridity_index, drought_category.
p_awc_mm = Available Water Capacity [mm], default 150 mm.';


DO $$ BEGIN
    RAISE NOTICE '=======================================================';
    RAISE NOTICE 'CWB functions installed:';
    RAISE NOTICE '  climate.get_cwb(lon, lat, date_from, date_to [,awc])';
    RAISE NOTICE '  climate.get_cwb(lon, lat, year, month        [,awc])';
    RAISE NOTICE '  climate.get_cwb(lon, lat, year               [,awc])';
    RAISE NOTICE '  climate.get_cwb(lon, lat, date               [,awc])';
    RAISE NOTICE '  climate.get_cwb_annual(lon, lat, yr_f, yr_t  [,awc])';
    RAISE NOTICE '  Default AWC = 150 mm (medium loam soil)';
    RAISE NOTICE '=======================================================';
END $$;