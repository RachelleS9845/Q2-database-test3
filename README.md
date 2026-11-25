[README.md](https://github.com/user-attachments/files/35401181/README.md)
# ICT371 Advanced Database — Final Assessment (Questions 1–10)

PostgreSQL solutions for all ten questions. Each question sits in its own folder with:

- one `.sql` script that answers parts **(a)–(g)** in order, with test calls that show each rule working, and
- a `README.md` explaining every part and the expected output.

| Q | Folder | Topic |
|---|--------|-------|
| 1 | [`Q01_Pharmacy_Stock_and_Sales`](Q01_Pharmacy_Stock_and_Sales) | Pharmacy stock and daily sales |
| 2 | [`Q02_University_Fee_Payments`](Q02_University_Fee_Payments) | University fee payments |
| 3 | [`Q03_Library_Returns_and_Fines`](Q03_Library_Returns_and_Fines) | Library returns and overdue fines |
| 4 | [`Q04_Clinic_Appointments`](Q04_Clinic_Appointments) | Clinic appointment scheduling |
| 5 | [`Q05_Hostel_Room_Allocation`](Q05_Hostel_Room_Allocation) | Hostel room allocation |
| 6 | [`Q06_Monthly_Payroll`](Q06_Monthly_Payroll) | Monthly payroll processing |
| 7 | [`Q07_Water_Meter_Billing`](Q07_Water_Meter_Billing) | Water meter readings and billing |
| 8 | [`Q08_Fleet_Maintenance`](Q08_Fleet_Maintenance) | Transport fleet maintenance |
| 9 | [`Q09_Maize_Deliveries`](Q09_Maize_Deliveries) | Farmer cooperative maize deliveries |
| 10 | [`Q10_Scholarship_Assessment`](Q10_Scholarship_Assessment) | Scholarship application assessment |

## Environment

- **PostgreSQL 14 or newer.** Tested on PostgreSQL 16.
- **pg_cron** for the scheduled jobs in part (g).
- Every script creates its own schema (`q01_pharmacy`, `q02_fees`, …, `q10_scholarship`), and the first line drops that schema. That means:
  - you can run any script again at any time, and
  - all ten can live in one database without name clashes.

## How to run

**pgAdmin:** open your database, go to Query Tool, open the question's `.sql` file and press **F5**. Query results appear in *Data Output* and the `RAISE NOTICE` test messages appear in *Messages*.

**psql:**

```bash
psql -d ict371 -f Q01_Pharmacy_Stock_and_Sales/q01_pharmacy.sql
```

The negative tests (overselling, slot clashes, bad input and so on) are wrapped in `DO $$ … EXCEPTION … $$` blocks. Each error is printed as a NOTICE, so the script keeps running and you can see the error message.

## Setting up pg_cron (part g)

pg_cron has to be loaded when the server starts. Add these lines to `postgresql.conf`, then restart PostgreSQL:

```
shared_preload_libraries = 'pg_cron'
cron.database_name       = 'ict371'          -- the database that holds these schemas
cron.timezone            = 'Africa/Lusaka'   -- so "00:15" means 00:15 local time
```

Then, once, in that database:

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

Each script schedules its job with a **named** `cron.schedule(...)`. Running the script again replaces the job instead of creating a duplicate.

Useful commands:

```sql
SELECT jobid, jobname, schedule, command, active FROM cron.job ORDER BY jobid;   -- all jobs
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;           -- run history
SELECT cron.unschedule('q01_refresh_daily_sales');                              -- remove a job
```

> The cron worker does **not** use your session's `search_path`. Two things deal with that:
> 1. The job commands use schema-qualified names, for example `CALL q01_pharmacy.pr_refresh_sales(...)`.
> 2. Every function and procedure carries `SET search_path = <its schema>, public`, so the unqualified table names inside it still resolve when cron (or any other session) runs it.
>
> Without point 2 the jobs fail with `relation "daily_sales" does not exist`. All ten jobs were run by pg_cron and finished with status `succeeded`.

## A note on the EXPLAIN plans (part f)

The seed tables only hold about 6–10 rows. With that little data PostgreSQL correctly picks a **Seq Scan**, because reading one small page is cheaper than opening an index. Each script therefore shows two plans:

1. a plain `EXPLAIN`, which shows the planner's real choice on tiny data, and
2. `SET LOCAL enable_seqscan = off` plus `EXPLAIN ANALYZE` inside a transaction. This shows the index **matches** the query (`Index Scan using idx_…`, `Index Cond: …`), which is the plan you would get on a production-sized table.
