# frozen_string_literal: true

require "yaml"
require "erb"
require "pathname"

module Upstate
  module Rails
    module Recurring
      # Solid Queue: tasks come from config/recurring.yml (or SOLID_QUEUE_RECURRING_SCHEDULE),
      # under the current Rails environment key when the file has one, the same way Solid Queue
      # reads it. Runs come from solid_queue_recurring_executions and the job rows they point
      # at, so they are visible from any container, not only the worker's.
      module SolidQueueSource
        WINDOW = 24 * 3600
        RUNS_PER_TASK = 10
        MAX_RUNNING = 100
        MAX_TASKS = 100

        module_function

        def call(now: Time.now)
          list = tasks
          return {adapter: "solid_queue", tasks: nil, runs: []} if list.nil?

          {adapter: "solid_queue", tasks: list, runs: runs(list.map { |t| t[:key] }, now)}
        end

        def schedule_path
          configured = ENV["SOLID_QUEUE_RECURRING_SCHEDULE"].to_s.strip
          root = ::Rails.root || Pathname(Dir.pwd)
          root.join(configured.empty? ? "config/recurring.yml" : configured)
        end

        # => [{key:, class_name:, schedule:, interval_seconds:}] or nil when unreadable.
        def tasks(path: schedule_path, env: ::Rails.env.to_s)
          return nil unless File.file?(path)

          data = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true, permitted_classes: [Symbol])
          return nil unless data.is_a?(Hash)

          scoped = data[env].is_a?(Hash) ? data[env] : nil
          entries = scoped || data
          list = entries.filter_map { |key, entry| task(key, entry) }.first(MAX_TASKS)
          # A file with only other environments' sections is not a schedule for this one.
          return nil if scoped.nil? && list.empty? && !entries.empty?

          list
        rescue StandardError, Psych::Exception, ScriptError
          nil
        end

        # Only key, class and schedule are read from an entry; args and command never are.
        def task(key, entry)
          return unless entry.is_a?(Hash)

          schedule = entry["schedule"]
          return unless schedule.is_a?(String) && !schedule.strip.empty?

          class_name = entry["class"]
          {
            key: key.to_s,
            class_name: class_name.is_a?(String) ? class_name : nil,
            schedule: schedule.strip,
            interval_seconds: interval_seconds(schedule.strip)
          }
        end

        # Longest gap over the next runs, via Fugit (a Solid Queue dependency) when present.
        def interval_seconds(schedule, from: Time.now)
          return unless defined?(::Fugit)

          parsed = ::Fugit.parse(schedule)
          if parsed.respond_to?(:next_time)
            times = [from]
            12.times { times << parsed.next_time(times.last).to_t }
            times.each_cons(2).map { |a, b| (b - a).to_i }.max
          elsif parsed.respond_to?(:to_sec)
            parsed.to_sec.to_i
          end
        rescue StandardError
          nil
        end

        # Recent runs of the given recurring tasks. Per task, three independent bounded reads,
        # none of which depends on the order executions were enqueued in:
        #   * runs still going: every claimed execution of the task (bounded by what is
        #     actually executing, capped at MAX_RUNNING), at any age;
        #   * finished jobs, newest RUNS_PER_TASK by finish time inside WINDOW;
        #   * failed jobs, newest RUNS_PER_TASK by failure time inside WINDOW.
        # The finished and failed reads are merged and cut to RUNS_PER_TASK by end time.
        def runs(keys, now)
          return [] if keys.empty? || !defined?(::SolidQueue::RecurringExecution)

          since = now - WINDOW
          keys.flat_map { |key| task_runs(key, since) }
        rescue StandardError
          []
        end

        def task_runs(key, since)
          job_ids = ::SolidQueue::RecurringExecution.where(task_key: key).select(:job_id)

          running = ::SolidQueue::ClaimedExecution.where(job_id: job_ids)
            .order(created_at: :desc).limit(MAX_RUNNING).pluck(:job_id, :created_at)
          done = ::SolidQueue::Job.where(id: job_ids).where(finished_at: since..)
            .order(finished_at: :desc).limit(RUNS_PER_TASK).pluck(:id, :finished_at)
          failed = ::SolidQueue::FailedExecution.where(job_id: job_ids).where(created_at: since..)
            .order(created_at: :desc).limit(RUNS_PER_TASK).pluck(:job_id, :created_at)

          ended = failed.map { |id, at| run(key, id, nil, at, nil) } +
            done.map { |id, at| run(key, id, at, nil, nil) }
          ended = ended.compact.uniq { |r| r[:run_id] }.sort_by { |r| r[:finished_at] }.reverse
          going = running.filter_map { |id, at| run(key, id, nil, nil, at) }

          going + ended.reject { |r| going.any? { |g| g[:run_id] == r[:run_id] } }.first(RUNS_PER_TASK)
        end

        # failed -> fail (at the failure), finished -> success, claimed -> running (since the
        # claim). A job still waiting to be claimed has not started and is not reported.
        # Solid Queue keeps no start time once a job finishes, so only a running job has one.
        def run(key, job_id, finished_at, failed_at, claimed_at)
          base = {key: key, run_id: "sq-#{job_id}", started_at: nil, finished_at: nil}
          if failed_at
            base.merge(finished_at: iso(failed_at), result: "fail")
          elsif finished_at
            base.merge(finished_at: iso(finished_at), result: "success")
          elsif claimed_at
            base.merge(started_at: iso(claimed_at), result: "running")
          end
        end

        def iso(time)
          time.utc.iso8601
        end
      end
    end
  end
end
