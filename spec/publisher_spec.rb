require File.expand_path(File.join(File.dirname(__FILE__), "spec_helper"))

describe "Publisher", ".publish" do
  it "sends data to the dashboard server" do
    expect(Dboard::Api::Client).to receive(:post).with("/sources/new_relic", body: { data: { db: "80%" }.to_json }, timeout: 10000)
    Dboard::Publisher.publish(:new_relic, { db: "80%" })
  end

  it "retries network errors" do
    stub_request(:post, "http://api.example/sources/new_relic")
      .to_timeout.times(2)
      .to_return({ body: "OK!" })

    Dboard::Publisher.publish(:new_relic, {})
  end

  it "raises network errors if we run out of retries" do
    stub_request(:post, "http://api.example/sources/new_relic")
      .to_timeout.times(3)
      .to_return({ body: "OK!" })

    expect {
      Dboard::Publisher.publish(:new_relic, {})
    }.to raise_error(Net::OpenTimeout)
  end

  # 2021-12-07: No idea why we've treated this one specially, but keeping it for now.
  it "logs socket errors if we run out of retries" do
    expect(Dboard::Api::Client).to receive(:post).and_raise(SocketError.new("failed to connect"))
    expect(Dboard::Publisher).to receive(:puts).with("SocketError: failed to connect")
    Dboard::Publisher.publish(:new_relic, {})
  end
end
