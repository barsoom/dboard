require File.expand_path(File.join(File.dirname(__FILE__), "spec_helper"))

describe "Publisher", "publish" do
  it "should send data to the dashboard server" do
    expect(Dboard::Api::Client).to receive(:post).with("/sources/new_relic", :body => { :data => { :db => "80%" }.to_json }, :timeout => 10000)
    Dboard::Publisher.publish(:new_relic, { :db => "80%" })
  end

  it "should handle and log socket errors" do
    expect(Dboard::Api::Client).to receive(:post).and_raise(SocketError.new("failed to connect"))
    expect(Dboard::Publisher).to receive(:puts).with("SocketError: failed to connect")
    Dboard::Publisher.publish(:new_relic, {})
  end
end
