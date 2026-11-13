# frozen_string_literal: true

require "json"
require "digest"
require "time"
require "tmpdir"
require "securerandom"
require "active_support"
require "active_support/notifications"
require "active_support/security_utils"
require "rails/railtie"

require_relative "rails/version"

# NOTE: inside this namespace, `Rails` means Upstate::Rails. Use `::Rails` for the framework.
module Upstate
  module Rails
    PATH = "/upstate/health"
    BOOTED_AT = Time.now.utc.freeze

    class << self
      # The per-process action rollup. Replaceable in tests.
      attr_writer :rollup

      def rollup
        @rollup ||= ActionRollup.new
      end

      # Subscribes once to process_action.action_controller.
      def subscribe!
        return if @subscriber

        @subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
          record_event(event)
        end
      end

      def unsubscribe!
        ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
        @subscriber = nil
      end

      private

      # Never raises into the request. Only the controller#action name, timings and an
      # error flag are kept; params, paths, SQL and exception details are not read.
      def record_event(event)
        payload = event.payload
        status = payload[:status].to_i
        error = status >= 500 || !payload[:exception].nil? || !payload[:exception_object].nil?
        rollup.record("#{payload[:controller]}##{payload[:action]}", event.duration, payload[:db_runtime], error)
      rescue StandardError
        nil
      end
    end
  end
end

require_relative "rails/action_store"
require_relative "rails/action_rollup"
require_relative "rails/jobs/solid_queue"
require_relative "rails/jobs/sidekiq"
require_relative "rails/jobs/good_job"
require_relative "rails/jobs"
require_relative "rails/recurring/solid_queue_source"
require_relative "rails/recurring"
require_relative "rails/sections"
require_relative "rails/health"
require_relative "rails/endpoint"
require_relative "rails/railtie"
