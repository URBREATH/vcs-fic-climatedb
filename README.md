# Climate DB delivery bundle

**Provided by:** virtualcitySYSTEMS based on FICLIMA data

## Description

This package installs climate database objects and imports FICLIMA climate observations and projections from a generic folder structure. It is not tied to a specific city: each direct subfolder under `Observations` or `Projections` is treated as a city.

The package installs a PostgreSQL schema with PostGIS support, imports climate data, and provides functions for querying temperature and precipitation, comparing observation and projection scenarios, and calculating event, ET0, and climatic water-balance indicators.

## Installation Prerequisites

- Python 3.10 or newer.
- `pip` and network access to PyPI, or the Python packages listed in `requirements.txt` already installed locally.
- An existing PostgreSQL database accessible over its host and port. The package does not create a database or start a PostgreSQL server.
- PostGIS installed on the server and available in the target database. The setup uses `geometry`, GiST indexes, and `ST_VoronoiPolygons`.
- A database user permitted to create schemas, tables, functions, indexes, and materialized views, and to run `CREATE EXTENSION postgis`. An administrator can enable PostGIS beforehand if needed.
- Firewall, DNS, and, where applicable, TLS configuration that allows the setup machine to connect to PostgreSQL.
- At least **10 GB of free database server space per city**.

A dedicated database is recommended. The package uses the `climate` schema and global keys for station, model, and scenario names. The administrator should check any existing `climate` schema before setup. The package does not drop tables.

## Installation Instructions

1. **Create the target database** on the PostgreSQL server. For example, run `CREATE DATABASE climate_xxx;` or use **Create > Database** in pgAdmin. Assign the database user the required privileges.
2. **Enable PostGIS** in the target database. Run `CREATE EXTENSION postgis;` or use **Create > Extension** in pgAdmin and select `postgis`.
3. **Verify the PostGIS installation** by running the pre-installation checks under [Database administrator check](#database-administrator-check).
4. **Install the Python dependencies** from the bundle directory:

   ```powershell
   python -m venv .venv
   .\.venv\Scripts\Activate.ps1
   python -m pip install -r requirements.txt
   ```

5. **Prepare the input data** using the folder structure described under [Expected data structure](#expected-data-structure).
6. **Run the setup** from the bundle directory. The password is requested interactively if it is not supplied through the environment:

   ```powershell
   python run_setup.py --data-root C:\path\to\data-root `
     --host postgres.example.org `
     --port 5432 `
     --database climate `
     --user climate_admin
   ```

   To import one or more specific cities, add `--city` for each city. Without `--city`, setup imports all detected cities.

7. **Validate the installation**:

   ```powershell
   python validate_installation.py `
     --host postgres.example.org `
     --port 5432 `
     --database climate `
     --user climate_admin
   ```

Setup installs the schema migrations, including scalar support, before importing data. Do not run the legacy scripts in the repository’s `initFunctions` folder separately when using this delivery bundle.

## Built Image Registry

Not specified in the provided documentation.

## License

This project is licensed under the MIT License.

Copyright 2026 tadolphi tadolphi@vc.systems

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## External technical resources

- [FICLIMA](https://ficlima.org/) — climate data source.
- [PostgreSQL: `CREATE DATABASE`](https://www.postgresql.org/docs/current/sql-createdatabase.html)
- [PostgreSQL: `CREATE EXTENSION`](https://www.postgresql.org/docs/current/sql-createextension.html)

## User Guide References

No separate user guide or FAQ links were provided. Setup and usage instructions are included under [Additional Information](#additional-information).

## Additional Information

### Expected data structure

Every direct subfolder under `Observations` or `Projections` is treated as a city name, for example `Cluj-Napoca`, `Madrid`, or `Tallinn`.

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

City folder names must match exactly in both directory trees. The script does not apply aliases or rename cities; names are case-sensitive (`Tallin` and `Tallinn` are different names).

#### Input file formats

- Observatory files are tab-separated text files with six or seven columns: `station_id`, `longitude`, `latitude`, optional `height`, `name`, `region`, and `country_code`.
- Precipitation and scalar-variable files use one row per value in the format `YYYY MM DD value`.
- Temperature files use one row in the format `YYYY MM DD temp_min temp_max`.
- Files must be UTF-8 encoded and use the `.txt` extension.
- Projection model folders must follow the `NN_ModelName` pattern, for example `02_MPI-ESM1-2-HR`.
- The station ID at the end of each filename must match an ID from an observatory file. Observation files typically end in `_precipitation.txt` or `_temperature.txt`; projection files end in `_<station_id>.txt`.
- Empty or unparsable data lines are skipped and appear as warnings or reduced import counts.

### Database administrator check

Before running setup, a database administrator can use `psql` or pgAdmin to verify that PostGIS and the function required for the Voronoi calculation are available:

```sql
SELECT postgis_version();
SELECT ST_AsText(
    ST_VoronoiPolygons(
        ST_GeomFromText('MULTIPOINT((0 0),(1 0),(0 1))', 4326)
    )
);
```

If the second command fails, fix or update the PostGIS installation before running setup.

### Setup configuration and import behavior

The setup runner requests the password interactively. Alternatively, set `DB_PASSWORD`. The host, database, user, port, and SSL mode can also be provided through `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PORT`, and `DB_SSLMODE`. For a remote server requiring TLS, for example, set `DB_SSLMODE=require`.

To import selected cities, specify `--city` once per city:

```powershell
python run_setup.py --data-root C:\path\to\data-root --city Cluj-Napoca
```

Every selected city must exist in both directory trees. Without `--city`, setup stops if the city lists under `Observations` and `Projections` do not match exactly.

The process can be run again. Inserts use existing unique constraints and `ON CONFLICT`, so data is not duplicated. Existing observation or projection rows are not overwritten on a subsequent run. If source files are corrected, an administrator must deliberately remove the affected data before re-importing, or the import should be performed into a new database.

Import duration depends on data volume, internet connection, and the variables supplied. A Cluj-Napoca test run took 35 minutes and used 6.2 GB of database storage. The import requires sufficient network transfer capacity, database storage, and disk space. The `--workers` parameter controls the number of parallel import connections; reduce it if PostgreSQL has limited connection capacity.

### Validation

The validator checks the PostGIS version, main tables, and a query function. Setup also refreshes the annual materialized views and station Voronoi polygons.

```powershell
python validate_installation.py `
  --host postgres.example.org `
  --port 5432 `
  --database climate `
  --user climate_admin
```

### Shell wrappers

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

### Data model

Observations and projections are stored in the same tables. Flat observation files receive these reference values:

- Model: `ERA5`
- Scenario: `ERA5_Observed`
- `is_reference`: `true`

Projection model and scenario names are preserved from their folders. The known scalar variables `LWR`, `SWR`, `RHmax`, `RHmin`, and `WindSpeed` are imported into `climate.scalar_observations`.

### Using the database

The database can retrieve climate values for a location, compare observation and projection scenarios, and calculate event, ET0, and climatic water-balance indicators.

#### Location lookup

All spatial functions accept decimal WGS84 coordinates, with longitude first and latitude second:

```text
--lon 23.5667 --lat 46.7831
```

The coordinates identify the location to query; they do not need to match a station exactly. The function finds the station geometry with the smallest geographic distance and uses that station’s data. It does not interpolate between stations or combine values from multiple stations.

The response includes the selected station in `nearest_station`, including its `station_id`, city, coordinates, and `distance_m` from the requested point. Check `distance_m` and use coordinates within the city or station area being analyzed.

#### Values and periods

The base `get_climate` function returns temperature and precipitation values for the nearest station. Results are separated by imported `model_name` and `scenario_name`, so a response can contain reference observations and multiple climate projections.

| Request | Result |
| --- | --- |
| `--date 2045-07-14` | Values for one calendar day. |
| `--from 2045-01-01 --to 2045-12-31` | Values for an explicit date range. |
| `--year 2045` | Values for a complete calendar year. |
| `--year 2045 --month 7` | Values for one calendar month. |
| `--year-from 2045 --year-to 2060` | One row per year for a trend. |
| `--year-from 2045 --year-to 2060 --season summer` | One row per season year. |
| `--year-from 2045 --year-to 2060 --month 7 --day 14` | The same calendar day across years. |

Aggregates describe the requested period. For example, `total_precipitation_mm` is the precipitation sum for that period, while `avg_temp_max` is the average of the daily maximum temperatures. Daily functions return `obs_date` so individual days can be inspected.

#### Optional analyses

Add one or more `--include` values to request additional calculations:

- `events` returns heat, frost, precipitation, wind, humidity, radiation, and combined event statistics.
- `et0` calculates FAO-56 reference evapotranspiration using temperature, radiation, humidity, and wind data.
- `cwb` calculates precipitation minus ET0, together with soil moisture, actual evapotranspiration, water stress, and runoff indicators. CWB implies ET0 and requires the same scalar inputs.

Example request for all available analyses over a full year:

```powershell
python query_climate.py --env .env --lon 23.5667 --lat 46.7831 `
  --year 2045 --include events et0 cwb
```

The query client prints JSON to the console. Applications can import `query_climate.py` and call `query_climate()` directly, or call the PostgreSQL functions from SQL:

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

If source data is unavailable for the selected station, period, model, scenario, or required scalar variable, the relevant result array can be empty or a derived value can be `null`. A `null` ET0 or CWB value means the calculation could not be completed from available inputs; it does not mean zero climate impact.

#### Query example and `.env`

The following example uses a point in Cluj-Napoca. Replace the coordinates with a location in a city whose data has been imported.

```powershell
python query_climate.py --env .env --lon 23.5667 --lat 46.7831 `
  --year 2045 --include events et0 cwb
```

The setup process does **not** create a `.env` file. It reads connection values from environment variables or asks interactively for missing values. A `.env` file is only needed when using the included `query_climate.py` client.

Create a local `.env` file in the bundle directory by copying `.env.example` and replacing the placeholder values:

```powershell
Copy-Item .env.example .env
notepad .env
```

The query script reads `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and optionally `DB_PORT` from that file. Do not commit or share the resulting `.env`, because it contains database credentials. The setup runner can use the same values through environment variables, but does not require or create this file.

### Schema functions

The setup installs the following functions in the `climate` schema. Query functions return JSONB documents. Most are available with explicit date ranges and convenience overloads for a single date, calendar month, or calendar year.

#### Core climate queries

- `climate.get_climate(lon, lat, date_from, date_to)` returns aggregated temperature and precipitation for the nearest station across imported models and scenarios.
- `climate.get_climate(lon, lat, date)` returns the same climate data for one calendar day.
- `climate.get_climate(lon, lat, year, month)` returns data for one calendar month.
- `climate.get_climate(lon, lat, year)` returns data for one calendar year.
- `climate.get_climate_annual(lon, lat, year_from, year_to)` returns annual climate summaries for a multi-year trend.
- `climate.get_climate_seasonal(lon, lat, season, year_from, year_to)` returns seasonal climate summaries for spring, summer, autumn, or winter.
- `climate.get_climate_day_of_year(lon, lat, month, day, year_from, year_to)` compares the same calendar day across multiple years.

#### Event analysis

- `climate.get_climate_events(lon, lat, date_from, date_to)` calculates threshold events, degree-day totals, heatwave statistics, and dry-spell statistics for a date range. Date, month, and year overloads are also available.
- `climate.get_climate_events_annual(lon, lat, year_from, year_to)` returns event metrics for each year in a multi-year trend.
- `climate.get_climate_events_seasonal(lon, lat, season, year_from, year_to)` returns event metrics for each requested season and year.
- `climate.get_climate_events_day_of_year(lon, lat, month, day, year_from, year_to)` evaluates event metrics for one calendar day across multiple years.

#### Evapotranspiration and water balance

- `climate.calc_et0_pm(...)` is the FAO-56 Penman-Monteith helper for reference evapotranspiration (ET0).
- `climate.get_et0(lon, lat, date_from, date_to)` calculates daily ET0 and period summaries using temperature, radiation, humidity, and wind data. Date, month, and year overloads are also available.
- `climate.get_et0_annual(lon, lat, year_from, year_to)` returns annual ET0 summaries for a multi-year trend.
- `climate.get_et0_seasonal(lon, lat, season, year_from, year_to)` returns seasonal ET0 summaries for a multi-year trend.
- `climate.get_et0_day_of_year(lon, lat, month, day, year_from, year_to)` compares ET0 for one calendar day across multiple years.
- `climate.get_cwb(lon, lat, date_from, date_to [, awc_mm])` calculates climatic water balance and sequential soil-moisture state using precipitation and ET0. Date, month, and year overloads are also available.
- `climate.get_cwb_annual(lon, lat, year_from, year_to [, awc_mm])` returns annual climatic water-balance summaries and soil-moisture indicators.

#### Spatial support

`climate.refresh_station_voronoi()` rebuilds the Voronoi polygon for every station, grouped by city. Setup runs this after importing stations. Run it again whenever station locations are added or changed.

### Response attributes and meanings

All query functions return a JSONB document. The Python query client prints the same structure as JSON and merges requested extras such as `events`, `et0`, and `cwb` into the base climate response. Arrays contain separate entries for each model and scenario unless stated otherwise.

#### Common response attributes

| Attribute | Meaning |
| --- | --- |
| `nearest_station` | Metadata for the station nearest to the requested WGS84 coordinates. |
| `query` | Input coordinates and period, plus calculation settings where applicable. |
| `temperature` | Temperature observations or aggregates. |
| `precipitation` | Precipitation observations or aggregates. |
| `LWR`, `SWR`, `RHmax`, `RHmin`, `WindSpeed` | Scalar-variable observations or aggregates, when available. |

The `nearest_station` object contains `station_id`, `name`, `city`, `region`, `country_code`, `latitude`, `longitude`, `height_m`, `distance_m`, and `voronoi_cell`. Coordinates use WGS84; `distance_m` is the distance from the requested point in metres. `voronoi_cell` is a GeoJSON geometry and can be `null` if no Voronoi polygon exists.

Most array rows also contain:

| Attribute | Meaning |
| --- | --- |
| `model_name` | Climate model name, or `ERA5` for reference observations. |
| `scenario_name` | Projection scenario, or `ERA5_Observed` for reference observations. |
| `is_reference` | `true` for reference observations and `false` for projections. |
| `year` | Calendar year for annual and day-of-year trend results. |
| `season_year` | Year assigned to a seasonal result. December belongs to the following winter year. |
| `obs_date` | Observation date for daily results. |
| `days` or `day_count` | Number of source days represented by the row. |

Depending on the function, the `query` object can also contain `date_from`, `date_to`, `year_from`, `year_to`, `month`, `day`, `season`, `method`, `wind_height_assumed_m`, `awc_mm`, and an explanatory `note`.

#### Climate attributes

Temperature aggregate rows contain:

| Attribute | Meaning | Unit |
| --- | --- | --- |
| `avg_temp_min`, `avg_temp_max` | Average daily minimum and maximum temperature. | deg C |
| `min_temp_min` | Lowest recorded daily minimum temperature. | deg C |
| `max_temp_max` | Highest recorded daily maximum temperature. | deg C |

Precipitation aggregate rows contain:

| Attribute | Meaning | Unit |
| --- | --- | --- |
| `total_precipitation_mm` | Sum of precipitation over the period. | mm |
| `avg_daily_precipitation_mm` | Average precipitation per source day. | mm/day |
| `max_daily_precipitation_mm` | Maximum precipitation on one source day. | mm/day |

The top-level scalar key identifies the variable. Scalar aggregate rows contain `avg_value`, `min_value`, `max_value`, and `days`. Trend rows may also contain `variable` and `year` or `season_year`. Scalar units are `W/m2` for `LWR` and `SWR`, `%` for `RHmax` and `RHmin`, and `m/s` for `WindSpeed`. Day-of-year results instead expose the raw scalar as `value`.

#### Event attributes

Date-range event functions return `temperature_events`, `precipitation_events`, `wind_events`, `humidity_events`, `radiation_events`, and `combined_events`. Annual and seasonal event functions return the same metrics in an `events` array, with an additional `year` or `season_year`.

Temperature event rows contain:

| Attribute | Meaning |
| --- | --- |
| `heat_days` | Days with maximum temperature above 30 deg C. |
| `desert_days` | Days with maximum temperature above 35 deg C. |
| `tropical_nights` | Days with minimum temperature above 20 deg C. |
| `frost_days` | Days with minimum temperature below 0 deg C. |
| `ice_days` | Days with maximum temperature below 0 deg C. |
| `max_heatwave_days` | Longest consecutive run with maximum temperature above 30 deg C. |
| `hdd18`, `cdd22` | Heating and cooling degree-day totals using bases 18 and 22 deg C. |
| `gdd5`, `gdd10` | Growing degree-day totals using bases 5 and 10 deg C. |

Other event fields include:

- **Precipitation:** `total_precip_mm`, `max_daily_precip_mm`, `wet_days` (at least 1 mm), `dry_days` (below 1 mm), `heavy_rain_days` (at least 10 mm), `very_heavy_rain_days` (at least 20 mm), and `max_dry_spell_days`.
- **Wind:** `mean_wind_speed`, `max_wind_speed`, `calm_days` (below 1 m/s), `strong_wind_days` (above 10 m/s), and `storm_days` (above 17 m/s).
- **Humidity:** `mean_rh`, `mean_rh_max`, `mean_rh_min`, `high_humidity_days` (`RHmax` above 90%), and `low_humidity_days` (`RHmin` below 30%).
- **Radiation:** `mean_swr_w_m2`, `max_swr_w_m2`, `high_solar_days` (SWR above 200 W/m2), `low_solar_days` (SWR below 50 W/m2), `total_solar_kwh_m2`, `mean_lwr_w_m2`, `min_lwr_w_m2`, and `max_lwr_w_m2`.
- **Combined events:** `hot_and_dry_days` (maximum temperature above 30 deg C and `RHmin` below 30%), `stagnation_days` (mean temperature above 25 deg C and wind below 2 m/s), and `hot_humid_nights` (minimum temperature above 20 deg C and `RHmax` above 80%).

#### ET0 attributes

`get_et0` returns `et0_daily` and `et0_period_summary`. Annual, seasonal, and day-of-year ET0 functions return corresponding rows in `annual_et0`.

ET0 estimates how much water a healthy, well-watered reference grass surface would lose through evaporation and plant transpiration under the day’s weather conditions. It is an atmospheric water-demand indicator, not a direct measurement of water loss from a specific crop, soil, or city. The implementation uses FAO-56 Penman-Monteith and combines temperature, radiation, humidity, wind, and station altitude. ET0 is expressed as millimetres of water per day and is used as the potential evapotranspiration input for the climatic water-balance calculation. Actual evapotranspiration (`aet_mm`) can be lower when soil does not contain enough available water.

ET0 requires temperature, `SWR`, `LWR`, `WindSpeed`, `RHmax`, and `RHmin` for the same station, model, scenario, and date.

Daily ET0 rows contain:

| Attribute | Meaning | Unit |
| --- | --- | --- |
| `et0_mm` | FAO-56 Penman-Monteith reference evapotranspiration. | mm/day |
| `precip_mm` | Precipitation for the day. | mm |
| `water_deficit_mm` | ET0 exceeding precipitation. | mm |
| `water_surplus_mm` | Precipitation exceeding ET0. | mm |
| `rn_mj_m2_day` | Net radiation. | MJ/m2/day |
| `rns_mj_m2_day` | Net shortwave radiation. | MJ/m2/day |
| `rnl_mj_m2_day` | Net longwave radiation. | MJ/m2/day |
| `es_kpa`, `ea_kpa`, `vpd_kpa` | Saturation vapour pressure, actual vapour pressure, and vapour pressure deficit. | kPa |
| `delta_kpa_c`, `gamma_kpa_c` | Slope of the saturation vapour pressure curve and psychrometric constant. | kPa/deg C |
| `pressure_kpa` | Estimated atmospheric pressure from station altitude. | kPa |
| `lambda_mj_kg` | Latent heat of vaporisation. | MJ/kg |
| `u2_m_s` | Wind speed adjusted to 2 m. | m/s |
| `t_mean_c`, `t_max_c`, `t_min_c` | Mean, maximum, and minimum temperature used by the calculation. | deg C |
| `swr_w_m2`, `lwr_w_m2`, `wind_speed_m_s` | Raw radiation and wind inputs. | W/m2, W/m2, m/s |
| `rh_max_pct`, `rh_min_pct` | Raw relative-humidity inputs. | % |

ET0 period, annual, and seasonal rows contain `total_et0_mm`, `total_precip_mm`, `total_water_deficit_mm`, `total_water_surplus_mm`, `mean_daily_et0_mm`, and, where applicable, `max_daily_et0_mm`, `aridity_index`, `drought_category`, and `days_with_et0`. The aridity index is precipitation divided by ET0. Categories are `humid`, `dry_subhumid`, `semiarid`, `arid`, and `hyperarid`.

#### Climatic water-balance attributes

`get_cwb` returns `cwb_daily` and `cwb_period_summary`; `get_cwb_annual` returns `annual_cwb`. The soil-moisture simulation starts at the configured available water capacity (`awc_mm`, default `150 mm`) and carries the state forward through the requested period.

Daily CWB rows contain:

| Attribute | Meaning | Unit |
| --- | --- | --- |
| `et0_mm` | Reference evapotranspiration used by the water-balance step. | mm |
| `precip_mm` | Precipitation input. | mm |
| `cwb_mm` | Climatic water balance, calculated as precipitation minus ET0. | mm |
| `aet_mm` | Actual evapotranspiration limited by available water. | mm |
| `water_stress_index` | Moisture stress from 0 (no stress) to 1 (maximum stress). | index |
| `soil_moisture_mm` | Soil water remaining after the daily step. | mm |
| `soil_moisture_deficit_mm` | `awc_mm` minus soil moisture. | mm |
| `runoff_mm` | Water above the configured soil capacity; used as a recharge/runoff proxy. | mm |

Period and annual CWB rows contain `total_et0_mm`, `total_precip_mm`, `total_cwb_mm`, `total_aet_mm`, `total_recharge_proxy_mm`, `min_soil_moisture_mm`, `final_soil_moisture_mm` or `end_soil_moisture_mm`, `max_consecutive_deficit_days`, `aridity_index`, `drought_category`, `days_with_cwb`, and `awc_mm`.

Derived ET0 and CWB attributes are `null` when required scalar inputs are missing for that exact station, model, scenario, or date. A `null` value means the calculation was unavailable; it is not an initialized zero value.
