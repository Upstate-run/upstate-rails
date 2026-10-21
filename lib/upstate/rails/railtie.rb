# frozen_string_literal: true

module Upstate
  module Rails
    class Railtie < ::Rails::Railtie
      # Prepended (not appended) so a catch-all route in the host app cannot shadow it.
      initializer "upstate_rails.routes" do |app|
        app.routes.prepend do
          get Upstate::Rails::PATH, to: Upstate::Rails::Endpoint.new
        end
      end

      # The observer calls the container IP over plain HTTP, so Host authorization and
      # force_ssl redirects must not apply to the health path.
      initializer "upstate_rails.exclusions", before: :build_middleware_stack do |app|
        path = Upstate::Rails::PATH
        wrap = lambda do |existing|
          ->(request) { request.path == path || (existing.respond_to?(:call) && existing.call(request)) }
        end

        hosts = (app.config.host_authorization || {}).dup
        hosts[:exclude] = wrap.call(hosts[:exclude])
        app.config.host_authorization = hosts

        ssl = (app.config.ssl_options || {}).dup
        redirect = ssl[:redirect]
        redirect = {} unless redirect.is_a?(Hash)
        ssl[:redirect] = redirect.merge(exclude: wrap.call(redirect[:exclude]))
        app.config.ssl_options = ssl
      end

      # Collect action rollups only when the endpoint is switched on.
      config.after_initialize do
        next if ENV["UPSTATE_HEALTH_TOKEN"].to_s.empty?

        Upstate::Rails.subscribe!
        at_exit { Upstate::Rails.rollup.flush! }
      end

      generators do
        require "generators/upstate/install/install_generator"
      end
    end
  end
end
