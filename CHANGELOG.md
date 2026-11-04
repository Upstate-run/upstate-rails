# Changelog

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
