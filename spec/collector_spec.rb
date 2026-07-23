require File.expand_path(File.join(File.dirname(__FILE__), "spec_helper"))

class FakeClock
  attr_reader :now

  def initialize
    @now = 0.0
  end

  def advance(seconds)
    @now += seconds
  end
end

class LatchSource
  attr_reader :update_interval

  def initialize(update_interval:)
    @update_interval = update_interval
    @lock = Mutex.new
    @started = Queue.new
    @release = Queue.new
    @block_next = false
    @value = nil
    @fetch_values = []
    @fetch_times = []
  end

  def set_value(value)
    @lock.synchronize { @value = value }
  end

  def block_next_fetch!
    @lock.synchronize { @block_next = true }
  end

  def wait_until_started
    @started.pop
  end

  def release!
    @release << true
  end

  def fetch_count
    @lock.synchronize { @fetch_values.size }
  end

  def fetch_values
    @lock.synchronize { @fetch_values.dup }
  end

  def fetch_times
    @lock.synchronize { @fetch_times.dup }
  end

  def fetch
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    block_here = @lock.synchronize {
      @fetch_values << @value
      @fetch_times << now
      blocking = @block_next
      @block_next = false
      blocking
    }
    if block_here
      @started << true
      @release.pop
    end
    { value: fetch_values.last }
  end
end

RSpec.describe Dboard::Collector do
  describe ".register_source" do
    before do
      Dboard::Collector.instance.sources.clear
    end

    let(:new_relic) { double(:new_relic) }
    let(:callback) { double(:callback) }

    it "can register a source" do
      allow(new_relic).to receive(:update_interval).and_return(5)
      Dboard::Collector.register_source :new_relic, new_relic
      expect(Dboard::Collector.instance.sources).to eq({ new_relic: new_relic })
    end

    it "can register an after update callback" do
      allow(new_relic).to receive(:fetch).and_return({ db: "100%" })
      allow(callback).to receive(:call)
      allow(Dboard::Publisher).to receive(:publish)
      Dboard::Collector.register_after_update_callback callback

      Dboard::Collector.instance.update_source(:new_relic, new_relic)

      expect(callback).to have_received(:call)

      # since it is a singleton, and this callbacks leaks into the other tests
      Dboard::Collector.register_after_update_callback(lambda {})
    end

    it "can register an error callback" do
      error = RuntimeError.new("error")
      allow(new_relic).to receive(:fetch).and_raise(error)
      allow(callback).to receive(:call)
      allow(Dboard::Publisher).to receive(:publish)
      allow_any_instance_of(Dboard::Collector).to receive(:puts)
      Dboard::Collector.register_error_callback callback

      Dboard::Collector.instance.update_source(:new_relic, new_relic)

      expect(callback).to have_received(:call).with(error)

      # since it is a singleton, and this callbacks leaks into the other tests
      Dboard::Collector.register_error_callback(lambda { |_| })
    end
  end

  describe "update_source" do
    before do
      Dboard::Collector.instance.sources.clear
    end

    let(:new_relic) { double(:new_relic) }

    it "collects and publishes data from sources" do
      allow(new_relic).to receive(:fetch).and_return({ db: "100%" })
      allow(Dboard::Publisher).to receive(:publish)

      Dboard::Collector.instance.update_source(:new_relic, new_relic)

      expect(Dboard::Publisher).to have_received(:publish).with(:new_relic, { db: "100%" })
    end

    it "prints out debugging info" do
      allow(new_relic).to receive(:fetch).and_raise(Exception.new("some error"))
      allow(Dboard::Collector.instance).to receive(:puts)

      Dboard::Collector.instance.update_source(:new_relic, new_relic)

      expect(Dboard::Collector.instance).to have_received(:puts).twice
    end
  end

  describe "throttled on-demand refresh" do
    let(:collector) { Dboard::Collector.instance }

    before do
      reset_collector!
      allow(collector).to receive(:puts)
      allow(Dboard::Publisher).to receive(:publish)
    end

    after do
      join_threads
      reset_collector!
    end

    describe "the refresh decision" do
      it "refreshes immediately on the first trigger" do
        expect(collector.send(:decide_request, false, nil, 30, 100)).to eq(:refresh_now)
      end

      it "refreshes again once the floor has elapsed" do
        expect(collector.send(:decide_request, false, 100, 30, 130)).to eq(:refresh_now)
      end

      it "schedules a trailing when triggered within the floor" do
        expect(collector.send(:decide_request, false, 100, 30, 110)).to eq(:schedule)
      end

      it "coalesces a trigger that arrives while a refresh is active or scheduled" do
        expect(collector.send(:decide_request, true, 100, 30, 110)).to eq(:coalesce)
      end
    end

    describe "the effective floor" do
      it "defaults to DEFAULT_MIN_INTERVAL" do
        source = double(:source, update_interval: 100)
        expect(collector.send(:min_interval_for, source)).to eq(Dboard::Collector::DEFAULT_MIN_INTERVAL)
      end

      it "uses a source's min_update_interval override" do
        source = double(:source, update_interval: 100, min_update_interval: 10)
        expect(collector.send(:min_interval_for, source)).to eq(10)
      end

      it "never exceeds the update_interval" do
        too_short = double(:source, update_interval: 5)
        big_override = double(:source, update_interval: 5, min_update_interval: 30)
        expect(collector.send(:min_interval_for, too_short)).to eq(5)
        expect(collector.send(:min_interval_for, big_override)).to eq(5)
      end
    end

    describe "coalescing (deterministic clock)" do
      it "turns a burst into exactly one leading and one trailing refresh" do
        source = double(:source, update_interval: 100)
        allow(source).to receive(:fetch).and_return({ ok: true })
        collector.register_source(:src, source)
        use_fake_clock
        workers = capture_worker_blocks

        10.times { collector.request_update(:src) }
        workers.each(&:call)

        expect(source).to have_received(:fetch).twice
      end

      it "still fires the trailing when the floor is clamped to a fast update_interval" do
        source = double(:source, update_interval: 5)
        allow(source).to receive(:fetch).and_return({ ok: true })
        collector.register_source(:src, source)
        use_fake_clock
        workers = capture_worker_blocks

        3.times { collector.request_update(:src) }
        workers.each(&:call)

        expect(source).to have_received(:fetch).twice
      end

      it "resets in-flight state when a fetch raises, so a later trigger still refreshes" do
        source = double(:source, update_interval: 100)
        calls = 0
        allow(source).to receive(:fetch) do
          calls += 1
          raise "boom" if calls == 1

          { ok: true }
        end
        collector.register_source(:src, source)
        clock = use_fake_clock
        run_workers_inline

        collector.request_update(:src)
        expect(collector.instance_variable_get(:@active)[:src]).to be_falsey

        clock.advance(30)
        collector.request_update(:src)

        expect(source).to have_received(:fetch).twice
      end
    end

    describe "the shared clock" do
      it "re-evaluates a scheduled trailing when a poll refreshes during its sleep" do
        source = double(:source, update_interval: 100, min_update_interval: 10)
        clock = FakeClock.new
        fetch_times = []
        allow(source).to receive(:fetch) { fetch_times << clock.now; { ok: true } }
        collector.register_source(:src, source)
        allow(collector).to receive(:monotonic_now) { clock.now }

        polled = false
        allow(collector).to receive(:sleep) do |seconds|
          if polled
            clock.advance(seconds)
          else
            polled = true
            clock.advance(4)
            collector.instance_variable_get(:@last_update_at)[:src] = clock.now
          end
        end

        workers = capture_worker_blocks
        2.times { collector.request_update(:src) }
        workers.each(&:call)

        expect(fetch_times.length).to eq(2)
        expect(fetch_times.last).to be >= 4 + 10
      end
    end

    describe "with arguments" do
      it "passes the argument to fetch as a one-element batch and publishes the result" do
        source = double(:source, update_interval: 100)
        allow(source).to receive(:fetch).and_return({ ok: "x" })
        collector.register_source(:src, source)
        use_fake_clock
        run_workers_inline

        collector.request_update(:src, "x")

        expect(source).to have_received(:fetch).with([ "x" ])
        expect(Dboard::Publisher).to have_received(:publish).with(:src, { ok: "x" })
      end

      it "forwards the argument through the class-level request_update" do
        source = double(:source, update_interval: 100)
        allow(source).to receive(:fetch).and_return({ ok: true })
        collector.register_source(:src, source)
        use_fake_clock
        run_workers_inline

        Dboard::Collector.request_update(:src, "x")

        expect(source).to have_received(:fetch).with([ "x" ])
      end

      it "splits a burst of arguments into a leading batch and a trailing batch" do
        source = double(:source, update_interval: 100)
        allow(source).to receive(:fetch).and_return({ ok: true })
        collector.register_source(:src, source)
        use_fake_clock
        workers = capture_worker_blocks

        collector.request_update(:src, "x")
        collector.request_update(:src, "y")
        collector.request_update(:src, "z")
        workers.each(&:call)

        expect(source).to have_received(:fetch).with([ "x" ]).once
        expect(source).to have_received(:fetch).with([ "y", "z" ]).once
      end

      it "refreshes the whole source when no argument is given" do
        source = double(:source, update_interval: 100)
        allow(source).to receive(:fetch).and_return({ ok: true })
        collector.register_source(:src, source)
        use_fake_clock
        run_workers_inline

        collector.request_update(:src)

        expect(source).to have_received(:fetch).with(no_args)
      end

      it "does a full refresh when a no-arg request is coalesced with pending arguments" do
        source = double(:source, update_interval: 100)
        allow(source).to receive(:fetch).and_return({ ok: true })
        collector.register_source(:src, source)
        use_fake_clock
        workers = capture_worker_blocks

        collector.request_update(:src, "a")
        collector.request_update(:src, "b")
        collector.request_update(:src)
        workers.each(&:call)

        expect(source).to have_received(:fetch).with([ "a" ]).once
        expect(source).to have_received(:fetch).with(no_args).once
      end

      it "treats a caller-supplied :full argument as an ordinary partial arg" do
        source = double(:source, update_interval: 100)
        allow(source).to receive(:fetch).and_return({ ok: true })
        collector.register_source(:src, source)
        use_fake_clock
        run_workers_inline

        collector.request_update(:src, :full)

        expect(source).to have_received(:fetch).with([ :full ])
      end

      it "refreshes a source whose fetch takes no arguments" do
        source = Class.new do
          def update_interval
            100
          end

          def fetch
            { ok: true }
          end
        end.new
        collector.register_source(:src, source)
        use_fake_clock
        run_workers_inline

        collector.request_update(:src)

        expect(Dboard::Publisher).to have_received(:publish).with(:src, { ok: true })
      end

      it "retries the retained leading snapshot when a poll refreshes before it runs" do
        source = double(:source, update_interval: 100)
        fetch_args = []
        allow(source).to receive(:fetch) { |*args| fetch_args << args.first; { ok: true } }
        collector.register_source(:src, source)
        clock = use_fake_clock
        workers = capture_worker_blocks

        collector.request_update(:src, "p")
        collector.instance_variable_get(:@last_update_at)[:src] = clock.now
        workers.each(&:call)

        expect(fetch_args).to eq([ [ "p" ] ])
      end
    end

    describe "under real threads" do
      it "coalesces a burst arriving during the leading fetch into one trailing that captures the final state" do
        source = LatchSource.new(update_interval: 0.15)
        source.set_value("v1")
        source.block_next_fetch!
        collector.register_source(:src, source)
        capture_real_threads

        collector.request_update(:src)
        source.wait_until_started

        source.set_value("v2")
        10.times { collector.request_update(:src) }

        source.release!
        join_threads

        expect(source.fetch_count).to eq(2)
        expect(source.fetch_values.last).to eq("v2")
        expect(source.fetch_times[1] - source.fetch_times[0]).to be >= 0.15 - 0.02
      end

      it "throttles a sustained stream of triggers to roughly one refresh per floor" do
        source = LatchSource.new(update_interval: 0.1)
        collector.register_source(:src, source)
        capture_real_threads

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          collector.request_update(:src)
          sleep 0.01
        end
        join_threads

        expect(source.fetch_count).to be_between(2, 8)
      end
    end

    private

    def reset_collector!
      collector.sources.clear
      %i[@last_update_at @active @pending @refresh_locks].each { |ivar| collector.instance_variable_get(ivar).clear }
      collector.register_after_update_callback(lambda {})
      collector.register_error_callback(lambda { |_| })
    end

    def use_fake_clock
      clock = FakeClock.new
      allow(collector).to receive(:monotonic_now) { clock.now }
      allow(collector).to receive(:sleep) { |seconds| clock.advance(seconds) }
      clock
    end

    def run_workers_inline
      allow(collector).to receive(:spawn) { |&block| block.call }
    end

    def capture_worker_blocks
      blocks = []
      allow(collector).to receive(:spawn) { |&block| blocks << block }
      blocks
    end

    def capture_real_threads
      @threads = []
      allow(collector).to receive(:spawn) do |&block|
        thread = Thread.new(&block)
        @threads << thread
        thread
      end
    end

    def join_threads
      (@threads || []).each { |thread| thread.join(3) }
    end
  end
end
