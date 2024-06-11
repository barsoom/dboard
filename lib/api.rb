require File.expand_path(File.join(File.dirname(__FILE__), "cache"))
require File.expand_path(File.join(File.dirname(__FILE__), "collector.rb"))
require "digest/md5"
require "json"
require "httparty"
require "net_http_timeout_errors"

module Dboard
  class Api
    MAX_CACHE_TIME = 3600 # seconds
    @@version = nil

    class Client
      class << self
        attr_accessor :clients
      end

      def self.endpoints=(endpoints)
        self.clients = endpoints.map { |config|
          Class.new {
            include HTTParty
            base_uri config.fetch(:base_uri)
            basic_auth *config.fetch(:basic_auth)
          }
        }
      end

      def self.post(url, opts)
        with_retries {
          self.clients.each do |client|
            client.post(url, opts)
          end
        }
      end

      private

      private_class_method \
      def self.with_retries
        remaining_attempts = 3

        begin
          remaining_attempts -= 1
          yield
        rescue *NetHttpTimeoutErrors.all
          raise if remaining_attempts == 0

          sleep((ENV["RACK_ENV"] == "test") ? 0 : 5)
          retry
        end
      end
    end

    def self.get(params)
      types = {}
      params[:types].split(",").each do |type|
        raw_data = CACHE.get("dashboard::source::#{type}")
        data = raw_data ? JSON.parse(raw_data) : {}
        types.merge!(type => { data: data, checksum: Digest::MD5.hexdigest(data.inspect) })
      end
      { version: (@@version || ENV["COMMIT_HASH"] || "unversioned"), sources: types }.to_json
    end

    def self.version=(version)
      @@version = version
    end

    def self.update(params)
      CACHE.set "dashboard::source::#{params[:type]}", params[:data], MAX_CACHE_TIME
    end
  end
end
