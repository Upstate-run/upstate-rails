# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "active_job/railtie"
require "logger"
require "rack/mock"
require "minitest/autorun"
require "upstate/rails"

TMP_ROOT = Dir.mktmpdir("upstate-rails-test")
Minitest.after_run { FileUtils.remove_entry(TMP_ROOT) if File.exist?(TMP_ROOT) }

FileUtils.mkdir_p(File.join(TMP_ROOT, "config"))
File.write(File.join(TMP_ROOT, "config/database.yml"), <<~YAML)
  test:
    adapter: sqlite3
    database: #{File.join(TMP_ROOT, "test.sqlite3")}
YAML

class DummyApp < ::Rails::Application
  config.root = TMP_ROOT
  config.eager_load = false
  config.secret_key_base = "x" * 64
  config.logger = Logger.new(nil)
  config.hosts.clear
  config.active_job.queue_adapter = :test
end

DummyApp.initialize!

class Minitest::Test
  # Sets env vars for the duration of a block.
  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  # Defines fake top-level constants (e.g. "Sidekiq::Stats") for a block.
  def with_constants(defs)
    created = []
    defs.each do |path, value|
      parts = path.split("::")
      parent = parts[0..-2].inject(Object) do |mod, name|
        if mod.const_defined?(name, false)
          mod.const_get(name, false)
        else
          created << [mod, name]
          mod.const_set(name, Module.new)
        end
      end
      created << [parent, parts.last]
      parent.const_set(parts.last, value)
    end
    yield
  ensure
    created.reverse_each { |mod, name| mod.send(:remove_const, name) if mod.const_defined?(name, false) }
  end

  def get_health(token: nil, app: Upstate::Rails::Endpoint.new)
    headers = token ? {"HTTP_AUTHORIZATION" => "Bearer #{token}"} : {}
    Rack::MockRequest.new(app).get("/upstate/health", headers)
  end
end

# Minimal stand-in for an ActiveRecord relation / model class.
class FakeRelation
  def initialize(count: 0, minimum: nil, maximum: nil)
    @count = count
    @minimum = minimum
    @maximum = maximum
  end

  def where(*) = self
  def not(*) = self
  def count(*) = @count
  def minimum(*) = @minimum
  def maximum(*) = @maximum
end
