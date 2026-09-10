-- =============================================================================
-- add_voronoi.sql
--
-- Creates a pre-computed Voronoi tessellation for all climate stations, grouped
-- by city.  Each station owns exactly one polygon — the set of points on the
-- map that are closer to that station than to any other station in the same city.
--
-- Why Voronoi?
-- -----------
-- Every climate query first finds the station nearest to (lon, lat) and returns
-- that station's data.  The Voronoi cell is therefore the *area of validity* of
-- the result: any query point inside the cell will return the same station and
-- the same projection data.  Delivering the polygon in the response lets the
-- frontend (e.g. VC Map) render a clear "coverage polygon" around the result.
--
-- Implementation notes
-- --------------------
-- • ST_VoronoiPolygons() computes the Voronoi diagram for a given set of
--   input points (MULTIPOINT).  Each output polygon contains exactly one
--   input point.
-- • Cells are clipped to a 1.0-degree buffer around the convex hull of all
--   stations in the city.  This keeps the edge cells finite while ensuring
--   they fully enclose the inter-station space.
-- • If a city has only one station, ST_VoronoiPolygons returns the clip
--   envelope as the single cell — which is the correct "whole area" result.
-- • Matching output polygons back to stations uses ST_Within(station_geom,
--   voronoi_polygon), which is guaranteed to hold by construction.
-- • All geometries are stored in WGS84 (SRID 4326).
--
-- Refresh
-- -------
-- Re-run climate.refresh_station_voronoi() whenever stations are added or moved.
-- The function truncates and repopulates the table atomically in a transaction.
--
-- Table added
-- -----------
--   climate.station_voronoi
--
-- Function added
-- --------------
--   climate.refresh_station_voronoi()  – truncate + repopulate
--
-- All query functions (get_climate*, get_et0*, get_cwb*) return the Voronoi
-- cell as "voronoi_cell" (GeoJSON) inside their "nearest_station" JSON object.
-- The geometry is fetched inline via a correlated subquery at virtually zero
-- extra cost (PK lookup by station_id).
--
-- Usage
-- -----
--   psql -h <host> -U <user> -d <db> -f add_voronoi.sql
--   SELECT climate.refresh_station_voronoi();
-- =============================================================================

SET search_path TO climate, public;


-- =============================================================================
-- 1.  Table
-- =============================================================================
CREATE TABLE IF NOT EXISTS climate.station_voronoi (
    station_id  text        PRIMARY KEY
                            REFERENCES climate.stations(station_id)
                            ON DELETE CASCADE,
    city_id     integer     REFERENCES climate.cities(id),
    geom        geometry(Polygon, 4326) NOT NULL
);

COMMENT ON TABLE climate.station_voronoi IS
'Pre-computed Voronoi cells for every climate station.
Each row contains the polygon that is closer to station_id than to any other
station in the same city.  Used to return the area of validity ("voronoi_cell")
in every climate query response.  Refresh with climate.refresh_station_voronoi().';

COMMENT ON COLUMN climate.station_voronoi.station_id IS 'FK → climate.stations.station_id.';
COMMENT ON COLUMN climate.station_voronoi.city_id    IS 'FK → climate.cities.id.  Denormalised for efficient per-city queries.';
COMMENT ON COLUMN climate.station_voronoi.geom       IS 'Voronoi polygon in WGS84 (SRID 4326), clipped to a 1° buffer around the city convex hull. Exterior ring is stored CCW (ST_ForcePolygonCCW) so ST_AsGeoJSON() emits RFC 7946-compliant coordinates without requiring the options=8 flag.';


-- =============================================================================
-- 2.  Spatial index
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_station_voronoi_geom
    ON climate.station_voronoi USING gist (geom);

COMMENT ON INDEX climate.idx_station_voronoi_geom IS
'GiST index supporting spatial lookups on Voronoi cells (e.g. point-in-polygon
queries from the VC Map frontend: "which cell does this click fall into?").';


-- =============================================================================
-- 3.  refresh_station_voronoi()
--
--     Computes Voronoi cells fresh from the current station positions.
--     Safe to re-run at any time; wraps everything in a transaction so
--     the table is never left in a partially-populated state.
--
--     Algorithm (per city):
--       a. Collect all station geometries into a MULTIPOINT.
--       b. Build a clip envelope = ST_Expand(ST_Envelope(all_points), 1.0°).
--       c. Call ST_VoronoiPolygons(multipoint, tolerance=0, clip=clip_env).
--       d. Dump the resulting GeometryCollection into individual polygons.
--       e. Match each polygon to the station whose geometry falls within it
--          (guaranteed unique by the Voronoi construction).
-- =============================================================================
CREATE OR REPLACE FUNCTION climate.refresh_station_voronoi()
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = climate, public
AS $func$
BEGIN
    -- Full refresh inside this transaction block.
    -- TRUNCATE + INSERT is atomic from the caller's perspective.
    TRUNCATE climate.station_voronoi;

    INSERT INTO climate.station_voronoi (station_id, city_id, geom)
    WITH
    -- ── a. Per-city point collection + clip envelope ──────────────────────────
    city_pts AS (
        SELECT
            s.city_id,
            ST_Collect(s.geom)                              AS pts,
            -- 1.0 degree buffer around the bounding box of all city stations.
            -- Keeps edge cells finite while fully enclosing all inter-station space.
            ST_Expand(ST_Envelope(ST_Collect(s.geom)), 1.0) AS clip_env
        FROM climate.stations s
        WHERE s.geom IS NOT NULL
        GROUP BY s.city_id
    ),

    -- ── b. Voronoi polygons (one per station) ─────────────────────────────────
    voronoi_raw AS (
        SELECT
            cp.city_id,
            (ST_Dump(
                ST_VoronoiPolygons(
                    cp.pts,       -- input points (MULTIPOINT)
                    0.0,          -- snap tolerance
                    cp.clip_env   -- clip to this envelope
                )
            )).geom AS cell_geom
        FROM city_pts cp
    )

    -- ── c. Match each polygon to its station ──────────────────────────────────
    -- ST_Within is safe here: each station point falls strictly inside its
    -- Voronoi cell by construction.
    -- ST_ForcePolygonCCW ensures the exterior ring is counter-clockwise so that
    -- ST_AsGeoJSON() emits RFC 7946-compliant GeoJSON without needing option 8.
    SELECT
        s.station_id,
        s.city_id,
        ST_ForcePolygonCCW(
            ST_Intersection(vr.cell_geom, cp.clip_env)
        ) AS geom
    FROM voronoi_raw    vr
    JOIN city_pts       cp ON cp.city_id   = vr.city_id
    JOIN climate.stations s ON s.city_id   = vr.city_id
                           AND ST_Within(s.geom, vr.cell_geom);

    RAISE NOTICE 'station_voronoi refreshed: % rows inserted.',
        (SELECT COUNT(*) FROM climate.station_voronoi);
END;
$func$;

COMMENT ON FUNCTION climate.refresh_station_voronoi() IS
'Truncates and repopulates climate.station_voronoi with freshly computed Voronoi
cells for every station.  Run after adding or moving stations.
Uses ST_VoronoiPolygons per city, clipped to 1° around the city bounding box.';


-- =============================================================================
-- 4.  Initial population
-- =============================================================================
SELECT climate.refresh_station_voronoi();


-- =============================================================================
-- 5.  Verify
-- =============================================================================
SELECT
    c.name                              AS city,
    COUNT(sv.station_id)::int           AS voronoi_cells,
    COUNT(s.station_id)::int            AS total_stations,
    COUNT(sv.station_id)::int =
        COUNT(s.station_id)::int        AS all_covered,
    ROUND(AVG(
        ST_Area(sv.geom::geography) / 1e6   -- km²
    )::numeric, 1)                      AS avg_cell_area_km2
FROM climate.cities c
JOIN climate.stations    s  ON s.city_id  = c.id
LEFT JOIN climate.station_voronoi sv ON sv.station_id = s.station_id
GROUP BY c.id, c.name
ORDER BY c.name;


-- =============================================================================
-- Done
-- =============================================================================
DO $$ BEGIN
    RAISE NOTICE '=================================================';
    RAISE NOTICE 'Voronoi infrastructure ready:';
    RAISE NOTICE '  Table : climate.station_voronoi';
    RAISE NOTICE '  Index : climate.idx_station_voronoi_geom';
    RAISE NOTICE '  Fn    : climate.refresh_station_voronoi()';
    RAISE NOTICE '';
    RAISE NOTICE 'Next step: run patch_voronoi_in_functions.sql';
    RAISE NOTICE 'to add voronoi_cell to all query response objects.';
    RAISE NOTICE '=================================================';
END $$;
