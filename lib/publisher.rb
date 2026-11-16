# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), "logging"))
require "json"

module Dboard
  class Publisher
    def self.publish(source, data)
      Api::Client.post("/sources/#{source}", body: { data: data.to_json }, timeout: 10000)
    rescue SocketError => ex
      Dboard.logger.error("SocketError: #{ex.message}")
    end
  end
end
