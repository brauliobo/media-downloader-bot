require 'spec_helper'
require_relative '../../lib/utils/progress_counter'

RSpec.describe Utils::ProgressCounter do
  it 'reports synchronized count and total progress for batches and items' do
    updates = []
    status = double(update: nil)
    allow(status).to receive(:update) { |message| updates << message }
    progress = described_class.new(total: 5, status: status) do |count, total|
      "Processing #{count}/#{total}"
    end

    progress.batch_callback.call([:first, :second])
    progress.advance

    expect(updates).to eq(['Processing 2/5', 'Processing 3/5'])
  end
end
