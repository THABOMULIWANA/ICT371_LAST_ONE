-- ICT371 Question 6: Monthly Payroll Processing (PostgreSQL 14+)

-- (a) Tables
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    TEXT NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),  -- first date of the month
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- Seed employees (E3 becomes inactive later)
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Alice Mwansa', 5000.00, 500.00, 300.00, TRUE),
    ('Brian Soko',   4000.00,   0.00, 200.00, TRUE),
    ('Chanda Lungu', 3500.00, 300.00, 150.00, TRUE);

-- (d) Trigger: logs real basic_salary changes only
CREATE FUNCTION trg_salary_audit_fn() RETURNS trigger AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit_fn();

-- (b) Function: net pay = basic + allowance - deduction
CREATE FUNCTION fn_net_pay(p_employee_id INTEGER) RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_basic     NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net       NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allowance, v_deduction
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee %', p_employee_id;
    END IF;

    v_net := v_basic + v_allowance - v_deduction;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay % for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: process one month for every active employee
CREATE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    rec   RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Pay month must be the first date of a month, got %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        -- An invalid calculation raises here and rolls back the whole call
        v_net := fn_net_pay(rec.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.basic_salary + rec.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END;
$$;

-- Seed: October with all three employees, then November after Chanda becomes inactive
CALL pr_process_payroll('2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 3;
CALL pr_process_payroll('2026-11-01');

-- (e) View: includes history for employees who are no longer active
CREATE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index: the unique index leads with employee_id, so a pay_month filter needs its own index
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

SET enable_seqscan = off;   -- demo only
EXPLAIN SELECT * FROM payroll WHERE pay_month = '2026-11-01';
SET enable_seqscan = on;

-- (g) Scheduled job: run on the 1st of each month at 02:00 for the previous month
-- Inspect with:  SELECT * FROM cron.job;
--                SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q6-payroll', '0 2 1 * *',
            $job$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
