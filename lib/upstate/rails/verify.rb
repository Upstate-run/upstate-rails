# frozen_string_literal: true

module Upstate
  module Rails
    # Read-only local check for `rake upstate:verify`. It answers the questions that can
    # be answered inside this process: is the reporter turned on, is a token present (never
    # printed), and does the endpoint authorize and answer. It sends nothing to Upstate,
    # writes nothing (no cache probe, no rollup flush) and never changes credentials. It
    # does read from the app's own database to build the response. Whether Upstate has received a report
    # is a separate fact that only Upstate can confirm (`upstate doctor`).
    class Verify
      Check = Struct.new(:name, :status, :detail, :action, keyword_init: true) do
        def ok? = status == "ok"
      end

      def self.call(endpoint: nil)
        new(endpoint).call
      end

      def initialize(endpoint)
        @endpoint = endpoint || Endpoint.new(health: -> { Health.call(read_only: true) })
      end

      # => {reporter:, runtime:, environment:, token:, checks:, ok:}
      def call
        # The railtie registers an exit-time rollup flush when a token is set; a check must
        # write nothing, so switch it off for this process.
        Upstate::Rails.disable_flush!
        token = ENV["UPSTATE_HEALTH_TOKEN"].to_s
        checks = [configured_check(token)]
        checks.concat(endpoint_checks(token)) unless token.empty?
        {
          reporter: {name: "upstate-rails", version: Upstate::Rails::VERSION},
          runtime: {rails: ::Rails.version, ruby: RUBY_VERSION},
          environment: ::Rails.env.to_s,
          token: token_summary(token),
          checks: checks.map(&:to_h),
          ok: checks.all?(&:ok?),
          next_step: "A passing local check is not proof that Upstate receives data. After a deploy, run `upstate doctor` and wait for fresh evidence."
        }
      end

      # Human-readable lines. Never includes the token or any part of it.
      def self.render(report)
        lines = ["Upstate Rails reporter #{report[:reporter][:version]} (Rails #{report[:runtime][:rails]}, Ruby #{report[:runtime][:ruby]}, #{report[:environment]})"]
        lines << "Token: #{report[:token][:present] ? "present (#{report[:token][:length]} characters, value not shown)" : "not set"}"
        report[:checks].each do |check|
          lines << "#{(check[:status] == "ok") ? "ok  " : "FAIL"} #{check[:name]}: #{check[:detail]}"
          lines << "     next: #{check[:action]}" if check[:action]
        end
        lines << report[:next_step]
        lines.join("\n")
      end

      private

      def token_summary(token)
        {present: !token.empty?, length: token.length}
      end

      def configured_check(token)
        if token.empty?
          Check.new(name: "configured", status: "disabled",
            detail: "UPSTATE_HEALTH_TOKEN is not set in this environment, so /upstate/health answers 404 and nothing is reported.",
            action: "Generate a health token in Upstate, set UPSTATE_HEALTH_TOKEN for this environment (for example under env.secret in config/deploy.yml), then deploy.")
        else
          Check.new(name: "configured", status: "ok", detail: "UPSTATE_HEALTH_TOKEN is set; the endpoint is on.")
        end
      end

      def endpoint_checks(token)
        if token.bytesize > Endpoint::MAX_TOKEN_BYTES
          return [Check.new(name: "authorization", status: "failed",
            detail: "UPSTATE_HEALTH_TOKEN is #{token.bytesize} bytes; the endpoint rejects any token over #{Endpoint::MAX_TOKEN_BYTES} bytes.",
            action: "Generate a token in Upstate (they are well under the limit) and set it as UPSTATE_HEALTH_TOKEN, without extra characters.")]
        end

        # One request with the configured token serves both the authorization and the
        # response check, so the health build (database, jobs, schedules) runs once.
        status, _headers, body = call_endpoint(token)
        [auth_check(token, status), health_check(status, body)]
      end

      # A wrong token that can never equal the configured one.
      def probe_token(token)
        loop do
          candidate = "probe-#{SecureRandom.hex(16)}"
          return candidate unless candidate == token
        end
      end

      def call_endpoint(bearer)
        @endpoint.call({"HTTP_AUTHORIZATION" => "Bearer #{bearer}"})
      end

      def auth_check(token, accepted)
        rejected = call_endpoint(probe_token(token)).first
        if rejected == 401 && accepted != 401
          Check.new(name: "authorization", status: "ok", detail: "The endpoint rejects a wrong token and accepts the configured one.")
        else
          Check.new(name: "authorization", status: "failed",
            detail: "The endpoint did not behave as expected (wrong token: #{rejected}, configured token: #{accepted}).",
            action: "Check that UPSTATE_HEALTH_TOKEN has no stray characters or whitespace, and that this endpoint is the Upstate one, then redeploy.")
        end
      end

      def health_check(status, body)
        parsed = JSON.parse(body.join)
        if status == 200 && parsed["schema"] == Health::SCHEMA
          Check.new(name: "health response", status: "ok", detail: "Schema #{Health::SCHEMA}, application version #{parsed["version"].inspect} (APP_VERSION or KAMAL_VERSION).")
        elsif status == 503
          Check.new(name: "health response", status: "failed", detail: "The database is not answering (503).",
            action: "Fix database connectivity for this environment; the reporter will then answer 200.")
        else
          Check.new(name: "health response", status: "failed", detail: "Unexpected response #{status}.",
            action: "Run the app and request /upstate/health with the token to see the response.")
        end
      rescue StandardError => e
        Check.new(name: "health response", status: "failed", detail: "Could not read the health response (#{e.class}).",
          action: "Run the app in this environment and check its logs for the error.")
      end
    end
  end
end
