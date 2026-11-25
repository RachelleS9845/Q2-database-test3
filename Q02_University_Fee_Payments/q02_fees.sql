/* =====================================================================
   ICT371 Advanced Database — Question 2: University Fee Payments
   DBMS : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Rule : credit balances are NOT allowed (nobody may pay more than owed).
   ===================================================================== */

DROP SCHEMA IF EXISTS q02_fees CASCADE;
CREATE SCHEMA q02_fees;
SET search_path TO q02_fees, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables and constraints  [6 marks]
   --------------------------------------------------------------------- */
CREATE TABLE students (
    student_id      SERIAL        PRIMARY KEY,
    student_number  VARCHAR(20)   NOT NULL UNIQUE,
    full_name       VARCHAR(100)  NOT NULL,
    fee_due         NUMERIC(12,2) NOT NULL CONSTRAINT chk_fee_due_nonneg CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id  SERIAL        PRIMARY KEY,
    student_id  INTEGER       NOT NULL REFERENCES students(student_id),
    amount      NUMERIC(12,2) NOT NULL CONSTRAINT chk_payment_positive CHECK (amount > 0),
    paid_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id    SERIAL        PRIMARY KEY,
    payment_id  INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id  INTEGER       NOT NULL REFERENCES students(student_id),
    amount      NUMERIC(12,2) NOT NULL,
    logged_at   TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date  DATE          PRIMARY KEY,
    payment_count    INTEGER       NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount     NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_fee_balance(p_student_id)  [6 marks]
   fee_due minus total payments; full fee if no payments; unknown -> error.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q02_fees, public
AS $$
DECLARE
    v_fee_due students.fee_due%TYPE;
    v_paid    NUMERIC(14,2);
BEGIN
    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student % does not exist', p_student_id USING ERRCODE = 'P0002';
    END IF;

    -- COALESCE turns "no payments" (SUM = NULL) into 0, so the full fee is returned
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee_due - v_paid;
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_receive_payment(p_student_id, p_amount, p_paid_on)  [8 marks]
   Rejects NULL/zero/negative amounts and over-payments. Inserts the payment
   only — fee_due is never changed and NO audit insert is done here.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
SET search_path = q02_fees, public
AS $$
DECLARE
    v_balance    NUMERIC;
    v_payment_id INTEGER;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment rejected: amount must be greater than zero (got %)', p_amount
              USING ERRCODE = '22023';
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment rejected: payment date is required' USING ERRCODE = '22023';
    END IF;

    -- lock the student so two cashiers cannot both accept the last kwacha owed
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;

    v_balance := fn_fee_balance(p_student_id);   -- raises if the student is unknown

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment rejected: K% exceeds outstanding balance K%', p_amount, v_balance
              USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on)
    RETURNING payment_id INTO v_payment_id;

    RAISE NOTICE 'Payment % accepted: student %, K%, new balance K%',
                 v_payment_id, p_student_id, p_amount, v_balance - p_amount;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — AFTER INSERT row trigger on payments  [8 marks]
   Automatically writes payment_id, student_id, amount and timestamp.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q02_fees, public
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

/* ---------------------------------------------------------------------
   (a) SEED DATA — 3 students with different fees, 6 payments.
   Student 3 (Natasha) has NO payments.
   --------------------------------------------------------------------- */
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('2024010101', 'Mwila Banda',   15000.00),
    ('2024010102', 'Chanda Phiri',  12500.00),
    ('2024010103', 'Natasha Zulu',   9800.00);

CALL pr_receive_payment(1, 5000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 3000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 6000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 2500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1, 4000.00, CURRENT_DATE - 1);   -- Mwila fully settled (15 000)
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 1);   -- Chanda still owes 5 500

SELECT * FROM payments ORDER BY payment_id;

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
-- (b) balances: settled (0), partly paid (5500), no payments = full fee (9800)
SELECT student_id, full_name, fee_due, fn_fee_balance(student_id) AS balance
FROM students ORDER BY student_id;

DO $$
BEGIN
    BEGIN PERFORM fn_fee_balance(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_fee_balance(999) -> %', SQLERRM; END;
END $$;

-- (c) rejected payments: nothing inserted, fee_due untouched
DO $$
BEGIN
    BEGIN CALL pr_receive_payment(2, NULL, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'NULL amount   -> %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(2, 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Zero amount   -> %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(2, -100, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Negative      -> %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(2, 9999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Over balance  -> %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Settled acct  -> %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(77, 50, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown stud  -> %', SQLERRM; END;
END $$;

SELECT COUNT(*) AS payments_still_6 FROM payments;
SELECT student_id, fee_due FROM students ORDER BY student_id;   -- fee_due unchanged

-- (d) every payment has exactly one audit row, written by the trigger
SELECT * FROM payment_audit ORDER BY audit_id;

/* ---------------------------------------------------------------------
   (e) VIEW v_fee_balances — only students who still owe  [5 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(p.total_paid, 0) AS outstanding_balance
FROM   students s
LEFT JOIN (SELECT student_id, SUM(amount) AS total_paid
           FROM payments
           GROUP BY student_id) p ON p.student_id = s.student_id
WHERE  s.fee_due - COALESCE(p.total_paid, 0) > 0;

SELECT * FROM v_fee_balances ORDER BY student_number;   -- Mwila (settled) is excluded

/* ---------------------------------------------------------------------
   (f) COMPOSITE INDEX — payments by student_id and a paid_on range  [5 marks]
   Justification: student_id is tested with "=", paid_on with a range.
   Putting student_id first groups each student's payments together in the
   B-tree, and paid_on second keeps them in date order, so the range is one
   short contiguous read.
   --------------------------------------------------------------------- */
CREATE INDEX idx_payments_student_paidon ON payments (student_id, paid_on);
ANALYZE payments;

EXPLAIN
SELECT payment_id, amount, paid_on
FROM   payments
WHERE  student_id = 2
AND    paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

BEGIN;
SET LOCAL enable_seqscan = off;   -- tiny table: force the planner to show the index path
EXPLAIN ANALYZE
SELECT payment_id, amount, paid_on
FROM   payments
WHERE  student_id = 2
AND    paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_refresh_collections(p_day)  [6 marks]
   Upsert replaces the summary row on rerun.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
SET search_path = q02_fees, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM   payments
    WHERE  paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
       SET payment_count = EXCLUDED.payment_count,
           total_amount  = EXCLUDED.total_amount;

    RAISE NOTICE 'daily_collections refreshed for %', p_day;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);   -- rerun: still one row, 3 payments, K8000.00
SELECT * FROM daily_collections;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q02_refresh_collections',
    '0 1 * * *',                                   -- 01:00 every day
    $$CALL q02_fees.pr_refresh_collections(CURRENT_DATE - 1)$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job WHERE jobname = 'q02_refresh_collections';
