# Climate DB delivery bundle

This package installs the climate database objects and imports FICLIMA (https://ficlima.org/) climate data from a
generic folder structure. It is not tied to a specific city. Every direct
subfolder under `Observations` or `Projections` is treated as a city name, for
example `Cluj-Napoca`, `Madrid`, or `Tallinn`.

## Prerequisites

- Python 3.10 or newer
- `pip` and network access to PyPI, or the two Python packages from
  `requirements.txt` must already be installed locally
- Access to an existing PostgreSQL database over its host and port
- The target database must already exist; this package does not create a
  database and does not start a PostgreSQL server
- PostGIS must be installed on the PostgreSQL server and available in the
  target database. The setup uses `geometry`, GiST indexes, and
  `ST_VoronoiPolygons`
- A database user with permission to create schemas, tables, functions,
  indexes, and materialized views
- The user must be allowed to run `CREATE EXTENSION postgis`, or an
  administrator must enable PostGIS in the target database beforehand
- Firewall, DNS, and, where applicable, TLS certificates must allow the
  machine running this bundle to connect to the PostgreSQL server
- The database server needs a minimum of **10 GB of free space per city** for
  storing the climate data.

This package does not start a PostgreSQL server or create a database. The city
must provide the host, port, database name, user, and password.

## Important steps for DB creation

- The database on the PostgreSQL server must be created before starting setup.
- To create it, use the standard SQL command `CREATE DATABASE climate_xxx;`
  or use **Create > Database** in pgAdmin. See the [PostgreSQL
  documentation](https://www.postgresql.org/docs/current/sql-createdatabase.html).
- Provide a valid database name and assign the required user privileges.
- After creating the database, select it and enable the `postgis` extension:
  - Run `CREATE EXTENSION postgis;` in SQL, as described in the
    [PostGIS documentation](https://www.postgresql.org/docs/current/sql-createextension.html).
  - Alternatively, in pgAdmin select **Create > Extension**, choose `postgis`,
    and click **Save**.
- You can then start the setup process.

### Pre-installation check for the database administrator

The administrator can use `psql` or pgAdmin to verify that PostGIS and the
function required for the Voronoi calculation are available:

```sql
SELECT postgis_version();
SELECT ST_AsText(
    ST_VoronoiPolygons(
        ST_GeomFromText('MULTIPOINT((0 0),(1 0),(0 1))', 4326)
    )
);
```

If the second command fails, the PostGIS installation must be updated or fixed
before running the setup.

A dedicated database for this installation is recommended. The package does
not drop tables, but it uses the `climate` schema and global keys for station,
model, and scenario names. An existing `climate` database should therefore be
checked by the administrator first.

## Expected data structure

The data folder must have the following structure:

```text
data-root/
├── Observations/
│   ├── Cluj-Napoca/
│   │   ├── Precipitation_observatories.txt
│   │   ├── Temperature_observatories.txt
│   │   ├── Precipitation/*.txt
│   │   └── Temperature/*.txt
│   └── Madrid/
└── Projections/
    ├── Cluj-Napoca/
    │   ├── Precipitation_observatories.txt
    │   ├── Temperature_observatories.txt
    │   ├── Precipitation_corrected/<model>/<scenario>/*.txt
    │   ├── Temperature_corrected/<model>/<scenario>/*.txt
    │   ├── LWR/<model>/<scenario>/*.txt
    │   ├── SWR/<model>/<scenario>/*.txt
    │   ├── RHmax/<model>/<scenario>/*.txt
    │   ├── RHmin/<model>/<scenario>/*.txt
    │   └── WindSpeed/<model>/<scenario>/*.txt
    └── Madrid/
```

Folder names must be identical in both directory trees. The script does not
apply city aliases or rename cities. The file formats and station ID parsing
match the existing importer. Names are case-sensitive; `Tallin` and `Tallinn`
are treated as two different names.

### File formats

- Observatory files are tab-separated text files with six or seven columns:
  `station_id`, `longitude`, `latitude`, optional `height`, `name`, `region`,
  `country_code`
- Precipitation and scalar variables use one row in the format:
  `YYYY MM DD value`
- Temperature uses one row in the format:
  `YYYY MM DD temp_min temp_max`
- Files must be UTF-8 encoded and have the `.txt` extension
- Projection model folders must follow the `NN_ModelName` pattern, for
  example `02_MPI-ESM1-2-HR`
- The station ID at the end of each filename must match an ID from an
  observatory file. Observation files typically end in `_precipitation.txt` or
  `_temperature.txt`; projection files end in `_<station_id>.txt`
- Empty or unparsable data lines are skipped and appear as warnings or reduced
  import counts

## Installation and import

From the bundle directory:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python run_setup.py --data-root C:\path\to\data-root `
  --host postgres.example.org `
  --port 5432 `
  --database climate `
  --user climate_admin
```

`run_setup.py` installs the schema migrations, including scalar support, before
it imports observations and projections. Do not run the legacy scripts in the
repository's `initFunctions` folder separately when using this delivery bundle.

The password is requested interactively. Alternatively, set `DB_PASSWORD`.
The host, database, user, port, and `sslmode` can also be provided through
`DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PORT`, and `DB_SSLMODE`. For a remote server
that requires TLS, for example, use `DB_SSLMODE=require`.

By default, the setup imports all detected city folders. Individual cities can
be selected explicitly:

```powershell
python run_setup.py --data-root C:\path\to\data-root --city Cluj-Napoca
```

`--city` can be specified more than once. Every selected city must exist in
both directory trees. Without `--city`, setup stops if the city lists under
`Observations` and `Projections` do not match exactly.

The process can be run again. Inserts use the existing unique constraints and
`ON CONFLICT`, so existing data is not duplicated. Existing observation or
projection rows are not overwritten on a subsequent run. If source files are
corrected, the affected data must be deliberately removed by the database
administrator before re-importing, or the import should be performed into a
new database.

Depending on the amount of data, the import can take a long time and requires
enough network transfer capacity, database storage, and disk space. The
`--workers` parameter controls the number of parallel import connections; use a
lower value if PostgreSQL has a limited connection capacity.

## Validation

```powershell
python validate_installation.py `
  --host postgres.example.org `
  --port 5432 `
  --database climate `
  --user climate_admin
```

The validator checks the PostGIS version, the main tables, and a query
function. The setup run also refreshes the annual materialized views and the
station Voronoi polygons.

## Shell wrappers

On Windows:

```powershell
.\scripts\run_setup.ps1 -DataRoot C:\path\to\data-root `
  -DbHost postgres.example.org -Database climate -User climate_admin
```

On Linux or macOS:

```bash
./scripts/run_setup.sh --data-root /path/to/data-root \
  --host postgres.example.org --database climate --user climate_admin
```

## Using the database

After setup, the database can be used to retrieve climate values for a
location, compare observation and projection scenarios, and calculate event,
ET0, and climatic water-balance indicators.

### Location lookup

All spatial functions accept a longitude and latitude in decimal WGS84
coordinates. Pass longitude first and latitude second:

```text
--lon 23.5667 --lat 46.7831
```

The coordinates identify the location to query; they do not need to be the
exact coordinates of a station. The function searches the station geometry
with the smallest geographic distance and uses that station's data. The
response includes the selected station in `nearest_station`, including its
`station_id`, city, coordinates, and `distance_m` from the requested point.
The functions do not interpolate between stations or combine values from
multiple stations. Check `distance_m` and choose coordinates within the city
or station area you intend to analyse.

### Values and periods

The base `get_climate` function returns temperature and precipitation values
for the nearest station. Results are separated by imported `model_name` and
`scenario_name`, so one response can contain the reference observations and
multiple climate projections. Use one of these period selections:

| Request                                              | Result                               |
| ---------------------------------------------------- | ------------------------------------ |
| `--date 2045-07-14`                                  | Values for one calendar day.         |
| `--from 2045-01-01 --to 2045-12-31`                  | Values for an explicit date range.   |
| `--year 2045`                                        | Values for a complete calendar year. |
| `--year 2045 --month 7`                              | Values for one calendar month.       |
| `--year-from 2045 --year-to 2060`                    | One row per year for a trend.        |
| `--year-from 2045 --year-to 2060 --season summer`    | One row per season year.             |
| `--year-from 2045 --year-to 2060 --month 7 --day 14` | The same calendar day across years.  |

The returned aggregates describe the requested period. For example,
`total_precipitation_mm` is the precipitation sum for that period, while
`avg_temp_max` is the average of the daily maximum temperatures. Daily
functions return `obs_date` so individual days can be inspected.

### Optional analyses

Add one or more `--include` values to request additional calculations:

- `events` returns heat, frost, precipitation, wind, humidity, radiation, and
  combined event statistics.
- `et0` calculates FAO-56 reference evapotranspiration from temperature,
  radiation, humidity, and wind data.
- `cwb` calculates precipitation minus ET0 together with soil moisture,
  actual evapotranspiration, water stress, and runoff indicators. CWB implies
  ET0 and requires the same scalar inputs.

For example, this requests all available analyses for a full year:

```powershell
python query_climate.py --env .env --lon 23.5667 --lat 46.7831 `
  --year 2045 --include events et0 cwb
```

The query client prints the JSON response to the console. Applications can
also import `query_climate.py` and call `query_climate()` directly, or call
the PostgreSQL functions from SQL. For example:

```sql
SELECT climate.get_climate(
    23.5667, 46.7831,
    DATE '2045-01-01', DATE '2045-12-31'
);

SELECT climate.get_et0(
    23.5667, 46.7831,
    DATE '2045-01-01', DATE '2045-12-31'
);

SELECT climate.get_cwb(
    23.5667, 46.7831,
    DATE '2045-01-01', DATE '2045-12-31',
    150.0
);
```

If no source data exists for the selected station, period, model, scenario,
or required scalar variable, the relevant result array can be empty or a
derived value can be `null`. A `null` ET0 or CWB value means that the
calculation could not be completed from the available inputs; it does not
mean zero climate impact.

## Query example

After a successful installation, use the included query script:
**Replace lat / lon coordinates with values of a location in your city. The given example is a point in Cluj-Napoca. So it won't work in any other city!!**

See the [`.env` configuration](#using-the-database) information above.

```powershell
python query_climate.py --env .env --lon 23.5667 --lat 46.7831 \
  --year 2045 --include events et0 cwb
```

The setup process does **not** create a `.env` file. It reads connection values
from environment variables or asks interactively for missing values. The
`.env` file is only needed when using the included `query_climate.py` client.

Create a local `.env` file in the bundle directory by copying `.env.example`
and replacing the placeholder values:

```powershell
Copy-Item .env.example .env
notepad .env
```

The query script reads `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and
optionally `DB_PORT` from that file. Do not commit or share the resulting
`.env`, because it contains database credentials. The setup runner can also
use the same values through environment variables, but does not require or
create the file.

## Import of data

The setup process will automatically import the climate observation and projection data into the respective tables. This process can easily take several hours, depending on internet connection, amount of data and provided variables. **A test run of the setup for Cluj-Napoca took 35 minutes and uses 6.2 GB of database storage.**

## Data model

Observations and projections are stored in the same tables. Flat observation
files receive the following reference values:

- Model: `ERA5`
- Scenario: `ERA5_Observed`
- `is_reference`: `true`

Projection model and scenario names are preserved from their folders. The
known scalar variables `LWR`, `SWR`, `RHmax`, `RHmin`, and `WindSpeed` are
imported into `climate.scalar_observations`.

## Schema functions

The setup installs the following functions in the `climate` schema. The query
functions return JSONB documents. Most query functions are available with
explicit date ranges and convenience overloads for a single date, calendar
month, or calendar year.

### Core climate queries

- `climate.get_climate(lon, lat, date_from, date_to)` returns aggregated
  temperature and precipitation for the station nearest to the requested
  coordinates, for all imported models and scenarios.
- `climate.get_climate(lon, lat, date)` returns the same climate data for one
  calendar day.
- `climate.get_climate(lon, lat, year, month)` returns data for one calendar
  month.
- `climate.get_climate(lon, lat, year)` returns data for one calendar year.
- `climate.get_climate_annual(lon, lat, year_from, year_to)` returns annual
  climate summaries for a multi-year trend.
- `climate.get_climate_seasonal(lon, lat, season, year_from, year_to)` returns
  seasonal climate summaries for spring, summer, autumn, or winter.
- `climate.get_climate_day_of_year(lon, lat, month, day, year_from, year_to)`
  compares the same calendar day across multiple years.

### Event analysis

- `climate.get_climate_events(lon, lat, date_from, date_to)` calculates
  threshold events, degree-day totals, heatwave statistics, and dry-spell
  statistics for a date range. Date, month, and year overloads are also
  available.
- `climate.get_climate_events_annual(lon, lat, year_from, year_to)` returns
  event metrics for each year in a multi-year trend.
- `climate.get_climate_events_seasonal(lon, lat, season, year_from, year_to)`
  returns event metrics for each requested season and year.
- `climate.get_climate_events_day_of_year(lon, lat, month, day, year_from,
year_to)` evaluates event metrics for one calendar day across multiple years.

### Evapotranspiration and water balance

- `climate.calc_et0_pm(...)` is the FAO-56 Penman-Monteith calculation helper
  for reference evapotranspiration (ET0).
- `climate.get_et0(lon, lat, date_from, date_to)` calculates daily ET0 and
  period summaries using temperature, radiation, humidity, and wind data.
  Date, month, and year overloads are also available.
- `climate.get_et0_annual(lon, lat, year_from, year_to)` returns annual ET0
  summaries for a multi-year trend.
- `climate.get_et0_seasonal(lon, lat, season, year_from, year_to)` returns
  seasonal ET0 summaries for a multi-year trend.
- `climate.get_et0_day_of_year(lon, lat, month, day, year_from, year_to)`
  compares ET0 for one calendar day across multiple years.
- `climate.get_cwb(lon, lat, date_from, date_to [, awc_mm])` calculates the
  climatic water balance and sequential soil-moisture state using precipitation
  and ET0. Date, month, and year overloads are also available.
- `climate.get_cwb_annual(lon, lat, year_from, year_to [, awc_mm])` returns
  annual climatic water-balance summaries and soil-moisture indicators.

### Spatial support

- `climate.refresh_station_voronoi()` rebuilds the Voronoi polygon for every
  station, grouped by city. The setup runs this after importing stations.
  Run it again whenever station locations are added or changed.

## Delivered attributes and meanings

All query functions return a JSONB document. The Python query client prints
the same structure as JSON and merges requested extras such as `events`, `et0`,
and `cwb` into the base climate response. Arrays contain separate entries for
each model and scenario unless stated otherwise.

### Common response attributes

| Attribute                                   | Meaning                                                                       |
| ------------------------------------------- | ----------------------------------------------------------------------------- |
| `nearest_station`                           | Metadata for the station nearest to the requested WGS84 coordinates.          |
| `query`                                     | The input coordinates and period, plus calculation settings where applicable. |
| `temperature`                               | Temperature observations or aggregates.                                       |
| `precipitation`                             | Precipitation observations or aggregates.                                     |
| `LWR`, `SWR`, `RHmax`, `RHmin`, `WindSpeed` | Scalar-variable observations or aggregates, when available.                   |

The `nearest_station` object contains `station_id`, `name`, `city`, `region`,
`country_code`, `latitude`, `longitude`, `height_m`, `distance_m`, and
`voronoi_cell`. Coordinates use WGS84; `distance_m` is the distance from the
requested point in metres; `voronoi_cell` is a GeoJSON geometry and can be
`null` if no Voronoi polygon exists.

Most array rows also contain these fields:

| Attribute             | Meaning                                                                            |
| --------------------- | ---------------------------------------------------------------------------------- |
| `model_name`          | Climate model name, or `ERA5` for reference observations.                          |
| `scenario_name`       | Projection scenario or `ERA5_Observed` for reference observations.                 |
| `is_reference`        | `true` for reference observations and `false` for projections.                     |
| `year`                | Calendar year for annual and day-of-year trend results.                            |
| `season_year`         | Year assigned to a seasonal result. December belongs to the following winter year. |
| `obs_date`            | Observation date for daily results.                                                |
| `days` or `day_count` | Number of source days represented by the row.                                      |

The `query` object can additionally contain `date_from`, `date_to`,
`year_from`, `year_to`, `month`, `day`, `season`, `method`,
`wind_height_assumed_m`, `awc_mm`, and an explanatory `note`, depending on
the function.

### Climate attributes

Temperature aggregate rows contain:

| Attribute                      | Meaning                                        | Unit  |
| ------------------------------ | ---------------------------------------------- | ----- |
| `avg_temp_min`, `avg_temp_max` | Average daily minimum and maximum temperature. | deg C |
| `min_temp_min`                 | Lowest recorded daily minimum temperature.     | deg C |
| `max_temp_max`                 | Highest recorded daily maximum temperature.    | deg C |

Precipitation aggregate rows contain:

| Attribute                    | Meaning                                  | Unit   |
| ---------------------------- | ---------------------------------------- | ------ |
| `total_precipitation_mm`     | Sum of precipitation over the period.    | mm     |
| `avg_daily_precipitation_mm` | Average precipitation per source day.    | mm/day |
| `max_daily_precipitation_mm` | Maximum precipitation on one source day. | mm/day |

The top-level scalar key identifies the variable. Scalar aggregate rows contain
`avg_value`, `min_value`, `max_value`, and `days`. Trend rows may also contain
`variable` and `year` or `season_year`. The scalar units are `W/m2` for `LWR`
and `SWR`, `%` for `RHmax` and `RHmin`, and `m/s` for `WindSpeed`. Day-of-year
results instead expose the raw scalar as `value`.

### Event attributes

The date-range event function returns `temperature_events`,
`precipitation_events`, `wind_events`, `humidity_events`, `radiation_events`,
and `combined_events`. Annual and seasonal event functions return the same
metrics in an `events` array, with an additional `year` or `season_year`.

Temperature event rows contain:

| Attribute           | Meaning                                                            |
| ------------------- | ------------------------------------------------------------------ |
| `heat_days`         | Days with maximum temperature above 30 deg C.                      |
| `desert_days`       | Days with maximum temperature above 35 deg C.                      |
| `tropical_nights`   | Days with minimum temperature above 20 deg C.                      |
| `frost_days`        | Days with minimum temperature below 0 deg C.                       |
| `ice_days`          | Days with maximum temperature below 0 deg C.                       |
| `max_heatwave_days` | Longest consecutive run with maximum temperature above 30 deg C.   |
| `hdd18`, `cdd22`    | Heating and cooling degree-day totals using bases 18 and 22 deg C. |
| `gdd5`, `gdd10`     | Growing degree-day totals using bases 5 and 10 deg C.              |

Precipitation event rows contain `total_precip_mm`, `max_daily_precip_mm`,
`wet_days` (at least 1 mm), `dry_days` (below 1 mm), `heavy_rain_days` (at
least 10 mm), `very_heavy_rain_days` (at least 20 mm), and
`max_dry_spell_days`.

Wind event rows contain `mean_wind_speed`, `max_wind_speed`, `calm_days`
(below 1 m/s), `strong_wind_days` (above 10 m/s), and `storm_days` (above
17 m/s). Humidity event rows contain `mean_rh`, `mean_rh_max`, `mean_rh_min`,
`high_humidity_days` (RHmax above 90%), and `low_humidity_days` (RHmin below
30%).

Radiation event rows contain `mean_swr_w_m2`, `max_swr_w_m2`,
`high_solar_days` (SWR above 200 W/m2), `low_solar_days` (SWR below 50 W/m2),
`total_solar_kwh_m2`, `mean_lwr_w_m2`, `min_lwr_w_m2`, and `max_lwr_w_m2`.

Combined event rows contain `hot_and_dry_days` (maximum temperature above 30
deg C and RHmin below 30%), `stagnation_days` (mean temperature above 25 deg C
and wind below 2 m/s), and `hot_humid_nights` (minimum temperature above 20
deg C and RHmax above 80%).

### ET0 attributes

`get_et0` returns `et0_daily` and `et0_period_summary`. Annual, seasonal, and
day-of-year ET0 functions return the corresponding rows in `annual_et0`.

ET0 means reference evapotranspiration. It estimates how much water a healthy,
well-watered reference grass surface would lose through evaporation and plant
transpiration under the given day's weather conditions. It is an atmospheric
water-demand indicator, not a direct measurement of the actual water loss from
a specific crop, soil, or city. The implementation uses the FAO-56
Penman-Monteith method and combines temperature, radiation, humidity, wind, and
station altitude. ET0 is expressed as millimetres of water per day and is used
as the potential evapotranspiration input for the climatic water-balance
calculation. Actual evapotranspiration (`aet_mm`) can be lower when the soil
does not contain enough available water.

ET0 requires temperature, `SWR`, `LWR`, `WindSpeed`, `RHmax`, and `RHmin` for
the same station, model, scenario, and date.

Daily ET0 rows contain:

| Attribute                                | Meaning                                                                          | Unit            |
| ---------------------------------------- | -------------------------------------------------------------------------------- | --------------- |
| `et0_mm`                                 | FAO-56 Penman-Monteith reference evapotranspiration.                             | mm/day          |
| `precip_mm`                              | Precipitation for the day.                                                       | mm              |
| `water_deficit_mm`                       | ET0 exceeding precipitation.                                                     | mm              |
| `water_surplus_mm`                       | Precipitation exceeding ET0.                                                     | mm              |
| `rn_mj_m2_day`                           | Net radiation.                                                                   | MJ/m2/day       |
| `rns_mj_m2_day`                          | Net shortwave radiation.                                                         | MJ/m2/day       |
| `rnl_mj_m2_day`                          | Net longwave radiation.                                                          | MJ/m2/day       |
| `es_kpa`, `ea_kpa`, `vpd_kpa`            | Saturation vapour pressure, actual vapour pressure, and vapour pressure deficit. | kPa             |
| `delta_kpa_c`, `gamma_kpa_c`             | Slope of the saturation vapour pressure curve and psychrometric constant.        | kPa/deg C       |
| `pressure_kpa`                           | Estimated atmospheric pressure from station altitude.                            | kPa             |
| `lambda_mj_kg`                           | Latent heat of vaporisation.                                                     | MJ/kg           |
| `u2_m_s`                                 | Wind speed adjusted to 2 m.                                                      | m/s             |
| `t_mean_c`, `t_max_c`, `t_min_c`         | Mean, maximum, and minimum temperature used by the calculation.                  | deg C           |
| `swr_w_m2`, `lwr_w_m2`, `wind_speed_m_s` | Raw radiation and wind inputs.                                                   | W/m2, W/m2, m/s |
| `rh_max_pct`, `rh_min_pct`               | Raw relative-humidity inputs.                                                    | %               |

ET0 period, annual, and seasonal rows contain `total_et0_mm`,
`total_precip_mm`, `total_water_deficit_mm`, `total_water_surplus_mm`,
`mean_daily_et0_mm`, and, where applicable, `max_daily_et0_mm`,
`aridity_index`, `drought_category`, and `days_with_et0`. The aridity index
is precipitation divided by ET0. Categories are `humid`, `dry_subhumid`,
`semiarid`, `arid`, and `hyperarid`.

### Climatic water balance attributes

`get_cwb` returns `cwb_daily` and `cwb_period_summary`; `get_cwb_annual`
returns `annual_cwb`. The soil-moisture simulation starts at the configured
available water capacity (`awc_mm`, default 150 mm) and carries the state
forward through the requested period.

Daily CWB rows contain:

| Attribute                  | Meaning                                                                    | Unit  |
| -------------------------- | -------------------------------------------------------------------------- | ----- |
| `et0_mm`                   | Reference evapotranspiration used by the water-balance step.               | mm    |
| `precip_mm`                | Precipitation input.                                                       | mm    |
| `cwb_mm`                   | Climatic water balance, calculated as precipitation minus ET0.             | mm    |
| `aet_mm`                   | Actual evapotranspiration limited by available water.                      | mm    |
| `water_stress_index`       | Moisture stress from 0 (no stress) to 1 (maximum stress).                  | index |
| `soil_moisture_mm`         | Soil water remaining after the daily step.                                 | mm    |
| `soil_moisture_deficit_mm` | `awc_mm` minus soil moisture.                                              | mm    |
| `runoff_mm`                | Water above the configured soil capacity; used as a recharge/runoff proxy. | mm    |

Period and annual CWB rows contain `total_et0_mm`, `total_precip_mm`,
`total_cwb_mm`, `total_aet_mm`, `total_recharge_proxy_mm`,
`min_soil_moisture_mm`, `final_soil_moisture_mm` or
`end_soil_moisture_mm`, `max_consecutive_deficit_days`, `aridity_index`,
`drought_category`, `days_with_cwb`, and `awc_mm`.

Derived ET0 and CWB attributes are `null` when the required scalar inputs are
missing for that exact station, model, scenario, or date. This represents an
unavailable calculation; it is not an initialized zero value.
