# frozen_string_literal: true

module Upstate
  module Rails
    module Jobs
      # Uses GoodJob's tables (GoodJob 3+/4: GoodJob::Job, GoodJob::Process).
      module GoodJobAdapter
        module_function

        def call(now: Time.now)
          queued = ::GoodJob::Job.where(finished_at: nil, performed_at: nil, scheduled_at: ..now)
          oldest = queued.minimum(:scheduled_at)
          since = now - 300
          finished = ::GoodJob::Job.where(finished_at: since..)
          recent = [::GoodJob::Job.maximum(:performed_at), ::GoodJob::Job.maximum(:finished_at)].compact.max

          jobs = {
            adapter: "good_job",
            queue_depth: queued.count,
            oldest_queued_age_seconds: oldest && [now.to_i - oldest.to_i, 0].max,
            workers: ::GoodJob::Process.where(updated_at: (now - 120)..).count,
            processed_last_5m: finished.count,
            failed_last_5m: finished.where.not(error: nil).count,
            recent_processing_at: recent&.utc&.iso8601,
            queues: Jobs.optional { queues(queued, now) },
            served_queues: Jobs.optional { served_queues(now) },
            classes: Jobs.optional { classes(finished) }
          }
          [jobs, nil]
        end

        DURATION_MS = "EXTRACT(EPOCH FROM (good_jobs.finished_at - good_jobs.performed_at)) * 1000"

        def queues(queued, now)
          counts = queued.group(:queue_name).order(Arel.sql("count(*) DESC")).limit(Jobs::MAX_ENTRIES).count
          oldest = queued.where(queue_name: counts.keys).group(:queue_name).minimum(:scheduled_at)
          Jobs.queue_entries(counts, oldest, now)
        end

        # Queue strings in each live scheduler's state ("*", "a,b", "a:2;b"); null when any
        # worker's state is unreadable. Processes with no schedulers (a web process in external
        # mode) execute nothing and are skipped. Liveness uses GoodJob's own `active` scope
        # (advisory lock or a recent heartbeat) when available.
        def served_queues(now)
          scope = ::GoodJob::Process.respond_to?(:active) ? ::GoodJob::Process.active : ::GoodJob::Process.where(updated_at: (now - 120)..)
          processes = Jobs.capped_processes(scope)
          return nil unless processes

          Jobs.served(processes.map { |process| process_queues(process) }.reject { |list| list == :none })
        end

        def process_queues(process)
          state = process.state
          state = JSON.parse(state) if state.is_a?(String)
          schedulers = state.is_a?(Hash) ? (state["schedulers"] || state[:schedulers]) : nil
          return nil unless schedulers.is_a?(Array)
          return :none if schedulers.empty?

          lists = schedulers.map { |s| Jobs.queue_specs((s["queues"] || s[:queues]) || nil) }
          lists.any?(&:nil?) ? nil : lists.flatten
        end

        def classes(finished)
          # Failed jobs are finished jobs with an error, so the finished count already includes them.
          grouped = finished.group(:job_class)
          processed = grouped.order(Arel.sql("count(*) DESC")).limit(Jobs::MAX_ENTRIES).count
          names = processed.keys
          failed = finished.where(job_class: names).where.not(error: nil).group(:job_class).count
          timed = finished.where(job_class: names).where.not(performed_at: nil).group(:job_class)
          avg = timed.average(Arel.sql(DURATION_MS))
          max = timed.maximum(Arel.sql(DURATION_MS))
          rows = processed.keys.to_h do |name|
            [name, {processed: processed[name], failed: failed[name], avg: avg[name], max: max[name]}]
          end
          Jobs.class_entries(rows, failed_in_processed: true)
        end
      end
    end
  end
end
