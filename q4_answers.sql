-- ICT371 Question 4: Clinic Appointment Scheduling (PostgreSQL 14+)

-- (a) Tables
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  TEXT NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name TEXT NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
    status          TEXT NOT NULL CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

-- Database-level backstop for the slot rule: one non-cancelled booking per doctor/day/slot
CREATE UNIQUE INDEX uq_doctor_slot_active
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

-- Seed patients and doctors
INSERT INTO patients (full_name) VALUES ('Mary Zulu'), ('Peter Tembo'), ('Grace Lungu');
INSERT INTO doctors  (full_name) VALUES ('Dr. Mulenga'), ('Dr. Kabwe'), ('Dr. Chikwanda');

-- (d) Trigger: rejects a clash with another non-cancelled appointment
CREATE FUNCTION trg_appt_clash_fn() RETURNS trigger AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments a
        WHERE a.doctor_id       = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time       = NEW.slot_time
          AND a.status         <> 'CANCELLED'
          AND a.appointment_id IS DISTINCT FROM NEW.appointment_id  -- exclude the row being updated
    ) THEN
        RAISE EXCEPTION 'Doctor % already has a booking at % on %',
            NEW.doctor_id, NEW.slot_time, NEW.appointment_day;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appt_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_appt_clash_fn();

-- (b) Function: the doctor's non-cancelled load on a day
CREATE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE) RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor %', p_doctor_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM appointments
    WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
    RETURN v_count;   -- 0 when the day has no bookings
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: book a slot
CREATE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER,
                                     p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient %', p_patient_id; END IF;
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot %', p_slot;
    END IF;

    -- The trigger rejects a clash; the unique index is a second guard
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Seed six appointments through the procedure (all dates are in the future)
CALL pr_book_appointment(1, 1, '2026-12-01', '09:00');
CALL pr_book_appointment(2, 1, '2026-12-01', '10:00');
CALL pr_book_appointment(3, 2, '2026-12-01', '09:00');
CALL pr_book_appointment(1, 3, '2026-12-02', '11:00');
CALL pr_book_appointment(2, 2, '2026-12-02', '12:00');
CALL pr_book_appointment(3, 1, '2026-12-02', '09:00');

-- Give the seed a realistic spread of statuses
UPDATE appointments SET status = 'ATTENDED'  WHERE appointment_id = 1;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 2;

-- (e) View: today's BOOKED appointments, names only
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- (f) Index: non-unique, for searches by day then doctor
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

SET enable_seqscan = off;   -- demo only
EXPLAIN SELECT * FROM appointments
WHERE appointment_day = '2026-12-01' AND doctor_id = 1;
SET enable_seqscan = on;

-- (g) Scheduled job: count each status for one date; rerun replaces the row
CREATE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('ict371-q4-clinic-summary', '0 1 * * *',
                              $job$CALL pr_refresh_clinic_summary((CURRENT_DATE - 1))$job$);
    ELSE
        RAISE NOTICE 'pg_cron not installed; skipping schedule';
    END IF;
END $$;
