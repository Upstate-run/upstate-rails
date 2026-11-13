# frozen_string_literal: true

require "test_helper"

class RecurringTest < Minitest::Test
  NOW = Time.utc(2026, 11, 12, 12, 0, 0)
  Source = Upstate::Rails::Recurring::SolidQueueSource

  YAML_FILE = <<~YAML
    default: &default
      nightly_cleanup:
        class: CleanupJob
        args: ["SECRET-JOB-ARG", 42]
        schedule: every day at 3am
        queue: background
      command_task:
        command: "User.delete_all"
        schedule: "*/15 * * * *"
      not_a_task:
        queue: background
    production:
      nightly_cleanup:
        class: CleanupJob
        args: ["SECRET-JOB-ARG", 42]
        schedule: "0 3 * * *"
      hourly_sync:
        class: Sync::PullJob
        schedule: "<%= '0 * * * *' %>"
    development:
      dev_only:
        class: DevJob
        schedule: "* * * * *"
  YAML

  def with_schedule(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "recurring.yml")
      File.write(path, content) if content
      yield path
    end
  end

  def test_reads_the_current_environment_and_sends_only_key_class_and_schedule
    with_schedule(YAML_FILE) do |path|
      tasks = Source.tasks(path: path, env: "production")

      assert_equal %w[nightly_cleanup hourly_sync], tasks.map { |t| t[:key] }
      assert_equal ["CleanupJob", "Sync::PullJob"], tasks.map { |t| t[:class_name] }
      assert_equal ["0 3 * * *", "0 * * * *"], tasks.map { |t| t[:schedule] }
      tasks.each { |t| assert_equal %i[class_name interval_seconds key schedule], t.keys.sort }

      serialized = JSON.generate(tasks)
      refute_includes serialized, "SECRET-JOB-ARG"
      refute_includes serialized, "delete_all"
      refute_includes serialized, "background"
    end
  end

  def test_a_file_with_only_other_environments_is_not_a_schedule_for_this_one
    content = "production:\n  a:\n    class: A\n    schedule: '0 * * * *'\ntest:\n  b:\n    schedule: '0 * * * *'\n"
    with_schedule(content) { |path| assert_nil Source.tasks(path: path, env: "staging") }
  end

  def test_missing_or_broken_files_report_no_schedule
    assert_nil Source.tasks(path: "/nonexistent/recurring.yml", env: "production")
    with_schedule("production: [unclosed") { |path| assert_nil Source.tasks(path: path, env: "production") }
    with_schedule("") { |path| assert_nil Source.tasks(path: path, env: "production") }
    # Malformed ERB raises SyntaxError (a ScriptError), which must fail closed too.
    with_schedule("production:\n  a:\n    schedule: \"<%= if %>\"\n") do |path|
      assert_nil Source.tasks(path: path, env: "production")
    end
  end

  def test_empty_environment_section_is_an_empty_schedule
    with_schedule("production: {}\n") { |path| assert_equal [], Source.tasks(path: path, env: "production") }
    with_schedule("production:\n  only:\n    schedule: '* * * * *'\n") do |path|
      assert_equal 1, Source.tasks(path: path, env: "production").size
    end
  end

  def test_schedule_file_can_be_overridden
    with_schedule(YAML_FILE) do |path|
      with_env("SOLID_QUEUE_RECURRING_SCHEDULE" => path) do
        assert_equal path, Source.schedule_path.to_s
      end
    end
  end

  def test_fugit_interval_when_available
    begin
      require "fugit"
    rescue LoadError
      skip "fugit not installed"
    end

    assert_equal 300, Source.interval_seconds("*/5 * * * *", from: NOW)
    assert_equal 3600, Source.interval_seconds("every hour", from: NOW)
  end

  def test_run_states
    assert_equal({key: "k", run_id: "sq-1", started_at: nil, finished_at: "2026-11-12T11:00:00Z", result: "success"},
      Source.run("k", 1, Time.utc(2026, 11, 12, 11), nil, nil))
    failed = Source.run("k", 2, nil, Time.utc(2026, 11, 12, 11, 1), nil)
    assert_equal "fail", failed[:result]
    running = Source.run("k", 3, nil, nil, Time.utc(2026, 11, 12, 11, 2))
    assert_equal "running", running[:result]
    assert_equal "2026-11-12T11:02:00Z", running[:started_at]
    assert_nil running[:finished_at]
    assert_nil Source.run("k", 4, nil, nil, nil)
  end

  # A tiny in-memory relation that really applies where/order/limit (so the source's limits
  # are exercised), over rows given as hashes.
  class Rel
    attr_reader :plucked

    def initialize(rows, column_log = nil)
      @rows = rows
      @log = column_log || []
    end

    def where(conditions)
      rows = @rows.select do |row|
        conditions.all? do |col, cond|
          v = row[col]
          case cond
          when Range then !v.nil? && cond.cover?(v)
          when Rel then cond.values(:job_id).include?(v)
          else v == cond
          end
        end
      end
      Rel.new(rows, @log)
    end

    def order(spec)
      col, dir = spec.first
      sorted = @rows.sort_by { |r| r[col] }
      Rel.new(dir == :desc ? sorted.reverse : sorted, @log)
    end

    def limit(n) = Rel.new(@rows.first(n), @log)

    def select(*) = self

    def values(col) = @rows.map { |r| r[col] }

    def pluck(*cols)
      @log << cols
      @rows.map { |r| cols.map { |c| r[c] } }
    end
  end

  def solid_queue(executions: [], jobs: [], failed: [], claimed: [])
    log = []
    {
      "SolidQueue::RecurringExecution" => Rel.new(executions, log),
      "SolidQueue::Job" => Rel.new(jobs, log),
      "SolidQueue::FailedExecution" => Rel.new(failed, log),
      "SolidQueue::ClaimedExecution" => Rel.new(claimed, log)
    }.tap { |h| h.define_singleton_method(:log) { log } }
  end

  def test_runs_never_select_job_arguments_and_report_each_state
    fakes = solid_queue(
      executions: [11, 12, 13].map { |id| {task_key: "k", job_id: id} },
      jobs: [{id: 11, finished_at: NOW - 590}],
      failed: [{job_id: 12, created_at: NOW - 290}],
      claimed: [{job_id: 13, created_at: NOW - 55}]
    )

    with_constants(fakes) do
      runs = Source.runs(["k"], NOW)
      assert_equal %w[running fail success], runs.map { |r| r[:result] }
      assert_equal %w[sq-13 sq-12 sq-11], runs.map { |r| r[:run_id] }
    end

    refute_includes fakes.log.flatten.map(&:to_s), "arguments"
  end

  def test_a_running_job_survives_far_more_than_the_row_limit_of_newer_executions
    executions = (1..200).map { |id| {task_key: "k", job_id: id} }
    # Job 1 still runs; jobs 2..200 finished, 199 more than any per-task limit.
    jobs = (2..200).map { |id| {id: id, finished_at: NOW - (300 - id) * 60} }
    fakes = solid_queue(executions: executions, jobs: jobs,
      claimed: [{job_id: 1, created_at: NOW - 6000}])

    with_constants(fakes) do
      runs = Source.runs(["k"], NOW)
      assert_equal "sq-1", runs.first[:run_id]
      assert_equal "running", runs.first[:result]
      finished = runs.drop(1)
      assert_equal 10, finished.size
      # The ten newest by completion time, not by enqueue order.
      assert_equal (191..200).map { |i| "sq-#{i}" }.sort, finished.map { |r| r[:run_id] }.sort
    end
  end

  def test_an_old_execution_that_just_finished_is_among_the_newest_completions
    executions = (1..100).map { |id| {task_key: "k", job_id: id} }
    jobs = (2..100).map { |id| {id: id, finished_at: NOW - 3600 - id * 60} }
    jobs << {id: 1, finished_at: NOW - 30}
    fakes = solid_queue(executions: executions, jobs: jobs)

    with_constants(fakes) do
      runs = Source.runs(["k"], NOW)
      assert_equal "sq-1", runs.first[:run_id]
      assert_equal 10, runs.size
    end
  end

  def test_finished_long_ago_is_dropped
    fakes = solid_queue(
      executions: [{task_key: "k", job_id: 1}],
      jobs: [{id: 1, finished_at: NOW - 39 * 3600}]
    )
    with_constants(fakes) { assert_equal [], Source.runs(["k"], NOW) }
  end

  def test_rows_are_read_per_task_so_a_frequent_task_cannot_hide_another
    executions = (1..300).map { |id| {task_key: "busy", job_id: id} } + [{task_key: "daily", job_id: 999}]
    jobs = (1..300).map { |id| {id: id, finished_at: NOW - id} } + [{id: 999, finished_at: NOW - 7200}]
    with_constants(solid_queue(executions: executions, jobs: jobs)) do
      runs = Source.runs(%w[busy daily], NOW)
      assert_includes runs.map { |r| r[:run_id] }, "sq-999"
      assert_equal 10, runs.count { |r| r[:key] == "busy" }
    end
  end

  def test_runs_fail_closed
    with_constants("SolidQueue::RecurringExecution" => Object.new) do
      assert_equal [], Source.runs(["a"], NOW)
    end
  end

  def test_health_includes_recurring_only_when_a_schedule_is_readable
    section = {adapter: "solid_queue", tasks: [], runs: []}
    ActiveJob::Base.stub(:queue_adapter_name, "solid_queue") do
      Source.stub(:call, section) do
        assert_equal section, Upstate::Rails::Recurring.call(now: NOW)
      end

      Source.stub(:call, {adapter: "solid_queue", tasks: nil, runs: []}) do
        assert_nil Upstate::Rails::Recurring.call(now: NOW)
      end
    end

    ActiveJob::Base.stub(:queue_adapter_name, "sidekiq") do
      assert_nil Upstate::Rails::Recurring.call(now: NOW)
    end

    _, body = Upstate::Rails::Health.call(now: NOW)
    refute body.key?(:recurring)
  end
end
