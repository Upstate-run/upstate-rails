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
            recent_processing_at: recent&.utc&.iso8601
          }
          [jobs, nil]
        end
      end
    end
  end
end
