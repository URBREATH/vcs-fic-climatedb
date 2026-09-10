-- =============================================================================
-- add_et0_functions.sql
--
-- Adds FAO-56 Penman-Monteith reference evapotranspiration (ET0) functions to
-- the climate schema.
--
-- Prerequisites
-- -------------
--   • add_scalar_observations.sql must have been run first so that
--     climate.scalar_observations contains daily SWR, LWR, WindSpeed, RHmax,
--     RHmin values per station / model / scenario.
--
-- Functions added
-- ---------------
--   climate.calc_et0_pm(...)                              – pure PM helper
--   climate.get_et0(lon, lat, date_from, date_to)         – daily ET0 + summary
--   climate.get_et0(lon, lat, year, month)                – convenience: month
--   climate.get_et0(lon, lat, year)                       – convenience: year
--   climate.get_et0(lon, lat, date)                       – convenience: day
--   climate.get_et0_annual(lon, lat, year_from, year_to)  – annual SSP trend
--
-- Physics reference
-- -----------------
--   FAO Irrigation and Drainage Paper No. 56, Allen et al. (1998), Eq. 6
--   https://www.fao.org/3/X0490E/x0490e00.htm
--
-- Equation summary (FAO-56, Eq. 6)
-- ---------------------------------
--   ET0 = [0.408·Δ·Rn + γ·(900/(T+273))·u₂·(es−ea)] / [Δ + γ·(1+0.34·u₂)]
--
--   where
--     T   = mean daily temperature at 2 m  [°C]
--     u₂  = wind speed at 2 m             [m s⁻¹]
--     Rn  = net radiation                 [MJ m⁻² day⁻¹]
--     es  = saturation vapour pressure    [kPa]
--     ea  = actual vapour pressure        [kPa]
--     Δ   = slope of sat. VP curve        [kPa °C⁻¹]
--     γ   = psychrometric constant        [kPa °C⁻¹]
--
-- Radiation inputs (from climate model / station)
-- ------------------------------------------------
--   SWR  – surface downwelling shortwave radiation  [W m⁻²]
--   LWR  – surface downwelling longwave radiation   [W m⁻²]
--
--   Net shortwave:  Rns = (1 − 0.23) × SWR × 0.0864
--   Surface LW out: L_out = ε_s × σ × (T_max_K⁴ + T_min_K⁴)/2 × 0.0864
--                   (ε_s = 0.97, σ = 5.67×10⁻⁸ W m⁻² K⁻⁴)
--   Net longwave:   Rnl = LWR × 0.0864 − L_out      (negative = surface loss)
--   Net radiation:  Rn  = Rns + Rnl
--
-- Wind speed correction
-- ---------------------
--   u₂ = u_z × 4.87 / ln(67.8·z − 5.42)     (FAO-56 Eq. 47)
--   Climate model output is typically at z = 10 m (p_wind_height_m default).
--
-- Usage (psql / pgAdmin)
-- ----------------------
--   psql -h <host> -U <user> -d <db> -f add_et0_functions.sql
--
--   SELECT climate.get_et0(4.35, 50.85, '2045-01-01'::date, '2045-12-31'::date);
--   SELECT climate.get_et0(4.35, 50.85, 2045, 7);
--   SELECT climate.get_et0(4.35, 50.85, 2045);
--   SELECT climate.get_et0(4.35, 50.85, '2045-07-14'::date);
--   SELECT climate.get_et0_annual(4.35, 50.85, 2025, 2060);
-- =============================================================================

SET search_path TO climate, public;


-- =============================================================================
-- 1.  Pure Penman-Monteith calculation helper
--
--     Inputs
--     ------
--       p_t_max / p_t_min      daily maximum / minimum temperature [°C]
--       p_swr_w_m2             surface downwelling shortwave radiation [W m⁻²]
--       p_lwr_w_m2             surface downwelling longwave radiation  [W m⁻²]
--       p_wind_speed           wind speed at anemometer height [m s⁻¹]
--       p_rh_max / p_rh_min    daily max / min relative humidity [%]
--       p_altitude_m           station elevation [m a.s.l.]
--       p_wind_height_m        anemometer height (default 10 m for climate models)
--
--     Outputs (via OUT parameters)
--     ----------------------------
--       r_et0_mm               reference evapotranspiration  [mm day⁻¹]
--       r_rns / r_rnl / r_rn   net SW / net LW / net total radiation [MJ m⁻² day⁻¹]
--       r_es_kpa               saturation vapour pressure     [kPa]
--       r_ea_kpa               actual vapour pressure         [kPa]
--       r_vpd_kpa              vapour pressure deficit        [kPa]
--       r_delta_kpa_c          slope of sat. VP curve         [kPa °C⁻¹]
--       r_gamma_kpa_c          psychrometric constant         [kPa °C⁻¹]
--       r_pressure_kpa         atmospheric pressure           [kPa]
--       r_u2_m_s               wind speed corrected to 2 m   [m s⁻¹]
--       r_lambda_mj_kg         latent heat of vaporisation    [MJ kg⁻¹]
--
--     Returns all NULLs when any essential input is NULL.
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.calc_et0_pm(
    p_t_max          double precision,          -- daily max temperature  [°C]
    p_t_min          double precision,          -- daily min temperature  [°C]
    p_swr_w_m2       double precision,          -- downwelling SWR        [W m⁻²]
    p_lwr_w_m2       double precision,          -- downwelling LWR        [W m⁻²]
    p_wind_speed     double precision,          -- wind speed             [m s⁻¹]
    p_rh_max         double precision,          -- max relative humidity  [%]
    p_rh_min         double precision,          -- min relative humidity  [%]
    p_altitude_m     double precision,          -- station elevation      [m]
    p_wind_height_m  double precision DEFAULT 10.0, -- anemometer height  [m]
    -- OUT parameters
    OUT r_et0_mm         double precision,      -- reference ET           [mm day⁻¹]
    OUT r_rns_mj_m2_day  double precision,      -- net shortwave          [MJ m⁻² day⁻¹]
    OUT r_rnl_mj_m2_day  double precision,      -- net longwave           [MJ m⁻² day⁻¹]
    OUT r_rn_mj_m2_day   double precision,      -- net radiation          [MJ m⁻² day⁻¹]
    OUT r_es_kpa         double precision,      -- sat. vapour pressure   [kPa]
    OUT r_ea_kpa         double precision,      -- actual vapour pressure [kPa]
    OUT r_vpd_kpa        double precision,      -- vapour pressure deficit[kPa]
    OUT r_delta_kpa_c    double precision,      -- slope of sat. VP curve [kPa °C⁻¹]
    OUT r_gamma_kpa_c    double precision,      -- psychrometric constant [kPa °C⁻¹]
    OUT r_pressure_kpa   double precision,      -- atmospheric pressure   [kPa]
    OUT r_u2_m_s         double precision,      -- wind speed at 2 m      [m s⁻¹]
    OUT r_lambda_mj_kg   double precision       -- latent heat of evap.   [MJ kg⁻¹]
)
RETURNS record
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
AS $func$
DECLARE
    v_t_mean        double precision;
    v_t_max_k       double precision;
    v_t_min_k       double precision;
    v_eo_tmax       double precision;
    v_eo_tmin       double precision;
    v_eo_tmean      double precision;
    v_swr_mj        double precision;
    v_lwr_mj        double precision;
    v_lwr_out_mj    double precision;
    v_num           double precision;
    v_den           double precision;
BEGIN
    -- ── Guard: return all NULLs when essential inputs are missing ────────────
    IF p_t_max IS NULL OR p_t_min IS NULL
       OR p_swr_w_m2 IS NULL OR p_lwr_w_m2 IS NULL
       OR p_wind_speed IS NULL
       OR p_rh_max IS NULL OR p_rh_min IS NULL
    THEN
        RETURN;
    END IF;

    -- ── Mean temperature & Kelvin conversions ────────────────────────────────
    v_t_mean  := (p_t_max + p_t_min) / 2.0;
    v_t_max_k := p_t_max + 273.16;
    v_t_min_k := p_t_min + 273.16;

    -- ── Latent heat of vaporisation λ  (FAO-56 Appendix A.1.1) ──────────────
    --   λ [MJ kg⁻¹] = 2.501 − 0.002361 × T_mean
    r_lambda_mj_kg := 2.501 - 0.002361 * v_t_mean;

    -- ── Saturation vapour pressure  (FAO-56 Eq. 11) ──────────────────────────
    --   e°(T) = 0.6108 × exp( 17.27·T / (T + 237.3) )   [kPa]
    v_eo_tmax  := 0.6108 * exp(17.27 * p_t_max  / (p_t_max  + 237.3));
    v_eo_tmin  := 0.6108 * exp(17.27 * p_t_min  / (p_t_min  + 237.3));
    v_eo_tmean := 0.6108 * exp(17.27 * v_t_mean / (v_t_mean + 237.3));
    r_es_kpa   := (v_eo_tmax + v_eo_tmin) / 2.0;          -- FAO-56 Eq. 12

    -- ── Actual vapour pressure from relative humidity  (FAO-56 Eq. 17) ───────
    --   ea = [ e°(T_min)·RH_max/100 + e°(T_max)·RH_min/100 ] / 2
    --   (T_min ≈ dew-point when RH_max ≈ 100 %)
    r_ea_kpa := (  v_eo_tmin * LEAST(p_rh_max, 100.0) / 100.0
                 + v_eo_tmax * GREATEST(p_rh_min, 0.0) / 100.0 ) / 2.0;

    -- Clamp ea ≤ es  (physically impossible to exceed saturation)
    r_ea_kpa  := LEAST(r_ea_kpa, r_es_kpa);
    r_vpd_kpa := GREATEST(r_es_kpa - r_ea_kpa, 0.0);

    -- ── Slope of sat. vapour pressure curve Δ  (FAO-56 Eq. 13) ──────────────
    --   Δ = 4098 × e°(T_mean) / (T_mean + 237.3)²   [kPa °C⁻¹]
    r_delta_kpa_c := 4098.0 * v_eo_tmean / POWER(v_t_mean + 237.3, 2.0);

    -- ── Atmospheric pressure P  (FAO-56 Eq. 7) ───────────────────────────────
    --   P = 101.3 × [(293 − 0.0065·z) / 293]^5.26   [kPa]
    r_pressure_kpa := 101.3
                    * POWER((293.0 - 0.0065 * COALESCE(p_altitude_m, 0.0)) / 293.0, 5.26);

    -- ── Psychrometric constant γ  (FAO-56 Eq. 8) ─────────────────────────────
    --   γ = 0.000665 × P   [kPa °C⁻¹]
    r_gamma_kpa_c := 0.000665 * r_pressure_kpa;

    -- ── Wind speed at 2 m height  (FAO-56 Eq. 47) ────────────────────────────
    --   u₂ = u_z × 4.87 / ln(67.8·z − 5.42)
    --   Guard ensures the argument to ln() stays > 0  (z must be > 0.08 m).
    r_u2_m_s := p_wind_speed
              * (4.87 / ln(67.8 * GREATEST(p_wind_height_m, 0.09) - 5.42));

    -- ── Unit conversion: W m⁻² → MJ m⁻² day⁻¹   (× 86400/1 000 000 = ×0.0864) ─
    v_swr_mj := GREATEST(p_swr_w_m2, 0.0) * 0.0864;
    v_lwr_mj := GREATEST(p_lwr_w_m2, 0.0) * 0.0864;

    -- ── Net shortwave radiation  (FAO-56 Eq. 38) ─────────────────────────────
    --   Rns = (1 − α) × Rs ,  α = 0.23 for FAO-56 reference grass
    r_rns_mj_m2_day := 0.77 * v_swr_mj;

    -- ── Surface outgoing longwave radiation (Stefan-Boltzmann) ───────────────
    --   L_out = ε_s × σ × (T_max_K⁴ + T_min_K⁴) / 2
    --   σ as daily energy flux = 4.903 × 10⁻⁹ MJ m⁻² K⁻⁴ day⁻¹
    --                          = 5.67 × 10⁻⁸ W m⁻² K⁻⁴ × 86400 / 1 000 000
    --   ε_s = 0.97  (emissivity of moist short-grass surface)
    v_lwr_out_mj := 0.97 * 4.903e-9
                  * (POWER(v_t_max_k, 4.0) + POWER(v_t_min_k, 4.0)) / 2.0;

    -- ── Net longwave radiation ────────────────────────────────────────────────
    --   Rnl = LWR_in − L_out
    --   Sign convention: positive = net surface gain; typically negative
    --   (surface radiates more to atmosphere than it receives from it).
    r_rnl_mj_m2_day := v_lwr_mj - v_lwr_out_mj;

    -- ── Net radiation ─────────────────────────────────────────────────────────
    r_rn_mj_m2_day := r_rns_mj_m2_day + r_rnl_mj_m2_day;

    -- ── FAO-56 Penman-Monteith  (Eq. 6, G = 0 for daily step) ───────────────
    --
    --         0.408·Δ·Rn  +  γ · (900/(T+273)) · u₂ · (es−ea)
    --   ET0 = ──────────────────────────────────────────────────
    --                   Δ + γ · (1 + 0.34·u₂)
    --
    --   0.408 = 1/λ_ref  (λ_ref = 2.45 MJ kg⁻¹, FAO-56 standard value)
    --   900   = coefficient for FAO-56 reference crop aerodynamic resistance
    --
    v_num := 0.408 * r_delta_kpa_c * r_rn_mj_m2_day
           + r_gamma_kpa_c * (900.0 / (v_t_mean + 273.0))
           * r_u2_m_s * r_vpd_kpa;

    v_den := r_delta_kpa_c + r_gamma_kpa_c * (1.0 + 0.34 * r_u2_m_s);

    -- Clamp to 0 (ET0 cannot be negative)
    r_et0_mm := GREATEST(v_num / v_den, 0.0);
END;
$func$;

COMMENT ON FUNCTION climate.calc_et0_pm(
    double precision, double precision,
    double precision, double precision,
    double precision,
    double precision, double precision,
    double precision, double precision
) IS
'Pure FAO-56 Penman-Monteith ET0 calculation.
Inputs: T_max, T_min [°C], SWR, LWR [W m⁻²], wind speed [m s⁻¹],
        RH_max, RH_min [%], altitude [m], wind height [m] (default 10 m).
Returns all OUT parameters as NULL when any essential input is NULL.
Reference: Allen et al. (1998), FAO-56 Eq. 6.';


-- =============================================================================
-- 2.  get_et0 – daily Penman-Monteith ET0 + water-balance for a date range
--
--     For each calendar day in [p_date_from, p_date_to] the function returns:
--       • daily ET0 per model / scenario
--       • precipitation, water deficit and water surplus for that day
--       • full set of intermediate PM variables (Rn, es, ea, VPD, u₂, …)
--     plus an aggregated period-summary section per model / scenario.
--
--     Water-balance metrics (daily)
--     ─────────────────────────────
--       water_deficit_mm  = max(0, ET0 − precip)  "atmospheric demand unmet"
--       water_surplus_mm  = max(0, precip − ET0)  "potential groundwater recharge"
--
--     Period-summary metrics
--     ──────────────────────
--       total_et0_mm            cumulative reference evapotranspiration
--       total_precip_mm         cumulative precipitation
--       total_water_deficit_mm  cumulative unmet atmospheric demand
--       total_water_surplus_mm  cumulative surplus available for recharge
--       mean_daily_et0_mm       average daily ET0
--       aridity_index           total_precip / total_ET0  (UNEP scale)
--       drought_category        humid / dry_subhumid / semiarid / arid / hyperarid
--
--     Note: for long multi-year date ranges prefer get_et0_annual, which returns
--     annual aggregates without the (large) daily array.
--
--   Example
--   ───────
--   SELECT climate.get_et0(4.35, 50.85, '2045-01-01'::date, '2045-12-31'::date);
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_et0(
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
    v_station_altitude double precision;
    v_station_json     jsonb;
    v_et0_daily        jsonb;
    v_et0_summary      jsonb;
BEGIN
    -- ── 1. Nearest station (KNN spatial lookup) ───────────────────────────────
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

    -- ── 2. Daily ET0 array ────────────────────────────────────────────────────
    SELECT jsonb_agg(
        jsonb_build_object(
            'obs_date',          r.obs_date,
            'model_name',        r.model_name,
            'scenario_name',     r.scenario_name,
            'is_reference',      r.is_reference,
            -- Core ET0 output
            'et0_mm',            ROUND(r.et0_mm::numeric,         3),
            'precip_mm',         ROUND(COALESCE(r.precip, 0.0)::numeric, 3),
            'water_deficit_mm',  ROUND(GREATEST(r.et0_mm - COALESCE(r.precip, 0.0), 0.0)::numeric, 3),
            'water_surplus_mm',  ROUND(GREATEST(COALESCE(r.precip, 0.0) - r.et0_mm, 0.0)::numeric, 3),
            -- Radiation components
            'rn_mj_m2_day',      ROUND(r.rn_mj_m2_day::numeric,  4),
            'rns_mj_m2_day',     ROUND(r.rns_mj_m2_day::numeric, 4),
            'rnl_mj_m2_day',     ROUND(r.rnl_mj_m2_day::numeric, 4),
            -- Vapour pressure
            'es_kpa',            ROUND(r.es_kpa::numeric,         4),
            'ea_kpa',            ROUND(r.ea_kpa::numeric,         4),
            'vpd_kpa',           ROUND(r.vpd_kpa::numeric,        4),
            -- Ancillary PM parameters
            'delta_kpa_c',       ROUND(r.delta_kpa_c::numeric,    4),
            'gamma_kpa_c',       ROUND(r.gamma_kpa_c::numeric,    4),
            'pressure_kpa',      ROUND(r.pressure_kpa::numeric,   3),
            'lambda_mj_kg',      ROUND(r.lambda_mj_kg::numeric,   4),
            'u2_m_s',            ROUND(r.u2_m_s::numeric,         3),
            -- Raw climate inputs
            't_mean_c',          ROUND(((r.t_max + r.t_min) / 2.0)::numeric, 2),
            't_max_c',           ROUND(r.t_max::numeric,          2),
            't_min_c',           ROUND(r.t_min::numeric,          2),
            'swr_w_m2',          ROUND(r.swr_w_m2::numeric,       2),
            'lwr_w_m2',          ROUND(r.lwr_w_m2::numeric,       2),
            'wind_speed_m_s',    ROUND(r.wind_speed::numeric,     3),
            'rh_max_pct',        ROUND(r.rh_max::numeric,         1),
            'rh_min_pct',        ROUND(r.rh_min::numeric,         1)
        )
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.obs_date
    )
    INTO v_et0_daily
    FROM (
        SELECT
            t.obs_date,
            mdl.model_name,
            scn.scenario_name,
            scn.is_reference,
            t.temp_max         AS t_max,
            t.temp_min         AS t_min,
            p.precipitation    AS precip,
            swr.value          AS swr_w_m2,
            lwr.value          AS lwr_w_m2,
            ws.value           AS wind_speed,
            rhmax.value        AS rh_max,
            rhmin.value        AS rh_min,
            pm.r_et0_mm        AS et0_mm,
            pm.r_rns_mj_m2_day AS rns_mj_m2_day,
            pm.r_rnl_mj_m2_day AS rnl_mj_m2_day,
            pm.r_rn_mj_m2_day  AS rn_mj_m2_day,
            pm.r_es_kpa        AS es_kpa,
            pm.r_ea_kpa        AS ea_kpa,
            pm.r_vpd_kpa       AS vpd_kpa,
            pm.r_delta_kpa_c   AS delta_kpa_c,
            pm.r_gamma_kpa_c   AS gamma_kpa_c,
            pm.r_pressure_kpa  AS pressure_kpa,
            pm.r_u2_m_s        AS u2_m_s,
            pm.r_lambda_mj_kg  AS lambda_mj_kg
        FROM climate.temperature_observations t
        JOIN climate.climate_models mdl ON mdl.id = t.model_id
        JOIN climate.scenarios      scn ON scn.id = t.scenario_id
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
        -- LATERAL call: computes full PM for this row
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
          AND t.obs_date BETWEEN p_date_from AND p_date_to
    ) r;

    -- ── 3. Period summary per model / scenario ────────────────────────────────
    SELECT jsonb_agg(
        jsonb_build_object(
            'model_name',               s.model_name,
            'scenario_name',            s.scenario_name,
            'is_reference',             s.is_reference,
            'total_et0_mm',             ROUND(s.total_et0::numeric,    2),
            'total_precip_mm',          ROUND(s.total_precip::numeric, 2),
            'total_water_deficit_mm',   ROUND(s.total_deficit::numeric, 2),
            'total_water_surplus_mm',   ROUND(s.total_surplus::numeric, 2),
            'mean_daily_et0_mm',        ROUND(s.mean_et0::numeric,      3),
            'aridity_index',            ROUND(s.ai::numeric,            3),
            'drought_category',         CASE
                WHEN s.ai >= 0.65 THEN 'humid'
                WHEN s.ai >= 0.50 THEN 'dry_subhumid'
                WHEN s.ai >= 0.20 THEN 'semiarid'
                WHEN s.ai >= 0.05 THEN 'arid'
                ELSE                   'hyperarid'
            END,
            'days_with_et0',            s.days_et0
        )
        ORDER BY s.is_reference DESC, s.scenario_name, s.model_name
    )
    INTO v_et0_summary
    FROM (
        SELECT
            mdl.model_name,
            scn.scenario_name,
            scn.is_reference,
            COALESCE(SUM(pm.r_et0_mm), 0.0)                                          AS total_et0,
            COALESCE(SUM(p.precipitation), 0.0)                                       AS total_precip,
            COALESCE(SUM(GREATEST(pm.r_et0_mm - COALESCE(p.precipitation, 0.0), 0.0)), 0.0) AS total_deficit,
            COALESCE(SUM(GREATEST(COALESCE(p.precipitation, 0.0) - pm.r_et0_mm, 0.0)), 0.0) AS total_surplus,
            AVG(pm.r_et0_mm)                                                          AS mean_et0,
            CASE WHEN SUM(pm.r_et0_mm) > 0
                 THEN SUM(COALESCE(p.precipitation, 0.0)) / SUM(pm.r_et0_mm)
                 ELSE NULL
            END                                                                       AS ai,
            COUNT(pm.r_et0_mm)::int                                                   AS days_et0
        FROM climate.temperature_observations t
        JOIN climate.climate_models mdl ON mdl.id = t.model_id
        JOIN climate.scenarios      scn ON scn.id = t.scenario_id
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
                10.0
            )
        ) pm ON TRUE
        WHERE t.station_id = v_station_id
          AND t.obs_date BETWEEN p_date_from AND p_date_to
        GROUP BY mdl.model_name, scn.scenario_name, scn.is_reference
    ) s;

    -- ── 4. Assemble final JSONB result ────────────────────────────────────────
    RETURN jsonb_build_object(
        'nearest_station',    v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'date_from',  p_date_from::text,
            'date_to',    p_date_to::text,
            'method',     'FAO-56 Penman-Monteith',
            'wind_height_assumed_m', 10
        ),
        'et0_daily',          COALESCE(v_et0_daily,   '[]'::jsonb),
        'et0_period_summary', COALESCE(v_et0_summary, '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_et0(double precision, double precision, date, date) IS
'Returns daily FAO-56 Penman-Monteith reference evapotranspiration (ET0) for the
station nearest to (p_lon, p_lat) in [p_date_from, p_date_to].

JSON keys
  et0_daily          – one object per (date × model × scenario), containing ET0,
                       precipitation, water deficit/surplus and all intermediate
                       PM variables (Rn, es, ea, VPD, u2, Δ, γ, …).
  et0_period_summary – one object per (model × scenario) with cumulative totals,
                       mean daily ET0, aridity index and drought category.

Requires: climate.scalar_observations with SWR, LWR, WindSpeed, RHmax, RHmin.
For multi-year SSP comparisons prefer climate.get_et0_annual().';


-- =============================================================================
-- 3a.  Convenience overload: single calendar month
--
--   SELECT climate.get_et0(4.35, 50.85, 2045, 7);
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_et0(
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
    SELECT climate.get_et0(
        p_lon,
        p_lat,
        make_date(p_year, p_month, 1),
        (make_date(p_year, p_month, 1) + interval '1 month' - interval '1 day')::date
    );
$func$;

COMMENT ON FUNCTION climate.get_et0(double precision, double precision, integer, integer) IS
'Convenience overload: ET0 for a full calendar month. Delegates to the date-range variant.';


-- =============================================================================
-- 3b.  Convenience overload: full calendar year
--
--   SELECT climate.get_et0(4.35, 50.85, 2045);
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_et0(
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
    SELECT climate.get_et0(
        p_lon,
        p_lat,
        make_date(p_year, 1,  1),
        make_date(p_year, 12, 31)
    );
$func$;

COMMENT ON FUNCTION climate.get_et0(double precision, double precision, integer) IS
'Convenience overload: ET0 for a full calendar year. Delegates to the date-range variant.';


-- =============================================================================
-- 3c.  Convenience overload: single calendar day
--
--   SELECT climate.get_et0(4.35, 50.85, '2045-07-14'::date);
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_et0(
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
    SELECT climate.get_et0(p_lon, p_lat, p_date, p_date);
$func$;

COMMENT ON FUNCTION climate.get_et0(double precision, double precision, date) IS
'Convenience overload: ET0 for a single calendar day. Delegates to the date-range variant.';


-- =============================================================================
-- 4.  get_et0_annual – annual ET0 aggregates for SSP drought-risk comparison
--
--     For each year in [p_year_from, p_year_to] this function returns annual
--     totals and derived drought indicators per model / scenario combination,
--     making it easy to compare how ET0 demand and water deficit evolve under
--     SSP1-2.6, SSP2-4.5, SSP3-7.0 and SSP5-8.5 relative to the historical
--     reference run.
--
--     Drought indicators returned per year / model / scenario
--     ──────────────────────────────────────────────────────
--       total_et0_mm            cumulative reference ET          [mm yr⁻¹]
--       total_precip_mm         cumulative precipitation         [mm yr⁻¹]
--       total_water_deficit_mm  Σ max(0, ET0ᵢ − precipᵢ)        [mm yr⁻¹]
--       total_water_surplus_mm  Σ max(0, precipᵢ − ET0ᵢ)        [mm yr⁻¹]
--       mean_daily_et0_mm       mean daily ET0                   [mm day⁻¹]
--       max_daily_et0_mm        peak daily ET0                   [mm day⁻¹]
--       aridity_index           total_precip / total_ET0         (UNEP scale)
--       drought_category        humid/dry_subhumid/semiarid/arid/hyperarid
--       days_with_et0           count of days with full PM data
--
--   Example – compare SSP scenarios over 2025-2060 near Brussels:
--   SELECT climate.get_et0_annual(4.35, 50.85, 2025, 2060);
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.get_et0_annual(
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
    v_station_id       text;
    v_station_altitude double precision;
    v_station_json     jsonb;
    v_annual_et0       jsonb;
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

    -- ── 2. Annual ET0 aggregates ──────────────────────────────────────────────
    SELECT jsonb_agg(
        jsonb_build_object(
            'year',                     r.yr,
            'model_name',               r.model_name,
            'scenario_name',            r.scenario_name,
            'is_reference',             r.is_reference,
            'total_et0_mm',             ROUND(r.total_et0::numeric,      2),
            'total_precip_mm',          ROUND(r.total_precip::numeric,   2),
            'total_water_deficit_mm',   ROUND(r.total_deficit::numeric,  2),
            'total_water_surplus_mm',   ROUND(r.total_surplus::numeric,  2),
            'mean_daily_et0_mm',        ROUND(r.mean_et0::numeric,       3),
            'max_daily_et0_mm',         ROUND(r.max_et0::numeric,        3),
            'aridity_index',            ROUND(r.ai::numeric,             3),
            'drought_category',         CASE
                WHEN r.ai >= 0.65 THEN 'humid'
                WHEN r.ai >= 0.50 THEN 'dry_subhumid'
                WHEN r.ai >= 0.20 THEN 'semiarid'
                WHEN r.ai >= 0.05 THEN 'arid'
                ELSE                   'hyperarid'
            END,
            'days_with_et0',            r.days_et0
        )
        ORDER BY r.is_reference DESC, r.scenario_name, r.model_name, r.yr
    )
    INTO v_annual_et0
    FROM (
        SELECT
            EXTRACT(YEAR FROM t.obs_date)::int           AS yr,
            mdl.model_name,
            scn.scenario_name,
            scn.is_reference,
            COALESCE(SUM(pm.r_et0_mm), 0.0)                                           AS total_et0,
            COALESCE(SUM(p.precipitation), 0.0)                                        AS total_precip,
            COALESCE(SUM(GREATEST(pm.r_et0_mm - COALESCE(p.precipitation, 0.0), 0.0)), 0.0) AS total_deficit,
            COALESCE(SUM(GREATEST(COALESCE(p.precipitation, 0.0) - pm.r_et0_mm, 0.0)), 0.0) AS total_surplus,
            AVG(pm.r_et0_mm)                                                           AS mean_et0,
            MAX(pm.r_et0_mm)                                                           AS max_et0,
            CASE WHEN SUM(pm.r_et0_mm) > 0
                 THEN SUM(COALESCE(p.precipitation, 0.0)) / SUM(pm.r_et0_mm)
                 ELSE NULL
            END                                                                        AS ai,
            COUNT(pm.r_et0_mm)::int                                                    AS days_et0
        FROM climate.temperature_observations t
        JOIN climate.climate_models mdl ON mdl.id = t.model_id
        JOIN climate.scenarios      scn ON scn.id = t.scenario_id
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
                10.0
            )
        ) pm ON TRUE
        WHERE t.station_id = v_station_id
          AND EXTRACT(YEAR FROM t.obs_date) BETWEEN p_year_from AND p_year_to
        GROUP BY 1, mdl.model_name, scn.scenario_name, scn.is_reference
    ) r;

    -- ── 3. Final result ───────────────────────────────────────────────────────
    RETURN jsonb_build_object(
        'nearest_station', v_station_json,
        'query', jsonb_build_object(
            'input_lon',  p_lon,
            'input_lat',  p_lat,
            'year_from',  p_year_from,
            'year_to',    p_year_to,
            'method',     'FAO-56 Penman-Monteith',
            'wind_height_assumed_m', 10
        ),
        'annual_et0', COALESCE(v_annual_et0, '[]'::jsonb)
    );
END;
$func$;

COMMENT ON FUNCTION climate.get_et0_annual(double precision, double precision, integer, integer) IS
'Returns annual FAO-56 Penman-Monteith ET0 aggregates for every year in
[p_year_from, p_year_to] from the station nearest to (p_lon, p_lat).

Each entry in the "annual_et0" array carries a "year" field and includes
total ET0, precipitation, water deficit, water surplus, aridity index and
drought category per model / scenario.  Designed for cross-SSP drought-risk
comparisons and long-term trend analysis.

Aridity index (UNEP scale): total_precip / total_ET0
  ≥ 0.65  → humid
  0.50–0.65 → dry_subhumid
  0.20–0.50 → semiarid
  0.05–0.20 → arid
  < 0.05  → hyperarid';


-- =============================================================================
-- Done
-- =============================================================================
DO $$ BEGIN
    RAISE NOTICE '=======================================================';
    RAISE NOTICE 'ET0 functions installed:';
    RAISE NOTICE '  climate.calc_et0_pm(t_max, t_min, swr, lwr, wind,';
    RAISE NOTICE '                       rh_max, rh_min, alt [,z])';
    RAISE NOTICE '  climate.get_et0(lon, lat, date_from, date_to)';
    RAISE NOTICE '  climate.get_et0(lon, lat, year, month)';
    RAISE NOTICE '  climate.get_et0(lon, lat, year)';
    RAISE NOTICE '  climate.get_et0(lon, lat, date)';
    RAISE NOTICE '  climate.get_et0_annual(lon, lat, year_from, year_to)';
    RAISE NOTICE '=======================================================';
END $$;
