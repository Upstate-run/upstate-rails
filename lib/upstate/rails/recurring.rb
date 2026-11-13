# frozen_string_literal: true

module Upstate
  module Rails
    # The `recurring` section: the app's own recurring-job schedule and recent runs of those
    # jobs, so Upstate can propose a check-in for each one. Sent: job key, class name,
    # schedule text and, per run, an id, start, end and result. Never job arguments, never a
    # `command:` string, never queue names or error text.
    #
    # Each source answers `call(now:)` with
    #   {adapter: "...", tasks: [{key:, class_name:, schedule:, interval_seconds:}] | nil,
    #    runs: [{key:, run_id:, started_at:, finished_at:, result:}]}
    # `tasks: nil` means the schedule could not be read (the server then changes nothing).
    # To add sidekiq-cron or GoodJob cron, add a source here that returns the same shape and
    # register it under the adapter name; the server allowlist gains the adapter name too.
    module Recurring
      SOURCES = {"solid_queue" => :SolidQueueSource}.freeze

      module_function

      # => section hash, or nil when the adapter has no source or finds no schedule file.
      def call(now: Time.now)
        source = SOURCES[Jobs.adapter_name]
        return unless source

        section = const_get(source).call(now: now)
        section if section && !section[:tasks].nil?
      end
    end
  end
end
