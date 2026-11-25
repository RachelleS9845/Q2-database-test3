# Question 2 — University Fee Payments

**Script:** [`q02_fees.sql`](q02_fees.sql) · **Schema:** `q02_fees` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q02_fees.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q02_fees.sql
```

The script drops and recreates the `q02_fees` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `students`, `payments`, `payment_audit`, `daily_collections` | `student_number` UNIQUE, `fee_due >= 0`, `amount > 0`. Three students with fees of K15 000, K12 500 and K9 800. Six payments: Mwila is fully settled, Chanda is part-paid, and **Natasha has no payments**. |
| (b) Function [6] | `fn_fee_balance(p_student_id)` | `fee_due − COALESCE(SUM(amount),0)`. The COALESCE means a student with no payments gets the full fee back. An unknown student raises an error. |
| (c) Procedure [8] | `pr_receive_payment(p_student_id, p_amount, p_paid_on)` | Rejects NULL, zero and negative amounts, and any amount above the outstanding balance, so no credit balance is possible. It locks the student row and inserts the payment **only**. `fee_due` is never changed and no audit row is written here. |
| (d) Trigger [8] | `trg_payments_audit` (AFTER INSERT, FOR EACH ROW) | Writes `payment_id`, `student_id`, `amount` and `now()` to `payment_audit` automatically for every payment, including direct SQL inserts. |
| (e) View [5] | `v_fee_balances` | Student number, name and outstanding balance, filtered to `balance > 0`. The fully settled student is excluded. |
| (f) Index [5] | `idx_payments_student_paidon (student_id, paid_on)` | Composite index: `student_id` (=) first, then `paid_on` (range), so one student's payments are stored together in date order. |
| (g) Job [6] | `pr_refresh_collections(p_day)` + cron `0 1 * * *` | Stores the payment count and total for the day with an upsert, so a rerun replaces the row. The job runs at 01:00 for the previous day. |

## Expected results (verified on PostgreSQL 16)

Balances are 0 / 5 500 / 9 800. Six rejected payments leave 6 payment rows and unchanged `fee_due`. There are six audit rows. Yesterday's collection is 3 payments, K8 000.00.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
