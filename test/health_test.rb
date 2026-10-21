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
