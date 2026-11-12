# frozen_string_literal: true

require "test_helper"

class HealthTest < Minitest::Test
  def with_migrations
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "20260101000000_create_things.rb"), <<~RUBY)
        class CreateThings < ActiveRecord::Migration[7.1]
          def change = create_table(:things)
        end
      RUBY
      old = ActiveRecord::Migrator.migrations_paths
      ActiveRecord::Migrator.migrations_paths = [dir]
      yield
    ensure
      ActiveRecord::Migrator.migrations_paths = old
    end
  end

  def test_response_shape
    status, body = Upstate::Rails::Health.call
    assert_equal 200, status
    assert_equal %i[schema version rails ruby booted_at database active_record_pool puma jobs cache actions].sort, body.keys.sort
    assert_equal 1, body[:schema]
    assert_equal ::Rails.version, body[:rails][:version]
    assert_equal "test", body[:rails][:environment]
    assert_equal RUBY_VERSION, body[:ruby][:version]
    assert_includes [true, false], body[:ruby][:yjit]
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, body[:booted_at])
    assert_equal %i[busy size waiting], body[:active_record_pool].keys.sort
    assert_equal true, body[:database][:ok]
    assert_nil body[:puma]
    assert_equal "none", body[:jobs][:adapter]
    assert_nil body[:cache]
    assert_equal [], body[:actions]
    refute body.key?(:solid_queue)
  end

  def test_version_precedence
    with_env("APP_VERSION" => "v1", "KAMAL_VERSION" => "k1") { assert_equal "v1", Upstate::Rails::Health.call[1][:version] }
    with_env("APP_VERSION" => nil, "KAMAL_VERSION" => "k1") { assert_equal "k1", Upstate::Rails::Health.call[1][:version] }
    with_env("APP_VERSION" => "", "KAMAL_VERSION" => nil) { assert_equal "unknown", Upstate::Rails::Health.call[1][:version] }
  end

  def test_pending_migrations_true_then_false
    with_migrations do
      assert_equal true, Upstate::Rails::Health.call[1][:database][:pending_migrations]
      ActiveRecord::Base.connection_pool.migration_context.migrate
      assert_equal false, Upstate::Rails::Health.call[1][:database][:pending_migrations]
    end
  end

  # Answers the reporter's three queries by SQL text; a value that is an Exception raises.
  class FakePgConnection
    attr_reader :statements

    def initialize(adapter_name, answers)
      @adapter_name = adapter_name
      @answers = answers
      @statements = []
    end

    attr_reader :adapter_name

    def transaction(requires_new: false)
      yield
    end

    def execute(sql)
      @statements << sql
    end

    def select_rows(sql)
      @statements << sql
      key = if sql.include?("pg_stat_replication") then :replicas
      elsif sql.include?("pg_stat_user_tables") then :tables
      else :summary
      end
      answer = @answers.fetch(key)
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  FakePool = Struct.new(:connection) do
    def with_connection
      yield connection
    end
  end

  PRIMARY = [[1_342_177_280, 12, 100, 0, 1, 48_211_934, false, nil]].freeze
  TABLES = [["public.events", 812_646_400, 4_210_000, 1_200], ["public.users", 1_000, 10, 0]].freeze

  def with_fake_connection(connection, &block)
    ActiveRecord::Base.stub(:connection_pool, FakePool.new(connection), &block)
  end

  def test_sqlite_omits_database_health
    database = Upstate::Rails::Health.call[1][:database]
    assert_equal %i[ok pending_migrations], database.keys.sort
    assert_equal({}, Upstate::Rails::Sections.database_stats)
  end

  def test_postgres_reports_aggregate_database_health_under_a_statement_timeout
    connection = FakePgConnection.new("PostgreSQL", summary: PRIMARY, tables: TABLES, replicas: [[0, nil]])
    stats = with_fake_connection(connection) { Upstate::Rails::Sections.database_stats }

    assert_equal 1_342_177_280, stats[:size_bytes]
    assert_equal({in_use: 12, max: 100}, stats[:connections])
    assert_equal 0, stats[:oldest_transaction_age_seconds]
    assert_equal 1, stats[:idle_in_transaction]
    assert_equal 48_211_934, stats[:xid_age]
    assert_equal({name: "public.events", total_bytes: 812_646_400, live_rows: 4_210_000, dead_rows: 1_200}, stats[:largest_tables].first)
    refute stats.key?(:replication), "no replicas means no replication section"
    assert_equal "SET LOCAL statement_timeout = 250", connection.statements.first
  end

  def test_replica_and_primary_replication_lag
    replica = FakePgConnection.new("PostGIS", summary: [[1, 1, 10, 0, 0, 5, true, "42"]], tables: [], replicas: RuntimeError.new("not asked"))
    stats = with_fake_connection(replica) { Upstate::Rails::Sections.database_stats }
    assert_equal({role: "replica", lag_seconds: 42}, stats[:replication])
    refute(replica.statements.any? { |sql| sql.include?("pg_stat_replication") })

    primary = FakePgConnection.new("PostgreSQL", summary: PRIMARY, tables: [], replicas: [[2, 3]])
    stats = with_fake_connection(primary) { Upstate::Rails::Sections.database_stats }
    assert_equal({role: "primary", replicas: 2, lag_seconds: 3}, stats[:replication])
  end

  def test_a_failing_query_drops_only_its_own_fields
    connection = FakePgConnection.new("PostgreSQL", summary: PRIMARY, tables: RuntimeError.new("permission denied"), replicas: [[0, nil]])
    stats = with_fake_connection(connection) { Upstate::Rails::Sections.database_stats }
    assert_equal 1_342_177_280, stats[:size_bytes]
    refute stats.key?(:largest_tables)

    timeout = FakePgConnection.new("PostgreSQL", summary: RuntimeError.new("canceling statement due to statement timeout"), tables: TABLES, replicas: [[0, nil]])
    stats = with_fake_connection(timeout) { Upstate::Rails::Sections.database_stats }
    refute stats.key?(:size_bytes)
    assert_equal 2, stats[:largest_tables].size
  end

  def test_health_never_fails_because_of_database_stats
    Upstate::Rails::Sections.stub(:database_stats, {}) do
      database = Upstate::Rails::Sections.database
      assert_equal true, database[:ok]
      assert_equal %i[ok pending_migrations], database.keys.sort
    end

    Upstate::Rails::Sections.stub(:database_stats, {size_bytes: 77}) do
      assert_equal 77, Upstate::Rails::Health.call[1][:database][:size_bytes]
    end
  end

  def test_mysql_omits_database_health
    connection = FakePgConnection.new("Mysql2", summary: PRIMARY, tables: TABLES, replicas: [])
    assert_equal({}, with_fake_connection(connection) { Upstate::Rails::Sections.database_stats })
  end

  def test_database_down_is_503
    Upstate::Rails::Sections.stub(:database, {ok: false, pending_migrations: nil}) do
      status, body = Upstate::Rails::Health.call
      assert_equal 503, status
      assert_equal false, body[:database][:ok]
    end
  end

  def test_section_errors_report_nil
    Upstate::Rails::Sections.stub(:active_record_pool, -> { raise "boom" }) do
      status, body = Upstate::Rails::Health.call
      assert_equal 200, status
      assert_nil body[:active_record_pool]
      refute_nil body[:rails]
    end
  end

  def test_puma_single_and_cluster
    single = {started_at: "x", backlog: 1, running: 2, pool_capacity: 3, max_threads: 5}
    with_constants("Puma" => Module.new { define_singleton_method(:stats_hash) { single } }) do
      assert_equal({workers: 1, booted_workers: 1, max_threads: 5, backlog: 1, pool_capacity: 3}, Upstate::Rails::Sections.puma)
    end

    cluster = {workers: 2, booted_workers: 2, worker_status: [
      {last_status: {backlog: 0, pool_capacity: 2, max_threads: 3}},
      {last_status: {backlog: 2, pool_capacity: 1, max_threads: 3}}
    ]}
    with_constants("Puma" => Module.new { define_singleton_method(:stats_hash) { cluster } }) do
      assert_equal({workers: 2, booted_workers: 2, max_threads: 6, backlog: 2, pool_capacity: 3}, Upstate::Rails::Sections.puma)
    end
  end

  def test_cache_probe_for_redis_like_store_only
    klass = Class.new(ActiveSupport::Cache::MemoryStore)
    store = klass.new
    ::Rails.stub(:cache, store) { assert_nil Upstate::Rails::Sections.cache }

    solid = Class.new(ActiveSupport::Cache::MemoryStore)
    with_constants("SolidCache::Store" => solid) do
      ::Rails.stub(:cache, solid.new) do
        assert_equal({store: "solid_cache", ok: true}, Upstate::Rails::Sections.cache)
      end
    end
  end
end
