# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "version"

Gem::Specification.new do |s|
  s.name        = "dboard"
  s.version     = Dboard::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = [ "Joakim Kolsjö" ]
  s.email       = [ "joakim.kolsjo@gmail.com" ]
  s.homepage    = ""
  s.summary     = %q{Dashboard framework}
  s.description = %q{Dashboard framework}
  s.license     = "MIT"
  s.metadata    = { "rubygems_mfa_required" => "true" }

  s.files         = `git ls-files`.split("\n")
  s.require_paths = [ "lib" ]

  s.add_dependency "dalli"
  s.add_dependency "httparty"
  s.add_dependency "json"
  s.add_dependency "net_http_timeout_errors"
  s.add_dependency "rake"
  s.add_dependency "sinatra"
end
