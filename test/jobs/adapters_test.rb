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
    queue = Struct.new(:latency)
    fakes = {
      "Sidekiq::Stats" => stats_class,
      "Sidekiq::Queue" => Class.new { define_singleton_method(:all) { [queue.new(1.5), queue.new(12.9)] } },
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

  def test_unreachable_store_reports_nil_jobs
    with_adapter("solid_queue") do
      # constants missing -> NameError is a StandardError -> section nil
      _, body = Upstate::Rails::Health.call(now: NOW)
      assert_nil body[:jobs]
    end
  end
end
