-- Run this in pgAdmin / psql to add the single-date overload to an already
-- migrated database.

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
