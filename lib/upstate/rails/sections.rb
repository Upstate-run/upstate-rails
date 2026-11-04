# frozen_string_literal: true

module Upstate
  module Rails
    module Sections
      module_function

      def database
        return nil unless defined?(::ActiveRecord::Base)

        ok = begin
          ::ActiveRecord::Base.connection_pool.with_connection { |c| c.select_value("SELECT 1") }
          true
        rescue StandardError
          false
        end
        return {ok: false, pending_migrations: nil} unless ok

        {ok: true, pending_migrations: pending_migrations}.merge(database_stats)
      end

      STATEMENT_TIMEOUT_MS = 250

      SUMMARY_SQL = <<~SQL
        SELECT
          pg_database_size(current_database()),
          (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'),
          current_setting('max_connections')::int,
          COALESCE((SELECT floor(extract(epoch FROM now() - min(xact_start)))::bigint
                    FROM pg_stat_activity
                    WHERE datname = current_database() AND xact_start IS NOT NULL
                      AND pid <> pg_backend_pid() AND backend_type = 'client backend'), 0),
          (SELECT count(*) FROM pg_stat_activity
           WHERE datname = current_database()
             AND state IN ('idle in transaction', 'idle in transaction (aborted)')),
          (SELECT age(datfrozenxid) FROM pg_database WHERE datname = current_database()),
          pg_is_in_recovery(),
          CASE WHEN pg_is_in_recovery()
            THEN floor(extract(epoch FROM now() - pg_last_xact_replay_timestamp()))::bigint END
      SQL

      TABLES_SQL = <<~SQL
        SELECT quote_ident(schemaname) || '.' || quote_ident(relname), pg_total_relation_size(relid), n_live_tup, n_dead_tup
        FROM pg_stat_user_tables
        ORDER BY pg_total_relation_size(relid) DESC
        LIMIT 5
      SQL

      REPLICAS_SQL = <<~SQL
        SELECT count(*), floor(extract(epoch FROM max(replay_lag)))::bigint FROM pg_stat_replication
      SQL

      # Cheap, aggregate, read-only PostgreSQL health numbers for the primary connection:
      # size (this database only, not WAL or other databases), connections vs
      # max_connections, the oldest open transaction and sessions idle in transaction (as
      # visible to the app's role), age(datfrozenxid), replication lag where visible, and
      # the 5 largest tables with estimated live/dead rows (names and numbers, no row data;
      # each name part is quote_ident-ed so distinct tables never share a schema.table name).
      # One transaction with a transaction-local statement timeout and a savepoint per query,
      # so a failing query drops only its fields. Other adapters or any error return {}.
      def database_stats
        ::ActiveRecord::Base.connection_pool.with_connection do |connection|
          next {} unless connection.adapter_name.to_s.match?(/postg/i)

          connection.transaction(requires_new: true) do
            connection.execute("SET LOCAL statement_timeout = #{STATEMENT_TIMEOUT_MS}")
            summary = guarded_rows(connection, SUMMARY_SQL)&.first
            tables = guarded_rows(connection, TABLES_SQL)
            replicas = guarded_rows(connection, REPLICAS_SQL)&.first if primary?(summary)

            stats = summary_stats(summary)
            table_list = table_stats(tables)
            stats[:largest_tables] = table_list if table_list
            replica_stats = replicas_stats(replicas)
            stats[:replication] = replica_stats if replica_stats
            stats
          end
        end
      rescue StandardError
        {}
      end

      # Runs one query behind a savepoint; a failure rolls back to it and returns nil.
      def guarded_rows(connection, sql)
        connection.transaction(requires_new: true) { connection.select_rows(sql) }
      rescue StandardError
        nil
      end

      def primary?(summary)
        summary.is_a?(Array) && [false, "f"].include?(summary[6])
      end

      def summary_stats(row)
        return {} unless row.is_a?(Array) && row.size == 8

        size, in_use, max, oldest, idle, xid_age, recovery, lag = row
        stats = {}
        put(stats, :size_bytes, count(size))
        in_use = count(in_use)
        max = count(max)
        stats[:connections] = {in_use: in_use, max: max} if in_use && max&.positive?
        put(stats, :oldest_transaction_age_seconds, count(oldest))
        put(stats, :idle_in_transaction, count(idle))
        put(stats, :xid_age, count(xid_age))
        stats[:replication] = {role: "replica", lag_seconds: count(lag)} if [true, "t"].include?(recovery)
        stats
      end

      def table_stats(rows)
        return nil unless rows.is_a?(Array) && !rows.empty?

        tables = rows.first(5).filter_map do |name, total, live, dead|
          next unless name.is_a?(String)

          {name: name, total_bytes: count(total), live_rows: count(live), dead_rows: count(dead)}
        end
        tables.empty? ? nil : tables
      end

      def replicas_stats(row)
        return nil unless row.is_a?(Array)

        replicas = count(row[0])
        return nil unless replicas&.positive?

        {role: "primary", replicas: replicas, lag_seconds: count(row[1])}
      end

      def count(value)
        number = Integer(value, exception: false) if value.is_a?(Integer) || value.is_a?(String)
        number if number && number >= 0
      end

      def put(hash, key, value)
        hash[key] = value unless value.nil?
      end

      # ConnectionPool#migration_context exists on 7.1+; older shapes fall back to the connection.
      def pending_migrations
        pool = ::ActiveRecord::Base.connection_pool
        context = if pool.respond_to?(:migration_context)
          pool.migration_context
        else
          pool.with_connection(&:migration_context)
        end
        context.needs_migration?
      rescue StandardError
        nil
      end

      def active_record_pool
        return nil unless defined?(::ActiveRecord::Base)

        stat = ::ActiveRecord::Base.connection_pool.stat
        {size: stat[:size], busy: stat[:busy], waiting: stat[:waiting]}
      end

      # Sums across cluster workers. In cluster mode a worker's view of its siblings comes
      # from the master's last snapshot, so values are best effort.
      def puma
        return nil unless defined?(::Puma) && ::Puma.respond_to?(:stats_hash)

        stats = ::Puma.stats_hash
        return nil unless stats.is_a?(Hash) && !stats.empty?

        stats = stats.transform_keys(&:to_sym)
        if stats[:worker_status]
          statuses = stats[:worker_status].map { |w| (w[:last_status] || w["last_status"] || {}).transform_keys(&:to_sym) }
          {
            workers: stats[:workers],
            booted_workers: stats[:booted_workers],
            max_threads: sum(statuses, :max_threads),
            backlog: sum(statuses, :backlog),
            pool_capacity: sum(statuses, :pool_capacity)
          }
        else
          {workers: 1, booted_workers: 1, max_threads: stats[:max_threads],
           backlog: stats[:backlog], pool_capacity: stats[:pool_capacity]}
        end
      end

      def sum(rows, key)
        values = rows.filter_map { |r| r[key] }
        values.empty? ? nil : values.sum
      end

      PROBED = {"SolidCache::Store" => "solid_cache", "ActiveSupport::Cache::RedisCacheStore" => "redis_cache_store"}.freeze

      # Matches by class name, never by constant, so autoloaded stores (and their gems)
      # are not loaded just to be compared against.
      def cache
        store = ::Rails.cache
        name = store.class.ancestors.filter_map { |k| PROBED[k.name] }.first
        return nil unless name

        key = "upstate:health-probe"
        store.write(key, "1", expires_in: 60)
        {store: name, ok: store.read(key) == "1"}
      rescue StandardError
        name ? {store: name, ok: false} : nil
      end
    end
  end
end
