require 'spec_helper'

RSpec.describe Processors::Base do
  it 'parses options from message captions' do
    Dir.mktmpdir('base-spec-') do |dir|
      ctx = Context.new(dir: dir, msg: SymMash.new(text: '', caption: 'audio speed=1.2'))
      processor = described_class.new(ctx)

      expect(processor.opts.audio).to eq(1)
      expect(processor.opts.speed).to eq('1.2')
    end
  end

  it 'expands language options from url query parameters' do
    Dir.mktmpdir('base-spec-') do |dir|
      ctx = Context.new(dir: dir, msg: SymMash.new(text: 'https://www.youtube.com/watch?v=4MCYhF_bte8&lang=pt'))
      processor = described_class.new(ctx)

      expect(processor.url).to eq('https://www.youtube.com/watch?v=4MCYhF_bte8')
      expect(processor.opts.slang).to eq('pt')
      expect(processor.opts.alang).to eq('pt')
    end
  end

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
