# Changelog

## 0.7.0

- Report the reporter's name and version, and this process's resident memory (`rss_bytes`, Linux only, otherwise `null`) and Ruby GC counters (`process.gc`). Counts and sizes only. They describe the one Puma worker that answered the request; workers are not merged.
- Add `queues` (name, depth, oldest queued age; top 50), `served_queues` (queues served by live workers) and `classes` (per job class processed, failed and run time over 5 minutes; top 50) to `jobs` for Solid Queue, GoodJob and Sidekiq where the adapter exposes them. Each is `null` independently if it cannot be read. Arguments, errors and job ids are never read.

## 0.6.0

- Report the oldest active Solid Queue claim independently of recent run history, so fast jobs can be checked for stuck runs. Report the latest successful completion even when newer failures fill the history sample.
- Allow applications to report aggregate progress for a durable inbox or outbox through the authenticated health endpoint.

## 0.5.0

- With no `UPSTATE_HEALTH_TOKEN` in a development or test environment, `rake upstate:verify` reports a `note` instead of `FAIL`, says this is expected outside production, prints the production command and exits 0. Without a token in production it still fails.
- Document running the check in production: `kamal app exec --reuse 'bin/rails upstate:verify'`.

## 0.4.0

- Add `rake upstate:verify`, a read-only check that sends nothing to Upstate and writes nothing (it reads the app's database, as the endpoint does, and does not touch the cache, job systems, recurring-job tables or action rollups): disabled or configured, token presence (never the value), reporter and runtime versions, and endpoint authorization and response. Nothing runs on install, and it sends nothing to Upstate.

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
