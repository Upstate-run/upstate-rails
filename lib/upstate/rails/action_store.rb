# frozen_string_literal: true

module Upstate
  module Rails
    # Reads and writes per-process rollup files in Dir.tmpdir/upstate-rails/<pid>.json.
    # File shape: {"schema":1,"pid":1,"minutes":{"<epoch minute>":{"Name#action":{...}}}}
    module ActionStore
      BUCKETS = 12
      MAX_AGE = 20 * 60
      MAX_FILE_BYTES = 512 * 1024
      MAX_NAME = 200
      TOP = 10

      module_function

      def dir
        File.join(Dir.tmpdir, "upstate-rails")
      end

      # Atomic: write a temp file in the same directory, then rename over the target.
      def write(pid, minutes, dir: self.dir)
        FileUtils.mkdir_p(dir, mode: 0o700)
        target = File.join(dir, "#{pid}.json")
        tmp = "#{target}.#{SecureRandom.hex(4)}.tmp"
        File.write(tmp, JSON.generate("schema" => 1, "pid" => pid, "minutes" => minutes.transform_keys(&:to_s)), perm: 0o600)
        File.rename(tmp, target)
      ensure
        File.delete(tmp) if tmp && File.exist?(tmp)
      end

      # Merges every live pid file into [{minute: Time, items: [...]}], the last `window`
      # closed minutes, ascending, top TOP items per minute by total time.
      def merged(now: Time.now, window: 15, dir: self.dir)
        current = now.to_i / 60
        range = (current - window)...current
        acc = Hash.new { |h, k| h[k] = {} }

        each_file(now: now, dir: dir) do |data|
          data["minutes"].each do |minute, items|
            m = minute.to_i
            next unless range.cover?(m)

            items.each do |name, e|
              entry = acc[m][name] ||= {count: 0, errors: 0, buckets: Array.new(BUCKETS, 0), db_ms: 0.0, total_ms: 0.0}
              entry[:count] += e["count"]
              entry[:errors] += e["errors"]
              entry[:db_ms] += e["db_ms"]
              entry[:total_ms] += e["total_ms"]
              e["buckets"].each_with_index { |c, i| entry[:buckets][i] += c }
            end
          end
        end

        acc.keys.sort.map do |m|
          top = acc[m].sort_by { |_, e| -e[:total_ms] }.first(TOP)
          {
            minute: Time.at(m * 60).utc,
            items: top.map do |name, e|
              {name: name, count: e[:count], errors: e[:errors], duration_buckets: e[:buckets], db_ms: e[:db_ms].round}
            end
          }
        end
      end

      def each_file(now:, dir:)
        Dir.glob(File.join(dir, "*.json")).each do |path|
          pid = File.basename(path)[/\A(\d+)\.json\z/, 1]&.to_i
          next unless pid
          next if (now.to_i - File.mtime(path).to_i) > MAX_AGE
          next unless alive?(pid)
          next if File.size(path) > MAX_FILE_BYTES

          data = sanitize(JSON.parse(File.read(path)))
          yield data if data
        rescue StandardError
          next
        end
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # Defensive: files are local but not trusted. Keep only well-typed numbers and short names.
      def sanitize(data)
        return unless data.is_a?(Hash) && data["schema"] == 1 && data["minutes"].is_a?(Hash)

        minutes = {}
        data["minutes"].each do |minute, items|
          next unless minute.to_s.match?(/\A\d+\z/) && items.is_a?(Hash)

          clean = {}
          items.each do |name, e|
            next unless name.is_a?(String) && e.is_a?(Hash)

            b = e["buckets"]
            next unless b.is_a?(Array) && b.size == BUCKETS && b.all?(Integer)
            next unless %w[count errors].all? { |k| e[k].is_a?(Integer) } && %w[db_ms total_ms].all? { |k| e[k].is_a?(Numeric) }

            clean[name[0, MAX_NAME]] = e
          end
          minutes[minute] = clean
        end
        {"minutes" => minutes}
      end
    end
  end
end
