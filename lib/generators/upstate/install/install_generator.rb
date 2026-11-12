# frozen_string_literal: true

require "rails/generators"

module Upstate
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      desc "Prints the steps to turn on Upstate Rails app health (GET /upstate/health)."

      DEPLOY_EXAMPLE = <<~YAML

        # Upstate app health: add UPSTATE_HEALTH_TOKEN to .kamal/secrets, then uncomment.
        # env:
        #   secret:
        #     - UPSTATE_HEALTH_TOKEN
      YAML

      def append_deploy_example
        path = File.join(destination_root, "config/deploy.yml")
        return unless File.exist?(path)
        return if File.read(path).include?("UPSTATE_HEALTH_TOKEN")

        append_to_file "config/deploy.yml", DEPLOY_EXAMPLE
      end

      def print_steps
        say <<~TEXT

          Upstate Rails app health is installed. The endpoint is off until you set a token.

          1. In Upstate, open the environment page and generate a health token (shown once).
          2. Add it to .kamal/secrets:
               UPSTATE_HEALTH_TOKEN=<the token>
          3. List it under env.secret in config/deploy.yml:
               env:
                 secret:
                   - UPSTATE_HEALTH_TOKEN
          4. Deploy, then check it:
               curl -H "Authorization: Bearer $UPSTATE_HEALTH_TOKEN" https://your-app.example.com/upstate/health

          Without the token the path returns 404. With a wrong token it returns 401.
        TEXT
      end
    end
  end
end
