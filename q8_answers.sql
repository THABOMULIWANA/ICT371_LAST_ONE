-- ICT371 Question 8: Transport Fleet Maintenance (PostgreSQL 14+)
-- Service rule: a vehicle is due when km since last service is at least 5,000.

-- (a) Tables
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          TEXT NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         SERIAL PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on         DATE NOT NULL,
    start_odometer  INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer    INTEGER NOT NULL CHECK (end_odometer >= 0),
    CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id        INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service  INTEGER NOT NULL,
    flagged_on        DATE NOT NULL
);

-- Seed three vehicles at different service positions (trips are added below)
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('KAA 1001',  8000,  8000),   -- trips will take it to 9,200: 1,200 km since service (not due)
    ('KAB 1002', 12000, 12000),   -- trips will take it to 17,500: 5,500 km since service (due)
    ('KAC 1003',  2000,  2000);   -- trips will take it to 7,000: exactly 5,000 km (due)

-- (d) Trigger: checks the start, rejects bad mileage, and moves the odometer exactly once
CREATE FUNCTION trg_trip_odometer_fn() RETURNS trigger AS $$
DECLARE
    v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match current odometer %',
            NEW.start_odometer, v_current;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'End odometer % must exceed start odometer %',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_trip_odometer_fn();

-- (c) Procedure: record a trip (the trigger does the odometer work)
CREATE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date is required';
    END IF;
    IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer must be greater than start odometer';
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- Seed six trips through the procedure, after the trigger is installed
CALL pr_record_trip(1, '2026-10-01', 8000, 8500);
CALL pr_record_trip(1, '2026-10-10', 8500, 9200);
CALL pr_record_trip(2, '2026-10-01', 12000, 15000);
CALL pr_record_trip(2, '2026-10-20', 15000, 17500);
CALL pr_record_trip(3, '2026-10-01', 2000, 4000);
CALL pr_record_trip(3, '2026-10-15', 4000, 7000);

-- (b) Function: service due for one vehicle
CREATE FUNCTION fn_service_due(p_vehicle_id INTEGER) RETURNS BOOLEAN AS $$
DECLARE
    v_current INTEGER;
    v_last    INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
    END IF;
    RETURN (v_current - v_last) >= 5000;
END;
$$ LANGUAGE plpgsql;

-- (e) View: vehicles that currently meet the threshold
CREATE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- (f) Index: one vehicle's trips within a date range
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

SET enable_seqscan = off;   -- demo only
EXPLAIN SELECT trip_id, trip_on, start_odometer, end_odometer FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN '2026-10-01' AND '2026-10-31';
SET enable_seqscan = on;

-- (g) Scheduled job: keep service_alerts in step with the rule
CREATE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- remove alerts for vehicles no longer due
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );

    -- insert or update one alert per due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT v.vehicle_id, v.current_odometer - v.last_service_odometer, CURRENT_DATE
    FROM vehicles v
    WHERE v.current_odometer - v.last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;   -- keep the original flagged_on
END;
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q8-service-alerts', '0 6 * * 1',
                              $job$CALL pr_refresh_service_alerts()$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
