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

        {ok: true, pending_migrations: pending_migrations}
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
