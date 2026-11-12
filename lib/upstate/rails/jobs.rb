# frozen_string_literal: true

module Upstate
  module Rails
    module Jobs
      NO_QUEUE = %w[async inline test].freeze

      module_function

      # Returns [jobs_hash, solid_queue_block_or_nil]. Raises if the adapter's store is unreachable.
      def call(now: Time.now)
        case adapter_name
        when "solid_queue" then SolidQueueAdapter.call(now: now)
        when "sidekiq" then SidekiqAdapter.call(now: now)
        when "good_job" then GoodJobAdapter.call(now: now)
        when "none" then [empty("none"), nil]
        else [empty("unsupported"), nil]
        end
      end

      def adapter_name
        return "none" unless defined?(::ActiveJob::Base)

        name = ::ActiveJob::Base.queue_adapter_name.to_s
        return name if %w[solid_queue sidekiq good_job].include?(name)
        return "none" if NO_QUEUE.include?(name) || name.empty?

        "unsupported"
      rescue StandardError
        "unsupported"
      end

      def empty(adapter)
        {adapter: adapter, queue_depth: nil, oldest_queued_age_seconds: nil, workers: nil,
         processed_last_5m: nil, failed_last_5m: nil, recent_processing_at: nil}
      end
    end
  end
end
