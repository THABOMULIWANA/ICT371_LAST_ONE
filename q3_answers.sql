-- ICT371 Question 3: Library Returns and Overdue Fines (PostgreSQL 14+)
-- Fine rule (hypothetical): K2 per day after due_on. Return on due date = no fine.

-- (a) Tables
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   TEXT NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name TEXT NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CHECK (due_on >= borrowed_on),
    CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

-- Seed books
INSERT INTO books (title) VALUES
    ('Database Systems'),
    ('Data Structures'),
    ('Operating Systems');

-- (d) Trigger: installed before returns are processed
CREATE FUNCTION trg_loan_audit_fn() RETURNS trigger AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit_fn();

-- (b) Function
CREATE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE) RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
    v_days     INTEGER;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_returned FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan %', p_loan_id;
    END IF;

    -- Use the earlier of p_as_of and the return date when a return exists
    v_end  := CASE WHEN v_returned IS NULL THEN p_as_of ELSE LEAST(p_as_of, v_returned) END;
    v_days := GREATEST(v_end - v_due, 0);
    RETURN 2 * v_days;
END;
$$ LANGUAGE plpgsql;

-- Seed loans. Open loans are inserted directly; returns go through the procedure.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice',   '2026-10-01', '2026-10-15'),  -- L1 open and overdue
    (2, 'Brian',   '2026-11-20', '2026-12-05'),  -- L2 open, not yet due
    (3, 'Chanda',  '2026-10-01', '2026-10-10'),  -- L3 returned late
    (1, 'Dumisani','2026-10-25', '2026-11-08'),  -- L4 returned early
    (3, 'Esther',  '2026-10-28', '2026-11-05'),  -- L5 open and overdue
    (2, 'Felix',   '2026-11-01', '2026-11-05');  -- L6 returned on the due date

-- (c) Procedure: return a loan and store the final fine with the date
CREATE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);
    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

CALL pr_return_loan(3, '2026-10-14');   -- 4 days late: fine 8.00
CALL pr_return_loan(4, '2026-11-06');   -- early: fine 0.00
CALL pr_return_loan(6, '2026-11-05');   -- due date: fine 0.00

-- (e) View: unreturned loans that are past due today
CREATE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- (f) Index: a partial index on open loans, searched by book
CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;

SET enable_seqscan = off;   -- demo only
EXPLAIN SELECT loan_id, borrower_name, due_on FROM loans
WHERE book_id = 1 AND returned_on IS NULL;
SET enable_seqscan = on;

-- (g) Scheduled job: count loans unreturned on p_as_of and sum their fines
CREATE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q3-refresh-overdue', '10 0 * * *',
                              $job$CALL pr_refresh_overdue(CURRENT_DATE)$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
