-- ICT371 Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL 14+)
-- Rates (hypothetical): grade A K5/kg, grade B K4/kg, grade C K3/kg.

-- (a) Tables
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number TEXT NOT NULL UNIQUE,
    full_name     TEXT NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        TEXT NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(12,3) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,
    total_value  NUMERIC(12,2) NOT NULL,
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,3) NOT NULL,
    total_value   NUMERIC(12,2) NOT NULL
);

-- Seed farmers (F-004 has no deliveries)
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F-001', 'Sipho Nkandu'),
    ('F-002', 'Mary Chilufya'),
    ('F-003', 'Joseph Banda'),
    ('F-004', 'Esther Mumba');

-- (b) Function: rate for a grade
CREATE FUNCTION fn_maize_rate(p_grade TEXT) RETURNS NUMERIC(10,2) AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    ELSIF p_grade = 'A' THEN RETURN 5.00;
    ELSIF p_grade = 'B' THEN RETURN 4.00;
    ELSIF p_grade = 'C' THEN RETURN 3.00;
    ELSE
        RAISE EXCEPTION 'Unsupported grade %', p_grade;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger: pricing rule for every insert and update, including direct SQL
CREATE FUNCTION trg_delivery_price_fn() RETURNS trigger AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := NEW.weight_kg * NEW.unit_rate;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_delivery_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_delivery_price_fn();

-- (c) Procedure: receive a delivery; the trigger sets the rate and value
CREATE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade TEXT,
                                     p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    PERFORM fn_maize_rate(p_grade);   -- rejects NULL or unsupported grades

    -- unit_rate and total_value are placeholders; the trigger overwrites them
    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, 0, 0, p_date, FALSE);
END;
$$;

-- Load deliveries after the trigger is installed
CALL pr_receive_delivery(1, 'A', 100, '2026-11-01');
CALL pr_receive_delivery(1, 'B', 200, '2026-11-01');
CALL pr_receive_delivery(2, 'C', 300, '2026-11-02');
CALL pr_receive_delivery(2, 'A',  50, '2026-11-02');
CALL pr_receive_delivery(3, 'B', 120, '2026-11-03');
CALL pr_receive_delivery(3, 'C',  80, '2026-11-03');

-- Mark two deliveries as paid so both payment states exist
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3);

-- (e) View: unpaid value per farmer, including farmers with none
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index: a farmer's deliveries between two dates
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

SET enable_seqscan = off;   -- demo only
EXPLAIN SELECT delivery_id, delivered_on, total_value FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN '2026-11-01' AND '2026-11-30';
SET enable_seqscan = on;

-- (g) Scheduled job: replace that day's totals on every run
CREATE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q9-purchases', '30 1 * * *',
                              $job$CALL pr_refresh_purchases((CURRENT_DATE - 1))$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
