require File.expand_path(File.join(File.dirname(__FILE__), "publisher"))
require "singleton"

module Dboard
  class Collector
    include Singleton

    DEFAULT_MIN_INTERVAL = 30 # seconds

    FULL = Object.new.freeze # a no-arg request; compared by identity so a caller-supplied value never collides
    SKIP = Object.new.freeze # a throttled/empty attempt that must not fetch
    private_constant :FULL, :SKIP

    attr_reader :sources

    def self.register_source(key, source_instance)
      instance.register_source(key, source_instance)
    end

    def self.register_after_update_callback(callback)
      instance.register_after_update_callback(callback)
    end

    def self.register_error_callback(callback)
      instance.register_error_callback(callback)
    end

    def self.request_update(key, arg = nil)
      instance.request_update(key, arg)
    end

    def self.start
      instance.start
    end

    def initialize
      @sources = {}
      @after_update_callback = lambda {}
      @error_callback = lambda { |exception| }
      @mutex = Mutex.new
      @last_update_at = {}
      @active = {}
      @pending = {}
      @refresh_locks = {}
    end

    def start
      @sources.each do |source, instance|
        Thread.new do
          wait_a_little_bit_to_not_start_all_fetches_at_once

          loop do
            request_update(source)
            sleep instance.update_interval
          end
        end
      end
      loop { sleep 1 }
    end

    def register_source(key, instance)
      @sources.merge!({ key => instance })
      @refresh_locks[key] = Mutex.new
    end

    def register_after_update_callback(callback)
      @after_update_callback = callback
    end

    def register_error_callback(callback)
      @error_callback = callback
    end

    def request_update(key, arg = nil)
      instance = @sources.fetch(key)
      floor = min_interval_for(instance)
      entry = arg.nil? ? FULL : arg
      leading = nil
      delay = @mutex.synchronize {
        now = monotonic_now
        (@pending[key] ||= []) << entry
        case decide_request(@active[key], @last_update_at[key], floor, now)
        when :coalesce
          return
        when :refresh_now
          @active[key] = true
          leading = @pending[key]
          @pending[key] = []
          0
        when :schedule
          @active[key] = true
          floor - (now - @last_update_at[key])
        end
      }
      spawn { run_worker(key, instance, floor, delay, leading) }
    end

    def update_source(source, instance, batch = nil)
      begin
        data = fetch_source(instance, batch)
        publish_data(source, data)
      ensure
        @after_update_callback.call
      end
    rescue Exception => ex
      puts "Failed to update #{source}: #{ex.message}"
      puts ex.backtrace
      @error_callback.call(ex)
    end

    private

    def fetch_source(instance, batch)
      full_batch?(batch) ? instance.fetch : instance.fetch(batch)
    end

    def full_batch?(batch)
      batch.nil? || batch.any? { |entry| entry.equal?(FULL) }
    end

    def describe_batch(batch)
      full_batch?(batch) ? nil : "(#{batch.join(", ")})"
    end

    def decide_request(active, last_update_at, floor, now)
      return :coalesce if active
      return :refresh_now if last_update_at.nil? || (now - last_update_at) >= floor

      :schedule
    end

    def run_worker(key, instance, floor, delay, leading)
      cleared = false
      loop do
        sleep delay if delay && delay > 0
        fired = perform_refresh(key, instance, floor, leading: leading, drain: leading.nil?)
        delay = @mutex.synchronize {
          remaining = floor - (monotonic_now - @last_update_at[key])
          remaining = 0 if remaining < 0
          pending = @pending[key]
          if fired
            leading = nil
            if pending && !pending.empty?
              remaining # trailing: drain the burst that arrived while we were active
            else
              @active[key] = false
              cleared = true
              nil
            end
          elsif leading || (pending && !pending.empty?)
            remaining # throttled; retry the retained leading snapshot or the queued args after the floor
          else
            @active[key] = false
            cleared = true
            nil
          end
        }
        break if cleared
      end
    rescue Exception => ex
      puts "Something failed in the update worker for #{key}: #{ex.message}"
      puts ex.backtrace
    ensure
      @mutex.synchronize { @active[key] = false } unless cleared
    end

    def perform_refresh(source, instance, min_interval, leading: nil, drain: false)
      @refresh_locks.fetch(source).synchronize {
        batch = @mutex.synchronize {
          now = monotonic_now
          last = @last_update_at[source]
          next SKIP unless last.nil? || (now - last) >= min_interval

          if leading
            resolved = leading
          elsif drain
            queued = (@pending[source] ||= [])
            next SKIP if queued.empty?

            resolved = queued
            @pending[source] = []
          else
            resolved = nil
          end
          @last_update_at[source] = now
          resolved
        }
        return false if batch.equal?(SKIP)

        started = monotonic_now
        update_source(source, instance, batch)
        puts [ "#{source} refreshed", describe_batch(batch), "in #{(monotonic_now - started).round(1)}s" ].compact.join(" ")
        true
      }
    end

    def min_interval_for(instance)
      override = instance.respond_to?(:min_update_interval) ? instance.min_update_interval : DEFAULT_MIN_INTERVAL
      [ override, instance.update_interval ].min
    end

    def spawn(&block)
      Thread.new(&block)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def publish_data(source, data)
      Publisher.publish(source, data)
    end

    def wait_a_little_bit_to_not_start_all_fetches_at_once
      sleep 10 * rand
    end
  end
end
