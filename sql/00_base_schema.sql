CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS climate;
SET search_path TO climate, public;

CREATE TABLE IF NOT EXISTS climate.cities (
    id   SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS climate.stations (
    station_id   TEXT PRIMARY KEY,
    city_id      INTEGER REFERENCES climate.cities(id),
    longitude    DOUBLE PRECISION NOT NULL,
    latitude     DOUBLE PRECISION NOT NULL,
    height       DOUBLE PRECISION,
    name         TEXT,
    region       TEXT,
    country_code TEXT,
    geom         geometry(Point, 4326)
);

CREATE INDEX IF NOT EXISTS idx_stations_geom
    ON climate.stations USING GIST(geom);

CREATE TABLE IF NOT EXISTS climate.climate_models (
    id            SERIAL PRIMARY KEY,
    model_name    TEXT UNIQUE NOT NULL,
    folder_prefix VARCHAR(5)
);

CREATE TABLE IF NOT EXISTS climate.scenarios (
    id            SERIAL PRIMARY KEY,
    scenario_name TEXT UNIQUE NOT NULL,
    is_reference  BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS climate.precipitation_observations (
    id            BIGSERIAL PRIMARY KEY,
    station_id    TEXT REFERENCES climate.stations(station_id),
    model_id      INTEGER REFERENCES climate.climate_models(id),
    scenario_id   INTEGER REFERENCES climate.scenarios(id),
    obs_date      DATE NOT NULL,
    precipitation DOUBLE PRECISION,
    UNIQUE (station_id, model_id, scenario_id, obs_date)
);

CREATE INDEX IF NOT EXISTS idx_precip_lookup
    ON climate.precipitation_observations(station_id, model_id, scenario_id);

CREATE TABLE IF NOT EXISTS climate.temperature_observations (
    id          BIGSERIAL PRIMARY KEY,
    station_id  TEXT REFERENCES climate.stations(station_id),
    model_id    INTEGER REFERENCES climate.climate_models(id),
    scenario_id INTEGER REFERENCES climate.scenarios(id),
    obs_date    DATE NOT NULL,
    temp_min    DOUBLE PRECISION,
    temp_max    DOUBLE PRECISION,
    UNIQUE (station_id, model_id, scenario_id, obs_date)
);

CREATE INDEX IF NOT EXISTS idx_temp_lookup
    ON climate.temperature_observations(station_id, model_id, scenario_id);

CREATE TABLE IF NOT EXISTS climate.scalar_observations (
    id          BIGSERIAL PRIMARY KEY,
    station_id  TEXT REFERENCES climate.stations(station_id),
    model_id    INTEGER REFERENCES climate.climate_models(id),
    scenario_id INTEGER REFERENCES climate.scenarios(id),
    variable    TEXT NOT NULL,
    obs_date    DATE NOT NULL,
    value       DOUBLE PRECISION,
    UNIQUE (station_id, model_id, scenario_id, variable, obs_date)
);

CREATE INDEX IF NOT EXISTS idx_scalar_lookup
    ON climate.scalar_observations(station_id, model_id, scenario_id, variable);

CREATE TABLE IF NOT EXISTS climate.station_voronoi (
    station_id TEXT PRIMARY KEY REFERENCES climate.stations(station_id) ON DELETE CASCADE,
    city_id    INTEGER REFERENCES climate.cities(id),
    geom       geometry(Polygon, 4326) NOT NULL
);