# frozen_string_literal: true

module Upstate
  module Rails
    module Jobs
      # Sidekiq keeps lifetime counters, so the last-5-minute numbers are deltas between
      # samples taken by this process. Until two samples span time, they are null.
      module SidekiqAdapter
        WINDOW = 300
        MAX_SAMPLES = 64
        MUTEX = Mutex.new
        SAMPLES = []

        module_function

        def reset_samples!
          MUTEX.synchronize { SAMPLES.clear }
        end

        def call(now: Time.now)
          stats = ::Sidekiq::Stats.new
          depth = stats.enqueued
          # One latency read per queue, shared by the overall oldest age and the per-queue rows.
          latencies = depth.to_i.positive? ? ::Sidekiq::Queue.all.to_h { |q| [q.name.to_s, q.latency.to_f] } : {}
          oldest = latencies.values.max
          processed, failed = deltas(now, stats.processed.to_i, stats.failed.to_i)

          jobs = {
            adapter: "sidekiq",
            queue_depth: depth.to_i,
            oldest_queued_age_seconds: oldest && oldest.floor,
            workers: ::Sidekiq::ProcessSet.new.size,
            processed_last_5m: processed,
            failed_last_5m: failed,
            recent_processing_at: nil,
            queues: Jobs.optional { queues(stats, latencies) },
            served_queues: Jobs.optional { served_queues },
            classes: nil
          }
          [jobs, nil]
        end

        # Sizes come from one pipelined Stats#queues call; latency (one LINDEX each) is read
        # only for the retained non-empty queues.
        def queues(stats, latencies = {})
          top = stats.queues.map { |name, size| [name.to_s, size.to_i] }
            .sort_by { |name, size| [-size, name] }.first(Jobs::MAX_ENTRIES)
          top.map do |name, size|
            {name: Jobs.clip(name, Jobs::QUEUE_NAME_MAX), depth: size,
             oldest_queued_age_seconds: size.positive? ? (latencies[name] || ::Sidekiq::Queue.new(name).latency.to_f).floor : nil}
          end
        end

        def served_queues
          sets = ::Sidekiq::ProcessSet.new.map { |process| Array(process["queues"]).map(&:to_s) }
          Jobs.served(sets, wildcard: false)
        end

        def deltas(now, processed, failed)
          MUTEX.synchronize do
            SAMPLES.reject! { |t, _, _| now.to_f - t > WINDOW + 60 }
            base = SAMPLES.find { |t, _, _| now.to_f - t >= 30 }
            SAMPLES << [now.to_f, processed, failed]
            SAMPLES.shift while SAMPLES.size > MAX_SAMPLES
            return [nil, nil] unless base && processed >= base[1] && failed >= base[2]

            [processed - base[1], failed - base[2]]
          end
        end
      end
    end
  end
end
