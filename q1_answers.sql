-- ICT371 Question 1: Pharmacy Stock and Daily Sales (PostgreSQL 14+)
-- Run in its own database. Scheduling needs the pg_cron extension.

-- (a) Tables
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name TEXT NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

-- Seed medicines
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 50),
    ('Amoxicillin 250mg', 8.00, 12),
    ('Cough Syrup 100ml', 15.00, 8);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
    END IF;
    RETURN v_price * p_quantity;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: record a sale
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;

    -- Lock the row so two sales cannot both use the same stock
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: % available, % requested', v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger: audit stock changes only (installed BEFORE sales are loaded)
CREATE OR REPLACE FUNCTION trg_stock_audit_fn() RETURNS trigger AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NULL;  -- AFTER trigger: return value is ignored
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_stock_audit_fn();

-- Load sales through the procedure
CALL pr_record_sale(1, 5,  '2026-11-01');
CALL pr_record_sale(1, 3,  '2026-11-01');
CALL pr_record_sale(2, 4,  '2026-11-01');
CALL pr_record_sale(2, 3,  '2026-11-02');
CALL pr_record_sale(3, 2,  '2026-11-02');
CALL pr_record_sale(1, 10, '2026-11-03');

-- (e) View
CREATE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

-- (f) Index: equality on medicine_id first, then the sold_on range
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

-- Show the plan. Seq scan is cheaper on six rows, so disable it for the demo.
SET enable_seqscan = off;
EXPLAIN SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN '2026-11-01' AND '2026-11-03';
SET enable_seqscan = on;

-- (g) Scheduled job: rebuild one day's totals (idempotent)
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Runs at 00:15 every day for the previous day (only if pg_cron is installed)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q1-refresh-sales', '15 0 * * *',
                              $job$CALL pr_refresh_sales((CURRENT_DATE - 1))$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
