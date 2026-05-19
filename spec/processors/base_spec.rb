require 'spec_helper'

RSpec.describe Processors::Base do
  describe '.add_opt' do
    it 'applies nice as a general parsed option' do
      opts = SymMash.new

      allow(Process).to receive(:setpriority)

      described_class.add_opt(opts, 'nice=19')

      expect(opts.nice).to eq('19')
      expect(Process).to have_received(:setpriority).with(Process::PRIO_PROCESS, 0, 19)
    end
  end
end
