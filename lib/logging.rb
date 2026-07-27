require "logger"

module Dboard
  class << self
    attr_writer :logger

    def logger
      @logger ||= Logger.new($stdout)
    end
  end
end
