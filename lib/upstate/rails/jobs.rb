# frozen_string_literal: true

module Upstate
  module Rails
    module Jobs
      NO_QUEUE = %w[async inline test].freeze
      MAX_ENTRIES = 50
      MAX_PROCESSES = 200
      QUEUE_NAME_MAX = 120
      CLASS_NAME_MAX = 200

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

      # Runs one optional sub-field; any failure leaves just that field nil.
      def optional
        yield
      rescue StandardError, NotImplementedError
        nil
      end

      def clip(value, max)
        value.to_s[0, max]
      end

      def age(now, oldest)
        oldest && [now.to_i - oldest.to_i, 0].max
      end

      # counts: {queue_name => depth} (already limited by the query); oldest: {queue_name => Time}.
      def queue_entries(counts, oldest, now)
        counts.sort_by { |name, depth| [-depth.to_i, name.to_s] }.first(MAX_ENTRIES).map do |name, depth|
          {name: clip(name, QUEUE_NAME_MAX), depth: depth.to_i, oldest_queued_age_seconds: age(now, oldest && oldest[name])}
        end
      end

      # Parses a GoodJob queue string ("a,b:2;+c,d"; also an array of such segments). Pools are
      # separated by ";" and each may end in ":threads". A leading "-" on a segment means
      # "everything except" (coverage unknown, nil); a leading "+" (ordered) is dropped once
      # for the segment, before splitting on commas, so "default,+bulk" has the literal
      # names "default" and "+bulk".
      def queue_specs(value)
        return nil if value.nil?

        segments = value.is_a?(Array) ? value : value.to_s.split(";")
        segments = [""] if segments.empty?
        names = []
        segments.each do |segment|
          text = segment.to_s.strip.sub(/:\s*\d+\z/, "").strip
          text = "*" if text.empty? # GoodJob reads a blank queue string as all queues
          return nil if text.start_with?("-")

          names.concat(text.sub(/\A\+/, "").split(",").map(&:strip).reject(&:empty?))
        end
        names.empty? ? nil : names
      end

      # sets: one array of names per live worker process (nil entries mean unknown).
      # `wildcard: false` for adapters (Sidekiq) where "*" is just a queue name.
      def served(sets, wildcard: true)
        return {all: false, names: []} if sets.empty?
        return nil if sets.any?(&:nil?)

        names = sets.flatten.uniq
        # An incomplete union would make omitted queues look unserved, so overflow is unknown.
        return nil if names.size > MAX_ENTRIES * 2

        {all: wildcard && names.include?("*"), names: names.map { |n| clip(n, QUEUE_NAME_MAX) }}
      end

      # rows: {name => {processed:, failed:, avg:, max:}}
      # `failed_in_processed`: failures are already part of `processed` (GoodJob), so rank by it alone.
      def class_entries(rows, failed_in_processed: false)
        score = ->(r) { failed_in_processed ? r[:processed].to_i : r[:processed].to_i + r[:failed].to_i }
        rows.sort_by { |name, r| [-score.call(r), name.to_s] }.first(MAX_ENTRIES).map do |name, r|
          {name: clip(name, CLASS_NAME_MAX), processed_last_5m: r[:processed].to_i, failed_last_5m: r[:failed].to_i,
           duration_ms_avg: r[:avg]&.to_f&.round, duration_ms_max: r[:max]&.to_f&.round}
        end
      end

      # Fetches live worker rows with a cap; nil when more than the cap exist (coverage unknown).
      def capped_processes(scope)
        rows = scope.limit(MAX_PROCESSES + 1).to_a
        rows.size > MAX_PROCESSES ? nil : rows
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
         processed_last_5m: nil, failed_last_5m: nil, recent_processing_at: nil,
         queues: nil, served_queues: nil, classes: nil}
      end
    end
  end
end
