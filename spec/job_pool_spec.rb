require 'spec_helper'
require_relative '../lib/job_pool'

RSpec.describe JobPool do
  it 'streams parallel results in input order' do
    completed = Queue.new
    values = described_class.new(jobs: 3).ordered_map([0.06, 0.03, 0.01]) do |delay|
      sleep delay
      completed << delay
      delay
    end.to_a

    expect(values).to eq([0.06, 0.03, 0.01])
    expect(completed.pop).to eq(0.01)
  end

  it 'raises worker errors to the ordered consumer' do
    results = described_class.new(jobs: 2).ordered_map([1, 2, 3]) do |value|
      raise 'worker failed' if value == 2

      value
    end

    expect { results.to_a }.to raise_error('worker failed')
  end
end
