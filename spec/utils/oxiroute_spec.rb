require 'rails_helper'

RSpec.describe Utils::Oxiroute do
  let(:metrics) do
    <<~TEXT
      oxiroute_pool_queue_depth{pool="nginx"} 4
      oxiroute_pool_queue_depth{pool="omnivoice_nodes"} 7
      oxiroute_pool_queue_admissions_total{pool="omnivoice_nodes"} 9
    TEXT
  end

  before do
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:get).and_return(instance_double(Net::HTTPOK, value: nil, body: metrics))
  end

  it 'reads how many requests wait for a server of a pool' do
    expect(described_class.new.queue_depth('omnivoice_nodes')).to eq(7)
  end

  it 'fails for a pool it does not publish, rather than reading it as nothing waiting' do
    expect { described_class.new.queue_depth('nope') }.to raise_error(/no oxiroute_pool_queue_depth for the pool nope/)
  end
end
