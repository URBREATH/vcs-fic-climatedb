-- =============================================================================
-- add_indexes_and_mvs.sql
--
-- 1. Composite indexes with obs_date for fast date-range queries
-- 2. Materialized views for annual summaries (instant trend queries)
--
-- Run in pgAdmin / psql:
--   psql -h <host> -U <user> -d <db> -f add_indexes_and_mvs.sql
--
-- Note: The delivery setup executes this complete file in one database call.
--       Use regular CREATE INDEX statements here because PostgreSQL does not
--       allow CREATE INDEX CONCURRENTLY inside a multi-statement call.
-- =============================================================================

SET search_path TO climate, public;


-- =============================================================================
-- 1. Indexes
-- =============================================================================

-- temperature_observations: date-range scans by station/model/scenario
CREATE INDEX IF NOT EXISTS idx_temp_station_date
    ON climate.temperature_observations(station_id, model_id, scenario_id, obs_date);

-- precipitation_observations: date-range scans by station/model/scenario
CREATE INDEX IF NOT EXISTS idx_precip_station_date
    ON climate.precipitation_observations(station_id, model_id, scenario_id, obs_date);

-- scalar_observations: date-range scans by station/model/scenario/variable
CREATE INDEX IF NOT EXISTS idx_scalar_station_date
    ON climate.scalar_observations(station_id, model_id, scenario_id, variable, obs_date);


-- =============================================================================
-- 2. Materialized view: annual temperature summary
--
--    One row per (station_id, model_id, scenario_id, year).
--    All event counts computed in a single pass over the data.
--    Refresh after each ingest run with:
--      REFRESH MATERIALIZED VIEW CONCURRENTLY climate.mv_annual_temp;
-- =============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS climate.mv_annual_temp AS
SELECT
    station_id,
    model_id,
    scenario_id,
    EXTRACT(YEAR FROM obs_date)::int                                   AS year,
    ROUND(AVG(temp_min)::numeric, 2)                                   AS avg_tmin,
    ROUND(AVG(temp_max)::numeric, 2)                                   AS avg_tmax,
    ROUND(AVG((temp_min + temp_max) / 2.0)::numeric, 2)               AS avg_tmean,
    ROUND(MIN(temp_min)::numeric, 2)                                   AS abs_tmin,
    ROUND(MAX(temp_max)::numeric, 2)                                   AS abs_tmax,
    -- Threshold event counts (in a single pass)
    COUNT(*) FILTER (WHERE temp_max > 30)::int                        AS heat_days,
    COUNT(*) FILTER (WHERE temp_max > 35)::int                        AS desert_days,
    COUNT(*) FILTER (WHERE temp_min > 20)::int                        AS tropical_nights,
    COUNT(*) FILTER (WHERE temp_max < 0)::int                         AS ice_days,
    COUNT(*) FILTER (WHERE temp_min < 0)::int                         AS frost_days,
    -- Degree days (base 18 °C for HDD, base 22 °C for CDD – standard EU)
    ROUND(SUM(GREATEST(0, 18.0 - (temp_min + temp_max) / 2.0))::numeric, 1)  AS hdd18,
    ROUND(SUM(GREATEST(0, (temp_min + temp_max) / 2.0 - 22.0))::numeric, 1) AS cdd22,
    -- GDD base 5 °C (growing degree days, agri standard)
    ROUND(SUM(GREATEST(0, (temp_min + temp_max) / 2.0 - 5.0))::numeric, 1)  AS gdd5,
    -- GDD base 10 °C (maize / warm crops)
    ROUND(SUM(GREATEST(0, (temp_min + temp_max) / 2.0 - 10.0))::numeric, 1) AS gdd10,
    COUNT(*)::int                                                       AS day_count
FROM climate.temperature_observations
GROUP BY station_id, model_id, scenario_id, EXTRACT(YEAR FROM obs_date);

-- Unique index required for REFRESH CONCURRENTLY
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_annual_temp_pk
    ON climate.mv_annual_temp(station_id, model_id, scenario_id, year);

-- Index for spatial lookup (join with nearest station)
CREATE INDEX IF NOT EXISTS idx_mv_annual_temp_station
    ON climate.mv_annual_temp(station_id, year);

COMMENT ON MATERIALIZED VIEW climate.mv_annual_temp IS
'Annual temperature statistics per (station, model, scenario, year).
Includes avg/min/max temps, event counts (heat days, frost days, etc.),
HDD18, CDD22, GDD5, GDD10.
Refresh after each ingest: REFRESH MATERIALIZED VIEW CONCURRENTLY climate.mv_annual_temp;';


-- =============================================================================
-- 3. Materialized view: annual precipitation summary
-- =============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS climate.mv_annual_precip AS
SELECT
    station_id,
    model_id,
    scenario_id,
    EXTRACT(YEAR FROM obs_date)::int                                          AS year,
    ROUND(SUM(precipitation)::numeric, 1)                                     AS total_precip_mm,
    ROUND(AVG(precipitation)::numeric, 2)                                     AS avg_daily_precip_mm,
    ROUND(MAX(precipitation)::numeric, 2)                                     AS max_daily_precip_mm,
    COUNT(*) FILTER (WHERE precipitation >= 1.0)::int                        AS wet_days,
    COUNT(*) FILTER (WHERE precipitation < 1.0)::int                         AS dry_days,
    COUNT(*) FILTER (WHERE precipitation >= 10.0)::int                       AS heavy_rain_days,
    COUNT(*) FILTER (WHERE precipitation >= 20.0)::int                       AS very_heavy_rain_days,
    COUNT(*)::int                                                              AS day_count
FROM climate.precipitation_observations
GROUP BY station_id, model_id, scenario_id, EXTRACT(YEAR FROM obs_date);

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_annual_precip_pk
    ON climate.mv_annual_precip(station_id, model_id, scenario_id, year);

CREATE INDEX IF NOT EXISTS idx_mv_annual_precip_station
    ON climate.mv_annual_precip(station_id, year);

COMMENT ON MATERIALIZED VIEW climate.mv_annual_precip IS
'Annual precipitation statistics per (station, model, scenario, year).
Includes total, avg, max daily precip, wet/dry/heavy rain day counts.
Refresh after each ingest: REFRESH MATERIALIZED VIEW CONCURRENTLY climate.mv_annual_precip;';


-- =============================================================================
-- Done
-- =============================================================================
DO $$ BEGIN
    RAISE NOTICE '======================================================';
    RAISE NOTICE 'Indexes and materialized views created successfully.';
    RAISE NOTICE '';
    RAISE NOTICE 'New indexes:';
    RAISE NOTICE '  idx_temp_station_date    (temperature_observations)';
    RAISE NOTICE '  idx_precip_station_date  (precipitation_observations)';
    RAISE NOTICE '  idx_scalar_station_date  (scalar_observations)';
    RAISE NOTICE '';
    RAISE NOTICE 'New materialized views:';
    RAISE NOTICE '  climate.mv_annual_temp   (~rows: stations × models × scenarios × years)';
    RAISE NOTICE '  climate.mv_annual_precip (~rows: stations × models × scenarios × years)';
    RAISE NOTICE '';
    RAISE NOTICE 'To refresh after ingest:';
    RAISE NOTICE '  REFRESH MATERIALIZED VIEW CONCURRENTLY climate.mv_annual_temp;';
    RAISE NOTICE '  REFRESH MATERIALIZED VIEW CONCURRENTLY climate.mv_annual_precip;';
    RAISE NOTICE '======================================================';
END $$;
