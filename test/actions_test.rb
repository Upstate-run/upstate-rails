# frozen_string_literal: true

require "test_helper"

class ActionsTest < Minitest::Test
  Rollup = Upstate::Rails::ActionRollup
  Store = Upstate::Rails::ActionStore
  T0 = Time.utc(2026, 10, 21, 20, 0, 10)

  def setup
    @dir = Dir.mktmpdir("upstate-actions")
    @now = T0
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def rollup
    @rollup ||= Rollup.new(clock: -> { @now }, dir: @dir)
  end

  def pid_file(pid, minutes, age: 0)
    path = File.join(@dir, "#{pid}.json")
    File.write(path, JSON.generate("schema" => 1, "pid" => pid, "minutes" => minutes))
    File.utime(T0 - age, T0 - age, path)
  end

  def entry(count: 1, errors: 0, bucket: 0, total: 10.0)
    buckets = Array.new(12, 0)
    buckets[bucket] = count
    {"count" => count, "errors" => errors, "buckets" => buckets, "db_ms" => 2.0, "total_ms" => total}
  end

  def test_bucket_boundaries_are_upper_inclusive
    idx = Rollup.method(:bucket_index)
    assert_equal 0, idx.call(0)
    assert_equal 0, idx.call(5)
    assert_equal 1, idx.call(5.01)
    assert_equal 1, idx.call(10)
    assert_equal 2, idx.call(25)
    assert_equal 7, idx.call(1000)
    assert_equal 8, idx.call(1000.1)
    assert_equal 10, idx.call(10_000)
    assert_equal 11, idx.call(10_000.1)
    assert_equal 12, Upstate::Rails::ActionStore::BUCKETS
  end

  def test_record_counts_and_error_without_class
    Upstate::Rails.rollup = rollup
    Upstate::Rails.subscribe!
    begin
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "PostsController", action: "show", status: 200, db_runtime: 3.0, path: "/posts/9?secret=1") {}
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "PostsController", action: "show", status: 500, exception: ["RuntimeError", "very secret message"]) {}
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "PostsController", action: "show", status: nil, exception_object: RuntimeError.new("x")) {}
    ensure
      Upstate::Rails.unsubscribe!
    end

    @now += 60
    closed = rollup.snapshot_closed
    e = closed.values.first.fetch("PostsController#show")
    assert_equal 3, e["count"]
    assert_equal 2, e["errors"]
    assert_equal 3, e["buckets"].sum
    assert_equal 3.0, e["db_ms"]
    assert_equal %w[buckets count db_ms errors total_ms], e.keys.sort
    refute_includes JSON.generate(closed), "RuntimeError"
    refute_includes JSON.generate(closed), "secret"
  end

  def test_only_top_10_by_total_time_per_minute
    15.times { |i| rollup.record("C#a#{i}", (i + 1) * 10.0, 0, false) }
    @now += 60
    names = rollup.snapshot_closed.values.first.keys
    assert_equal 10, names.size
    assert_includes names, "C#a14"
    refute_includes names, "C#a0"
  end

  def test_memory_is_bounded
    (Rollup::MAX_NAMES_PER_MINUTE + 50).times { |i| rollup.record("C#a#{i}", 1.0, 0, false) }
    assert_operator rollup.instance_variable_get(:@minutes).values.first.size, :<=, Rollup::MAX_NAMES_PER_MINUTE
    40.times do
      @now += 60
      rollup.record("C#a", 1.0, 0, false)
    end
    assert_operator rollup.instance_variable_get(:@minutes).size, :<=, Rollup::RETAIN_MINUTES + 1
  end

  def test_flush_is_atomic_throttled_and_closed_minutes_only
    rollup.record("C#a", 1.0, 0, false)
    refute File.exist?(File.join(@dir, "#{Process.pid}.json")), "open minute must not be written"

    @now += 60
    rollup.record("C#b", 1.0, 0, false) # closes minute 1, opens minute 2 -> flush
    path = File.join(@dir, "#{Process.pid}.json")
    assert File.exist?(path)
    assert_empty Dir.glob(File.join(@dir, "*.tmp"))
    written = JSON.parse(File.read(path))["minutes"]
    assert_equal 1, written.size
    assert_equal ["C#a"], written.values.first.keys

    mtime = File.mtime(path)
    rollup.record("C#b", 1.0, 0, false)
    assert_equal mtime, File.mtime(path), "no disk IO on every request"
  end

  def test_merge_across_simulated_pids
    minute = T0.to_i / 60 - 1
    pid_file(Process.pid, {minute.to_s => {"A#x" => entry(count: 2, errors: 1, bucket: 3, total: 20.0)}})
    parent = Process.ppid
    pid_file(parent, {minute.to_s => {"A#x" => entry(count: 3, bucket: 3, total: 30.0), "B#y" => entry(total: 5.0)}})

    merged = Store.merged(now: T0, dir: @dir)
    assert_equal 1, merged.size
    assert_equal Time.at(minute * 60).utc, merged.first[:minute]
    x = merged.first[:items].find { |i| i[:name] == "A#x" }
    assert_equal 5, x[:count]
    assert_equal 1, x[:errors]
    assert_equal 5, x[:duration_buckets][3]
    assert_equal 4, x[:db_ms]
    assert_equal %w[A#x B#y], merged.first[:items].map { |i| i[:name] }
  end

  def test_dead_pid_old_files_and_open_or_old_minutes_ignored
    minute = T0.to_i / 60 - 1
    dead = spawn_dead_pid
    pid_file(dead, {minute.to_s => {"Dead#a" => entry}})
    pid_file(Process.pid, {minute.to_s => {"Stale#a" => entry}}, age: 21 * 60)
    pid_file(Process.ppid, {
      minute.to_s => {"Live#a" => entry},
      (T0.to_i / 60).to_s => {"Open#a" => entry},
      (T0.to_i / 60 - 16).to_s => {"Old#a" => entry}
    })
    File.write(File.join(@dir, "garbage.json"), "{")
    File.write(File.join(@dir, "#{Process.pid + 1}.json"), "{not json")

    names = Store.merged(now: T0, dir: @dir).flat_map { |m| m[:items].map { |i| i[:name] } }
    assert_equal ["Live#a"], names
  end

  def test_malformed_content_is_dropped
    minute = (T0.to_i / 60 - 1).to_s
    pid_file(Process.pid, {minute => {"Bad#a" => {"count" => "9", "errors" => 0, "buckets" => [1], "db_ms" => 0, "total_ms" => 0}}})
    assert_empty Store.merged(now: T0, dir: @dir)
  end

  def spawn_dead_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end
end
