# upstate-rails

Rails app health for [Upstate](https://upstate.cloud): boot facts, migrations, database health, Puma, jobs, and the slowest actions. Counts only.

The gem adds one endpoint, `GET /upstate/health`. Upstate's host observer reads it from inside your server, over your private Docker network, every minute. Nothing else is installed, and nothing is sent anywhere by the gem itself.

## What is sent

- App version (`APP_VERSION`, else `KAMAL_VERSION`, else `unknown`), Rails and Ruby versions, whether YJIT is on, when the process booted.
- Whether the database answers, and whether migrations are pending.
- Database health for the primary connection (PostgreSQL only): its size in bytes (`pg_database_size`, this database only, not WAL or other databases), connections in use and `max_connections`, the oldest open transaction's age and the number of sessions idle in transaction (as visible to the app's role), `age(datfrozenxid)` (wraparound headroom), replication lag where this connection can see it, and the 5 largest tables with their total size and estimated live and dead rows. Table names are sent; row data never is. One transaction with a 250ms statement timeout and a savepoint per query; anything that fails, or MySQL/SQLite, is left out.
- Active Record pool size, busy and waiting connections.
- Puma workers, threads, backlog and spare capacity.
- Job numbers for Solid Queue, Sidekiq or GoodJob: queue depth, oldest queued age, worker count, jobs processed and failed in the last 5 minutes, and when something last ran.
- Solid Queue only: your recurring jobs from `config/recurring.yml` (or `SOLID_QUEUE_RECURRING_SCHEDULE`), under the current Rails environment. For each, the key, the class name and the schedule text, and for its recent runs (last 24 hours, newest 10 finished runs per job, plus any still running) an id, when it started or finished and whether it succeeded, failed or is running. Upstate turns these into check-in suggestions; nothing is monitored until you accept. A job's arguments and `command:` are never read.
- Whether your cache (Solid Cache or Redis) answers.
- For the last 15 minutes, the 10 slowest `Controller#action` names per minute, with request count, error count, a 12-bucket timing histogram, and total database time.

## What is never sent

No params, URLs or paths, SQL, row data, IP addresses, user agents, headers, cookies, job arguments, exception classes or messages, logs, or traces. An error is only a count (a 5xx response or an unhandled exception). Queue names are not read. Job class names are read only for the recurring jobs listed in `config/recurring.yml`, and never for other jobs.

## Install

```ruby
# Gemfile
gem "upstate-rails"
```

```sh
bundle install
bin/rails g upstate:install
```

The endpoint is off until `UPSTATE_HEALTH_TOKEN` is set. Without it, `/upstate/health` returns 404. With a missing or wrong token it returns 401.

## Kamal secrets

1. In Upstate, open the environment page and generate a health token. It is shown once.
2. Add it to `.kamal/secrets`:

   ```sh
   UPSTATE_HEALTH_TOKEN=<the token>
   ```

3. List it in `config/deploy.yml`:

   ```yaml
   env:
     secret:
       - UPSTATE_HEALTH_TOKEN
   ```

4. `kamal deploy`.

The generator appends a commented example to `config/deploy.yml` only when `UPSTATE_HEALTH_TOKEN` is not already in the file.

## Verify

```sh
curl -i -H "Authorization: Bearer $UPSTATE_HEALTH_TOKEN" https://your-app.example.com/upstate/health
```

You should get `200` and JSON starting with `"schema": 1`. A `503` means the database is not answering (the JSON says so). Anything with a slow, missing or erroring section reports that section as `null` and still returns the rest.

## Good to know

- The route is added ahead of your routes, so a catch-all route cannot hide it.
- The path is excluded from `config.host_authorization` and from the `force_ssl` redirect, because the observer calls the container's private IP over plain HTTP. Nothing else changes in those settings.
- Action timings are kept in memory per Puma worker and written to `Dir.tmpdir/upstate-rails/<pid>.json` about once a minute (not on every request). The endpoint merges the files of live processes. Files older than 20 minutes are ignored.
- Sidekiq keeps lifetime counters only, so `processed_last_5m` and `failed_last_5m` are `null` until the gem has seen two readings at least 30 seconds apart in one process.
- In Puma cluster mode, a worker answering the request sees the other workers through the master's last snapshot, so Puma numbers are best effort.
- Requires Ruby 3.1+ and Rails 7.1+. No other runtime gems.

## Migrating from the v0 controller

If you copied `upstate_health_controller.rb` and its route into your app, remove both: delete `app/controllers/upstate_health_controller.rb` and the `get "/upstate/health"` line in `config/routes.rb`. Keep the same `UPSTATE_HEALTH_TOKEN`. The gem's response is a superset of the v0 response (including the same `solid_queue` block), so Upstate keeps working through the change.

## Development

```sh
bundle install
bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle install && BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rake test
```

CI runs Rails 7.2 and 8.0 on Ruby 3.2 to 3.4.

## License

MIT.
