# frozen_string_literal: true

module Upstate
  module Rails
    module Jobs
      # Uses the Solid Queue tables (the same queries as the v0 controller).
      module SolidQueueAdapter
        module_function

        def call(now: Time.now)
          ready = ::SolidQueue::ReadyExecution
          oldest = ready.minimum(:created_at)
          recent_claim = ::SolidQueue::ClaimedExecution.maximum(:created_at)
          recent_finish = ::SolidQueue::Job.where.not(finished_at: nil).maximum(:finished_at)
          recent = [recent_claim, recent_finish].compact.max
          since = now - 300

          block = {
            workers: ::SolidQueue::Process.where(kind: "Worker").where(last_heartbeat_at: (now - 120)..).count,
            queue_depth: ready.count,
            oldest_queued_age_seconds: oldest && [now.to_i - oldest.to_i, 0].max,
            recent_processing_at: recent&.utc&.iso8601
          }

          jobs = block.merge(
            adapter: "solid_queue",
            processed_last_5m: ::SolidQueue::Job.where(finished_at: since..).count,
            failed_last_5m: ::SolidQueue::FailedExecution.where(created_at: since..).count,
            queues: Jobs.optional { queues(now) },
            served_queues: Jobs.optional { served_queues(now) },
            classes: Jobs.optional { classes(since) }
          )
          [jobs, block]
        end

        def queues(now)
          ready = ::SolidQueue::ReadyExecution
          counts = ready.group(:queue_name).order(Arel.sql("count(*) DESC")).limit(Jobs::MAX_ENTRIES).count
          oldest = ready.where(queue_name: counts.keys).group(:queue_name).minimum(:created_at)
          Jobs.queue_entries(counts, oldest, now)
        end

        def served_queues(now)
          threshold = ::SolidQueue.respond_to?(:process_alive_threshold) ? ::SolidQueue.process_alive_threshold.to_f : 300
          processes = Jobs.capped_processes(::SolidQueue::Process.where(kind: "Worker").where(last_heartbeat_at: (now - threshold)..))
          return nil unless processes

          Jobs.served(processes.map { |process| queue_specs(metadata(process)["queues"]) })
        end

        # Solid Queue treats names literally ("low*" is a prefix wildcard, "*" is all); only
        # commas separate them.
        def queue_specs(value)
          return nil if value.nil?

          names = (value.is_a?(Array) ? value : value.to_s.split(",")).map { |n| n.to_s.strip }.reject(&:empty?)
          names.empty? ? nil : names
        end

        def metadata(process)
          value = process.metadata
          value = JSON.parse(value) if value.is_a?(String)
          value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
        end

        # Candidates are the busiest classes in each source; the counts for the chosen classes
        # are then read completely from both, so a class never shows a missing side as 0.
        def classes(since)
          jobs = ::SolidQueue::Job.where(finished_at: since..)
          failures = ::SolidQueue::FailedExecution.where(created_at: since..).joins(:job)
          failed_column = "#{::SolidQueue::Job.table_name}.class_name"
          top = Jobs::MAX_ENTRIES
          candidates = jobs.group(:class_name).order(Arel.sql("count(*) DESC")).limit(top).count.keys |
            failures.group(failed_column).order(Arel.sql("count(*) DESC")).limit(top).count.keys
          finished = jobs.where(class_name: candidates).group(:class_name).count
          failed = failures.where(::SolidQueue::Job.table_name => {class_name: candidates}).group(failed_column).count
          rows = candidates.to_h { |name| [name, {processed: finished[name], failed: failed[name]}] }
          Jobs.class_entries(rows)
        end
      end
    end
  end
end
