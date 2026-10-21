# frozen_string_literal: true

require "fileutils"

module Upstate
  module Rails
    # Per-process, thread-safe, bounded rollup of controller actions per minute.
    # Stores only: name, count, error count, duration buckets, db ms, total ms.
    class ActionRollup
      # Upper bounds in ms, inclusive; the 12th bucket is +inf.
      BUCKETS_MS = [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000].freeze
      MAX_NAMES_PER_MINUTE = 200
      RETAIN_MINUTES = 20
      FLUSH_INTERVAL = 5

      def self.bucket_index(ms)
        BUCKETS_MS.index { |upper| ms <= upper } || BUCKETS_MS.size
      end

      def initialize(clock: -> { Time.now }, dir: ActionStore.dir)
        @clock = clock
        @dir = dir
        @mutex = Mutex.new
        reset!
      end

      def record(name, duration_ms, db_ms, error)
        @mutex.synchronize do
          reset! if @pid != Process.pid # forked (Puma cluster, preload_app)
          now = @clock.call
          minute = now.to_i / 60
          names = (@minutes[minute] ||= {})
          entry = names[name] || (names.size < MAX_NAMES_PER_MINUTE ? (names[name] = blank) : nil)
          if entry
            entry[:count] += 1
            entry[:errors] += 1 if error
            entry[:buckets][self.class.bucket_index(duration_ms.to_f)] += 1
            entry[:db_ms] += db_ms.to_f
            entry[:total_ms] += duration_ms.to_f
          end
          @minutes.delete_if { |m, _| m < minute - RETAIN_MINUTES }
          flush_locked(now, force: false)
        end
      rescue StandardError
        nil
      end

      # Writes closed minutes to disk. force: skips the interval throttle.
      def flush!(force: true)
        @mutex.synchronize { flush_locked(@clock.call, force: force) }
      rescue StandardError
        nil
      end

      def snapshot_closed(now = @clock.call)
        current = now.to_i / 60
        @mutex.synchronize do
          @minutes.select { |m, _| m < current }.transform_values { |names| top(names) }
        end
      end

      private

      def reset!
        @pid = Process.pid
        @minutes = {}
        @flushed_through = nil
        @last_flush = 0
      end

      def blank
        {count: 0, errors: 0, buckets: Array.new(ActionStore::BUCKETS, 0), db_ms: 0.0, total_ms: 0.0}
      end

      def top(names)
        names.sort_by { |_, e| -e[:total_ms] }.first(ActionStore::TOP).to_h.transform_values do |e|
          {"count" => e[:count], "errors" => e[:errors], "buckets" => e[:buckets],
           "db_ms" => e[:db_ms].round(1), "total_ms" => e[:total_ms].round(1)}
        end
      end

      # Disk IO only when a new minute has closed since the last write, and at most
      # once per FLUSH_INTERVAL seconds.
      def flush_locked(now, force:)
        current = now.to_i / 60
        closed = @minutes.keys.select { |m| m < current }
        return if closed.empty?

        latest = closed.max
        return if !force && (@flushed_through == latest || (now.to_f - @last_flush) < FLUSH_INTERVAL)
        return if force && @flushed_through == latest

        payload = closed.to_h { |m| [m, top(@minutes[m])] }
        ActionStore.write(Process.pid, payload, dir: @dir)
        @flushed_through = latest
        @last_flush = now.to_f
      end
    end
  end
end
