require File.expand_path(File.join(File.dirname(__FILE__), "spec_helper"))

describe Dboard::Collector, ".register_source" do
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
    Dboard::Collector.register_after_update_callback callback

    expect(callback).to receive(:call)
    allow(Dboard::Publisher).to receive(:publish)
    Dboard::Collector.instance.update_source(:new_relic, new_relic)

    # since it is a singleton, and this callbacks leaks into the other tests
    Dboard::Collector.register_after_update_callback(lambda {})
  end

  it "can register an error callback" do
    error = RuntimeError.new("error")
    allow(new_relic).to receive(:fetch).and_raise(error)

    Dboard::Collector.register_error_callback callback

    expect(callback).to receive(:call).with(error)
    allow(Dboard::Publisher).to receive(:publish)
    allow_any_instance_of(Dboard::Collector).to receive(:puts)
    Dboard::Collector.instance.update_source(:new_relic, new_relic)

    # since it is a singleton, and this callbacks leaks into the other tests
    Dboard::Collector.register_error_callback(lambda { |_| })
  end
end

describe Dboard::Collector, "update_source" do
  before do
    Dboard::Collector.instance.sources.clear
  end

  let(:new_relic) { double(:new_relic) }

  it "collects and publishes data from sources" do
    allow(new_relic).to receive(:fetch).and_return({ db: "100%" })
    expect(Dboard::Publisher).to receive(:publish).with(:new_relic, { db: "100%" })
    Dboard::Collector.instance.update_source(:new_relic, new_relic)
  end

  it "prints out debugging info" do
    allow(new_relic).to receive(:fetch).and_raise(Exception.new("some error"))
    expect(Dboard::Collector.instance).to receive(:puts).twice
    Dboard::Collector.instance.update_source(:new_relic, new_relic)
  end
end
