DROP TRIGGER IF EXISTS trigger_important_waterway_linestring ON osm_important_waterway_linestring;
DROP TRIGGER IF EXISTS trigger_store ON osm_waterway_linestring;
DROP TRIGGER IF EXISTS trigger_flag ON osm_waterway_linestring;
DROP TRIGGER IF EXISTS trigger_refresh ON waterway_important.updates;

-- We merge the waterways by name like the highways
-- This helps to drop not important rivers (since they do not have a name)
-- and also makes it possible to filter out too short rivers

CREATE INDEX IF NOT EXISTS osm_waterway_linestring_waterway_partial_idx
    ON osm_waterway_linestring ((true))
    WHERE name <> ''
      AND waterway = 'river'
      AND ST_IsValid(geometry);

CREATE TABLE IF NOT EXISTS osm_important_waterway_linestring (
    id SERIAL PRIMARY KEY,
    geometry geometry,
    name varchar,
    name_en varchar,
    name_zh varchar,
    tags hstore
);

-- etldoc: osm_waterway_linestring ->  osm_important_waterway_linestring
INSERT INTO osm_important_waterway_linestring (geometry, name, name_en, name_zh, tags)
SELECT (ST_Dump(geometry)).geom AS geometry,
       name,
       name_en,
       name_zh,
       tags
FROM (
         SELECT ST_LineMerge(ST_Union(geometry)) AS geometry,
                name,
                name_en,
                name_zh,
                slice_language_tags(tags) AS tags
         FROM osm_waterway_linestring
         WHERE name <> ''
           AND waterway = 'river'
           AND ST_IsValid(geometry)
         GROUP BY name, name_en, name_zh, slice_language_tags(tags)
     ) AS waterway_union;
CREATE INDEX IF NOT EXISTS osm_important_waterway_linestring_geometry_idx ON osm_important_waterway_linestring USING gist (geometry);

CREATE TABLE IF NOT EXISTS osm_important_waterway_linestring_gen_z11
(LIKE osm_important_waterway_linestring);

CREATE TABLE IF NOT EXISTS osm_important_waterway_linestring_gen_z10
(LIKE osm_important_waterway_linestring_gen_z11);

CREATE TABLE IF NOT EXISTS osm_important_waterway_linestring_gen_z9
(LIKE osm_important_waterway_linestring_gen_z10);

CREATE OR REPLACE FUNCTION insert_important_waterway_linestring_gen(update_id bigint) RETURNS void AS
$$
BEGIN
    -- etldoc: osm_important_waterway_linestring -> osm_important_waterway_linestring_gen_z11
    INSERT INTO osm_important_waterway_linestring_gen_z11 (geometry, id, name, name_en, name_zh, tags)
    SELECT ST_Simplify(geometry, ZRes(12)) AS geometry,
        id,
        name,
        name_en,
        name_zh,
        tags
    FROM osm_important_waterway_linestring
    WHERE
        (update_id IS NULL OR id = update_id) AND
        ST_Length(geometry) > 1000;

    -- etldoc: osm_important_waterway_linestring_gen_z11 -> osm_important_waterway_linestring_gen_z10
    INSERT INTO osm_important_waterway_linestring_gen_z10 (geometry, id, name, name_en, name_zh, tags)
    SELECT ST_Simplify(geometry, ZRes(11)) AS geometry,
        id,
        name,
        name_en,
        name_zh,
        tags
    FROM osm_important_waterway_linestring_gen_z11
    WHERE
        (update_id IS NULL OR id = update_id) AND
        ST_Length(geometry) > 4000;

    -- etldoc: osm_important_waterway_linestring_gen_z10 -> osm_important_waterway_linestring_gen_z9
    INSERT INTO osm_important_waterway_linestring_gen_z9 (geometry, id, name, name_en, name_zh, tags)
    SELECT ST_Simplify(geometry, ZRes(10)) AS geometry,
        id,
        name,
        name_en,
        name_zh,
        tags
    FROM osm_important_waterway_linestring_gen_z10
    WHERE
        (update_id IS NULL OR id = update_id) AND
        ST_Length(geometry) > 8000;
END;
$$ LANGUAGE plpgsql;

TRUNCATE osm_important_waterway_linestring_gen_z11;
TRUNCATE osm_important_waterway_linestring_gen_z10;
TRUNCATE osm_important_waterway_linestring_gen_z9;
SELECT insert_important_waterway_linestring_gen(NULL);

CREATE INDEX IF NOT EXISTS osm_important_waterway_linestring_gen_z11_geometry_idx
    ON osm_important_waterway_linestring_gen_z11 USING gist (geometry);
CREATE INDEX IF NOT EXISTS osm_important_waterway_linestring_gen_z10_geometry_idx
    ON osm_important_waterway_linestring_gen_z10 USING gist (geometry);
CREATE INDEX IF NOT EXISTS osm_important_waterway_linestring_gen_z9_geometry_idx
    ON osm_important_waterway_linestring_gen_z9 USING gist (geometry);


-- Handle updates

CREATE SCHEMA IF NOT EXISTS waterway_important;

CREATE TABLE IF NOT EXISTS waterway_important.changes
(
    id serial PRIMARY KEY,
    osm_id bigint,
    is_old boolean,
    name character varying,
    name_en character varying,
    name_zh character varying,
    tags hstore
);
CREATE OR REPLACE FUNCTION waterway_important.store() RETURNS trigger AS
$$
BEGIN
    IF (tg_op IN ('DELETE', 'UPDATE')) AND OLD.name <> '' AND OLD.waterway = 'river' THEN
        INSERT INTO waterway_important.changes(is_old, name, name_en, name_zh, tags)
        VALUES (TRUE, OLD.name, OLD.name_en, OLD.name_zh, slice_language_tags(OLD.tags));
    END IF;
    IF (tg_op IN ('UPDATE', 'INSERT')) AND NEW.name <> '' AND NEW.waterway = 'river' THEN
        INSERT INTO waterway_important.changes(is_old, name, name_en, name_zh, tags)
        VALUES (FALSE, NEW.name, NEW.name_en, NEW.name_zh, slice_language_tags(NEW.tags));
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS waterway_important.updates
(
    id serial PRIMARY KEY,
    t text,
    UNIQUE (t)
);
CREATE OR REPLACE FUNCTION waterway_important.flag() RETURNS trigger AS
$$
BEGIN
    INSERT INTO waterway_important.updates(t) VALUES ('y') ON CONFLICT(t) DO NOTHING;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION waterway_important.refresh() RETURNS trigger AS
$$
DECLARE
    t TIMESTAMP WITH TIME ZONE := clock_timestamp();
BEGIN
    RAISE LOG 'Refresh waterway';

    -- REFRESH osm_important_waterway_linestring

    -- Compact the change history to keep only the first and last version, and then uniq version of row
    CREATE TEMP TABLE changes_compact AS
    SELECT DISTINCT ON (name, name_en, name_zh, tags)
        name,
        name_en,
        name_zh,
        tags
    FROM ((
              SELECT DISTINCT ON (osm_id) *
              FROM waterway_important.changes
              WHERE is_old
              ORDER BY osm_id,
                       id ASC
          )
          UNION ALL
          (
              SELECT DISTINCT ON (osm_id) *
              FROM waterway_important.changes
              WHERE NOT is_old
              ORDER BY osm_id,
                       id DESC
          )) AS t;

    DELETE
    FROM osm_important_waterway_linestring AS w
        USING changes_compact AS c
    WHERE w.name = c.name
      AND w.name_en IS NOT DISTINCT FROM c.name_en
      AND w.name_zh IS NOT DISTINCT FROM c.name_zh
      AND w.tags IS NOT DISTINCT FROM c.tags;

    INSERT INTO osm_important_waterway_linestring (geometry, name, name_en, name_zh, tags)
    SELECT (ST_Dump(geometry)).geom AS geometry,
           name,
           name_en,
           name_zh,
           tags
    FROM (
             SELECT ST_LineMerge(ST_Union(geometry)) AS geometry,
                    w.name,
                    w.name_en,
                    w.name_zh,
                    slice_language_tags(w.tags) AS tags
             FROM osm_waterway_linestring AS w
                      JOIN changes_compact AS c ON
                     w.name = c.name AND w.name_en IS NOT DISTINCT FROM c.name_en AND
                     w.name_zh IS NOT DISTINCT FROM c.name_zh AND
                     slice_language_tags(w.tags) IS NOT DISTINCT FROM c.tags
             WHERE w.name <> ''
               AND w.waterway = 'river'
               AND ST_IsValid(geometry)
             GROUP BY w.name, w.name_en, w.name_zh, slice_language_tags(w.tags)
         ) AS waterway_union;

    DROP TABLE changes_compact;
    -- noinspection SqlWithoutWhere
    DELETE FROM waterway_important.changes;
    -- noinspection SqlWithoutWhere
    DELETE FROM waterway_important.updates;

    RAISE LOG 'Refresh waterway done in %', age(clock_timestamp(), t);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION waterway_important.important_waterway_linestring_gen_refresh() RETURNS trigger AS
$$
BEGIN
    IF (tg_op = 'DELETE' OR tg_op = 'UPDATE') THEN
        DELETE FROM osm_important_waterway_linestring_gen_z11 WHERE id = old.id;
        DELETE FROM osm_important_waterway_linestring_gen_z10 WHERE id = old.id;
        DELETE FROM osm_important_waterway_linestring_gen_z9 WHERE id = old.id;
    END IF;

    IF (tg_op = 'UPDATE' OR tg_op = 'INSERT') THEN
        PERFORM insert_important_waterway_linestring_gen(new.id);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_important_waterway_linestring
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_important_waterway_linestring
    FOR EACH ROW
EXECUTE PROCEDURE waterway_important.important_waterway_linestring_gen_refresh();

CREATE TRIGGER trigger_store
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_waterway_linestring
    FOR EACH ROW
EXECUTE PROCEDURE waterway_important.store();

CREATE TRIGGER trigger_flag
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_waterway_linestring
    FOR EACH STATEMENT
EXECUTE PROCEDURE waterway_important.flag();

CREATE CONSTRAINT TRIGGER trigger_refresh
    AFTER INSERT
    ON waterway_important.updates
    INITIALLY DEFERRED
    FOR EACH ROW
EXECUTE PROCEDURE waterway_important.refresh();
