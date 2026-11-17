# frozen_string_literal: true

namespace :upstate do
  desc "Check the Upstate app-health reporter locally (read-only; prints no token)"
  task verify: :environment do
    report = Upstate::Rails::Verify.call
    puts Upstate::Rails::Verify.render(report)
    exit(1) unless report[:ok]
  end
end
