require 'spec_helper'
require_relative '../../lib/bot/status'

RSpec.describe Bot::Status do
  it 'runs empty cleanup after deleting the last successful line' do
    cleaned = false
    updates = []
    status = described_class.new(on_empty: -> { cleaned = true }) { |text| updates << text }

    status.add('working') { 'ok' }

    expect(cleaned).to eq(true)
    expect(updates).to eq(['working'])
  end

  it 'keeps error lines instead of running empty cleanup' do
    cleaned = false
    status = described_class.new(on_empty: -> { cleaned = true }) { |_text| }

    status.add('working') { |line| line.error('failed') }

    expect(cleaned).to eq(false)
    expect(status.formatted).to eq('failed')
  end
end
