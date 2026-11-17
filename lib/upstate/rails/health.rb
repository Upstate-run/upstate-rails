# frozen_string_literal: true

module Upstate
  module Rails
    # Builds the schema 1 response. Every section rescues its own errors and reports nil.
    class Health
      SCHEMA = 1

      # `read_only` builds the response without any write or side effect: the cache probe,
      # the job-system read (Sidekiq's process set prunes dead entries when loaded) and
      # recurring-job tables (Solid Queue) and action rollups are skipped. Used by the local verify.
      def self.call(now: Time.now, read_only: false)
        new(now, read_only: read_only).call
      end

      def initialize(now, read_only: false)
        @now = now
        @read_only = read_only
      end

      # => [http_status, body_hash]
      def call
        database = section { Sections.database }
        jobs, solid_queue = (@read_only ? nil : section { Jobs.call(now: @now) }) || [nil, nil]

        body = {
          schema: SCHEMA,
          version: version,
          rails: section { {version: ::Rails.version, environment: ::Rails.env.to_s} },
          ruby: section { {version: RUBY_VERSION, yjit: yjit?} },
          booted_at: BOOTED_AT.iso8601,
          database: database,
          active_record_pool: section { Sections.active_record_pool },
          puma: section { Sections.puma },
          jobs: jobs,
          cache: @read_only ? nil : section { Sections.cache },
          actions: @read_only ? nil : section { actions }
        }
        body[:solid_queue] = solid_queue if solid_queue
        recurring = @read_only ? nil : section { Recurring.call(now: @now) }
        body[:recurring] = recurring if recurring

        status = database && database[:ok] == false ? 503 : 200
        [status, body]
      end

      private

      def version
        [ENV["APP_VERSION"], ENV["KAMAL_VERSION"]].find { |v| !v.to_s.strip.empty? }&.strip || "unknown"
      end

      def yjit?
        !!(defined?(::RubyVM::YJIT) && ::RubyVM::YJIT.enabled?)
      end

      def actions
        Upstate::Rails.rollup.flush!
        ActionStore.merged(now: @now).map { |m| {minute: m[:minute].iso8601, items: m[:items]} }
      end

      def section
        yield
      rescue StandardError, NotImplementedError
        nil
      end
    end
  end
end
