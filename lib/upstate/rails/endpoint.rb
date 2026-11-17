# frozen_string_literal: true

module Upstate
  module Rails
    # Rack endpoint for GET /upstate/health.
    class Endpoint
      MAX_TOKEN_BYTES = 256

      # `health` is any callable returning [status, body]; `rake upstate:verify` passes a
      # read-only one.
      def initialize(health: Health.method(:call))
        @health = health
      end

      def call(env)
        expected = ENV["UPSTATE_HEALTH_TOKEN"].to_s
        return respond(404, "") if expected.empty?
        return respond(401, "", "www-authenticate" => "Bearer") unless authorized?(env["HTTP_AUTHORIZATION"], expected)

        status, body = @health.call
        respond(status, JSON.generate(body), "content-type" => "application/json")
      end

      private

      def authorized?(header, expected)
        header = header.to_s
        return false unless header.start_with?("Bearer ")

        supplied = header.delete_prefix("Bearer ")
        return false if supplied.empty? || supplied.bytesize > MAX_TOKEN_BYTES

        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(supplied), Digest::SHA256.hexdigest(expected))
      end

      def respond(status, body, headers = {})
        [status, {"cache-control" => "no-store", "content-length" => body.bytesize.to_s}.merge(headers), [body]]
      end
    end
  end
end
