# frozen_string_literal: true

module Upstate
  module Rails
    # Builds the schema 1 response. Every section rescues its own errors and reports nil.
    class Health
      SCHEMA = 1

      def self.call(now: Time.now)
        new(now).call
      end

      def initialize(now)
        @now = now
      end

      # => [http_status, body_hash]
      def call
        database = section { Sections.database }
        jobs, solid_queue = section { Jobs.call(now: @now) } || [nil, nil]

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
          cache: section { Sections.cache },
          actions: section { actions }
        }
        body[:solid_queue] = solid_queue if solid_queue

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
