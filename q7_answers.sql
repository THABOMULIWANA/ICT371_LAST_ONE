-- ICT371 Question 7: Water Meter Readings and Billing (PostgreSQL 14+)
-- Tariff (hypothetical): first 10 units at K5 each, units above 10 at K8 each.

-- (a) Tables
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   TEXT NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on      DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12,2) NOT NULL
);

-- Seed customers
INSERT INTO customers (full_name) VALUES ('Esther Mulenga'), ('Felix Tembo'), ('Grace Banda');

-- (d) Trigger: rejects a reading that goes backwards, including direct SQL
CREATE FUNCTION trg_reading_check_fn() RETURNS trigger AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading % is below previous reading %',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_reading_check_fn();

-- Seed readings (covering zero, exactly 10 and above 10 units)
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100, 100),   -- 0 units
    (1, '2026-10-01', 100, 110),   -- exactly 10 units
    (2, '2026-10-01', 200, 215),   -- 15 units
    (3, '2026-10-01',  50,  60),   -- exactly 10 units
    (2, '2026-11-01', 215, 230),   -- 15 units
    (3, '2026-11-01',  60,  75);   -- 15 units

-- (b) Function: two-band tariff
CREATE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC(12,2) AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Units are required';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Units cannot be negative, got %', p_units;
    END IF;
    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: create one bill per reading
CREATE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev  NUMERIC(12,2);
    v_curr  NUMERIC(12,2);
    v_units NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- Generate bills (September readings due 15 Oct, October due 15 Nov, November due 15 Dec)
CALL pr_generate_bill(1, '2026-10-15');
CALL pr_generate_bill(2, '2026-11-15');
CALL pr_generate_bill(3, '2026-11-15');
CALL pr_generate_bill(4, '2026-11-15');
CALL pr_generate_bill(5, '2026-12-15');
CALL pr_generate_bill(6, '2026-12-15');

-- Record some payments: bill 2 settled, bill 3 part paid, bills 1, 4, 5, 6 unpaid or zero
UPDATE bills SET amount_paid = 50 WHERE bill_id = 2;
UPDATE bills SET amount_paid = 40 WHERE bill_id = 3;

-- (e) View: overdue bills that are not fully paid
CREATE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id   = b.reading_id
JOIN customers c ON c.customer_id  = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- (f) Index: partial index on unpaid bills, searched by due date
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;

SET enable_seqscan = off;   -- demo only
EXPLAIN SELECT bill_id, due_on FROM bills
WHERE amount_paid < charge AND due_on < DATE '2026-11-25';
SET enable_seqscan = on;

-- (g) Scheduled job: total unpaid balance for today
CREATE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;
END;
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q7-receivables', '30 0 * * *',
                              $job$CALL pr_refresh_receivables()$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
