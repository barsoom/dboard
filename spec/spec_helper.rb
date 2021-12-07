require "rspec"
require 'webmock/rspec'

ENV["RACK_ENV"] ||= "test"
ENV["API_URL"] = "http://api.example"
ENV["API_USER"] = "test"
ENV["API_PASSWORD"] = "test"

require File.expand_path(File.join(File.dirname(__FILE__), "../lib/dboard"))

Dboard::Api::Client.basic_auth(ENV["API_USER"], ENV["API_PASSWORD"])
Dboard::Api::Client.base_uri(ENV["API_URL"])
