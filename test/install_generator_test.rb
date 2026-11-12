# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/upstate/install/install_generator"

class InstallGeneratorTest < ::Rails::Generators::TestCase
  tests Upstate::Generators::InstallGenerator
  destination File.join(Dir.tmpdir, "upstate-generator-test")
  setup :prepare_destination

  def test_appends_commented_example_when_missing
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/deploy.yml"), "service: app\n")
    out = run_generator
    assert_match "UPSTATE_HEALTH_TOKEN", File.read(File.join(destination_root, "config/deploy.yml"))
    assert_match ".kamal/secrets", out
  end

  def test_does_not_touch_deploy_yml_when_token_already_present
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    original = "env:\n  secret:\n    - UPSTATE_HEALTH_TOKEN\n"
    File.write(File.join(destination_root, "config/deploy.yml"), original)
    run_generator
    assert_equal original, File.read(File.join(destination_root, "config/deploy.yml"))
  end

  def test_only_prints_without_deploy_yml
    out = run_generator
    refute File.exist?(File.join(destination_root, "config/deploy.yml"))
    assert_match "curl", out
  end
end

class ExclusionsTest < Minitest::Test
  def test_health_path_excluded_from_host_authorization_and_ssl_redirect
    request = Struct.new(:path)
    assert DummyApp.config.host_authorization[:exclude].call(request.new("/upstate/health"))
    refute DummyApp.config.host_authorization[:exclude].call(request.new("/"))
    assert DummyApp.config.ssl_options[:redirect][:exclude].call(request.new("/upstate/health"))
  end
end
