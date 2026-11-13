# Changelog

## 0.3.0

- Solid Queue: report the app's recurring jobs in a new `recurring` section so Upstate can
  propose a check-in for each one:
  - `tasks`: `{key, class_name, schedule, interval_seconds}` for each entry of
    `config/recurring.yml` (or `SOLID_QUEUE_RECURRING_SCHEDULE`) under the current Rails
    environment key. `interval_seconds` is the longest gap between the next runs, from Fugit
    when it is loaded. Job arguments, `command:` and queue names are never read.
  - `runs`: for those jobs, the last 24 hours (newest 10 finished runs per job, plus every run still going at any age; running jobs are read independently of the row limits; finished and failed runs are the newest by end time) as `{key, run_id,
    started_at, finished_at, result}` with `result` of `success`, `fail` or `running`,
    read from Solid Queue's own tables so any container reports them. `run_id` is
    `sq-<job id>`. Solid Queue keeps no start time once a job finishes, so `started_at` is
    only present while a run is going.
  - The section is left out when there is no readable schedule or another job adapter is
    in use (sidekiq-cron and GoodJob cron are not read yet; `Upstate::Rails::Recurring::SOURCES`
    is the seam). The schema stays 1 and the section is additive: servers that predate it
    ignore it, and this gem keeps working against them.

## 0.2.0

- Report database health in the `database` section, for the primary connection on
  PostgreSQL:
  - `size_bytes`: `pg_database_size(current_database())` (this database only, not WAL or
    other databases on the server);
  - `connections`: `{in_use, max}` (client connections and `max_connections`);
  - `oldest_transaction_age_seconds` (0 when none is open) and `idle_in_transaction`, for
    sessions the app's role can see;
  - `xid_age`: `age(datfrozenxid)` (transaction ID wraparound headroom used);
  - `replication`: replica replay lag, or the replica count and largest `replay_lag` on a
    primary where visible; left out otherwise;
  - `largest_tables`: the 5 largest tables with total size and estimated live/dead rows.
    Table names and numbers only, never row data.
- One transaction with a 250ms `SET LOCAL statement_timeout` and a savepoint per query.
  Anything that fails, or another adapter, is left out; it never changes `database.ok` or
  the status. The schema stays 1 (all fields are additive); Upstate servers that predate
  them ignore them.

## 0.1.0

- First release: `GET /upstate/health` (schema 1) with boot facts, migrations, DB pool, Puma,
  Solid Queue / Sidekiq / GoodJob job numbers, cache probe, and per-minute action rollups.
