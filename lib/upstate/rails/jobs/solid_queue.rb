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
            failed_last_5m: ::SolidQueue::FailedExecution.where(created_at: since..).count
          )
          [jobs, block]
        end
      end
    end
  end
end
