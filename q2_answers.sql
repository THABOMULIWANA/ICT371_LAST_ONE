-- ICT371 Question 2: University Fee Payments (PostgreSQL 14+)

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number TEXT NOT NULL UNIQUE,
    full_name      TEXT NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

-- Seed students (Dave's three cases: part paid, unpaid, will be settled)
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('ST001', 'Alice Banda',   1000.00),
    ('ST002', 'Brian Phiri',    500.00),   -- no payments at first
    ('ST003', 'Chanda Mwape',   800.00);

-- (d) Trigger: installed BEFORE payments are loaded so every payment is audited
CREATE FUNCTION trg_payment_audit_fn() RETURNS trigger AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payment_audit_fn();

-- (b) Function
CREATE FUNCTION fn_fee_balance(p_student_id INTEGER) RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student %', p_student_id;
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
    RETURN v_fee - v_paid;   -- equals full fee when there are no payments
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: receive a payment
CREATE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive, got %', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;

    -- Lock the student so two payments cannot both fit the same balance
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;

    -- Only the payment row is written; students.fee_due is untouched
    INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- Seed payments through the procedure (six in total; ST002 has none)
CALL pr_receive_payment(1, 300, '2026-10-01');
CALL pr_receive_payment(1, 200, '2026-10-15');
CALL pr_receive_payment(1, 100, '2026-11-01');
CALL pr_receive_payment(3, 300, '2026-10-02');
CALL pr_receive_payment(3, 300, '2026-10-20');
CALL pr_receive_payment(3, 200, '2026-11-05');

-- (e) View: only students who still owe fees
CREATE VIEW v_fee_balances AS
SELECT student_number, full_name, outstanding_balance
FROM (
    SELECT s.student_number, s.full_name, fn_fee_balance(s.student_id) AS outstanding_balance
    FROM students s
) t
WHERE outstanding_balance > 0;

-- (f) Index: equality on student_id first, then the paid_on range
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

SET enable_seqscan = off;   -- demo only: six rows would otherwise use a seq scan
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN '2026-10-01' AND '2026-11-30';
SET enable_seqscan = on;

-- (g) Scheduled job: store one day's count and total; rerun replaces the row
CREATE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;
END;
$$;

-- Daily at 01:00 for the previous day (only if pg_cron is installed)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q2-refresh-collections', '0 1 * * *',
                              $job$CALL pr_refresh_collections((CURRENT_DATE - 1))$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
