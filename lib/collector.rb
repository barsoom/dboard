require File.expand_path(File.join(File.dirname(__FILE__), "publisher"))
require "singleton"

module Dboard
  class Collector
    include Singleton

    DEFAULT_MIN_INTERVAL = 30 # seconds

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

    def self.request_update(key)
      instance.request_update(key)
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
            update_in_thread(source, instance)
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

    def request_update(key)
      instance = @sources.fetch(key)
      floor = min_interval_for(instance)
      delay = @mutex.synchronize {
        now = monotonic_now
        case decide_request(@active[key], @last_update_at[key], floor, now)
        when :coalesce
          @pending[key] = true
          return
        when :refresh_now
          @active[key] = true
          0
        when :schedule
          @active[key] = true
          floor - (now - @last_update_at[key])
        end
      }
      spawn { run_worker(key, instance, floor, delay) }
    end

    def update_source(source, instance)
      begin
        data = instance.fetch
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

    def decide_request(active, last_update_at, floor, now)
      return :coalesce if active
      return :refresh_now if last_update_at.nil? || (now - last_update_at) >= floor

      :schedule
    end

    def run_worker(key, instance, floor, delay)
      cleared = false
      loop do
        sleep delay if delay && delay > 0
        fired = perform_refresh(key, instance, floor)
        delay = @mutex.synchronize {
          remaining = floor - (monotonic_now - @last_update_at[key])
          remaining = 0 if remaining < 0
          if !fired
            remaining # a poll or another refresh got in first; retry after the floor
          elsif @pending[key]
            @pending[key] = false
            remaining # trailing: drain the burst that arrived while we were active
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

    def perform_refresh(source, instance, min_interval)
      @refresh_locks.fetch(source).synchronize {
        should_fetch = @mutex.synchronize {
          now = monotonic_now
          last = @last_update_at[source]
          if last.nil? || (now - last) >= min_interval
            @last_update_at[source] = now
            true
          else
            false
          end
        }
        update_source(source, instance) if should_fetch
        should_fetch
      }
    end

    def update_in_thread(source, instance)
      puts "#{source} polling..."
      fired = perform_refresh(source, instance, instance.update_interval)
      time_until_next_update = @mutex.synchronize {
        remaining = instance.update_interval - (monotonic_now - @last_update_at[source])
        remaining < 0 ? 0 : remaining
      }
      puts "#{source} #{fired ? "updated" : "still fresh"}, will poll again in #{time_until_next_update} seconds (interval: #{instance.update_interval})."
      sleep time_until_next_update
    rescue Exception => ex
      puts "Something failed outside the update_source method. #{ex.message}"
      puts ex.backtrace
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
