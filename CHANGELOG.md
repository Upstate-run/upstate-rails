# Changelog

## 0.2.0

- Report `database.size_bytes`: `pg_database_size(current_database())` for the primary
  connection, in bytes. This database only, not WAL or other databases on the server. One
  query under a 500ms transaction-local statement timeout, PostgreSQL only; left out on other
  adapters or on error, and it never changes `database.ok` or the status. The schema stays 1
  (the field is additive); Upstate servers that predate it ignore it.

## 0.1.0

- First release: `GET /upstate/health` (schema 1) with boot facts, migrations, DB pool, Puma,
  Solid Queue / Sidekiq / GoodJob job numbers, cache probe, and per-minute action rollups.
