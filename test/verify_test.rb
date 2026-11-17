# frozen_string_literal: true

require "test_helper"
require "rake"
require "minitest/mock"

class VerifyTest < Minitest::Test
  TOKEN = "s3cr3t-" + ("t" * 33)

  def report(token)
    with_env("UPSTATE_HEALTH_TOKEN" => token) { Upstate::Rails::Verify.call }
  end

  def test_disabled_without_token_has_next_action
    r = report(nil)
    refute r[:ok]
    check = r[:checks].first
    assert_equal "disabled", check[:status]
    assert_match "UPSTATE_HEALTH_TOKEN", check[:action]
    refute r[:token][:present]
    assert_equal 1, r[:checks].size
  end

  def test_blank_token_is_disabled
    assert_equal "disabled", report("")[:checks].first[:status]
  end

  def test_configured_token_authorizes_and_answers
    r = report(TOKEN)
    assert r[:ok], r.inspect
    assert_equal %w[configured authorization health\ response], r[:checks].map { |c| c[:name] }
    assert_equal Upstate::Rails::VERSION, r[:reporter][:version]
    assert_equal ::Rails.version, r[:runtime][:rails]
  end

  def test_output_never_contains_the_token
    r = report(TOKEN)
    text = Upstate::Rails::Verify.render(r) + JSON.generate(r)
    refute_includes text, TOKEN
    refute_includes text, "s3cr3t"
    assert_match "value not shown", text
  end

  def test_not_proof_of_collection_is_stated
    assert_match "not proof that Upstate receives data", Upstate::Rails::Verify.render(report(TOKEN))
  end

  def test_endpoint_that_accepts_a_wrong_token_fails_authorization
    open_endpoint = ->(_env) { [200, {}, ['{"schema":1,"version":"x"}']] }
    r = with_env("UPSTATE_HEALTH_TOKEN" => TOKEN) { Upstate::Rails::Verify.call(endpoint: open_endpoint) }
    refute r[:ok]
    assert_equal "failed", r[:checks].find { |c| c[:name] == "authorization" }[:status]
  end

  def test_database_down_is_reported_with_action
    down = lambda do |env|
      bearer = env["HTTP_AUTHORIZATION"]
      (bearer == "Bearer #{TOKEN}") ? [503, {}, ['{"schema":1}']] : [401, {}, [""]]
    end
    r = with_env("UPSTATE_HEALTH_TOKEN" => TOKEN) { Upstate::Rails::Verify.call(endpoint: down) }
    check = r[:checks].last
    assert_equal "failed", check[:status]
    assert_match "database", check[:detail]
  end

  def test_configured_token_equal_to_a_fixed_probe_string_still_verifies
    assert report("upstate-verify-probe")[:ok]
  end

  def test_verification_health_is_read_only
    _status, body = Upstate::Rails::Health.call(read_only: true)
    assert_nil body[:cache]
    assert_nil body[:actions]
    assert_nil body[:jobs]
    assert_equal 1, body[:schema]
  end

  def test_reports_the_application_version_not_the_gem_version
    with_env("APP_VERSION" => "app-9") do
      detail = report(TOKEN)[:checks].last[:detail]
      assert_match 'application version "app-9"', detail
      refute_match "reporter version", detail
    end
  end

  def test_read_only_health_never_touches_the_job_system
    calls = 0
    Upstate::Rails::Jobs.stub(:call, ->(**) { calls += 1; [nil, nil] }) do
      _status, body = Upstate::Rails::Health.call(read_only: true)
      assert_nil body[:jobs]
    end
    assert_equal 0, calls, "the read-only build called the job system"
  end

  def test_read_only_health_never_reads_recurring_jobs
    calls = 0
    Upstate::Rails::Recurring.stub(:call, ->(**) { calls += 1; nil }) do
      _status, body = Upstate::Rails::Health.call(read_only: true)
      refute body.key?(:recurring)
    end
    assert_equal 0, calls, "the read-only build read the recurring-job tables"
  end

  def test_verify_turns_off_the_exit_time_rollup_flush
    Upstate::Rails.instance_variable_set(:@flush_disabled, nil)
    refute Upstate::Rails.flush_disabled?
    report(TOKEN)
    assert Upstate::Rails.flush_disabled?
  ensure
    Upstate::Rails.instance_variable_set(:@flush_disabled, nil)
  end

  def test_builds_the_health_response_once
    calls = 0
    endpoint = Upstate::Rails::Endpoint.new(health: -> { calls += 1; [200, {schema: 1, version: "x"}] })
    with_env("UPSTATE_HEALTH_TOKEN" => TOKEN) { Upstate::Rails::Verify.call(endpoint: endpoint) }
    assert_equal 1, calls
  end

  def test_oversized_token_names_the_byte_limit
    r = report("é" * 200) # 200 characters, 400 bytes
    refute r[:ok]
    check = r[:checks].last
    assert_match "400 bytes", check[:detail]
    assert_match "256", check[:detail]
    refute_match "route", check[:action].to_s
  end

  def test_makes_no_network_request_and_is_repeatable
    first = report(TOKEN)
    second = report(TOKEN)
    assert_equal first[:checks], second[:checks]
  end

  def test_rake_task_is_defined_by_the_railtie_but_not_run_on_load
    Rake::Task.clear
    Rake::Task.define_task(:environment)
    load File.expand_path("../lib/tasks/upstate.rake", __dir__)
    assert Rake::Task.task_defined?("upstate:verify")
  end
end
