# frozen_string_literal: true

require "test_helper"

class JobAdaptersTest < Minitest::Test
  NOW = Time.utc(2026, 10, 21, 20, 0, 0)

  def with_adapter(name, &block)
    ActiveJob::Base.stub(:queue_adapter_name, name, &block)
  end

  def test_none_and_unsupported
    with_adapter("inline") { assert_equal "none", Upstate::Rails::Jobs.call(now: NOW)[0][:adapter] }
    with_adapter("resque") do
      jobs, extra = Upstate::Rails::Jobs.call(now: NOW)
      assert_equal "unsupported", jobs[:adapter]
      assert_nil jobs[:queue_depth]
      assert_nil extra
    end
  end

  def test_solid_queue_and_v0_block
    oldest = NOW - 90
    fakes = {
      "SolidQueue::ReadyExecution" => FakeRelation.new(count: 4, minimum: oldest),
      "SolidQueue::ClaimedExecution" => FakeRelation.new(maximum: NOW - 10),
      "SolidQueue::Job" => FakeRelation.new(count: 42, maximum: NOW - 5),
      "SolidQueue::Process" => FakeRelation.new(count: 2),
      "SolidQueue::FailedExecution" => FakeRelation.new(count: 1)
    }
    with_constants(fakes) do
      with_adapter("solid_queue") do
        jobs, block = Upstate::Rails::Jobs.call(now: NOW)
        assert_equal "solid_queue", jobs[:adapter]
        assert_equal 4, jobs[:queue_depth]
        assert_equal 90, jobs[:oldest_queued_age_seconds]
        assert_equal 2, jobs[:workers]
        assert_equal 42, jobs[:processed_last_5m]
        assert_equal 1, jobs[:failed_last_5m]
        assert_equal (NOW - 5).iso8601, jobs[:recent_processing_at]
        assert_equal %i[oldest_queued_age_seconds queue_depth recent_processing_at workers], block.keys.sort

        _, body = Upstate::Rails::Health.call(now: NOW)
        assert_equal block, body[:solid_queue]
      end
    end
  end

  def test_sidekiq_with_sampled_deltas
    Upstate::Rails::Jobs::SidekiqAdapter.reset_samples!
    stats = Struct.new(:enqueued, :processed, :failed)
    counters = [stats.new(3, 100, 5), stats.new(3, 160, 7)]
    stats_class = Class.new { define_singleton_method(:new) { counters.shift } }
    queue = Struct.new(:name, :latency)
    fakes = {
      "Sidekiq::Stats" => stats_class,
      "Sidekiq::Queue" => Class.new { define_singleton_method(:all) { [queue.new("a", 1.5), queue.new("b", 12.9)] } },
      "Sidekiq::ProcessSet" => Class.new { define_method(:size) { 2 } }
    }
    with_constants(fakes) do
      with_adapter("sidekiq") do
        first, = Upstate::Rails::Jobs.call(now: NOW)
        assert_equal "sidekiq", first[:adapter]
        assert_equal 3, first[:queue_depth]
        assert_equal 12, first[:oldest_queued_age_seconds]
        assert_equal 2, first[:workers]
        assert_nil first[:processed_last_5m]

        second, = Upstate::Rails::Jobs.call(now: NOW + 60)
        assert_equal 60, second[:processed_last_5m]
        assert_equal 2, second[:failed_last_5m]
      end
    end
  end

  def test_good_job
    fakes = {
      "GoodJob::Job" => FakeRelation.new(count: 7, minimum: NOW - 30, maximum: NOW - 2),
      "GoodJob::Process" => FakeRelation.new(count: 3)
    }
    with_constants(fakes) do
      with_adapter("good_job") do
        jobs, extra = Upstate::Rails::Jobs.call(now: NOW)
        assert_equal "good_job", jobs[:adapter]
        assert_equal 7, jobs[:queue_depth]
        assert_equal 30, jobs[:oldest_queued_age_seconds]
        assert_equal 3, jobs[:workers]
        assert_equal 7, jobs[:processed_last_5m]
        assert_equal (NOW - 2).iso8601, jobs[:recent_processing_at]
        assert_nil extra
      end
    end
  end

  def test_solid_queue_queues_served_queues_and_classes
    long = "q" * 300
    process = Struct.new(:metadata)
    fakes = {
      "SolidQueue::ReadyExecution" => FakeRelation.new(count: 4, minimum: NOW - 90,
        grouped: {count: {"default" => 3, long => 1}, minimum: {"default" => NOW - 90}}),
      "SolidQueue::ClaimedExecution" => FakeRelation.new(maximum: NOW - 10),
      "SolidQueue::Job" => FakeRelation.new(count: 42, maximum: NOW - 5,
        grouped: {count: {"A" => 5, "B" => 1, "C" * 300 => 2}}),
      "SolidQueue::Process" => FakeRelation.new(count: 2,
        records: [process.new({"queues" => "default,low*"}), process.new('{"queues":["mail"]}')]),
      "SolidQueue::FailedExecution" => FakeRelation.new(count: 1, grouped: {count: {"B" => 4}})
    }
    with_constants(fakes) do
      with_adapter("solid_queue") do
        jobs, = Upstate::Rails::Jobs.call(now: NOW)
        assert_equal [{name: "default", depth: 3, oldest_queued_age_seconds: 90},
          {name: "q" * 120, depth: 1, oldest_queued_age_seconds: nil}], jobs[:queues]
        assert_equal({all: false, names: ["default", "low*", "mail"]}, jobs[:served_queues])
        assert_equal %w[A B] + ["C" * 200], jobs[:classes].map { |c| c[:name] }.sort_by { |n| [n.size, n] }
        b = jobs[:classes].find { |c| c[:name] == "B" }
        assert_equal({name: "B", processed_last_5m: 1, failed_last_5m: 4, duration_ms_avg: nil, duration_ms_max: nil}, b)
      end
    end
  end

  def test_solid_queue_wildcard_no_workers_and_unknown
    process = Struct.new(:metadata)
    run = lambda do |records|
      fakes = {
        "SolidQueue::ReadyExecution" => FakeRelation.new(count: 0), "SolidQueue::ClaimedExecution" => FakeRelation.new,
        "SolidQueue::Job" => FakeRelation.new, "SolidQueue::FailedExecution" => FakeRelation.new,
        "SolidQueue::Process" => FakeRelation.new(count: 1, records: records)
      }
      with_constants(fakes) { with_adapter("solid_queue") { Upstate::Rails::Jobs.call(now: NOW)[0] } }
    end
    assert_equal true, run.call([process.new({"queues" => "*"})])[:served_queues][:all]
    assert_equal({all: false, names: []}, run.call([])[:served_queues])
    assert_nil run.call([process.new({})])[:served_queues]
    jobs = run.call([])
    assert_nil jobs[:queues]   # unreadable grouped data -> nil
    assert_nil jobs[:classes]
    assert_equal 0, jobs[:queue_depth]
  end

  def test_queue_and_class_caps
    counts = (1..80).to_h { |i| ["queue#{i}", i] }
    entries = Upstate::Rails::Jobs.queue_entries(counts, nil, NOW)
    assert_equal 50, entries.size
    assert_equal "queue80", entries.first[:name]
    rows = (1..80).to_h { |i| ["Job#{i}", {processed: i, failed: 0}] }
    assert_equal 50, Upstate::Rails::Jobs.class_entries(rows).size
  end

  def test_sidekiq_queues_and_served_queues
    Upstate::Rails::Jobs::SidekiqAdapter.reset_samples!
    stats = Struct.new(:enqueued, :processed, :failed, :queues)
    queue = Struct.new(:name, :size, :latency)
    list = [queue.new("low", 0, 0.0), queue.new("default", 3, 12.9)]
    fakes = {
      "Sidekiq::Stats" => Class.new { define_singleton_method(:new) { stats.new(3, 1, 0, {"low" => 0, "default" => 3}) } },
      "Sidekiq::Queue" => Class.new {
        define_singleton_method(:all) { list }
        define_singleton_method(:new) { |name| list.find { |q| q.name == name } }
      },
      "Sidekiq::ProcessSet" => Class.new {
        include Enumerable
        define_method(:size) { 2 }
        define_method(:each) { |&b| [{"queues" => %w[default]}, {"queues" => %w[default low]}].each(&b) }
      }
    }
    with_constants(fakes) do
      with_adapter("sidekiq") do
        jobs, = Upstate::Rails::Jobs.call(now: NOW)
        assert_equal [{name: "default", depth: 3, oldest_queued_age_seconds: 12}, {name: "low", depth: 0, oldest_queued_age_seconds: nil}], jobs[:queues]
        assert_equal({all: false, names: %w[default low]}, jobs[:served_queues])
        assert_nil jobs[:classes]
      end
    end
  end

  def test_good_job_queues_served_queues_and_classes
    process = Struct.new(:state)
    fakes = {
      "GoodJob::Job" => FakeRelation.new(count: 7, minimum: NOW - 30, maximum: NOW - 2,
        grouped: {count: {"Mailer" => 6, "Sync" => 1}, minimum: {"mailers" => NOW - 30}, average: {"Mailer" => 1250.4, "Sync" => nil},
                  maximum: {"Mailer" => 4000.0}}),
      "GoodJob::Process" => FakeRelation.new(count: 1, records: [process.new({"schedulers" => [{"queues" => "mailers:2;*"}]})])
    }
    with_constants(fakes) do
      with_adapter("good_job") do
        jobs, = Upstate::Rails::Jobs.call(now: NOW)
        assert_equal({all: true, names: %w[mailers *]}, jobs[:served_queues])
        assert_equal [{name: "Mailer", processed_last_5m: 6, failed_last_5m: 6, duration_ms_avg: 1250, duration_ms_max: 4000},
          {name: "Sync", processed_last_5m: 1, failed_last_5m: 1, duration_ms_avg: nil, duration_ms_max: nil}], jobs[:classes]
        assert_equal ["Mailer", "Sync"].size, jobs[:classes].size
        assert_equal 2, jobs[:queues].size
      end
    end
  end

  def test_good_job_web_processes_without_schedulers_are_not_workers
    process = Struct.new(:state)
    web = process.new({"schedulers" => []})
    worker = process.new({"schedulers" => [{"queues" => "default"}]})
    [[[web, worker], {all: false, names: ["default"]}], [[web], {all: false, names: []}]].each do |records, expected|
      fakes = {"GoodJob::Job" => FakeRelation.new, "GoodJob::Process" => FakeRelation.new(count: records.size, records: records)}
      with_constants(fakes) do
        with_adapter("good_job") { assert_equal expected, Upstate::Rails::Jobs.call(now: NOW)[0][:served_queues] }
      end
    end
  end

  def test_good_job_blank_queue_string_means_all_queues
    assert_equal ["*"], Upstate::Rails::Jobs.queue_specs("")
    assert_equal ["*"], Upstate::Rails::Jobs.queue_specs(" :5")
  end

  def test_good_job_unknown_state_and_exclusions_are_null
    process = Struct.new(:state)
    [{}, {"schedulers" => [{"queues" => "-mailers"}]}].each do |state|
      fakes = {"GoodJob::Job" => FakeRelation.new, "GoodJob::Process" => FakeRelation.new(count: 1, records: [process.new(state)])}
      with_constants(fakes) do
        with_adapter("good_job") { assert_nil Upstate::Rails::Jobs.call(now: NOW)[0][:served_queues] }
      end
    end
  end

  def test_solid_queue_queue_names_are_literal
    process = Struct.new(:metadata)
    fakes = {
      "SolidQueue::ReadyExecution" => FakeRelation.new, "SolidQueue::ClaimedExecution" => FakeRelation.new,
      "SolidQueue::Job" => FakeRelation.new, "SolidQueue::FailedExecution" => FakeRelation.new,
      "SolidQueue::Process" => FakeRelation.new(records: [process.new({"queues" => " +a:2, -b ,low* "})])
    }
    with_constants(fakes) do
      with_adapter("solid_queue") do
        assert_equal({all: false, names: ["+a:2", "-b", "low*"]}, Upstate::Rails::Jobs.call(now: NOW)[0][:served_queues])
      end
    end
  end

  def test_live_worker_overflow_is_null_for_solid_queue_and_good_job
    sq = Struct.new(:metadata)
    many = Array.new(201) { sq.new({"queues" => "*"}) }
    fakes = {
      "SolidQueue::ReadyExecution" => FakeRelation.new, "SolidQueue::ClaimedExecution" => FakeRelation.new,
      "SolidQueue::Job" => FakeRelation.new, "SolidQueue::FailedExecution" => FakeRelation.new,
      "SolidQueue::Process" => FakeRelation.new(records: many)
    }
    with_constants(fakes) { with_adapter("solid_queue") { assert_nil Upstate::Rails::Jobs.call(now: NOW)[0][:served_queues] } }

    gj = Struct.new(:state)
    # scheduler-less processes would be skipped, but exceeding the cap still means unknown coverage
    many = Array.new(201) { gj.new({"schedulers" => []}) }
    fakes = {"GoodJob::Job" => FakeRelation.new, "GoodJob::Process" => FakeRelation.new(records: many)}
    with_constants(fakes) { with_adapter("good_job") { assert_nil Upstate::Rails::Jobs.call(now: NOW)[0][:served_queues] } }

    exact = Array.new(200) { gj.new({"schedulers" => []}) }
    fakes = {"GoodJob::Job" => FakeRelation.new, "GoodJob::Process" => FakeRelation.new(records: exact)}
    with_constants(fakes) { with_adapter("good_job") { assert_equal({all: false, names: []}, Upstate::Rails::Jobs.call(now: NOW)[0][:served_queues]) } }
  end

  def test_good_job_class_ranking_counts_failures_once
    rows = {"Failing" => {processed: 10, failed: 10}, "Busy" => {processed: 15, failed: 0}}
    assert_equal %w[Busy Failing], Upstate::Rails::Jobs.class_entries(rows, failed_in_processed: true).map { |c| c[:name] }
    assert_equal %w[Failing Busy], Upstate::Rails::Jobs.class_entries(rows).map { |c| c[:name] }
  end

  def test_solid_queue_classes_read_complete_counts_for_the_selected_classes
    jobs = FakeRelation.new(grouped: {count: {"A" => 5}})
    failures = FakeRelation.new(grouped: {count: {"B" => 4}})
    fakes = {
      "SolidQueue::ReadyExecution" => FakeRelation.new, "SolidQueue::ClaimedExecution" => FakeRelation.new,
      "SolidQueue::Job" => jobs, "SolidQueue::FailedExecution" => failures, "SolidQueue::Process" => FakeRelation.new(records: [])
    }
    with_constants(fakes) do
      with_adapter("solid_queue") do
        classes = Upstate::Rails::Jobs.call(now: NOW)[0][:classes]
        assert_equal [{name: "A", processed_last_5m: 5, failed_last_5m: 0}, {name: "B", processed_last_5m: 0, failed_last_5m: 4}],
          classes.map { |c| c.slice(:name, :processed_last_5m, :failed_last_5m) }
      end
    end
    assert_includes jobs.wheres, [{class_name: %w[A B]}]
    assert_includes failures.wheres, [{"solid_queue_jobs" => {class_name: %w[A B]}}]
  end

  def test_good_job_queue_string_parsing
    parse = ->(v) { Upstate::Rails::Jobs.queue_specs(v) }
    assert_equal %w[default +bulk], parse.call("default,+bulk")
    assert_equal %w[default -bulk], parse.call("default,-bulk")
    assert_equal %w[mailers default], parse.call("+  mailers,default")
    assert_nil parse.call("-a,b")
    assert_nil parse.call("x;-a")
    assert_equal %w[a b c], parse.call("a,b:2;+c")
    assert_equal %w[*], parse.call("*")
    assert_nil parse.call(nil)
  end

  def test_good_job_follow_up_queries_are_limited_to_the_ranked_classes
    job = FakeRelation.new(count: 1, grouped: {count: {"A" => 2}, average: {}, maximum: {}})
    with_constants("GoodJob::Job" => job, "GoodJob::Process" => FakeRelation.new(records: [])) do
      with_adapter("good_job") { Upstate::Rails::Jobs.call(now: NOW) }
    end
    assert_includes job.wheres, [{job_class: ["A"]}]
  end

  def test_sidekiq_star_queue_is_a_name_not_a_wildcard_and_latency_is_read_for_the_top_only
    # Depth comes from one pipelined Stats#queues call, latency only for the retained queues.
    queue = Struct.new(:name, :size) do
      def latency = (raise "latency read for #{name}" if size.zero?; 1.0)
    end
    all = [queue.new("empty", 0)] + Array.new(60) { |i| queue.new("q#{i}", 100 + i) }
    Upstate::Rails::Jobs::SidekiqAdapter.reset_samples!
    stats = Struct.new(:enqueued, :processed, :failed, :queues)
    sizes = all.to_h { |q| [q.name, q.size] }
    fakes = {
      "Sidekiq::Stats" => Class.new { define_singleton_method(:new) { stats.new(0, 1, 0, sizes) } },
      "Sidekiq::Queue" => Class.new {
        define_singleton_method(:all) { raise "Queue.all must not be used to rank depth" }
        define_singleton_method(:new) { |name| all.find { |q| q.name == name } }
      },
      "Sidekiq::ProcessSet" => Class.new {
        include Enumerable
        define_method(:size) { 1 }
        define_method(:each) { |&b| [{"queues" => %w[*]}].each(&b) }
      }
    }
    with_constants(fakes) do
      with_adapter("sidekiq") do
        jobs, = Upstate::Rails::Jobs.call(now: NOW)
        assert_equal 50, jobs[:queues].size
        assert_equal({all: false, names: %w[*]}, jobs[:served_queues])
      end
    end
  end

  def test_served_queue_name_overflow_is_unknown
    many = Array.new(101) { |i| "q#{i}" }
    assert_nil Upstate::Rails::Jobs.served([many])
    assert_equal 100, Upstate::Rails::Jobs.served([many.first(100)])[:names].size
  end

  def test_unreachable_store_reports_nil_jobs
    with_adapter("solid_queue") do
      # constants missing -> NameError is a StandardError -> section nil
      _, body = Upstate::Rails::Health.call(now: NOW)
      assert_nil body[:jobs]
    end
  end
end
