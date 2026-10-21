# frozen_string_literal: true

require_relative "lib/upstate/rails/version"

Gem::Specification.new do |spec|
  spec.name = "upstate-rails"
  spec.version = Upstate::Rails::VERSION
  spec.authors = ["Upstate"]

  spec.summary = "Rails app health for Upstate: boot facts, migrations, Puma, jobs, and slowest actions. Counts only."
  spec.description = "Adds a bearer-protected GET /upstate/health to a Rails app. Reports aggregate counts and " \
                     "fixed-bucket timings only: no params, paths, SQL, IPs, user agents, or job arguments."
  spec.homepage = "https://github.com/Upstate-run/upstate-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "actionpack", ">= 7.1"
end
