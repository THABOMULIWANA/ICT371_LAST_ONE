-- ICT371 Question 10: Scholarship Application Assessment (PostgreSQL 14+)
-- Rules (fictional): age 18-25 inclusive, monthly income at most K3,000, average mark at least 70.

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number TEXT NOT NULL UNIQUE,
    full_name      TEXT NOT NULL
);

CREATE TABLE applications (
    application_id      SERIAL PRIMARY KEY,
    student_id          INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application  INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE NOT NULL,
    status              TEXT NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     TEXT NOT NULL,
    new_status     TEXT NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- Seed students
INSERT INTO students (student_number, full_name) VALUES
    ('SCH-001', 'Lweendo Mwape'),
    ('SCH-002', 'Natasha Zulu'),
    ('SCH-003', 'Oscar Mulenga');

-- Seed six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 18, 3000.00, 70.00, '2026-11-01'),   -- 1 qualifies: all three boundaries met exactly
    (1, 25, 2500.00, 85.00, '2026-11-02'),   -- 2 qualifies: maximum age
    (2, 17, 1000.00, 90.00, '2026-11-03'),   -- 3 fails: too young
    (2, 22, 3001.00, 80.00, '2026-11-04'),   -- 4 fails: income just over
    (3, 20, 1500.00, 69.99, '2026-11-05'),   -- 5 fails: mark just under
    (3, 26,  500.00, 95.00, '2026-11-06');   -- 6 fails: too old

-- (d) Trigger: audits real status changes only
CREATE FUNCTION trg_decision_audit_fn() RETURNS trigger AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit_fn();

-- (b) Function: eligibility, all three rules
CREATE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL';
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: assess one application
CREATE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_age    INTEGER;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
    v_status TEXT;
    v_ok     BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications WHERE application_id = p_application_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (%)', p_application_id, v_status;
    END IF;

    v_ok := fn_scholarship_eligible(v_age, v_income, v_mark);
    UPDATE applications
    SET status = CASE WHEN v_ok THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (g) Procedure: assess every PENDING application with a query FOR loop
CREATE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

-- (e) View: approved applicants only, no household income
CREATE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index: applications by status within a submission date range
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

SET enable_seqscan = off;   -- demo only
EXPLAIN SELECT application_id, submitted_on FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
SET enable_seqscan = on;

-- (g) Scheduled job: Monday at 08:00
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q10-assess-pending', '0 8 * * 1',
                              $job$CALL pr_assess_pending()$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
